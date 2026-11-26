/// Tree view: a hierarchy shown as indented rows that expand and collapse, over a virtual list.
///
/// The tree reads its data through delegates, so nodes stay in the app's own types. Only the rows of expanded
/// nodes are listed, and only the rows in view exist as nodes. Keys must be unique across the whole tree.
module dentrite.widgets.tree;

import dentrite.containers : ScrollView, scroll;
import dentrite.access : contentText, textOnly;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.icons : Icon, paintIcon;
import dentrite.widgets.list : ListStyle, VirtualList, virtualList;
import std.algorithm.comparison : max;
import std.math : round;

/// Look of tree rows. Backgrounds and padding come from `ListStyle`.
struct TreeStyle
{
    enum section = "tree"; /// section name in theme files

    Color arrow = Color(0x99, 0x99, 0x99, 0xff);      /// expand arrow
    Color arrowHover = Color(0xee, 0xee, 0xee, 0xff); /// expand arrow under the pointer
    float indent = 16;   /// width of a level, also the arrow column
    float arrowSize = 8; /// size of the expand arrow
}

/// One listed row of a tree.
struct TreeEntry(T)
{
    T item;            /// app item shown in this row
    size_t depth;      /// nesting level, 0 for the roots
    size_t parent = size_t.max; /// row index of the parent, `size_t.max` for a root
    bool expandable;   /// has children
    bool expanded;     /// children are listed below
}

/// Tree over app data. Build it with `treeView`.
final class TreeView(K, T) : Node
{
    VirtualList!(K, TreeEntry!T) list; /// virtual list showing the listed rows
    ScrollView view;                   /// scroll view around the list

    private T[] delegate() roots;          /// top nodes
    private T[] delegate(T) childrenOf;    /// children of a node
    private bool delegate(T) hasChildren;  /// true if a node has children, without listing them, or null
    private K delegate(T) keyOf;           /// node key
    private Signal!K selection;            /// selected key
    private void delegate(T) activated;    /// Enter or a double click on a leaf, or null
    private bool[K] open;                  /// expanded keys
    private Signal!uint changes;           /// bumped when `open` changes
    private TreeEntry!T[] entries;         /// rows listed last

    /// Creates a tree. Use `treeView`, which also builds the list.
    this(T[] delegate() roots, T[] delegate(T) childrenOf, bool delegate(T) hasChildren, K delegate(T) keyOf,
        Signal!K selection, void delegate(T) activated)
    {
        this.roots = roots;
        this.childrenOf = childrenOf;
        this.hasChildren = hasChildren;
        this.keyOf = keyOf;
        this.selection = selection;
        this.activated = activated;
        changes = signal(0u);
    }

    /// True if the node of `k` is expanded.
    bool isExpanded(K k)
    {
        return (k in open) !is null;
    }

    /// Lists the children of the node of `k`.
    void expand(K k)
    {
        if ((k in open) is null)
        {
            open[k] = true;
            changes.set(changes.peek + 1);
        }
    }

    /// Hides the children of the node of `k`. The children leave the selection, and the current node moves to
    /// the collapsed one when it was among them.
    void collapse(K k)
    {
        if ((k in open) is null)
        {
            return;
        }
        ptrdiff_t at = indexOf(k);
        ptrdiff_t sel = list.selectedIndex();
        bool moved = at >= 0 && sel > at && isUnder(sel, at);
        Signal!(K[]) multi = list.selectedKeys;
        batch(() {
            if (moved)
            {
                selection.set(k);
            }
            if (multi !is null && at >= 0)
            {
                deselectUnder(multi, at, moved);
            }
        });
        open.remove(k);
        changes.set(changes.peek + 1);
    }

    /// Expands or collapses the node of `k`.
    void toggle(K k)
    {
        if (isExpanded(k))
        {
            collapse(k);
        }
        else
        {
            expand(k);
        }
    }

    /// Rows listed now, in order.
    const(TreeEntry!T)[] rows()
    {
        return entries;
    }

    /// Row of the node of `k`, or -1 when it is not listed.
    ptrdiff_t indexOf(K k)
    {
        foreach (size_t i, ref TreeEntry!T e; entries)
        {
            if (keyOf(e.item) == k)
            {
                return i;
            }
        }
        return -1;
    }

    /// Drops the keys of the rows under row `at` from `multi`, adding row `at` when `add` is set.
    private void deselectUnder(Signal!(K[]) multi, size_t at, bool add)
    {
        bool[K] hidden;
        for (size_t j = at + 1; j < entries.length && isUnder(j, at); ++j)
        {
            hidden[keyOf(entries[j].item)] = true;
        }
        K k = keyOf(entries[at].item);
        K[] keep;
        bool has;
        foreach (K key; multi.peek)
        {
            if ((key in hidden) is null)
            {
                keep ~= key;
                has = has || key == k;
            }
        }
        if (add && has == false)
        {
            keep ~= k;
        }
        multi.set(keep);
    }

    /// True if row `i` is inside the children of row `ancestor`.
    private bool isUnder(size_t i, size_t ancestor)
    {
        for (size_t p = entries[i].parent; p != size_t.max; p = entries[p].parent)
        {
            if (p == ancestor)
            {
                return true;
            }
        }
        return false;
    }

    /// Rows of the roots and of every expanded node below them, read by the list effect.
    private TreeEntry!T[] flatten()
    {
        changes.get;
        TreeEntry!T[] rows;
        void walk(T[] items, size_t depth, size_t parent)
        {
            foreach (T it; items)
            {
                bool can = hasChildren !is null ? hasChildren(it) : childrenOf(it).length > 0;
                bool ex = can && (keyOf(it) in open) !is null;
                rows ~= TreeEntry!T(it, depth, parent, can, ex);
                if (ex)
                {
                    walk(childrenOf(it), depth + 1, rows.length - 1);
                }
            }
        }

        walk(roots(), 0, size_t.max);
        entries = rows;
        return rows;
    }

    /// Expands or collapses `e` if it has children, else runs the activation handler.
    private void activate(TreeEntry!T e)
    {
        if (e.expandable)
        {
            toggle(keyOf(e.item));
        }
        else if (activated !is null)
        {
            activated(e.item);
        }
    }

    /// Right expands, or goes to the first child of an expanded node. Left collapses, or goes to the parent.
    override bool onKey(ref const KeyEvent e)
    {
        ptrdiff_t at = list.selectedIndex();
        if (e.mods != 0 || at < 0 || (e.key != Key.left && e.key != Key.right))
        {
            return false;
        }
        TreeEntry!T en = entries[at];
        if (e.key == Key.right)
        {
            if (en.expandable && en.expanded == false)
            {
                expand(keyOf(en.item));
            }
            else if (en.expanded && at + 1 < entries.length)
            {
                list.choose(at + 1, 0);
            }
        }
        else if (en.expanded)
        {
            collapse(keyOf(en.item));
        }
        else if (en.parent != size_t.max)
        {
            list.choose(en.parent, 0);
        }
        return true;
    }

    /// Tree of the bound rows.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.tree;
        a.multiselectable = list.selectedKeys !is null;
    }

    /// The scroll view's size.
    protected override Size performLayout(Constraints c)
    {
        children[0].offset = Point.init;
        return children[0].layout(c);
    }
}

/// Row of a tree: indent, expand arrow and the app's content. Press selects, a press on the arrow or a double
/// click expands or collapses.
private final class TreeRow(K, T) : Node
{
    private TreeView!(K, T) view; /// owning tree
    private TreeEntry!T shown;    /// entry last read
    private bool selected;        /// drawn as selected
    private bool overArrow;       /// pointer over the expand arrow

    /// Wraps `content` for the entry `entry` returns. The effect belongs to the current owner.
    this(TreeView!(K, T) view, TreeEntry!T delegate() entry, Node content)
    {
        this.view = view;
        add(content);
        interactive = true;
        effect(() {
            TreeEntry!T e = entry();
            bool sel = view.list.isSelected(view.keyOf(e.item));
            if (e.depth != shown.depth)
            {
                markNeedsLayout();
            }
            shown = e;
            selected = sel;
            markNeedsPaint();
        });
    }

    /// Tree item named by its content, with its depth and open state.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.treeItem;
        a.hidden = view.list.offView(this);
        a.label = contentText(this);
        a.leaf = textOnly(this);
        a.level = cast(uint) shown.depth + 1;
        a.selected = tri(selected);
        a.allow(AccessAction.click);
        if (shown.expandable)
        {
            a.expanded = tri(shown.expanded);
            a.allow(shown.expanded ? AccessAction.collapse : AccessAction.expand);
        }
    }

    /// Click selects, expand and collapse open and close the children.
    override bool accessAction(ref const AccessRequest r)
    {
        K k = view.keyOf(shown.item);
        switch (r.action)
        {
        case AccessAction.click:
            view.list.press(view.list.indexOf(k), 0, this);
            view.list.endDrag();
            return true;
        case AccessAction.expand:
            view.expand(k);
            return true;
        case AccessAction.collapse:
            view.collapse(k);
            return true;
        default:
            return false;
        }
    }

    /// Left edge of the arrow column, from the row's left edge.
    private float arrowX(const ref TreeStyle t, const ref ListStyle l)
    {
        return l.padX + shown.depth * t.indent;
    }

    /// True if window point `p` is over the expand arrow.
    private bool onArrow(Point p)
    {
        TreeStyle t = tree.style!TreeStyle();
        ListStyle l = tree.style!ListStyle();
        float x = p.x - bounds.x - arrowX(t, l);
        return shown.expandable && x >= 0 && x < t.indent;
    }

    /// Content after the indent and arrow column, inside the list padding.
    protected override Size performLayout(Constraints c)
    {
        TreeStyle t = tree.style!TreeStyle();
        ListStyle l = tree.style!ListStyle();
        float x = arrowX(t, l) + t.indent;
        float w = max(0f, c.maxW - x - l.padX);
        Size cs = children[0].layout(Constraints(0, w, 0, float.infinity));
        children[0].offset = Point(x, l.padY);
        return c.constrain(Size(x + cs.w + l.padX, max(cs.h, t.arrowSize) + l.padY * 2));
    }

    /// Background for the state, the arrow and the content.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TreeStyle t = ctx.style!TreeStyle();
        ListStyle l = ctx.style!ListStyle();
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (selected)
        {
            ctx.list.rect(r, l.rowSelected);
            ctx.list.rect(Rect(r.x, r.y, 2, r.h), l.selectedBar);
        }
        else if (hoverInside)
        {
            ctx.list.rect(r, l.rowHover);
        }
        if (shown.expandable)
        {
            float s = t.arrowSize;
            Rect box = Rect(origin.x + arrowX(t, l) + round((t.indent - s) / 2), origin.y + round((size.h - s) / 2),
                s, s);
            paintIcon(*ctx.list, shown.expanded ? Icon.chevronDown : Icon.chevronRight, box,
                overArrow && hovered ? t.arrowHover : t.arrow);
        }
        paintChildren(ctx, origin);
    }

    /// Hover, then a press selecting the row or toggling it, and a drag selecting a range.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.leave:
        case PointerKind.move:
            if (e.kind == PointerKind.move && pressed)
            {
                view.list.dragTo(e.pos.y);
            }
            bool over = e.kind != PointerKind.leave && onArrow(e.pos);
            if (over != overArrow || e.kind != PointerKind.move)
            {
                overArrow = over;
                markNeedsPaint();
            }
            return true;
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            K k = view.keyOf(shown.item);
            if (onArrow(e.pos))
            {
                view.toggle(k);
                return true;
            }
            view.list.press(view.list.indexOf(k), e.mods, this);
            if (e.clicks == 2 && e.mods == 0)
            {
                view.activate(shown);
            }
            return true;
        case PointerKind.up:
        case PointerKind.cancel:
            view.list.endDrag();
            return true;
        default:
            return false;
        }
    }
}

/// Tree over `roots` and `children`, one Tab stop moving `selected` with the arrow keys:
/// `treeView!(string, Dir)(() => [root], (Dir d) => d.subdirs, (Dir d) => d.path, (Dir delegate() d) =>
/// label(() => d().name), selected)`. `row` builds the content of a row around a getter of its node and must
/// read it inside effects, as rows are reused. Enter or a double click expands or collapses a node with
/// children, and runs `onActivate` on a leaf. `hasChildren` saves listing children just to know if a node has
/// any. With `text` typing selects the next shown node whose text starts with the typed letters. With `multi`
/// more than one node may be selected, see `VirtualList.setMultiple`. The scopes belong to the current owner.
TreeView!(K, T) treeView(K, T, R : Node)(T[] delegate() roots, T[] delegate(T) children, K delegate(T) key,
    R delegate(T delegate()) row, Signal!K selected, void delegate(T) onActivate = null,
    bool delegate(T) hasChildren = null, string delegate(T) text = null, Signal!(K[]) multi = null)
{
    TreeView!(K, T) t = new TreeView!(K, T)(roots, children, hasChildren, key, selected, onActivate);
    /// Row around the content for the entry `e` returns.
    Node makeRow(TreeEntry!T delegate() e)
    {
        return new TreeRow!(K, T)(t, e, row(() => e().item));
    }

    string delegate(TreeEntry!T) entryText;
    if (text !is null)
    {
        entryText = (TreeEntry!T e) => text(e.item);
    }
    t.list = virtualList!(K, TreeEntry!T)(&t.flatten, (TreeEntry!T e) => key(e.item), &makeRow, selected,
        &t.activate, entryText, multi);
    t.list.accessRole = Role.none;
    t.view = scroll()(t.list);
    t.add(t.view);
    return t;
}

version (unittest)
{
    /// Node of the test trees.
    private final class Dir
    {
        string name; /// unique name
        Dir[] kids;  /// children

        /// Creates a node.
        this(string name, Dir[] kids...)
        {
            this.name = name;
            this.kids = kids.dup;
        }
    }
}

// Rows follow expansion, arrows walk the tree, collapsing moves the selection up, and the arrow and double
// clicks toggle.
unittest
{
    import dentrite.containers : sized;
    import dentrite.host : Host;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 300);
    scope (exit)
    {
        h.close();
    }
    Dir root = new Dir("root", new Dir("a", new Dir("a1"), new Dir("a2")), new Dir("b"));
    Signal!string sel = signal("");
    string opened;
    TreeView!(string, Dir) t = treeView!(string, Dir)(() => [root], (Dir d) => d.kids, (Dir d) => d.name,
        (Dir delegate() d) => label(() => d().name), sel, (Dir d) { opened = d.name; }, null,
        (Dir d) => d.name);
    h.setRoot(sized(h: 200)(t));
    h.frame();
    assert(t.rows.length == 1 && t.rows[0].expandable && t.rows[0].expanded == false);

    /// Window point of the middle of row `i`'s content, or of its arrow.
    Point at(size_t i, bool arrow = false)
    {
        Rect b = t.list.children[i].bounds;
        TreeStyle s;
        ListStyle l;
        float x = arrow ? b.x + l.padX + t.rows[i].depth * s.indent + s.indent / 2 : b.right - 10;
        return Point(x, b.y + b.h / 2);
    }

    /// Press and release at `p`, as a double click when `clicks` is 2.
    void click(Point p, ubyte clicks = 1)
    {
        h.inject(PointerKind.move, p);
        h.inject(PointerKind.down, p, clicks);
        h.inject(PointerKind.up, p, clicks);
        h.frame();
    }

    click(at(0));
    assert(sel.peek == "root" && h.focused is t.list, "a press selects and focuses the list");
    h.injectKey(Key.right, 0);
    h.frame();
    assert(t.rows.length == 3 && t.rows[1].item.name == "a" && t.rows[1].depth == 1);
    h.injectKey(Key.right, 0);
    assert(sel.peek == "a", "right on an expanded node goes to its first child");
    h.injectKey(Key.right, 0);
    h.injectKey(Key.down, 0);
    h.frame();
    assert(t.rows.length == 5 && sel.peek == "a1" && t.rows[2].parent == 1);
    h.injectKey(Key.left, 0);
    assert(sel.peek == "a", "left on a leaf goes to the parent");
    h.injectKey(Key.down, 0);
    t.collapse("a");
    h.frame();
    assert(sel.peek == "a" && t.rows.length == 3, "collapsing moves the selection out of the children");

    click(at(1, true));
    assert(t.isExpanded("a") && t.rows.length == 5 && sel.peek == "a", "the arrow toggles without selecting");
    click(at(4), 2);
    assert(sel.peek == "b" && opened == "b", "a double click activates a leaf");
    click(at(1), 2);
    assert(t.isExpanded("a") == false && t.rows.length == 3, "a double click toggles a node with children");
    h.injectKey(Key.enter, 0);
    h.frame();
    assert(t.rows.length == 5, "so does Enter");
    h.injectText("a2");
    assert(sel.peek == "a2", "typing selects a shown node");
}

// With `multi` Ctrl clicks pick several nodes, and collapsing drops the hidden ones, adding the collapsed node
// when the current node was among them.
unittest
{
    import dentrite.containers : sized;
    import dentrite.host : Host;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(300, 300);
    scope (exit)
    {
        h.close();
    }
    Dir root = new Dir("root", new Dir("a", new Dir("a1"), new Dir("a2")), new Dir("b"));
    Signal!string sel = signal("");
    Signal!(string[]) picked = signal(cast(string[]) null);
    TreeView!(string, Dir) t = treeView!(string, Dir)(() => [root], (Dir d) => d.kids, (Dir d) => d.name,
        (Dir delegate() d) => label(() => d().name), sel, multi: picked);
    h.setRoot(sized(h: 200)(t));
    t.expand("root");
    t.expand("a");
    h.frame();
    clickOn(h, t.list["a1"]);
    clickOn(h, t.list["b"], 1, Mod.ctrl);
    assert(picked.peek == ["a1", "b"] && sel.peek == "b");
    t.collapse("a");
    h.frame();
    assert(picked.peek == ["b"] && sel.peek == "b", "a1 is hidden, the current node stays");
    t.expand("a");
    h.frame();
    clickOn(h, t.list["a2"], 1, Mod.shift);
    assert(picked.peek == ["a2", "b"] && sel.peek == "a2", "Shift picks from the anchor, the last Ctrl click");
    t.collapse("a");
    h.frame();
    assert(picked.peek == ["b", "a"] && sel.peek == "a");
}
