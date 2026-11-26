/// Accessibility tree for screen readers and UI tests: roles, names, states and actions of the nodes.
///
/// Nodes fill an `AccessInfo` in `Node.describe`. `AccessTree` walks the tree after a frame and keeps what it sent,
/// so a platform adapter gets only the nodes that changed. A node with `Role.none` stays out and its children join
/// the nearest ancestor that is in. Nothing here knows a platform API, adapters map roles to their own.
module dentrite.access;

import dentrite.geom : Rect;
import dentrite.node : Node, Tree;
import std.math : isNaN;

/// 64-bit hash of `a` seeded with `b` (splitmix64 finalizer), same on 32 and 64-bit targets.
ulong mixId(ulong a, ulong b) @safe pure nothrow @nogc
{
    ulong z = a ^ (b + 0x9e37_79b9_7f4a_7c15) * 0xbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 30)) * 0xbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 27)) * 0x94d0_49bb_1331_11eb;
    return z ^ (z >> 31);
}

/// What a node is to an assistive technology.
enum Role : ubyte
{
    none,               /// not exposed, children join the nearest exposed ancestor
    window,             /// the window, root of the tree
    group,              /// related controls
    pane,               /// dock pane or panel with a title
    label,              /// static text
    button,             /// push button
    checkBox,           /// on or off
    radioButton,        /// one of a group
    slider,             /// number in a range
    progressIndicator,  /// progress of a task
    textInput,          /// single line text
    passwordInput,      /// single line text shown as dots
    multilineTextInput, /// text over several lines
    spinButton,         /// number with step buttons
    comboBox,           /// choice from a popup list
    listBox,            /// list of choices
    listBoxOption,      /// row of a list
    tree,               /// hierarchical list
    treeItem,           /// row of a tree
    table,              /// rows and columns
    row,                /// table row
    cell,               /// table cell
    columnHeader,       /// table column header
    tabList,            /// row of tabs
    tab,                /// one tab
    tabPanel,           /// content of the chosen tab
    menu,               /// popup menu
    menuBar,            /// window menu bar
    menuItem,           /// menu entry
    menuItemCheckBox,   /// menu entry with a check mark
    dialog,             /// dialog window
    tooltip,            /// tooltip text
    scrollView,         /// scrolled content
    separator,          /// divider line
    image,              /// picture or icon
}

/// How screen readers announce changes to a node's text.
enum Live : ubyte
{
    off,       /// not announced
    polite,    /// announced once the reader is idle
    assertive, /// announced at once, interrupting, for urgent alerts
}

/// State of a check box or toggle.
enum Toggle : ubyte
{
    none, /// not a toggle
    off,  /// unchecked
    on,   /// checked
    mixed, /// partly checked
}

/// Optional yes or no, for states that only some roles have.
enum Tri : ubyte
{
    unset, /// the role has no such state
    no,    /// false
    yes,   /// true
}

/// `Tri` of `b`.
Tri tri(bool b)
{
    return b ? Tri.yes : Tri.no;
}

/// What an assistive technology can ask a node to do.
enum AccessAction : ubyte
{
    click,           /// default action, as a press would
    focus,           /// take keyboard focus
    increment,       /// step up
    decrement,       /// step down
    setValue,        /// replace text or number
    expand,          /// open children or a popup
    collapse,        /// close children or a popup
    scrollIntoView,  /// bring into the visible part of its scroll views
    showContextMenu, /// open the context menu
    setSelection,    /// move the caret or selection of a text field
}

/// Line of a text field as laid out, so screen readers find each character on screen.
struct AccessLine
{
    size_t from;   /// first byte in the field's value
    size_t to;     /// byte after the last, past the newline ending it
    Rect rect;     /// line box in window coordinates
    float[] edges; /// x of each character's left edge from `rect.x`, then of the line's right end
}

/// Accessible description of a node, filled by `Node.describe`.
struct AccessInfo
{
    Role role;          /// role, `Role.none` to stay out
    string label;       /// name, such as a caption
    string value;       /// text content or current choice
    string description; /// longer help, the tooltip if not set and the node has a label
    string placeholder; /// hint shown in an empty text field
    string shortcut;    /// key that runs it, such as "Ctrl+S"
    Toggle toggled;     /// check state
    Tri selected;       /// whether it is the chosen row, tab or option
    Tri expanded;       /// whether its children or popup are open
    bool disabled;      /// shown but inactive
    bool readOnly;      /// value cannot be edited
    bool modal;         /// blocks the rest of the window
    bool multiselectable; /// several rows can be chosen
    bool leaf;          /// children stay out, for nodes that name themselves
    bool hidden;        /// the node and its children stay out
    double number;      /// numeric value, NaN for none
    double min;         /// lowest numeric value, NaN for none
    double max;         /// highest numeric value, NaN for none
    double step;        /// step of increment and decrement, NaN for none
    uint level;         /// tree depth from 1, 0 for none
    uint position;      /// place in its set from 1, 0 for none
    uint setSize;       /// items in its set, 0 for none
    uint rowIndex;      /// table rows and cells: row from 1, the header row being 1, 0 for none
    uint columnIndex;   /// cells and column headers: column from 1, 0 for none
    uint rowCount;      /// tables: rows with the header row, 0 for none
    uint columnCount;   /// tables: columns, 0 for none
    size_t caret = size_t.max;  /// text fields: caret as a byte offset into `value`, `size_t.max` for none
    size_t anchor = size_t.max; /// text fields: other end of the selection, the caret when nothing is selected
    AccessLine[] lines; /// text fields: lines covering `value` as laid out, empty when unknown
    Live live;          /// how changes are announced
    ushort actions;     /// supported actions, one bit per `AccessAction` value

    /// Adds `a` to the supported actions.
    void allow(AccessAction a)
    {
        actions |= cast(ushort)(1 << a);
    }

    /// True if `a` is supported.
    bool allows(AccessAction a) const
    {
        return (actions & (1 << a)) != 0;
    }

    /// Field by field, with NaN equal to NaN.
    bool opEquals(ref const AccessInfo o) const
    {
        static foreach (size_t i; 0 .. this.tupleof.length)
        {
            static if (__traits(isFloating, this.tupleof[i]))
            {
                if (this.tupleof[i] != o.tupleof[i] && (isNaN(this.tupleof[i]) && isNaN(o.tupleof[i])) == false)
                {
                    return false;
                }
            }
            else if (this.tupleof[i] != o.tupleof[i])
            {
                return false;
            }
        }
        return true;
    }
}

/// Node as an adapter sees it.
struct AccessNode
{
    ulong id;         /// node id, stable for the node's life
    AccessInfo info;  /// what the node exposes
    Rect bounds;      /// bounds in window coordinates, logical pixels
    ulong[] children; /// exposed children in order
    ulong labelledBy; /// id of the exposed node naming it, 0 for none

    /// Same description, bounds, children and label.
    bool opEquals(ref const AccessNode o) const
    {
        return id == o.id && info == o.info && bounds == o.bounds && children == o.children
            && labelledBy == o.labelledBy;
    }
}

/// Nodes for an adapter, from `AccessTree.update`.
struct AccessUpdate
{
    AccessNode[] nodes; /// changed and new nodes, every node when `full`
    ulong root;         /// id of the window node
    ulong focus;        /// id of the focused node, the window node when none
    bool full;          /// first update after an adapter activated
}

/// What an assistive technology asked for, delivered as an `Event` of kind `access`.
struct AccessRequest
{
    ulong target;        /// id of the node to act on
    AccessAction action; /// action to run
    string text;         /// `setValue`: new text, null when `number` is set
    double number;       /// `setValue`: new number, NaN when `text` is set
    size_t anchor = size_t.max; /// `setSelection`: fixed end, a byte offset into the value
    size_t caret = size_t.max;  /// `setSelection`: moving end, a byte offset into the value
}

/// What the next update must hold, from `AccessAdapter.demand`.
enum AccessDemand
{
    none,    /// no assistive technology listens
    changes, /// only the changed nodes
    full,    /// every node, after activation
}

/// Platform side of accessibility. The host updates it after every frame while `demand` is not `none`.
interface AccessAdapter
{
    /// What the next update must hold. Reading `full` resets it to `changes`. Called on the UI thread.
    AccessDemand demand();
    /// Sends `u`. Bounds are logical, `scale` is physical pixels per logical pixel.
    void update(ref const AccessUpdate u, float scale);
}

/// Node holding focus for controls it draws itself, such as an island, reports which one has it.
interface AccessFocus
{
    Node accessFocus(); /// node with focus inside, or null for this node
}

/// Node that runs actions for descendants without their own, such as an island for its controls.
interface AccessActions
{
    /// Runs `r` on `n`, true if done.
    bool accessActionFor(Node n, ref const AccessRequest r);
}

/// Node whose exposed descendants are not its children, such as an island and its last pass.
interface AccessContent
{
    Node accessContent(); /// root of those nodes, or null
}

/// Node drawing several items without a node each, such as a tab strip. Each item is exposed before the node's
/// children, as a child of the node, or of its nearest exposed parent when the node itself is not exposed.
interface AccessParts
{
    size_t accessPartCount();                                   /// number of items
    void describePart(size_t i, ref AccessInfo a, ref Rect r);  /// fills item `i`, `r` starts as the node's bounds
    bool accessPartAction(size_t i, ref const AccessRequest r); /// runs `r` on item `i`, true if done
    ptrdiff_t accessFocusPart();                                /// item with the node's focus, or -1
}

/// `AccessParts` node whose items hold other items or its children, such as a dock view with a tab list and a
/// pane per stack.
interface AccessPartTree : AccessParts
{
    ptrdiff_t partParent(size_t i); /// item holding item `i`, one before it, or -1 for none
    ptrdiff_t childPart(Node c);    /// item holding child `c`, or -1 for none
}

/// Id of the window node.
enum ulong accessRootId = 1;

/// Next id for a node without one. Ids with one of the top three bits set are left to islands, parts and text
/// runs.
private ulong nextAccessId = accessRootId + 1;

/// Id of `n`, assigned on first use.
ulong accessIdOf(Node n)
{
    if (n.accessId == 0)
    {
        n.accessId = nextAccessId++;
    }
    return n.accessId;
}

/// Exposed nodes of a tree and what was last sent for them.
final class AccessTree
{
    string title;                  /// window title, the name of the window node
    private AccessNode[ulong] sent; /// nodes as last sent, by id
    private Node[ulong] nodes;      /// tree node by id, as of the last update
    private AccessActions[ulong] handlers; /// node running the actions of a node by id, where not the node
    private size_t[ulong] parts;    /// item index of the ids that stand for an `AccessParts` item

    /// Nodes changed since the last update, or all of them when `full`, with `focus` mapped to its id.
    AccessUpdate update(Tree t, Node focus, bool full)
    {
        AccessNode[ulong] now;
        Node[ulong] byId;
        AccessNode root;
        root.id = accessRootId;
        root.info.role = Role.window;
        root.info.label = title;
        root.bounds = Rect(0, 0, t.viewport.w, t.viewport.h);
        AccessActions[ulong] by;
        parts = null;
        collect(t.root, root.children, now, byId, by, null, false);
        now[root.id] = root;
        foreach (ref AccessNode n; now)
        {
            if (n.labelledBy != 0 && (n.labelledBy in now) is null)
            {
                n.labelledBy = 0;
            }
        }
        AccessUpdate u;
        u.root = accessRootId;
        u.full = full;
        u.focus = focusId(focus, byId);
        foreach (ulong id, ref AccessNode n; now)
        {
            const(AccessNode)* old = id in sent;
            if (full || old is null || *old != n)
            {
                u.nodes ~= n;
            }
        }
        sent = now;
        nodes = byId;
        handlers = by;
        return u;
    }

    /// Tree node of `id` as of the last update, or null.
    Node nodeOf(ulong id)
    {
        Node* n = id in nodes;
        return n is null ? null : *n;
    }

    /// Last sent node of `id`, or null.
    const(AccessNode)* find(ulong id) const
    {
        return id in sent;
    }

    /// First node in tree order with `role` and `label`, or null. For tests.
    const(AccessNode)* find(Role role, string label) const
    {
        return search(accessRootId, role, label);
    }

    /// Depth first search under `id`.
    private const(AccessNode)* search(ulong id, Role role, string label) const
    {
        const(AccessNode)* n = id in sent;
        if (n is null)
        {
            return null;
        }
        if (n.info.role == role && n.info.label == label)
        {
            return n;
        }
        foreach (ulong c; n.children)
        {
            if (const(AccessNode)* hit = search(c, role, label))
            {
                return hit;
            }
        }
        return null;
    }

    /// Index of the item `id` stands for in the `AccessParts` node `nodeOf(id)` returns, or -1 when `id` is that
    /// node itself.
    ptrdiff_t partOf(ulong id)
    {
        size_t* i = id in parts;
        return i is null ? -1 : *i;
    }

    /// Node running the actions of `id` for it, such as its island, or null.
    AccessActions handlerOf(ulong id)
    {
        AccessActions* h = id in handlers;
        return h is null ? null : *h;
    }

    /// Adds the exposed nodes under `n` to `into`, their descriptions to `now`, and `owner` as the action handler
    /// of each when set. `menu` is set inside a node with a context menu. The items of an `AccessParts` node come
    /// first, and only they when `leaf` is set.
    private void collect(Node n, ref ulong[] into, ref AccessNode[ulong] now, ref Node[ulong] byId,
        ref AccessActions[ulong] by, AccessActions owner, bool menu, bool leaf = false)
    {
        menu = menu || n.hasContextMenu;
        if (AccessActions h = cast(AccessActions) n)
        {
            owner = h;
        }
        AccessNode[] items;
        ulong[][] held; // ids each item holds
        ulong[] top;
        AccessPartTree nest = cast(AccessPartTree) n;
        if (AccessParts p = cast(AccessParts) n)
        {
            ulong id = accessIdOf(n);
            items.length = p.accessPartCount();
            held.length = items.length;
            foreach (size_t i, ref AccessNode pn; items)
            {
                pn.id = partId(id, i);
                pn.bounds = n.bounds;
                p.describePart(i, pn.info, pn.bounds);
                ptrdiff_t up = nest is null ? -1 : nest.partParent(i);
                if (up >= 0 && up < i)
                {
                    held[up] ~= pn.id;
                }
                else
                {
                    top ~= pn.id;
                }
            }
        }
        Node[] kids = leaf ? null : n.children;
        if (AccessContent ac = cast(AccessContent) n)
        {
            Node inner = ac.accessContent();
            kids = inner is null || leaf ? null : [inner];
        }
        foreach (Node c; kids)
        {
            ptrdiff_t k = nest is null ? -1 : nest.childPart(c);
            visit(c, k >= 0 && k < items.length ? held[k] : top, now, byId, by, owner, menu);
        }
        foreach (size_t i, ref AccessNode pn; items)
        {
            pn.children = held[i];
            now[pn.id] = pn;
            byId[pn.id] = n;
            parts[pn.id] = i;
        }
        into ~= top;
    }

    /// Adds `c` to `into` when exposed, else its exposed descendants, as `collect` does for each child.
    private void visit(Node c, ref ulong[] into, ref AccessNode[ulong] now, ref Node[ulong] byId,
        ref AccessActions[ulong] by, AccessActions owner, bool menu)
    {
        AccessInfo a;
        c.describe(a);
        if (a.hidden)
        {
            return;
        }
        if (a.role == Role.none)
        {
            collect(c, into, now, byId, by, owner, menu);
            return;
        }
        if (c.accessName !is null)
        {
            a.label = c.accessName;
        }
        else if (c.labelledBy !is null)
        {
            a.label = nameOf(c.labelledBy);
        }
        if (c.accessLive != Live.off)
        {
            a.live = c.accessLive;
        }
        if (a.label.length == 0 && a.role != Role.label)
        {
            a.label = c.tooltip;
        }
        else if (a.description.length == 0)
        {
            a.description = c.tooltip;
        }
        if (c.focusable && a.disabled == false)
        {
            a.allow(AccessAction.focus);
        }
        if ((menu || c.hasContextMenu) && a.disabled == false)
        {
            a.allow(AccessAction.showContextMenu);
        }
        AccessNode an;
        an.id = accessIdOf(c);
        an.info = a;
        an.bounds = c.bounds;
        an.labelledBy = c.labelledBy is null ? 0 : accessIdOf(c.labelledBy);
        collect(c, an.children, now, byId, by, owner, menu, a.leaf);
        into ~= an.id;
        now[an.id] = an;
        byId[an.id] = c;
        if (owner !is null)
        {
            by[an.id] = owner;
        }
    }

    /// Id of item `i` of the node with id `id`. Bit 62 keeps it apart from other ids, bit 63 from islands.
    private static ulong partId(ulong id, size_t i)
    {
        return (mixId(i, id) | 1UL << 62) & ~(1UL << 63);
    }

    /// Id of the nearest exposed node at or above `focus`, asking `AccessFocus` and `AccessParts` nodes first.
    private ulong focusId(Node focus, ref Node[ulong] byId)
    {
        if (AccessFocus f = cast(AccessFocus) focus)
        {
            if (Node inner = f.accessFocus())
            {
                focus = inner;
            }
        }
        if (AccessParts p = cast(AccessParts) focus)
        {
            ptrdiff_t i = p.accessFocusPart();
            if (i >= 0 && focus.accessId != 0 && (partId(focus.accessId, i) in byId) !is null)
            {
                return partId(focus.accessId, i);
            }
        }
        for (Node n = focus; n !is null; n = n.parent)
        {
            if (n.accessId != 0 && (n.accessId in byId) !is null)
            {
                return n.accessId;
            }
        }
        return accessRootId;
    }
}

/// Name of `n` for the nodes it labels: its `accessName`, else what it describes.
string nameOf(Node n)
{
    if (n.accessName !is null)
    {
        return n.accessName;
    }
    AccessInfo a;
    n.describe(a);
    return a.label;
}

/// Text of the labels under `n` in tree order, joined by `sep`, for rows named by their content.
string contentText(Node n, string sep = " ")
{
    string s;
    foreach (Node c; n.children)
    {
        AccessInfo a;
        c.describe(a);
        string part = a.role == Role.label ? a.label : contentText(c, sep);
        if (a.hidden || part.length == 0)
        {
            continue;
        }
        s ~= s.length > 0 ? sep ~ part : part;
    }
    return s;
}

// The host sends the whole tree when an adapter starts listening, then only what changed, and runs actions.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.immediate : Ui;
    import dentrite.island : island;
    import dentrite.platform : Event, EventKind, WindowOptions;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.button : button;
    import dentrite.widgets.checkbox : checkbox;
    import dentrite.widgets.label : label;

    WindowOptions o;
    o.title = "Test";
    o.accessibility = true;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(300, 200);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }

    /// Sends `action` to node `id` and runs a frame.
    void ask(ulong id, AccessAction action)
    {
        Event e = {kind: EventKind.access, request: AccessRequest(id, action)};
        h.handle(e);
        h.frame();
    }

    int saved;
    Signal!bool wrap = signal(false);
    h.setRoot(column()(label("Settings"), button("Save", onClick: () { ++saved; }), checkbox(wrap, "Wrap")));
    h.frame();
    assert(p.accessUpdates.length == 0, "nothing is sent while no one listens");
    p.listening = AccessDemand.full;
    h.frame();
    AccessUpdate u = p.accessUpdates[$ - 1];
    assert(u.full && u.nodes.length == 4 && u.focus == accessRootId);
    assert(h.access.find(accessRootId).info.label == "Test");
    assert(h.access.find(Role.label, "Settings") !is null);
    const(AccessNode)* save = h.access.find(Role.button, "Save");
    assert(save.info.allows(AccessAction.click) && save.info.allows(AccessAction.focus));
    ask(save.id, AccessAction.click);
    assert(saved == 1);
    h.click(Role.button, "Save");
    assert(saved == 2 && h.find(Role.checkBox, "Wrap") !is null && h.find(Role.button, "Load") is null,
        "tests find and click by role and name, apart from what the adapter is sent");

    ulong box = h.access.find(Role.checkBox, "Wrap").id;
    size_t sent = p.accessUpdates.length;
    ask(box, AccessAction.click);
    assert(wrap.peek);
    u = p.accessUpdates[$ - 1];
    assert(p.accessUpdates.length == sent + 1 && u.full == false, "a change sends one update");
    assert(u.nodes.length == 1 && u.nodes[0].id == box && u.nodes[0].info.toggled == Toggle.on);
    ask(save.id, AccessAction.focus);
    assert(p.accessUpdates[$ - 1].focus == save.id && h.focused.accessId == save.id);
    sent = p.accessUpdates.length;
    h.requestFrame();
    h.frame();
    assert(p.accessUpdates.length == sent, "an unchanged tree sends nothing");

    int went;
    bool bold;
    h.setRoot(island((Ui ui) {
        if (ui.button("Go"))
        {
            ++went;
        }
        ui.checkbox(bold, "Bold");
    }));
    h.frame();
    ulong go = h.access.find(Role.button, "Go").id;
    assert(go >> 63 == 1 && h.access.find(Role.group, null) !is null);
    ask(go, AccessAction.click);
    assert(went == 1);
    assert(h.access.find(Role.button, "Go").id == go, "island controls keep their ids across passes");
    ulong b = h.access.find(Role.checkBox, "Bold").id;
    ask(b, AccessAction.focus);
    assert(p.accessUpdates[$ - 1].focus == b, "focus inside an island goes to the control");
    ask(b, AccessAction.click);
    assert(bold && h.access.find(b).info.toggled == Toggle.on);
}

/// True if every exposed node under `n` is a label, so a row named by `contentText` can leave them out.
bool textOnly(Node n)
{
    foreach (Node c; n.children)
    {
        AccessInfo a;
        c.describe(a);
        if (a.hidden == false && ((a.role != Role.none && a.role != Role.label) || textOnly(c) == false))
        {
            return false;
        }
    }
    return true;
}

/// Text of `n` itself if it is a label, else of the labels under it, for cells named by their content.
string nodeText(Node n, string sep = " ")
{
    AccessInfo a;
    n.describe(a);
    return a.role == Role.label ? a.label : contentText(n, sep);
}

// A label names the control it is for, with a relation only while the label is exposed, and a click on it focuses
// the control, in islands too. A live label says how its changes are announced, and a dock view exposes per stack
// a tab list and a pane named by the chosen tab.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column, row, sized;
    import dentrite.dock : DockNode, DockSpace, DockView;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.immediate : Ui;
    import dentrite.island : island;
    import dentrite.platform : Event, EventKind, WindowOptions;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.button : button;
    import dentrite.widgets.label : Label, label;
    import dentrite.widgets.textbox : TextBox, textBox;

    WindowOptions o;
    o.accessibility = true;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(400, 300);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }

    /// Sends `action` to node `id` and runs a frame.
    void ask(ulong id, AccessAction action)
    {
        Event e = {kind: EventKind.access, request: AccessRequest(id, action)};
        h.handle(e);
        h.frame();
    }

    p.listening = AccessDemand.full;
    Signal!string name = signal("");
    Signal!string status = signal("Idle");
    TextBox box = textBox(name);
    Label caption = label("File name", for_: box);
    Label line = label(() => status.get, live: Live.polite);
    Node[string] panes = ["log": button("Clear"), "calls": label("No calls"), "watch": label("Empty")];
    DockView dock = new DockView(new DockSpace(DockNode.split(false, DockNode.stack("log", "calls"),
        DockNode.stack("watch"))), panes, ["log": "Log", "calls": "Calls"]);
    h.setRoot(column()(row()(caption, sized(w: 150)(box)), line, sized(h: 200)(dock)));
    h.frame();

    const(AccessNode)* field = h.access.find(Role.textInput, "File name");
    assert(field !is null && field.labelledBy == caption.accessId);
    h.click(Role.label, "File name");
    assert(h.focused is box, "a click on the label focuses its control");
    assert(h.access.find(Role.label, "Idle").info.live == Live.polite);
    const(AccessNode)* log = h.access.find(Role.pane, "Log");
    const(AccessNode)* watch = h.access.find(Role.pane, "watch");
    assert(log !is null && watch !is null, "named by the title, or the ID without one");
    assert(log.children == [panes["log"].accessId] && log.bounds == panes["log"].bounds);
    const(AccessNode)* calls = h.access.find(Role.tab, "Calls");
    assert(h.access.find(Role.tab, "Log").info.selected == Tri.yes && calls.info.selected == Tri.no);
    assert(h.access.find(Role.pane, "Calls") is null, "a pane only for the chosen tab");
    ask(calls.id, AccessAction.click);
    log = h.access.find(Role.pane, "Calls");
    assert(log !is null && log.children == [panes["calls"].accessId], "a tab chosen from a screen reader");
    assert(h.access.find(Role.tab, "Calls").info.selected == Tri.yes);
    h.click(Role.tab, "Log");
    assert(h.access.find(Role.pane, "Log") !is null, "tabs sit where they are drawn");

    caption.setText("Path");
    h.frame();
    assert(h.access.find(Role.textInput, "Path") !is null, "follows the label");
    caption.accessName = "Hidden";
    caption.parent.setChildren([box.parent]);
    h.frame();
    field = h.access.find(Role.textInput, "Hidden");
    assert(field !is null && field.labelledBy == 0, "no relation to a label that is gone");

    string mail;
    h.setRoot(island((Ui ui) {
        ui.label("Mail", forNext: true);
        ui.textBox(mail);
        ui.label(mail.length > 0 ? "Typed" : "Empty", live: Live.assertive);
    }));
    h.frame();
    field = h.access.find(Role.textInput, "Mail");
    assert(field !is null && field.labelledBy == h.access.find(Role.label, "Mail").id);
    assert(h.access.find(Role.label, "Empty").info.live == Live.assertive);
    h.click(Role.label, "Mail");
    assert(p.accessUpdates[$ - 1].focus == field.id, "a click on an island label focuses the control");
}

// Text fields report where each character is, line by line, and a screen reader moves their caret and selection.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column, sized;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : Event, EventKind, WindowOptions;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.textarea : TextArea, TextPos, textArea;
    import dentrite.widgets.textbox : TextBox, textBox;

    WindowOptions o;
    o.accessibility = true;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(400, 300);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    p.listening = AccessDemand.full;

    /// Asks node `id` to select from byte `anchor` to byte `caret`, then runs a frame.
    void select(ulong id, size_t anchor, size_t caret)
    {
        Event e = {kind: EventKind.access};
        e.request = AccessRequest(id, AccessAction.setSelection, null, double.nan, anchor, caret);
        h.handle(e);
        h.frame();
    }

    TextBox box = textBox(signal("héllo"), accessName: "Word");
    TextArea area = textArea(signal("ab\ncd"), accessName: "Notes");
    h.setRoot(column()(sized(w: 200)(box), sized(w: 200, h: 100)(area)));
    h.frame();

    const(AccessNode)* b = h.access.find(Role.textInput, "Word");
    assert(b.info.allows(AccessAction.setSelection) && b.info.lines.length == 1);
    const(AccessLine) l = b.info.lines[0];
    assert(l.from == 0 && l.to == "héllo".length && l.edges.length == 6, "an edge per character, then the end");
    assert(l.edges[0] == 0 && l.edges[1] > 0 && l.edges[5] > l.edges[4] && l.rect.w == l.edges[5]);
    assert(l.rect.x > b.bounds.x && l.rect.y > b.bounds.y && l.rect.bottom < b.bounds.bottom, "inside the padding");
    select(b.id, 0, 3);
    assert(box.line.anchor == 0 && box.line.caret == 3, "selects \"hé\"");
    assert(h.access.find(b.id).info.caret == 3);

    const(AccessNode)* a = h.access.find(Role.multilineTextInput, "Notes");
    assert(a.info.lines.length == 2);
    const(AccessLine) first = a.info.lines[0];
    const(AccessLine) second = a.info.lines[1];
    assert(first.from == 0 && first.to == 3 && first.edges.length == 4, "the newline ends the first line");
    assert(first.edges[3] == first.edges[2], "the newline takes no room");
    assert(second.from == 3 && second.to == 5 && second.rect.y == first.rect.bottom);
    select(a.id, 4, 4);
    assert(area.caret == TextPos(1, 1) && area.anchor == area.caret);
}
