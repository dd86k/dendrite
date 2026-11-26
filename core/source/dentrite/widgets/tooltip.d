/// Tooltips show the text of the node under the pointer, shown under the cursor after a delay, or of the node Tab
/// moved focus to, shown under that node.
///
/// Nodes carry the text (`Node.setTooltip`), and a child without its own shows its parent's. The host drives
/// one `Tooltips` per window: pointer moves and frames update it, presses, keys and the wheel quiet it.
module dentrite.widgets.tooltip;

import core.time : MonoTime, msecs;
import dentrite.command : Command;
import dentrite.node;
import dentrite.overlay : Popup;
import dentrite.text;
import dentrite.widgets.label : paintLines, TextAlign, TextStyle;
import dentrite.widgets.menu : mnemonic;
import std.algorithm.comparison : max, min;

/// Look and timing of tooltips.
struct TooltipStyle
{
    enum section = "tooltip"; /// section name in theme files

    Color fill = Color(0x2a, 0x2a, 0x2e, 0xff);   /// background
    Color border = Color(0x50, 0x50, 0x55, 0xff); /// outline
    Color text = Color(0xdd, 0xdd, 0xdd, 0xff);   /// text color
    Color shadow = Color(0, 0, 0, 0x60);          /// soft shadow under the box
    float shadowBlur = 6;   /// shadow fade width
    float shadowY = 2;      /// shadow offset below the box
    float radius = 4;       /// corner radius
    float padX = 8;         /// space between the text and the left and right edges
    float padY = 4;         /// space between the text and the top and bottom edges
    float maxWidth = 320;   /// widest box, longer text wraps
    float below = 20;       /// distance from the pointer to the top of the box, enough to clear the cursor
    float delay = 500;      /// milliseconds of hover before a tooltip shows
    float browse = 500;     /// milliseconds after one closes during which the next shows at once
    FontKind font = FontKind.ui; /// text font
    float size = 12;        /// text size
}

/// Tooltip text for `c`: its label without the mnemonic mark, then its shortcut, as "Step (F10)".
string commandTip(Command c)
{
    string s = mnemonic(c.label).text;
    string keys = c.shortcut;
    return keys.length > 0 ? s ~ " (" ~ keys ~ ")" : s;
}

/// Command tips: the label without its mnemonic mark, then the shortcut.
unittest
{
    import dentrite.command : command;

    assert(commandTip(command("&Step", null, keys: "F10")) == "Step (F10)");
    assert(commandTip(command("R&&D", null)) == "R&D");
}

/// Box with the text, wrapped at the style's width.
private final class TipBox : Node
{
    string text;           /// text shown
    private ShapedRun run; /// shaped content
    private Line[] lines;  /// wrapped lines

    /// Tooltip text.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.tooltip;
        a.label = text;
    }

    /// Replaces the text.
    void setText(string s)
    {
        if (s != text)
        {
            text = s;
            markNeedsLayout();
        }
    }

    /// Shapes, wraps past the style's width, and adds the padding.
    protected override Size performLayout(Constraints c)
    {
        TooltipStyle s = tree.style!TooltipStyle();
        TextSystem t = tree.text;
        run = t.shape(s.font, s.size, text);
        float room = max(0f, min(s.maxWidth, c.maxW) - s.padX * 2);
        if (run.width / t.ppp > room)
        {
            lines = wrap(run, room * t.ppp);
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
        return Size(w / t.ppp + s.padX * 2, lines.length * t.lineHeight(s.font, s.size) + s.padY * 2);
    }

    /// Shadow, box, then the lines.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TooltipStyle s = ctx.style!TooltipStyle();
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (s.shadow.a > 0)
        {
            ctx.list.shadow(Rect(r.x, r.y + s.shadowY, r.w, r.h), s.radius, s.shadowBlur, s.shadow);
        }
        ctx.list.rect(r, s.fill, s.radius, s.border, 1);
        TextStyle ts = TextStyle(s.font, s.size, s.text);
        paintLines(ctx, run, lines, Point(r.x + s.padX, r.y + s.padY), r.w - s.padX * 2, TextAlign.start, ts);
    }
}

/// Tooltip of one window. It shows a delay after the pointer reaches a node with text, at once while moving
/// on from a shown one, and stays until the pointer leaves that node. A press, key or wheel step hides it
/// until the pointer leaves. Tab to a node with text shows it below the node after the delay, until the
/// pointer moves to another node or a key, press or wheel step hides it.
final class Tooltips
{
    private Tree tree;       /// window tree
    private Popup popup;     /// box above everything, passing the pointer through
    private TipBox box;      /// text
    private Node owner;      /// node whose text shows or is pending, or null
    private Node hovered;    /// node whose text applies under the pointer, or null
    private Node anchor;     /// focused node the tooltip goes under, or null to follow the pointer
    private bool quiet;      /// hidden by input until the pointer leaves `owner`
    private Point at;        /// pointer at the last update
    private MonoTime due;    /// when to show, or `MonoTime.init` for not pending
    private MonoTime closed; /// when the last shown tooltip closed, or `MonoTime.init` for none

    /// Tooltips over `t`.
    this(Tree t)
    {
        tree = t;
        box = new TipBox;
        popup = new Popup(box);
        popup.dismiss = false;
        popup.focus = false;
        popup.passPointer = true;
        popup.onClose = () { closed = MonoTime.currTime; };
    }

    /// True while a tooltip shows.
    bool shown()
    {
        return popup.isOpen;
    }

    /// Text of the shown tooltip, or null.
    string text()
    {
        return popup.isOpen ? box.text : null;
    }

    /// Box of the shown tooltip, in window coordinates.
    Rect bounds()
    {
        return popup.isOpen ? popup.bounds : Rect.init;
    }

    /// Reports the pointer at window point `p` over `hit`, the deepest node there, or null when outside the
    /// window or blocked.
    void pointer(Node hit, Point p)
    {
        at = p;
        Node o = hit;
        while (o !is null && o.tooltip.length == 0)
        {
            o = o.parent;
        }
        if (o is hovered)
        {
            refresh();
            return;
        }
        hovered = o;
        anchor = null;
        MonoTime now = MonoTime.currTime;
        TooltipStyle s = tree.style!TooltipStyle();
        bool quick = popup.isOpen || (closed != MonoTime.init && now - closed < msecs(cast(long) s.browse));
        owner = o;
        quiet = false;
        popup.close();
        due = MonoTime.init;
        if (o !is null)
        {
            schedule(quick ? now : now + msecs(cast(long) s.delay));
        }
    }

    /// Keyboard focus moved to `n` by Tab: shows the text that applies to it under it after the delay, or
    /// hides the tooltip when none applies.
    void focus(Node n)
    {
        Node o = n;
        while (o !is null && o.tooltip.length == 0)
        {
            o = o.parent;
        }
        owner = o;
        anchor = o is null ? null : n;
        quiet = false;
        popup.close();
        due = MonoTime.init;
        if (o !is null)
        {
            TooltipStyle s = tree.style!TooltipStyle();
            schedule(MonoTime.currTime + msecs(cast(long) s.delay));
        }
    }

    /// Follows text changes of the shown tooltip, and hides it when its text or node is gone.
    private void refresh()
    {
        if (popup.isOpen == false)
        {
            return;
        }
        if (owner is null || owner.tree !is tree || owner.tooltip.length == 0
            || (anchor !is null && anchor.tree !is tree))
        {
            popup.close();
        }
        else if (box.text != owner.tooltip)
        {
            box.setText(owner.tooltip);
        }
    }

    /// Hides the tooltip until the pointer leaves the node, after a press, key or wheel step.
    void hush()
    {
        quiet = true;
        due = MonoTime.init;
        popup.close();
        closed = MonoTime.init;
    }

    /// Shows the pending tooltip if its time came by `now`, at the start of a frame.
    void tick(MonoTime now)
    {
        if (due == MonoTime.init || now < due)
        {
            return;
        }
        due = MonoTime.init;
        if (owner is null || quiet || owner.tree !is tree || owner.tooltip.length == 0
            || (anchor !is null && anchor.tree !is tree))
        {
            return;
        }
        TooltipStyle s = tree.style!TooltipStyle();
        box.setText(owner.tooltip);
        popup.openAt(tree, anchor is null ? Rect(at.x, at.y, 0, s.below) : anchor.bounds);
    }

    /// Shows at `t`, waking a frame then.
    private void schedule(MonoTime t)
    {
        due = t;
        if (tree.services !is null)
        {
            tree.services.requestFrameAt(t);
        }
    }
}

version (unittest)
{
    import dentrite.containers : column, row;
    import dentrite.host : Host;
    import dentrite.platform : Event, EventKind;
    import dentrite.theme : Theme;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.label : Label, label;
    import dentrite.widgets.menu : clickOn, hoverOn, menuHost;
    import std.math : abs;

    /// Test window: buttons A and B with tips, a label without one, and a row with a tip around a label.
    struct TipWindow
    {
        Host h;      /// headless window, tooltips without delay
        Button a;    /// tip "Alpha"
        Button b;    /// tip "Beta"
        Label plain; /// no tip
        Label inner; /// no tip, inside `box`
        Node box;    /// tip "Box"

        /// Builds and lays out the window.
        static TipWindow make()
        {
            TipWindow w;
            w.h = menuHost();
            w.h.tree.theme = new Theme("[tooltip]\ndelay = 0\n", "test");
            w.a = button("A", tooltip: "Alpha");
            w.b = button("B", tooltip: "Beta");
            w.plain = label("plain");
            w.inner = label("inner");
            w.box = row()(w.inner);
            w.box.setTooltip("Box");
            w.h.setRoot(column(gap: 10)(row(gap: 10)(w.a, w.b, w.plain), w.box));
            w.h.frame();
            return w;
        }
    }
}

// A tooltip shows under the pointer, lets the pointer through, follows text changes, and children without
// their own show their parent's.
unittest
{
    TipWindow w = TipWindow.make();
    scope (exit)
    {
        w.h.close();
    }
    Tooltips t = w.h.tooltips;
    hoverOn(w.h, w.a);
    assert(t.shown && t.text == "Alpha");
    Rect ab = w.a.bounds;
    Rect tb = t.bounds;
    assert(abs(tb.y - (ab.y + ab.h / 2 + TooltipStyle.init.below)) <= 0.5, "below the cursor");
    assert(abs(tb.x - (ab.x + ab.w / 2)) <= 0.5);
    Node under = w.h.tree.root.hitTest(Point(tb.x + 2, tb.y + 2), Point.init);
    assert(under is null || under.isInside(t.popup) == false, "the pointer goes through");
    w.a.setTooltip("Alpha 2");
    w.h.frame();
    assert(t.text == "Alpha 2");
    hoverOn(w.h, w.inner);
    assert(t.text == "Box", "from the parent");
    w.inner.setTooltip("Inner");
    w.h.frame();
    w.h.frame();
    assert(t.text == "Inner", "own text wins");
    hoverOn(w.h, w.plain);
    assert(t.shown == false);
    hoverOn(w.h, w.b);
    w.b.setTooltip(null);
    w.h.frame();
    assert(t.shown == false, "text removed");
}

// A press or key hides the tooltip until the pointer leaves the node. Leaving the window, or the node leaving
// the tree, hides it.
unittest
{
    TipWindow w = TipWindow.make();
    scope (exit)
    {
        w.h.close();
    }
    Tooltips t = w.h.tooltips;
    hoverOn(w.h, w.a);
    clickOn(w.h, w.a);
    w.h.frame();
    assert(t.shown == false, "press");
    hoverOn(w.h, w.a);
    assert(t.shown == false, "same node, still quiet");
    hoverOn(w.h, w.b);
    assert(t.shown && t.text == "Beta", "another node");
    w.h.injectKey('x');
    w.h.frame();
    assert(t.shown == false, "key");
    hoverOn(w.h, w.plain);
    hoverOn(w.h, w.b);
    assert(t.shown, "back after leaving");
    Event left = { kind: EventKind.pointerLeft };
    w.h.handle(left);
    w.h.frame();
    assert(t.shown == false, "pointer left the window");
    hoverOn(w.h, w.a);
    assert(t.shown);
    w.h.setRoot(label("other"));
    w.h.frame();
    w.h.frame();
    assert(t.shown == false, "node left the tree");
}

// With a long delay, nothing shows at first. Moving on from a shown tooltip shows the next at once, also
// shortly after it closed, but not after a press.
unittest
{
    TipWindow w = TipWindow.make();
    scope (exit)
    {
        w.h.close();
    }
    Tooltips t = w.h.tooltips;
    w.h.tree.theme = new Theme("[tooltip]\ndelay = 60000\nbrowse = 60000\n", "test");
    hoverOn(w.h, w.a);
    assert(t.shown == false, "waits");
    hoverOn(w.h, w.plain);
    w.h.tree.theme = new Theme("[tooltip]\ndelay = 0\nbrowse = 60000\n", "test");
    hoverOn(w.h, w.a);
    assert(t.shown);
    w.h.tree.theme = new Theme("[tooltip]\ndelay = 60000\nbrowse = 60000\n", "test");
    hoverOn(w.h, w.b);
    assert(t.text == "Beta", "moved on, at once");
    hoverOn(w.h, w.plain);
    assert(t.shown == false);
    hoverOn(w.h, w.inner);
    assert(t.text == "Box", "shortly after closing, at once");
    clickOn(w.h, w.inner);
    hoverOn(w.h, w.a);
    assert(t.shown == false, "a press ends the quick switching");
}

// Long text wraps at the style's width. Opening and closing a tooltip leaves focus alone, also when focus
// was cleared while it showed.
unittest
{
    TipWindow w = TipWindow.make();
    scope (exit)
    {
        w.h.close();
    }
    Tooltips t = w.h.tooltips;
    w.a.setTooltip("a long tooltip text that cannot fit in one line of the default width, so it wraps");
    hoverOn(w.h, w.a);
    float line = w.h.tree.text.lineHeight(FontKind.ui, 12);
    assert(t.bounds.w <= TooltipStyle.init.maxWidth && t.bounds.h > line + TooltipStyle.init.padY * 2, "wrapped");
    w.h.setFocus(w.b);
    hoverOn(w.h, w.plain);
    assert(w.h.focused is w.b);
    hoverOn(w.h, w.a);
    w.h.setFocus(null);
    hoverOn(w.h, w.plain);
    assert(t.shown == false && w.h.focused is null, "focus not given back to B");
}

// Tab shows the focused node's tooltip below it, and the pointer at rest keeps it. A key hides it, moving the
// pointer to another node takes over, and a focused node without text shows none.
unittest
{
    TipWindow w = TipWindow.make();
    scope (exit)
    {
        w.h.close();
    }
    Tooltips t = w.h.tooltips;
    hoverOn(w.h, w.plain);
    w.h.injectKey(Key.tab);
    w.h.frame();
    w.h.frame();
    assert(w.h.focused is w.a && t.shown && t.text == "Alpha");
    Rect ab = w.a.bounds;
    assert(t.bounds.y >= ab.y + ab.h - 0.5, "below the node");
    assert(abs(t.bounds.x - ab.x) <= 0.5);
    w.h.injectKey(Key.tab);
    w.h.frame();
    w.h.frame();
    assert(w.h.focused is w.b && t.text == "Beta");
    w.h.injectKey('x');
    w.h.frame();
    assert(t.shown == false, "key");
    w.h.injectKey(Key.tab);
    w.h.frame();
    w.h.frame();
    assert(w.h.focused is w.a && t.text == "Alpha");
    hoverOn(w.h, w.b);
    assert(t.text == "Beta", "the pointer took over");
    w.a.setTooltip(null);
    hoverOn(w.h, w.plain);
    w.h.injectKey(Key.tab);
    w.h.injectKey(Key.tab);
    w.h.frame();
    w.h.frame();
    assert(w.h.focused is w.a && t.shown == false, "no text");
}
