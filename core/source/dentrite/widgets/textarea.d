/// Multi-line text editor bound to a string signal: word wrap or sideways scrolling, selection, clipboard,
/// undo, and an optional line number gutter.
///
/// The text is kept as lines. Each line is shaped once and cut into rows, one per line without wrapping, so
/// carets, selection and painting work on rows. Only the rows in view are painted. Input method text is shaped
/// into the caret's line for display only, so positions after the caret on that line are off while composing.
/// NOTE: tabs become spaces, and `\r` is dropped.
module dentrite.widgets.textarea;

import core.time : MonoTime, msecs;
import dentrite.containers : Fling, ScrollStyle;
import dentrite.node;
import dentrite.signals : Signal, effect;
import dentrite.text;
import dentrite.widgets.handles : HandleTarget, SelectionHandles;
import std.algorithm.comparison : clamp, max, min;
import std.array : join, split;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.math : abs, ceil, floor, isInfinity, isNaN, round;
import std.utf : stride, strideBack;

/// Look of a text area. The scroll bar is `ScrollStyle`.
struct TextAreaStyle
{
    enum section = "textarea"; /// section name in theme files

    /// Variants theme files can style as `[section.variant]`.
    enum Variants
    {
        code, /// fixed pitch, for source and logs
    }

    Color fill = Color(0x1e, 0x1e, 0x21, 0xff);        /// background
    Color fillFocus = Color(0x1a, 0x1a, 0x1d, 0xff);   /// background while focused
    Color fillDisabled = Color(0x24, 0x24, 0x27, 0xff); /// background when disabled
    Color border = Color(0x48, 0x48, 0x4e, 0xff);      /// outline
    Color borderFocus = Color(0x4c, 0x8d, 0xf6, 0xff); /// outline while focused
    Color text = Color(0xdd, 0xdd, 0xdd, 0xff);        /// text color
    Color textDisabled = Color(0x80, 0x80, 0x80, 0xff); /// text color when disabled
    Color placeholder = Color(0x78, 0x78, 0x80, 0xff); /// placeholder text color
    Color selection = Color(0x2f, 0x5c, 0xa8, 0xff);   /// selection highlight
    Color caret = Color(0xff, 0xff, 0xff, 0xff);       /// caret color
    Color gutter = Color(0x22, 0x22, 0x26, 0xff);      /// line number background
    Color gutterText = Color(0x6c, 0x6c, 0x74, 0xff);  /// line number color
    Color gutterCurrent = Color(0xbb, 0xbb, 0xbb, 0xff); /// color of the caret line number
    float radius = 4;     /// corner radius
    float padX = 6;       /// horizontal padding
    float padY = 4;       /// vertical padding
    float minWidth = 240; /// width when the parent leaves the width open
    float minLines = 3;   /// height in lines without a bounded parent and with little text
    float gutterPad = 8;  /// space either side of the line numbers
    FontKind font = FontKind.ui; /// text font
    float size = 13;      /// text size
    Features features;    /// OpenType features of the text, line numbers are tabular

    /// Look of `variant` without a theme.
    static void applyVariant(ref TextAreaStyle s, string variant)
    {
        if (variant == "code")
        {
            s.font = FontKind.mono;
            s.size = 12;
        }
    }
}

/// Place in the text: line and byte offset in it.
struct TextPos
{
    size_t line; /// line index
    size_t col;  /// byte offset in the line

    /// Compares by line, then by byte offset.
    int opCmp(const TextPos o) const
    {
        if (line != o.line)
        {
            return line < o.line ? -1 : 1;
        }
        return col < o.col ? -1 : col > o.col ? 1 : 0;
    }
}

/// Row of the view: glyphs of one line that fit the width.
private struct Row
{
    size_t line;  /// line index
    size_t first; /// first glyph in the line's run
    size_t last;  /// one past the last glyph
    size_t start; /// first caret byte offset on this row
    size_t end;   /// last caret byte offset on this row
    float x0 = 0; /// physical run x of the first glyph
}

/// What the lines for screen readers were made from, see `TextArea.accessLines`.
private struct LinesKey
{
    Rect text;       /// text rect in window coordinates
    float scrollX;   /// sideways scroll, rounded
    float scrollY;   /// vertical scroll, rounded
    size_t rows;     /// `TextArea.rowsMade` they belong to
}

/// Kinds of edits, so typing and deleting in a row undo as one step.
private enum EditKind
{
    other,    /// anything else, never merged
    typing,   /// inserting typed characters
    deleting, /// backspace or delete
}

/// Text and selection before an edit.
private struct Snapshot
{
    string[] lines; /// lines, never changed in place
    TextPos caret;  /// caret position
    TextPos anchor; /// selection end
}

/// Most undo steps kept.
private enum undoDepth = 500;

/// True if `e` is a key that types text, so shortcuts without Ctrl, Alt or Super do not fire while typing.
private bool typesText(ref const KeyEvent e)
{
    return e.key >= Key.space && e.key < 0x40000000 && (e.mods & (Mod.ctrl | Mod.alt | Mod.gui)) == 0;
}

/// `s` without `\r` and with tabs as spaces to the next multiple of 4 columns.
private string clean(string s)
{
    char[] o;
    size_t col;
    foreach (char c; s)
    {
        if (c == '\r')
        {
            continue;
        }
        if (c == '\t')
        {
            size_t n = 4 - col % 4;
            foreach (size_t k; 0 .. n)
            {
                o ~= ' ';
            }
            col += n;
            continue;
        }
        o ~= c;
        col = c == '\n' ? 0 : col + 1;
    }
    return o.idup;
}

/// Lines of `s`, at least one.
private string[] linesOf(string s)
{
    string[] ls = clean(s).split("\n");
    return ls.length == 0 ? [""] : ls;
}

/// Retained multi-line editor. Build it with `textArea`.
final class TextArea : Node, Composer, DragScroller, HandleTarget
{
    Signal!string value;  /// bound text
    string placeholder;   /// placeholder text shown while empty
    string variant;       /// TextAreaStyle variant
    bool wrap;            /// break long lines at spaces, else scroll sideways
    bool readOnly;        /// selectable and copyable, not editable
    int tabSpaces;        /// spaces Tab inserts, 0 to leave Tab for moving focus
    bool lineNumbers;     /// gutter with line numbers
    bool enabled = true;  /// takes focus and input
    TextPos caret;        /// caret position
    TextPos anchor;       /// other end of the selection, equal to `caret` for none

    private string[] lines = [""];  /// content, never changed in place
    private string joined;          /// content as last written or read
    private ShapedRun[] runs;       /// shaped line, null until shaped
    private Row[] rows;             /// rows of every line
    private size_t[] firstRow;      /// first row of each line
    private float widest = 0;       /// widest line, logical
    private float rowsWidth = -1;   /// wrap width the rows were made for, physical
    private bool rowsStale = true;  /// text changed since the rows were made
    private uint styleSeen;         /// tree style version the runs belong to
    private float pppSeen = 0;      /// scale the runs belong to
    private float scrollX = 0;      /// sideways scroll
    private float scrollY = 0;      /// vertical scroll
    private float goalX;            /// x that up and down aim for, NaN after other moves
    private bool reveal;            /// scroll the caret into view at the next paint
    private MonoTime blinkStart;    /// caret shown from here
    private bool dragging;          /// selecting with the pointer
    private bool thumbHeld;         /// dragging the scroll thumb
    private float grabY = 0;        /// pointer y minus thumb top at grab
    private bool sideThumbHeld;     /// dragging the sideways scroll thumb
    private float grabX = 0;        /// pointer x minus sideways thumb left at grab
    private Fling fling;            /// content drag and fling
    private Snapshot[] undos;       /// steps to undo, latest last
    private Snapshot[] redos;       /// undone steps, latest last
    private EditKind lastKind;      /// kind of the last edit
    private TextPos lastAt;         /// caret after the last edit
    private string composing;       /// input method text shown at the caret, not in the lines yet
    private size_t composeFrom;     /// start of the part being converted, bytes into `composing`
    private size_t composeTo;       /// end of that part, and the caret
    private size_t rowsMade;        /// times the rows were made
    private AccessLine[] lineCache; /// rows as lines for screen readers, see `accessLines`
    private LinesKey linesKey;      /// what `lineCache` was made from
    private SelectionHandles handles; /// touch selection handles, made on first use

    /// Creates an editor over `value`. The binding effect belongs to the current owner.
    this(Signal!string value, string placeholder, string variant)
    {
        this.value = value;
        this.placeholder = placeholder;
        this.variant = variant;
        interactive = true;
        focusable = true;
        textInput = true;
        longPress = true;
        cursor = CursorShape.text;
        effect(() {
            string v = value.get;
            if (v != joined)
            {
                joined = v;
                lines = linesOf(v);
                caret = clampPos(caret);
                anchor = clampPos(anchor);
                undos = null;
                redos = null;
                lastKind = EditKind.other;
                linesChanged();
            }
        });
    }

    /// Content as lines.
    const(string)[] text()
    {
        return lines;
    }

    /// Enables or disables. Disabling drops focus.
    void setEnabled(bool on)
    {
        if (on == enabled)
        {
            return;
        }
        enabled = on;
        focusable = on;
        cursor = on ? CursorShape.text : CursorShape.arrow;
        if (on == false && focused && tree !is null && tree.services !is null)
        {
            tree.services.setFocus(null);
        }
        markNeedsPaint();
    }

    /// Switches the style variant and shapes the text again.
    void setVariant(string v)
    {
        if (v == variant)
        {
            return;
        }
        variant = v;
        linesChanged();
    }

    /// Breaks long lines at spaces when `on`, else scrolls sideways.
    void setWrap(bool on)
    {
        if (on == wrap)
        {
            return;
        }
        wrap = on;
        scrollX = 0;
        markNeedsLayout();
    }

    /// Shows or hides the line number gutter.
    void setLineNumbers(bool on)
    {
        if (on == lineNumbers)
        {
            return;
        }
        lineNumbers = on;
        markNeedsLayout();
    }

    /// Stops or allows editing. Selection and copying work either way.
    void setReadOnly(bool on)
    {
        if (on == readOnly)
        {
            return;
        }
        readOnly = on;
        markNeedsPaint();
    }

    /// Selected text, empty without a selection.
    string selectedText()
    {
        return textBetween(min(caret, anchor), max(caret, anchor));
    }

    /// Selects from `from` to `to`, with the caret at `to`, and scrolls it into view.
    void select(TextPos from, TextPos to)
    {
        anchor = clampPos(from);
        caret = clampPos(to);
        goalX = float.nan;
        reveal = true;
        touch();
    }

    /// True if there is something to undo.
    bool canUndo()
    {
        return undos.length > 0;
    }

    /// Goes back one step.
    void undo()
    {
        if (undos.length > 0 && readOnly == false)
        {
            redos ~= Snapshot(lines, caret, anchor);
            restore(undos[$ - 1]);
            undos = undos[0 .. $ - 1];
        }
    }

    /// Redoes the last undone step.
    void redo()
    {
        if (redos.length > 0 && readOnly == false)
        {
            undos ~= Snapshot(lines, caret, anchor);
            restore(redos[$ - 1]);
            redos = redos[0 .. $ - 1];
        }
    }

    /// Puts back `s` and writes the signal.
    private void restore(Snapshot s)
    {
        lines = s.lines;
        caret = s.caret;
        anchor = s.anchor;
        lastKind = EditKind.other;
        written();
    }

    /// `p` moved inside the text.
    private TextPos clampPos(TextPos p)
    {
        size_t l = min(p.line, lines.length - 1);
        return TextPos(l, min(p.col, lines[l].length));
    }

    /// Text from `a` to `b`, lines joined with `\n`.
    private string textBetween(TextPos a, TextPos b)
    {
        if (a.line == b.line)
        {
            return lines[a.line][a.col .. b.col];
        }
        string[] parts = [lines[a.line][a.col .. $]];
        parts ~= lines[a.line + 1 .. b.line];
        parts ~= lines[b.line][0 .. b.col];
        return parts.join("\n");
    }

    /// Multi-line field with its text and hint. Name it with `accessName` or a label.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.multilineTextInput;
        a.value = joined;
        a.caret = offsetOf(caret);
        a.anchor = offsetOf(anchor);
        a.placeholder = placeholder;
        a.readOnly = readOnly;
        a.disabled = enabled == false;
        a.lines = accessLines();
        a.allow(AccessAction.setSelection);
        if (readOnly == false)
        {
            a.allow(AccessAction.setValue);
        }
    }

    /// Rows as lines for screen readers, kept until the rows, their place or the scroll change. None while
    /// composing, as that text is not in the value.
    private AccessLine[] accessLines()
    {
        if (tree is null || rowsStale || composing.length > 0 || rows.length == 0)
        {
            return null;
        }
        TextAreaStyle s = style();
        LinesKey k = LinesKey(textRect(bounds.pos, s), round(scrollX), round(scrollY), rowsMade);
        if (k == linesKey && lineCache !is null)
        {
            return lineCache;
        }
        float lh = lineHeight();
        float ppp = tree.text.ppp;
        AccessLine[] made;
        size_t lineStart;
        foreach (size_t r, ref const Row row; rows)
        {
            if (r > 0 && rows[r - 1].line != row.line)
            {
                lineStart += lines[rows[r - 1].line].length + 1;
            }
            float[] edges = runs[row.line].charEdges(row.start, row.end, row.x0, ppp);
            size_t to = lineStart + row.end;
            if ((r + 1 == rows.length || rows[r + 1].line != row.line) && row.line + 1 < lines.length)
            {
                edges ~= edges[$ - 1];
                ++to;
            }
            Rect box = Rect(k.text.x - k.scrollX, k.text.y + r * lh - k.scrollY, edges[$ - 1], lh);
            made ~= AccessLine(lineStart + row.start, to, box, edges);
        }
        linesKey = k;
        lineCache = made;
        return made;
    }

    /// Position of byte offset `b` in the joined text, the end when past it.
    private TextPos posOf(size_t b)
    {
        foreach (size_t i, string l; lines)
        {
            if (b <= l.length)
            {
                return TextPos(i, b);
            }
            b -= l.length + 1;
        }
        return TextPos(lines.length - 1, lines[$ - 1].length);
    }

    /// Byte offset of `p` in the joined text.
    private size_t offsetOf(TextPos p)
    {
        size_t n;
        foreach (string l; lines[0 .. min(p.line, lines.length)])
        {
            n += l.length + 1;
        }
        return n + p.col;
    }

    /// Replaces the text, or moves the caret and selection.
    override bool accessAction(ref const AccessRequest r)
    {
        if (r.action == AccessAction.setSelection && enabled && r.caret != size_t.max)
        {
            select(posOf(r.anchor == size_t.max ? r.caret : r.anchor), posOf(r.caret));
            return true;
        }
        if (r.action != AccessAction.setValue || readOnly || enabled == false || r.text is null)
        {
            return false;
        }
        value.set(r.text);
        return true;
    }

    /// Marks the shaped lines and rows stale after the lines changed.
    private void linesChanged()
    {
        runs = new ShapedRun[lines.length];
        rowsStale = true;
        markNeedsLayout();
        markNeedsPaint();
    }

    /// Writes the joined lines to the signal after an edit.
    private void written()
    {
        linesChanged();
        joined = lines.join("\n");
        value.set(joined);
        goalX = float.nan;
        reveal = true;
        touch();
    }

    /// Keeps the text before an edit of `kind` for undo, merged into the previous step while typing or deleting
    /// goes on where the last edit left the caret.
    private void remember(EditKind kind)
    {
        bool merge = kind != EditKind.other && kind == lastKind && caret == anchor && caret == lastAt
            && undos.length > 0;
        if (merge == false)
        {
            undos ~= Snapshot(lines, caret, anchor);
            if (undos.length > undoDepth)
            {
                undos = undos[$ - undoDepth .. $];
            }
        }
        redos = null;
        lastKind = kind;
    }

    /// Replaces the text from `a` to `b` with `s`, puts the caret after it, and writes the signal.
    private void replaceRange(TextPos a, TextPos b, string s, EditKind kind)
    {
        if (readOnly || enabled == false)
        {
            return;
        }
        if (a == b && s.length == 0)
        {
            return;
        }
        remember(kind);
        string post = lines[b.line][b.col .. $];
        string[] mid = (lines[a.line][0 .. a.col] ~ s ~ post).split("\n");
        if (mid.length == 0)
        {
            mid = [""];
        }
        lines = lines[0 .. a.line] ~ mid ~ lines[b.line + 1 .. $];
        size_t l = a.line + mid.length - 1;
        caret = anchor = TextPos(l, lines[l].length - post.length);
        lastAt = caret;
        written();
    }

    /// Replaces the selection with `s`.
    private void replaceSelection(string s, EditKind kind)
    {
        replaceRange(min(caret, anchor), max(caret, anchor), s, kind);
    }

    /// Style for the variant.
    private TextAreaStyle style()
    {
        return tree.style!TextAreaStyle(variant);
    }

    /// Gutter width, 0 without line numbers.
    private float gutterWidth(const ref TextAreaStyle s)
    {
        if (lineNumbers == false)
        {
            return 0;
        }
        size_t digits = max(2, lines.length.to!string.length);
        char[] zeros = new char[digits];
        zeros[] = '0';
        return round(tree.text.measure(s.font, s.size, zeros.idup, Features.tabular) + s.gutterPad * 2);
    }

    /// Text area inside the gutter and padding, for a box at `origin`.
    private Rect textRect(Point origin, const ref TextAreaStyle s)
    {
        float g = gutterWidth(s);
        return Rect(origin.x + g + s.padX, origin.y + s.padY, max(0f, size.w - g - s.padX * 2),
            max(0f, size.h - s.padY * 2));
    }

    /// Shapes stale lines and cuts them into rows for text `w` logical pixels wide.
    private void makeRows(float w)
    {
        TextSystem t = tree.text;
        TextAreaStyle s = style();
        if (styleSeen != tree.styleVersion || pppSeen != t.ppp)
        {
            styleSeen = tree.styleVersion;
            pppSeen = t.ppp;
            runs = new ShapedRun[lines.length];
            rowsStale = true;
        }
        float wrapW = wrap ? max(1f, w * t.ppp) : float.infinity;
        if (rowsStale == false && wrapW == rowsWidth)
        {
            return;
        }
        rowsStale = false;
        rowsWidth = wrapW;
        ++rowsMade;
        rows.length = 0;
        rows.assumeSafeAppend();
        firstRow.length = lines.length;
        float wide = 0;
        foreach (size_t i; 0 .. lines.length)
        {
            string line = shownLine(i);
            if (runs[i] is null)
            {
                runs[i] = t.shape(s.font, s.size, line, s.features);
            }
            ShapedRun r = runs[i];
            wide = max(wide, r.width);
            firstRow[i] = rows.length;
            if (wrap == false)
            {
                rows ~= Row(i, 0, r.glyphs.length, 0, line.length, 0);
                continue;
            }
            Line[] ls = .wrap(r, wrapW);
            foreach (size_t k, ref Line l; ls)
            {
                size_t start = k == 0 ? 0 : r.clusters[l.first];
                size_t end = k + 1 < ls.length ? r.clusters[l.last] : line.length;
                rows ~= Row(i, l.first, l.last, start, end, l.x0);
            }
        }
        widest = wide / t.ppp;
    }

    /// Line `i` as shown, with the input method text at the caret.
    private string shownLine(size_t i)
    {
        if (composing.length == 0 || i != caret.line)
        {
            return lines[i];
        }
        return lines[i][0 .. caret.col] ~ composing ~ lines[i][caret.col .. $];
    }

    /// Caret as shown, inside the input method text while composing.
    private TextPos shownCaret()
    {
        return TextPos(caret.line, caret.col + composeTo);
    }

    /// Bounded width or the minimum. Bounded height, or tall enough for the rows and at least the minimum lines.
    protected override Size performLayout(Constraints c)
    {
        TextAreaStyle s = style();
        float w = isInfinity(c.maxW) ? max(c.minW, s.minWidth) : c.maxW;
        size.w = w;
        makeRows(max(0f, w - gutterWidth(s) - s.padX * 2));
        float lh = tree.text.lineHeight(s.font, s.size);
        float h = isInfinity(c.maxH) ? max(rows.length, s.minLines) * lh + s.padY * 2 : c.maxH;
        return c.constrain(Size(w, h));
    }

    /// Row holding `p`. A position at a wrap belongs to the row it ends.
    private size_t rowOf(TextPos p)
    {
        size_t r = firstRow[p.line];
        while (r + 1 < rows.length && rows[r + 1].line == p.line && p.col > rows[r].end)
        {
            ++r;
        }
        return r;
    }

    /// Logical x of `p` on row `r`, from the row start.
    private float xOf(TextPos p, size_t r)
    {
        return (runs[p.line].caretX(p.col) - rows[r].x0) / tree.text.ppp;
    }

    /// Position on row `r` nearest to logical x `x` from the row start.
    private TextPos posAt(size_t r, float x)
    {
        Row row = rows[r];
        ShapedRun run = runs[row.line];
        float px = x * tree.text.ppp + row.x0;
        foreach (size_t i; row.first .. row.last)
        {
            float st = run.pens[i];
            float en = i + 1 < run.glyphs.length ? run.pens[i + 1] : run.width;
            if (px < (st + en) / 2)
            {
                return TextPos(row.line, clamp(cast(size_t) run.clusters[i], row.start, row.end));
            }
        }
        return TextPos(row.line, row.end);
    }

    /// Line height for the style.
    private float lineHeight()
    {
        TextAreaStyle s = style();
        return tree.text.lineHeight(s.font, s.size);
    }

    /// Position under window point `p`.
    private TextPos posUnder(Point p)
    {
        TextAreaStyle s = style();
        Rect tr = textRect(bounds.pos, s);
        float lh = lineHeight();
        ptrdiff_t r = cast(ptrdiff_t) floor((p.y - tr.y + round(scrollY)) / lh);
        return posAt(clamp(r, 0, cast(ptrdiff_t) rows.length - 1), p.x - tr.x + round(scrollX));
    }

    /// Largest vertical scroll for a text area `viewH` tall. With a sideways bar the last row can scroll above
    /// it.
    private float maxScrollY(float viewH)
    {
        float content = rows.length * lineHeight();
        if (content > viewH && scrollsSideways)
        {
            content += tree.style!ScrollStyle().width + 2;
        }
        return max(0f, content - viewH);
    }

    /// Width of the text inside the gutter and padding.
    private float textWidth()
    {
        TextAreaStyle s = style();
        return max(0f, size.w - gutterWidth(s) - s.padX * 2);
    }

    /// Largest sideways scroll, 0 when wrapping or when every line fits.
    private float maxScrollX()
    {
        return wrap ? 0 : max(0f, widest - textWidth + 1);
    }

    /// True if some line is wider than the text.
    private bool scrollsSideways()
    {
        return maxScrollX > 0;
    }

    /// Length of the vertical thumb's track, shorter when the sideways bar shows.
    private float track(const ref ScrollStyle ss)
    {
        return size.h - 4 - (scrollsSideways ? ss.width + 2 : 0);
    }

    /// Scroll thumb in window coordinates for a box at `origin`, empty when everything fits.
    private Rect thumb(Point origin, const ref ScrollStyle ss, const ref TextAreaStyle s)
    {
        float viewH = size.h - s.padY * 2;
        float contentH = rows.length * lineHeight();
        if (contentH <= viewH || viewH <= 0)
        {
            return Rect.init;
        }
        float tl = track(ss);
        float h = max(ss.minThumb, tl * viewH / contentH);
        float y = (tl - h) * scrollY / maxScrollY(viewH);
        return Rect(origin.x + size.w - ss.width - 2, origin.y + 2 + y, ss.width, h);
    }

    /// Left end and length of the sideways thumb's track for a box at `origin`, right of the gutter and short of
    /// the vertical bar.
    private float[2] sideTrack(Point origin, const ref ScrollStyle ss, const ref TextAreaStyle s)
    {
        bool vertical = rows.length * lineHeight() > size.h - s.padY * 2;
        float x0 = origin.x + gutterWidth(s) + 2;
        return [x0, max(0f, origin.x + size.w - 2 - (vertical ? ss.width + 2 : 0) - x0)];
    }

    /// Sideways scroll thumb in window coordinates for a box at `origin`, empty when every line fits.
    private Rect sideThumb(Point origin, const ref ScrollStyle ss, const ref TextAreaStyle s)
    {
        float most = maxScrollX;
        if (most <= 0)
        {
            return Rect.init;
        }
        float[2] t = sideTrack(origin, ss, s);
        float w = min(t[1], max(ss.minThumb, t[1] * textWidth / (widest + 1)));
        return Rect(t[0] + (t[1] - w) * scrollX / most, origin.y + size.h - ss.width - 2, w, ss.width);
    }

    /// Box, gutter, selection, rows in view, caret and scroll thumb.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TextAreaStyle s = ctx.style!TextAreaStyle(variant);
        TextSystem t = ctx.text;
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        ctx.list.rect(r, enabled == false ? s.fillDisabled : focused ? s.fillFocus : s.fill, s.radius,
            focused ? s.borderFocus : s.border, 1);
        float g = gutterWidth(s);
        if (g > 0)
        {
            ctx.list.rect(Rect(r.x + 1, r.y + 1, g - 1, r.h - 2), s.gutter);
        }
        Rect tr = textRect(origin, s);
        float lh = t.lineHeight(s.font, s.size);
        float asc = t.ascent(s.font, s.size);
        if (reveal && rows.length > 0)
        {
            reveal = false;
            TextPos sc = shownCaret();
            size_t cr = rowOf(sc);
            float bar = scrollsSideways ? ctx.style!ScrollStyle().width + 2 : 0;
            scrollY = clamp(scrollY, cr * lh + lh - (tr.h - bar), cr * lh);
            if (wrap == false)
            {
                float cx = xOf(sc, cr);
                if (cx < scrollX)
                {
                    scrollX = max(0f, cx - tr.w / 4);
                }
                else if (cx > scrollX + tr.w - 1)
                {
                    scrollX = cx - tr.w + 1;
                }
            }
        }
        scrollY = clamp(scrollY, 0, maxScrollY(tr.h));
        scrollX = clamp(scrollX, 0, maxScrollX);
        float sy = round(scrollY);
        float x0 = tr.x - round(scrollX);
        size_t firstVis = min(rows.length, cast(size_t) floor(sy / lh));
        size_t lastVis = min(rows.length, cast(size_t) ceil((sy + tr.h) / lh) + 1);
        TextPos a = min(caret, anchor);
        TextPos b = max(caret, anchor);
        TextPos sc = shownCaret();
        size_t caretRow = rows.length > 0 ? rowOf(sc) : 0;
        TextPos ca = TextPos(caret.line, caret.col + composeFrom);
        TextPos end = TextPos(caret.line, caret.col + composing.length);
        Rect clip = Rect(tr.x, r.y + 1, tr.w, r.h - 2);
        ctx.clipped(clip, {
            if (lines.length == 1 && lines[0].length == 0 && placeholder.length > 0)
            {
                ctx.list.text(t.shape(s.font, s.size, placeholder, s.features), Point(tr.x, tr.y + asc), s.placeholder);
            }
            foreach (size_t k; firstVis .. lastVis)
            {
                Row row = rows[k];
                float y = tr.y + k * lh - sy;
                if (focused && a != b)
                {
                    paintSelection(ctx, k, a, b, Rect(x0, y, 0, lh), lh, s);
                }
                ctx.list.text(runs[row.line], Point(x0, y + asc), enabled ? s.text : s.textDisabled, row.first,
                    row.last);
                if (composing.length > 0 && row.line == caret.line)
                {
                    underline(ctx, k, caret, end, x0, y + lh - 1, 1, s.text);
                    underline(ctx, k, ca, sc, x0, y + lh - 2, 2, s.text);
                }
            }
            if (focused && tree.services !is null && rows.length > 0)
            {
                MonoTime now = tree.services.now;
                long ms = (now - blinkStart).total!"msecs";
                if (ms % 1000 < 530)
                {
                    ctx.list.rect(Rect(x0 + round(xOf(sc, caretRow)), tr.y + caretRow * lh - sy, 1, lh), s.caret);
                }
                markNeedsPaintAt(now + msecs(530 - ms % 530));
            }
        });
        if (g > 0)
        {
            ctx.clipped(Rect(r.x, r.y + 1, g, r.h - 2), {
                foreach (size_t k; firstVis .. lastVis)
                {
                    if (firstRow[rows[k].line] != k)
                    {
                        continue;
                    }
                    ShapedRun n = t.shape(s.font, s.size, (rows[k].line + 1).to!string, Features.tabular);
                    float y = tr.y + k * lh - sy + asc;
                    ctx.list.text(n, Point(r.x + g - s.gutterPad - n.width / t.ppp, y),
                        rows[k].line == caret.line && focused ? s.gutterCurrent : s.gutterText);
                }
            });
        }
        ScrollStyle ss = ctx.style!ScrollStyle();
        Rect th = thumb(origin, ss, s);
        if (th.empty == false)
        {
            ctx.list.rect(th, thumbHeld || hovered ? ss.thumbHover : ss.thumb, ss.width / 2);
        }
        Rect sth = sideThumb(origin, ss, s);
        if (sth.empty == false)
        {
            ctx.list.rect(sth, sideThumbHeld || hovered ? ss.thumbHover : ss.thumb, ss.width / 2);
        }
        if (handles !is null && handles.shown)
        {
            Rect view = textRect(bounds.pos, s);
            Rect ab = boxOf(anchor);
            Rect cb = boxOf(caret);
            handles.place(ab, focused && seen(ab, view), cb, focused && seen(cb, view));
        }
    }

    /// True if caret box `r` is inside `view`, give or take a pixel.
    private static bool seen(Rect r, Rect view)
    {
        return r.x >= view.x - 1 && r.x <= view.right + 1 && r.y >= view.y - 1 && r.bottom <= view.bottom + 1;
    }

    /// Caret box of `p` in window coordinates, as last laid out and scrolled.
    private Rect boxOf(TextPos p)
    {
        TextAreaStyle s = style();
        Rect tr = textRect(bounds.pos, s);
        size_t r = rowOf(p);
        float lh = lineHeight();
        return Rect(tr.x - round(scrollX) + round(xOf(p, r)), tr.y + r * lh - round(scrollY), 1, lh);
    }

    /// Selects the word under `p` with handles to change it. A context menu around it still opens.
    override bool onLongPress(Point p)
    {
        if (enabled == false || tree is null || rows.length == 0 || composing.length > 0)
        {
            return false;
        }
        if (tree.services !is null)
        {
            tree.services.setFocus(this);
        }
        TextPos at = posUnder(p);
        size_t[2] w = wordAt(lines[at.line], at.col);
        select(TextPos(at.line, w[0]), TextPos(at.line, w[1]));
        dragging = false;
        showHandles();
        return false;
    }

    /// Moves an end of the selection to the text under `p`, from a handle.
    void dragHandle(bool caretEnd, Point p)
    {
        if (rows.length == 0)
        {
            return;
        }
        TextPos at = posUnder(p);
        if (caretEnd)
        {
            caret = at;
        }
        else
        {
            anchor = at;
        }
        goalX = float.nan;
        touch();
    }

    /// True while touch selection handles show.
    bool handlesShown()
    {
        return handles !is null && handles.shown;
    }

    /// Shows the touch selection handles.
    private void showHandles()
    {
        if (handles is null)
        {
            handles = new SelectionHandles(this, this);
        }
        handles.show();
    }

    /// Hides the touch selection handles.
    private void hideHandles()
    {
        if (handles !is null)
        {
            handles.hide();
        }
    }

    /// Drops the handles with the editor.
    override void onDetach()
    {
        hideHandles();
    }

    /// Selection highlight from `a` to `b` on row `k`, at `at` with the row's left edge. A row whose line break
    /// is selected gets a little extra width.
    private void paintSelection(ref PaintContext ctx, size_t k, TextPos a, TextPos b, Rect at, float lh,
        const ref TextAreaStyle s)
    {
        Row row = rows[k];
        TextPos rs = TextPos(row.line, row.start);
        TextPos re = TextPos(row.line, row.end);
        if (b < rs || a > re)
        {
            return;
        }
        TextPos sa = max(a, rs);
        TextPos sb = min(b, re);
        bool lastOfLine = k + 1 >= rows.length || rows[k + 1].line != row.line;
        float extra = b > re && lastOfLine ? round(lh * 0.35f) : 0;
        float xa = xOf(sa, k);
        float xb = xOf(sb, k);
        if (xb - xa + extra > 0)
        {
            ctx.list.rect(Rect(at.x + round(xa), at.y, round(xb - xa) + extra, lh), s.selection);
        }
    }

    /// Line under `a .. b` on row `k`, `thick` pixels from `y` down, for a row starting at `x0`. None when the
    /// part on the row is empty.
    private void underline(ref PaintContext ctx, size_t k, TextPos a, TextPos b, float x0, float y, float thick,
        Color c)
    {
        Row row = rows[k];
        TextPos sa = max(a, TextPos(row.line, row.start));
        TextPos sb = min(b, TextPos(row.line, row.end));
        if (sb > sa)
        {
            float xa = round(xOf(sa, k));
            ctx.list.rect(Rect(x0 + xa, y, round(xOf(sb, k)) - xa, thick), c);
        }
    }

    /// Shows input method text at the caret until committed or cleared. A selection is deleted when it starts.
    void compose(string s, size_t from, size_t to)
    {
        if (readOnly || enabled == false || (s.length == 0 && composing.length == 0))
        {
            return;
        }
        char[] c = s.dup;
        foreach (ref char ch; c)
        {
            if (ch == '\n' || ch == '\r' || ch == '\t')
            {
                ch = ' ';
            }
        }
        if (c.length > 0 && composing.length == 0 && caret != anchor)
        {
            replaceSelection("", EditKind.other);
        }
        composing = c.length == 0 ? null : c.idup;
        composeFrom = min(from, composing.length);
        composeTo = min(to, composing.length);
        if (caret.line < runs.length)
        {
            runs[caret.line] = null;
        }
        rowsStale = true;
        reveal = true;
        markNeedsLayout();
        touch();
    }

    /// Caret in window coordinates as last laid out and scrolled.
    Rect caretRect()
    {
        if (rows.length == 0)
        {
            return bounds;
        }
        TextAreaStyle s = style();
        Rect tr = textRect(bounds.pos, s);
        TextPos p = shownCaret();
        size_t r = rowOf(p);
        float lh = lineHeight();
        return Rect(tr.x - round(scrollX) + round(xOf(p, r)), tr.y + r * lh - round(scrollY), 1, lh);
    }

    /// Restarts the blink so the caret shows right after a change.
    private void touch()
    {
        if (tree !is null && tree.services !is null)
        {
            blinkStart = tree.services.now;
        }
        markNeedsPaint();
    }

    /// Caret placement, word or line selection on double and triple clicks, drag selection, the scroll thumbs,
    /// content drags.
    override bool onPointer(ref const PointerEvent e)
    {
        if (enabled == false || rows.length == 0)
        {
            return false;
        }
        if (fling.held)
        {
            switch (e.kind)
            {
            case PointerKind.move:
                panBy(fling.drag(e.pos, e.time));
                return true;
            case PointerKind.up:
                ScrollStyle fs = tree.style!ScrollStyle();
                if (fling.release(e.pos, e.time, fs.flingMin))
                {
                    fling.next(this, &coast);
                }
                return true;
            case PointerKind.cancel:
                fling.held = false;
                return true;
            default:
                break;
            }
        }
        TextAreaStyle s = style();
        ScrollStyle ss = tree.style!ScrollStyle();
        switch (e.kind)
        {
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            if (composing.length > 0)
            {
                return true; // positions on the caret line are off until the input method commits
            }
            Rect sth = sideThumb(bounds.pos, ss, s);
            float[2] st = sideTrack(bounds.pos, ss, s);
            if (sth.empty == false && e.pos.y >= bounds.bottom - ss.width - 4 && e.pos.x >= st[0]
                && e.pos.x < st[0] + st[1])
            {
                if (sth.contains(e.pos))
                {
                    sideThumbHeld = true;
                    grabX = e.pos.x - sth.x;
                }
                else
                {
                    scrollX += e.pos.x < sth.x ? -textWidth : textWidth;
                }
                markNeedsPaint();
                return true;
            }
            Rect th = thumb(bounds.pos, ss, s);
            if (th.empty == false && e.pos.x >= bounds.right - ss.width - 4)
            {
                if (th.contains(e.pos))
                {
                    thumbHeld = true;
                    grabY = e.pos.y - th.y;
                }
                else
                {
                    float page = size.h - s.padY * 2;
                    scrollY += e.pos.y < th.y ? -page : page;
                }
                markNeedsPaint();
                return true;
            }
            caret = posUnder(e.pos);
            if ((e.mods & Mod.shift) == 0)
            {
                anchor = caret;
            }
            if (e.clicks == 2)
            {
                size_t[2] w = wordAt(lines[caret.line], caret.col);
                anchor = TextPos(caret.line, w[0]);
                caret = TextPos(caret.line, w[1]);
            }
            else if (e.clicks >= 3)
            {
                anchor = TextPos(caret.line, 0);
                caret = caret.line + 1 < lines.length ? TextPos(caret.line + 1, 0)
                    : TextPos(caret.line, lines[caret.line].length);
            }
            dragging = e.clicks < 2;
            goalX = float.nan;
            reveal = true;
            if (e.source != PointerSource.mouse && e.clicks == 2)
            {
                showHandles();
            }
            else
            {
                hideHandles();
            }
            touch();
            return true;
        case PointerKind.move:
            if (thumbHeld == false && sideThumbHeld == false && dragging == false)
            {
                cursor = overBar(e.pos, ss, s) ? CursorShape.arrow : CursorShape.text;
            }
            if (thumbHeld)
            {
                Rect th = thumb(bounds.pos, ss, s);
                float room = track(ss) - th.h;
                float viewH = size.h - s.padY * 2;
                scrollY = room > 0 ? (e.pos.y - grabY - bounds.y - 2) / room * maxScrollY(viewH) : 0;
                markNeedsPaint();
                return true;
            }
            if (sideThumbHeld)
            {
                Rect sth = sideThumb(bounds.pos, ss, s);
                float[2] st = sideTrack(bounds.pos, ss, s);
                float room = st[1] - sth.w;
                scrollX = room > 0 ? clamp((e.pos.x - grabX - st[0]) / room * maxScrollX, 0, maxScrollX) : 0;
                markNeedsPaint();
                return true;
            }
            if (dragging)
            {
                caret = posUnder(e.pos);
                reveal = true;
                touch();
            }
            return dragging;
        case PointerKind.cancel:
        case PointerKind.up:
            dragging = false;
            thumbHeld = false;
            sideThumbHeld = false;
            markNeedsPaint();
            return true;
        case PointerKind.enter:
            cursor = overBar(e.pos, ss, s) ? CursorShape.arrow : CursorShape.text;
            markNeedsPaint();
            return true;
        case PointerKind.leave:
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// True if `source` drags it per the window, away from the bars, while the text does not fit.
    bool scrollsDrag(PointerSource source, Point at, out bool onBar)
    {
        TextAreaStyle s = style();
        ScrollStyle ss = tree.style!ScrollStyle();
        bool overflows = maxScrollY(size.h - s.padY * 2) > 0 || maxScrollX > 0;
        onBar = enabled && overBar(at, ss, s);
        return enabled && overflows && tree.scrollDrag.scrollsWith(source) && onBar == false;
    }

    /// Takes a drag along the axis it mostly moved on, if the text scrolls that way, with room left unless `edge`
    /// is set. The drag then scrolls both ways.
    bool takeDrag(Point at, Point moved, bool edge, MonoTime time)
    {
        bool across = abs(moved.x) > abs(moved.y);
        float most = across ? maxScrollX : maxScrollY(size.h - style().padY * 2);
        float now = across ? scrollX : scrollY;
        float toward = across ? moved.x : moved.y;
        if (most <= 0 || (edge == false && (toward > 0 ? now <= 0 : now >= most)))
        {
            return false;
        }
        dragging = false;
        fling.grab(at, time);
        return true;
    }

    /// Stops a fling and holds the text at `at`.
    bool catchFling(Point at, MonoTime time)
    {
        return fling.catchAt(at, time);
    }

    /// Scrolls by `d`, clamped. False if that went past an end.
    private bool panBy(Point d)
    {
        Point want = Point(scrollX + d.x, scrollY + d.y);
        scrollX = clamp(want.x, 0, maxScrollX);
        scrollY = clamp(want.y, 0, maxScrollY(size.h - style().padY * 2));
        markNeedsPaint();
        return scrollX == want.x && scrollY == want.y;
    }

    /// Moves the fling on to the frame time, until it stops or reaches an end.
    private void coast()
    {
        if (fling.coasting == false)
        {
            return;
        }
        ScrollStyle ss = tree.style!ScrollStyle();
        if (panBy(fling.coast(tree.services.now, ss.flingDecay, ss.flingMin)) == false)
        {
            fling.stop();
        }
        fling.next(this, &coast);
    }

    /// True if window point `p` is over a scroll bar's strip, where presses scroll.
    private bool overBar(Point p, const ref ScrollStyle ss, const ref TextAreaStyle s)
    {
        Rect b = bounds;
        if (thumb(b.pos, ss, s).empty == false && p.x >= b.right - ss.width - 4)
        {
            return true;
        }
        float[2] st = sideTrack(b.pos, ss, s);
        return sideThumb(b.pos, ss, s).empty == false && p.y >= b.bottom - ss.width - 4 && p.x >= st[0]
            && p.x < st[0] + st[1];
    }

    /// The wheel scrolls, sideways too without wrapping.
    override bool onWheel(ref const WheelEvent e)
    {
        TextAreaStyle s = style();
        fling.stop();
        float viewH = size.h - s.padY * 2;
        bool sideways = e.dx != 0 || (e.mods & Mod.shift) != 0;
        if (sideways)
        {
            if (wrap)
            {
                return false;
            }
            float before = scrollX;
            scrollX = clamp(scrollX + (e.dx != 0 ? e.dx : e.dy), 0, maxScrollX);
            markNeedsPaint();
            return scrollX != before;
        }
        if (maxScrollY(viewH) <= 0)
        {
            return false;
        }
        scrollY = clamp(scrollY + e.dy, 0, maxScrollY(viewH));
        markNeedsPaint();
        return true;
    }

    /// Position before `p`, across line breaks.
    private TextPos prevPos(TextPos p)
    {
        if (p.col > 0)
        {
            return TextPos(p.line, p.col - strideBack(lines[p.line], p.col));
        }
        return p.line > 0 ? TextPos(p.line - 1, lines[p.line - 1].length) : p;
    }

    /// Position after `p`, across line breaks.
    private TextPos nextPos(TextPos p)
    {
        if (p.col < lines[p.line].length)
        {
            return TextPos(p.line, p.col + stride(lines[p.line], p.col));
        }
        return p.line + 1 < lines.length ? TextPos(p.line + 1, 0) : p;
    }

    /// Start of the word before `p`, or the end of the line above at a line start.
    private TextPos wordLeft(TextPos p)
    {
        if (p.col == 0)
        {
            return prevPos(p);
        }
        return TextPos(p.line, wordStart(lines[p.line], p.col));
    }

    /// End of the word after `p`, or the start of the line below at a line end.
    private TextPos wordRight(TextPos p)
    {
        if (p.col == lines[p.line].length)
        {
            return nextPos(p);
        }
        return TextPos(p.line, wordEnd(lines[p.line], p.col));
    }

    /// Position `n` rows above or below `p`, nearest to the goal x.
    private TextPos rowsAway(TextPos p, ptrdiff_t n)
    {
        size_t r = rowOf(p);
        if (isNaN(goalX))
        {
            goalX = xOf(p, r);
        }
        ptrdiff_t to = cast(ptrdiff_t) r + n;
        if (to < 0)
        {
            return TextPos(0, 0);
        }
        if (to >= rows.length)
        {
            return TextPos(lines.length - 1, lines[$ - 1].length);
        }
        return posAt(to, goalX);
    }

    /// Rows in a page, less one kept for context.
    private ptrdiff_t pageRows()
    {
        TextAreaStyle s = style();
        return max(1, cast(ptrdiff_t) floor((size.h - s.padY * 2) / lineHeight()) - 1);
    }

    /// Moves the caret to `to`, extending the selection when `extend`. Keeps the goal x when `vertical`.
    private void move(TextPos to, bool extend, bool vertical = false)
    {
        caret = to;
        if (extend == false)
        {
            anchor = caret;
        }
        if (vertical == false)
        {
            goalX = float.nan;
        }
        lastKind = EditKind.other;
        reveal = true;
    }

    /// Movement, editing, clipboard and undo keys.
    override bool onKey(ref const KeyEvent e)
    {
        if (enabled == false || rows.length == 0)
        {
            return false;
        }
        bool shift = (e.mods & Mod.shift) != 0;
        bool ctrl = (e.mods & Mod.ctrl) != 0;
        TextPos lo = min(caret, anchor);
        TextPos hi = max(caret, anchor);
        switch (e.key)
        {
        case Key.left:
            move(caret != anchor && shift == false && ctrl == false ? lo : ctrl ? wordLeft(caret) : prevPos(caret),
                shift);
            break;
        case Key.right:
            move(caret != anchor && shift == false && ctrl == false ? hi : ctrl ? wordRight(caret) : nextPos(caret),
                shift);
            break;
        case Key.up:
            move(rowsAway(caret, -1), shift, true);
            break;
        case Key.down:
            move(rowsAway(caret, 1), shift, true);
            break;
        case Key.pageUp:
        case Key.pageDown:
            ptrdiff_t n = e.key == Key.pageUp ? -pageRows() : pageRows();
            scrollY += n * lineHeight();
            move(rowsAway(caret, n), shift, true);
            break;
        case Key.home:
            move(ctrl ? TextPos(0, 0) : TextPos(caret.line, rows[rowOf(caret)].start), shift);
            break;
        case Key.end:
            move(ctrl ? TextPos(lines.length - 1, lines[$ - 1].length)
                : TextPos(caret.line, rows[rowOf(caret)].end), shift);
            break;
        case Key.backspace:
            if (readOnly)
            {
                return true;
            }
            replaceRange(caret != anchor ? lo : ctrl ? wordLeft(caret) : prevPos(caret), hi, "", EditKind.deleting);
            break;
        case Key.delete_:
            if (readOnly)
            {
                return true;
            }
            replaceRange(lo, caret != anchor ? hi : ctrl ? wordRight(caret) : nextPos(caret), "", EditKind.deleting);
            break;
        case Key.enter:
            if (readOnly || (e.mods & (Mod.ctrl | Mod.alt)) != 0)
            {
                return false;
            }
            string l = lines[lo.line];
            size_t ind;
            while (ind < lo.col && l[ind] == ' ')
            {
                ++ind;
            }
            replaceSelection("\n" ~ l[0 .. ind], EditKind.other);
            break;
        case Key.tab:
            if (tabSpaces <= 0 || readOnly || e.mods != 0)
            {
                return false;
            }
            size_t n = tabSpaces - lo.col % tabSpaces;
            char[] sp = new char[n];
            sp[] = ' ';
            replaceSelection(sp.idup, EditKind.typing);
            break;
        case Key.a:
            if (ctrl == false)
            {
                return typesText(e);
            }
            anchor = TextPos(0, 0);
            caret = TextPos(lines.length - 1, lines[$ - 1].length);
            break;
        case Key.c:
        case Key.x:
            if (ctrl == false)
            {
                return typesText(e);
            }
            if (caret != anchor && tree.services !is null)
            {
                tree.services.setClipboard(selectedText());
                if (e.key == Key.x)
                {
                    replaceSelection("", EditKind.other);
                }
            }
            break;
        case Key.v:
            if (ctrl == false)
            {
                return typesText(e);
            }
            if (tree.services !is null && readOnly == false)
            {
                replaceSelection(clean(tree.services.clipboard), EditKind.other);
            }
            break;
        case 'z':
            if (ctrl == false)
            {
                return typesText(e);
            }
            if (shift)
            {
                redo();
            }
            else
            {
                undo();
            }
            break;
        case 'y':
            if (ctrl == false)
            {
                return typesText(e);
            }
            redo();
            break;
        default:
            return typesText(e);
        }
        hideHandles();
        touch();
        return true;
    }

    /// Inserts typed text.
    override bool onText(string s)
    {
        compose(null, 0, 0);
        if (enabled == false || readOnly)
        {
            return false;
        }
        hideHandles();
        string c = clean(s);
        bool plain = true;
        foreach (char ch; c)
        {
            plain = plain && ch != '\n';
        }
        replaceSelection(c, plain ? EditKind.typing : EditKind.other);
        return true;
    }

    /// Restarts the blink and repaints, and drops the handles when focus leaves.
    override void onFocus(bool gained)
    {
        compose(null, 0, 0);
        dragging = false;
        thumbHeld = false;
        sideThumbHeld = false;
        if (gained == false)
        {
            hideHandles();
        }
        touch();
    }
}

/// Start of the word at or before byte `i` of `l`.
private size_t wordStart(string l, size_t i)
{
    while (i > 0 && isAlphaNum(l[i - 1]) == false && l[i - 1] < 0x80)
    {
        --i;
    }
    while (i > 0 && (isAlphaNum(l[i - 1]) || l[i - 1] >= 0x80))
    {
        --i;
    }
    return i;
}

/// Word holding the character at byte `i` of `l` or just before it, else the run of other characters there, for
/// selecting a word under a press.
private size_t[2] wordAt(string l, size_t i)
{
    bool word(size_t k)
    {
        return isAlphaNum(l[k]) || l[k] >= 0x80;
    }

    bool inWord = (i < l.length && word(i)) || (i > 0 && word(i - 1));
    size_t a = i;
    size_t b = i;
    while (a > 0 && word(a - 1) == inWord)
    {
        --a;
    }
    while (b < l.length && word(b) == inWord)
    {
        ++b;
    }
    return [a, b];
}

/// End of the word at or after byte `i` of `l`.
private size_t wordEnd(string l, size_t i)
{
    while (i < l.length && isAlphaNum(l[i]) == false && l[i] < 0x80)
    {
        ++i;
    }
    while (i < l.length && (isAlphaNum(l[i]) || l[i] >= 0x80))
    {
        ++i;
    }
    return i;
}

/// Retained multi-line editor: `textArea(notes, wrap: true)`, or `textArea(source, variant: "code",
/// lineNumbers: true, tabSpaces: 4)` for code. Without a bounded height it grows with its text. `readOnly`
/// keeps selection and copying. `enabled` greys it out and stops input when false.
TextArea textArea(Signal!string value, string placeholder = null, bool wrap = false, bool readOnly = false,
    int tabSpaces = 0, bool lineNumbers = false, string variant = null, bool delegate() enabled = null,
    string tooltip = null, string accessName = null)
{
    TextArea a = new TextArea(value, placeholder, variant);
    a.wrap = wrap;
    a.readOnly = readOnly;
    a.tabSpaces = tabSpaces;
    a.lineNumbers = lineNumbers;
    a.setTooltip(tooltip);
    a.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { a.setEnabled(enabled()); });
    }
    return a;
}

// Lines and positions: tabs become spaces, `\r` goes, and positions order by line then byte.
unittest
{
    assert(linesOf("a\r\n\tb\n") == ["a", "    b", ""]);
    assert(linesOf("") == [""]);
    assert(clean("ab\tc") == "ab  c");
    assert(TextPos(1, 0) > TextPos(0, 9) && TextPos(2, 3) < TextPos(2, 4));
}

// Typing across lines, auto indent, the goal column, word and line deletion, undo merging, the clipboard,
// outside writes, read only and disabled.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import std.math : abs;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    Signal!string v = signal("");
    TextArea a = textArea(v, tabSpaces: 4);
    h.setRoot(column()(a));
    h.frame();
    h.setFocus(a);
    TextAreaStyle s;
    float lh = h.tree.text.lineHeight(s.font, s.size);
    assert(a.size.h == s.minLines * lh + s.padY * 2, "empty, as tall as the minimum lines");

    h.injectText("if (x)");
    h.injectKey(Key.enter);
    h.injectKey(Key.tab);
    h.injectText("go();");
    h.injectKey(Key.enter);
    h.injectText("done");
    assert(v.peek == "if (x)\n    go();\n    done", "Tab inserts spaces and Enter keeps the indent");
    assert(a.caret == TextPos(2, 8));
    h.frame();

    float x = a.xOf(a.caret, a.rowOf(a.caret));
    h.injectKey(Key.up);
    assert(a.caret.line == 1 && abs(a.xOf(a.caret, a.rowOf(a.caret)) - x) < 5, "nearest x one line up");
    h.injectKey(Key.up);
    assert(a.caret.line == 0);
    h.injectKey(Key.down);
    h.injectKey(Key.down);
    assert(a.caret == TextPos(2, 8), "the goal x comes back on longer lines");
    h.injectKey(Key.home, Mod.ctrl);
    h.injectKey(Key.end, Mod.shift);
    assert(a.selectedText == "if (x)");
    h.injectKey(Key.right, Mod.shift);
    assert(a.selectedText == "if (x)\n", "the selection crosses the line break");

    h.injectKey(Key.c, Mod.ctrl);
    h.injectKey(Key.end, Mod.ctrl);
    h.injectKey(Key.v, Mod.ctrl);
    assert(v.peek == "if (x)\n    go();\n    doneif (x)\n" && a.caret == TextPos(3, 0));
    h.injectKey('z', Mod.ctrl);
    assert(v.peek == "if (x)\n    go();\n    done" && a.caret == TextPos(2, 8), "paste undone");
    h.injectKey(Key.backspace, Mod.ctrl);
    assert(v.peek == "if (x)\n    go();\n    ");
    h.injectKey(Key.backspace);
    h.injectKey(Key.backspace);
    h.injectKey('z', Mod.ctrl);
    assert(v.peek == "if (x)\n    go();\n    done", "deleting in a row undoes as one step");
    h.injectKey('z', Mod.ctrl);
    assert(v.peek == "if (x)\n    go();\n    ", "before typing done");
    h.injectKey('y', Mod.ctrl);
    h.injectKey('y', Mod.ctrl);
    assert(v.peek == "if (x)\n    go();\n  " && a.canUndo, "both steps redone");

    v.set("one\ntwo");
    assert(a.text == ["one", "two"] && a.canUndo == false, "outside writes replace the text and the history");
    h.frame();
    assert(a.size.h == s.minLines * lh + s.padY * 2);
    v.set("1\n2\n3\n4\n5");
    h.frame();
    assert(a.size.h == 5 * lh + s.padY * 2, "grows with its lines");

    a.readOnly = true;
    h.injectKey(Key.a, Mod.ctrl);
    h.injectText("x");
    h.injectKey(Key.backspace);
    assert(v.peek == "1\n2\n3\n4\n5" && a.selectedText == "1\n2\n3\n4\n5", "read only selects but keeps the text");
    a.readOnly = false;
    a.setEnabled(false);
    assert(h.focused is null && a.onText("x") == false && v.peek == "1\n2\n3\n4\n5");
}

// Wrapped rows: carets at a wrap, up and down by rows, clicks and drags, and scrolling to the caret.
unittest
{
    import dentrite.containers : CrossAlign, column, sized;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    Signal!string v = signal("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi"
        ~ "\nshort");
    TextArea a = textArea(v, wrap: true, lineNumbers: true);
    h.setRoot(column(cross: CrossAlign.start)(sized(w: 200, h: 60)(a)));
    h.frame();
    assert(a.rows.length > 3 && a.rows[0].line == 0 && a.rows[$ - 1].line == 1);
    Row r0 = a.rows[0];
    Row r1 = a.rows[1];
    assert(r0.start == 0 && r1.start == r0.end + 1 && v.peek[r0.end] == ' ', "rows break at a space");
    assert(a.rowOf(TextPos(0, r0.end)) == 0 && a.rowOf(TextPos(0, r1.start)) == 1);

    h.setFocus(a);
    h.injectKey(Key.end);
    assert(a.caret == TextPos(0, r0.end), "end of the row, not the line");
    h.injectKey(Key.down);
    assert(a.caret.line == 0 && a.rowOf(a.caret) == 1);
    h.injectKey(Key.end, Mod.ctrl);
    h.frame();
    assert(a.caret == TextPos(1, 5) && a.scrollY > 0, "scrolled to show the caret");
    h.injectKey(Key.home, Mod.ctrl);
    h.frame();
    assert(a.scrollY == 0);

    TextAreaStyle s;
    float lh = h.tree.text.lineHeight(s.font, s.size);
    Rect tr = a.textRect(a.bounds.pos, s);
    Point p0 = Point(tr.x + 1, tr.y + lh / 2);
    Point p1 = Point(tr.x + 1, tr.y + lh * 1.5f);
    h.inject(PointerKind.move, p0);
    h.inject(PointerKind.down, p0);
    h.inject(PointerKind.move, p1);
    h.inject(PointerKind.up, p1);
    assert(a.anchor == TextPos(0, 0) && a.caret == TextPos(0, r1.start), "drag from the first row to the second");
    h.inject(PointerKind.down, p0, 2);
    h.inject(PointerKind.up, p0, 2);
    assert(a.selectedText == "alpha", "a double click selects a word");
    h.injectWheel(p0, 5);
    assert(a.scrollY == 5);
    h.injectWheel(p0, 5, 30);
    assert(a.scrollY == 10, "a diagonal scroll keeps its vertical part");
}

// Without wrapping a long line gets a sideways bar: Shift and the wheel, a horizontal wheel, the thumb and the
// track scroll it, and a wrapped area has none.
unittest
{
    import dentrite.containers : CrossAlign, column, sized;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    string longLine = "a long line that is clearly much wider than the text area it is shown in, by a lot";
    TextArea a = textArea(signal("short\n" ~ longLine ~ "\n3\n4\n5\n6\n7"), lineNumbers: true);
    TextArea w = textArea(signal(longLine), wrap: true);
    h.setRoot(column(cross: CrossAlign.start, gap: 10)(sized(w: 200, h: 80)(a), sized(w: 200, h: 80)(w)));
    h.frame();
    TextAreaStyle s;
    ScrollStyle ss;
    Rect th = a.sideThumb(a.bounds.pos, ss, s);
    assert(th.empty == false && th.bottom == a.bounds.bottom - 2 && a.scrollX == 0);
    assert(w.sideThumb(w.bounds.pos, ss, s).empty, "wrapped areas do not scroll sideways");

    Point mid = a.bounds.pos + Point(100, 20);
    h.injectWheel(mid, 30, 0, Mod.shift);
    assert(a.scrollX == 30, "Shift and the wheel");
    h.injectWheel(mid, 0, -10);
    assert(a.scrollX == 20, "a horizontal wheel");

    th = a.sideThumb(a.bounds.pos, ss, s);
    Point grab = Point(th.x + 2, th.y + th.h / 2);
    h.inject(PointerKind.move, mid);
    assert(a.cursor == CursorShape.text);
    h.inject(PointerKind.move, grab);
    assert(a.cursor == CursorShape.arrow, "an arrow over the bar");
    h.inject(PointerKind.down, grab);
    h.inject(PointerKind.move, grab + Point(1000, 0));
    h.inject(PointerKind.up, grab + Point(1000, 0));
    assert(a.scrollX == a.maxScrollX && a.caret == TextPos.init, "dragging the thumb scrolls, not selects");
    th = a.sideThumb(a.bounds.pos, ss, s);
    Point track = Point(a.sideTrack(a.bounds.pos, ss, s)[0] + 1, th.y + 1);
    h.inject(PointerKind.down, track);
    h.inject(PointerKind.up, track);
    h.frame();
    assert(a.scrollX < a.maxScrollX, "a press on the track pages back");
    h.inject(PointerKind.move, Point(a.bounds.right - 3, a.bounds.y + 10));
    assert(a.cursor == CursorShape.arrow, "and over the vertical bar");
    h.inject(PointerKind.move, mid);
    assert(a.cursor == CursorShape.text);

    size_t rows = w.rows.length;
    w.setWrap(false);
    h.frame();
    assert(w.rows.length == 1 && w.maxScrollX > 0, "unwrapped by the setter");
    w.setWrap(true);
    h.frame();
    assert(w.rows.length == rows && w.maxScrollX == 0, "and wrapped again");
    float textW = a.textRect(a.bounds.pos, s).w;
    a.setLineNumbers(false);
    h.frame();
    assert(a.textRect(a.bounds.pos, s).w > textW, "no gutter");
}

// Input method text is shaped into the caret line without editing, and a selection is deleted when it starts.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    Signal!string v = signal("ab\ncd");
    TextArea a = textArea(v);
    h.setRoot(column()(a));
    h.frame();
    h.setFocus(a);
    a.select(TextPos(0, 1), TextPos(1, 1));
    h.frame();
    float before = a.caretRect.x;
    h.injectCompose("ka", 0, 2);
    h.frame();
    assert(v.peek == "ad" && a.caret == TextPos(0, 1), "the selection goes");
    assert(a.shownLine(0) == "akad" && a.lines[0] == "ad" && a.caretRect.x > before);
    Point inText = a.bounds.pos + Point(20, 10);
    h.inject(PointerKind.down, inText);
    h.inject(PointerKind.up, inText);
    assert(a.caret == TextPos(0, 1), "presses wait for the commit");
    h.injectText("か");
    assert(v.peek == "aかd" && a.caret == TextPos(0, 4) && a.composing is null);
    h.frame();
    assert(a.shownLine(0) == "aかd");
}

// A touch swipe scrolls a text area without moving the caret or focusing it, a tap places the caret.
unittest
{
    import core.time : MonoTime, msecs;
    import dentrite.containers : CrossAlign, column, sized;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    Signal!string v = signal("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12");
    TextArea a = textArea(v);
    h.setRoot(column(cross: CrossAlign.start)(sized(w: 200, h: 60)(a)));
    h.frame();
    MonoTime t = MonoTime.currTime;
    int ms;
    void touch(PointerKind k, float y)
    {
        ms += 200;
        h.inject(k, Point(a.bounds.x + 50, a.bounds.y + y), 1, 1, 0, PointerSource.touch, t + ms.msecs);
    }

    touch(PointerKind.down, 50);
    touch(PointerKind.move, 40);
    touch(PointerKind.move, 20);
    touch(PointerKind.up, 20);
    assert(a.scrollY == 22 && a.caret == TextPos.init && h.focused is null);
    touch(PointerKind.down, 10);
    touch(PointerKind.up, 10);
    assert(h.focused is a && a.caret.line > 0, "a tap places the caret on a scrolled line");
}

// Word selection takes the word holding the character at a byte, or ending there, else the run of other
// characters.
unittest
{
    assert(wordAt("std.algorithm : filter", 16) == [16, 22]);
    assert(wordAt("std.algorithm : filter", 13) == [4, 13]);
    assert(wordAt("std.algorithm : filter", 14) == [13, 16]);
    assert(wordAt("", 0) == [0, 0]);
}

// Switching the variant shapes the lines again in the new font.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    TextArea a = textArea(signal("iiii"));
    h.setRoot(column()(a));
    h.frame();
    float ui = a.runs[0].width;
    a.setVariant("code");
    h.frame();
    assert(a.variant == "code" && a.runs[0].width > ui, "mono i is wider");
}
