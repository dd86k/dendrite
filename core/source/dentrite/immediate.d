/// Immediate-mode core for islands: declare a tree per pass, lay it out with box constraints,
/// hit-test against the previous pass's rects.
///
/// Grown from research/examples/immediate.d. Nodes are the retained tree's own classes, so
/// islands share layout, theme and renderer with the rest of the window. `Ui` holds
/// only primitives. Widgets are free functions over `Ui` in their component modules,
/// called through UFCS. NOTE: a `Ui` member named like a widget would hide it.
/// A pass that handled input is built again before painting, so the frame shows the result.
module dentrite.immediate;

import core.time : MonoTime;
import dentrite.access : mixId;
import dentrite.containers;
import dentrite.draw;
import dentrite.node;
import dentrite.overlay : Popup, Side;
import dentrite.signals : runWithOwner;
import std.math : isInfinity, isNaN;

/// Widget identity, stable across passes.
alias Id = ulong;

/// Pointer state of a widget this pass, from `Ui.clickable`.
struct Press
{
    bool hovered;       /// pointer over it as laid out last pass
    bool held;          /// primary button held, pressed on it
    bool clicked;       /// primary button released over it this pass, after a press on it
    bool pressedNow;    /// primary button went down over it this pass
    bool doubleClicked; /// second click of a double click
}

/// Node whose rect is recorded under `id` at the end of the pass.
private struct Tracked
{
    Node node; /// declared node
    Id id;     /// its widget ID
}

/// Tab stop declared this pass.
private struct Stop
{
    Id id;       /// its widget ID
    size_t group; /// radio group it belongs to, 0 for none
    bool chosen; /// the chosen member of its group
}

/// Key presses and the text typed before them, for one pass.
private struct Input
{
    KeyEvent[] keys; /// key presses
    string typed;     /// text typed before them
}

/// Area with a context menu, from `Ui.contextArea`.
private struct ContextArea
{
    Id id; /// the area's ID
    bool delegate(Point p, bool keyboard) open; /// opens the menu at window point `p`, true if it did
}

/// Per-ID memory entry. Values with a `dropped` method hear when a pass skips their ID.
private class Memo
{
    /// Runs when a pass skipped the ID.
    void dropped()
    {
    }
}

/// Leaf painted by a callback with its laid-out rect, for custom controls. Paint outside the rect is clipped.
final class Canvas : Node
{
    float w; /// wanted width, NaN to fill
    float h; /// wanted height, NaN to fill
    void delegate(ref PaintContext ctx, Rect r) painter; /// paints the content

    /// Creates a canvas.
    this(float w, float h, void delegate(ref PaintContext, Rect) painter)
    {
        this.w = w;
        this.h = h;
        this.painter = painter;
    }

    /// Wanted size, or as much as allowed.
    protected override Size performLayout(Constraints c)
    {
        float fw = isNaN(w) ? (isInfinity(c.maxW) ? c.minW : c.maxW) : w;
        float fh = isNaN(h) ? (isInfinity(c.maxH) ? c.minH : c.maxH) : h;
        return Size(fw, fh);
    }

    /// Calls the painter, clipped to the rect so rows scrolled partly out stay inside.
    override void paint(ref PaintContext ctx, Point origin)
    {
        if (painter !is null)
        {
            Rect r = Rect(origin.x, origin.y, size.w, size.h);
            ctx.clipped(r, { painter(ctx, r); });
        }
    }
}

/// Group options from `row` and `column`, waiting for the children.
struct Group
{
    private Ui ui;            /// context to declare into
    private Axis axis;        /// main axis
    private float gap;        /// space between children
    private CrossAlign cross; /// cross-axis placement

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Ui ui, Axis axis, float gap, CrossAlign cross)
    {
        this.ui = ui;
        this.axis = axis;
        this.gap = gap;
        this.cross = cross;
    }

    /// Declares the container with `children` inside.
    void opCall(scope void delegate() children)
    {
        Flex n = new Flex(axis, gap, cross, null);
        ui.put(n);
        ui.inside(n, children);
    }
}

/// Style edit from `Ui.withStyle`, waiting for the children.
struct StyleScope(T)
{
    private Ui ui;                     /// context
    private void delegate(ref T) edit; /// applied to every `T` read inside

    /// Stores the edit. Needed because `opCall` hides the struct literal.
    this(Ui ui, void delegate(ref T) edit)
    {
        this.ui = ui;
        this.edit = edit;
    }

    /// Declares `children` with the edit in effect.
    void opCall(scope void delegate() children)
    {
        Ui.Edits!T stack = ui.editsOf!T();
        stack.items ~= edit;
        scope (exit)
        {
            stack.items.length -= 1;
            stack.items.assumeSafeAppend();
        }
        children();
    }
}

/// Immediate-mode context of one island.
final class Ui
{
    Point mouse = Point(-1e9, -1e9); /// pointer, window coordinates
    bool pressed;     /// primary button went down since the last pass
    bool released;    /// primary button went up since the last pass
    bool down;        /// primary button held
    ubyte clicks;     /// click count of the last press
    ubyte mods;       /// `Mod` flags held at the last press
    float wheelY = 0; /// wheel distance since the last pass, positive scrolls content up
    KeyEvent[] keys;  /// key presses since the last pass, while focused
    KeyEvent[] unused; /// key presses the last frame's passes did not take
    string typed;     /// text typed since the last pass, while focused
    bool focused;     /// the island has keyboard focus
    bool ringVisible; /// focus last moved by keyboard, so the focused control shows a ring
    Id focus;         /// control with focus inside the island, 0 for the island itself
    MonoTime now;     /// time of this pass
    Rect area;        /// island rect this pass
    Tree tree;        /// layout tree sharing the window's text and theme
    DrawList output;  /// painted result of the last pass
    bool again;       /// a widget handled input this pass, build again before painting
    bool frameWanted; /// a widget wants another pass next frame, for animation
    MonoTime wakeAt = MonoTime.max; /// a widget wants a pass at this time, for blinking
    Services services; /// window services such as the clipboard, null without a window
    string composing;  /// input method text for the focused text box, null for none
    size_t composeFrom; /// byte offset into `composing` where the part being converted starts
    size_t composeTo;  /// byte offset into `composing` where that part ends, also the caret
    Rect caret;        /// caret of the focused text box as last painted, empty for none
    bool hiddenText;   /// the focused text box is a password
    ulong accessSalt;  /// mixed into the access ids of this pass's nodes, unique per island
    Id accessClick;    /// control an assistive technology clicked, taken by its next `clickable`
    Tree window;       /// the window's tree, where popups open, null without an island in a window
    void delegate() wake; /// asks for a pass from outside one, as a popup does after a pick, null without an island

    private Node root;              /// this pass's tree
    private Node[] open;            /// containers being declared
    private Id[] idStack;           /// pushed keys, innermost last
    private Tracked[] tracked;      /// nodes that need their rect recorded
    private Rect[Id] lastRects;     /// rects from the previous pass
    private Rect[Id] rects;         /// rects from this pass
    private Memo[Id] memory;        /// per-ID state that survives passes
    private int[Id] memoryUsed;     /// pass each memory entry was last used in
    private Id pressedOn;           /// widget the primary button went down on, 0 for none
    private int pass;               /// passes so far
    private Object[string] edits;   /// `Edits!T` by `T.mangleof`, from `withStyle`
    private Stop[] stops;           /// Tab stops of this pass, in order
    private Stop[] lastStops;       /// Tab stops of the previous pass
    private bool pressFocused;      /// a stop took focus from this pass's press
    private Id stepFrom;            /// stop that asked `stepGroup` this pass, 0 for none
    private int stepDir;            /// direction asked by `stepGroup`
    private Id stepped;             /// stop moved to by `stepGroup`, picked on the next pass
    private ulong accessSeq;        /// nodes put this pass, for access ids of untracked nodes
    private Input[] queued;        /// input that came after a key press of `keys`, run by later passes
    private Popup[Id] popups;       /// open popups by the control they belong to
    private ContextArea[] areas;    /// context menu areas of this pass
    private ContextArea[] lastAreas; /// context menu areas of the last pass
    private Node nextLabel;         /// label naming the next tracked node, from `labelNext`, or null
    private bool labelClicked;      /// that label was clicked, so the next Tab stop takes focus

    /// Scoped edits of style `T`, innermost last.
    private static final class Edits(T)
    {
        void delegate(ref T)[] items; /// edits in effect
    }

    /// Most build passes per frame. A view still changing state after that shows it next frame.
    enum maxPasses = 4;

    /// Creates a context laying out with `outer`'s text and theme.
    this(Tree outer)
    {
        tree = new Tree(outer.text, outer.theme, null);
    }

    /// Runs `view` in `area`, again while it handles input, then lays out and paints into `output`.
    /// Input is spent after the first pass. Text typed after a key press waits for a later pass, so a pass
    /// never sees text that came after its keys. Input left after `maxPasses` asks for another frame.
    void frame(scope void delegate(Ui) view, Rect area)
    {
        this.area = area;
        frameWanted = false;
        wakeAt = MonoTime.max;
        caret = Rect.init;
        unused = null;
        begin();
        foreach (int i; 1 .. maxPasses + 1)
        {
            hiddenText = false;
            view(this);
            settleStep();
            if ((again == false && queued.length == 0) || i == maxPasses)
            {
                break;
            }
            spendInput();
            begin();
        }
        end();
        spendInput();
        frameWanted = frameWanted || keys.length > 0 || typed.length > 0;
    }

    /// Adds a key press for a pass, after any text typed before it.
    void addKey(KeyEvent e)
    {
        if (queued.length > 0)
        {
            queued[$ - 1].keys ~= e;
        }
        else
        {
            keys ~= e;
        }
    }

    /// Adds typed text for a pass, after any key pressed before it.
    void addText(string s)
    {
        if (queued.length > 0)
        {
            if (queued[$ - 1].keys.length > 0)
            {
                queued ~= Input(null, s);
            }
            else
            {
                queued[$ - 1].typed ~= s;
            }
        }
        else if (keys.length > 0)
        {
            queued ~= Input(null, s);
        }
        else
        {
            typed ~= s;
        }
    }

    /// Clears per-pass input so the next pass does not handle it twice.
    private void spendInput()
    {
        if (pressed && pressFocused == false)
        {
            focus = 0;
        }
        pressFocused = false;
        unused ~= keys;
        pressed = false;
        released = false;
        wheelY = 0;
        keys = null;
        typed = null;
        if (queued.length > 0)
        {
            keys = queued[0].keys;
            typed = queued[0].typed;
            queued = queued[1 .. $];
        }
    }

    /// Starts a build pass with a stretching column as the root.
    private void begin()
    {
        ++pass;
        again = false;
        Flex body = new Flex(Axis.vertical, 0, CrossAlign.stretch, null);
        root = body;
        open = [body];
        tracked.length = 0;
        tracked.assumeSafeAppend();
        stops.length = 0;
        stops.assumeSafeAppend();
        rects = null;
        accessSeq = 0;
        areas.length = 0;
        nextLabel = null;
        labelClicked = false;
        areas.assumeSafeAppend();
    }

    /// Lays out at the area, records rects, paints and drops unused memory.
    private void end()
    {
        tree.viewport = Size(area.w, area.h);
        tree.setRoot(root);
        tree.flush();
        root.offset = area.pos;
        foreach (Tracked t; tracked)
        {
            rects[t.id] = t.node.bounds;
        }
        lastRects = rects;
        if (focus != 0 && indexOfStop(stops, focus) < 0)
        {
            focus = 0;
        }
        Stop[] swap = lastStops;
        lastStops = stops;
        stops = swap;
        ContextArea[] swapAreas = lastAreas;
        lastAreas = areas;
        areas = swapAreas;
        stepped = 0;
        output.clear();
        PaintContext ctx = PaintContext(&output, area, tree);
        root.paint(ctx, area.pos);
        runWithOwner(null, {
            followPopups();
            foreach (Id id; memoryUsed.keys)
            {
                if (memoryUsed[id] != pass)
                {
                    Memo m = memory[id];
                    memory.remove(id);
                    memoryUsed.remove(id);
                    m.dropped();
                }
            }
        });
        if (down == false)
        {
            pressedOn = 0;
        }
    }

    /// ID of the call site at `file` and `line`, hashed (FNV-1a) with the keys pushed by `pushId`.
    Id id(string file, size_t line)
    {
        Id h = 0xcbf2_9ce4_8422_2325;
        void mix(const(ubyte)[] bytes)
        {
            foreach (ubyte b; bytes)
            {
                h = (h ^ b) * 0x100_0000_01b3;
            }
        }

        foreach (Id k; idStack)
        {
            mix((cast(const(ubyte)*) &k)[0 .. Id.sizeof]);
        }
        mix(cast(const(ubyte)[]) file);
        mix((cast(const(ubyte)*) &line)[0 .. size_t.sizeof]);
        return h;
    }

    /// Scopes following IDs by `key`, for loop bodies.
    void pushId(Id key)
    {
        idStack ~= key;
    }

    /// Ends the innermost `pushId`.
    void popId()
    {
        idStack.length -= 1;
        idStack.assumeSafeAppend();
    }

    /// Persistent state of type `T` for `id`, created from `init` on first use. A `T` with a `dropped` method
    /// hears when a pass skips `id`, as an island widget holding retained nodes closes them.
    T* memoryFor(T)(Id id, T init)
    {
        static final class Box : Memo
        {
            T value; /// stored state

            /// Passes the news on to the value if it listens.
            override void dropped()
            {
                static if (__traits(hasMember, T, "dropped"))
                {
                    value.dropped();
                }
            }
        }

        memoryUsed[id] = pass;
        if (Memo* o = id in memory)
        {
            Box found = cast(Box) *o;
            assert(found !is null, "per-ID memory reused with another type, IDs collide");
            return &found.value;
        }
        Box b = new Box;
        b.value = init;
        memory[id] = b;
        return &b.value;
    }

    /// Persistent state for the call site at `file` and `line`: `int* n = ui.memoryFor(0, file, line)` in an
    /// island function taking its caller's file and line.
    T* memoryFor(T)(T init, string file = __FILE__, size_t line = __LINE__)
    {
        return memoryFor!T(id(file, line), init);
    }

    /// Rect of `id` as laid out last pass, or an empty rect.
    Rect lastRect(Id id)
    {
        Rect* r = id in lastRects;
        return r is null ? Rect.init : *r;
    }

    /// True if the pointer is over `id` as laid out last pass.
    bool hovered(Id id)
    {
        Rect* r = id in lastRects;
        return r !is null && r.contains(mouse);
    }

    /// Adds `n` to the open container.
    void put(Node n)
    {
        n.accessId = accessIdFor(++accessSeq);
        open[$ - 1].add(n);
    }

    /// Runs `children` with `n` as the open container.
    void inside(Node n, scope void delegate() children)
    {
        open ~= n;
        if (children !is null)
        {
            children();
        }
        open.length -= 1;
        open.assumeSafeAppend();
    }

    /// The single node declared by `child`, not yet attached.
    Node one(scope void delegate() child)
    {
        Fixed scratch = new Fixed(Size.init);
        inside(scratch, child);
        assert(scratch.children.length == 1, "exactly one child expected");
        Node n = scratch.children[0];
        scratch.setChildren(null);
        return n;
    }

    /// Records the rect of `n` under `id` at the end of the pass, for `hovered` and `clickable`, and gives it a label
    /// pending from `labelNext`.
    void track(Node n, Id id)
    {
        n.accessId = accessIdFor(id);
        if (nextLabel !is null)
        {
            if (n.labelledBy is null)
            {
                n.labelledBy = nextLabel;
            }
            nextLabel = null;
            labelClicked = false;
        }
        tracked ~= Tracked(n, id);
    }

    /// Makes `label` name the next node tracked this pass for screen readers, and when `clicked` focuses the next
    /// Tab stop, as an island label with `forNext` does. Null drops a pending one.
    void labelNext(Node label, bool clicked)
    {
        nextLabel = label;
        labelClicked = label !is null && clicked;
    }

    /// Access id of key `k` in this island. The top bit keeps it apart from the ids of retained nodes.
    private ulong accessIdFor(ulong k)
    {
        return mixId(k, accessSalt) | 1UL << 63;
    }

    /// Root of the last pass, or null before the first.
    Node content()
    {
        return root;
    }

    /// Node tracked under `id` in the last pass, or null.
    Node nodeOf(Id id)
    {
        foreach (Tracked t; tracked)
        {
            if (t.id == id)
            {
                return t.node;
            }
        }
        return null;
    }

    /// Id `n` was tracked under in the last pass, or 0.
    Id idOf(Node n)
    {
        foreach (Tracked t; tracked)
        {
            if (t.node is n)
            {
                return t.id;
            }
        }
        return 0;
    }

    /// Opens `p` in the window next to control `id` as last laid out, on `side`, then keeps it as `keepPopup`
    /// does. Does nothing without a window.
    void openPopup(Id id, Popup p, Side side = Side.below)
    {
        if (window is null)
        {
            return;
        }
        Rect r = lastRect(id);
        runWithOwner(null, {
            p.anchor = null;
            p.side = side;
            p.openAt(window, r);
        });
        keepPopup(id, p);
    }

    /// Ties open popup `p` to control `id`: it moves with the control, and closes when a pass skips `id` or the
    /// island leaves the window. `p` opens at a rectangle, as `Popup.openAt` and `Menu.openAt` do.
    void keepPopup(Id id, Popup p)
    {
        popups[id] = p;
    }

    /// True if `p` is open and tied to control `id`, as a menu button shows its menu open.
    bool keeps(Id id, Popup p)
    {
        Popup* q = id in popups;
        return q !is null && *q is p && p.isOpen;
    }

    /// Moves kept popups to their control's rect of this pass, and closes those whose control is gone.
    private void followPopups()
    {
        foreach (Id id, Popup p; popups.dup)
        {
            Rect* r = id in rects;
            if (p.isOpen && r is null)
            {
                p.close();
            }
            if (p.isOpen == false)
            {
                popups.remove(id);
                continue;
            }
            p.moveTo(*r);
        }
    }

    /// Closes every kept popup, as the island leaves the window.
    void closePopups()
    {
        runWithOwner(null, {
            foreach (Popup p; popups.values)
            {
                p.close();
            }
        });
        popups = null;
    }

    /// Gives area `id` a context menu: `open` runs with the window point of a right press inside the area's last
    /// rect, or of the menu key with focus inside it. Areas declared later, such as inner ones, go first.
    void contextArea(Id id, bool delegate(Point p, bool keyboard) open)
    {
        areas ~= ContextArea(id, open);
    }

    /// Opens at window point `p` the context menu of the last pass's innermost area holding `p`, or for the menu
    /// key the focused control. True if one opened.
    bool openContextMenu(Point p, bool keyboard)
    {
        Rect f = lastRect(focus);
        Point probe = keyboard && focus != 0 ? Point(f.x + f.w / 2, f.y + f.h / 2) : p;
        return openContextMenu(p, probe, keyboard);
    }

    /// Opens at window point `p` the context menu of the last pass's innermost area holding `probe`, with the
    /// first item highlighted when `keyboard`. True if one opened.
    bool openContextMenu(Point p, Point probe, bool keyboard)
    {
        foreach_reverse (ContextArea a; lastAreas)
        {
            if (lastRect(a.id).contains(probe) && a.open(p, keyboard))
            {
                return true;
            }
        }
        return false;
    }

    /// Pointer state of `id` from last pass's rects, none if disabled. A press or click asks for another pass, and
    /// so does a click from `accessClick`.
    Press clickable(Id id, bool enabled = true)
    {
        if (enabled == false)
        {
            return Press.init;
        }
        bool over = hovered(id);
        Press p;
        p.hovered = over;
        if (accessClick == id)
        {
            accessClick = 0;
            p.clicked = true;
            again = true;
        }
        if (over && pressed)
        {
            pressedOn = id;
            p.pressedNow = true;
            p.doubleClicked = clicks >= 2;
            again = true;
        }
        p.held = down && pressedOn == id;
        if (released && pressedOn == id)
        {
            p.clicked = p.clicked || over;
            again = again || over;
        }
        return p;
    }

    /// Makes `id` a Tab stop this pass unless disabled, focused by a press on it, so call it after `clickable`.
    /// `group` is a radio group key and `chosen` its chosen member, which alone takes Tab. True if `id` has focus.
    bool focusStop(Id id, bool enabled = true, size_t group = 0, bool chosen = false)
    {
        if (enabled == false)
        {
            return false;
        }
        stops ~= Stop(id, group, chosen);
        if (labelClicked)
        {
            labelClicked = false;
            focus = id;
            pressFocused = true;
        }
        else if (pressed && pressedOn == id)
        {
            focus = id;
            pressFocused = true;
        }
        return focused && focus == id;
    }

    /// True if `id` has focus moved there by keyboard, so it should show a ring.
    bool focusRing(Id id)
    {
        return focused && ringVisible && focus == id;
    }

    /// Moves focus `dir` stops through the group of `from` after this pass, wrapping, so the stop moved to is
    /// `picked` on the next pass. For arrows in radio groups.
    void stepGroup(Id from, int dir)
    {
        stepFrom = from;
        stepDir = dir;
    }

    /// True once, on the pass after `stepGroup` moved focus to `id`.
    bool picked(Id id)
    {
        if (stepped == 0 || stepped != id)
        {
            return false;
        }
        stepped = 0;
        return true;
    }

    /// Resolves a `stepGroup` request against this pass's stops and asks for another pass.
    private void settleStep()
    {
        if (stepFrom == 0)
        {
            return;
        }
        ptrdiff_t at = indexOfStop(stops, stepFrom);
        stepFrom = 0;
        if (at < 0)
        {
            return;
        }
        size_t[] members;
        size_t self;
        foreach (size_t i, Stop s; stops)
        {
            if (s.group == stops[at].group)
            {
                if (i == at)
                {
                    self = members.length;
                }
                members ~= i;
            }
        }
        size_t n = members.length;
        stepped = stops[members[(self + n + (stepDir < 0 ? n - 1 : 1)) % n]].id;
        focus = stepped;
        again = true;
    }

    /// Tab order of last pass: stops outside groups, and per group its chosen member, or its first if none is.
    private size_t[] tabOrder()
    {
        size_t[] order;
        foreach (size_t i, Stop s; lastStops)
        {
            if (s.group == 0 || s.chosen)
            {
                order ~= i;
                continue;
            }
            bool first = true;
            bool chosen;
            foreach (size_t j, Stop o; lastStops)
            {
                if (o.group == s.group)
                {
                    first = first && j >= i;
                    chosen = chosen || o.chosen;
                }
            }
            if (first && chosen == false)
            {
                order ~= i;
            }
        }
        return order;
    }

    /// Focuses the first stop of last pass, or the last when `backward`, or the island itself if it has none.
    void enterFocus(bool backward)
    {
        size_t[] order = tabOrder();
        focus = order.length == 0 ? 0 : lastStops[backward ? order[$ - 1] : order[0]].id;
    }

    /// Moves focus to the next or previous stop of last pass, skipping the rest of the focused stop's group.
    /// False when there is none, so Tab leaves the island.
    bool stepFocus(bool backward)
    {
        size_t[] order = tabOrder();
        ptrdiff_t at = indexOfStop(lastStops, focus);
        if (at < 0)
        {
            if (backward || order.length == 0)
            {
                return false;
            }
            focus = lastStops[order[0]].id;
            return true;
        }
        size_t group = lastStops[at].group;
        bool other(size_t i)
        {
            return group == 0 || lastStops[i].group != group;
        }

        if (backward)
        {
            foreach_reverse (size_t i; order)
            {
                if (i < at && other(i))
                {
                    focus = lastStops[i].id;
                    return true;
                }
            }
            return false;
        }
        foreach (size_t i; order)
        {
            if (i > at && other(i))
            {
                focus = lastStops[i].id;
                return true;
            }
        }
        return false;
    }

    /// Asks for another pass next frame, for animation.
    void requestFrame()
    {
        frameWanted = true;
    }

    /// Asks for a pass at `t`, for a blinking caret.
    void requestFrameAt(MonoTime t)
    {
        if (t < wakeAt)
        {
            wakeAt = t;
        }
    }

    /// Style `T` for `variant`: from the theme or `T`'s defaults, then the `withStyle` edits, innermost last.
    T style(T)(string variant = null)
    {
        T s = tree.style!T(variant);
        if (Object* o = T.mangleof in edits)
        {
            foreach (void delegate(ref T) e; (cast(Edits!T) *o).items)
            {
                e(s);
            }
        }
        return s;
    }

    /// Edit for every `T` read inside, then the children: `ui.withStyle((ref TextStyle s) { ... })({ ... })`.
    StyleScope!T withStyle(T)(void delegate(ref T) edit)
    {
        return StyleScope!T(this, edit);
    }

    /// Edit stack of style `T`, created on first use.
    private Edits!T editsOf(T)()
    {
        if (Object* o = T.mangleof in edits)
        {
            return cast(Edits!T) *o;
        }
        Edits!T e = new Edits!T;
        edits[T.mangleof] = e;
        return e;
    }

    /// Takes the first press of `key` from this pass's `keys`, true if there was one. Ctrl, Alt and GUI must match
    /// `mods` exactly, Shift only when `mods` has it.
    bool takeKey(uint key, ubyte mods = 0)
    {
        foreach (size_t i, ref KeyEvent k; keys)
        {
            if (k.key == key && (k.mods & ~Mod.shift) == (mods & ~Mod.shift)
                && ((mods & Mod.shift) == 0 || (k.mods & Mod.shift) != 0))
            {
                keys = keys[0 .. i] ~ keys[i + 1 .. $];
                return true;
            }
        }
        return false;
    }
}

/// Index of the stop with `id` in `list`, or -1.
private ptrdiff_t indexOfStop(const(Stop)[] list, Id id)
{
    foreach (size_t i, Stop s; list)
    {
        if (s.id == id)
        {
            return i;
        }
    }
    return -1;
}

/// Vertical group: `ui.column(gap: 4)({ ... })`.
Group column(Ui ui, float gap = 0, CrossAlign cross = CrossAlign.stretch)
{
    return Group(ui, Axis.vertical, gap, cross);
}

/// Horizontal group: `ui.row(gap: 4)({ ... })`.
Group row(Ui ui, float gap = 0, CrossAlign cross = CrossAlign.center)
{
    return Group(ui, Axis.horizontal, gap, cross);
}

/// Single child that takes the remaining space of its group.
void expand(Ui ui, scope void delegate() child)
{
    ui.put(new Flexible(ui.one(child)));
}

/// Empty space that takes the remaining space of its group.
void spacer(Ui ui)
{
    ui.put(dentrite.containers.spacer());
}

/// Padding around the children, declared as a column.
void padded(Ui ui, float x, float y, scope void delegate() children)
{
    Flex inner = new Flex(Axis.vertical, 0, CrossAlign.stretch, null);
    ui.put(new Padding(Insets.xy(x, y), inner));
    ui.inside(inner, children);
}

/// Panel of `variant` around the children, declared as a column.
void panel(Ui ui, string variant, scope void delegate() children)
{
    Flex inner = new Flex(Axis.vertical, 0, CrossAlign.stretch, null);
    ui.put(new Panel(variant, inner));
    ui.inside(inner, children);
}

/// Result of `canvas`: its ID, last pass's rect and pointer state.
struct CanvasState
{
    Id id;      /// widget ID
    Rect rect;  /// rect from last pass, empty on the first
    Press press; /// pointer state from the last pass's rect
}

/// Custom control painted by `painter`, `w` by `h` or filling. Returns its ID, last rect and pointer state.
CanvasState canvas(Ui ui, void delegate(ref PaintContext, Rect) painter, float w = float.nan,
    float h = float.nan, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Canvas n = new Canvas(w, h, painter);
    ui.put(n);
    ui.track(n, i);
    return CanvasState(i, ui.lastRect(i), ui.clickable(i));
}

version (unittest)
{
    /// Context over a bare tree.
    private Ui testUi()
    {
        return new Ui(new Tree(null, null, null));
    }
}

// First pass lays out exactly, hit testing uses last pass's rects, a click re-runs before painting. Canvas
// paint is clipped to its rect.
unittest
{
    Ui ui = testUi();
    int clicks;
    int passes;
    Rect seen;
    void view(Ui u)
    {
        ++passes;
        u.row(gap: 4)({
            u.canvas((ref PaintContext c, Rect r) {}, w: 40, h: 20);
            CanvasState s = u.canvas((ref PaintContext c, Rect r) {
                seen = r;
                c.list.rect(Rect(r.x, r.y - 5, r.w, 10), Color(0xff, 0, 0, 0xff));
            }, w: 60, h: 20);
            if (s.press.clicked)
            {
                ++clicks;
            }
        });
    }

    ui.frame(&view, Rect(10, 10, 300, 100));
    assert(seen == Rect(54, 10, 60, 20), "laid out and painted in window coordinates on the first frame");
    const(DrawCmd)[] cmds = ui.output.cmds;
    bool clipped;
    foreach (size_t k; 0 .. cmds.length - 2)
    {
        clipped = clipped || (cmds[k].op == Op.pushClip && cmds[k].r == seen && cmds[k + 1].op == Op.rect
            && cmds[k + 2].op == Op.popClip);
    }
    assert(clipped, "the rect above the canvas is clipped to it");
    ui.mouse = Point(60, 15);
    ui.pressed = true;
    ui.down = true;
    ui.frame(&view, Rect(10, 10, 300, 100));
    assert(clicks == 0, "press alone is not a click");
    ui.down = false;
    ui.released = true;
    passes = 0;
    ui.frame(&view, Rect(10, 10, 300, 100));
    assert(clicks == 1 && passes == 2, "clicked once, built again before painting");
    ui.frame(&view, Rect(10, 10, 300, 100));
    assert(clicks == 1, "input spent");
}

// Per-ID memory survives passes while used and is dropped when not, IDs scoped by pushed keys.
unittest
{
    Ui ui = testUi();
    bool show = true;
    int*[2] seen;
    void view(Ui u)
    {
        if (show == false)
        {
            return;
        }
        foreach (int k; 0 .. 2)
        {
            u.pushId(k);
            seen[k] = u.memoryFor!int(u.id(__FILE__, __LINE__), k * 10);
            u.popId();
        }
    }

    ui.frame(&view, Rect(0, 0, 10, 10));
    assert(*seen[0] == 0 && *seen[1] == 10 && seen[0] !is seen[1]);
    *seen[1] = 99;
    ui.frame(&view, Rect(0, 0, 10, 10));
    assert(*seen[1] == 99);
    show = false;
    ui.frame(&view, Rect(0, 0, 10, 10));
    show = true;
    ui.frame(&view, Rect(0, 0, 10, 10));
    assert(*seen[1] == 10, "dropped while not declared");
}

// Memory with a `dropped` method hears once when a pass skips its ID.
unittest
{
    /// State that counts its drops.
    static struct Held
    {
        int* drops; /// incremented on drop

        /// Counts the drop.
        void dropped()
        {
            ++*drops;
        }
    }

    Ui ui = testUi();
    int drops;
    bool show = true;
    void view(Ui u)
    {
        if (show)
        {
            u.memoryFor(u.id(__FILE__, __LINE__), Held(&drops));
        }
    }

    ui.frame(&view, Rect(0, 0, 100, 100));
    ui.frame(&view, Rect(0, 0, 100, 100));
    assert(drops == 0);
    show = false;
    ui.frame(&view, Rect(0, 0, 100, 100));
    ui.frame(&view, Rect(0, 0, 100, 100));
    assert(drops == 1);
}
