/// Docking layout: splits, tab stacks and floating windows, with drop zones and save/restore, and
/// `DockView`, the retained view with tab dragging.
///
/// `DockSpace` is pure data. A retained UI keeps this tree as its shell, an immediate UI
/// stores it in persistent memory and walks it every frame. Panes are string
/// IDs that the application maps to content.
module dentrite.dock;

import dentrite.access : AccessPartTree;
import dentrite.geom : Point, Rect;
import dentrite.node;
import dentrite.signals : Effect, Signal, effect, runWithOwner;
import dentrite.text : FontKind, TextSystem;
import dentrite.widgets.menu : Menu;
import dentrite.widgets.tabs : TabInfo, TabLook, TabStrip, paintRow, paintSlot, rowWidth, slotRect;
import std.algorithm.comparison : max, min;
import std.algorithm.mutation : remove;
import std.algorithm.searching : countUntil;
import std.math : round;
import std.json;

/// Kind of dock tree node.
enum Kind
{
    split, /// children side by side or stacked
    tabs,  /// panes sharing one area, one visible
}

/// Where a dragged pane lands relative to a tab stack.
enum Zone
{
    none,   /// no drop
    center, /// join the stack as a tab
    left,   /// split, new pane on the left
    right,  /// split, new pane on the right
    top,    /// split, new pane on top
    bottom, /// split, new pane at the bottom
}

/// Splitter thickness between split children.
enum float splitterSize = 4;

/// Tab bar height of a stack.
enum float tabBarHeight = 24;

/// Part of the main area a pane docked to its edge takes.
enum float outerShare = 0.25;

/// Node of the dock tree.
final class DockNode
{
    Kind kind;            /// whether it splits its area or stacks panes as tabs
    bool vertical;        /// split direction, true stacks children top to bottom
    float[] shares;       /// split weights, one per child
    DockNode[] children;  /// child nodes of a split
    string[] panes;       /// pane IDs of a tab stack, in tab order
    size_t active;        /// index of the selected tab
    DockNode parent;      /// parent node, null for a root
    Rect rect;            /// area in logical pixels, set by `DockSpace.layout`

    /// New tab stack holding `panes`.
    static DockNode stack(string[] panes...)
    {
        DockNode n = new DockNode;
        n.kind = Kind.tabs;
        n.panes = panes.dup;
        return n;
    }

    /// New split of `kids` with equal shares.
    static DockNode split(bool vertical, DockNode[] kids...)
    {
        DockNode n = new DockNode;
        n.kind = Kind.split;
        n.vertical = vertical;
        foreach (DockNode k; kids)
        {
            n.children ~= k;
            n.shares ~= 1;
            k.parent = n;
        }
        return n;
    }

    /// True for a stack with no panes or a split with no children.
    bool empty() const
    {
        return kind == Kind.tabs ? panes.length == 0 : children.length == 0;
    }
}

/// Window with its own dock tree, outside the main area.
struct Floating
{
    Rect rect;     /// window rectangle in logical pixels
    DockNode root; /// dock tree inside the window
}

/// Main dock tree plus floating windows.
final class DockSpace
{
    DockNode root;        /// dock tree of the main area
    Floating[] floating;  /// detached windows, last on top

    /// Creates a space with `root` as the main tree.
    this(DockNode root)
    {
        this.root = root;
    }

    /// Assigns rects: splits divide by share, stacks reserve a tab bar. Floating windows are moved and shrunk
    /// into `area` for the layout, keeping their stored rects.
    void layout(Rect area)
    {
        place(root, area);
        foreach (ref Floating f; floating)
        {
            place(f.root, keepIn(f.rect, area));
        }
    }

    /// `r` moved and shrunk to fit inside `area`.
    static Rect keepIn(Rect r, Rect area)
    {
        import std.algorithm.comparison : clamp;

        float w = min(r.w, area.w);
        float h = min(r.h, area.h);
        return Rect(clamp(r.x, area.x, area.right - w), clamp(r.y, area.y, area.bottom - h), w, h);
    }

    /// Every pane, main tree first.
    string[] paneIds()
    {
        string[] ids;
        void walk(DockNode n)
        {
            ids ~= n.panes;
            foreach (DockNode c; n.children)
            {
                walk(c);
            }
        }

        walk(root);
        foreach (ref Floating f; floating)
        {
            walk(f.root);
        }
        return ids;
    }

    /// Every tab stack, main tree first.
    DockNode[] stacks()
    {
        DockNode[] all;
        void walk(DockNode n)
        {
            if (n.kind == Kind.tabs)
            {
                all ~= n;
                return;
            }
            foreach (DockNode c; n.children)
            {
                walk(c);
            }
        }

        walk(root);
        foreach (ref Floating f; floating)
        {
            walk(f.root);
        }
        return all;
    }

    /// Index into `floating` of the window holding `n`, or -1 for the main tree.
    ptrdiff_t windowOf(DockNode n)
    {
        while (n.parent !is null)
        {
            n = n.parent;
        }
        foreach (size_t i, ref Floating f; floating)
        {
            if (f.root is n)
            {
                return i;
            }
        }
        return -1;
    }

    /// Puts floating window `i` on top, returning its new index.
    size_t raise(size_t i)
    {
        Floating f = floating[i];
        floating = floating.remove(i) ~ f;
        return floating.length - 1;
    }

    /// Recursive part of `layout`.
    private void place(DockNode n, Rect r)
    {
        n.rect = r;
        if (n.kind == Kind.tabs)
        {
            return;
        }
        float total = 0;
        foreach (float s; n.shares)
        {
            total += s;
        }
        float extent = (n.vertical ? r.h : r.w) - splitterSize * (n.children.length - 1);
        float pos = n.vertical ? r.y : r.x;
        foreach (size_t i, DockNode c; n.children)
        {
            float len = extent * n.shares[i] / total;
            place(c, n.vertical ? Rect(r.x, pos, r.w, len) : Rect(pos, r.y, len, r.h));
            pos += len + splitterSize;
        }
    }

    /// Stack holding `pane`, or null.
    DockNode find(string pane)
    {
        DockNode hit = findIn(root, pane);
        foreach (ref Floating f; floating)
        {
            if (hit is null)
            {
                hit = findIn(f.root, pane);
            }
        }
        return hit;
    }

    /// Recursive part of `find`.
    private static DockNode findIn(DockNode n, string pane)
    {
        if (n.kind == Kind.tabs)
        {
            return countUntil(n.panes, pane) >= 0 ? n : null;
        }
        foreach (DockNode c; n.children)
        {
            if (DockNode hit = findIn(c, pane))
            {
                return hit;
            }
        }
        return null;
    }

    /// Stack under `p`, floating windows first, or null.
    DockNode stackAt(Point p)
    {
        foreach_reverse (ref Floating f; floating)
        {
            if (DockNode hit = stackIn(f.root, p))
            {
                return hit;
            }
        }
        return stackIn(root, p);
    }

    /// Recursive part of `stackAt`.
    private static DockNode stackIn(DockNode n, Point p)
    {
        if (n.rect.contains(p) == false)
        {
            return null;
        }
        if (n.kind == Kind.tabs)
        {
            return n;
        }
        foreach (DockNode c; n.children)
        {
            if (DockNode hit = stackIn(c, p))
            {
                return hit;
            }
        }
        return null;
    }

    /// Drop zone for `p` over `target`: the middle half joins, otherwise the nearest edge splits.
    static Zone zoneAt(DockNode target, Point p)
    {
        Rect r = target.rect;
        if (r.contains(p) == false)
        {
            return Zone.none;
        }
        float fx = (p.x - r.x) / r.w;
        float fy = (p.y - r.y) / r.h;
        if (fx >= 0.25 && fx <= 0.75 && fy >= 0.25 && fy <= 0.75)
        {
            return Zone.center;
        }
        float best = fx;
        Zone z = Zone.left;
        if (1 - fx < best)
        {
            best = 1 - fx;
            z = Zone.right;
        }
        if (fy < best)
        {
            best = fy;
            z = Zone.top;
        }
        if (1 - fy < best)
        {
            z = Zone.bottom;
        }
        return z;
    }

    /// Rect to highlight while dragging over `target` at zone `z`.
    static Rect preview(DockNode target, Zone z)
    {
        return part(target.rect, z, 0.5);
    }

    /// Rect to highlight while dragging to edge `z` of the main area.
    Rect outerPreview(Zone z)
    {
        return part(root.rect, z, outerShare);
    }

    /// Fraction `f` of `r` on side `z`, all of it for the center.
    static Rect part(Rect r, Zone z, float f)
    {
        final switch (z)
        {
        case Zone.none:
            return Rect.init;
        case Zone.center:
            return r;
        case Zone.left:
            return Rect(r.x, r.y, r.w * f, r.h);
        case Zone.right:
            return Rect(r.right - r.w * f, r.y, r.w * f, r.h);
        case Zone.top:
            return Rect(r.x, r.y, r.w, r.h * f);
        case Zone.bottom:
            return Rect(r.x, r.bottom - r.h * f, r.w, r.h * f);
        }
    }

    /// Moves `pane` into or beside `target`, then simplifies.
    void dock(string pane, DockNode target, Zone z)
    {
        if (z == Zone.none || (target.panes == [pane]))
        {
            return;
        }
        detach(pane);
        if (z == Zone.center)
        {
            target.panes ~= pane;
            target.active = target.panes.length - 1;
            simplify();
            return;
        }
        bool vertical = z == Zone.top || z == Zone.bottom;
        bool before = z == Zone.left || z == Zone.top;
        DockNode added = DockNode.stack(pane);
        DockNode p = target.parent;
        if (p !is null && p.vertical == vertical)
        {
            size_t i = countUntil(p.children, target);
            float half = p.shares[i] / 2;
            p.shares[i] = half;
            size_t at = before ? i : i + 1;
            p.children = p.children[0 .. at] ~ added ~ p.children[at .. $];
            p.shares = p.shares[0 .. at] ~ half ~ p.shares[at .. $];
            added.parent = p;
        }
        else
        {
            DockNode s = before ? DockNode.split(vertical, added, target)
                : DockNode.split(vertical, target, added);
            replace(target, s, p);
        }
        simplify();
    }

    /// Moves `pane` to edge `z` of the main area, where it takes `outerShare` of it, then simplifies.
    void dockOuter(string pane, Zone z)
    {
        if (z == Zone.none || z == Zone.center)
        {
            return;
        }
        detach(pane);
        bool vertical = z == Zone.top || z == Zone.bottom;
        DockNode added = DockNode.stack(pane);
        DockNode s;
        if (z == Zone.left || z == Zone.top)
        {
            s = DockNode.split(vertical, added, root);
            s.shares = [outerShare, 1 - outerShare];
        }
        else
        {
            s = DockNode.split(vertical, root, added);
            s.shares = [1 - outerShare, outerShare];
        }
        root = s;
        simplify();
    }

    /// Moves `pane` to tab position `index` of `target`, which may already hold it, then simplifies.
    void move(string pane, DockNode target, size_t index)
    {
        if (find(pane) is target)
        {
            size_t at = countUntil(target.panes, pane);
            if (index > at)
            {
                --index;
            }
        }
        detach(pane);
        index = min(index, target.panes.length);
        target.panes = target.panes[0 .. index] ~ pane ~ target.panes[index .. $];
        target.active = index;
        simplify();
    }

    /// Moves `pane` into a new floating window at `r`.
    void undock(string pane, Rect r)
    {
        detach(pane);
        floating ~= Floating(r, DockNode.stack(pane));
        simplify();
    }

    /// Removes `pane`, then simplifies. Its stack shows the tab that followed it, or the one before.
    void remove(string pane)
    {
        detach(pane);
        simplify();
    }

    /// Removes `pane` from its stack, leaving the stack possibly empty.
    private void detach(string pane)
    {
        DockNode s = find(pane);
        if (s is null)
        {
            return;
        }
        size_t i = countUntil(s.panes, pane);
        s.panes = s.panes.remove(i);
        if (i < s.active)
        {
            --s.active;
        }
        s.active = s.panes.length == 0 ? 0 : min(s.active, s.panes.length - 1);
    }

    /// Puts `with_` where `old` was under `p`, or makes it the root.
    private void replace(DockNode old, DockNode with_, DockNode p)
    {
        with_.parent = p;
        if (p is null)
        {
            if (root is old)
            {
                root = with_;
            }
            foreach (ref Floating f; floating)
            {
                if (f.root is old)
                {
                    f.root = with_;
                }
            }
            return;
        }
        p.children[countUntil(p.children, old)] = with_;
    }

    /// Drops empty nodes, collapses single-child splits, flattens same-direction nesting.
    void simplify()
    {
        root = tidy(root);
        if (root is null)
        {
            root = DockNode.stack();
        }
        root.parent = null;
        Floating[] kept;
        foreach (ref Floating f; floating)
        {
            f.root = tidy(f.root);
            if (f.root !is null)
            {
                f.root.parent = null;
                kept ~= f;
            }
        }
        floating = kept;
    }

    /// Simplified replacement for `n`, or null if nothing is left.
    private static DockNode tidy(DockNode n)
    {
        if (n.kind == Kind.tabs)
        {
            return n.empty ? null : n;
        }
        DockNode[] kids;
        float[] shares;
        foreach (size_t i, DockNode c; n.children)
        {
            DockNode t = tidy(c);
            if (t is null)
            {
                continue;
            }
            if (t.kind == Kind.split && t.vertical == n.vertical)
            {
                float sum = 0;
                foreach (float s; t.shares)
                {
                    sum += s;
                }
                foreach (size_t j, DockNode g; t.children)
                {
                    kids ~= g;
                    shares ~= n.shares[i] * t.shares[j] / sum;
                }
                continue;
            }
            kids ~= t;
            shares ~= n.shares[i];
        }
        if (kids.length == 0)
        {
            return null;
        }
        if (kids.length == 1)
        {
            return kids[0];
        }
        n.children = kids;
        n.shares = shares;
        foreach (DockNode k; kids)
        {
            k.parent = n;
        }
        return n;
    }

    /// Layout as JSON, for the settings file.
    JSONValue save()
    {
        JSONValue[] wins;
        foreach (ref Floating f; floating)
        {
            JSONValue w = JSONValue(["x": f.rect.x, "y": f.rect.y, "w": f.rect.w, "h": f.rect.h]);
            w["root"] = toJson(f.root);
            wins ~= w;
        }
        JSONValue j = JSONValue(["root": toJson(root)]);
        j["floating"] = JSONValue(wins);
        return j;
    }

    /// Space rebuilt from `save` output. Throws `JSONException` on a malformed layout.
    static DockSpace restore(const JSONValue j)
    {
        DockSpace d = new DockSpace(fromJson(j["root"]));
        if (const(JSONValue)* wins = "floating" in j)
        {
            foreach (const JSONValue w; wins.array)
            {
                Rect r = Rect(num(w["x"]), num(w["y"]), num(w["w"]), num(w["h"]));
                d.floating ~= Floating(r, fromJson(w["root"]));
            }
        }
        d.simplify();
        return d;
    }

    /// JSON for one node.
    private static JSONValue toJson(DockNode n)
    {
        if (n.kind == Kind.tabs)
        {
            JSONValue t = JSONValue(["tabs": JSONValue(n.panes)]);
            t["active"] = n.active;
            return t;
        }
        JSONValue[] kids;
        foreach (DockNode c; n.children)
        {
            kids ~= toJson(c);
        }
        JSONValue s = JSONValue(["split": n.vertical ? "v" : "h"]);
        s["shares"] = JSONValue(n.shares);
        s["children"] = JSONValue(kids);
        return s;
    }

    /// Node from its JSON.
    private static DockNode fromJson(const JSONValue j)
    {
        if (const(JSONValue)* tabs = "tabs" in j)
        {
            DockNode t = DockNode.stack();
            foreach (const JSONValue p; tabs.array)
            {
                t.panes ~= p.str;
            }
            if (const(JSONValue)* a = "active" in j)
            {
                t.active = t.panes.length == 0 ? 0 : min(cast(size_t) a.integer, t.panes.length - 1);
            }
            return t;
        }
        DockNode s = DockNode.split(j["split"].str == "v");
        const(JSONValue)[] shares = j["shares"].array;
        foreach (size_t i, const JSONValue c; j["children"].array)
        {
            DockNode k = fromJson(c);
            k.parent = s;
            s.children ~= k;
            s.shares ~= i < shares.length ? num(shares[i]) : 1;
        }
        return s;
    }

    /// Number from JSON, accepting integers and floats.
    private static float num(const JSONValue v)
    {
        return v.type == JSONType.float_ ? v.floating : v.integer;
    }
}

/// Debugger layout: source left, breakpoints and watch stacked over memory on the right.
private DockSpace sample()
{
    return new DockSpace(DockNode.split(false,
        DockNode.stack("source"),
        DockNode.split(true, DockNode.stack("breakpoints", "watch"), DockNode.stack("memory"))));
}

// Layout, hit testing and drop zones.
unittest
{
    DockSpace d = sample();
    d.layout(Rect(0, 0, 1004, 604));
    DockNode memory = d.find("memory");
    assert(d.find("source").rect == Rect(0, 0, 500, 604));
    assert(d.find("watch").rect == Rect(504, 0, 500, 300));
    assert(memory.rect == Rect(504, 304, 500, 300));
    assert(d.stackAt(Point(700, 400)) is memory);
    assert(DockSpace.zoneAt(memory, Point(754, 454)) == Zone.center);
    assert(DockSpace.zoneAt(memory, Point(990, 454)) == Zone.right);
    assert(DockSpace.zoneAt(memory, Point(754, 310)) == Zone.top);
    assert(DockSpace.preview(memory, Zone.right) == Rect(754, 304, 250, 300));
}

// Docking to an edge splits, docking to the center joins, empty stacks disappear.
unittest
{
    DockSpace d = sample();
    d.layout(Rect(0, 0, 1004, 604));
    d.dock("watch", d.find("memory"), Zone.right);
    assert(d.find("breakpoints").panes == ["breakpoints"]);
    DockNode watch = d.find("watch");
    assert(watch.parent.vertical == false && watch.parent.children[0] is d.find("memory"));

    d.dock("breakpoints", d.find("source"), Zone.center);
    assert(d.find("source").panes == ["source", "breakpoints"]);
    assert(d.find("source").active == 1);
    assert(d.root.vertical == false && d.root.children.length == 3,
        "vertical split collapsed, then flattened into the root row");
    float total = 0;
    foreach (float s; d.root.shares)
    {
        total += s;
    }
    assert(total == 2, "the right column's share was divided among its children");
}

// Floating windows and a save/restore round trip.
unittest
{
    DockSpace d = sample();
    d.undock("memory", Rect(100, 100, 400, 300));
    assert(d.floating.length == 1 && d.root.children.length == 2);
    string saved = d.save().toString;
    DockSpace back = DockSpace.restore(parseJSON(saved));
    assert(back.save().toString == saved);
    assert(back.find("memory") !is null);
    back.layout(Rect(0, 0, 1000, 600));
    assert(back.stackAt(Point(150, 150)) is back.find("memory"), "floating window on top");
    back.dock("memory", back.find("source"), Zone.bottom);
    assert(back.floating.length == 0, "empty window closed");
}


// Reordering tabs, docking at the main area's edge, floating window order, and restoring bad input.
unittest
{
    DockSpace d = sample();
    assert(d.paneIds == ["source", "breakpoints", "watch", "memory"]);
    DockNode bw = d.find("watch");
    d.move("breakpoints", bw, 2);
    assert(bw.panes == ["watch", "breakpoints"] && bw.active == 1);
    d.move("breakpoints", bw, 0);
    assert(bw.panes == ["breakpoints", "watch"] && bw.active == 0);
    d.move("source", bw, 1);
    assert(bw.panes == ["breakpoints", "source", "watch"] && bw.active == 1);
    assert(d.root is bw.parent, "the emptied stack went, leaving the column as the root");

    d.dockOuter("memory", Zone.bottom);
    assert(d.root.vertical && d.root.children.length == 2 && d.root.shares == [0.75f, 0.25f]);
    d.layout(Rect(0, 0, 1000, 604));
    assert(d.find("memory").rect == Rect(0, 454, 1000, 150));
    assert(d.outerPreview(Zone.left) == Rect(0, 0, 250, 604));

    d.undock("watch", Rect(0, 0, 100, 100));
    d.undock("source", Rect(900, -20, 300, 100));
    assert(d.windowOf(d.find("source")) == 1 && d.windowOf(d.find("memory")) == -1);
    assert(d.raise(0) == 1 && d.windowOf(d.find("watch")) == 1);
    d.layout(Rect(0, 0, 1000, 604));
    assert(d.find("source").rect == Rect(700, 0, 300, 100) && d.floating[0].rect.x == 900,
        "laid out inside the area, stored rect kept");

    DockSpace r = DockSpace.restore(parseJSON(`{"root": {"split": "h", "shares": [1],
        "children": [{"tabs": ["a"], "active": 5}, {"tabs": []}]}}`));
    assert(r.root.kind == Kind.tabs && r.root.panes == ["a"] && r.root.active == 0);
}

// Removing a pane keeps the shown tab, or shows the next one, and lists the stacks.
unittest
{
    DockSpace d = sample();
    DockNode bw = d.find("watch");
    d.move("source", bw, 2);
    assert(bw.panes == ["breakpoints", "watch", "source"] && bw.active == 2);
    d.remove("breakpoints");
    assert(bw.panes == ["watch", "source"] && bw.active == 1, "still shows source");
    d.remove("source");
    assert(bw.panes == ["watch"] && bw.active == 0);
    assert(d.stacks() == [bw, d.find("memory")]);
    d.remove("watch");
    d.remove("memory");
    assert(d.root.kind == Kind.tabs && d.root.empty && d.stacks() == [d.root]);
}

/// Look of dock tab bars, splitters, floating windows and drop targets.
struct DockStyle
{
    enum section = "dock"; /// section name in theme files

    Color background = Color(0x1b, 0x1b, 0x1e, 0xff);  /// background behind all panes
    Color tabBar = Color(0x23, 0x23, 0x27, 0xff);      /// tab strip background
    Color tabHover = Color(0x2c, 0x2c, 0x31, 0xff);    /// tab under the pointer
    Color tabActive = Color(0x1e, 0x1e, 0x22, 0xff);   /// selected tab, same as the pane
    Color text = Color(0x98, 0x98, 0xa0, 0xff);        /// tab title
    Color textActive = Color(0xee, 0xee, 0xee, 0xff);  /// selected tab title
    Color accent = Color(0x4c, 0x8d, 0xf6, 0xff);      /// line on the focused stack's selected tab, drop targets
    Color accentIdle;                                  /// line on the selected tab of other stacks
    Color splitter = Color(0x16, 0x16, 0x19, 0xff);    /// gap between panes
    Color splitterHover = Color(0x4c, 0x8d, 0xf6, 0xff); /// splitter under the pointer or dragged
    Color border = Color(0x33, 0x33, 0x38, 0xff);      /// line under the tab strip
    Color window = Color(0x44, 0x44, 0x4a, 0xff);      /// floating window border
    Color shadow = Color(0, 0, 0, 0x70);               /// floating window shadow
    Color drop = Color(0x4c, 0x8d, 0xf6, 0x40);        /// area a drop would fill
    Color guide = Color(0x2c, 0x2c, 0x31, 0xf0);       /// drop button fill
    Color guideBorder = Color(0x55, 0x55, 0x5c, 0xff); /// drop button outline
    Color closeHover = Color(0xff, 0xff, 0xff, 0x1a);  /// close button under the pointer
    Color track = Color(0xff, 0xff, 0xff, 0x20);       /// unfilled part of a tab's progress bar
    Color progress = Color(0x4c, 0x8d, 0xf6, 0xff);    /// filled part of a tab's progress bar
    float tabPadX = 12;    /// space between a tab title and the sides of its tab
    float iconSize = 12;   /// tab icon and lock size
    float iconGap = 6;     /// space between a tab icon and the title
    float markGap = 6;     /// space before each mark after a title
    float maxTitle = 0;    /// widest tab title before it is shortened, 0 for no limit
    float fade = 24;       /// fade at a cut edge of a tab bar with more tabs than room
    float closeSize = 8;   /// close icon size
    float closeGap = 8;    /// space between a tab title and its close icon
    float guideSize = 32;  /// side length of a drop button
    float shadowBlur = 12; /// floating window shadow size
    FontKind font = FontKind.ui; /// title font
    float size = 12;       /// title size
}

/// Part of the dock under the pointer.
private struct DockHit
{
    enum Kind
    {
        none,     /// nothing
        tab,      /// a tab title
        close,    /// a tab's close button
        bar,      /// the empty part of a tab bar
        splitter, /// a gap between split children
        edge,     /// the border of a floating window
        content,  /// pane content
    }

    Kind kind;      /// what was hit
    DockNode node;  /// stack for a tab, close button, bar or content, split for a splitter, window root for an edge
    size_t index;   /// tab index, the child before the splitter, or `Edge` bits
}

/// Sides of a floating window border, as bits.
private enum Edge : size_t
{
    left = 1,   /// left side
    right = 2,  /// right side
    top = 4,    /// top side
    bottom = 8, /// bottom side
}

/// What a press on the dock view drags.
private enum Drag
{
    none,     /// nothing
    splitter, /// a gap between split children
    pending,  /// a tab, not yet moved far enough
    tab,      /// a tab, to dock elsewhere or float
    window,   /// a floating window, by its tab bar
    resize,   /// a floating window, by its border
    keys,     /// a pane, by the arrow keys, see `DockView.startMove`
}

/// Where a dragged pane would land.
/// Item of a dock view exposed to screen readers: a stack's tab list, one of its tabs, or its shown pane.
private struct AccessItem
{
    DockNode stack;   /// stack it belongs to
    Role role;        /// `Role.tabList`, `Role.tab` or `Role.pane`
    size_t tab;       /// index into the stack's panes, for a tab
    ptrdiff_t parent; /// item holding it, the tab list for a tab, else -1
}

private struct Drop
{
    enum Kind
    {
        none,  /// floats, or stays where its window was moved
        zone,  /// into or beside `stack`, by `zone`
        outer, /// at side `zone` of the main area
        tab,   /// into the tab bar of `stack` at `index`
    }

    Kind kind;      /// target kind
    DockNode stack; /// target stack for `zone` and `tab`
    Zone zone;      /// side
    size_t index;   /// tab position for `tab`
}

/// Drop button.
private struct Guide
{
    Zone zone; /// side it docks to
    Rect rect; /// button, local coordinates
}

/// Space between the drop buttons over a stack.
private enum float guideGap = 4;

/// Pointer travel that turns a tab press into a drag.
private enum float dragThreshold = 5;

/// Smallest floating window width.
private enum float minWindowW = 120;

/// Smallest floating window height.
private enum float minWindowH = 80;

/// Reach of a floating window's border grab outside the window.
private enum float edgeOut = 5;

/// Reach of a floating window's border grab inside the window.
private enum float edgeIn = 2;

/// Retained view of a dock space: tab bars, splitters, floating windows, and the active pane of each stack as
/// children. Panes are nodes by ID. Inactive panes are detached, so their islands stop running.
///
/// Dragging a tab shows drop buttons over the stack under the pointer and near the sides of the main area.
/// Dropping on a button docks the pane there, on a tab bar inserts the tab, anywhere else floats the pane in
/// a window inside the view. A floating window moves by its tab bar, or by its tab when it holds one pane,
/// which also docks it. It resizes by its border. Escape cancels a drag. `startMove` docks a pane by the arrow keys
/// instead, `shiftTab` reorders tabs.
final class DockView : Node, WindowKeys, AccessPartTree
{
    DockSpace space;       /// dock layout shown
    Node[string] panes;    /// pane content nodes by pane ID
    string[string] titles; /// tab titles by pane ID, the ID when missing
    /// Shown pane of the focused stack, the one holding keyboard focus or pressed last, null when no pane shows.
    /// Change it with `select`.
    Signal!string current;
    /// Runs after the user drops a tab, floats a pane, drags a splitter, moves or resizes a floating window, or ends
    /// a keyboard move with Enter. Not for other method calls or tab choices, see `current` for those.
    void delegate() onLayout;
    /// Runs when the user asks to close a pane, by its close button or a middle click on its tab. Removing it is
    /// up to the app, through `removePane`, at once or after asking about unsaved changes. Null for no close
    /// buttons.
    void delegate(string pane) onCloseRequest;
    bool delegate(string pane) closable; /// whether a pane can be closed, null for all
    /// Menu for a right press on the tab of `pane`, or null for none. The press does not choose the tab.
    Menu delegate(string pane) tabMenu;
    void delegate(DockNode stack) onBarDoubleClick; /// runs on a double click on the empty part of a tab bar
    bool floating = true; /// a tab dropped away from the drop buttons floats, false cancels the drag instead
    /// Smallest content size of a stack, under its tab bar. Splitter drags, floating window resizes and side drop
    /// buttons keep to it. A window too small for every pane still squeezes them.
    Size minPane = Size(40, 40);

    private DockHit hot;         /// under the pointer
    private Drag mode;           /// what the press drags
    private DockHit grab;        /// part pressed
    private Point grabAt;        /// pointer at the press, local
    private float[] dragShares;  /// split shares at the press
    private Rect grabRect;       /// floating window rect at the press
    private DockNode grabWindow; /// root of the floating window moved or resized
    private string moving;       /// pane being docked, null when only moving a window
    private Drop drop;           /// target under the pointer while docking
    private DockNode guided;     /// stack whose drop buttons show
    private Point pointer;       /// last pointer position, local
    private AccessItem[] items;  /// items exposed to screen readers as of the last access update
    private DockNode focus;      /// focused stack, see `current`
    private TabInfo delegate(string pane) tabInfo; /// tab content by pane, see `setTabInfo`
    private TabInfo[string] infos; /// what `tabInfo` gave at its last read, by pane
    private Signal!uint tabsRead;  /// bumped to read `tabInfo` again
    private Effect reader;       /// reads `tabInfo` while attached
    private Node delegate(DockNode stack) trailing; /// node for the end of a tab bar, see `setTrailing`
    private Node[DockNode] trailers; /// nodes from `trailing` by stack
    private TabStrip[DockNode] strips; /// tab bar scrolling by stack
    private DockNode fileStack;  /// stack lit as the target of a file dragged over the window, or null
    private DockHit closing;     /// tab whose close button or middle button is pressed, `Kind.none` for none
    private ubyte closingButton; /// button pressed on `closing`
    private string closingPane;  /// pane of `closing`
    private DockNode aim;        /// stack a keyboard move is at
    private Node keptFocus;      /// keyboard focus before a keyboard move, given back after

    /// Creates a view of `space` showing `panes`.
    this(DockSpace space, Node[string] panes, string[string] titles)
    {
        this.space = space;
        this.panes = panes;
        this.titles = titles;
        current = new Signal!string(null);
        tabsRead = new Signal!uint(0);
        interactive = true;
        sync();
    }

    /// Makes the active pane of every stack a child, detaching the rest.
    void sync()
    {
        Node[] shown;
        void walk(DockNode n)
        {
            if (n.kind == Kind.tabs)
            {
                if (n.panes.length > 0)
                {
                    if (Node* p = n.panes[n.active] in panes)
                    {
                        shown ~= *p;
                    }
                }
                return;
            }
            foreach (DockNode c; n.children)
            {
                walk(c);
            }
        }

        walk(space.root);
        foreach (ref Floating f; space.floating)
        {
            walk(f.root);
        }
        DockNode[] stacks = space.stacks();
        Node[DockNode] keptNodes;
        TabStrip[DockNode] keptStrips;
        foreach (DockNode st; stacks)
        {
            if (Node* t = st in trailers)
            {
                keptNodes[st] = *t;
            }
            else if (trailing !is null)
            {
                if (Node t = trailing(st))
                {
                    keptNodes[st] = t;
                }
            }
            if (Node* t = st in keptNodes)
            {
                shown ~= *t;
            }
            if (TabStrip* s = st in strips)
            {
                keptStrips[st] = *s;
            }
        }
        trailers = keptNodes;
        strips = keptStrips;
        setChildren(shown);
        refocus();
        tabsRead.set(tabsRead.peek + 1);
    }

    /// Takes tab titles, icons, tooltips and marks from `info`, read again whenever a signal it reads changes or a
    /// pane comes or goes. A null title there leaves the one from `titles`.
    void setTabInfo(TabInfo delegate(string pane) info)
    {
        tabInfo = info;
        tabsRead.set(tabsRead.peek + 1);
    }

    /// Reads `setTabInfo`'s delegate again, for data it reads outside signals.
    void refreshTabs()
    {
        tabsRead.set(tabsRead.peek + 1);
    }

    /// Puts the node `make` returns at the right end of each stack's tab bar, such as a pane number. Asked once per
    /// stack, null for none.
    void setTrailing(Node delegate(DockNode stack) make)
    {
        trailing = make;
        trailers = null;
        sync();
        markNeedsLayout();
    }

    /// Reads `tabInfo` for every pane, tracking the signals it reads.
    private void readTabs()
    {
        tabsRead.get;
        TabInfo[string] next;
        if (tabInfo !is null)
        {
            foreach (string id; space.paneIds)
            {
                next[id] = tabInfo(id);
            }
        }
        infos = next;
        markNeedsLayout();
    }

    /// Shows `s` instead, dropping any drag.
    void setSpace(DockSpace s)
    {
        space = s;
        focus = null;
        reset();
        sync();
    }

    /// Selects tab `index` of `stack`.
    void activate(DockNode stack, size_t index)
    {
        if (stack.active == index)
        {
            refocus();
            return;
        }
        stack.active = index;
        sync();
    }

    /// Adds pane `id` showing `content` under `title`, as the chosen tab of a stack placed by `zone` against
    /// `target`, the focused stack when null. A pane the space already holds, as from a restored layout, keeps its
    /// place and becomes its stack's chosen tab.
    void addPane(string id, Node content, string title, DockNode target = null, Zone zone = Zone.center)
    {
        panes[id] = content;
        titles[id] = title;
        if (DockNode s = space.find(id))
        {
            s.active = countUntil(s.panes, id);
        }
        else
        {
            if (target is null)
            {
                target = focus !is null ? focus : space.stacks()[0];
            }
            space.dock(id, target, zone == Zone.none ? Zone.center : zone);
        }
        sync();
        markNeedsLayout();
    }

    /// Removes pane `id` with its content and title. Its stack shows the tab that followed, or the one before.
    void removePane(string id)
    {
        if (mode != Drag.none)
        {
            reset();
        }
        space.remove(id);
        panes.remove(id);
        titles.remove(id);
        sync();
        markNeedsLayout();
    }

    /// Shows pane `id` and makes its stack the focused one. Keyboard focus moves to the pane's first Tab stop, or
    /// is cleared when it was elsewhere in the view. Does nothing for a pane the space lacks.
    void select(string id)
    {
        DockNode s = space.find(id);
        if (s is null)
        {
            return;
        }
        s.active = countUntil(s.panes, id);
        focus = s;
        sync();
        markNeedsLayout();
        focusInto(id);
    }

    /// Moves keyboard focus to the first Tab stop of pane `id`, or clears it when it was elsewhere in the view.
    private void focusInto(string id)
    {
        Node* p = id in panes;
        if (p is null || tree is null || tree.services is null)
        {
            return;
        }
        if (Node f = firstStop(*p))
        {
            tree.services.setFocus(f);
        }
        else if (holds(tree.services.focused()))
        {
            tree.services.setFocus(null);
        }
    }

    /// Replaces the tab title of pane `id`.
    void setTitle(string id, string title)
    {
        titles[id] = title;
        markNeedsLayout();
    }

    /// Starts moving `pane`, the shown pane of the focused stack when null, by keyboard. The arrow keys pick a drop
    /// button: a side of the stack, then the next stack that way, then a side of the main area. Enter docks the pane
    /// there and runs `onLayout`, Escape or a press cancels. The view holds keyboard focus meanwhile and gives it
    /// back after. False when the pane is missing or a drag is on.
    bool startMove(string pane = null)
    {
        if (pane is null)
        {
            pane = current.get;
        }
        DockNode st = pane is null ? null : space.find(pane);
        if (st is null || mode != Drag.none || tree is null)
        {
            return false;
        }
        mode = Drag.keys;
        moving = pane;
        setHot(DockHit.init);
        aimAt(st, Zone.center);
        if (tree.services !is null)
        {
            keptFocus = tree.services.focused();
            tree.services.setFocus(this);
        }
        return true;
    }

    /// True during a keyboard move, see `startMove`.
    bool movingByKeys() const
    {
        return mode == Drag.keys;
    }

    /// Moves the tab of `pane`, the shown pane of the focused stack when null, `by` places along its tab bar,
    /// stopping at the ends. The shown tab stays. False when nothing moved. Does not run `onLayout`.
    bool shiftTab(int by, string pane = null)
    {
        import std.algorithm.comparison : clamp;

        if (pane is null)
        {
            pane = current.get;
        }
        DockNode st = pane is null ? null : space.find(pane);
        if (st is null || mode != Drag.none)
        {
            return false;
        }
        ptrdiff_t i = countUntil(st.panes, pane);
        ptrdiff_t j = clamp(i + by, 0, cast(ptrdiff_t) st.panes.length - 1);
        if (j == i)
        {
            return false;
        }
        string shown = st.panes[st.active];
        space.move(pane, st, j > i ? j + 1 : j);
        st.active = countUntil(st.panes, shown);
        sync();
        markNeedsLayout();
        return true;
    }

    /// Stack under window point `p`, floating windows first, or null, such as for where a dropped file goes.
    DockNode stackAt(Point p)
    {
        return space.stackAt(p - bounds.pos);
    }

    /// Lights the stack under window point `p` as where a dragged file would go and returns it, or null when none is
    /// there, such as over a splitter. Call it from `Host.onFileHover`, and `fileLeave` from `Host.onFileLeave`.
    DockNode fileHover(Point p)
    {
        DockNode st = stackAt(p);
        if (st !is fileStack)
        {
            fileStack = st;
            markNeedsPaint();
        }
        return st;
    }

    /// Turns off the light from `fileHover`.
    void fileLeave()
    {
        if (fileStack !is null)
        {
            fileStack = null;
            markNeedsPaint();
        }
    }

    /// Focused stack, see `current`, or null when no pane shows.
    DockNode focusedStack()
    {
        return focus;
    }

    /// Points `current` at the shown pane of the focused stack, or of the first stack with panes when the focused
    /// one is gone.
    private void refocus()
    {
        DockNode was = focus;
        if (focus is null || focus.panes.length == 0 || placed(focus) == false)
        {
            focus = null;
            foreach (DockNode s; space.stacks())
            {
                if (s.panes.length > 0)
                {
                    focus = s;
                    break;
                }
            }
        }
        if (focus !is was)
        {
            markNeedsPaint();
        }
        current.set(focus is null ? null : focus.panes[focus.active]);
    }

    /// True if `stack` is in the main tree or a floating window.
    private bool placed(DockNode stack)
    {
        DockNode r = stack;
        while (r.parent !is null)
        {
            r = r.parent;
        }
        return r is space.root || windowFor(r) !is null;
    }

    /// True if `n` is inside the view.
    private bool holds(Node n)
    {
        for (; n !is null; n = n.parent)
        {
            if (n is this)
            {
                return true;
            }
        }
        return false;
    }

    /// Focus moving into a pane makes its stack the focused one.
    override void onFocusWithin(Node n)
    {
        while (n !is null && n.parent !is this)
        {
            n = n.parent;
        }
        if (n is null)
        {
            return;
        }
        foreach (DockNode s; space.stacks())
        {
            if (s.panes.length > 0)
            {
                Node* p = s.panes[s.active] in panes;
                if (p !is null && *p is n)
                {
                    focus = s;
                    refocus();
                    return;
                }
            }
        }
    }

    /// Listens for Escape during drags and starts reading tab content.
    override void onAttach()
    {
        tree.addWindowKeys(this);
        runWithOwner(null, { reader = effect(&readTabs); });
    }

    /// Stops listening and reading tab content.
    override void onDetach()
    {
        tree.removeWindowKeys(this);
        if (reader !is null)
        {
            reader.dispose();
            reader = null;
        }
    }

    /// Arrow keys, Enter and Escape during a keyboard move, see `startMove`. Takes every other key meanwhile.
    override bool onKey(ref const KeyEvent e)
    {
        if (mode != Drag.keys)
        {
            return false;
        }
        switch (e.key)
        {
        case Key.left:
            stepMove(Zone.left);
            break;
        case Key.right:
            stepMove(Zone.right);
            break;
        case Key.up:
            stepMove(Zone.top);
            break;
        case Key.down:
            stepMove(Zone.bottom);
            break;
        case Key.enter:
            endMove();
            break;
        case Key.escape:
            reset();
            break;
        default:
            break;
        }
        return true;
    }

    /// Losing keyboard focus cancels a keyboard move.
    override void onFocus(bool gained)
    {
        if (gained == false && mode == Drag.keys)
        {
            keptFocus = null;
            reset();
        }
    }

    /// Points a keyboard move at the drop button for `z` over `st`, or at no drop when `st` lacks it.
    private void aimAt(DockNode st, Zone z)
    {
        aim = st;
        guided = st.panes == [moving] ? null : st;
        drop = guided !is null && offers(st, z) ? Drop(Drop.Kind.zone, st, z) : Drop.init;
        markNeedsPaint();
    }

    /// True if `st` shows a drop button for `z` while moving a pane.
    private bool offers(DockNode st, Zone z)
    {
        DockStyle s = tree.style!DockStyle();
        foreach (Guide g; stackGuides(st, s))
        {
            if (g.zone == z)
            {
                return true;
            }
        }
        return false;
    }

    /// Steps a keyboard move toward side `d`: from the center of a stack to its side `d`, from there to the next
    /// stack that way, past the last one to side `d` of the main area. The other way leads back to the center.
    private void stepMove(Zone d)
    {
        Zone back = d == Zone.left ? Zone.right : d == Zone.right ? Zone.left : d == Zone.top ? Zone.bottom
            : Zone.top;
        if (drop.kind == Drop.Kind.outer)
        {
            if (drop.zone == back)
            {
                aimAt(aim, Zone.center);
            }
            else
            {
                drop = Drop(Drop.Kind.outer, null, d);
                markNeedsPaint();
            }
            return;
        }
        Zone z = drop.kind == Drop.Kind.zone ? drop.zone : Zone.center;
        if (z == back)
        {
            aimAt(aim, Zone.center);
        }
        else if (z != d && guided !is null && offers(aim, d))
        {
            aimAt(aim, d);
        }
        else if (DockNode n = neighbor(aim, d))
        {
            aimAt(n, Zone.center);
        }
        else
        {
            drop = Drop(Drop.Kind.outer, null, d);
            markNeedsPaint();
        }
    }

    /// Nearest stack past side `d` of `from` and level with it, or null.
    private DockNode neighbor(DockNode from, Zone d)
    {
        import std.math : abs;

        bool across = d == Zone.left || d == Zone.right;
        bool ahead = d == Zone.right || d == Zone.bottom;
        Rect a = from.rect;
        DockNode best;
        float[2] bestKey;
        foreach (DockNode c; space.stacks())
        {
            Rect r = c.rect;
            float lead = across ? r.x + r.w / 2 - (a.x + a.w / 2) : r.y + r.h / 2 - (a.y + a.h / 2);
            float level = across ? min(a.bottom, r.bottom) - max(a.y, r.y) : min(a.right, r.right) - max(a.x, r.x);
            if (c is from || (ahead ? lead : -lead) <= 0 || level <= 0)
            {
                continue;
            }
            float gap = across ? (ahead ? r.x - a.right : a.x - r.right) : (ahead ? r.y - a.bottom : a.y - r.bottom);
            float off = across ? abs(r.y + r.h / 2 - (a.y + a.h / 2)) : abs(r.x + r.w / 2 - (a.x + a.w / 2));
            float[2] key = [max(gap, 0f), off];
            if (best is null || key[] < bestKey[])
            {
                best = c;
                bestKey = key;
            }
        }
        return best;
    }

    /// Ends a keyboard move by docking the pane at the chosen drop button, if any, and runs `onLayout` then.
    private void endMove()
    {
        string pane = moving;
        bool docked = drop.kind != Drop.Kind.none;
        if (docked)
        {
            land(pane, drop);
            focus = space.find(pane);
            sync();
            markNeedsLayout();
        }
        reset();
        if (docked && onLayout !is null)
        {
            onLayout();
        }
    }

    /// Escape during a drag puts things back as they were at the press.
    bool windowKey(ref const KeyEvent e)
    {
        if (e.key != Key.escape || mode == Drag.none)
        {
            return false;
        }
        if (mode == Drag.splitter)
        {
            grab.node.shares = dragShares;
        }
        else if (mode == Drag.window || mode == Drag.resize)
        {
            if (Floating* f = windowFor(grabWindow))
            {
                f.rect = grabRect;
            }
        }
        reset();
        markNeedsLayout();
        return true;
    }

    /// Number of items exposed to screen readers: per stack a tab list holding its tabs, then a pane named by the
    /// chosen tab holding its content. Lists them anew, so the other item calls refer to this update.
    size_t accessPartCount()
    {
        items = null;
        void walk(DockNode n)
        {
            if (n.kind == Kind.split)
            {
                foreach (DockNode k; n.children)
                {
                    walk(k);
                }
                return;
            }
            ptrdiff_t list = items.length;
            items ~= AccessItem(n, Role.tabList, 0, -1);
            foreach (size_t i; 0 .. n.panes.length)
            {
                items ~= AccessItem(n, Role.tab, i, list);
            }
            if (n.panes.length > 0)
            {
                items ~= AccessItem(n, Role.pane, n.active, -1);
            }
        }

        walk(space.root);
        foreach (ref Floating f; space.floating)
        {
            walk(f.root);
        }
        return items.length;
    }

    /// Item `i`: a tab named by its title, selected when chosen, a pane named by its chosen tab, or a tab list.
    void describePart(size_t i, ref AccessInfo a, ref Rect r)
    {
        AccessItem it = items[i];
        Point at = bounds.pos;
        a.role = it.role;
        switch (it.role)
        {
        case Role.tabList:
            r = Rect(it.stack.rect.x, it.stack.rect.y, it.stack.rect.w, tabBarHeight).translate(at);
            break;
        case Role.tab:
            DockStyle s = tree.style!DockStyle();
            a.label = titleOf(it.stack.panes[it.tab]);
            a.description = infoOf(it.stack.panes[it.tab]).tooltip;
            a.selected = tri(it.tab == it.stack.active);
            a.allow(AccessAction.click);
            r = tabRects(it.stack, s)[it.tab].translate(at);
            break;
        default:
            a.label = titleOf(it.stack.panes[it.tab]);
            r = contentOf(it.stack).translate(at);
            break;
        }
    }

    /// Tab list of item `i`'s tab, else none.
    ptrdiff_t partParent(size_t i)
    {
        return items[i].parent;
    }

    /// Pane item showing `c`, or -1.
    ptrdiff_t childPart(Node c)
    {
        foreach (size_t i, AccessItem it; items)
        {
            if (it.role == Role.pane)
            {
                Node* p = it.stack.panes[it.tab] in panes;
                if (p !is null && *p is c)
                {
                    return i;
                }
            }
        }
        return -1;
    }

    /// Click chooses the tab of item `i`.
    bool accessPartAction(size_t i, ref const AccessRequest r)
    {
        if (r.action != AccessAction.click || i >= items.length || items[i].role != Role.tab)
        {
            return false;
        }
        AccessItem it = items[i];
        if (it.tab >= it.stack.panes.length)
        {
            return false;
        }
        focus = it.stack;
        activate(it.stack, it.tab);
        markNeedsLayout();
        return true;
    }

    /// No item takes focus.
    ptrdiff_t accessFocusPart()
    {
        return -1;
    }

    /// Title of pane `id`.
    private string titleOf(string id)
    {
        return infoOf(id).title;
    }

    /// What the tab of pane `id` shows: `tabInfo`'s last answer, its title from `titles` or the ID when null.
    private TabInfo infoOf(string id)
    {
        TabInfo t;
        if (TabInfo* i = id in infos)
        {
            t = *i;
        }
        if (t.title is null)
        {
            string* s = id in titles;
            t.title = s is null || *s is null ? id : *s;
        }
        return t;
    }

    /// Drawing sizes and colors from `s`.
    private static TabLook lookOf(const ref DockStyle s)
    {
        return TabLook(s.font, s.size, s.tabPadX, s.iconSize, s.iconGap, s.closeSize, s.closeGap, s.markGap,
            s.maxTitle, s.closeHover, s.track, s.progress);
    }

    /// Width of the tab bar of `stack` left for tabs, beside its trailing node.
    private float room(DockNode stack)
    {
        Node* t = stack in trailers;
        return stack.rect.w - (t is null ? 0 : t.size.w);
    }

    /// Tab widths of `stack`.
    private float[] widthsOf(DockNode stack, const ref DockStyle s)
    {
        TabLook l = lookOf(s);
        float[] ws;
        foreach (string p; stack.panes)
        {
            TabInfo info = infoOf(p);
            ws ~= rowWidth(tree.text, l, info, canClose(p) || info.modified);
        }
        return ws;
    }

    /// Area under the tab bar of `stack`, local coordinates.
    private static Rect contentOf(DockNode stack)
    {
        Rect r = stack.rect;
        return Rect(r.x, r.y + tabBarHeight, r.w, r.h - tabBarHeight);
    }

    /// Tab rects of `stack` as scrolled, local coordinates.
    private Rect[] tabRects(DockNode stack, const ref DockStyle s)
    {
        Rect[] rs;
        TabStrip* st = stack in strips;
        float x = stack.rect.x - (st is null ? 0 : round(st.scrollX));
        foreach (float w; widthsOf(stack, s))
        {
            rs ~= Rect(x, stack.rect.y, w, tabBarHeight);
            x += w;
        }
        return rs;
    }

    /// True if pane `id` shows a close button.
    private bool canClose(string id)
    {
        return onCloseRequest !is null && (closable is null || closable(id));
    }

    /// Smallest size of `n` by `minPane`: splits add up their children along their direction.
    private Size minOf(DockNode n)
    {
        if (n.kind == Kind.tabs)
        {
            return Size(minPane.w, minPane.h + tabBarHeight);
        }
        Size m;
        foreach (size_t i, DockNode c; n.children)
        {
            Size k = minOf(c);
            float gap = i > 0 ? splitterSize : 0;
            m = n.vertical ? Size(max(m.w, k.w), m.h + k.h + gap) : Size(m.w + k.w + gap, max(m.h, k.h));
        }
        return m;
    }

    /// Floating window rooted at `root`, or null.
    private Floating* windowFor(DockNode root)
    {
        foreach (ref Floating f; space.floating)
        {
            if (f.root is root)
            {
                return &f;
            }
        }
        return null;
    }

    /// Fills the constraints, places every stack, and lays out the active panes tightly.
    protected override Size performLayout(Constraints c)
    {
        import std.math : isInfinity;

        Size own = Size(isInfinity(c.maxW) ? c.minW : c.maxW, isInfinity(c.maxH) ? c.minH : c.maxH);
        space.layout(Rect(0, 0, own.w, own.h));
        void place(DockNode n)
        {
            if (n.kind == Kind.tabs)
            {
                if (n.panes.length > 0)
                {
                    if (Node* p = n.panes[n.active] in panes)
                    {
                        Rect r = contentOf(n);
                        p.layout(Constraints.tight(Size(r.w, r.h)));
                        p.offset = r.pos;
                    }
                }
                if (Node* t = n in trailers)
                {
                    t.layout(Constraints.loose(Size(n.rect.w / 2, tabBarHeight)));
                    t.offset = Point(n.rect.right - t.size.w, n.rect.y + round((tabBarHeight - t.size.h) / 2));
                }
                return;
            }
            foreach (DockNode k; n.children)
            {
                place(k);
            }
        }

        place(space.root);
        foreach (ref Floating f; space.floating)
        {
            place(f.root);
        }
        return own;
    }

    /// Main tree, floating windows from the bottom up, the file drop target, then drop targets.
    override void paint(ref PaintContext ctx, Point origin)
    {
        DockStyle s = ctx.style!DockStyle();
        ctx.list.rect(Rect(origin.x, origin.y, size.w, size.h), s.splitter);
        paintTree(ctx, origin, space.root, s);
        foreach (ref Floating f; space.floating)
        {
            Rect r = f.root.rect.translate(origin);
            ctx.list.shadow(r, 0, s.shadowBlur, s.shadow);
            ctx.list.rect(r.inset(-1), s.window);
            ctx.list.rect(r, s.splitter);
            paintTree(ctx, origin, f.root, s);
        }
        if (fileStack !is null && placed(fileStack))
        {
            ctx.list.rect(fileStack.rect.translate(origin), s.drop, 0, s.accent, 1);
        }
        paintDrop(ctx, origin, s);
    }

    /// Tab bars, active panes and lit splitters of the tree under `root`.
    private void paintTree(ref PaintContext ctx, Point origin, DockNode root, const ref DockStyle s)
    {
        void walk(DockNode n)
        {
            if (n.kind == Kind.split)
            {
                foreach (DockNode k; n.children)
                {
                    walk(k);
                }
                return;
            }
            paintBar(ctx, origin, n, s);
            if (n.panes.length > 0)
            {
                if (Node* p = n.panes[n.active] in panes)
                {
                    paintChild(ctx, origin, *p);
                }
            }
        }

        walk(root);
        foreach (DockHit h; splitters(root))
        {
            if ((mode == Drag.splitter && grab == h) || (mode == Drag.none && hot == h))
            {
                ctx.list.rect(splitterRect(h).translate(origin), s.splitterHover);
            }
        }
    }

    /// Tab bar of `n`: tabs scrolled to show the chosen one, close buttons on the chosen and hovered tabs, faded
    /// edges where tabs are cut off, then the trailing node.
    private void paintBar(ref PaintContext ctx, Point origin, DockNode n, const ref DockStyle s)
    {
        TabLook l = lookOf(s);
        Rect bar = Rect(n.rect.x, n.rect.y, n.rect.w, tabBarHeight).translate(origin);
        ctx.list.rect(bar, s.tabBar);
        ctx.list.hline(bar.x, bar.right, bar.bottom - 1, s.border);
        float[] ws = widthsOf(n, s);
        TabStrip* st = &strips.require(n);
        st.settle(ws, n.active, room(n), s.fade);
        Rect area = Rect(bar.x, bar.y, room(n), bar.h);
        ctx.clipped(area, {
            bool faded = st.pushFade(*ctx.list, area, ws, s.fade);
            scope (exit)
            {
                if (faded)
                {
                    ctx.list.popFade();
                }
            }
            foreach (size_t i, Rect t; tabRects(n, s))
            {
                Rect tr = t.translate(origin);
                if (tr.right < area.x || tr.x > area.right)
                {
                    continue;
                }
                bool active = i == n.active;
                if (active)
                {
                    ctx.list.rect(tr, s.tabActive);
                    ctx.list.rect(Rect(tr.x, tr.y, tr.w, 2), n is focus ? s.accent : s.accentIdle);
                }
                bool over = (hot.kind == DockHit.Kind.tab || hot.kind == DockHit.Kind.close) && hot.node is n
                    && hot.index == i;
                if (active == false && over)
                {
                    ctx.list.rect(Rect(tr.x, tr.y, tr.w, tr.h - 1), s.tabHover);
                }
                Color ink = active ? s.textActive : s.text;
                TabInfo info = infoOf(n.panes[i]);
                paintRow(ctx, l, info, tr, ink, false);
                bool close = (active || over) && canClose(n.panes[i]);
                if (close || info.modified)
                {
                    paintSlot(ctx, l, slotRect(tr, l), close, close && over && hot.kind == DockHit.Kind.close,
                        info.modified, ink);
                }
            }
        });
        if (Node* t = n in trailers)
        {
            paintChild(ctx, origin, *t);
        }
    }

    /// While docking: the area a drop would fill, the tab insertion mark or the stack a keyboard move is at, the drop
    /// buttons, and the dragged tab at the pointer.
    private void paintDrop(ref PaintContext ctx, Point origin, const ref DockStyle s)
    {
        if (moving is null || (mode != Drag.tab && mode != Drag.window && mode != Drag.keys))
        {
            return;
        }
        Rect area;
        final switch (drop.kind)
        {
        case Drop.Kind.none:
            area = mode == Drag.tab && floating ? floatRect(pointer) : Rect.init;
            break;
        case Drop.Kind.zone:
            area = DockSpace.preview(drop.stack, drop.zone);
            break;
        case Drop.Kind.outer:
            area = space.outerPreview(drop.zone);
            break;
        case Drop.Kind.tab:
            Rect[] ts = tabRects(drop.stack, s);
            float x = drop.index < ts.length ? ts[drop.index].x : ts.length > 0 ? ts[$ - 1].right : drop.stack.rect.x;
            ctx.list.rect(Rect(x - 1, drop.stack.rect.y + 2, 2, tabBarHeight - 4).translate(origin), s.accent);
            break;
        }
        if (area.empty == false)
        {
            ctx.list.rect(area.translate(origin), s.drop, 0, s.accent, 1);
        }
        else if (mode == Drag.keys && drop.kind == Drop.Kind.none)
        {
            ctx.list.rect(aim.rect.translate(origin), Color.init, 0, s.accent, 1);
        }
        if (guided !is null)
        {
            foreach (Guide g; stackGuides(guided, s))
            {
                bool lit = drop.kind == Drop.Kind.zone && drop.stack is guided && drop.zone == g.zone;
                paintGuide(ctx, g.rect.translate(origin), g.zone, lit, s);
            }
        }
        foreach (Guide g; outerGuides(s))
        {
            paintGuide(ctx, g.rect.translate(origin), g.zone, drop.kind == Drop.Kind.outer && drop.zone == g.zone, s);
        }
        if (mode == Drag.tab)
        {
            TabLook l = lookOf(s);
            TabInfo info = infoOf(moving);
            float w = rowWidth(ctx.text, l, info, false);
            Rect t = Rect(pointer.x + 14, pointer.y + 14, w, tabBarHeight).translate(origin);
            ctx.list.shadow(t, 0, s.shadowBlur / 2, s.shadow);
            ctx.list.rect(t, s.tabActive, 0, s.window, 1);
            ctx.list.rect(Rect(t.x, t.y, t.w, 2), s.accent);
            paintRow(ctx, l, info, t, s.textActive, false);
        }
    }

    /// Drop button at `r` for side `z`, window coordinates, in the accent color when `lit`.
    private static void paintGuide(ref PaintContext ctx, Rect r, Zone z, bool lit, const ref DockStyle s)
    {
        ctx.list.rect(r, s.guide, 4, lit ? s.accent : s.guideBorder, 1);
        Rect inner = r.inset(8);
        Color c = lit ? s.accent : s.text;
        ctx.list.rect(inner, Color.init, 0, c, 1);
        ctx.list.rect(DockSpace.part(inner, z, 0.5), c);
    }

    /// Drop buttons over `stack`: the center unless `stack` holds the dragged pane, and the sides where half of it
    /// still fits the smallest pane.
    private Guide[] stackGuides(DockNode stack, const ref DockStyle s)
    {
        Rect c = contentOf(stack);
        float g = s.guideSize;
        float step = g + guideGap;
        float x = round(c.x + (c.w - g) / 2);
        float y = round(c.y + (c.h - g) / 2);
        Guide[] gs;
        if (space.find(moving) !is stack)
        {
            gs ~= Guide(Zone.center, Rect(x, y, g, g));
        }
        Size m = minOf(stack);
        if ((stack.rect.w - splitterSize) / 2 >= m.w)
        {
            gs ~= Guide(Zone.left, Rect(x - step, y, g, g));
            gs ~= Guide(Zone.right, Rect(x + step, y, g, g));
        }
        if ((stack.rect.h - splitterSize) / 2 >= m.h)
        {
            gs ~= Guide(Zone.top, Rect(x, y - step, g, g));
            gs ~= Guide(Zone.bottom, Rect(x, y + step, g, g));
        }
        return gs;
    }

    /// Drop buttons near the sides of the main area.
    private Guide[] outerGuides(const ref DockStyle s)
    {
        Rect r = space.root.rect;
        float g = s.guideSize;
        float pad = 8;
        float x = round(r.x + (r.w - g) / 2);
        float y = round(r.y + (r.h - g) / 2);
        return [Guide(Zone.left, Rect(r.x + pad, y, g, g)), Guide(Zone.right, Rect(r.right - pad - g, y, g, g)),
            Guide(Zone.top, Rect(x, r.y + tabBarHeight + pad, g, g)),
            Guide(Zone.bottom, Rect(x, r.bottom - pad - g, g, g))];
    }

    /// Window a tab dropped at `p` floats in: its stack's size within limits, with the tab bar under `p`.
    private Rect floatRect(Point p)
    {
        import std.algorithm.comparison : clamp;

        DockNode from = space.find(moving);
        float w = from is null ? 320 : clamp(from.rect.w, 240f, 480f);
        float h = from is null ? 240 : clamp(from.rect.h, 160f, 360f);
        return Rect(p.x - 40, p.y - tabBarHeight / 2, w, h);
    }

    /// Target for the dragged pane at local point `p`. Also picks the stack whose drop buttons show.
    private Drop dropAt(Point p)
    {
        DockStyle s = tree.style!DockStyle();
        Drop outer;
        foreach (Guide g; outerGuides(s))
        {
            if (g.rect.contains(p))
            {
                outer = Drop(Drop.Kind.outer, null, g.zone);
            }
        }
        // The buttons of a narrow stack overhang its neighbors, keep them while the pointer is on them.
        if (guided !is null && outer.kind == Drop.Kind.none)
        {
            foreach (Guide g; stackGuides(guided, s))
            {
                if (g.rect.inset(-guideGap / 2).contains(p))
                {
                    return g.rect.contains(p) ? Drop(Drop.Kind.zone, guided, g.zone) : Drop.init;
                }
            }
        }
        DockNode st = stackUnder(p, grabWindow);
        bool bar = st !is null && p.y < st.rect.y + tabBarHeight;
        bool alone = st !is null && st.panes.length == 1 && st.panes[0] == moving;
        guided = st is null || bar || alone ? null : st;
        if (outer.kind != Drop.Kind.none)
        {
            return outer;
        }
        if (bar)
        {
            Rect[] ts = tabRects(st, s);
            size_t i = ts.length;
            foreach (size_t k, Rect t; ts)
            {
                if (p.x < t.x + t.w / 2)
                {
                    i = k;
                    break;
                }
            }
            return Drop(Drop.Kind.tab, st, Zone.none, i);
        }
        if (guided !is null)
        {
            foreach (Guide g; stackGuides(guided, s))
            {
                if (g.rect.contains(p))
                {
                    return Drop(Drop.Kind.zone, guided, g.zone);
                }
            }
        }
        return Drop.init;
    }

    /// Stack under local point `p`, floating windows first, skipping the window rooted at `skip`.
    private DockNode stackUnder(Point p, DockNode skip)
    {
        foreach_reverse (ref Floating f; space.floating)
        {
            if (f.root !is skip && f.root.rect.contains(p))
            {
                return DockSpace.stackIn(f.root, p);
            }
        }
        return DockSpace.stackIn(space.root, p);
    }

    /// Every splitter in the tree under `root`.
    private static DockHit[] splitters(DockNode root)
    {
        DockHit[] hs;
        void walk(DockNode n)
        {
            if (n.kind == Kind.tabs)
            {
                return;
            }
            foreach (size_t i, DockNode c; n.children)
            {
                if (i + 1 < n.children.length)
                {
                    hs ~= DockHit(DockHit.Kind.splitter, n, i);
                }
                walk(c);
            }
        }

        walk(root);
        return hs;
    }

    /// Gap after child `h.index` of split `h.node`, local coordinates.
    private static Rect splitterRect(DockHit h)
    {
        Rect a = h.node.children[h.index].rect;
        Rect r = h.node.rect;
        return h.node.vertical ? Rect(r.x, a.bottom, r.w, splitterSize) : Rect(a.right, r.y, splitterSize, r.h);
    }

    /// Part at local point `p`, floating windows first.
    private DockHit hitAt(Point p)
    {
        foreach_reverse (ref Floating f; space.floating)
        {
            Rect r = f.root.rect;
            if (r.inset(-edgeOut).contains(p))
            {
                size_t e = edgesAt(r, p);
                return e != 0 ? DockHit(DockHit.Kind.edge, f.root, e) : partIn(f.root, p);
            }
        }
        return partIn(space.root, p);
    }

    /// `Edge` bits of the border of window rect `r` that `p` is on.
    private static size_t edgesAt(Rect r, Point p)
    {
        size_t e;
        if (p.x < r.x + edgeIn)
        {
            e |= Edge.left;
        }
        else if (p.x >= r.right - edgeIn)
        {
            e |= Edge.right;
        }
        if (p.y < r.y + edgeIn)
        {
            e |= Edge.top;
        }
        else if (p.y >= r.bottom - edgeIn)
        {
            e |= Edge.bottom;
        }
        return e;
    }

    /// Splitter, tab, bar or content at `p` in the tree under `root`.
    private DockHit partIn(DockNode root, Point p)
    {
        foreach (DockHit h; splitters(root))
        {
            if (splitterRect(h).inset(-2).contains(p))
            {
                return h;
            }
        }
        DockNode stack = DockSpace.stackIn(root, p);
        if (stack is null)
        {
            return DockHit.init;
        }
        if (p.y >= stack.rect.y + tabBarHeight)
        {
            return DockHit(DockHit.Kind.content, stack);
        }
        DockStyle s = tree.style!DockStyle();
        TabLook l = lookOf(s);
        if (p.x >= stack.rect.x + room(stack))
        {
            return DockHit(DockHit.Kind.bar, stack);
        }
        foreach (size_t i, Rect t; tabRects(stack, s))
        {
            if (t.contains(p))
            {
                bool x = canClose(stack.panes[i]) && slotRect(t, l).inset(-3).contains(p);
                return DockHit(x ? DockHit.Kind.close : DockHit.Kind.tab, stack, i);
            }
        }
        return DockHit(DockHit.Kind.bar, stack);
    }

    /// Tab bars, splitters and window borders belong to the view, pane content and trailing nodes to themselves.
    override Node hitTest(Point p, Point origin)
    {
        if (Rect(origin.x, origin.y, size.w, size.h).contains(p) == false)
        {
            return null;
        }
        DockHit h = hitAt(p - origin);
        if (h.kind == DockHit.Kind.bar)
        {
            if (Node* t = h.node in trailers)
            {
                if (t.parent is this)
                {
                    if (Node hit = t.hitTest(p, origin + t.offset))
                    {
                        return hit;
                    }
                }
            }
        }
        if (h.kind == DockHit.Kind.content && h.node.panes.length > 0)
        {
            if (Node* n = h.node.panes[h.node.active] in panes)
            {
                if (n.parent is this)
                {
                    if (Node hit = n.hitTest(p, origin + n.offset))
                    {
                        return hit;
                    }
                }
            }
        }
        return this;
    }

    /// Tab selection, hover, close presses, bar double clicks, and the drags.
    override bool onPointer(ref const PointerEvent e)
    {
        Point local = e.pos - bounds.pos;
        pointer = local;
        switch (e.kind)
        {
        case PointerKind.move:
            dragMove(local);
            updateCursor();
            return true;
        case PointerKind.leave:
            if (mode == Drag.none)
            {
                setHot(DockHit.init);
            }
            return true;
        case PointerKind.down:
            if (mode == Drag.keys)
            {
                reset();
            }
            if (mode != Drag.none || closing.kind != DockHit.Kind.none)
            {
                return true;
            }
            DockHit h = hitAt(local);
            if ((e.button == 1 && h.kind == DockHit.Kind.close)
                || (e.button == 2 && (h.kind == DockHit.Kind.tab || h.kind == DockHit.Kind.close)
                    && canClose(h.node.panes[h.index])))
            {
                closing = h;
                closingButton = e.button;
                closingPane = h.node.panes[h.index];
            }
            else if (e.button == 1 && e.clicks == 2 && h.kind == DockHit.Kind.bar && onBarDoubleClick !is null)
            {
                onBarDoubleClick(h.node);
            }
            else if (e.button == 1)
            {
                press(local);
                updateCursor();
            }
            return true;
        case PointerKind.up:
            if (closing.kind != DockHit.Kind.none)
            {
                if (e.button == closingButton)
                {
                    closeAt(local);
                }
                return true;
            }
            if (e.button == 1)
            {
                finish();
                setHot(hitAt(local));
                updateCursor();
            }
            return true;
        case PointerKind.cancel:
            closing = DockHit.init;
            return true;
        default:
            return false;
        }
    }

    /// Ends a close press with a release at local point `p`: on the pressed pane's close button, or its tab for the
    /// middle button, it runs `onCloseRequest`.
    private void closeAt(Point p)
    {
        closing = DockHit.init;
        DockHit h = hitAt(p);
        if (h.node is null || h.index >= h.node.panes.length || h.node.panes[h.index] != closingPane)
        {
            return;
        }
        if (h.kind == DockHit.Kind.close || (closingButton == 2 && h.kind == DockHit.Kind.tab))
        {
            onCloseRequest(closingPane);
        }
    }

    /// Scrolls the tab bar under the pointer when its tabs do not fit.
    override bool onWheel(ref const WheelEvent e)
    {
        DockHit h = hitAt(e.pos - bounds.pos);
        if (h.kind != DockHit.Kind.tab && h.kind != DockHit.Kind.close && h.kind != DockHit.Kind.bar)
        {
            return false;
        }
        DockStyle s = tree.style!DockStyle();
        TabStrip* st = &strips.require(h.node);
        if (st.wheel(e.dy != 0 ? e.dy : e.dx, widthsOf(h.node, s), room(h.node)) == false)
        {
            return false;
        }
        setHot(hitAt(e.pos - bounds.pos));
        markNeedsPaint();
        return true;
    }

    /// Tooltip of the tab under window point `p`, else the view's own.
    override string tooltipAt(Point p)
    {
        DockHit h = hitAt(p - bounds.pos);
        if (h.kind == DockHit.Kind.tab || h.kind == DockHit.Kind.close)
        {
            string t = infoOf(h.node.panes[h.index]).tooltip;
            if (t.length > 0)
            {
                return t;
            }
        }
        return tooltip;
    }

    /// Opens `tabMenu` for the tab under a right press at window point `p`. Not from the keyboard, tabs take no
    /// focus.
    override bool onContextMenu(Point p, bool keyboard)
    {
        if (keyboard || tabMenu is null)
        {
            return false;
        }
        DockHit h = hitAt(p - bounds.pos);
        if (h.kind != DockHit.Kind.tab && h.kind != DockHit.Kind.close)
        {
            return false;
        }
        Menu m = tabMenu(h.node.panes[h.index]);
        if (m is null)
        {
            return false;
        }
        m.openAt(tree, p);
        return true;
    }

    /// Makes the stack under a press at window point `p` the focused one and raises the floating window there.
    override void onPressInside(Point p)
    {
        DockHit h = hitAt(p - bounds.pos);
        if (h.kind == DockHit.Kind.tab || h.kind == DockHit.Kind.bar || h.kind == DockHit.Kind.content)
        {
            focus = h.node;
            refocus();
        }
        raiseAt(p - bounds.pos);
    }

    /// Puts the floating window under local point `p` on top. Its index after, or -1 when `p` is in none.
    private ptrdiff_t raiseAt(Point p)
    {
        DockHit h = hitAt(p);
        ptrdiff_t w = h.node is null ? -1 : space.windowOf(h.node);
        if (w >= 0 && w + 1 < space.floating.length)
        {
            w = space.raise(w);
            sync();
        }
        return w;
    }

    /// Starts what a press at `p` grabs: a tab, selected at once with keyboard focus moved into its pane, a
    /// floating window's bar or border, or a splitter. A press in a floating window raises it.
    private void press(Point p)
    {
        DockHit h = hitAt(p);
        grab = h;
        grabAt = p;
        ptrdiff_t w = raiseAt(p);
        final switch (h.kind)
        {
        case DockHit.Kind.none:
        case DockHit.Kind.close:
        case DockHit.Kind.content:
            break;
        case DockHit.Kind.tab:
            activate(h.node, h.index);
            focusInto(h.node.panes[h.index]);
            mode = Drag.pending;
            break;
        case DockHit.Kind.bar:
            if (w >= 0)
            {
                mode = Drag.window;
                grabWindow = space.floating[w].root;
                grabRect = grabWindow.rect;
            }
            break;
        case DockHit.Kind.edge:
            mode = Drag.resize;
            grabWindow = h.node;
            grabRect = h.node.rect;
            break;
        case DockHit.Kind.splitter:
            mode = Drag.splitter;
            dragShares = h.node.shares.dup;
            break;
        }
        markNeedsPaint();
    }

    /// Follows the pointer at `p` for the current drag, or updates hover.
    private void dragMove(Point p)
    {
        import std.math : abs;

        final switch (mode)
        {
        case Drag.none:
            setHot(hitAt(p));
            break;
        case Drag.splitter:
            dragTo(p);
            break;
        case Drag.pending:
            if (abs(p.x - grabAt.x) >= dragThreshold || abs(p.y - grabAt.y) >= dragThreshold)
            {
                startDrag();
                dragMove(p);
            }
            break;
        case Drag.tab:
            drop = dropAt(p);
            markNeedsPaint();
            break;
        case Drag.window:
            if (Floating* f = windowFor(grabWindow))
            {
                f.rect = Rect(grabRect.x + p.x - grabAt.x, grabRect.y + p.y - grabAt.y, grabRect.w, grabRect.h);
            }
            if (moving !is null)
            {
                drop = dropAt(p);
            }
            markNeedsLayout();
            break;
        case Drag.resize:
            resizeTo(p);
            break;
        case Drag.keys:
            break;
        }
    }

    /// Turns the pending tab press into a drag of its pane, or of its window when the pane is alone in one.
    private void startDrag()
    {
        DockNode st = grab.node;
        moving = st.panes[grab.index];
        ptrdiff_t w = space.windowOf(st);
        if (w >= 0 && space.floating[w].root is st && st.panes.length == 1)
        {
            mode = Drag.window;
            grabWindow = st;
            grabRect = st.rect;
        }
        else
        {
            mode = Drag.tab;
        }
        setHot(DockHit.init);
    }

    /// Moves the grabbed sides of the floating window to follow the pointer, keeping the smallest size and its
    /// panes' smallest sizes.
    private void resizeTo(Point p)
    {
        Rect r = grabRect;
        float dx = p.x - grabAt.x;
        float dy = p.y - grabAt.y;
        size_t e = grab.index;
        Size m = minOf(grabWindow);
        float minW = max(minWindowW, m.w);
        float minH = max(minWindowH, m.h);
        if ((e & Edge.left) != 0)
        {
            float d = min(dx, r.w - minW);
            r.x += d;
            r.w -= d;
        }
        if ((e & Edge.right) != 0)
        {
            r.w = max(r.w + dx, minW);
        }
        if ((e & Edge.top) != 0)
        {
            float d = min(dy, r.h - minH);
            r.y += d;
            r.h -= d;
        }
        if ((e & Edge.bottom) != 0)
        {
            r.h = max(r.h + dy, minH);
        }
        if (Floating* f = windowFor(grabWindow))
        {
            f.rect = r;
        }
        markNeedsLayout();
    }

    /// Ends the drag: docks the dragged pane, or floats it while `floating` is on, and focuses it. Or keeps a moved
    /// or resized window inside the view. Runs `onLayout` if anything changed.
    private void finish()
    {
        Rect view = Rect(0, 0, size.w, size.h);
        bool changed;
        final switch (mode)
        {
        case Drag.none:
        case Drag.pending:
        case Drag.keys:
            break;
        case Drag.splitter:
            changed = grab.node.shares != dragShares;
            break;
        case Drag.tab:
            if (drop.kind == Drop.Kind.none && floating == false)
            {
                break;
            }
            if (drop.kind == Drop.Kind.none)
            {
                space.undock(moving, DockSpace.keepIn(floatRect(pointer), view));
            }
            else
            {
                land(moving, drop);
            }
            focus = space.find(moving);
            sync();
            changed = true;
            break;
        case Drag.window:
        case Drag.resize:
            if (mode == Drag.window && moving !is null && drop.kind != Drop.Kind.none)
            {
                land(moving, drop);
                focus = space.find(moving);
                sync();
                changed = true;
            }
            else if (Floating* f = windowFor(grabWindow))
            {
                f.rect = DockSpace.keepIn(f.rect, view);
                changed = f.rect != grabRect;
            }
            markNeedsLayout();
            break;
        }
        reset();
        if (changed && onLayout !is null)
        {
            onLayout();
        }
    }

    /// Docks `pane` at target `d`.
    private void land(string pane, Drop d)
    {
        final switch (d.kind)
        {
        case Drop.Kind.none:
            break;
        case Drop.Kind.zone:
            space.dock(pane, d.stack, d.zone);
            break;
        case Drop.Kind.outer:
            space.dockOuter(pane, d.zone);
            break;
        case Drop.Kind.tab:
            space.move(pane, d.stack, d.index);
            break;
        }
    }

    /// Forgets the drag and hover, and gives keyboard focus back after a keyboard move.
    private void reset()
    {
        bool keys = mode == Drag.keys;
        mode = Drag.none;
        grab = DockHit.init;
        grabWindow = null;
        moving = null;
        drop = Drop.init;
        guided = null;
        aim = null;
        hot = DockHit.init;
        cursor = CursorShape.arrow;
        markNeedsPaint();
        Node back = keptFocus;
        keptFocus = null;
        if (keys && focused && tree !is null && tree.services !is null)
        {
            tree.services.setFocus(back !is null && back.tree is tree ? back : null);
        }
    }

    /// Updates the hovered part.
    private void setHot(DockHit h)
    {
        if (h != hot)
        {
            hot = h;
            markNeedsPaint();
        }
    }

    /// Cursor for the drag, or for the hovered part.
    private void updateCursor()
    {
        DockHit h = mode == Drag.none ? hot : grab;
        if (mode == Drag.window)
        {
            cursor = CursorShape.move;
        }
        else if (h.kind == DockHit.Kind.splitter && (mode == Drag.none || mode == Drag.splitter))
        {
            cursor = h.node.vertical ? CursorShape.nsResize : CursorShape.ewResize;
        }
        else if (h.kind == DockHit.Kind.edge && (mode == Drag.none || mode == Drag.resize))
        {
            bool across = (h.index & (Edge.left | Edge.right)) != 0;
            bool along = (h.index & (Edge.top | Edge.bottom)) != 0;
            bool falling = h.index == (Edge.left | Edge.top) || h.index == (Edge.right | Edge.bottom);
            cursor = across && along ? (falling ? CursorShape.nwseResize : CursorShape.neswResize)
                : across ? CursorShape.ewResize : CursorShape.nsResize;
        }
        else
        {
            cursor = CursorShape.arrow;
        }
    }

    /// Moves the dragged splitter so the pointer stays on it, keeping both neighbors at their smallest size. Stays
    /// put when the two are already smaller.
    private void dragTo(Point local)
    {
        import std.algorithm.comparison : clamp;

        DockNode n = grab.node;
        size_t i = grab.index;
        float total = 0;
        foreach (float sh; dragShares)
        {
            total += sh;
        }
        float extent = (n.vertical ? n.rect.h : n.rect.w) - splitterSize * (n.children.length - 1);
        float pair = dragShares[i] + dragShares[i + 1];
        float pairPx = extent * pair / total;
        float delta = n.vertical ? local.y - grabAt.y : local.x - grabAt.x;
        Size a = minOf(n.children[i]);
        Size b = minOf(n.children[i + 1]);
        float lo = n.vertical ? a.h : a.w;
        float hi = pairPx - (n.vertical ? b.h : b.w);
        if (hi < lo)
        {
            return;
        }
        float firstPx = clamp(extent * dragShares[i] / total + delta, lo, hi);
        n.shares[i] = pair * firstPx / pairPx;
        n.shares[i + 1] = pair - n.shares[i];
        markNeedsLayout();
    }
}

version (unittest)
{
    import dentrite.text : testText;

    /// Dock view of the sample layout with stand-in panes, laid out at 1004 by 604.
    private struct DockFixture
    {
        DockView v;        /// view under test
        Tree t;            /// its tree
        Fixed[string] nodes; /// panes by ID
        Point last;        /// last pointer position

        /// Builds and lays out the view.
        static DockFixture make()
        {
            DockFixture f;
            Node[string] ps;
            foreach (string id; ["source", "breakpoints", "watch", "memory"])
            {
                f.nodes[id] = new Fixed(Size.init);
                ps[id] = f.nodes[id];
            }
            f.v = new DockView(sample(), ps, null);
            f.t = new Tree(testText(), null, null);
            f.t.viewport = Size(1004, 604);
            f.t.setRoot(f.v);
            f.t.flush();
            return f;
        }

        /// Frees the fonts.
        void dispose()
        {
            t.text.dispose();
        }

        /// Sends pointer event `k` at `p`, then lays out.
        void send(PointerKind k, Point p)
        {
            last = p;
            PointerEvent e = PointerEvent(k, p, k == PointerKind.move ? 0 : 1);
            v.onPointer(e);
            t.flush();
        }

        /// Presses at `p` and moves 30 px down, past the drag threshold.
        void begin(Point p)
        {
            send(PointerKind.down, p);
            send(PointerKind.move, Point(p.x, p.y + 30));
        }

        /// Moves to `p`.
        void to(Point p)
        {
            send(PointerKind.move, p);
        }

        /// Sends Escape to the view, true if it took it.
        bool escape()
        {
            KeyEvent k = KeyEvent(Key.escape);
            return v.windowKey(k);
        }

        /// Releases where the pointer is.
        void end()
        {
            send(PointerKind.up, last);
        }

        /// Middle of tab `i` of the stack holding `pane`.
        Point tab(string pane, size_t i)
        {
            DockStyle s = t.style!DockStyle();
            Rect r = v.tabRects(v.space.find(pane), s)[i];
            return Point(r.x + r.w / 2, r.y + r.h / 2);
        }

        /// Middle of the drop button for `z` over the stack holding `pane`, during a drag.
        Point guide(string pane, Zone z)
        {
            DockStyle s = t.style!DockStyle();
            foreach (Guide g; v.stackGuides(v.space.find(pane), s))
            {
                if (g.zone == z)
                {
                    return Point(g.rect.x + g.rect.w / 2, g.rect.y + g.rect.h / 2);
                }
            }
            assert(false, "no such drop button");
        }
    }
}

// The view shows active panes in their stacks' content rects, switches tabs and drags splitters.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    assert(f.nodes["source"].bounds == Rect(0, 24, 500, 580));
    assert(f.nodes["breakpoints"].bounds == Rect(504, 24, 500, 276) && f.nodes["watch"].tree is null,
        "inactive tab detached");
    f.v.activate(f.v.space.find("watch"), 1);
    f.t.flush();
    assert(f.nodes["watch"].bounds == Rect(504, 24, 500, 276) && f.nodes["breakpoints"].tree is null);

    assert(f.v.hitTest(Point(502, 300), Point(0, 0)) is f.v, "splitter");
    assert(f.v.hitTest(Point(200, 300), Point(0, 0)) is f.nodes["source"], "content");
    f.send(PointerKind.down, Point(502, 300));
    f.send(PointerKind.move, Point(602, 300));
    assert(f.nodes["source"].bounds.w == 600 && f.nodes["memory"].bounds.x == 604);
    f.escape();
    f.t.flush();
    assert(f.nodes["source"].bounds.w == 500, "Escape put the splitter back");
}

// Dragging a tab onto a drop button docks it there, onto a tab bar inserts or reorders it.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    f.begin(f.tab("source", 0));
    assert(f.v.mode == Drag.tab && f.v.guided is null && f.v.drop.kind == Drop.Kind.none,
        "no buttons over its own stack");
    f.to(f.guide("memory", Zone.right));
    assert(f.v.drop.kind == Drop.Kind.zone && f.v.drop.zone == Zone.right && f.v.guided is f.v.space.find("memory"));
    f.end();
    DockNode src = f.v.space.find("source");
    assert(src.parent.vertical == false && src.parent.children[0] is f.v.space.find("memory"));
    assert(f.nodes["source"].bounds == Rect(504, 328, 500, 276));

    DockNode bw = f.v.space.find("watch");
    DockStyle s = f.t.style!DockStyle();
    Rect[] ts = f.v.tabRects(bw, s);
    f.begin(f.tab("breakpoints", 0));
    f.to(Point(ts[1].right + 10, bw.rect.y + 12));
    assert(f.v.drop.kind == Drop.Kind.tab && f.v.drop.stack is bw && f.v.drop.index == 2);
    f.end();
    assert(bw.panes == ["watch", "breakpoints"] && bw.active == 1);
    assert(f.nodes["breakpoints"].tree !is null && f.nodes["watch"].tree is null);

    f.begin(f.tab("watch", 0));
    f.to(Point(502, 590));
    assert(f.v.drop.kind == Drop.Kind.outer && f.v.drop.zone == Zone.bottom);
    f.end();
    assert(f.v.space.root.vertical && f.v.space.root.children[$ - 1].panes == ["watch"]);
    assert(f.nodes["watch"].bounds.h == 149 - tabBarHeight);
}

// A tab dropped away from the buttons floats, and its window docks back by the tab.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    f.begin(f.tab("watch", 1));
    f.to(Point(200, 400));
    assert(f.v.drop.kind == Drop.Kind.none);
    f.end();
    assert(f.v.space.floating.length == 1 && f.v.space.floating[0].rect == Rect(160, 304, 480, 300),
        "stack size, tab bar under the pointer, kept inside the view");
    assert(f.nodes["watch"].bounds == Rect(160, 328, 480, 276) && f.nodes["breakpoints"].tree !is null);
    assert(f.v.hitTest(Point(300, 400), Point(0, 0)) is f.nodes["watch"], "floating window over the main tree");
    assert(f.v.hitTest(Point(300, 312), Point(0, 0)) is f.v);

    f.begin(f.tab("watch", 0));
    assert(f.v.mode == Drag.window && f.v.moving == "watch", "a window's only tab moves the window");
    f.to(Point(400, 450));
    assert(f.v.space.floating[0].rect.y == 304 + 450 - 316);
    f.to(f.guide("source", Zone.center));
    assert(f.v.drop.kind == Drop.Kind.zone && f.v.drop.stack is f.v.space.find("source"));
    f.end();
    assert(f.v.space.floating.length == 0 && f.v.space.find("source").panes == ["source", "watch"]);
}

// A press on the content of a lower floating window raises it, and the content still gets the press.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;
    import dentrite.widgets.button : button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(1004, 604), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    Node[string] ps;
    foreach (string id; ["source", "breakpoints", "watch"])
    {
        ps[id] = new Fixed(Size.init);
    }
    ps["memory"] = button("Memory", onClick: () { ++clicks; });
    DockView v = new DockView(sample(), ps, null);
    v.space.undock("memory", Rect(100, 100, 300, 200));
    v.space.undock("watch", Rect(300, 150, 300, 200));
    v.sync();
    h.setRoot(v);
    h.frame();
    Point p = Point(ps["memory"].bounds.x + 5, ps["memory"].bounds.y + 5);
    assert(v.space.windowOf(v.space.find("memory")) == 0 && v.hitTest(p, Point(0, 0)) is ps["memory"]);
    h.inject(PointerKind.down, p);
    h.inject(PointerKind.up, p);
    h.frame();
    assert(v.space.windowOf(v.space.find("memory")) == 1 && clicks == 1);
}

// Floating windows move by the tab bar, resize by the border, rise when pressed, and Escape puts them back.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    f.v.space.undock("memory", Rect(100, 100, 300, 200));
    f.v.space.undock("watch", Rect(300, 150, 300, 200));
    f.v.sync();
    f.t.flush();
    assert(f.v.hitTest(Point(350, 250), Point(0, 0)) is f.nodes["watch"]);
    f.send(PointerKind.down, Point(380, 112));
    f.send(PointerKind.move, Point(430, 162));
    assert(f.v.cursor == CursorShape.move);
    f.end();
    assert(f.v.space.floating[1].rect == Rect(150, 150, 300, 200), "memory raised and moved");
    assert(f.v.hitTest(Point(350, 250), Point(0, 0)) is f.nodes["memory"]);

    f.send(PointerKind.move, Point(449, 349));
    assert(f.v.cursor == CursorShape.nwseResize);
    f.send(PointerKind.down, Point(449, 349));
    f.send(PointerKind.move, Point(499, 299));
    f.end();
    assert(f.v.space.floating[1].rect == Rect(150, 150, 350, 150));
    f.send(PointerKind.down, Point(151, 200));
    f.send(PointerKind.move, Point(451, 200));
    assert(f.v.space.floating[1].rect == Rect(380, 150, 120, 150), "smallest width");
    f.end();

    f.send(PointerKind.down, Point(480, 162));
    f.send(PointerKind.move, Point(700, 400));
    assert(f.escape());
    f.end();
    assert(f.v.space.floating[1].rect == Rect(380, 150, 120, 150) && f.v.mode == Drag.none);
}

// Drop buttons that overhang a narrow stack stay reachable over its neighbor, with a small enough `minPane`.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    f.v.minPane = Size(10, 10);
    f.send(PointerKind.down, Point(502, 300));
    f.send(PointerKind.move, Point(952, 300));
    f.end();
    DockNode memory = f.v.space.find("memory");
    assert(memory.rect.w < 104, "narrower than the buttons");
    f.begin(f.tab("source", 0));
    f.to(f.guide("memory", Zone.center));
    assert(f.v.guided is memory);
    Point left = f.guide("memory", Zone.left);
    assert(f.v.space.find("source").rect.contains(left), "button over the neighbor");
    f.to(left);
    assert(f.v.drop.kind == Drop.Kind.zone && f.v.drop.stack is memory && f.v.drop.zone == Zone.left);
    f.to(Point(200, 400));
    assert(f.v.guided is null && f.v.drop.kind == Drop.Kind.none, "off the buttons, over its own stack");
    f.end();
}

// Panes added, selected, retitled and removed through the view, and `current` following the focused stack.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    string[] seen;
    import dentrite.signals : effect;

    effect(() { seen ~= f.v.current.get; });
    assert(f.v.current.get == "source" && f.v.focusedStack is f.v.space.find("source"), "first stack at the start");

    Fixed log = new Fixed(Size.init);
    f.v.addPane("log", log, "Log");
    f.t.flush();
    assert(f.v.space.find("source").panes == ["source", "log"] && f.v.current.get == "log");
    assert(log.bounds == Rect(0, 24, 500, 580) && f.nodes["source"].tree is null);

    Fixed calls = new Fixed(Size.init);
    f.v.addPane("calls", calls, "Calls", f.v.space.find("memory"), Zone.bottom);
    f.t.flush();
    assert(f.v.space.find("calls").parent is f.v.space.find("memory").parent && f.v.current.get == "log",
        "another stack, focus stays");

    f.v.select("watch");
    assert(f.v.focusedStack is f.v.space.find("watch") && f.v.current.get == "watch");
    f.v.setTitle("watch", "Watches");
    assert(f.v.titleOf("watch") == "Watches");

    f.v.removePane("watch");
    assert(f.v.current.get == "breakpoints" && ("watch" in f.v.panes) is null && ("watch" in f.v.titles) is null);
    f.v.removePane("breakpoints");
    assert(f.v.current.get == "log", "focused stack gone, first stack with panes");
    assert(seen == ["source", "log", "watch", "breakpoints", "log"]);

    f.v.addPane("source", f.nodes["source"], "Source");
    assert(f.v.space.find("source").panes == ["source", "log"] && f.v.current.get == "source",
        "a held pane keeps its place and shows");
}

// Presses and drops move the focused stack, `onLayout` runs once per change made by dragging.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    int layouts;
    f.v.onLayout = () { ++layouts; };

    Point p = f.tab("watch", 1);
    f.v.onPressInside(p);
    f.send(PointerKind.down, p);
    f.end();
    assert(f.v.current.get == "watch" && layouts == 0, "a tab choice is no layout change");
    f.v.onPressInside(Point(700, 450));
    assert(f.v.current.get == "memory", "press on content");

    f.send(PointerKind.down, Point(502, 300));
    f.send(PointerKind.move, Point(602, 300));
    f.end();
    assert(layouts == 1);
    f.send(PointerKind.down, Point(602, 300));
    f.end();
    assert(layouts == 1, "splitter pressed but not moved");
    f.send(PointerKind.down, Point(602, 300));
    f.send(PointerKind.move, Point(652, 300));
    f.escape();
    f.end();
    assert(layouts == 1, "cancelled");

    f.begin(f.tab("source", 0));
    f.to(f.guide("memory", Zone.center));
    f.end();
    assert(layouts == 2 && f.v.current.get == "source" && f.v.focusedStack is f.v.space.find("memory"),
        "the dropped pane is focused");
}

// Keyboard focus moving into a pane focuses its stack, and `select` or a tab click moves keyboard focus into it.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;
    import dentrite.widgets.button : button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(1004, 604), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Node[string] ps;
    foreach (string id; ["source", "breakpoints", "watch"])
    {
        ps[id] = button(id);
    }
    ps["memory"] = new Fixed(Size.init);
    DockView v = new DockView(sample(), ps, null);
    h.setRoot(v);
    h.frame();
    assert(v.current.get == "source");
    h.setFocus(ps["breakpoints"]);
    assert(v.current.get == "breakpoints");

    v.select("source");
    assert(h.focused is ps["source"] && v.current.get == "source");
    v.select("memory");
    assert(h.focused is null && v.current.get == "memory", "no Tab stop, focus cleared");
    v.select("watch");
    h.frame();
    assert(h.focused is ps["watch"] && ps["breakpoints"].tree is null);

    DockStyle s = h.tree.style!DockStyle();
    Rect r = v.tabRects(v.space.find("breakpoints"), s)[0];
    Point p = Point(r.x + r.w / 2, r.y + r.h / 2);
    h.inject(PointerKind.down, p);
    h.inject(PointerKind.up, p);
    h.frame();
    assert(h.focused is ps["breakpoints"] && v.current.get == "breakpoints", "a tab click focuses its pane");
}

// The arrow keys walk a keyboard move through stack sides, neighbor stacks and the main area's sides, Enter docks.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    int layouts;
    f.v.onLayout = () { ++layouts; };
    bool key(uint k)
    {
        KeyEvent e = KeyEvent(k);
        bool took = f.v.onKey(e);
        f.t.flush();
        return took;
    }

    DockNode bw = f.v.space.find("watch");
    DockNode source = f.v.space.find("source");
    DockNode memory = f.v.space.find("memory");
    assert(f.v.startMove("watch") && f.v.movingByKeys && f.v.startMove("source") == false);
    assert(f.v.drop.kind == Drop.Kind.none && f.v.aim is bw, "no center button over its own stack");
    key(Key.left);
    assert(f.v.drop == Drop(Drop.Kind.zone, bw, Zone.left));
    key(Key.left);
    assert(f.v.drop == Drop(Drop.Kind.zone, source, Zone.center));
    key(Key.left);
    assert(f.v.drop == Drop(Drop.Kind.zone, source, Zone.left));
    key(Key.left);
    assert(f.v.drop == Drop(Drop.Kind.outer, null, Zone.left), "past the last stack");
    key(Key.up);
    assert(f.v.drop == Drop(Drop.Kind.outer, null, Zone.top));
    key(Key.down);
    assert(f.v.drop == Drop(Drop.Kind.zone, source, Zone.center), "back from the main area's side");
    key(Key.right);
    key(Key.right);
    assert(f.v.aim is bw && f.v.drop.kind == Drop.Kind.none);
    key(Key.down);
    assert(f.v.drop == Drop(Drop.Kind.zone, bw, Zone.bottom));
    key(Key.down);
    assert(f.v.drop == Drop(Drop.Kind.zone, memory, Zone.center));
    assert(key(Key.tab) && key(Key.a) && f.v.movingByKeys, "other keys are taken and ignored");
    assert(key(Key.enter) && f.v.movingByKeys == false);
    assert(f.v.space.find("watch") is memory && memory.panes == ["memory", "watch"] && layouts == 1);
    assert(key(Key.left) == false, "keys pass once done");

    string before = f.v.space.save().toString();
    assert(f.v.startMove("source"));
    assert(f.v.guided is null && f.v.aim is source, "no buttons over a stack holding only the moved pane");
    key(Key.right);
    assert(f.v.drop.kind == Drop.Kind.zone && f.v.drop.stack !is source);
    key(Key.escape);
    assert(f.v.movingByKeys == false && f.v.space.save().toString() == before && layouts == 1);

    assert(f.v.startMove("source"));
    key(Key.down);
    assert(f.v.drop == Drop(Drop.Kind.outer, null, Zone.bottom), "next stacks are level with it");
    key(Key.escape);
    assert(f.v.startMove("source"));
    key(Key.enter);
    assert(f.v.space.save().toString() == before && layouts == 1, "Enter without a drop button");
    assert(f.v.startMove("source"));
    key(Key.right);
    f.send(PointerKind.down, Point(10, 100));
    assert(f.v.movingByKeys == false && f.v.space.save().toString() == before, "a press cancels");
    f.send(PointerKind.up, Point(10, 100));
}

// `shiftTab` reorders a tab within its bar and keeps the shown tab.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    DockNode bw = f.v.space.find("watch");
    assert(f.v.shiftTab(1, "breakpoints") && bw.panes == ["watch", "breakpoints"] && bw.active == 1);
    assert(f.v.shiftTab(1, "breakpoints") == false, "at the end");
    f.v.activate(bw, 0);
    assert(f.v.shiftTab(-5, "breakpoints") && bw.panes == ["breakpoints", "watch"] && bw.active == 1);
    assert(f.v.current.get == "source" && f.v.shiftTab(1) == false, "alone in its stack");
    assert(f.v.shiftTab(1, "missing") == false);
}

// A keyboard move holds keyboard focus and gives it back after, also to a pane it moved.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;
    import dentrite.widgets.button : button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(1004, 604), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Node[string] ps;
    foreach (string id; ["source", "breakpoints", "watch", "memory"])
    {
        ps[id] = button(id);
    }
    DockView v = new DockView(sample(), ps, null);
    h.setRoot(v);
    h.frame();
    v.select("breakpoints");
    assert(v.startMove() && h.focused is v);
    h.injectKey(Key.tab);
    assert(h.focused is v && v.movingByKeys, "Tab stays in the move");
    h.injectKey(Key.left);
    h.injectKey(Key.left);
    h.injectKey(Key.enter);
    h.frame();
    assert(v.space.find("breakpoints") is v.space.find("source") && v.current.get == "breakpoints");
    assert(h.focused is ps["breakpoints"], "focus back on the moved pane");

    v.select("memory");
    assert(v.startMove());
    h.injectKey(Key.escape);
    assert(h.focused is ps["memory"] && v.movingByKeys == false);
    assert(v.startMove());
    h.setFocus(ps["watch"]);
    assert(v.movingByKeys == false && h.focused is ps["watch"], "losing focus cancels");
}

// Close buttons and middle clicks ask `onCloseRequest`, which may remove the pane or keep it.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    DockStyle s = f.t.style!DockStyle();
    DockNode bw = f.v.space.find("watch");
    float plain = f.v.tabRects(bw, s)[1].w;
    float memory = f.v.tabRects(f.v.space.find("memory"), s)[0].w;
    string[] asked;
    f.v.onCloseRequest = (string p) { asked ~= p; };
    f.v.closable = (string p) => p != "memory";
    assert(f.v.tabRects(bw, s)[1].w == plain + s.closeGap + s.closeSize);
    assert(f.v.tabRects(f.v.space.find("memory"), s)[0].w == memory, "not closable");

    Point x(string pane, size_t i)
    {
        TabLook l = DockView.lookOf(s);
        Rect c = slotRect(f.v.tabRects(f.v.space.find(pane), s)[i], l);
        return Point(c.x + c.w / 2, c.y + c.h / 2);
    }

    void middle(PointerKind k, Point p)
    {
        PointerEvent e = PointerEvent(k, p, 2);
        f.v.onPointer(e);
        f.t.flush();
    }

    f.send(PointerKind.down, x("breakpoints", 0));
    f.send(PointerKind.move, Point(x("breakpoints", 0).x, 300));
    assert(f.v.mode == Drag.none, "a close press does not drag");
    f.end();
    assert(asked.length == 0, "released off the button");
    f.send(PointerKind.down, x("breakpoints", 0));
    f.end();
    assert(asked == ["breakpoints"] && bw.panes == ["breakpoints", "watch"], "only asked");

    middle(PointerKind.down, f.tab("watch", 1));
    middle(PointerKind.up, f.tab("watch", 1));
    assert(asked == ["breakpoints", "watch"] && bw.active == 0, "middle click asks without choosing");
    middle(PointerKind.down, f.tab("memory", 0));
    middle(PointerKind.up, f.tab("memory", 0));
    assert(asked.length == 2, "memory cannot close");

    f.v.onCloseRequest = (string p) { f.v.removePane(p); };
    f.send(PointerKind.down, x("breakpoints", 0));
    f.end();
    assert(bw.panes == ["watch"] && f.nodes["watch"].tree !is null);
}

// With `floating` off a tab dropped away from the buttons goes back, and a bar double click runs its callback.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    int layouts;
    f.v.onLayout = () { ++layouts; };
    f.v.floating = false;
    f.begin(f.tab("watch", 1));
    f.to(Point(200, 400));
    assert(f.v.drop.kind == Drop.Kind.none);
    f.end();
    assert(f.v.space.floating.length == 0 && f.v.space.find("watch").panes == ["breakpoints", "watch"]);
    assert(layouts == 0);

    DockNode clicked;
    f.v.onBarDoubleClick = (DockNode s) { clicked = s; };
    DockNode memory = f.v.space.find("memory");
    Point bar = Point(memory.rect.right - 20, memory.rect.y + 12);
    PointerEvent e = PointerEvent(PointerKind.down, bar, 1, 2);
    f.v.onPointer(e);
    f.send(PointerKind.up, bar);
    assert(clicked is memory && f.v.mode == Drag.none);
    e.pos = f.tab("memory", 0);
    clicked = null;
    f.v.onPointer(e);
    f.send(PointerKind.up, e.pos);
    assert(clicked is null, "not on a tab");
}

// Splitters, floating window borders and side drop buttons keep to `minPane`.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    f.v.minPane = Size(180, 120);
    f.send(PointerKind.down, Point(502, 300));
    f.send(PointerKind.move, Point(1000, 300));
    f.end();
    assert(f.nodes["source"].bounds.w == 1004 - splitterSize - 180, "the column keeps 180");
    f.send(PointerKind.down, Point(900, 302));
    f.send(PointerKind.move, Point(900, 600));
    f.end();
    assert(f.nodes["memory"].bounds.h == 120);

    f.begin(f.tab("source", 0));
    f.to(f.guide("memory", Zone.center));
    DockStyle s = f.t.style!DockStyle();
    Guide[] gs = f.v.stackGuides(f.v.space.find("memory"), s);
    assert(gs.length == 1 && gs[0].zone == Zone.center, "halves would be too small");
    f.escape();
    f.end();

    f.v.space.undock("watch", Rect(100, 100, 400, 300));
    f.v.sync();
    f.t.flush();
    f.send(PointerKind.down, Point(499, 399));
    f.send(PointerKind.move, Point(150, 150));
    f.end();
    assert(f.v.space.floating[0].rect == Rect(100, 100, 180, 120 + tabBarHeight));
}

// A right press on a tab opens `tabMenu` for its pane without choosing it.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;
    import dentrite.widgets.menu : menuItem;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(1004, 604), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Node[string] ps;
    foreach (string id; ["source", "breakpoints", "watch", "memory"])
    {
        ps[id] = new Fixed(Size.init);
    }
    DockView v = new DockView(sample(), ps, null);
    string asked;
    Menu m = new Menu([menuItem("Close", () {})]);
    v.tabMenu = (string pane) { asked = pane; return pane == "memory" ? null : m; };
    h.setRoot(v);
    h.frame();
    DockStyle s = h.tree.style!DockStyle();
    Rect r = v.tabRects(v.space.find("watch"), s)[1];
    Point p = Point(r.x + r.w / 2, r.y + r.h / 2);
    h.inject(PointerKind.down, p, 1, 3);
    h.inject(PointerKind.up, p, 1, 3);
    h.frame();
    assert(asked == "watch" && m.isOpen && v.space.find("watch").active == 0);
    m.close();
    h.inject(PointerKind.down, Point(600, 400), 1, 3);
    h.inject(PointerKind.up, Point(600, 400), 1, 3);
    assert(asked == "watch" && m.isOpen == false, "not over a tab");
}

// Tab content from `setTabInfo` follows its signals, tabs show their tooltips, and new panes are asked too.
unittest
{
    import dentrite.signals : signal;
    import std.algorithm.searching : canFind;

    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    DockStyle s = f.t.style!DockStyle();
    DockNode bw = f.v.space.find("watch");
    float w = f.v.tabRects(bw, s)[1].w;
    Signal!bool dirty = signal(false);
    string[] asked;
    f.v.setTabInfo((string p) {
        asked ~= p;
        return p == "watch" ? TabInfo(null, tooltip: "/w", modified: dirty.get) : TabInfo.init;
    });
    assert(f.v.titleOf("watch") == "watch" && f.v.tabRects(bw, s)[1].w == w, "a null title keeps the pane's");
    dirty.set(true);
    assert(f.v.tabRects(bw, s)[1].w == w + s.closeGap + s.closeSize, "room for the dot");
    assert(f.v.tooltipAt(f.tab("watch", 1)) == "/w" && f.v.tooltipAt(f.tab("breakpoints", 0)) is null);
    assert(f.v.tooltipAt(Point(200, 300)) is null, "pane content");
    asked = null;
    f.v.addPane("log", new Fixed(Size.init), "Log");
    assert(asked.canFind("log"));
}

// Trailing nodes sit at the right end of their stack's tab bar, take presses there, and go with their stack.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    int made;
    f.v.setTrailing((DockNode st) {
        ++made;
        return new Fixed(Size(30, 16));
    });
    f.t.flush();
    DockNode memory = f.v.space.find("memory");
    Node t = f.v.trailers[memory];
    assert(made == 3 && t.bounds == Rect(memory.rect.right - 30, memory.rect.y + 4, 30, 16));
    Point at = Point(memory.rect.right - 15, memory.rect.y + 12);
    assert(f.v.hitTest(at, Point(0, 0)) is t && f.v.room(memory) == memory.rect.w - 30);

    f.v.addPane("log", new Fixed(Size.init), "Log", memory, Zone.bottom);
    f.t.flush();
    assert(made == 4 && f.v.trailers[memory] is t, "kept for the old stack, made for the new one");
    f.v.removePane("memory");
    f.t.flush();
    assert(t.parent is null && (memory in f.v.trailers) is null);
}

// A tab bar with more tabs than room scrolls the chosen tab into view, scrolls with the wheel, and keeps tabs out
// of the trailing node's room.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(1004, 604), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Node[string] ps;
    foreach (string id; ["source", "breakpoints", "watch", "memory"])
    {
        ps[id] = new Fixed(Size.init);
    }
    DockView v = new DockView(sample(), ps, null);
    v.setTrailing((DockNode st) => new Fixed(Size(40, 16)));
    h.setRoot(v);
    h.frame();
    DockNode src = v.space.find("source");
    foreach (int i; 0 .. 12)
    {
        string id = "a long file name " ~ cast(char)('a' + i);
        v.addPane(id, new Fixed(Size.init), id, src);
    }
    v.select("source");
    h.frame();
    DockStyle s = h.tree.style!DockStyle();
    assert(v.tabRects(src, s)[0].x == 0);
    v.select("a long file name l");
    h.frame();
    Rect last = v.tabRects(src, s)[$ - 1];
    assert(last.right == src.rect.w - 40, "the last tab scrolled in, left of the trailing node");
    assert(v.hitAt(Point(src.rect.w - 20, 12)).kind == DockHit.Kind.bar);
    WheelEvent w = WheelEvent(Point(100, 12), 0, -1e6);
    assert(v.onWheel(w));
    assert(v.tabRects(src, s)[0].x == 0);
    w.pos = Point(100, 300);
    assert(v.onWheel(w) == false, "not over a tab bar");
}

// `fileHover` lights the stack under the point, floating windows first, and `fileLeave` turns it off.
unittest
{
    DockFixture f = DockFixture.make();
    scope (exit)
    {
        f.dispose();
    }
    assert(f.v.fileHover(Point(700, 450)) is f.v.space.find("memory") && f.v.fileStack is f.v.space.find("memory"));
    assert(f.v.fileHover(Point(502, 300)) is null && f.v.fileStack is null, "splitter");
    f.v.space.undock("watch", Rect(600, 350, 300, 200));
    f.v.sync();
    f.t.flush();
    assert(f.v.fileHover(Point(700, 450)) is f.v.space.find("watch"), "floating window over memory");
    f.v.fileLeave();
    assert(f.v.fileStack is null);
}
