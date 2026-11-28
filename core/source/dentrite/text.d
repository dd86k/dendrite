/// Text rendering: font files, shaping with HarfBuzz, rasterizing with FreeType into one glyph atlas.
///
/// Characters the slot's font lacks come from the first fallback file that has them, as runs shaped apart.
/// Emoji prefer a fallback with color glyphs, which draw in their own colors at whole pixels.
/// NOTE: fallback glyphs use the slot font's line metrics.
///
/// Shaping runs at the physical pixel size, so runs and metrics are in physical
/// pixels and callers divide by `ppp` for layout. Glyphs are rasterized with light
/// (vertical only) hinting at one of four horizontal subpixel offsets. A scale
/// change drops every cache.
module dentrite.text;

import core.stdc.config : c_long;
import dentrite.c.freetype;
import dentrite.c.harfbuzz;
import std.algorithm.comparison : max, min;
import std.exception : enforce;
import std.format : format;
import std.math : ceil, floor, pow, round;
import std.string : toStringz;
import std.typecons : Yes;
import std.uni : isMark;
import std.utf : decode;

/// Font slots that styles name.
enum FontKind : ubyte
{
    ui,       /// proportional body text
    uiStrong, /// proportional, heavier, for headers and buttons
    mono,     /// fixed pitch, for addresses, bytes and code
}

/// Font file by path or by its bytes, such as `FontFile(data: import("Inter.otf"))`.
struct FontFile
{
    string path;             /// file to open, when `data` is empty
    immutable(ubyte)[] data; /// font file bytes, kept for the life of the text system

    /// Opens it as `face`. False when FreeType cannot.
    private bool open(FT_Library lib, out FT_Face face) const
    {
        if (data.length > 0)
        {
            return FT_New_Memory_Face(lib, data.ptr, cast(c_long) data.length, 0, &face) == 0;
        }
        return FT_New_Face(lib, path.toStringz, 0, &face) == 0;
    }
}

/// OpenType features to shape with, combined with `|`. Each member names its tag. Color fonts shape without them.
/// NOTE: `ccmp`, `kern` and the mark features stay on, text needs them.
enum Features : ulong
{
    none = 0,                 /// the font's defaults
    tabular = 1UL << 0,       /// `tnum`, equal-width digits
    proportional = 1UL << 1,  /// `pnum`, digits of their own widths
    lining = 1UL << 2,        /// `lnum`, digits at cap height
    oldstyle = 1UL << 3,      /// `onum`, digits with ascenders and descenders
    slashedZero = 1UL << 4,   /// `zero`
    fractions = 1UL << 5,     /// `frac`, digits around a slash as a fraction
    ordinals = 1UL << 6,      /// `ordn`, 1st and 2nd with raised letters
    superscript = 1UL << 7,   /// `sups`
    subscript = 1UL << 8,     /// `subs`
    caseForms = 1UL << 9,     /// `case`, punctuation placed for capitals
    smallCaps = 1UL << 10,    /// `smcp`, lowercase as small capitals
    capsToSmall = 1UL << 11,  /// `c2sc`, capitals as small capitals
    discretionary = 1UL << 12, /// `dlig` on, rare ligatures
    noLigatures = 1UL << 13,  /// `liga` and `clig` off
    noContextual = 1UL << 14, /// `calt` off, also the code ligatures of fonts like JetBrains Mono
    ss01 = 1UL << 15,         /// stylistic set 1
    ss02 = 1UL << 16,         /// stylistic set 2
    ss03 = 1UL << 17,         /// stylistic set 3
    ss04 = 1UL << 18,         /// stylistic set 4
    ss05 = 1UL << 19,         /// stylistic set 5
    ss06 = 1UL << 20,         /// stylistic set 6
    ss07 = 1UL << 21,         /// stylistic set 7
    ss08 = 1UL << 22,         /// stylistic set 8
    ss09 = 1UL << 23,         /// stylistic set 9
    ss10 = 1UL << 24,         /// stylistic set 10
    ss11 = 1UL << 25,         /// stylistic set 11
    ss12 = 1UL << 26,         /// stylistic set 12
    ss13 = 1UL << 27,         /// stylistic set 13
    ss14 = 1UL << 28,         /// stylistic set 14
    ss15 = 1UL << 29,         /// stylistic set 15
    ss16 = 1UL << 30,         /// stylistic set 16
    ss17 = 1UL << 31,         /// stylistic set 17
    ss18 = 1UL << 32,         /// stylistic set 18
    ss19 = 1UL << 33,         /// stylistic set 19
    ss20 = 1UL << 34,         /// stylistic set 20
}

/// Tags of `Features` bit `i`, in bit order. `noLigatures` and `noContextual` turn theirs off.
private immutable string[][] featureTags = [["tnum"], ["pnum"], ["lnum"], ["onum"], ["zero"], ["frac"], ["ordn"],
    ["sups"], ["subs"], ["case"], ["smcp"], ["c2sc"], ["dlig"], ["liga", "clig"], ["calt"], ["ss01"], ["ss02"],
    ["ss03"], ["ss04"], ["ss05"], ["ss06"], ["ss07"], ["ss08"], ["ss09"], ["ss10"], ["ss11"], ["ss12"], ["ss13"],
    ["ss14"], ["ss15"], ["ss16"], ["ss17"], ["ss18"], ["ss19"], ["ss20"]];

static assert(featureTags.length == __traits(allMembers, Features).length - 1, "a tag list per feature");

/// Most HarfBuzz features one `Features` value turns into.
private enum size_t maxFeatures = __traits(allMembers, Features).length;

/// Fills `buf` with the HarfBuzz features of `f`, over the whole text, and returns the used part.
private hb_feature_t[] hbFeatures(Features f, return ref hb_feature_t[maxFeatures] buf)
{
    size_t n;
    foreach (size_t i, const string[] tags; featureTags)
    {
        if ((f & (1UL << i)) == 0)
        {
            continue;
        }
        Features bit = cast(Features)(1UL << i);
        uint value = bit == Features.noLigatures || bit == Features.noContextual ? 0 : 1;
        foreach (string t; tags)
        {
            buf[n++] = hb_feature_t(hbTag(t), value, 0, uint.max);
        }
    }
    return buf[0 .. n];
}

/// Horizontal subpixel positions per pixel.
enum int subpixelBins = 4;

/// One font face at one physical pixel size.
final class SizedFont
{
    uint id;        /// index in `TextSystem.sized`, part of glyph keys
    size_t file;    /// font file index: a `FontKind` slot, or a fallback numbered after the slots
    float px;       /// physical pixel size
    FT_Face face;   /// FreeType face, size set to `px`
    hb_font_t* hb;  /// HarfBuzz font over `face`
    float ascent;   /// physical pixels above the baseline
    float descent;  /// physical pixels below the baseline, positive
    float lineGap;  /// extra physical pixels between lines
    bool color;     /// has color glyphs, such as emoji
    float strikeScale = 1; /// physical pixels per bitmap pixel of a bitmap-only font, else 1
}

/// Shaped text in physical pixels from the run's pen start.
final class ShapedRun
{
    string text;      /// source text, UTF-8
    SizedFont font;   /// slot font it was shaped with
    SizedFont[] faces; /// font of each glyph when fallbacks were used, else empty
    uint[] glyphs;    /// glyph indices
    float[] pens;     /// pen x before each glyph
    float[] xs;       /// draw x of each glyph, the pen plus its x offset
    float[] ys;       /// y offset of each glyph, down positive
    uint[] clusters;  /// byte offset in `text` of each glyph's cluster
    float width = 0;  /// total advance in physical pixels

    /// Pen x before the character at byte `index`, for carets. `text.length` gives the end.
    float caretX(size_t index) const
    {
        foreach (size_t i, uint c; clusters)
        {
            if (c >= index)
            {
                return pens[i];
            }
        }
        return width;
    }

    /// Left edge of each character of bytes `from .. to`, then the edge at `to`, in logical pixels from physical
    /// `origin` at `ppp` physical pixels per logical one. Characters inside a ligature after its first are empty.
    float[] charEdges(size_t from, size_t to, float origin, float ppp) const
    {
        import std.utf : stride;

        float[] edges;
        size_t g;
        /// Edge before byte `b`, moving `g` forward to the first glyph at or after it.
        float at(size_t b)
        {
            while (g < clusters.length && clusters[g] < b)
            {
                ++g;
            }
            return ((g < clusters.length ? pens[g] : width) - origin) / ppp;
        }

        for (size_t p = from; p < to; p += stride(text, p))
        {
            edges ~= at(p);
        }
        edges ~= at(to);
        return edges;
    }

    /// Byte offset of the caret position nearest to physical `x`.
    size_t indexAt(float x) const
    {
        if (glyphs.length == 0 || x <= 0)
        {
            return 0;
        }
        foreach (size_t i; 0 .. glyphs.length)
        {
            float start = pens[i];
            float end = i + 1 < glyphs.length ? pens[i + 1] : width;
            if (x < (start + end) / 2)
            {
                return clusters[i];
            }
        }
        return text.length;
    }
}

/// One line of wrapped text: glyphs `[first, last)` of a run.
struct Line
{
    size_t first;  /// index of the first glyph in the run
    size_t last;   /// index one past the last glyph in the run
    float x0 = 0;  /// run x of the first glyph, subtract to start the line at zero
    float width = 0; /// advance of the line without trailing spaces
}

/// Lines of `run` no wider than `maxWidth` physical pixels, broken after spaces.
/// A word longer than the width gets a line of its own and overflows.
Line[] wrap(const ShapedRun run, float maxWidth)
{
    Line[] lines;
    size_t n = run.glyphs.length;
    if (n == 0)
    {
        return [Line(0, 0, 0, 0)];
    }

    /// Run x where glyph `i` starts, or the run end.
    float startOf(size_t i)
    {
        return i < n ? run.pens[i] : run.width;
    }

    /// True if glyph `i` is a space.
    bool space(size_t i)
    {
        uint c = run.clusters[i];
        return c < run.text.length && (run.text[c] == ' ' || run.text[c] == '\t');
    }

    size_t first;
    size_t lastBreak = size_t.max;
    foreach (size_t i; 0 .. n)
    {
        if (space(i))
        {
            lastBreak = i;
        }
        float right = startOf(i + 1) - startOf(first);
        if (right > maxWidth && i > first && lastBreak != size_t.max && lastBreak >= first)
        {
            size_t end = lastBreak;
            lines ~= Line(first, end, startOf(first), startOf(end) - startOf(first));
            first = end + 1;
            lastBreak = size_t.max;
        }
    }
    size_t end = n;
    while (end > first && space(end - 1))
    {
        --end;
    }
    lines ~= Line(first, n, startOf(first), startOf(end) - startOf(first));
    return lines;
}

/// Atlas cache key: font, glyph and subpixel bin.
struct GlyphKey
{
    uint font;  /// `SizedFont.id` of the font
    uint glyph; /// glyph index
    ubyte bin;  /// horizontal offset in 1/subpixelBins of a pixel
}

/// Glyph bitmap placed in the atlas.
struct GlyphSlot
{
    short x;    /// left edge in the atlas, in texels
    short y;    /// top edge in the atlas, in texels
    short w;    /// bitmap width in texels, zero for blank glyphs
    short h;    /// bitmap height in texels
    short left; /// distance from the pen x to the left edge of the bitmap
    short top;  /// distance from the baseline up to the top edge of the bitmap
    bool color; /// texels hold the glyph's own colors, drawn with a white vertex color
}

/// RGBA8 premultiplied atlas: a white block for untextured shapes, then glyphs packed in shelves.
/// Grows by doubling its height, so texel coordinates stay valid until `clear`.
final class GlyphAtlas
{
    int width;            /// width in texels
    int height;           /// height in texels
    ubyte[] pixels;       /// premultiplied RGBA8 rows, top first
    int dirtyTop = int.max; /// first row changed this frame, see `endFrame`
    int dirtyBottom;      /// one past the last row changed this frame
    bool full;            /// true when out of space, cleared before the next frame
    uint generation;      /// bumped by `clear`, meshes made before hold stale texel coordinates
    ulong frames;         /// frames ended so far, see `changedRows`
    enum int maxHeight = 4096; /// tallest the atlas grows, in texels

    private GlyphSlot[GlyphKey] slots; /// placed glyphs
    private int shelfX;   /// next free x on the current shelf
    private int shelfY;   /// top of the current shelf
    private int shelfH;   /// height of the current shelf
    private ulong[] rowFrame; /// per texel row, the value of `frames` when it last changed

    /// Creates an empty atlas `width` texels wide.
    this(int width = 1024, int height = 1024)
    {
        this.width = width;
        this.height = height;
        clear();
    }

    /// Drops every glyph and keeps the white block.
    void clear()
    {
        ++generation;
        pixels = new ubyte[width * height * 4];
        rowFrame = new ulong[height];
        rowFrame[] = frames;
        slots = null;
        pixels[0 .. 4 * 4] = 0xff;
        foreach (int y; 0 .. 4)
        {
            pixels[y * width * 4 .. y * width * 4 + 16] = 0xff;
        }
        shelfX = 5;
        shelfY = 0;
        shelfH = 5;
        full = false;
        dirtyTop = 0;
        dirtyBottom = height;
    }

    /// Texel center of the white block, the UV of untextured vertices.
    static float whiteUV()
    {
        return 2;
    }

    /// Slot of `key`, or null if not placed yet.
    GlyphSlot* find(GlyphKey key)
    {
        return key in slots;
    }

    /// Places a `w` by `h` coverage bitmap with `pitch` bytes per row. Null when out of space.
    GlyphSlot* place(GlyphKey key, int w, int h, int pitch, const(ubyte)* src, int left, int top,
        const ref ubyte[256] curve)
    {
        GlyphSlot* s = reserve(key, w, h, left, top, false);
        if (s is null || w == 0 || h == 0)
        {
            return s;
        }
        foreach (int row; 0 .. h)
        {
            const(ubyte)* line = src + row * pitch;
            size_t at = (cast(size_t)(s.y + row) * width + s.x) * 4;
            ubyte[] dst = pixels[at .. at + w * 4];
            foreach (int col; 0 .. w)
            {
                ubyte c = curve[line[col]];
                dst[col * 4 .. col * 4 + 4] = c;
            }
        }
        return s;
    }

    /// Places a `w` by `h` premultiplied RGBA bitmap with packed rows. Null when out of space.
    GlyphSlot* placeColor(GlyphKey key, int w, int h, const(ubyte)[] rgba, int left, int top)
    {
        GlyphSlot* s = reserve(key, w, h, left, top, true);
        if (s is null || w == 0 || h == 0)
        {
            return s;
        }
        foreach (int row; 0 .. h)
        {
            size_t at = (cast(size_t)(s.y + row) * width + s.x) * 4;
            pixels[at .. at + w * 4] = rgba[row * w * 4 .. (row + 1) * w * 4];
        }
        return s;
    }

    /// Slot for a `w` by `h` bitmap on the shelves, marked dirty. Null when out of space.
    private GlyphSlot* reserve(GlyphKey key, int w, int h, int left, int top, bool color)
    {
        if (w == 0 || h == 0)
        {
            slots[key] = GlyphSlot(0, 0, 0, 0, cast(short) left, cast(short) top, color);
            return key in slots;
        }
        if (shelfX + w + 1 > width)
        {
            shelfY += shelfH;
            shelfX = 0;
            shelfH = 0;
        }
        while (shelfY + h + 1 > height)
        {
            if (height * 2 > maxHeight)
            {
                full = true;
                return null;
            }
            grow();
        }
        int x = shelfX;
        int y = shelfY;
        shelfX += w + 1;
        shelfH = max(shelfH, h + 1);
        dirtyTop = min(dirtyTop, y);
        dirtyBottom = max(dirtyBottom, y + h);
        rowFrame[y .. y + h] = frames;
        slots[key] = GlyphSlot(cast(short) x, cast(short) y, cast(short) w, cast(short) h,
            cast(short) left, cast(short) top, color);
        return key in slots;
    }

    /// Doubles the height, keeping texel coordinates.
    private void grow()
    {
        height *= 2;
        pixels.length = width * height * 4;
        size_t old = rowFrame.length;
        rowFrame.length = height;
        rowFrame[old .. $] = frames;
    }

    /// Rows changed this frame as `[top, bottom)`, empty when clean. Every renderer drawing this frame reads them.
    void dirtyRows(out int top, out int bottom) const
    {
        top = dirtyTop == int.max ? 0 : dirtyTop;
        bottom = dirtyTop == int.max ? 0 : dirtyBottom;
    }

    /// Rows changed since frame `since` of `frames`, this one included, as `[top, bottom)`, empty when clean. For a
    /// renderer that skips frames, such as one of a window drawn less often.
    void changedRows(ulong since, out int top, out int bottom) const
    {
        top = height;
        foreach (int y; 0 .. height)
        {
            if (rowFrame[y] >= since)
            {
                top = min(top, y);
                bottom = y + 1;
            }
        }
        if (bottom == 0)
        {
            top = 0;
        }
    }

    /// Starts a frame with no changed rows, once every renderer drew.
    void endFrame()
    {
        ++frames;
        dirtyTop = int.max;
        dirtyBottom = 0;
    }
}

/// Cache key of a shaped string.
private struct RunKey
{
    FontKind kind; /// slot
    uint size64;   /// logical size times 64
    Features features; /// OpenType features
    string text;   /// text shaped
}

/// Cached run and the frame it was last used in.
private struct CachedRun
{
    ShapedRun run; /// shaped text
    ulong used;    /// frame counter at last use
}

/// Atlas slot found lately, for the lookup cache of `TextSystem.glyph`.
private struct RecentGlyph
{
    GlyphKey key;    /// font, glyph and bin
    GlyphSlot* slot; /// placed glyph, null for an empty entry
}

/// Fonts, shaping cache and glyph atlas of one window.
final class TextSystem
{
    float ppp = 1;           /// physical pixels per logical pixel
    GlyphAtlas atlas;        /// glyph atlas shared by every run
    ulong frame;             /// frame counter for cache eviction
    float contrast = 1.0;    /// coverage exponent, below 1 darkens thin text
    int rasterized;          /// glyphs rasterized so far

    private FT_Library lib;                 /// FreeType library
    private immutable(ubyte)[][FontKind.max + 1] files; /// font file bytes per slot
    private FontFile[] fallbacks;           /// fallback fonts, tried in order
    private bool[] badFallback;             /// fallbacks that did not open
    private SizedFont[] sized;              /// every sized font, by id
    private SizedFont[ulong] bySize;        /// sized fonts by slot and size
    private CachedRun[RunKey] runs;         /// shaped strings
    private hb_buffer_t* buffer;            /// shaping buffer, reused
    private ubyte[256] curve;               /// coverage curve from `contrast`
    private RecentGlyph[1024] recent;       /// atlas lookups by a hash of their key, newest wins
    private uint recentGeneration;          /// atlas generation of `recent`

    /// Loads one font file per slot. `fallbacks` open when a character needs them, and bad ones are skipped.
    this(string[FontKind.max + 1] paths, string[] fallbacks = null)
    {
        import std.file : read;

        immutable(ubyte)[][FontKind.max + 1] slots;
        foreach (size_t i, string p; paths)
        {
            slots[i] = cast(immutable(ubyte)[]) read(p);
        }
        FontFile[] more;
        foreach (string p; fallbacks)
        {
            more ~= FontFile(p);
        }
        this(slots, more);
    }

    /// Takes the font file bytes of each slot. `fallbacks` open when a character needs them, and bad ones are
    /// skipped.
    this(immutable(ubyte)[][FontKind.max + 1] slots, FontFile[] fallbacks)
    {
        files = slots;
        this.fallbacks = fallbacks.dup;
        badFallback = new bool[fallbacks.length];
        enforce(FT_Init_FreeType(&lib) == 0, "FreeType init failed");
        buffer = hb_buffer_create();
        atlas = new GlyphAtlas;
        setContrast(contrast);
    }

    /// Frees fonts and the library.
    void dispose()
    {
        dropFonts();
        hb_buffer_destroy(buffer);
        FT_Done_FreeType(lib);
    }

    /// Sets the coverage exponent and clears the atlas.
    void setContrast(float c)
    {
        contrast = c;
        foreach (int i; 0 .. 256)
        {
            curve[i] = cast(ubyte) round(pow(i / 255.0, c) * 255);
        }
        atlas.clear();
    }

    /// Changes the scale. Every run and glyph is redone at the new size.
    void setScale(float scale)
    {
        if (scale == ppp)
        {
            return;
        }
        ppp = scale;
        dropFonts();
        runs = null;
        atlas.clear();
    }

    /// Replaces the font of slot `kind` with font file bytes `data`, throwing if FreeType cannot open them. Every
    /// run and glyph is redone.
    void setFont(FontKind kind, immutable(ubyte)[] data)
    {
        FT_Face test;
        enforce(data.length > 0 && FT_New_Memory_Face(lib, data.ptr, cast(c_long) data.length, 0, &test) == 0,
            "bad font file");
        FT_Done_Face(test);
        files[kind] = data;
        dropFonts();
        runs = null;
        atlas.clear();
    }

    /// Frees every sized font.
    private void dropFonts()
    {
        foreach (SizedFont f; sized)
        {
            hb_font_destroy(f.hb);
            FT_Done_Face(f.face);
        }
        sized = null;
        bySize = null;
    }

    /// Font of `kind` at logical `size` and the current scale.
    SizedFont font(FontKind kind, float size)
    {
        return face(kind, size);
    }

    /// Fallback `i` at logical `size`, or null when its file does not open.
    private SizedFont fallback(size_t i, float size)
    {
        if (badFallback[i])
        {
            return null;
        }
        SizedFont f = face(FontKind.max + 1 + i, size);
        badFallback[i] = f is null;
        return f;
    }

    /// Font file `file`, a slot or a fallback after the slots, at logical `size`. Null when a fallback does not
    /// open.
    private SizedFont face(size_t file, float size)
    {
        uint px64 = cast(uint) round(size * ppp * 64);
        ulong key = (cast(ulong) file << 32) | px64;
        if (SizedFont* f = key in bySize)
        {
            return *f;
        }
        SizedFont f = new SizedFont;
        f.file = file;
        f.px = px64 / 64.0f;
        if (file <= FontKind.max)
        {
            immutable(ubyte)[] data = files[file];
            enforce(FT_New_Memory_Face(lib, data.ptr, cast(c_long) data.length, 0, &f.face) == 0, "bad font file");
        }
        else if (fallbacks[file - FontKind.max - 1].open(lib, f.face) == false)
        {
            return null;
        }
        f.id = cast(uint) sized.length;
        f.color = (f.face.face_flags & FT_FACE_FLAG_COLOR) != 0;
        if ((f.face.face_flags & FT_FACE_FLAG_SCALABLE) == 0 && f.face.num_fixed_sizes > 0)
        {
            // HarfBuzz reads advances from the font tables, FreeType only knows the strike size.
            int strike = nearestStrike(f.face, px64);
            FT_Select_Size(f.face, strike);
            f.strikeScale = px64 / cast(float) f.face.available_sizes[strike].y_ppem;
            hb_face_t* hf = hb_ft_face_create_referenced(f.face);
            f.hb = hb_font_create(hf);
            hb_face_destroy(hf);
            hb_font_set_scale(f.hb, px64, px64);
        }
        else
        {
            FT_Set_Char_Size(f.face, 0, px64, 72, 72);
            f.hb = hb_ft_font_create_referenced(f.face);
        }
        float scale = f.px / f.face.units_per_EM;
        f.ascent = f.face.ascender * scale;
        f.descent = -f.face.descender * scale;
        f.lineGap = max(0f, f.face.height * scale - f.ascent - f.descent);
        sized ~= f;
        bySize[key] = f;
        return f;
    }

    /// Line height of `kind` at logical `size`, in logical pixels.
    float lineHeight(FontKind kind, float size)
    {
        SizedFont f = font(kind, size);
        return ceil(f.ascent + f.descent) / ppp;
    }

    /// Distance from the line top to the baseline, in logical pixels.
    float ascent(FontKind kind, float size)
    {
        SizedFont f = font(kind, size);
        return f.ascent / ppp;
    }

    /// `text` shaped with `kind` at logical `size` and `features`, from the cache when possible.
    ShapedRun shape(FontKind kind, float size, string text, Features features = Features.none)
    {
        RunKey key = RunKey(kind, cast(uint) round(size * 64), features, text);
        if (CachedRun* hit = key in runs)
        {
            hit.used = frame;
            return hit.run;
        }
        ShapedRun r = shapeUncached(font(kind, size), size, text, features);
        runs[RunKey(kind, key.size64, features, r.text)] = CachedRun(r, frame);
        return r;
    }

    /// Logical width of `text`.
    float measure(FontKind kind, float size, string text, Features features = Features.none)
    {
        return shape(kind, size, text, features).width / ppp;
    }

    /// Shapes `text` with `f`, at logical `size`, and its fallbacks, with `features`.
    private ShapedRun shapeUncached(SizedFont f, float size, string text, Features features)
    {
        ShapedRun r = new ShapedRun;
        r.text = text.idup;
        r.font = f;
        SizedFont current;
        size_t start;
        size_t i;
        while (i < r.text.length)
        {
            size_t at = i;
            dchar c = decode!(Yes.useReplacementDchar)(r.text, i);
            size_t j = i;
            dchar next = j < r.text.length ? decode!(Yes.useReplacementDchar)(r.text, j) : 0;
            SizedFont want = fontFor(c, next, f, current, size);
            if (current !is null && want !is current)
            {
                shapePart(r, current, start, at, features);
                start = at;
            }
            current = want;
        }
        shapePart(r, current is null ? f : current, start, r.text.length, features);
        return r;
    }

    /// Font for `c` followed by `next`: `current` for marks and joiners after it, a color fallback for emoji,
    /// then `f`, then the first fallback having it, then `f` for its missing glyph.
    private SizedFont fontFor(dchar c, dchar next, SizedFont f, SizedFont current, float size)
    {
        bool joins = isMark(c) || c == 0x200C || c == 0x200D || (c >= 0xFE00 && c <= 0xFE0F)
            || (c >= 0xE0020 && c <= 0xE007F) || (c >= 0xE0100 && c <= 0xE01EF);
        if (current !is null && joins)
        {
            return current;
        }
        if (next != 0xFE0E && (next == 0xFE0F || isEmoji(c)))
        {
            foreach (size_t i; 0 .. fallbacks.length)
            {
                SizedFont g = fallback(i, size);
                if (g !is null && g.color && FT_Get_Char_Index(g.face, c) != 0)
                {
                    return g;
                }
            }
        }
        if (c < 0x80 || fallbacks.length == 0 || FT_Get_Char_Index(f.face, c) != 0)
        {
            return f;
        }
        foreach (size_t i; 0 .. fallbacks.length)
        {
            SizedFont g = fallback(i, size);
            if (g !is null && FT_Get_Char_Index(g.face, c) != 0)
            {
                return g;
            }
        }
        return f;
    }

    /// Shapes bytes `[start, end)` of `r.text` with `f` and appends the glyphs to `r`, with the rest of the text
    /// as context and `features` unless `f` has color glyphs. Fills `r.faces` once a part uses a font other
    /// than `r.font`.
    private void shapePart(ShapedRun r, SizedFont f, size_t start, size_t end, Features features)
    {
        hb_buffer_clear_contents(buffer);
        hb_buffer_add_utf8(buffer, r.text.ptr, cast(int) r.text.length, cast(uint) start, cast(int)(end - start));
        hb_buffer_guess_segment_properties(buffer);
        hb_feature_t[maxFeatures] buf;
        hb_feature_t[] list = f.color ? null : hbFeatures(features, buf);
        hb_shape(f.hb, buffer, list.ptr, cast(uint) list.length);
        uint n;
        hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer, &n);
        hb_glyph_position_t* pos = hb_buffer_get_glyph_positions(buffer, &n);
        if (f !is r.font && r.faces.length < r.glyphs.length)
        {
            r.faces = new SizedFont[r.glyphs.length];
            r.faces[] = r.font;
        }
        float pen = r.width;
        foreach (uint i; 0 .. n)
        {
            r.glyphs ~= infos[i].codepoint;
            r.clusters ~= infos[i].cluster;
            r.pens ~= pen;
            r.xs ~= pen + pos[i].x_offset / 64.0f;
            r.ys ~= -pos[i].y_offset / 64.0f;
            pen += pos[i].x_advance / 64.0f;
            if (r.faces.length > 0 || f !is r.font)
            {
                r.faces ~= f;
            }
        }
        r.width = pen;
    }

    /// Atlas slot of glyph `glyph` of `f` at subpixel `bin`, rasterized on first use. Null when the atlas is full.
    GlyphSlot* glyph(SizedFont f, uint glyph, ubyte bin)
    {
        if (f.color)
        {
            bin = 0;
        }
        GlyphKey key = GlyphKey(f.id, glyph, bin);
        if (recentGeneration != atlas.generation)
        {
            recent[] = RecentGlyph.init;
            recentGeneration = atlas.generation;
        }
        RecentGlyph* r = &recent[((f.id * 0x9E3779B1u) ^ (glyph * subpixelBins + bin)) & (recent.length - 1)];
        if (r.slot !is null && r.key == key)
        {
            return r.slot;
        }
        GlyphSlot* s = atlas.find(key);
        if (s is null)
        {
            s = rasterize(f, key);
        }
        if (s !is null)
        {
            *r = RecentGlyph(key, s);
        }
        return s;
    }

    /// Rasterizes the glyph of `key` in `f` into the atlas. Null when the atlas is full.
    private GlyphSlot* rasterize(SizedFont f, GlyphKey key)
    {
        if (f.color)
        {
            return rasterizeColor(f, key);
        }
        uint glyph = key.glyph;
        ubyte bin = key.bin;
        FT_Vector delta = FT_Vector(bin * 64 / subpixelBins, 0);
        FT_Set_Transform(f.face, null, &delta);
        scope (exit)
        {
            FT_Set_Transform(f.face, null, null);
        }
        if (FT_Load_Glyph(f.face, glyph, FT_LOAD_TARGET_LIGHT) != 0
            || FT_Render_Glyph(f.face.glyph, FT_RENDER_MODE_LIGHT) != 0)
        {
            return atlas.place(key, 0, 0, 0, null, 0, 0, curve);
        }
        FT_GlyphSlot g = f.face.glyph;
        ++rasterized;
        if (g.bitmap.pixel_mode != FT_PIXEL_MODE_GRAY)
        {
            return atlas.place(key, 0, 0, 0, null, 0, 0, curve);
        }
        return atlas.place(key, g.bitmap.width, g.bitmap.rows, g.bitmap.pitch, g.bitmap.buffer,
            g.bitmap_left, g.bitmap_top, curve);
    }

    /// Rasterizes the glyph of `key` in color font `f` at whole pixels, bitmap strikes scaled to `f.px`. Glyphs
    /// without color take the text color. Null when the atlas is full.
    private GlyphSlot* rasterizeColor(SizedFont f, GlyphKey key)
    {
        if (FT_Load_Glyph(f.face, key.glyph, FT_LOAD_COLOR) != 0
            || FT_Render_Glyph(f.face.glyph, FT_RENDER_MODE_NORMAL) != 0)
        {
            return atlas.place(key, 0, 0, 0, null, 0, 0, curve);
        }
        FT_GlyphSlot g = f.face.glyph;
        ++rasterized;
        if (g.bitmap.pixel_mode == FT_PIXEL_MODE_GRAY && f.strikeScale == 1)
        {
            return atlas.place(key, g.bitmap.width, g.bitmap.rows, g.bitmap.pitch, g.bitmap.buffer,
                g.bitmap_left, g.bitmap_top, curve);
        }
        if (g.bitmap.pixel_mode != FT_PIXEL_MODE_BGRA || g.bitmap.width == 0 || g.bitmap.rows == 0)
        {
            return atlas.place(key, 0, 0, 0, null, 0, 0, curve);
        }
        int w;
        int h;
        ubyte[] rgba = scaledRGBA(g.bitmap, f.strikeScale, w, h);
        return atlas.placeColor(key, w, h, rgba, cast(int) round(g.bitmap_left * f.strikeScale),
            cast(int) round(g.bitmap_top * f.strikeScale));
    }

    /// Ends a frame once every renderer drew: resets the changed atlas rows, clears a full atlas and drops runs
    /// unused for `keep` frames.
    void endFrame(ulong keep = 600)
    {
        ++frame;
        atlas.endFrame();
        if (atlas.full)
        {
            atlas.clear();
        }
        if (frame % 128 != 0)
        {
            return;
        }
        RunKey[] old;
        foreach (ref const RunKey k, ref CachedRun c; runs)
        {
            if (frame - c.used > keep)
            {
                old ~= k;
            }
        }
        foreach (RunKey k; old)
        {
            runs.remove(k);
        }
    }

    /// Number of cached runs.
    size_t cachedRuns() const
    {
        return runs.length;
    }
}

/// Index of the smallest strike of `face` at least `px64` (26.6) tall, else the tallest.
private int nearestStrike(FT_Face face, uint px64)
{
    int best = -1;
    int tallest;
    foreach (int i; 0 .. face.num_fixed_sizes)
    {
        FT_Pos ppem = face.available_sizes[i].y_ppem;
        if (ppem >= px64 && (best < 0 || ppem < face.available_sizes[best].y_ppem))
        {
            best = i;
        }
        if (ppem > face.available_sizes[tallest].y_ppem)
        {
            tallest = i;
        }
    }
    return best < 0 ? tallest : best;
}

/// Premultiplied RGBA of BGRA bitmap `b` scaled by `s` with a box filter, `w` by `h` pixels.
private ubyte[] scaledRGBA(const ref FT_Bitmap b, float s, out int w, out int h)
{
    int sw = b.width;
    int sh = b.rows;
    w = max(1, cast(int) round(sw * s));
    h = max(1, cast(int) round(sh * s));
    ubyte[] o = new ubyte[w * h * 4];
    float fx = cast(float) sw / w;
    float fy = cast(float) sh / h;
    foreach (int y; 0 .. h)
    {
        float y0 = y * fy;
        float y1 = y0 + fy;
        foreach (int x; 0 .. w)
        {
            float x0 = x * fx;
            float x1 = x0 + fx;
            float[4] sum = 0;
            for (int sy = cast(int) y0; sy < y1 && sy < sh; ++sy)
            {
                float wy = min(y1, sy + 1) - max(y0, sy);
                const(ubyte)* row = b.buffer + sy * b.pitch;
                for (int sx = cast(int) x0; sx < x1 && sx < sw; ++sx)
                {
                    float wt = wy * (min(x1, sx + 1) - max(x0, sx));
                    const(ubyte)* p = row + sx * 4;
                    sum[0] += p[2] * wt;
                    sum[1] += p[1] * wt;
                    sum[2] += p[0] * wt;
                    sum[3] += p[3] * wt;
                }
            }
            foreach (size_t k; 0 .. 4)
            {
                o[(y * w + x) * 4 + k] = cast(ubyte) min(255f, round(sum[k] / (fx * fy)));
            }
        }
    }
    return o;
}

/// True if `c` shows as an emoji without a variation selector: Unicode's Emoji_Presentation in the BMP, and
/// the pictograph and regional indicator blocks.
private bool isEmoji(dchar c)
{
    static immutable dchar[2][] bmp = [[0x231A, 0x231B], [0x23E9, 0x23EC], [0x23F0, 0x23F0], [0x23F3, 0x23F3],
        [0x25FD, 0x25FE], [0x2614, 0x2615], [0x2648, 0x2653], [0x267F, 0x267F], [0x2693, 0x2693],
        [0x26A1, 0x26A1], [0x26AA, 0x26AB], [0x26BD, 0x26BE], [0x26C4, 0x26C5], [0x26CE, 0x26CE],
        [0x26D4, 0x26D4], [0x26EA, 0x26EA], [0x26F2, 0x26F3], [0x26F5, 0x26F5], [0x26FA, 0x26FA],
        [0x26FD, 0x26FD], [0x2705, 0x2705], [0x270A, 0x270B], [0x2728, 0x2728], [0x274C, 0x274C],
        [0x274E, 0x274E], [0x2753, 0x2755], [0x2757, 0x2757], [0x2795, 0x2797], [0x27B0, 0x27B0],
        [0x27BF, 0x27BF], [0x2B1B, 0x2B1C], [0x2B50, 0x2B50], [0x2B55, 0x2B55]];
    if (c < 0x231A)
    {
        return false;
    }
    if (c >= 0x1F000)
    {
        return c == 0x1F004 || c == 0x1F0CF || c == 0x1F18E || (c >= 0x1F191 && c <= 0x1F19A)
            || (c >= 0x1F1E6 && c <= 0x1F1FF) || (c >= 0x1F300 && c <= 0x1FAFF);
    }
    foreach (ref const dchar[2] r; bmp)
    {
        if (c >= r[0] && c <= r[1])
        {
            return true;
        }
    }
    return false;
}

/// Well-known system fonts that exist here, in order: wide coverage first, then CJK, then symbols and emoji.
string[] systemFallbackFonts()
{
    import std.file : exists;
    import std.process : environment;

    string[] candidates;
    version (Windows)
    {
        string dir = environment.get("WINDIR", `C:\Windows`) ~ `\Fonts\`;
        foreach (string f; ["segoeui.ttf", "arial.ttf", "msyh.ttc", "YuGothR.ttc", "malgun.ttf", "Nirmala.ttf",
            "seguisym.ttf", "seguiemj.ttf"])
        {
            candidates ~= dir ~ f;
        }
    }
    else version (OSX)
    {
        candidates = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/AppleSDGothicNeo.ttc",
            "/System/Library/Fonts/Apple Symbols.ttf"];
    }
    else
    {
        foreach (string f; ["noto/NotoSans-Regular.ttf", "dejavu/DejaVuSans.ttf", "TTF/DejaVuSans.ttf",
            "dejavu-sans-fonts/DejaVuSans.ttf", "noto-cjk/NotoSansCJK-Regular.ttc",
            "google-noto-cjk/NotoSansCJK-Regular.ttc", "noto/NotoSansCJK-Regular.ttc",
            "droid/DroidSansFallbackFull.ttf", "wqy/wqy-microhei.ttc", "noto/NotoSansSymbols-Regular.ttf",
            "noto/NotoSansSymbols2-Regular.ttf", "noto/NotoColorEmoji.ttf"])
        {
            foreach (string dir; ["/usr/share/fonts/truetype/", "/usr/share/fonts/opentype/", "/usr/share/fonts/"])
            {
                candidates ~= dir ~ f;
            }
        }
    }
    string[] found;
    foreach (string p; candidates)
    {
        if (exists(p))
        {
            found ~= p;
        }
    }
    return found;
}

/// Glyph key bin and whole pixel pen for a glyph drawn at physical `x`.
ubyte subpixel(float x, out int penX)
{
    float whole = floor(x);
    int b = cast(int) round((x - whole) * subpixelBins);
    if (b == subpixelBins)
    {
        b = 0;
        whole += 1;
    }
    penX = cast(int) whole;
    return cast(ubyte) b;
}

version (unittest)
{
    /// Text system over the fonts in `fonts/`, for tests run from the repo root.
    TextSystem testText()
    {
        return new TextSystem(["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf",
            "fonts/JetBrainsMono-Regular.ttf"]);
    }

    /// Text system over `fonts/` with the emoji subset as its one fallback.
    TextSystem testEmojiText()
    {
        return new TextSystem(["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf",
            "fonts/JetBrainsMono-Regular.ttf"], ["fonts/NotoColorEmoji-Subset.ttf"]);
    }
}

// Shaping: mono advances are equal, proportional ones are not, and scale multiplies widths.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun mono = t.shape(FontKind.mono, 13, "0x0040_1000");
    assert(mono.glyphs.length == 11);
    float adv = mono.xs[1] - mono.xs[0];
    assert(adv > 7 && adv < 8.5, format("%s", adv));
    assert(mono.width == adv * 11);
    float ui = t.measure(FontKind.ui, 13, "illegal");
    float wide = t.measure(FontKind.ui, 13, "MMMMMMM");
    assert(wide > ui * 1.5);
    assert(t.shape(FontKind.mono, 13, "0x0040_1000") is mono, "cached");

    t.setScale(2);
    assert(t.cachedRuns == 0);
    ShapedRun big = t.shape(FontKind.mono, 13, "0x0040_1000");
    assert(big.width > mono.width * 1.99 && big.width < mono.width * 2.01);
    assert(t.measure(FontKind.mono, 13, "0x0040_1000") == big.width / 2, "logical width");
}

// Carets map byte offsets to pen x and back.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun r = t.shape(FontKind.mono, 13, "abcd");
    float adv = r.width / 4;
    assert(r.caretX(0) == 0);
    assert(r.caretX(2) == adv * 2);
    assert(r.caretX(4) == r.width);
    assert(r.indexAt(adv * 1.4) == 1);
    assert(r.indexAt(adv * 1.6) == 2);
    assert(r.indexAt(1000) == 4);
}

// Wrapping breaks after spaces, drops trailing spaces from widths, and lets long words overflow.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun r = t.shape(FontKind.mono, 13, "one two three");
    float adv = r.width / 13;
    Line[] lines = wrap(r, adv * 8);
    assert(lines.length == 2);
    assert(lines[0].first == 0 && lines[0].last == 7 && lines[0].width == adv * 7, "one two");
    assert(lines[1].first == 8 && lines[1].width == adv * 5, "three");
    assert(wrap(r, 1000).length == 1);
    Line[] tight = wrap(r, adv * 2);
    assert(tight.length == 3 && tight[2].width == adv * 5, "overflowing words stay whole");
}

// The atlas packs glyphs, rasterizes each key once and grows without moving glyphs.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    SizedFont f = t.font(FontKind.ui, 13);
    GlyphSlot* a = t.glyph(f, t.shape(FontKind.ui, 13, "A").glyphs[0], 0);
    assert(a.w > 4 && a.h > 6 && a.top > 6);
    GlyphSlot first = *a;
    int count = t.rasterized;
    t.glyph(f, t.shape(FontKind.ui, 13, "A").glyphs[0], 0);
    assert(t.rasterized == count, "cached");
    t.glyph(f, t.shape(FontKind.ui, 13, "A").glyphs[0], 2);
    assert(t.rasterized == count + 1, "another bin is another glyph");

    GlyphAtlas small = new GlyphAtlas(64, 64);
    ubyte[100] ink = 255;
    ubyte[256] identity;
    foreach (int i; 0 .. 256)
    {
        identity[i] = cast(ubyte) i;
    }
    GlyphSlot* s = small.place(GlyphKey(0, 1, 0), 10, 10, 10, ink.ptr, 0, 0, identity);
    GlyphSlot keep = *s;
    foreach (uint g; 2 .. 40)
    {
        small.place(GlyphKey(0, g, 0), 10, 10, 10, ink.ptr, 0, 0, identity);
    }
    assert(small.height > 64 && small.full == false);
    assert(*small.find(GlyphKey(0, 1, 0)) == keep);
    assert(small.pixels[(keep.y * small.width + keep.x) * 4] == 255);
    int top;
    int bottom;
    small.endFrame();
    small.place(GlyphKey(0, 50, 0), 10, 10, 10, ink.ptr, 0, 0, identity);
    small.dirtyRows(top, bottom);
    int again;
    small.dirtyRows(again, bottom);
    assert(top > 0 && again == top && bottom == top + 10, "rows stay for every renderer of the frame");
    ulong drewAt = small.frames;
    small.endFrame();
    small.dirtyRows(top, bottom);
    assert(top == bottom);
    small.changedRows(drewAt, top, bottom);
    assert(top == again && bottom == again + 10, "a renderer that skipped a frame still sees its rows");
    small.changedRows(drewAt + 1, top, bottom);
    assert(top == bottom);
    int pen;
    assert(subpixel(10.3, pen) == 1 && pen == 10);
    assert(subpixel(10.9, pen) == 0 && pen == 11);
    assert(first.x >= 5, "after the white block");
}

// A character the slot font lacks comes from the first fallback having it, with clusters and pens running on,
// and characters no font has keep the slot font's missing glyph.
unittest
{
    string[FontKind.max + 1] slots = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf",
        "fonts/JetBrainsMono-Regular.ttf"];
    TextSystem plain = testText();
    TextSystem t = new TextSystem(slots, ["fonts/missing.ttf", "fonts/Inter-Regular.otf"]);
    scope (exit)
    {
        plain.dispose();
        t.dispose();
    }
    string s = "aἀb";
    ShapedRun before = plain.shape(FontKind.mono, 14, s);
    assert(before.glyphs[1] == 0 && before.faces.length == 0, "JetBrains Mono has no U+1F00");
    ShapedRun r = t.shape(FontKind.mono, 14, s);
    assert(r.glyphs.length == 3 && r.glyphs[1] != 0 && r.clusters == [0, 1, 4]);
    assert(r.faces.length == 3 && r.faces[0] is r.font && r.faces[2] is r.font);
    assert(r.faces[1].file == FontKind.max + 2, "the second fallback, the first does not open");
    assert(r.pens[1] == before.pens[1] && r.pens[2] > r.pens[1] && r.width > r.pens[2]);
    assert(t.shape(FontKind.mono, 14, "ab").faces.length == 0, "one font, no faces");
    ShapedRun none = t.shape(FontKind.mono, 14, "中");
    assert(none.glyphs == [0] && none.faces.length == 0);
}

// Emoji come from the color fallback as one glyph per sequence, the bitmap strike scaled to the text size, in
// their own colors and at whole pixels.
unittest
{
    TextSystem t = testEmojiText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun r = t.shape(FontKind.ui, 14, "a😀⭐");
    assert(r.glyphs.length == 3 && r.faces.length == 3 && r.faces[0] is r.font);
    SizedFont e = r.faces[1];
    assert(e.color && r.faces[2] is e && e.strikeScale > 0.12 && e.strikeScale < 0.13, "109 px strike at 14 px");
    float adv = r.pens[2] - r.pens[1];
    assert(adv > 14 * 1.2 && adv < 14 * 1.3, format("%s", adv));
    GlyphSlot* s = t.glyph(e, r.glyphs[1], 3);
    assert(s.color && s.w >= 16 && s.w <= 19 && s.h >= 15 && s.h <= 18 && s.top > 10, format("%s", *s));
    assert(t.glyph(e, r.glyphs[1], 0) is s, "one subpixel bin");
    size_t at = (cast(size_t)(s.y + s.h / 4) * t.atlas.width + s.x + s.w / 2) * 4;
    const(ubyte)[] px = t.atlas.pixels[at .. at + 4];
    assert(px[3] == 255 && px[0] > 200 && px[1] > 150 && px[2] < 100, format("yellow forehead %s", px));
    assert(t.shape(FontKind.ui, 14, "👍🏽").glyphs.length == 1, "skin tone");
    assert(t.shape(FontKind.ui, 14, "🇯🇵").glyphs.length == 1, "flag");
}

// Features change the glyphs, key the cache, and skip color fonts.
unittest
{
    TextSystem t = testEmojiText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun plain = t.shape(FontKind.ui, 13, "1111");
    ShapedRun tnum = t.shape(FontKind.ui, 13, "1111", Features.tabular);
    assert(tnum !is plain && tnum.width > plain.width, "tabular ones are wider");
    assert(t.shape(FontKind.ui, 13, "1111", Features.tabular) is tnum, "cached apart");
    assert(t.shape(FontKind.ui, 13, "1/2", Features.fractions).glyphs != t.shape(FontKind.ui, 13, "1/2").glyphs);
    assert(t.shape(FontKind.ui, 13, "(x)", Features.caseForms).glyphs != t.shape(FontKind.ui, 13, "(x)").glyphs);
    assert(t.shape(FontKind.ui, 13, "0", Features.slashedZero | Features.tabular).glyphs
        != t.shape(FontKind.ui, 13, "0", Features.tabular).glyphs, "flags combine");
    ShapedRun arrow = t.shape(FontKind.mono, 13, "a->b");
    assert(t.shape(FontKind.mono, 13, "a->b", Features.noContextual).glyphs != arrow.glyphs, "code ligature off");
    assert(t.shape(FontKind.ui, 14, "👍🏽", Features.noLigatures | Features.noContextual).glyphs.length == 1,
        "emoji keep their sequences");
}

// Each flag turns into its tags, the `no` ones turn theirs off.
unittest
{
    hb_feature_t[maxFeatures] buf;
    hb_feature_t[] l = hbFeatures(Features.tabular | Features.noLigatures | Features.ss20, buf);
    assert(l.length == 4);
    assert(l[0].tag == hbTag("tnum") && l[0].value == 1);
    assert(l[1].tag == hbTag("liga") && l[1].value == 0 && l[2].tag == hbTag("clig") && l[2].value == 0);
    assert(l[3].tag == hbTag("ss20") && l[3].value == 1 && l[3].end == uint.max);
    assert(hbFeatures(Features.none, buf).length == 0);
}

// Fonts load from bytes, fallbacks too, and swapping a slot font redoes its runs at the new font's widths.
unittest
{
    import std.exception : assertThrown;
    import std.file : read;

    immutable(ubyte)[] inter = cast(immutable(ubyte)[]) read("fonts/Inter-Regular.otf");
    immutable(ubyte)[] mono = cast(immutable(ubyte)[]) read("fonts/JetBrainsMono-Regular.ttf");
    TextSystem t = new TextSystem([inter, inter, mono], [FontFile(data: inter)]);
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun greek = t.shape(FontKind.mono, 14, "aἀb");
    assert(greek.glyphs[1] != 0 && greek.faces.length == 3, "the fallback from bytes has U+1F00");
    float before = t.measure(FontKind.ui, 13, "illegal");
    t.setFont(FontKind.ui, mono);
    assert(t.cachedRuns == 0);
    assert(t.measure(FontKind.ui, 13, "illegal") > before * 1.2, "mono is wider");
    assertThrown(t.setFont(FontKind.ui, cast(immutable(ubyte)[]) "not a font"));
    assertThrown(t.setFont(FontKind.ui, null));
    assert(t.measure(FontKind.ui, 13, "illegal") > before * 1.2, "a bad font keeps the old one");
}
