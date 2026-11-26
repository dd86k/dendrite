/// Text label: themed font and color, optional wrapping, bindable text.
module dentrite.widgets.label;

import dentrite.immediate : Id, Ui;
import dentrite.node;
import dentrite.signals : effect;
import dentrite.text;
import std.algorithm.comparison : max;
import std.math : isInfinity, round;

/// Look of text.
struct TextStyle
{
    enum section = "text"; /// section name in theme files

    /// Variants theme files can style as `[section.variant]`.
    enum Variants
    {
        muted,   /// secondary text
        strong,  /// emphasized
        mono,    /// fixed pitch
        monoMuted, /// fixed pitch, secondary
        heading, /// panel titles
        title,   /// page and dialog titles
        accent,  /// highlighted value
        changed, /// value changed by the last update
        error,   /// failures
        warn,    /// warnings
    }

    FontKind font = FontKind.ui;                 /// which loaded font to use
    float size = 13;                             /// text size in logical pixels
    Color color = Color(0xdd, 0xdd, 0xdd, 0xff); /// text color
    Features features;                           /// OpenType features, `Features.tabular` for counters

    /// Look of `variant` without a theme.
    static void applyVariant(ref TextStyle s, string variant)
    {
        enum Color muted = Color(0x7d, 0x7d, 0x88, 0xff);
        enum Color bright = Color(0xec, 0xec, 0xf0, 0xff);
        enum Color amber = Color(0xf2, 0xb9, 0x50, 0xff);
        switch (variant)
        {
        case "muted":
            s.color = muted;
            break;
        case "strong":
            s.font = FontKind.uiStrong;
            s.color = bright;
            break;
        case "mono":
            s.font = FontKind.mono;
            s.size = 12;
            break;
        case "monoMuted":
            s.font = FontKind.mono;
            s.size = 12;
            s.color = muted;
            break;
        case "heading":
            s.font = FontKind.uiStrong;
            s.size = 11;
            s.color = Color(0xa3, 0xa3, 0xad, 0xff);
            break;
        case "title":
            s.font = FontKind.uiStrong;
            s.size = 18;
            s.color = bright;
            break;
        case "accent":
            s.color = Color(0x6a, 0xa5, 0xff, 0xff);
            break;
        case "changed":
            s.font = FontKind.mono;
            s.size = 12;
            s.color = amber;
            break;
        case "error":
            s.color = Color(0xf4, 0x7a, 0x7a, 0xff);
            break;
        case "warn":
            s.color = amber;
            break;
        default:
            break;
        }
    }
}

/// Horizontal placement of text inside a wider box.
enum TextAlign
{
    start,  /// left
    center, /// centered
    end,    /// right
}

/// Paints wrapped `lines` of `run` from the top left `origin`, aligned in `width`.
void paintLines(ref PaintContext ctx, ShapedRun run, const Line[] lines, Point origin, float width,
    TextAlign align_, const ref TextStyle s)
{
    TextSystem t = ctx.text;
    float lineH = t.lineHeight(s.font, s.size);
    float ascent = t.ascent(s.font, s.size);
    foreach (size_t i, ref const Line l; lines)
    {
        float lw = l.width / t.ppp;
        float x = align_ == TextAlign.start ? 0 : align_ == TextAlign.center ? round((width - lw) / 2) : width - lw;
        ctx.list.text(run, Point(origin.x + x, origin.y + i * lineH + ascent), s.color, l.first, l.last);
    }
}

/// Text leaf. Wraps at spaces when `wrap` is set and the width is bounded.
final class Label : Node
{
    string text;        /// text shown
    string variant;     /// TextStyle variant
    bool wrap;          /// break lines to fit
    TextAlign align_;   /// placement in a wider box
    Node target;        /// control it names, focused by a click, see `labels`
    private ShapedRun run;  /// shaped content
    private Line[] lines;   /// wrapped lines

    /// Creates a label.
    this(string text, string variant = null, bool wrap = false, TextAlign align_ = TextAlign.start)
    {
        this.text = text;
        this.variant = variant;
        this.wrap = wrap;
        this.align_ = align_;
    }

    /// Names `n` for screen readers and focuses it on a click, or stops for null.
    void labels(Node n)
    {
        if (target !is null && target.labelledBy is this)
        {
            target.labelledBy = null;
        }
        target = n;
        interactive = n !is null;
        if (n !is null)
        {
            n.labelledBy = this;
        }
    }

    /// A left click focuses the first Tab stop in `target`.
    override bool onPointer(ref const PointerEvent e)
    {
        if (target is null || e.button != 1)
        {
            return false;
        }
        if (e.kind == PointerKind.up && hovered && tree !is null && tree.services !is null)
        {
            if (Node f = firstStop(target))
            {
                tree.services.setFocus(f);
            }
        }
        return e.kind == PointerKind.down || e.kind == PointerKind.up;
    }

    /// Static text.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.label;
        a.label = text;
    }

    /// Replaces the text. Same width on one line only repaints.
    void setText(string s)
    {
        if (s == text)
        {
            return;
        }
        text = s;
        if (tree !is null && run !is null && wrap == false)
        {
            TextStyle st = tree.style!TextStyle(variant);
            ShapedRun next = tree.text.shape(st.font, st.size, s, st.features);
            if (next.width == run.width)
            {
                run = next;
                lines = [Line(0, next.glyphs.length, 0, next.width)];
                markNeedsPaint();
                return;
            }
        }
        markNeedsLayout();
    }

    /// Switches the style variant.
    void setVariant(string v)
    {
        if (v == variant)
        {
            return;
        }
        TextStyle before = tree is null ? TextStyle.init : tree.style!TextStyle(variant);
        variant = v;
        TextStyle after = tree is null ? TextStyle.init : tree.style!TextStyle(variant);
        if (before.font == after.font && before.size == after.size && before.features == after.features)
        {
            markNeedsPaint();
            return;
        }
        markNeedsLayout();
    }

    /// Shapes, wraps if allowed, and sizes to the widest line.
    protected override Size performLayout(Constraints c)
    {
        TextStyle s = tree.style!TextStyle(variant);
        TextSystem t = tree.text;
        run = t.shape(s.font, s.size, text, s.features);
        if (wrap && isInfinity(c.maxW) == false && run.width / t.ppp > c.maxW)
        {
            lines = .wrap(run, c.maxW * t.ppp);
        }
        else
        {
            lines = [Line(0, run.glyphs.length, 0, run.width)];
        }
        float w = 0;
        foreach (ref Line l; lines)
        {
            w = max(w, l.width);
        }
        return Size(w / t.ppp, lines.length * t.lineHeight(s.font, s.size));
    }

    /// The lines.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TextStyle s = ctx.style!TextStyle(variant);
        paintLines(ctx, run, lines, origin, size.w, align_, s);
    }
}

/// Fixed text. It names `for_` for screen readers, and `live` sets how they announce changes.
Label label(string text, string variant = null, bool wrap = false, TextAlign align_ = TextAlign.start,
    string tooltip = null, Node for_ = null, Live live = Live.off)
{
    Label l = new Label(text, variant, wrap, align_);
    l.setTooltip(tooltip);
    l.accessLive = live;
    l.labels(for_);
    return l;
}

/// Text bound to `text`, re-read when the signals it reads change. The effect belongs to the current owner.
/// `for_` and `live` as for fixed text, such as `label(() => status.get, live: Live.polite)` for a status line.
Label label(string delegate() text, string variant = null, bool wrap = false,
    TextAlign align_ = TextAlign.start, string tooltip = null, Node for_ = null, Live live = Live.off)
{
    Label l = new Label(null, variant, wrap, align_);
    l.setTooltip(tooltip);
    l.accessLive = live;
    l.labels(for_);
    effect(() { l.setText(text()); });
    return l;
}

/// Island label: the retained label node, declared fresh each pass. `forNext` names the next control for screen
/// readers and lets a click focus it, `live` as for retained labels.
void label(Ui ui, string text, string variant = null, bool wrap = false, TextAlign align_ = TextAlign.start,
    bool forNext = false, Live live = Live.off, string file = __FILE__, size_t line = __LINE__)
{
    Label l = new Label(text, variant, wrap, align_);
    l.accessLive = live;
    ui.put(l);
    if (forNext)
    {
        Id i = ui.id(file, line);
        bool clicked = ui.clickable(i).clicked;
        ui.labelNext(null, false);
        ui.track(l, i);
        ui.labelNext(l, clicked);
    }
}

/// First Tab stop at or under `n` in tree order, or null.
private Node firstStop(Node n)
{
    if (n.tabStop)
    {
        return n;
    }
    foreach (Node c; n.children)
    {
        if (Node f = firstStop(c))
        {
            return f;
        }
    }
    return null;
}

// Labels measure with real fonts, wrap to the width, and skip relayout when the width stays.
unittest
{
    import dentrite.containers : column;
    import dentrite.signals : signal, Signal;
    import dentrite.theme : Theme;

    TextSystem ts = testText();
    scope (exit)
    {
        ts.dispose();
    }
    Signal!uint hits = signal(10u);
    Label count = label(() => format("%d", hits.get), "mono");
    Label para = label("the quick brown fox jumps over the lazy dog", wrap: true);
    Tree t = new Tree(ts, new Theme("[text.mono]\nfont = mono\n", "test"), null);
    t.viewport = Size(120, 200);
    t.setRoot(column()(count, para));
    t.flush();
    assert(count.text == "10");
    assert(para.size.h > ts.lineHeight(FontKind.ui, 13) * 2, "wrapped onto three or more lines");
    assert(para.size.w <= 120);
    int runs = count.layoutRuns;
    hits.set(11);
    assert(count.text == "11" && t.needsLayout == false, "same width, paint only");
    hits.set(100);
    assert(t.needsLayout);
    t.flush();
    assert(count.layoutRuns == runs + 1);
}

version (unittest) import std.format : format;
