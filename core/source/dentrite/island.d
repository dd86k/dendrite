/// Islands, retained nodes whose content is an immediate pass or raw backend drawing.
///
/// An island's pass runs inside an effect, so a signal it read marks it dirty. It
/// also runs after input, when its rect moves, or when a widget asked for
/// animation. Otherwise it costs nothing: its layer keeps the last pass's mesh.
/// Each island owns its `Ui`, so IDs and per-ID memory are private to it. The island holds the window's focus
/// for its controls: Tab goes through the stops its last pass declared, and keys go to the pass.
module dentrite.island;

import core.time : MonoTime;
import dentrite.access : AccessActions, AccessContent, AccessFocus, accessIdOf;
import dentrite.draw;
import dentrite.immediate;
import dentrite.node;
import dentrite.signals : Effect, effect;
import std.algorithm.comparison : min;
import std.math : isInfinity;

/// Look of an island.
struct IslandStyle
{
    enum section = "island"; /// section name in theme files
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff); /// ring around an island focused without a focused control
    float radius = 3;                            /// ring corner radius
}

/// Node running an immediate pass in its rect.
final class Island : Node, Updatable, FocusScope, Composer, AccessContent, AccessFocus, AccessActions
{
    Ui ui;                      /// immediate context, created on first attach
    void delegate(Ui) content;  /// function run on every immediate pass
    bool dirty = true;          /// needs a pass before the next paint
    int passes;                 /// passes run so far
    private Effect tracker;     /// fires when a signal read by the last pass changes
    private Rect lastRect;      /// bounds of the last pass
    float naturalW = 0;         /// width where the parent leaves it open
    float naturalH = 0;         /// height where the parent leaves it open

    /// Creates an island running `content`.
    this(void delegate(Ui) content)
    {
        this.content = content;
        interactive = true;
        focusable = true;
        textInput = true;
        repaintBoundary = true;
    }

    /// Fills whatever space the parent offers, and takes its natural size on an axis left open.
    protected override Size performLayout(Constraints c)
    {
        Size s = c.constrain(Size(isInfinity(c.maxW) ? naturalW : c.maxW, isInfinity(c.maxH) ? naturalH : c.maxH));
        debug
        {
            assert(s.w > 0 || isInfinity(c.maxW) == false, "island in an open width with no w, give it w: or wrap "
                ~ "it in expanded or sized");
            assert(s.h > 0 || isInfinity(c.maxH) == false, "island in an open height with no h, give it h: or wrap "
                ~ "it in expanded or sized");
        }
        return s;
    }

    /// Registers for updates and makes the context.
    override void onAttach()
    {
        if (ui is null)
        {
            ui = new Ui(tree);
            ui.accessSalt = accessIdOf(this);
        }
        ui.window = tree;
        ui.wake = &poke;
        tree.addUpdater(this);
        dirty = true;
    }

    /// Unregisters, stops tracking signals and closes the popups its controls opened.
    override void onDetach()
    {
        ui.closePopups();
        ui.window = null;
        tree.removeUpdater(this);
        if (tracker !is null)
        {
            tracker.dispose();
            tracker = null;
        }
    }

    /// Runs the pass if dirty or moved, re-tracking the signals it reads, then passes on the keys it did not take.
    void update()
    {
        Services sv = tree.services;
        bool ring = ui.focused && sv !is null && sv.focusVisible;
        if (ring != ui.ringVisible)
        {
            ui.ringVisible = ring;
            dirty = true;
        }
        Rect r = bounds;
        if (r != lastRect)
        {
            dirty = true;
        }
        if (dirty == false)
        {
            return;
        }
        dirty = false;
        lastRect = r;
        ++passes;
        ui.tree.theme = tree.theme;
        ui.services = sv;
        ui.now = tree.services is null ? MonoTime.currTime : tree.services.now;
        if (tracker !is null)
        {
            tracker.dispose();
        }
        bool first = true;
        tracker = effect(() {
            if (first == false)
            {
                dirty = true;
                markNeedsPaint();
                return;
            }
            first = false;
            ui.frame(content, r);
        });
        hiddenText = ui.hiddenText;
        invalidateLayer();
        if (ui.frameWanted)
        {
            dirty = true;
            markNeedsPaint();
        }
        else if (ui.wakeAt != MonoTime.max)
        {
            tree.callAt(this, ui.wakeAt, &poke);
        }
        KeyEvent[] left = ui.unused;
        ui.unused = null;
        foreach (KeyEvent k; sv is null ? null : left)
        {
            sv.passKey(this, k);
        }
    }

    /// Forces a pass on the next update.
    void invalidate()
    {
        dirty = true;
    }

    /// Replays the last pass, clipped to the island, with a ring inside its edge when it has focus and no
    /// control does.
    override void paint(ref PaintContext ctx, Point origin)
    {
        Rect b = Rect(origin.x, origin.y, size.w, size.h);
        ctx.clipped(b, { ctx.list.append(ui.output); });
        if (focusRing && ui.focus == 0)
        {
            IslandStyle s = ctx.style!IslandStyle();
            ctx.list.rect(b, Color.init, s.radius, s.focus, 1);
        }
    }

    /// Feeds pointer state to the context and schedules a pass.
    override bool onPointer(ref const PointerEvent e)
    {
        ui.mouse = e.pos;
        final switch (e.kind)
        {
        case PointerKind.down:
            if (e.button == 1)
            {
                ui.pressed = true;
                ui.down = true;
                ui.clicks = e.clicks;
                ui.mods = e.mods;
            }
            break;
        case PointerKind.up:
            if (e.button == 1)
            {
                ui.down = false;
                ui.released = true;
            }
            break;
        case PointerKind.cancel:
            ui.down = false;
            ui.mouse = Point(-1e9, -1e9);
            break;
        case PointerKind.leave:
            ui.mouse = Point(-1e9, -1e9);
            break;
        case PointerKind.move:
        case PointerKind.enter:
            break;
        }
        poke();
        return true;
    }

    /// Wheel distance for the next pass.
    override bool onWheel(ref const WheelEvent e)
    {
        ui.wheelY += e.dy;
        ui.mouse = e.pos;
        poke();
        return true;
    }

    /// Keys for the next pass, which passes on the ones it does not take. Tab is not taken: it closes the popups
    /// the controls opened, such as a combo box list, and moves focus.
    override bool onKey(ref const KeyEvent e)
    {
        if (e.key == Key.tab)
        {
            ui.closePopups();
            poke();
            return false;
        }
        ui.addKey(e);
        poke();
        return true;
    }

    /// Text for the next pass.
    override bool onText(string s)
    {
        ui.composing = null;
        ui.addText(s);
        poke();
        return true;
    }

    /// Opens the context menu of the innermost area holding `p`, or for the menu key the focused control.
    override bool onContextMenu(Point p, bool keyboard)
    {
        if (keyboard)
        {
            Rect f = focusRect();
            p = Point(f.x, f.y + min(f.h, 32f));
        }
        return ui.openContextMenu(p, keyboard);
    }

    /// Focuses the first control on Tab, or the last on Shift+Tab.
    void enterFocus(bool backward)
    {
        ui.enterFocus(backward);
        poke();
    }

    /// Moves to the next or previous control, false at the end.
    bool stepFocus(bool backward)
    {
        if (ui.stepFocus(backward) == false)
        {
            return false;
        }
        poke();
        return true;
    }

    /// Rect of the focused control as laid out last pass, or the island's bounds.
    Rect focusRect()
    {
        Rect r = ui.lastRect(ui.focus);
        return ui.focus == 0 || r.w <= 0 ? bounds : r;
    }

    /// Focus changes show in the next pass.
    override void onFocus(bool gained)
    {
        ui.focused = gained;
        ui.composing = null;
        poke();
    }

    /// Input method text for the focused text box, null to clear.
    void compose(string text, size_t from, size_t to)
    {
        ui.composing = text;
        ui.composeFrom = from;
        ui.composeTo = to;
        poke();
    }

    /// Caret of the focused text box as last painted, or the focused control.
    Rect caretRect()
    {
        return ui.caret.h > 0 ? ui.caret : focusRect();
    }

    /// A group of the controls its last pass declared.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.group;
    }

    /// Root of the last pass.
    Node accessContent()
    {
        return ui is null ? null : ui.content;
    }

    /// Control with focus as of the last pass, or null.
    Node accessFocus()
    {
        return ui is null || ui.focus == 0 ? null : ui.nodeOf(ui.focus);
    }

    /// Clicks, focuses or steps the control of the last pass that `n` shows, or opens the context menu of the
    /// area holding `n`. Steps are the arrow keys.
    bool accessActionFor(Node n, ref const AccessRequest r)
    {
        if (r.action == AccessAction.showContextMenu)
        {
            Rect b = n.bounds;
            return ui.openContextMenu(Point(b.x, b.y + min(b.h, 32f)), Point(b.x + b.w / 2, b.y + b.h / 2), true);
        }
        Id i = ui.idOf(n);
        if (i == 0)
        {
            return false;
        }
        switch (r.action)
        {
        case AccessAction.click:
            ui.accessClick = i;
            break;
        case AccessAction.focus:
            focusControl(i);
            break;
        case AccessAction.increment:
        case AccessAction.decrement:
            focusControl(i);
            ui.addKey(KeyEvent(r.action == AccessAction.increment ? Key.right : Key.left));
            break;
        default:
            return false;
        }
        poke();
        return true;
    }

    /// Gives control `i` the focus, and the island the window's.
    private void focusControl(Id i)
    {
        ui.focus = i;
        if (tree.services !is null)
        {
            tree.services.setFocus(this);
        }
    }

    /// Marks the island for a pass and asks for a frame.
    private void poke()
    {
        dirty = true;
        markNeedsPaint();
    }
}

/// Island over `content`: `island((Ui ui) { ... })`. It fills the space it is offered. `w` and `h` are its size
/// where the parent leaves an axis open, as a column does for height. An island with neither on an open axis
/// asserts in debug builds.
Island island(void delegate(Ui) content, float w = 0, float h = 0)
{
    Island i = new Island(content);
    i.naturalW = w;
    i.naturalH = h;
    return i;
}

/// Raw island: hands its rect to backend code through a custom draw, for 3D views.
/// The GL renderer calls `draw` every frame, also when the view's layer is reused. The software renderer
/// leaves the area empty.
final class RawView : Node, Updatable
{
    CustomDraw draw;   /// backend callback, given its rect in physical pixels
    bool animating;    /// ask for a frame after every frame
    int paints;        /// paints so far

    /// Creates a raw view drawing with `draw`.
    this(CustomDraw draw, bool animating)
    {
        this.draw = draw;
        this.animating = animating;
        interactive = true;
        repaintBoundary = true;
    }

    /// Registers for updates.
    override void onAttach()
    {
        tree.addUpdater(this);
    }

    /// Unregisters.
    override void onDetach()
    {
        tree.removeUpdater(this);
    }

    /// Asks for the next frame while animating.
    void update()
    {
        if (animating && tree.services !is null)
        {
            tree.services.requestFrame();
        }
    }

    /// Nothing to redo.
    void invalidate()
    {
    }

    /// Fills whatever space the parent offers.
    protected override Size performLayout(Constraints c)
    {
        return Size(isInfinity(c.maxW) ? c.minW : c.maxW, isInfinity(c.maxH) ? c.minH : c.maxH);
    }

    /// Emits the custom draw.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ++paints;
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        ctx.clipped(r, { ctx.list.custom(r, draw); });
    }
}

// An island re-runs on a signal it read, on input, or when moved, and replays its output otherwise.
unittest
{
    import dentrite.containers : column, expanded;
    import dentrite.signals : signal, Signal;

    Signal!int value = signal(1);
    Signal!int other = signal(1);
    int seen;
    Island isl = island((Ui ui) {
        seen = value.get;
        ui.expand({ ui.canvas((ref PaintContext c, Rect r) { c.list.rect(r, Color(1, 2, 3, 255)); }); });
    });
    Fixed header = new Fixed(Size(0, 20));
    Tree t = new Tree(null, null, null);
    t.viewport = Size(100, 100);
    t.setRoot(column()(header, expanded(isl)));
    t.flush();
    foreach (Updatable u; t.updaters)
    {
        u.update();
    }
    assert(isl.passes == 1 && seen == 1);
    assert(isl.ui.output.cmds.length == 3 && isl.ui.output.cmds[1].r == Rect(0, 20, 100, 80), "clip, rect, pop");

    isl.update();
    other.set(2);
    isl.update();
    assert(isl.passes == 1, "idle, and deaf to signals it did not read");
    value.set(5);
    assert(isl.dirty && isl.passes == 1, "marked, pass waits for the frame");
    isl.update();
    assert(isl.passes == 2 && seen == 5);

    PointerEvent e = PointerEvent(PointerKind.move, Point(10, 30));
    isl.onPointer(e);
    isl.update();
    assert(isl.passes == 3);

    header.want = Size(0, 30);
    header.markNeedsLayout();
    t.flush();
    isl.update();
    assert(isl.passes == 4 && isl.ui.output.cmds[1].r == Rect(0, 30, 100, 70), "moved");
}

// Keys a focused island's pass does not take go on to its parents and the window.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.command : Command, command, shortcuts;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(200, 100), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int downs;
    int runs;
    Command run = command("Run", () { ++runs; }, keys: "F5");
    Island isl = island((Ui ui) {
        if (ui.takeKey(Key.down))
        {
            ++downs;
        }
    });
    h.setRoot(shortcuts([run], window: true)(isl));
    h.frame();
    h.setFocus(isl);
    h.injectKey(Key.down);
    h.injectKey(Key.f5);
    h.frame();
    assert(downs == 1 && runs == 1);
}

// Tab goes through the island's controls between the nodes around it, Shift+Tab enters at the last, a radio
// group is one stop with arrows inside, keys reach the focused control, a press on empty space focuses the
// island itself, and a control that goes away gives focus back to the island.
unittest
{
    import dentrite.containers : column, expanded;
    import dentrite.host : Host;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.checkbox : checkbox;
    import dentrite.widgets.menu : clickOn, menuHost;
    import dentrite.widgets.radio : radio;
    import dentrite.widgets.slider : slider;

    Host h = menuHost(300, 300);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    bool on;
    int pick;
    int level = 5;
    bool showBox = true;
    Island isl = island((Ui ui) {
        if (ui.button("Go"))
        {
            ++clicks;
        }
        if (showBox)
        {
            ui.checkbox(on, "On");
        }
        ui.radio(pick, 0, "A");
        ui.radio(pick, 1, "B", enabled: false);
        ui.radio(pick, 2, "C");
        ui.slider(level, 0, 10, 1);
    });
    Button before = button("Before");
    Button after = button("After");
    h.setRoot(column()(before, expanded(isl), after));
    h.frame();
    void key(uint k, ubyte mods = 0)
    {
        h.injectKey(k, mods);
        h.frame();
    }

    h.setFocus(before);
    key(Key.tab);
    assert(h.focused is isl && isl.ui.focus != 0 && h.focusVisible);
    Rect go = isl.focusRect;
    key(Key.space);
    key(Key.enter);
    assert(clicks == 2);
    key(Key.tab);
    Rect box = isl.focusRect;
    assert(box.y > go.y, "the checkbox, below the button");
    key(Key.space);
    assert(on);
    key(Key.tab);
    key(Key.down);
    assert(pick == 2, "the disabled radio is skipped");
    key(Key.down);
    assert(pick == 0, "and the group wraps");
    key(Key.tab);
    key(Key.right);
    key(Key.pageUp);
    assert(level == 7);
    key(Key.end);
    assert(level == 10);
    Rect sl = isl.focusRect;
    h.injectWheel(Point(sl.x + sl.w / 2, sl.y + sl.h / 2), 48);
    h.frame();
    assert(level == 9, "the wheel steps the focused slider");
    key(Key.end);
    key(Key.tab);
    assert(h.focused is after, "the group was one stop, the slider the last");
    key(Key.tab, Mod.shift);
    assert(h.focused is isl);
    key(Key.home);
    assert(level == 0, "Shift+Tab enters at the slider");
    key(Key.tab, Mod.shift);
    key(Key.tab, Mod.shift);
    assert(isl.focusRect == box);
    key(Key.tab, Mod.shift);
    key(Key.tab, Mod.shift);
    assert(h.focused is before);

    clickOn(h, isl);
    h.frame();
    assert(h.focused is isl && isl.ui.focus == 0, "empty space focuses the island itself");
    h.inject(PointerKind.move, Point(box.x + 4, box.y + box.h / 2));
    h.inject(PointerKind.down, Point(box.x + 4, box.y + box.h / 2));
    h.inject(PointerKind.up, Point(box.x + 4, box.y + box.h / 2));
    h.frame();
    assert(on == false && isl.focusRect == box && h.focusVisible == false, "a click focuses without a ring");
    showBox = false;
    isl.invalidate();
    h.frame();
    assert(h.focused is isl && isl.ui.focus == 0);
    key(Key.tab);
    assert(isl.focusRect == go, "Tab from the island itself goes to its first control");
}

// An island focused by Tab without a focused control shows a ring inside its edge, one focused by a click
// or holding a focused control does not.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column, expanded;
    import dentrite.host : Host;
    import dentrite.theme : Theme;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(300, 300);
    scope (exit)
    {
        h.close();
    }
    h.tree.theme = new Theme("[island]\nfocus = #ff0000\n", "test");
    bool showGo;
    Island isl = island((Ui ui) {
        if (showGo)
        {
            ui.button("Go");
        }
    });
    Button before = button("Before");
    h.setRoot(column()(before, expanded(isl), button("After")));
    h.frame();
    SoftwareRenderer r = cast(SoftwareRenderer) h.renderer;
    /// True if the left edge of the island, halfway down, is the ring color.
    bool ring()
    {
        Rect b = isl.bounds;
        return r.pixels[cast(int) (b.y + b.h / 2) * r.width + cast(int) b.x] == 0xff0000ff;
    }

    void key(uint k)
    {
        h.injectKey(k);
        h.frame();
    }

    h.setFocus(before);
    key(Key.tab);
    assert(h.focused is isl && isl.ui.focus == 0 && ring(), "Tab into an island without stops");
    key(Key.tab);
    assert(h.focused !is isl && ring() == false, "the ring goes with the focus");
    clickOn(h, isl);
    assert(h.focused is isl && ring() == false, "a click shows no ring");
    showGo = true;
    isl.invalidate();
    h.frame();
    h.setFocus(before);
    key(Key.tab);
    assert(h.focused is isl && isl.ui.focus != 0 && ring() == false, "the focused control has the ring");
    showGo = false;
    isl.invalidate();
    h.frame();
    assert(isl.ui.focus == 0 && ring(), "a control that goes away leaves the ring on the island");
}

// A popup opened from an island control sits next to it, follows it when the pass moves it, and closes when a
// pass skips the control or the island leaves the window.
unittest
{
    import dentrite.host : Host;
    import dentrite.overlay : Popup, popup;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(300, 300);
    scope (exit)
    {
        h.close();
    }
    Popup p = popup()(new Fixed(Size(50, 30)));
    Signal!float above = signal(10f);
    Signal!bool shown = signal(true);
    Id at;
    Island isl = island((Ui ui) {
        ui.canvas(null, 10, above.get);
        if (shown.get)
        {
            CanvasState c = ui.canvas(null, 40, 20);
            at = c.id;
            if (c.press.pressedNow)
            {
                ui.openPopup(c.id, p);
            }
        }
    });
    h.setRoot(isl);
    h.frame();

    /// Rect of the control as last laid out.
    Rect control()
    {
        return isl.ui.lastRect(at);
    }

    /// Presses the control.
    void press()
    {
        Rect r = control();
        Point c = Point(r.x + r.w / 2, r.y + r.h / 2);
        h.inject(PointerKind.move, c);
        h.inject(PointerKind.down, c);
        h.inject(PointerKind.up, c);
        h.frame();
    }

    press();
    assert(p.isOpen && p.bounds.y == control.bottom && p.bounds.x == control.x, "below the control");
    above.set(50);
    h.frame();
    assert(control.y == 50 && p.bounds.y == control.bottom, "followed the control");
    shown.set(false);
    h.frame();
    assert(p.isOpen == false, "closed when the pass skipped the control");
    shown.set(true);
    h.frame();
    press();
    assert(p.isOpen);
    h.setRoot(new Fixed(Size(10, 10)));
    h.frame();
    assert(p.isOpen == false, "closed when the island left");
}

// An island takes `h` in a column, which leaves height open, and fills the width it is offered.
unittest
{
    import dentrite.containers : column, row;

    Island isl = island((Ui ui) {}, h: 60);
    Island wide = island((Ui ui) {}, w: 30, h: 40);
    Tree t = new Tree(null, null, null);
    t.viewport = Size(100, 200);
    t.setRoot(column()(isl, row()(wide)));
    t.flush();
    assert(isl.size == Size(100, 60) && wide.size == Size(30, 40));
}
