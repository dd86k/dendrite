/// Retained node tree: box-constraint layout, painting, input and focus.
///
/// Layout is Flutter's protocol from research/examples/layout.d: constraints go down,
/// sizes go up, parents set positions. Each node caches its last constraints and
/// relayout stops at boundaries (tight constraints or a parent that ignores the
/// size). Paint boundaries, which are relayout boundaries and nodes with
/// `repaintBoundary`, paint into their own `Layer`. Paint requests and layouts
/// mark the nearest one stale, and `Compositor` records only stale layers.
module dentrite.node;

public import dentrite.geom;
public import dentrite.access : AccessAction, AccessInfo, AccessRequest, Role, Toggle, Tri, tri;
import core.time : Duration, MonoTime;
import dentrite.draw;
import dentrite.overlay : Stage;
import dentrite.signals : Scope;
import dentrite.text : TextSystem;
import dentrite.theme : resolve, Theme;
import std.algorithm.comparison : clamp, max, min;
import std.algorithm.sorting : sort;
import std.math : isInfinity;

/// Keyboard modifier bits.
enum Mod : ubyte
{
    none = 0,  /// nothing held
    shift = 1, /// either shift
    ctrl = 2,  /// either control
    alt = 4,   /// either alt
    gui = 8,   /// either GUI key
}

/// Keys the toolkit and apps react to. Values are SDL3 key codes: characters as their code point, other keys
/// as scan code with bit 30 set. Platforms translate to these, keys not listed pass through as is.
enum Key : uint
{
    backspace = 0x08,
    tab = 0x09,
    enter = 0x0d,
    escape = 0x1b,
    space = 0x20,
    a = 0x61,
    c = 0x63,
    r = 0x72,
    v = 0x76,
    x = 0x78,
    delete_ = 0x7f,
    f1 = 0x4000003a,
    f2 = 0x4000003b,
    f3 = 0x4000003c,
    f4 = 0x4000003d,
    f5 = 0x4000003e,
    f6 = 0x4000003f,
    f7 = 0x40000040,
    f8 = 0x40000041,
    f9 = 0x40000042,
    f10 = 0x40000043,
    f11 = 0x40000044,
    f12 = 0x40000045,
    insert = 0x40000049,
    home = 0x4000004a,
    pageUp = 0x4000004b,
    end = 0x4000004d,
    pageDown = 0x4000004e,
    right = 0x4000004f,
    left = 0x40000050,
    down = 0x40000051,
    up = 0x40000052,
    menu = 0x40000065,
}

/// Pointer event kinds.
enum PointerKind
{
    move,   /// moved, or dragged while captured
    down,   /// button pressed
    up,     /// button released, sent to the node that saw the press
    enter,  /// became the hovered node
    leave,  /// stopped being the hovered node
    cancel, /// the press was taken by a drag that scrolls, no release follows. Undo what the press started
}

/// Device behind a pointer event.
enum PointerSource : ubyte
{
    mouse, /// mouse or touchpad
    touch, /// finger on a touch screen
    pen,   /// pen or stylus
}

/// Pointer event in window coordinates.
struct PointerEvent
{
    PointerKind kind;     /// kind of pointer event
    Point pos;            /// window position
    ubyte button;         /// 1 left, 2 middle, 3 right
    ubyte clicks;         /// 2 for a double click
    ubyte mods;           /// `Mod` flags, combined with `|`
    PointerSource source; /// device it came from
    MonoTime time;        /// when it happened, set by the window
}

/// Drag directions, see `Node.drags`.
enum DragAxes : ubyte
{
    none = 0,       /// no direction
    horizontal = 1, /// sideways
    vertical = 2,   /// up and down
    both = 3,       /// every direction
}

/// Which pointers scroll a view by dragging its content, see `DragScroller`.
enum ScrollDrag : ubyte
{
    inherit, /// the window's choice, `WindowOptions.scrollDrag`
    touch,   /// touch and pen, the window default
    always,  /// the mouse too, as for a VR laser pointer injected as mouse input
    never,   /// none, only the scroll bars and the wheel
}

/// True if `mode` lets a drag by `source` scroll. `inherit` reads as `touch`.
bool scrollsWith(ScrollDrag mode, PointerSource source)
{
    final switch (mode)
    {
    case ScrollDrag.inherit:
    case ScrollDrag.touch:
        return source != PointerSource.mouse;
    case ScrollDrag.always:
        return true;
    case ScrollDrag.never:
        return false;
    }
}

/// Node scrolled by dragging its content, such as a scroll view on a touch screen. The window holds back a press
/// inside one until the pointer moves, lifts or `ScrollStyle.pressDelay` passes, so a swipe never presses a control.
/// Once the pointer moves `ScrollStyle.dragStart`, the innermost one that can scroll that way takes the drag.
/// A mouse press held still until it reaches the control keeps its drag, so text can still be selected.
interface DragScroller
{
    /// True if a drag by `source` from window point `at` may scroll it. Sets `onBar` when `at` is on its scroll
    /// bars, where no view takes the drag.
    bool scrollsDrag(PointerSource source, Point at, out bool onBar);

    /// Takes a drag that moved `moved` since the press if it can scroll that way, or along that axis at all when
    /// `edge` is set. From then on it gets the moves and the release, from window point `at`. True if taken.
    bool takeDrag(Point at, Point moved, bool edge, MonoTime time);

    /// Stops a fling. True if one was running: it then holds the press at `at` as a taken drag.
    bool catchFling(Point at, MonoTime time);
}

/// Wheel event: scroll distance in logical pixels, positive `dy` moves content up.
struct WheelEvent
{
    Point pos;  /// window position
    float dx;   /// horizontal distance in logical pixels
    float dy;   /// vertical distance in logical pixels
    ubyte mods; /// `Mod` flags, combined with `|`
}

/// Key press.
struct KeyEvent
{
    uint key;    /// Key value or another key code
    ubyte mods;  /// `Mod` flags, combined with `|`
    bool repeat; /// auto-repeat
}

/// Mouse cursor shapes a node can ask for.
enum CursorShape
{
    arrow,    /// default arrow
    text,     /// I-beam
    pointer,  /// pointing hand, for links and clickable items
    ewResize, /// horizontal splitter
    nsResize, /// vertical splitter
    nwseResize, /// top left or bottom right corner
    neswResize, /// top right or bottom left corner
    move,     /// moving a window
}

/// What nodes need from the window.
interface Services
{
    void requestFrame();             /// paint again soon
    void requestFrameAt(MonoTime t); /// paint again at `t`, for blinking and animation
    void setFocus(Node n);           /// moves keyboard focus, null clears it
    Node focused();                  /// node with keyboard focus, or null
    string clipboard();              /// clipboard text
    void setClipboard(string s);     /// sets the clipboard
    MonoTime now();                  /// start time of the current frame
    bool focusVisible();             /// focus last moved by keyboard, so rings should show
    void forget(Node n);             /// drops hover, capture and focus held by `n`, which is leaving the tree
    void passKey(Node from, KeyEvent e); /// sends a key `from` did not use to its parents, then to the window
    /// Lets go of the held press: until the release, hover follows the pointer and the node under it gets the
    /// release, as a menu bar title hands a drag to the menu it opened. NOTE: meant for a node that opens a
    /// popup which blocks what is below, else a release on a button clicks it.
    void slidePress();
}

/// Node with work between layout and paint, such as an island running its pass.
interface Updatable
{
    void update();     /// runs pending work
    void invalidate(); /// forces work on the next update, after a theme or scale change
}

/// Node hearing keys from anywhere in the window, such as a menu bar firing its shortcuts.
interface WindowKeys
{
    bool windowKey(ref const KeyEvent e); /// handles `e` if it is one of its keys, true if it did
}

/// Focused node showing text an input method has not committed yet, such as a dead key's accent.
interface Composer
{
    /// Shows `text` at the caret until committed or replaced, null to clear. Bytes `from .. to` of it are the
    /// part being converted, or the caret when equal.
    void compose(string text, size_t from, size_t to);
    Rect caretRect(); /// caret in window coordinates, where the input method shows its candidates
}

/// Node with Tab stops of its own, such as an island with controls. Tab goes through them before leaving it.
interface FocusScope
{
    void enterFocus(bool backward); /// focuses its first stop on Tab, or its last on Shift+Tab
    bool stepFocus(bool backward);  /// moves to the next or previous stop, false at the end so focus leaves
    Rect focusRect();               /// window rect of the focused stop, or the node's bounds
}

/// Allowed size range handed from parent to child.
struct Constraints
{
    float minW = 0;              /// smallest allowed width
    float maxW = float.infinity; /// largest allowed width
    float minH = 0;              /// smallest allowed height
    float maxH = float.infinity; /// largest allowed height

    /// Exactly `s`.
    static Constraints tight(Size s)
    {
        return Constraints(s.w, s.w, s.h, s.h);
    }

    /// Anything from zero up to `s`.
    static Constraints loose(Size s)
    {
        return Constraints(0, s.w, 0, s.h);
    }

    /// True if only one size satisfies the constraints.
    bool isTight() const
    {
        return minW == maxW && minH == maxH;
    }

    /// `s` clamped into range.
    Size constrain(Size s) const
    {
        return Size(clamp(s.w, minW, maxW), clamp(s.h, minH, maxH));
    }

    /// Constraints shrunk by `i`, never below zero.
    Constraints deflate(Insets i) const
    {
        float dx = i.left + i.right;
        float dy = i.top + i.bottom;
        return Constraints(max(0f, minW - dx), max(0f, maxW - dx), max(0f, minH - dy), max(0f, maxH - dy));
    }

    /// Same maximums, no minimums.
    Constraints loosen() const
    {
        return Constraints(0, maxW, 0, maxH);
    }
}

/// State handed to `Node.paint`.
struct PaintContext
{
    DrawList* list; /// draw list painting goes into
    Rect clip;      /// visible area in window coordinates, for culling
    Tree tree;      /// tree giving the theme and the text system
    bool layers;    /// child paint boundaries go into their own layers, referenced from `list`
    bool culled;    /// a child was skipped as outside `clip`

    /// Style `T` for `variant` from the tree's theme.
    T style(T)(string variant = null)
    {
        return tree.style!T(variant);
    }

    /// Text system of the window.
    TextSystem text()
    {
        return tree.text;
    }

    /// Runs `body` with the clip narrowed to `r`, pushed on the list and popped after.
    void clipped(Rect r, scope void delegate() body)
    {
        Rect old = clip;
        clip = intersect(clip, r);
        list.pushClip(r);
        body();
        list.popClip();
        clip = old;
    }
}

/// Owner of a node tree: relayout queue, theme, text and window services.
final class Tree
{
    Stage root;           /// app root and open popups, laid out to the viewport
    Size viewport;        /// window size, logical pixels
    TextSystem text;      /// text system: fonts, shaping and the glyph atlas
    Theme theme;          /// styles, or style defaults when null
    Services services;    /// window services, null in tests
    bool paintRequested = true; /// something changed since the last paint
    Updatable[] updaters; /// nodes to update after layout and before paint, such as islands
    WindowKeys[] windowKeys; /// nodes hearing keys from anywhere in the window, in attach order
    int boundaryLayouts;  /// relayout boundaries laid out in the last flush
    uint styleVersion;    /// bumped by `restyle`, for nodes caching measurements
    bool frameStart;      /// set by the host around frame-start hooks, where paint requests need no new frame
    ScrollDrag scrollDrag = ScrollDrag.touch; /// `WindowOptions.scrollDrag`, for drag scrollers left at `inherit`

    private Node[] dirty;  /// boundaries marked since the last flush
    private bool flushing; /// inside `flush`, where paint requests need no new frame
    private Timer[] timers; /// repaints and calls waiting for their time

    /// Repaint of a node, or a call on its behalf, at a time.
    private static struct Timer
    {
        Node node;          /// node to repaint, or owning the call
        MonoTime at;        /// when
        void delegate() fn; /// call, null for a repaint
    }

    /// Creates an empty tree.
    this(TextSystem text, Theme theme, Services services)
    {
        this.text = text;
        this.theme = theme;
        this.services = services;
        root = new Stage;
        attach(root);
    }

    /// Replaces the app root, keeping open popups.
    void setRoot(Node r)
    {
        root.setContent(r);
        requestPaint();
    }

    /// App root, or null.
    Node content()
    {
        return root.content;
    }

    /// Sets `tree` on `n` and its descendants and tells them. Boundaries that went stale while detached are queued.
    void attach(Node n)
    {
        if (n.tree is this)
        {
            return;
        }
        n.tree = this;
        foreach (Node c; n.children)
        {
            attach(c);
        }
        if (n.needsLayout && n.boundary && n.parent !is null)
        {
            queue(n);
        }
        n.onAttach();
    }

    /// Clears `tree` on `n` and its descendants and tells them.
    void detach(Node n)
    {
        if (n.tree !is this)
        {
            return;
        }
        if (services !is null)
        {
            services.forget(n);
        }
        n.onDetach();
        foreach (Node c; n.children)
        {
            detach(c);
        }
        n.tree = null;
        n.layer = null;
    }

    /// Style `T` for `variant`.
    T style(T)(string variant = null)
    {
        return theme is null ? resolve!T(null, null, variant, null) : theme.style!T(variant);
    }

    /// Asks the window for a frame, unless a layout is running and paint follows anyway.
    void requestPaint()
    {
        paintRequested = true;
        if (services !is null && flushing == false && frameStart == false)
        {
            services.requestFrame();
        }
    }

    /// Physical pixels per logical pixel, 1 without text.
    float ppp()
    {
        return text is null ? 1 : text.ppp;
    }

    /// Adds `u` to the nodes updated before paint.
    void addUpdater(Updatable u)
    {
        updaters ~= u;
    }

    /// Removes `u` from the nodes updated before paint.
    void removeUpdater(Updatable u)
    {
        Updatable[] kept;
        foreach (Updatable k; updaters)
        {
            if (k !is u)
            {
                kept ~= k;
            }
        }
        updaters = kept;
    }

    /// Adds `w` to the nodes hearing keys from anywhere in the window.
    void addWindowKeys(WindowKeys w)
    {
        windowKeys ~= w;
    }

    /// Removes `w` from the nodes hearing keys from anywhere in the window.
    void removeWindowKeys(WindowKeys w)
    {
        WindowKeys[] kept;
        foreach (WindowKeys k; windowKeys)
        {
            if (k !is w)
            {
                kept ~= k;
            }
        }
        windowKeys = kept;
    }

    /// Repaints `n` at `t`, replacing an earlier time for `n`. Does nothing without a window.
    void paintAt(Node n, MonoTime t)
    {
        setTimer(n, t, null);
    }

    /// Calls `fn` at the start of the first frame at or after `t` if `n` is still in the tree, replacing an
    /// earlier call for `n`. Does nothing without a window.
    void callAt(Node n, MonoTime t, void delegate() fn)
    {
        assert(fn !is null);
        setTimer(n, t, fn);
    }

    /// True if a call for `n` is waiting.
    bool hasCall(Node n)
    {
        foreach (Timer p; timers)
        {
            if (p.node is n && p.fn !is null)
            {
                return true;
            }
        }
        return false;
    }

    /// Drops the pending call for `n`.
    void cancelCall(Node n)
    {
        Timer[] left;
        foreach (Timer p; timers)
        {
            if (p.node !is n || p.fn is null)
            {
                left ~= p;
            }
        }
        timers = left;
    }

    /// Sets the repaint time of `n`, or its call when `fn` is set, and asks for a frame then.
    private void setTimer(Node n, MonoTime t, void delegate() fn)
    {
        if (services is null)
        {
            return;
        }
        services.requestFrameAt(t);
        foreach (ref Timer p; timers)
        {
            if (p.node is n && (p.fn is null) == (fn is null))
            {
                p.at = t;
                p.fn = fn;
                return;
            }
        }
        timers ~= Timer(n, t, fn);
    }

    /// Marks the nodes whose repaint time has come and runs the calls that are due, at the start of a frame.
    void firePaintTimers(MonoTime now)
    {
        if (timers.length == 0)
        {
            return;
        }
        Timer[] left;
        Timer[] due;
        foreach (Timer p; timers)
        {
            if (p.at > now)
            {
                left ~= p;
            }
            else if (p.node.tree is this)
            {
                due ~= p;
            }
        }
        timers = left;
        foreach (Timer p; due)
        {
            if (p.fn is null)
            {
                p.node.markNeedsPaint();
            }
            else
            {
                p.fn();
            }
        }
    }

    /// Queues boundary `n` for the next flush.
    private void queue(Node n)
    {
        dirty ~= n;
        requestPaint();
    }

    /// Marks every node for layout, after a theme or scale change.
    void restyle()
    {
        ++styleVersion;
        root.markSubtreeNeedsLayout();
        foreach (Updatable u; updaters)
        {
            u.invalidate();
        }
        requestPaint();
    }

    /// True if a flush has work to do.
    bool needsLayout()
    {
        Node top = root;
        return dirty.length > 0 || top.needsLayout || top.constraints != Constraints.tight(viewport);
    }

    /// Relayouts every dirty boundary, parents first, then places the popups.
    void flush()
    {
        boundaryLayouts = 0;
        flushing = true;
        scope (exit)
        {
            flushing = false;
        }
        Node top = root;
        if (top.constraints != Constraints.tight(viewport) || top.needsLayout)
        {
            top.layout(Constraints.tight(viewport), false);
            ++boundaryLayouts;
        }
        sort!((Node a, Node b) => a.depth < b.depth)(dirty);
        foreach (Node n; dirty)
        {
            if (n.needsLayout && n.tree is this)
            {
                n.layout(n.constraints, n.parentUsesSize);
                ++boundaryLayouts;
            }
        }
        dirty.length = 0;
        dirty.assumeSafeAppend();
        root.place();
    }
}

/// Node in the retained tree.
abstract class Node
{
    Node parent;         /// parent node, set by `add`, null for a root or while detached
    Node[] children;     /// child nodes, in paint order
    Point offset;        /// position inside the parent, set by the parent
    Size size;           /// size from the last layout
    Tree tree;           /// tree this node is in, null while detached
    int layoutRuns;      /// times `performLayout` ran
    bool interactive;    /// receives pointer events and hover
    bool focusable;      /// takes keyboard focus on press and Tab
    bool keepFocus;      /// a press inside leaves focus where it is, as on a menu bar
    bool textInput;      /// wants text input events while focused
    bool hiddenText;     /// its text input is a password, so the platform keeps input methods off where it can
    bool hasContextMenu; /// opens a context menu for its content, so screen readers offer it on the nodes inside
    CursorShape cursor;  /// cursor shape while hovered
    /// Drag directions it uses itself, such as a canvas. A press on it is not held back for a `DragScroller`,
    /// which can still take drags the other way.
    DragAxes drags;
    bool hovered;        /// pointer is over it, set by the window
    bool pressed;        /// pointer pressed on it and not released yet, set by the window
    bool focused;        /// has keyboard focus, set by the window
    bool repaintBoundary; /// paints into its own layer even when not a relayout boundary. Set before attaching
    Scope owner;         /// scope owning the effects and scopes disposed with the node
    string accessName;   /// name for screen readers where the node has none, such as an icon button
    ulong accessId;      /// stable id for assistive technologies, assigned on first use, see `dentrite.access`

    private Constraints constraints;  /// constraints of the last layout
    private bool needsLayout = true;  /// stale since the last layout
    private bool boundary;            /// relayout stops here
    private bool parentUsesSize;      /// parent read our size last time
    private Layer layer;              /// cached paint while a paint boundary
    private string tip;               /// tooltip text, null for none

    /// Adds `child` and returns it.
    final Node add(Node child)
    {
        assert(child.parent is null, "node already has a parent");
        child.parent = this;
        children ~= child;
        if (tree !is null)
        {
            tree.attach(child);
        }
        markNeedsLayout();
        return child;
    }

    /// Replaces the children with `kids`. Children not in `kids` are detached, not disposed.
    final void setChildren(Node[] kids)
    {
        bool[Node] keep;
        foreach (Node k; kids)
        {
            keep[k] = true;
        }
        foreach (Node c; children)
        {
            if ((c in keep) is null)
            {
                if (tree !is null)
                {
                    tree.detach(c);
                }
                c.parent = null;
            }
        }
        children = kids.dup;
        foreach (Node k; children)
        {
            if (k.parent !is this)
            {
                assert(k.parent is null, "node already has a parent");
                k.parent = this;
                if (tree !is null)
                {
                    tree.attach(k);
                }
            }
        }
        markNeedsLayout();
    }

    /// Detaches `child`, without disposing it.
    final void removeChild(Node child)
    {
        Node[] kept;
        foreach (Node c; children)
        {
            if (c !is child)
            {
                kept ~= c;
            }
        }
        setChildren(kept);
    }

    /// Disposes the owned scope and the children's, then detaches from the parent.
    final void dispose()
    {
        foreach (Node c; children)
        {
            c.dispose();
        }
        if (owner !is null)
        {
            owner.dispose();
            owner = null;
        }
    }

    /// Lays out under `c`, skipping work when clean and `c` is unchanged. A layout marks the layer the node
    /// paints into stale, and the parent's too when a paint boundary changed size.
    final Size layout(Constraints c, bool parentUsesSize = true)
    {
        bool wasPaintBoundary = isPaintBoundary;
        boundary = parentUsesSize == false || c.isTight || parent is null;
        if (isPaintBoundary != wasPaintBoundary)
        {
            layer = null;
        }
        if (needsLayout == false && c == constraints)
        {
            return size;
        }
        constraints = c;
        this.parentUsesSize = parentUsesSize;
        Size before = size;
        size = c.constrain(performLayout(c));
        needsLayout = false;
        ++layoutRuns;
        invalidateLayer();
        if (size != before && isPaintBoundary && parent !is null)
        {
            parent.invalidateLayer();
        }
        return size;
    }

    /// Marks this node stale and walks up to the nearest relayout boundary.
    final void markNeedsLayout()
    {
        if (needsLayout)
        {
            if (tree !is null)
            {
                tree.requestPaint();
            }
            return;
        }
        needsLayout = true;
        if (boundary == false && parent !is null)
        {
            parent.markNeedsLayout();
        }
        else if (tree !is null)
        {
            tree.queue(this);
        }
    }

    /// Marks this node and its descendants stale without queueing, for restyles and detached nodes.
    final void markSubtreeNeedsLayout()
    {
        needsLayout = true;
        foreach (Node c; children)
        {
            c.markSubtreeNeedsLayout();
        }
    }

    /// Asks for a repaint.
    final void markNeedsPaint()
    {
        invalidateLayer();
        if (tree !is null)
        {
            tree.requestPaint();
        }
    }

    /// Repaints at `t`, for blinking and animation.
    final void markNeedsPaintAt(MonoTime t)
    {
        if (tree !is null)
        {
            tree.paintAt(this, t);
        }
    }

    /// Marks the layer holding this node's paint stale without asking for a frame, for changes made during one.
    final void invalidateLayer()
    {
        for (Node n = this; n !is null; n = n.parent)
        {
            if (n.isPaintBoundary)
            {
                if (n.layer !is null)
                {
                    n.layer.dirty = true;
                }
                return;
            }
        }
    }

    /// True if this node paints into its own layer.
    final bool isPaintBoundary() const
    {
        return boundary || repaintBoundary;
    }

    /// Layer of this paint boundary, made on first use.
    final Layer paintLayer()
    {
        if (layer is null)
        {
            layer = new Layer(&record);
        }
        return layer;
    }

    /// Paints into `l` at `origin`, culling against `clip`. Child paint boundaries become references.
    private void record(Layer l, Point origin, Rect clip)
    {
        l.list.clear();
        l.complete = true;
        if (tree is null)
        {
            return;
        }
        PaintContext ctx = PaintContext(&l.list, clip, tree, true);
        paint(ctx, origin);
        l.complete = ctx.culled == false;
    }

    /// Tooltip text, or null.
    final string tooltip()
    {
        return tip;
    }

    /// Sets the text shown while the pointer rests on this node, or on a child without its own. Null for none.
    /// A shown tooltip follows on the next frame.
    final void setTooltip(string s)
    {
        if (s == tip)
        {
            return;
        }
        tip = s;
        if (tree !is null)
        {
            tree.requestPaint();
        }
    }

    /// True if focused by keyboard, when focus rings should show.
    final bool focusRing()
    {
        return focused && tree !is null && tree.services !is null && tree.services.focusVisible;
    }

    /// True if this node relayouts without its parent.
    final bool isBoundary() const
    {
        return boundary;
    }

    /// Distance from the root.
    final int depth()
    {
        int d;
        for (Node p = parent; p !is null; p = p.parent)
        {
            ++d;
        }
        return d;
    }

    /// True if `ancestor` is this node or one of its parents.
    final bool isInside(Node ancestor)
    {
        for (Node n = this; n !is null; n = n.parent)
        {
            if (n is ancestor)
            {
                return true;
            }
        }
        return false;
    }

    /// Rectangle in window coordinates.
    final Rect bounds()
    {
        Point p = offset;
        for (Node n = parent; n !is null; n = n.parent)
        {
            p = p + n.offset;
        }
        return Rect(p.x, p.y, size.w, size.h);
    }

    /// Computes this node's size under `c` and positions its children.
    protected abstract Size performLayout(Constraints c);

    /// Paints at window position `origin`. The default paints the children.
    void paint(ref PaintContext ctx, Point origin)
    {
        paintChildren(ctx, origin);
    }

    /// Paints the children that intersect the clip. With layers, child paint boundaries become references
    /// whatever the clip, and the compositor culls them.
    final void paintChildren(ref PaintContext ctx, Point origin)
    {
        foreach (Node c; children)
        {
            paintChild(ctx, origin, c);
        }
    }

    /// Paints child `c` when this node sits at `origin`, as a layer reference, inline, or culled.
    final void paintChild(ref PaintContext ctx, Point origin, Node c)
    {
        Point o = origin + c.offset;
        Rect r = Rect(o.x, o.y, c.size.w, c.size.h);
        if (ctx.layers && c.isPaintBoundary)
        {
            ctx.list.layer(c.paintLayer, r);
        }
        else if (intersect(r, ctx.clip).empty == false || c.size.w == 0 || c.size.h == 0)
        {
            c.paint(ctx, o);
        }
        else
        {
            ctx.culled = true;
        }
    }

    /// Deepest node under window point `p` when this node sits at `origin`, or null. Later children win.
    Node hitTest(Point p, Point origin)
    {
        if (Rect(origin.x, origin.y, size.w, size.h).contains(p) == false)
        {
            return null;
        }
        foreach_reverse (Node c; children)
        {
            if (Node hit = c.hitTest(p, origin + c.offset))
            {
                return hit;
            }
        }
        return this;
    }

    /// Pointer event for an interactive node. True if handled.
    bool onPointer(ref const PointerEvent e)
    {
        return false;
    }

    /// Wheel event, bubbling from the deepest node. True if handled.
    bool onWheel(ref const WheelEvent e)
    {
        return false;
    }

    /// Key press, bubbling from the focused node. True if handled.
    bool onKey(ref const KeyEvent e)
    {
        return false;
    }

    /// Committed text for the focused node. True if handled.
    bool onText(string s)
    {
        return false;
    }

    /// Context menu request at window point `p`, bubbling from the node under a right press or from the
    /// focused node for the menu key. `keyboard` is set for the key. True if a menu opened.
    bool onContextMenu(Point p, bool keyboard)
    {
        return false;
    }

    /// Called on the node under a press at window point `p` and on its ancestors, innermost first, before the
    /// press is delivered. For containers that react to any press inside, such as raising a floating window.
    void onPressInside(Point p)
    {
    }

    /// Called when the node gains or loses keyboard focus.
    void onFocus(bool gained)
    {
    }

    /// True if Tab stops here. A radio group stops only at its chosen radio.
    bool tabStop()
    {
        return focusable;
    }

    /// Fills `a` for assistive technologies. The default leaves `Role.none`, so the node stays out and its
    /// children join the nearest exposed ancestor.
    void describe(ref AccessInfo a)
    {
    }

    /// Runs `r`, asked by an assistive technology for this node. True if done. Focus and scrolling into view
    /// are the host's.
    bool accessAction(ref const AccessRequest r)
    {
        return false;
    }

    /// Called when the node joins a tree.
    void onAttach()
    {
    }

    /// Called when the node leaves a tree.
    void onDetach()
    {
    }
}

/// Leaf that wants a given size, clamped by its constraints, for spacers and stand-ins.
final class Fixed : Node
{
    Size want; /// preferred size

    /// Creates a leaf preferring `want`.
    this(Size want)
    {
        this.want = want;
    }

    /// Returns the preferred size.
    protected override Size performLayout(Constraints c)
    {
        return want;
    }
}

version (unittest)
{
    /// Tree without fonts, theme or window.
    Tree bareTree(Node root, Size viewport)
    {
        Tree t = new Tree(null, null, null);
        t.viewport = viewport;
        t.setRoot(root);
        return t;
    }
}

// Caching and relayout boundaries: a tight child relayouts alone, a clean one is skipped.
unittest
{
    /// Box that fills the width and wants `h` tall, laying out one child tightly.
    static final class Holder : Node
    {
        float h; /// wanted height

        this(float h, Node child)
        {
            this.h = h;
            add(child);
        }

        protected override Size performLayout(Constraints c)
        {
            children[0].layout(Constraints.tight(Size(c.maxW, h)));
            return Size(c.maxW, h);
        }
    }

    Fixed inner = new Fixed(Size(10, 10));
    Holder mid = new Holder(50, inner);
    Holder root = new Holder(100, mid);
    Tree t = bareTree(root, Size(200, 200));
    t.flush();
    assert(root.layoutRuns == 1 && mid.layoutRuns == 1 && inner.layoutRuns == 1);
    assert(mid.isBoundary && inner.isBoundary);
    inner.want = Size(20, 20);
    inner.markNeedsLayout();
    assert(t.needsLayout);
    t.flush();
    assert(inner.layoutRuns == 2 && mid.layoutRuns == 1 && root.layoutRuns == 1, "stopped at the boundary");
    assert(t.boundaryLayouts == 1);
    t.flush();
    assert(inner.layoutRuns == 2 && t.boundaryLayouts == 0);
}

// setChildren keeps reused nodes attached and detaches the rest.
unittest
{
    Fixed a = new Fixed(Size(1, 1));
    Fixed b = new Fixed(Size(1, 1));
    Fixed c = new Fixed(Size(1, 1));
    Fixed root = new Fixed(Size(10, 10));
    root.add(a);
    root.add(b);
    Tree t = bareTree(root, Size(10, 10));
    assert(a.tree is t && b.tree is t);
    root.setChildren([b, c]);
    assert(a.tree is null && a.parent is null);
    assert(b.tree is t && c.tree is t && c.parent is root);
    root.size = Size(10, 10);
    c.size = Size(10, 10);
    assert(root.hitTest(Point(5, 5), Point(0, 0)) is c, "later children win");
}

version (unittest)
{
    /// Leaf of a wanted size filling its bounds with `color`.
    final class Swatch : Node
    {
        Size want;   /// preferred size
        Color color; /// fill

        /// Creates a swatch.
        this(Size want, Color color)
        {
            this.want = want;
            this.color = color;
        }

        /// Returns the preferred size.
        protected override Size performLayout(Constraints c)
        {
            return want;
        }

        /// The fill.
        override void paint(ref PaintContext ctx, Point origin)
        {
            ctx.list.rect(Rect(origin.x, origin.y, size.w, size.h), color);
        }
    }

    /// Frame of `t` painted into one list and tessellated whole, the result the layers must match.
    FrameMesh uncached(Tree t, float ppp = 1)
    {
        DrawList l;
        PaintContext ctx = PaintContext(&l, Rect(0, 0, t.viewport.w, t.viewport.h), t);
        t.root.paint(ctx, Point(0, 0));
        FrameMesh m = new FrameMesh;
        Tessellator tess;
        tess.ppp = ppp;
        tess.run(l, m, cast(int)(t.viewport.w * ppp), cast(int)(t.viewport.h * ppp));
        return m;
    }

    /// Header, a scroll view over `rows` swatches 10 px tall, and a footer. Every third row is a repaint boundary.
    Tree layeredTree(Size viewport, out Swatch[] rows, out Node sv, TextSystem text = null)
    {
        import dentrite.containers : column, expanded, scroll;

        Node[] kids;
        foreach (int i; 0 .. 40)
        {
            Swatch s = new Swatch(Size(0, 10), Color(cast(ubyte)(i * 6), 80, 160, 255));
            s.repaintBoundary = i % 3 == 0;
            rows ~= s;
            kids ~= s;
        }
        sv = scroll()(column()(kids));
        Node root = column()(new Swatch(Size(0, 10), Color(200, 0, 0, 255)), expanded(sv),
            new Swatch(Size(0, 10), Color(0, 200, 0, 255)));
        Tree t = new Tree(text, null, null);
        t.viewport = viewport;
        t.setRoot(root);
        t.flush();
        return t;
    }
}

// Layers give the same triangles and clips as one list. A clean frame records nothing, a paint request records
// only the layer holding the node, and scrolling records the scroll view while row layers move.
unittest
{
    import dentrite.containers : ScrollView;

    Swatch[] rows;
    Node svNode;
    Tree t = layeredTree(Size(200, 100), rows, svNode);
    ScrollView sv = cast(ScrollView) svNode;
    FrameMesh m = new FrameMesh;
    Compositor c;
    c.compose(t.root.paintLayer, m, 200, 100);
    assert(triangles(m) == triangles(uncached(t)));
    assert(c.recorded == 4 + 3, "stage, root, the flexible and the scroll view, rows 0, 3 and 6 in view");

    c.compose(t.root.paintLayer, m, 200, 100);
    assert(c.recorded == 0 && c.reused == 7);

    rows[4].color = Color(1, 2, 3, 255);
    rows[4].markNeedsPaint();
    c.compose(t.root.paintLayer, m, 200, 100);
    assert(c.recorded == 1 && c.reused == 6, "only the scroll view, which holds row 4");
    assert(triangles(m) == triangles(uncached(t)));

    sv.scrollTo(25);
    t.flush();
    c.compose(t.root.paintLayer, m, 200, 100);
    assert(triangles(m) == triangles(uncached(t)));
    assert(c.recorded == 2, "the scroll view and row 9, which came into view");
    assert(c.reused == 5, "stage, root, the flexible, rows 3 and 6 moved up");

    rows[6].color = Color(4, 5, 6, 255);
    rows[6].markNeedsPaint();
    c.compose(t.root.paintLayer, m, 200, 100);
    assert(c.recorded == 1, "row 6 paints into its own layer");
    assert(triangles(m) == triangles(uncached(t)));
}

// At 150% a scroll moves the content by whole physical pixels, so row layers are copied, not tessellated again.
unittest
{
    import dentrite.containers : ScrollView;

    TextSystem ts = testText();
    scope (exit)
    {
        ts.dispose();
    }
    ts.setScale(1.5);
    Swatch[] rows;
    Node svNode;
    Tree t = layeredTree(Size(200, 100), rows, svNode, ts);
    ScrollView sv = cast(ScrollView) svNode;
    FrameMesh m = new FrameMesh;
    Compositor c;
    c.tess.ppp = 1.5;
    c.tess.text = ts;
    c.compose(t.root.paintLayer, m, 300, 150);
    assert(triangles(m) == triangles(uncached(t, 1.5)));
    sv.scrollTo(5);
    t.flush();
    c.compose(t.root.paintLayer, m, 300, 150);
    assert(c.recorded == 1, "only the scroll view");
    assert(triangles(m) == triangles(uncached(t, 1.5)));

    ts.atlas.clear();
    c.compose(t.root.paintLayer, m, 300, 150);
    assert(c.reused == 0, "a cleared atlas invalidates every mesh");
}

// A layer that culled a child is recorded again when more of it comes into view, even if nothing in it changed.
unittest
{
    import dentrite.containers : column, scroll, ScrollView;

    Swatch top = new Swatch(Size(0, 10), Color(255, 0, 0, 255));
    Swatch bottom = new Swatch(Size(0, 10), Color(0, 0, 255, 255));
    Node pair = column()(top, bottom);
    pair.repaintBoundary = true;
    Fixed gap = new Fixed(Size(0, 15));
    ScrollView sv = scroll()(column()(gap, pair, new Fixed(Size(0, 100))));
    Tree t = bareTree(sv, Size(100, 20));
    t.flush();
    FrameMesh m = new FrameMesh;
    Compositor c;
    c.compose(t.root.paintLayer, m, 100, 20);
    assert(pair.paintLayer.complete == false, "bottom was culled");
    assert(triangles(m) == triangles(uncached(t)));
    sv.scrollTo(10);
    t.flush();
    c.compose(t.root.paintLayer, m, 100, 20);
    assert(c.recorded == 2 && pair.paintLayer.complete);
    assert(triangles(m) == triangles(uncached(t)));
}

// A timed repaint asks the window for a frame at that time and marks the layer once the time has come.
// A later request for the same node replaces the earlier one.
unittest
{
    import core.time : msecs;
    import dentrite.containers : column;

    /// Window stand-in that records frame times.
    static final class Clock : Services
    {
        MonoTime[] asked; /// times passed to `requestFrameAt`

        void requestFrame() {}
        void requestFrameAt(MonoTime t) { asked ~= t; }
        void setFocus(Node n) {}
        Node focused() { return null; }
        string clipboard() { return null; }
        void setClipboard(string s) {}
        MonoTime now() { return MonoTime.init; }
        bool focusVisible() { return false; }
        void forget(Node n) {}
        void passKey(Node from, KeyEvent e) {}
        void slidePress() {}
    }

    Clock clock = new Clock;
    Swatch s = new Swatch(Size(10, 10), Color(1, 1, 1, 255));
    s.repaintBoundary = true;
    Tree t = new Tree(null, null, clock);
    t.viewport = Size(10, 10);
    t.setRoot(column()(s));
    t.flush();
    FrameMesh m = new FrameMesh;
    Compositor c;
    c.compose(t.root.paintLayer, m, 10, 10);
    MonoTime t0 = MonoTime.currTime;
    s.markNeedsPaintAt(t0 + 500.msecs);
    s.markNeedsPaintAt(t0 + 530.msecs);
    assert(clock.asked == [t0 + 500.msecs, t0 + 530.msecs]);
    t.firePaintTimers(t0 + 510.msecs);
    c.compose(t.root.paintLayer, m, 10, 10);
    assert(c.recorded == 0, "replaced by the later time");
    t.firePaintTimers(t0 + 530.msecs);
    c.compose(t.root.paintLayer, m, 10, 10);
    assert(c.recorded == 1, "only the swatch");
}

version (unittest) import dentrite.text : testText;
