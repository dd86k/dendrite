/// Links: underlined text that opens a URL with the system's handler, or runs an action within the app.
module dentrite.widgets.link;

import dentrite.immediate;
import dentrite.node;
import dentrite.signals : effect;
import dentrite.text;
import dentrite.widgets.button : ButtonState, PressBehavior;
import std.algorithm.comparison : max, min;
import std.math : round;

/// Look of a link.
struct LinkStyle
{
    enum section = "link"; /// section name in theme files

    Color text = Color(0x6a, 0xa5, 0xff, 0xff);         /// text and underline
    Color textHover = Color(0x9c, 0xc3, 0xff, 0xff);    /// text under the pointer
    Color textPressed = Color(0x4c, 0x8d, 0xf6, 0xff);  /// text while held
    Color textDisabled = Color(0x80, 0x80, 0x80, 0xff); /// text when disabled
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff);        /// focus ring
    float underline = 1;  /// underline thickness, 0 for none
    bool hoverUnderline;  /// underline only under the pointer or with focus
    float radius = 2;     /// focus ring corner radius
    FontKind font = FontKind.ui; /// text font
    float size = 13;      /// text size
}

/// Size of a link showing `text`.
Size measureLink(TextSystem t, const ref LinkStyle s, string text)
{
    return Size(t.measure(s.font, s.size, text), t.lineHeight(s.font, s.size));
}

/// Paints a link in `r`. Shared by the retained node and the island function.
void paintLink(ref PaintContext ctx, Rect r, const ref LinkStyle s, string text, ButtonState st)
{
    Color ink = st.enabled == false ? s.textDisabled : st.held ? s.textPressed : st.hovered ? s.textHover : s.text;
    TextSystem t = ctx.text;
    float baseline = r.y + t.ascent(s.font, s.size);
    ctx.list.text(t.shape(s.font, s.size, text), Point(r.x, baseline), ink);
    bool under = s.hoverUnderline == false || (st.enabled && (st.hovered || st.focused));
    if (under && s.underline > 0 && text.length > 0)
    {
        float y = min(round(baseline + max(1, s.size * 0.1f)), r.bottom - s.underline);
        ctx.list.rect(Rect(r.x, y, r.w, s.underline), ink);
    }
    if (st.focused)
    {
        ctx.list.rect(r.inset(-2), Color.init, s.radius, s.focus, 1);
    }
}

/// Retained link.
final class Link : Node
{
    string text;                /// text shown
    string url;                 /// address opened on activation, null for none
    void delegate() onActivate; /// runs on activation in place of opening `url`
    bool enabled = true;        /// accepts clicks

    mixin PressBehavior;

    /// Creates a link to `url`, or running `onActivate` when set.
    this(string text, string url, void delegate() onActivate)
    {
        this.text = text;
        this.url = url;
        this.onActivate = onActivate;
        interactive = true;
        focusable = true;
        cursor = CursorShape.pointer;
    }

    /// Runs `onActivate`, or opens `url` with the system's handler.
    void activate()
    {
        if (onActivate !is null)
        {
            onActivate();
        }
        else if (url.length > 0 && tree !is null && tree.services !is null)
        {
            tree.services.openUrl(url);
        }
    }

    /// Changes the text.
    void setText(string s)
    {
        if (s != text)
        {
            text = s;
            markNeedsLayout();
        }
    }

    /// Changes the address.
    void setUrl(string s)
    {
        url = s;
    }

    /// Enables or disables.
    void setEnabled(bool on)
    {
        if (on != enabled)
        {
            enabled = on;
            markNeedsPaint();
        }
    }

    /// Link named by its text, with its address.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.link;
        a.label = text;
        a.url = url;
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
    }

    /// Text size.
    protected override Size performLayout(Constraints c)
    {
        LinkStyle s = tree.style!LinkStyle();
        return measureLink(tree.text, s, text);
    }

    /// The look for the current state.
    override void paint(ref PaintContext ctx, Point origin)
    {
        LinkStyle s = ctx.style!LinkStyle();
        paintLink(ctx, Rect(origin.x, origin.y, size.w, size.h), s, text,
            ButtonState(hovered, pressed && hovered, enabled, focusRing));
    }
}

/// Retained link: `link("Project page", "https://example.org")` opens the address with the system's handler,
/// `link("Show log", onActivate: &showLog)` runs an action instead. `enabled` greys it out and stops input when
/// false.
Link link(string text, string url = null, void delegate() onActivate = null, bool delegate() enabled = null,
    string tooltip = null, string accessName = null)
{
    Link l = new Link(text, url, onActivate);
    l.setTooltip(tooltip);
    l.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { l.setEnabled(enabled()); });
    }
    return l;
}

/// Paint-only link declared by an island pass.
final class LinkBox : Node
{
    string text;       /// text shown
    string url;        /// address, for screen readers
    LinkStyle style;   /// style in use, resolved from the theme
    ButtonState state; /// interaction state from last pass's rects

    /// Creates a box.
    this(string text, string url, LinkStyle style, ButtonState state)
    {
        this.text = text;
        this.url = url;
        this.style = style;
        this.state = state;
    }

    /// Link named by its text, with its address.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.link;
        a.label = text;
        a.url = url;
        a.disabled = state.enabled == false;
        a.allow(AccessAction.click);
    }

    /// Same size as the retained link.
    protected override Size performLayout(Constraints c)
    {
        return measureLink(tree.text, style, text);
    }

    /// Same look as the retained link.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintLink(ctx, Rect(origin.x, origin.y, size.w, size.h), style, text, state);
    }
}

/// Island link, true on the pass it is clicked, or Enter or Space is pressed while it has focus. Opens `url`
/// with the system's handler then, when given.
bool link(Ui ui, string text, string url = null, bool enabled = true, string accessName = null,
    string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i, enabled);
    if (ui.focusStop(i, enabled) && (ui.takeKey(Key.enter) || ui.takeKey(Key.space)))
    {
        p.clicked = true;
        ui.again = true;
    }
    if (p.clicked && url.length > 0 && ui.services !is null)
    {
        ui.services.openUrl(url);
    }
    LinkBox n = new LinkBox(text, url, ui.style!LinkStyle(),
        ButtonState(p.hovered, p.held && p.hovered, enabled, ui.focusRing(i)));
    n.accessName = accessName;
    ui.put(n);
    ui.track(n, i);
    return p.clicked;
}

// A link opens its address through the window, or runs its action instead, and screen readers see the address.
unittest
{
    import dentrite.access : AccessNode;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : CrossAlign, column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(300, 200);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int shown;
    Link site = link("Project page", "https://example.org");
    Link log = link("Show log", "https://example.org/log", onActivate: () { ++shown; });
    h.setRoot(column(cross: CrossAlign.start)(site, log));
    h.frame();
    const(AccessNode)* a = h.find(Role.link, "Project page");
    assert(a !is null && a.info.url == "https://example.org");
    h.click(Role.link, "Project page");
    assert(p.urls == ["https://example.org"]);
    h.setFocus(log);
    h.injectKey(Key.enter);
    assert(shown == 1 && p.urls.length == 1, "the action replaces opening the address");
    assert(site.size.w == h.tree.text.measure(FontKind.ui, 13, "Project page"));
    p.urlless = true;
    assert(h.openUrl("https://example.org") == false);
}

// The retained and island links have the same size, and a disabled one ignores keys.
unittest
{
    import dentrite.containers : CrossAlign, column;
    import dentrite.signals : Signal, signal;

    TextSystem ts = testText();
    scope (exit)
    {
        ts.dispose();
    }
    Signal!bool on = signal(false);
    int runs;
    Link l = link("Release notes", onActivate: () { ++runs; }, enabled: () => on.get);
    Tree t = new Tree(ts, null, null);
    t.viewport = Size(300, 100);
    t.setRoot(column(cross: CrossAlign.start)(l));
    t.flush();
    Ui ui = new Ui(t);
    ui.frame((Ui u) { u.row()({ u.link("Release notes"); }); }, Rect(0, 0, 300, 100));
    assert(ui.lastRect(ui.id(__FILE__, __LINE__ - 1)).w == l.size.w);
    KeyEvent enter = KeyEvent(Key.enter, 0);
    assert(l.onKey(enter) == false && runs == 0);
    on.set(true);
    assert(l.onKey(enter) && runs == 1);
}
