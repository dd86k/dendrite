/// List rows: keyed lists with a node per item, virtual lists with pooled nodes for the visible items.
module dentrite.widgets.list;

import core.time : Duration, MonoTime, msecs, seconds;
import dentrite.containers;
import dentrite.access : AccessFocus, contentText, textOnly;
import dentrite.node;
import dentrite.signals;
import dentrite.virtual : Anchor, capture, matchKeys, restore, RowHeights, RowRange;
import dentrite.widgets.button : PressBehavior;
import dentrite.widgets.label : Label;
import std.algorithm.comparison : clamp, max, min;
import std.algorithm.mutation : remove, swap;
import std.algorithm.searching : all, startsWith;
import std.math : isInfinity, isNaN;
import std.range : front;
import std.string : strip;
import std.uni : toLower;
import std.utf : byDchar, stride;

/// Letters typed into a list, jumping to the next row whose text starts with them. Letters typed within
/// `delay` of each other add up, and the same letter again goes to the next row starting with it.
struct TypeAhead
{
    string typed;  /// letters typed in the current search
    MonoTime last; /// time of the last letter
    enum Duration delay = 1.seconds; /// pause that starts a new search

    /// Index of the row to select after typing `s` at time `now`, or -1 when nothing matches or `s` is a space
    /// starting a search. `at` is the selected row, or -1, and `textOf(i)` the text of row `i` of `count`.
    ptrdiff_t type(string s, ptrdiff_t at, size_t count, scope string delegate(size_t) textOf, MonoTime now)
    {
        if (now - last > delay)
        {
            typed = null;
        }
        if (typed.length == 0 && s.strip.length == 0)
        {
            return -1;
        }
        last = now;
        typed ~= s;
        string want = typed;
        bool repeated = typed.byDchar.all!(c => toLower(c) == toLower(typed.front));
        if (repeated)
        {
            want = typed[0 .. typed.stride];
        }
        size_t start = at < 0 ? 0 : repeated ? at + 1 : at;
        foreach (size_t n; 0 .. count)
        {
            size_t i = (start + n) % count;
            if (textOf(i).startsWith!((a, b) => toLower(a) == toLower(b))(want))
            {
                return i;
            }
        }
        return -1;
    }
}

/// Column of rows reconciled by key. Rows live in scopes under one long-lived list scope,
/// so re-running the list effect never disposes rows that are still shown.
final class KeyedColumn(K, T) : Flex
{
    int created;      /// rows built so far
    int disposed;     /// rows dropped so far

    private Scope owner;            /// parent of every row scope
    private K delegate(T) keyOf;    /// item key
    private Node delegate(T) make;  /// builds a row and its effects
    private Node[K] rows;           /// live rows by key

    /// Creates an empty column with `gap` between rows, whose rows belong to `owner`.
    this(float gap, Scope owner, K delegate(T) keyOf, Node delegate(T) make)
    {
        super(Axis.vertical, gap, CrossAlign.stretch, null);
        this.owner = owner;
        this.keyOf = keyOf;
        this.make = make;
    }

    /// Reuses rows whose key survives, builds new ones, disposes the rest.
    void update(T[] items)
    {
        Node[] next;
        bool[K] keep;
        foreach (T item; items)
        {
            K k = keyOf(item);
            keep[k] = true;
            if (Node* found = k in rows)
            {
                next ~= *found;
                continue;
            }
            Node made;
            Scope s;
            runWithOwner(owner, () {
                s = effectScope(() { made = make(item); });
            });
            made.owner = s;
            rows[k] = made;
            next ~= made;
            ++created;
        }
        Node[] dropped;
        foreach (K k; rows.keys)
        {
            if ((k in keep) is null)
            {
                dropped ~= rows[k];
                rows.remove(k);
                ++disposed;
            }
        }
        setChildren(next);
        foreach (Node n; dropped)
        {
            n.dispose();
        }
    }

    /// Row of key `k`, or null.
    Node opIndex(K k)
    {
        Node* r = k in rows;
        return r is null ? null : *r;
    }
}

/// Wraps `make` to return `Node`, so row and cell builders may return any node class without a cast.
Node delegate(A) asNodeMaker(R : Node, A)(R delegate(A) make)
{
    static if (is(R == Node))
    {
        return make;
    }
    else
    {
        return delegate Node(A a) { return make(a); };
    }
}

/// Column of rows keyed by `key`, rebuilt from `items` when the signals it reads change:
/// `keyedColumn(() => tasks.get, (Task t) => t.id, &taskRow)`. Rows whose key stays keep their node.
/// The list effect and scope belong to the current owner.
KeyedColumn!(K, T) keyedColumn(K, T, R : Node)(T[] delegate() items, K delegate(T) key, R delegate(T) row,
    float gap = 0)
{
    Scope listOwner = effectScope(() {});
    KeyedColumn!(K, T) list = new KeyedColumn!(K, T)(gap, listOwner, key, asNodeMaker(row));
    effect(() { list.update(items()); });
    return list;
}

/// Rows for the items in view, inside a ScrollView. Each row node reads its item through a signal
/// of its slot. A slot keeps its node while its key stays in view, and slots that leave the view go
/// to a pool and take the next key that enters it, so scrolling and filtering rebind a few rows
/// instead of building them.
///
/// Heights come from measuring rows and follow their keys when the items change. Unmeasured rows count as the
/// first measured height. In a scroll view, the row at the top of the view stays in place when rows above it
/// change height or are added or removed, such as older messages loaded above. Rows paint into layers of their
/// own, so scrolling moves their meshes and a changed row repaints alone.
/// NOTE: row positions are floats, so rows past about 16 M px lose precision.
/// NOTE: pooled rows keep following their last item. The row holding focus stays bound out of view, and focus
/// is cleared when its item leaves the items, so keys never reach a row that took another item.
final class VirtualList(K, T) : Node, ViewportAware, RowChooser, AccessFocus
{
    int built;          /// rows built so far
    int rebound;        /// times a pooled row took another item
    size_t overscan = 4; /// rows bound past each edge of the view

    /// Row with its own item signal, bound to one key or waiting in the pool.
    private static final class Slot
    {
        Node node;      /// row root
        Signal!T item;  /// item shown, read by the row's effects
        K key;          /// key of `item`
        size_t index;   /// position of `item` in the items
        bool keep;      /// still in view, during `bind`
    }

    private K delegate(T) keyOf;             /// item key
    private Node delegate(T delegate()) make; /// builds a row reading its item through the getter
    private T[] items;          /// all items, in order
    private K[] itemKeys;       /// key of each item
    private K[] spareKeys;      /// buffer for the next `itemKeys`
    private RowHeights heights; /// row heights, null until the next layout
    private float estimate;     /// height of unmeasured rows, NaN before the first row is measured
    private float width;        /// width the heights belong to
    private uint styleVersion;  /// tree style version the estimate belongs to
    private float top = 0;      /// scroll distance, from the scroll view
    private float viewH = float.infinity; /// view height, everything until a scroll view says otherwise
    private float shift = 0;    /// scroll move owed to the scroll view, see `takeShift`
    private RowRange bound;     /// rows bound and laid out
    private Slot[K] byKey;      /// bound slots
    private Slot[] active;      /// bound slots in item order
    private Slot[] scratch;     /// next `active` while binding
    private Slot[] pool;        /// unbound slots
    private Signal!K selection; /// selected key, null without keyboard selection
    private void delegate(T) activated; /// Enter on the selected item
    private string delegate(T) textOf;  /// item text for typing to select, or null
    private TypeAhead search;           /// letters typed so far
    private Signal!(K[]) multi;         /// selected keys when more than one may be, or null
    private K anchor;                   /// key a Shift range starts from
    private bool anchored;              /// `anchor` is set
    private K[] lookupFor;              /// `multi` value `lookup` holds
    private bool[K] lookup;             /// keys of `lookupFor`
    private Node dragRow;               /// row a held press started on, kept bound, or null
    private size_t dragAt;              /// item the drag selected last
    private bool dragMoved;             /// the drag reached another item
    private K[] dragBase;               /// keys kept selected under a drag that started with Ctrl
    private float dragY;                /// window y of the pointer during that drag

    Role accessRole = Role.listBox; /// role for assistive technologies, `Role.none` inside a tree or table

    /// Creates an empty list. Use `virtualList`, which also sets `owner`.
    this(K delegate(T) keyOf, Node delegate(T delegate()) make)
    {
        this.keyOf = keyOf;
        this.make = make;
    }

    /// List of the bound rows.
    override void describe(ref AccessInfo a)
    {
        a.role = accessRole;
        a.multiselectable = multi !is null;
    }

    /// Row of the selected item while bound, which has the focus the list holds.
    Node accessFocus()
    {
        return selection is null ? null : opIndex(selection.peek);
    }

    /// Number of items.
    size_t count() const
    {
        return items.length;
    }

    /// Fills the place of the row holding `n` among all items, and whether it is selected.
    void describeRow(Node n, ref AccessInfo a)
    {
        foreach (Slot s; active)
        {
            if (n.isInside(s.node))
            {
                a.hidden = offView(s);
                a.position = cast(uint) s.index + 1;
                a.setSize = cast(uint) items.length;
                if (selection !is null)
                {
                    a.selected = tri(isSelectedNow(s.key));
                }
                return;
            }
        }
    }

    /// True when the row holding `n` is bound only to ease scrolling, past the edges of the view, and holds no
    /// focus or selection. Screen readers skip those rows, which have no place on screen.
    bool offView(Node n)
    {
        foreach (Slot s; active)
        {
            if (n.isInside(s.node))
            {
                return offView(s);
            }
        }
        return false;
    }

    /// True when `s` is outside the view, holding no focus or selection.
    private bool offView(Slot s)
    {
        if (heights is null || isInfinity(viewH) || (selection !is null && selection.peek == s.key))
        {
            return false;
        }
        RowRange shown = heights.visible(top, viewH, 0);
        if (s.index >= shown.first && s.index < shown.last)
        {
            return false;
        }
        Node f = tree is null || tree.services is null ? null : tree.services.focused;
        return f is null || f.isInside(s.node) == false;
    }

    /// Takes new items. Rows rebind at the next layout. Measured heights follow their keys, and the row at the
    /// top of the view stays in place when rows above it change.
    void setItems(T[] next)
    {
        K[] nextKeys = spareKeys;
        nextKeys.length = next.length;
        nextKeys.assumeSafeAppend();
        foreach (size_t i, T item; next)
        {
            nextKeys[i] = keyOf(item);
        }
        if (heights !is null)
        {
            carryHeights(nextKeys);
        }
        items = next;
        spareKeys = itemKeys;
        itemKeys = nextKeys;
        markNeedsLayout();
    }

    /// Moves measured heights from the current keys to `next`. Unless the kept rows were reordered, such as by
    /// sorting, the first one from the top of the view down stays in place. Appended items only add rows.
    private void carryHeights(K[] next)
    {
        if (isNaN(estimate))
        {
            heights = null;
            return;
        }
        if (next.length >= itemKeys.length && next[0 .. itemKeys.length] == itemKeys)
        {
            foreach (size_t i; itemKeys.length .. next.length)
            {
                heights.append(estimate);
            }
            return;
        }
        ptrdiff_t[] from = matchKeys(itemKeys, next);
        float[] h = new float[next.length];
        size_t topRow = heights.indexAt(top);
        ptrdiff_t kept = -1; /// new index of the first kept row from the top of the view down
        ptrdiff_t last = -1; /// old index of the last kept row so far
        bool ordered = true; /// kept rows are in their old order, so only rows were added or removed
        foreach (size_t i, ptrdiff_t o; from)
        {
            h[i] = o < 0 ? estimate : heights.height(o);
            if (o < 0)
            {
                continue;
            }
            ordered = ordered && o > last;
            last = o;
            if (kept < 0 && cast(size_t) o >= topRow)
            {
                kept = i;
            }
        }
        RowHeights old = heights;
        heights = new RowHeights(h);
        if (kept < 0 || ordered == false)
        {
            return;
        }
        double was = old.offsetOf(from[kept]);
        if (was < top + viewH)
        {
            keepAnchor(Anchor(kept, top - was));
        }
    }

    /// Moves the view so `a` is back at its top, owing the move to the scroll view. Nothing outside one.
    private void keepAnchor(Anchor a)
    {
        if (isInfinity(viewH))
        {
            return;
        }
        float y = cast(float) restore(heights, a);
        shift += y - top;
        top = y;
    }

    /// Scroll move owed since the last call, and forgets it.
    float takeShift()
    {
        float s = shift;
        shift = 0;
        return s;
    }

    /// Bound row of key `k`, or null.
    Node opIndex(K k)
    {
        Slot* s = k in byKey;
        return s is null ? null : (*s).node;
    }

    /// Makes the list one Tab stop whose arrow keys move `selected`, and Enter call `onActivate` with the
    /// selected item. With `text` typed letters select the next item whose text starts with them. List items in
    /// rows stop taking focus. The repaint effect belongs to the list.
    void setSelection(Signal!K selected, void delegate(T) onActivate, string delegate(T) text = null)
    {
        selection = selected;
        activated = onActivate;
        textOf = text;
        focusable = true;
        textInput = text !is null;
        runWithOwner(owner, () {
            effect(() {
                selected.get;
                markNeedsPaint();
            });
        });
        foreach (Slot s; active)
        {
            leaveFocus(s.node);
        }
    }

    /// Lets more than one item be selected, with their keys in `keys`. The selection given to `setSelection` stays
    /// the current item, which the keys move and the focus ring shows. Keys of items that leave stay in `keys`.
    void setMultiple(Signal!(K[]) keys)
    {
        multi = keys;
    }

    /// Selected keys when more than one item may be selected, or null.
    Signal!(K[]) selectedKeys()
    {
        return multi;
    }

    /// True if the item of `k` is selected, tracked. Rows read it for their selected look.
    bool isSelected(K k)
    {
        if (multi is null)
        {
            return selection !is null && selection.get == k;
        }
        K[] keys = multi.get;
        if (keys !is lookupFor)
        {
            lookup = null;
            foreach (K key; keys)
            {
                lookup[key] = true;
            }
            lookupFor = keys;
        }
        return (k in lookup) !is null;
    }

    /// Index of the item of `k`, or -1.
    ptrdiff_t indexOf(K k)
    {
        foreach (size_t i, T item; items)
        {
            if (keyOf(item) == k)
            {
                return i;
            }
        }
        return -1;
    }

    /// Index of the selected item, the current one with `setMultiple`, or -1.
    ptrdiff_t selectedIndex()
    {
        return selection is null ? -1 : indexOf(selection.peek);
    }

    /// Makes item `i` current and scrolls it into view. With `setMultiple` the selected keys stay as they are.
    void select(size_t i)
    {
        selection.set(keyOf(items[i]));
        reveal(i);
    }

    /// Selects item `i` as a press with `mods` does, makes it current and scrolls it into view. With
    /// `setMultiple` Ctrl adds or removes the item, Shift selects the items from the anchor to it, Ctrl and Shift
    /// add those, and no modifier selects it alone. Without, it selects the item.
    void choose(size_t i, ubyte mods)
    {
        K k = keyOf(items[i]);
        if (multi is null)
        {
            select(i);
            return;
        }
        bool ctrl = (mods & Mod.ctrl) != 0;
        K[] next;
        if (mods & Mod.shift)
        {
            ptrdiff_t a = anchored ? indexOf(anchor) : -1;
            if (a < 0)
            {
                a = selectedIndex >= 0 ? selectedIndex : i;
                anchor = keyOf(items[a]);
                anchored = true;
            }
            if (ctrl)
            {
                next = multi.peek.dup;
            }
            foreach (size_t j; min(a, i) .. max(a, i) + 1)
            {
                K key = keyOf(items[j]);
                if (ctrl == false || isSelectedNow(key) == false)
                {
                    next ~= key;
                }
            }
        }
        else if (ctrl)
        {
            next = isSelectedNow(k) ? multi.peek.dup.remove!(key => key == k)
                : multi.peek ~ k;
            anchor = k;
            anchored = true;
        }
        else
        {
            next = [k];
            anchor = k;
            anchored = true;
        }
        batch(() {
            multi.set(next);
            selection.set(k);
        });
        reveal(i);
    }

    /// `isSelected` without tracking.
    private bool isSelectedNow(K k)
    {
        return untracked(() => isSelected(k));
    }

    /// Selects every item, with `setMultiple`.
    void selectAll()
    {
        if (multi is null)
        {
            return;
        }
        K[] keys = new K[items.length];
        foreach (size_t i, T item; items)
        {
            keys[i] = keyOf(item);
        }
        multi.set(keys);
    }

    /// A press with `mods` on row `n` or a node inside it, with `setMultiple`. True if taken.
    bool chooseRow(Node n, ubyte mods)
    {
        if (multi is null || selection is null)
        {
            return false;
        }
        foreach (Slot s; active)
        {
            if (n.isInside(s.node))
            {
                press(s.index, mods, n);
                return true;
            }
        }
        return false;
    }

    /// Chooses item `i` as a press with `mods` on `row` does. With `setMultiple`, moves while held select from the
    /// anchor to the item under the pointer, see `dragTo`.
    void press(size_t i, ubyte mods, Node row)
    {
        K[] before = multi is null ? null : multi.peek;
        choose(i, mods);
        if (multi is null)
        {
            return;
        }
        dragRow = row;
        dragAt = i;
        dragMoved = false;
        dragBase = (mods & Mod.ctrl) != 0 ? before : null;
    }

    /// Selects the items from the anchor to the one at window y `y` while a press from `press` is held, added to
    /// the keys from before the press when it had Ctrl. Past the view it goes one item beyond the edge, so the
    /// view scrolls, and again every `ListStyle.dragScroll` while the pointer stays there.
    void dragTo(float y)
    {
        dragY = y;
        selectTo(y);
        scheduleDragScroll();
    }

    /// Steps a drag held past the view one item on, see `dragTo`.
    private void dragScroll()
    {
        if (dragRow !is null)
        {
            selectTo(dragY);
            scheduleDragScroll();
        }
    }

    /// Asks for `dragScroll` while a drag is past the view with items left that way, drops it otherwise.
    private void scheduleDragScroll()
    {
        if (tree is null)
        {
            return;
        }
        float viewTop = bounds.y + top;
        bool up = dragY < viewTop && dragAt > 0;
        bool down = dragY > viewTop + viewH && dragAt + 1 < items.length;
        if (dragRow is null || isInfinity(viewH) || (up == false && down == false))
        {
            tree.cancelCall(this);
            return;
        }
        ListStyle s = tree.style!ListStyle();
        tree.callAt(this, MonoTime.currTime + msecs(cast(long) s.dragScroll), &dragScroll);
    }

    /// Selects from the anchor to the item at window y `y`, see `dragTo`.
    private void selectTo(float y)
    {
        if (dragRow is null || heights is null || items.length == 0)
        {
            return;
        }
        size_t i = heights.indexAt(max(0.0, y - bounds.y));
        if (isInfinity(viewH) == false)
        {
            size_t first = heights.indexAt(top);
            size_t last = heights.indexAt(max(0.0, top + viewH - 0.5));
            i = clamp(i, first > 0 ? first - 1 : 0, min(last + 1, items.length - 1));
        }
        if (i == dragAt)
        {
            return;
        }
        dragAt = i;
        dragMoved = true;
        ptrdiff_t a = anchored ? indexOf(anchor) : -1;
        if (a < 0)
        {
            a = i;
        }
        bool[K] kept;
        foreach (K key; dragBase)
        {
            kept[key] = true;
        }
        K[] next = dragBase.dup;
        foreach (size_t j; min(a, i) .. max(a, i) + 1)
        {
            K key = keyOf(items[j]);
            if ((key in kept) is null)
            {
                next ~= key;
            }
        }
        batch(() {
            multi.set(next);
            selection.set(keyOf(items[i]));
        });
        reveal(i);
    }

    /// Ends a drag from `press`. True if it reached another item.
    bool endDrag()
    {
        bool moved = dragRow !is null && dragMoved;
        dragRow = null;
        dragBase = null;
        if (tree !is null)
        {
            tree.cancelCall(this);
        }
        return moved;
    }

    /// Scrolls the parent scroll view the least distance that shows item `i`.
    void reveal(size_t i)
    {
        ScrollView sv = cast(ScrollView) parent;
        if (sv is null || heights is null || i >= heights.length)
        {
            return;
        }
        sv.reveal(Rect(0, cast(float) heights.offsetOf(i), width, heights.height(i)));
    }

    /// Up and down move the selection a row, page up and page down a view, home and end to the ends. Enter
    /// activates the selected item.
    override bool onKey(ref const KeyEvent e)
    {
        if (selection is null || items.length == 0)
        {
            return false;
        }
        return moveKey(e) || rowKey(e);
    }

    /// Selection keys of `onKey`. With `setMultiple` Shift extends, Ctrl moves the current item alone, Ctrl and
    /// space adds or removes it, and Ctrl and A selects every item. True if handled.
    private bool moveKey(ref const KeyEvent e)
    {
        ubyte mods = e.mods;
        if (mods != 0 && (multi is null || (mods & ~(Mod.ctrl | Mod.shift)) != 0))
        {
            return false;
        }
        ptrdiff_t at = selectedIndex();
        if (mods == Mod.ctrl && (e.key == Key.a || e.key == Key.space))
        {
            if (e.key == Key.a)
            {
                selectAll();
            }
            else if (at >= 0)
            {
                choose(at, Mod.ctrl);
            }
            return true;
        }
        ptrdiff_t last = items.length - 1;
        ptrdiff_t page = 1;
        if (heights !is null && at >= 0 && isInfinity(viewH) == false)
        {
            page = max(1, cast(ptrdiff_t)(viewH / max(1f, heights.height(at))) - 1);
        }
        ptrdiff_t next;
        switch (e.key)
        {
        case Key.enter:
            if (at < 0 || activated is null || mods != 0)
            {
                return false;
            }
            activated(items[at]);
            return true;
        case Key.up:
            next = at < 0 ? 0 : at - 1;
            break;
        case Key.down:
            next = at < 0 ? 0 : at + 1;
            break;
        case Key.pageUp:
            next = at < 0 ? 0 : at - page;
            break;
        case Key.pageDown:
            next = at < 0 ? 0 : at + page;
            break;
        case Key.home:
            next = 0;
            break;
        case Key.end:
            next = last;
            break;
        default:
            return false;
        }
        next = clamp(next, 0, last);
        if (mods == Mod.ctrl)
        {
            select(next);
        }
        else
        {
            choose(next, mods);
        }
        return true;
    }

    /// Typed letters select the next item whose text starts with them. True while a search runs.
    override bool onText(string s)
    {
        if (selection is null || textOf is null || items.length == 0)
        {
            return false;
        }
        ptrdiff_t i = search.type(s, selectedIndex, items.length, (size_t j) => textOf(items[j]), MonoTime.currTime);
        if (i >= 0)
        {
            choose(i, 0);
        }
        return search.typed.length > 0;
    }

    /// Bound row of the selected item, or null.
    private Node selectedRow()
    {
        Slot* s = selection is null ? null : selection.peek in byKey;
        return s is null ? null : (*s).node;
    }

    /// First list item inside `row`, or `row`, where keys for a row start.
    private static Node keyStart(Node row)
    {
        ListItem found = firstItem(row);
        return found is null ? row : found;
    }

    /// First list item in `n` and its descendants, or null.
    private static ListItem firstItem(Node n)
    {
        if (ListItem li = cast(ListItem) n)
        {
            return li;
        }
        foreach (Node c; n.children)
        {
            if (ListItem li = firstItem(c))
            {
                return li;
            }
        }
        return null;
    }

    /// Sends a key the list did not use to the selected row, from its list item up, so shortcuts of a context
    /// menu around the row fire. True if handled.
    private bool rowKey(ref const KeyEvent e)
    {
        Node row = selectedRow();
        for (Node n = row is null ? null : keyStart(row); n !is null && n !is this; n = n.parent)
        {
            if (n.onKey(e))
            {
                return true;
            }
        }
        return false;
    }

    /// The menu key opens the context menu of the selected row, below its top edge.
    override bool onContextMenu(Point p, bool keyboard)
    {
        Node row = keyboard ? selectedRow() : null;
        if (row is null)
        {
            return false;
        }
        Rect b = row.bounds;
        Point at = Point(b.x, b.y + min(b.h, 32f));
        for (Node n = keyStart(row); n !is this; n = n.parent)
        {
            if (n.onContextMenu(at, true))
            {
                return true;
            }
        }
        return false;
    }

    /// Repaints to show or hide the focus ring.
    override void onFocus(bool gained)
    {
        markNeedsPaint();
    }

    /// Rows, then the focus ring around the selected one.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintChildren(ctx, origin);
        if (focusRing == false)
        {
            return;
        }
        if (Slot* s = selection.peek in byKey)
        {
            Node n = (*s).node;
            Rect r = Rect(origin.x + n.offset.x, origin.y + n.offset.y, n.size.w, n.size.h);
            ctx.list.rect(r.inset(1), Color.init, 0, ctx.style!ListStyle().focus, 1);
        }
    }

    /// Stores the view and asks for layout when it shows rows that are not bound.
    void viewport(float top, float height)
    {
        this.top = top;
        viewH = height;
        if (heights is null)
        {
            return;
        }
        RowRange need = heights.visible(top, height, 0);
        if (need.first < bound.first || need.last > bound.last)
        {
            markNeedsLayout();
        }
    }

    /// Binds the rows in view, measures them, and binds again while measuring moved the view.
    protected override Size performLayout(Constraints c)
    {
        float w = isInfinity(c.maxW) ? c.minW : c.maxW;
        Constraints rc = Constraints(w, w, 0, float.infinity);
        bool restyled = styleVersion != tree.styleVersion;
        bool remeasure = heights !is null && (restyled || w != width);
        Anchor a = remeasure ? capture(heights, top) : Anchor.init;
        if (restyled)
        {
            styleVersion = tree.styleVersion;
            estimate = float.nan;
            heights = null;
        }
        if (w != width)
        {
            width = w;
            heights = null;
        }
        if (isNaN(estimate) && items.length > 0)
        {
            bind(RowRange(0, 1));
            estimate = max(1f, active[0].node.layout(rc).h);
        }
        if (heights is null)
        {
            heights = new RowHeights(items.length, isNaN(estimate) ? 1 : estimate);
            if (remeasure)
            {
                keepAnchor(a);
            }
        }
        foreach (int pass; 0 .. 3)
        {
            bind(heights.visible(top, viewH, overscan));
            a = capture(heights, top);
            bool measured;
            foreach (Slot s; active)
            {
                float h = s.node.layout(rc).h;
                if (h != heights.height(s.index))
                {
                    heights.set(s.index, h);
                    measured = true;
                }
            }
            if (measured == false)
            {
                break;
            }
            keepAnchor(a);
        }
        foreach (Slot s; active)
        {
            s.node.offset = Point(0, cast(float) heights.offsetOf(s.index));
        }
        return Size(w, cast(float) heights.total);
    }

    /// Points the slots at the items in `r`: kept keys stay, the rest go to the pool and come back with new items.
    /// The row holding focus, or else the row a drag started on, stays bound outside `r` while its item is listed.
    private void bind(RowRange r)
    {
        foreach (Slot s; active)
        {
            s.keep = false;
        }
        foreach (size_t i; r.first .. r.last)
        {
            if (Slot* s = keyOf(items[i]) in byKey)
            {
                (*s).keep = true;
            }
        }
        Node focus = tree is null || tree.services is null ? null : tree.services.focused;
        Slot pin = heldOutside(focus, r);
        if (pin is null)
        {
            pin = heldOutside(dragRow, r);
        }
        if (pin !is null)
        {
            pin.keep = true;
        }
        foreach (Slot s; active)
        {
            if (s.keep == false)
            {
                byKey.remove(s.key);
                pool ~= s;
                if (focus !is null && focus.isInside(s.node))
                {
                    tree.services.setFocus(null);
                }
                if (dragRow !is null && dragRow.isInside(s.node))
                {
                    dragRow = null;
                }
            }
        }
        scratch.length = 0;
        scratch.assumeSafeAppend();
        /// Binds item `i` to its kept slot or a pooled one, next in `scratch`.
        void put(size_t i)
        {
            T item = items[i];
            K k = keyOf(item);
            Slot s;
            if (Slot* found = k in byKey)
            {
                s = *found;
                assert(s.keep, "duplicate key in a virtual list");
                s.keep = false;
                s.item.set(item);
            }
            else
            {
                s = take(item);
                s.key = k;
                byKey[k] = s;
            }
            s.index = i;
            scratch ~= s;
        }

        batch(() {
            if (pin !is null && pin.index < r.first)
            {
                put(pin.index);
            }
            foreach (size_t i; r.first .. r.last)
            {
                put(i);
            }
            if (pin !is null && pin.index >= r.last)
            {
                put(pin.index);
            }
        });
        bool same = scratch.length == active.length;
        for (size_t i; same && i < scratch.length; ++i)
        {
            same = scratch[i] is active[i];
        }
        swap(active, scratch);
        bound = r;
        if (same == false)
        {
            Node[] kids = new Node[active.length];
            foreach (size_t i, Slot s; active)
            {
                kids[i] = s.node;
            }
            setChildren(kids);
        }
    }

    /// Bound slot holding `n` when its item is still listed outside `r`, with its index updated, or null.
    private Slot heldOutside(Node n, RowRange r)
    {
        if (n is null)
        {
            return null;
        }
        foreach (Slot s; active)
        {
            if (n.isInside(s.node) == false)
            {
                continue;
            }
            bool still = s.index < items.length && keyOf(items[s.index]) == s.key;
            ptrdiff_t i = still ? s.index : indexOf(s.key);
            if (i < 0 || (i >= r.first && i < r.last))
            {
                return null;
            }
            s.index = i;
            return s;
        }
        return null;
    }

    /// A pooled slot showing `item`, or a new one. Pooled rows lay out from scratch, they may have missed a restyle.
    private Slot take(T item)
    {
        if (pool.length > 0)
        {
            Slot s = pool[$ - 1];
            pool.length -= 1;
            pool.assumeSafeAppend();
            s.item.set(item);
            s.node.markSubtreeNeedsLayout();
            ++rebound;
            return s;
        }
        Slot s = new Slot;
        s.item = signal(item);
        T delegate() get = &s.item.get;
        runWithOwner(owner, () {
            Scope rowScope = effectScope(() { s.node = make(get); });
            s.node.owner = rowScope;
            s.node.repaintBoundary = true;
        });
        if (selection !is null)
        {
            leaveFocus(s.node);
        }
        ++built;
        return s;
    }

    /// Stops the list items in `n` from taking focus, so a press focuses the list.
    private static void leaveFocus(Node n)
    {
        if (cast(ListItem) n)
        {
            n.focusable = false;
        }
        foreach (Node c; n.children)
        {
            leaveFocus(c);
        }
    }
}

/// Parent of rows that selects them on a press, such as a virtual list where more than one item may be selected.
interface RowChooser
{
    /// Handles a press with `mods` on the row holding `n`. True if taken.
    bool chooseRow(Node n, ubyte mods);
    /// Fills the place and selection of the row holding `n`.
    void describeRow(Node n, ref AccessInfo a);
    /// True when the row holding `n` is bound only past the edges of the view.
    bool offView(Node n);
    /// The pointer moved to window y `y` while the press `chooseRow` took is held.
    void dragTo(float y);
    /// The press `chooseRow` took was released. True if the drag reached another row.
    bool endDrag();
}

/// Virtual list of `items` keyed by `key`, for `scroll()(list)`. `row` builds a row around a getter
/// of its item and must read the getter inside effects, as pooled rows change items. With `selected` the list
/// is one Tab stop and arrows move the selection, and with `text` typing selects, see `VirtualList.setSelection`.
/// With `multi` too, more than one item may be selected, see `VirtualList.setMultiple`. Rows show the selected
/// look of `list.isSelected(key)`. The list scope belongs to the current owner and is disposed with the list.
VirtualList!(K, T) virtualList(K, T, R : Node)(T[] delegate() items, K delegate(T) key, R delegate(T delegate()) row,
    Signal!K selected = null, void delegate(T) onActivate = null, string delegate(T) text = null,
    Signal!(K[]) multi = null)
{
    VirtualList!(K, T) list = new VirtualList!(K, T)(key, asNodeMaker(row));
    list.owner = effectScope(() {
        effect(() { list.setItems(items()); });
    });
    if (selected !is null)
    {
        list.setSelection(selected, onActivate, text);
        if (multi !is null)
        {
            list.setMultiple(multi);
        }
    }
    return list;
}

/// Look of list rows.
struct ListStyle
{
    enum section = "list"; /// section name in theme files

    Color rowHover = Color(0xff, 0xff, 0xff, 0x0c);    /// background of the row under the pointer
    Color rowSelected = Color(0x3a, 0x7b, 0xe8, 0x40); /// background of the selected row
    Color selectedBar = Color(0x4c, 0x8d, 0xf6, 0xff); /// bar at the left of the selected row
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff);       /// focus ring, inside the row
    float padX = 8; /// row padding left and right
    float padY = 3; /// row padding top and bottom
    float dragScroll = 50; /// milliseconds per row while a drag selection is held past the view
}

/// Sibling rows the last typed search ran in.
private Node searchedIn;

/// Letters typed into the rows of `searchedIn`.
private TypeAhead siblingSearch;

/// Clickable row around one child, with hover and selection backgrounds. It takes focus on press, so keys
/// after a click reach the row and its parents, such as a context menu's shortcuts. Sibling rows form one Tab
/// stop, at the selected row, and arrows click the row above or below. Typing goes to the next row whose first
/// label starts with the typed letters. Rows of a virtual list with a selection leave focus and keys to the list.
final class ListItem : Node
{
    void delegate() onClick; /// click handler, usually selects
    bool selected;           /// drawn as selected
    bool enabled = true;     /// accepts clicks
    string variant;          /// ListStyle variant for padding and backgrounds
    private RowChooser holder; /// parent list the held press selected through, or null
    private ubyte chooseMods; /// modifiers of that press

    mixin PressBehavior press;

    /// Wraps `child`, styled as ListStyle `variant`.
    this(Node child, void delegate() onClick, string variant = null)
    {
        this.onClick = onClick;
        this.variant = variant;
        add(child);
        interactive = true;
        focusable = true;
        textInput = true;
    }

    /// Runs the handler.
    void activate()
    {
        if (onClick !is null)
        {
            onClick();
        }
    }

    /// A press selects through a list where more than one item may be selected, and a drag selects a range.
    /// Presses with Ctrl or Shift and drags go to that list alone, plain clicks also run the handler.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.down:
            RowChooser c = e.button == 1 && enabled ? chooser() : null;
            holder = c !is null && c.chooseRow(this, e.mods) ? c : null;
            chooseMods = e.mods;
            break;
        case PointerKind.move:
            if (holder !is null)
            {
                holder.dragTo(e.pos.y);
            }
            break;
        case PointerKind.cancel:
            if (holder !is null)
            {
                holder.endDrag();
                holder = null;
            }
            break;
        case PointerKind.up:
            if (holder !is null)
            {
                RowChooser c = holder;
                holder = null;
                if (c.endDrag() || (chooseMods & (Mod.ctrl | Mod.shift)) != 0)
                {
                    markNeedsPaint();
                    return true;
                }
            }
            break;
        default:
            break;
        }
        return press.onPointer(e);
    }

    /// Option named by its content, with its place in the list.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.listBoxOption;
        a.label = contentText(this);
        a.leaf = textOnly(this);
        a.selected = tri(selected);
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
        if (RowChooser c = chooser())
        {
            c.describeRow(this, a);
            return;
        }
        ListItem[] rows = siblings();
        foreach (size_t i, ListItem r; rows)
        {
            if (r is this)
            {
                a.position = cast(uint) i + 1;
            }
        }
        a.setSize = cast(uint) rows.length;
    }

    /// Click selects through the list holding the row, then runs the handler.
    override bool accessAction(ref const AccessRequest r)
    {
        if (r.action != AccessAction.click || enabled == false)
        {
            return false;
        }
        RowChooser c = chooser();
        if (c !is null)
        {
            c.chooseRow(this, 0);
            c.endDrag();
        }
        activate();
        return true;
    }

    /// Nearest parent selecting rows, or null.
    private RowChooser chooser()
    {
        for (Node n = parent; n !is null; n = n.parent)
        {
            if (RowChooser c = cast(RowChooser) n)
            {
                return c;
            }
        }
        return null;
    }

    /// Selects or deselects.
    void setSelected(bool on)
    {
        if (on != selected)
        {
            selected = on;
            markNeedsPaint();
        }
    }

    /// Rows next to this one, in sibling order.
    ListItem[] siblings()
    {
        if (parent is null)
        {
            return [this];
        }
        ListItem[] rows;
        foreach (Node c; parent.children)
        {
            if (ListItem r = cast(ListItem) c)
            {
                rows ~= r;
            }
        }
        return rows;
    }

    /// The selected row, or the first when none of the siblings is selected.
    override bool tabStop()
    {
        if (focusable == false)
        {
            return false;
        }
        if (selected)
        {
            return true;
        }
        ListItem[] rows = siblings();
        foreach (ListItem r; rows)
        {
            if (r.selected && r.focusable)
            {
                return false;
            }
        }
        return rows[0] is this;
    }

    /// Up and down click and focus the nearest enabled row above or below, home and end the first and last.
    /// Enter and space click this row.
    override bool onKey(ref const KeyEvent e)
    {
        if (enabled == false || e.mods != 0)
        {
            return false;
        }
        ListItem[] rows = siblings();
        ptrdiff_t at;
        foreach (size_t i, ListItem r; rows)
        {
            if (r is this)
            {
                at = i;
            }
        }
        ptrdiff_t from;
        ptrdiff_t dir;
        switch (e.key)
        {
        case Key.enter:
        case Key.space:
            activate();
            return true;
        case Key.up:
            from = at - 1;
            dir = -1;
            break;
        case Key.down:
            from = at + 1;
            dir = 1;
            break;
        case Key.home:
            from = 0;
            dir = 1;
            break;
        case Key.end:
            from = rows.length - 1;
            dir = -1;
            break;
        default:
            return false;
        }
        for (ptrdiff_t i = from; i >= 0 && i < rows.length; i += dir)
        {
            if (rows[i].enabled && rows[i].focusable)
            {
                rows[i].go();
                break;
            }
        }
        return true;
    }

    /// Clicks and focuses this row.
    private void go()
    {
        activate();
        if (tree !is null && tree.services !is null)
        {
            tree.services.setFocus(this);
        }
    }

    /// Text of the first label inside, or null.
    string text()
    {
        Label l = firstLabel(this);
        return l is null ? null : l.text;
    }

    /// First label in `n` and its descendants, or null.
    private static Label firstLabel(Node n)
    {
        if (Label l = cast(Label) n)
        {
            return l;
        }
        foreach (Node c; n.children)
        {
            if (Label l = firstLabel(c))
            {
                return l;
            }
        }
        return null;
    }

    /// Typed letters click and focus the next enabled sibling whose first label starts with them. True while a
    /// search runs.
    override bool onText(string s)
    {
        if (enabled == false || parent is null)
        {
            return false;
        }
        if (searchedIn !is parent)
        {
            searchedIn = parent;
            siblingSearch = TypeAhead.init;
        }
        ListItem[] rows = siblings();
        ptrdiff_t at = -1;
        foreach (size_t i, ListItem r; rows)
        {
            if (r is this)
            {
                at = i;
            }
        }
        string textOf(size_t i)
        {
            return rows[i].enabled && rows[i].focusable ? rows[i].text : null;
        }

        ptrdiff_t i = siblingSearch.type(s, at, rows.length, &textOf, MonoTime.currTime);
        if (i >= 0)
        {
            rows[i].go();
        }
        return siblingSearch.typed.length > 0;
    }

    /// Child inside the style's padding.
    protected override Size performLayout(Constraints c)
    {
        ListStyle s = tree.style!ListStyle(variant);
        Insets i = Insets.xy(s.padX, s.padY);
        Size cs = children[0].layout(c.deflate(i));
        children[0].offset = Point(i.left, i.top);
        return Size(cs.w + s.padX * 2, cs.h + s.padY * 2);
    }

    /// Background for the state, the child, then the focus ring.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ListStyle s = ctx.style!ListStyle(variant);
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (selected)
        {
            ctx.list.rect(r, s.rowSelected);
            ctx.list.rect(Rect(r.x, r.y, 2, r.h), s.selectedBar);
        }
        else if (hoverInside)
        {
            ctx.list.rect(r, s.rowHover);
        }
        paintChildren(ctx, origin);
        if (focusRing)
        {
            ctx.list.rect(r.inset(1), Color.init, 0, s.focus, 1);
        }
    }
}

/// Row around `child`: `listItem(onClick: () { sel.set(id); }, selected: () => sel.get == id)(child)`.
struct ListItemSpec
{
    void delegate() onClick;    /// click handler
    bool delegate() selected;   /// true when the row is selected, may read signals, or null
    string variant;             /// ListStyle variant

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(void delegate() onClick, bool delegate() selected, string variant)
    {
        this.onClick = onClick;
        this.selected = selected;
        this.variant = variant;
    }

    /// The row around `child`. The selection effect belongs to the current owner.
    ListItem opCall(Node child)
    {
        ListItem item = new ListItem(child, onClick, variant);
        if (selected !is null)
        {
            bool delegate() sel = selected;
            effect(() { item.setSelected(sel()); });
        }
        return item;
    }
}

/// Clickable list row options, `variant` naming a `[list.variant]` theme section.
ListItemSpec listItem(void delegate() onClick = null, bool delegate() selected = null, string variant = null)
{
    return ListItemSpec(onClick, selected, variant);
}

// A row stays hovered while the pointer is over a button inside it, and a theme variant changes its padding.
unittest
{
    import dentrite.host : Host;
    import dentrite.theme : Theme;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(200, 100);
    scope (exit)
    {
        h.close();
    }
    h.tree.theme = new Theme("[list.dense]\npadY = 0\n", "t.theme");
    Button go = button("Go");
    ListItem item = listItem()(go);
    ListItem dense = listItem(variant: "dense")(new Fixed(Size(10, 10)));
    Node col = column()(item, dense);
    h.setRoot(col);
    h.frame();
    assert(dense.size.h == 10 && item.size.h == go.size.h + 6, "the variant drops the padding");

    /// Middle of `n`.
    Point mid(Node n)
    {
        return Point(n.bounds.x + n.bounds.w / 2, n.bounds.y + n.bounds.h / 2);
    }

    h.inject(PointerKind.move, mid(go));
    assert(go.hovered && item.hovered == false && item.hoverInside, "hovered through its button");
    h.inject(PointerKind.move, Point(item.bounds.x + 1, item.bounds.y + 1));
    assert(item.hovered && item.hoverInside && go.hoverInside == false);
    h.inject(PointerKind.move, mid(go));
    h.inject(PointerKind.move, mid(dense));
    assert(item.hoverInside == false && go.hoverInside == false && dense.hoverInside && col.hoverInside);
    col.removeChild(dense);
    h.frame();
    assert(col.hoverInside == false && dense.hoverInside == false, "leaving the tree clears the parents");
}

// Filtering keeps surviving row nodes, disposes the rest with their effects, and rebuilds on return.
unittest
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    Signal!(int[]) items = signal([1, 2, 3, 4]);
    Signal!int cutoff = signal(0);
    int[] rowRuns = new int[5];

    /// Row node for `i`, with an effect counting runs.
    Node row(int i)
    {
        Fixed f = new Fixed(Size(10, 10));
        effect(() {
            cutoff.get;
            ++rowRuns[i];
        });
        return f;
    }

    KeyedColumn!(int, int) list;
    Scope root = effectScope(() {
        list = keyedColumn((() => items.get.filter!(i => i > cutoff.get).array), (int i) => i, &row);
    });
    Node two = list[2];
    assert(list.children.length == 4 && list.created == 4);
    cutoff.set(2);
    assert(list.children.length == 2 && list.disposed == 2);
    assert(list[2] is null && two.parent is null);
    assert(rowRuns[2] == 1 && rowRuns[3] == 2, "removed rows stopped, kept rows re-ran");
    Node three = list[3];
    cutoff.set(0);
    assert(list[3] is three && list.created == 6);
    root.dispose();
    cutoff.set(1);
    assert(rowRuns[3] == 3, "nothing runs after the owner is disposed");
}

version (unittest)
{
    /// 10 px row whose effect counts runs into `runs` and whose height follows `tall` of its item.
    private Node probeRow(int delegate() item, int* runs, bool delegate(int) tall)
    {
        Fixed f = new Fixed(Size(10, 10));
        effect(() {
            f.want = Size(10, tall(item()) ? 30 : 10);
            f.markNeedsLayout();
            ++*runs;
        });
        return f;
    }

    /// List of `items` with probe rows in a scroll view of `viewport`.
    private VirtualList!(int, int) probeList(Signal!(int[]) items, Size viewport, int* runs,
        bool delegate(int) tall, out ScrollView sv, out Tree t)
    {
        VirtualList!(int, int) list = virtualList!(int, int)(&items.get, (int i) => i,
            (int delegate() item) => probeRow(item, runs, tall));
        sv = scroll()(list);
        t = bareTree(sv, viewport);
        t.flush();
        return list;
    }
}

// 10 000 rows in a 100 px view build 15. Scrolling rebinds pooled rows, small scrolls stay inside the
// overscan, and removing a key rebinds one row while the others keep their nodes.
unittest
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.range : iota;

    Signal!(int[]) items = signal(iota(10_000).array);
    int runs;
    ScrollView sv;
    Tree t;
    VirtualList!(int, int) list;
    Scope root = effectScope(() {
        list = probeList(items, Size(50, 100), &runs, (int i) => false, sv, t);
    });
    assert(list.size.h == 100_000);
    assert(list.children.length == 15 && list.built == 15 && runs == 15, "rows 0 to 10 plus 4 below");
    assert(sv.hitTest(Point(5, 25), Point(0, 0)) is list[2]);

    sv.scrollTo(5000);
    t.flush();
    assert(list.children.length == 19 && list.built == 19 && list.rebound == 15, "rows 496 to 514");
    assert(list[500] !is null && list[500].bounds.y == 0 && list[2] is null);
    int layouts = list.layoutRuns;
    sv.scrollTo(5030);
    t.flush();
    assert(list.layoutRuns == layouts, "still inside the overscan");
    assert(sv.hitTest(Point(5, 5), Point(0, 0)) is list[503]);

    sv.scrollTo(0);
    t.flush();
    Node zero = list[0];
    int before = runs;
    items.set(items.peek.filter!(i => i != 3).array);
    t.flush();
    assert(list[0] is zero && list[3] is null && list[15] !is null);
    assert(runs == before + 1, "only the row that took key 15 ran");
    assert(list.built == 19);

    root.dispose();
    items.set([1, 2]);
    assert(runs == before + 1, "nothing runs after the owner is disposed");
}

// Rows taller than the first one are measured as they come into view.
unittest
{
    import std.array : array;
    import std.range : iota;

    Signal!(int[]) items = signal(iota(100).array);
    int runs;
    ScrollView sv;
    Tree t;
    VirtualList!(int, int) list;
    effectScope(() {
        list = probeList(items, Size(50, 100), &runs, (int i) => i % 2 == 1, sv, t);
    });
    assert(list[1].bounds.y == 10 && list[2].bounds.y == 40 && list[3].bounds.y == 50);
    assert(list.size.h == 8 * 10 + 7 * 30 + 85 * 10, "rows 0 to 14 measured, the rest estimated at 10");
    assert(list.children.length == 10, "rows 0 to 5 fill the view, plus 4 below");
}

// Measuring taller rows above the view keeps the row at its top in place.
unittest
{
    import std.array : array;
    import std.range : iota;

    Signal!(int[]) items = signal(iota(100).array);
    int runs;
    ScrollView sv;
    Tree t;
    VirtualList!(int, int) list;
    effectScope(() {
        list = probeList(items, Size(50, 100), &runs, (int i) => i % 2 == 1, sv, t);
    });
    sv.scrollTo(600);
    t.flush();
    assert(list[46] !is null && list[46].bounds.y == 0, "row 46 was at 600 before rows 43 and 45 grew");
    assert(sv.scrollY == 640);
}

// Item changes keep measured heights. Rows added or trimmed above the view leave its top row in place. Sorting
// does not move the view to follow it.
unittest
{
    import std.array : array;
    import std.range : iota, retro;

    Signal!(int[]) items = signal(iota(100).array);
    int runs;
    ScrollView sv;
    Tree t;
    VirtualList!(int, int) list;
    effectScope(() {
        list = probeList(items, Size(50, 100), &runs, (int i) => i % 2 == 1, sv, t);
    });
    sv.scrollTo(100);
    t.flush();
    Node five = list[5];
    assert(five.bounds.y == -10, "row 5 spans 90 to 120");
    float total = list.size.h;

    items.set(items.peek ~ [100, 101]);
    t.flush();
    assert(list.size.h == total + 20 && sv.scrollY == 100 && list[5] is five);

    items.set(iota(-20, 0).array ~ items.peek);
    t.flush();
    assert(list.size.h == total + 220, "rows 0 to 14 keep their measured heights");
    assert(sv.scrollY == 300 && list[5] is five && five.bounds.y == -10);

    items.set(items.peek[25 .. $]);
    t.flush();
    assert(sv.scrollY == 10 && five.bounds.y == -10, "rows -20 to 4 took 290 px above");

    items.set(items.peek.retro.array);
    t.flush();
    assert(list[5] is null && sv.scrollY < 100, "sorting does not follow row 5 down");
}

// Following the end wins over keeping the top row.
unittest
{
    import std.array : array;
    import std.range : iota;

    Signal!(int[]) items = signal(iota(50).array);
    int runs;
    VirtualList!(int, int) list = virtualList!(int, int)(&items.get, (int i) => i,
        (int delegate() item) => probeRow(item, &runs, (int i) => false));
    ScrollView sv = scroll(follow: true)(list);
    Tree t = bareTree(sv, Size(50, 100));
    t.flush();
    assert(sv.scrollY == 400);
    items.set(iota(-10, 0).array ~ items.peek);
    t.flush();
    assert(sv.scrollY == 500);
    items.set(items.peek[20 .. $] ~ [50]);
    t.flush();
    assert(sv.scrollY == 310);
}

// Following the top shows rows added above while scrolled to the top, and keeps the top row once scrolled away.
unittest
{
    import std.array : array;
    import std.range : iota;

    Signal!(int[]) items = signal(iota(50).array);
    int runs;
    VirtualList!(int, int) list = virtualList!(int, int)(&items.get, (int i) => i,
        (int delegate() item) => probeRow(item, &runs, (int i) => false));
    ScrollView sv = scroll(followTop: true)(list);
    Tree t = bareTree(sv, Size(50, 100));
    t.flush();
    items.set(iota(-10, 0).array ~ items.peek);
    t.flush();
    assert(sv.scrollY == 0 && list[-10] !is null && list[-10].bounds.y == 0);
    sv.scrollTo(50);
    t.flush();
    items.set(iota(-15, -10).array ~ items.peek);
    t.flush();
    assert(sv.scrollY == 100, "row -5 stays at the top of the view");
    items.set(iota(5).array);
    t.flush();
    items.set(iota(-20, 0).array ~ items.peek);
    t.flush();
    assert(sv.scrollY == 0, "shrinking to fit moved the view to the top, so it follows the top again");
}

// Sibling rows are one Tab stop at the selected row, and arrows click the next enabled row without wrapping.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(300, 300);
    scope (exit)
    {
        h.close();
    }
    Signal!int sel = signal(-1);
    /// Row selecting `i` on click.
    ListItem item(int i)
    {
        return listItem(onClick: () { sel.set(i); }, selected: () => sel.get == i)(new Fixed(Size(50, 20)));
    }

    ListItem[] rows = [item(0), item(1), item(2), item(3)];
    rows[2].enabled = false;
    Button before = button("Before");
    h.setRoot(column()(before, column()(cast(Node[]) rows)));
    h.frame();
    assert(rows[0].tabStop && rows[1].tabStop == false, "nothing selected, the first row is the stop");
    h.setFocus(before);
    h.injectKey(Key.tab, 0);
    assert(h.focused is rows[0]);
    h.injectKey(Key.down, 0);
    assert(sel.peek == 1 && h.focused is rows[1]);
    h.injectKey(Key.down, 0);
    assert(sel.peek == 3 && h.focused is rows[3], "skips the disabled row");
    h.injectKey(Key.down, 0);
    assert(sel.peek == 3, "no wrap at the end");
    h.injectKey(Key.home, 0);
    assert(sel.peek == 0 && h.focused is rows[0]);
    clickOn(h, rows[3]);
    h.setFocus(before);
    h.injectKey(Key.tab, 0);
    assert(h.focused is rows[3], "Tab lands on the selected row");
    h.injectKey(Key.tab, 0);
    assert(h.focused is before, "and leaves the rows with the next Tab");
}

// A virtual list with a selection takes focus for its rows, moves the selection with keys, scrolls it into
// view and activates it with Enter.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.menu : clickOn, menuHost;
    import std.array : array;
    import std.range : iota;

    Host h = menuHost(200, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!int sel = signal(-1);
    int opened = -1;
    int[] items = iota(1000).array;
    /// Row selecting its item on click.
    Node row(int delegate() it)
    {
        return listItem(onClick: () { sel.set(it()); }, selected: () => sel.get == it())(new Fixed(Size(10, 4)));
    }

    VirtualList!(int, int) list = virtualList!(int, int)(() => items, (int i) => i, &row, sel,
        (int i) { opened = i; });
    ScrollView sv = scroll()(list);
    h.setRoot(sv);
    h.frame();
    ListItem r3 = cast(ListItem) list[3];
    assert(r3.focusable == false && list.focusable);
    clickOn(h, r3);
    assert(sel.peek == 3 && h.focused is list, "the press focuses the list");
    h.injectKey(Key.down, 0);
    h.frame();
    assert(sel.peek == 4 && list.selectedIndex == 4);
    h.injectKey(Key.pageDown, 0);
    h.frame();
    assert(sel.peek == 13 && sv.scrollY == 40, "10 rows of 10 px less one, scrolled to show row 13");
    h.injectKey(Key.end, 0);
    h.frame();
    assert(sel.peek == 999 && sv.scrollY == 9900 && list[999] !is null);
    h.injectKey(Key.enter, 0);
    assert(opened == 999);
    h.injectKey(Key.home, 0);
    h.frame();
    assert(sel.peek == 0 && sv.scrollY == 0);
    assert(cast(ListItem) list[0] !is null && list[0].focusable == false, "pooled rows stay out of focus");
}

// One letter steps through rows starting with it, more letters narrow the search, and a pause starts over.
unittest
{
    import core.time : msecs;

    string[] fruit = ["Apple", "Banana", "Blueberry", "blackberry", "Cherry"];
    TypeAhead t;
    MonoTime now = MonoTime.currTime;
    ptrdiff_t at = 0;
    /// Types `s` 100 ms after the last letter, or `wait` later, and moves `at` to the match.
    ptrdiff_t type(string s, Duration wait = 100.msecs)
    {
        now += wait;
        ptrdiff_t i = t.type(s, at, fruit.length, (size_t j) => fruit[j], now);
        if (i >= 0)
        {
            at = i;
        }
        return i;
    }

    assert(type("b") == 1 && type("b") == 2 && type("B") == 3 && type("b") == 1, "the same letter cycles");
    assert(type("b", 2.seconds) == 2, "a pause starts over at the next row");
    assert(type("l") == 2, "more letters keep a row that still matches");
    assert(type("a") == 3, "and move on when it no longer does");
    assert(type("ch", 2.seconds) == 4, "pasted text searches at once");
    assert(type("z", 2.seconds) == -1 && at == 4 && t.typed == "z");
    assert(type(" ", 2.seconds) == -1 && t.typed.length == 0, "a space alone is no search");
}

// Typing in sibling rows selects by the first label, and in a virtual list by the item text.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 300);
    scope (exit)
    {
        h.close();
    }
    string[] names = ["Text", "Tabs", "Tables", "Trees"];
    Signal!int sel = signal(0);
    /// Row selecting `i` on click.
    ListItem item(int i)
    {
        return listItem(onClick: () { sel.set(i); }, selected: () => sel.get == i)(label(names[i]));
    }

    ListItem[] rows = [item(0), item(1), item(2), item(3)];
    Signal!string picked = signal("");
    string[] words = ["delta", "alpha", "charlie", "bravo"];
    VirtualList!(string, string) list = virtualList!(string, string)(() => words, (string s) => s,
        (string delegate() it) => new Fixed(Size(10, 10)), picked, null, (string s) => s);
    h.setRoot(column()(column()(cast(Node[]) rows), sized(h: 100)(scroll()(list))));
    h.frame();
    h.setFocus(rows[0]);
    h.injectText("tr");
    assert(sel.peek == 3 && h.focused is rows[3]);
    assert(list.textInput && rows[0].textInput);
    h.setFocus(list);
    h.injectText("c");
    assert(picked.peek == "charlie");
    h.injectText("x");
    assert(picked.peek == "charlie", "no match keeps the selection");
}

// With `multi` Ctrl and Shift clicks and keys pick sets of rows, and plain clicks still run the row handler.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.menu : clickOn, menuHost;
    import std.array : array;
    import std.range : iota;

    Host h = menuHost(200, 400);
    scope (exit)
    {
        h.close();
    }
    Signal!int sel = signal(-1);
    Signal!(int[]) picked = signal(cast(int[]) null);
    int clicked;
    int[] items = iota(20).array;
    VirtualList!(int, int) list;
    /// Row counting plain clicks, drawn selected while its item is picked.
    Node row(int delegate() it)
    {
        return listItem(onClick: () { ++clicked; }, selected: () => list.isSelected(it()))(new Fixed(Size(10, 10)));
    }

    list = virtualList!(int, int)(() => items, (int i) => i, &row, sel, multi: picked);
    h.setRoot(scroll()(list));
    h.frame();
    clickOn(h, list[2]);
    assert(picked.peek == [2] && sel.peek == 2 && clicked == 1 && h.focused is list);
    clickOn(h, list[5], 1, Mod.shift);
    assert(picked.peek == [2, 3, 4, 5] && sel.peek == 5 && clicked == 1, "Shift picks from the anchor");
    clickOn(h, list[3], 1, Mod.ctrl);
    assert(picked.peek == [2, 4, 5] && sel.peek == 3, "Ctrl removes a picked row");
    assert((cast(ListItem) list[4]).selected && (cast(ListItem) list[3]).selected == false);
    clickOn(h, list[7], 1, Mod.ctrl | Mod.shift);
    assert(picked.peek == [2, 4, 5, 3, 6, 7], "Ctrl and Shift add the range from the last Ctrl click");

    h.injectKey(Key.down, Mod.shift);
    assert(picked.peek == [3, 4, 5, 6, 7, 8] && sel.peek == 8, "Shift and an arrow pick from the anchor");
    h.injectKey(Key.down, Mod.ctrl);
    assert(sel.peek == 9 && picked.peek.length == 6, "Ctrl and an arrow move the current row alone");
    h.injectKey(Key.space, Mod.ctrl);
    assert(picked.peek == [3, 4, 5, 6, 7, 8, 9]);
    h.injectKey(Key.up, 0);
    assert(picked.peek == [8] && sel.peek == 8, "a plain arrow picks one row");
    h.injectKey(Key.a, Mod.ctrl);
    assert(picked.peek.length == 20);
}

// With `multi` a drag picks the rows from the pressed one to the one under the pointer, past the view one row a
// move so the view scrolls, and keeps the pressed row bound and holding the press.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.menu : menuHost;
    import std.array : array;
    import std.range : iota;

    Host h = menuHost(200, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!int sel = signal(-1);
    Signal!(int[]) picked = signal(cast(int[]) null);
    int clicked;
    int[] items = iota(100).array;
    VirtualList!(int, int) list;
    /// Row counting plain clicks.
    Node row(int delegate() it)
    {
        return listItem(onClick: () { ++clicked; }, selected: () => list.isSelected(it()))(new Fixed(Size(10, 10)));
    }

    list = virtualList!(int, int)(() => items, (int i) => i, &row, sel, multi: picked);
    ScrollView sv = scroll()(list);
    h.setRoot(sv);
    h.frame();
    /// Pointer at the middle of view row `i`.
    Point at(float i)
    {
        return Point(50, i * 16 + 8);
    }

    h.inject(PointerKind.move, at(2));
    h.inject(PointerKind.down, at(2));
    assert(picked.peek == [2], "the press picks its row");
    h.inject(PointerKind.move, at(5));
    assert(picked.peek == [2, 3, 4, 5] && sel.peek == 5);
    h.inject(PointerKind.move, at(3));
    assert(picked.peek == [2, 3], "moving back drops rows");
    h.inject(PointerKind.up, at(3));
    assert(clicked == 0, "a drag is no click");
    h.frame();

    h.inject(PointerKind.move, at(5));
    h.inject(PointerKind.down, at(5), 1, 1, Mod.ctrl);
    h.inject(PointerKind.move, at(4));
    h.inject(PointerKind.up, at(4), 1, 1, Mod.ctrl);
    assert(picked.peek == [2, 3, 4, 5], "Ctrl adds the dragged rows");
    h.frame();

    h.inject(PointerKind.move, at(0));
    h.inject(PointerKind.down, at(0));
    foreach (int i; 0 .. 15)
    {
        h.inject(PointerKind.move, at(30));
        h.frame();
    }
    assert(picked.peek == iota(22).array && sv.scrollY == 22 * 16 - 100, "each move past the view goes one row on");
    assert(list[0] !is null, "the pressed row stays bound");
    h.inject(PointerKind.move, at(-30));
    h.frame();
    assert(sel.peek == 14 && picked.peek == iota(15).array && sv.scrollY == 14 * 16);
    h.inject(PointerKind.up, at(-30));
    assert(clicked == 0);
}

// A drag held past the view keeps scrolling a row each `dragScroll` without moves, back inside it stops, and it
// stops at the end of the items or on release.
unittest
{
    import dentrite.host : Host;
    import dentrite.theme : Theme;
    import dentrite.widgets.menu : menuHost;
    import std.array : array;
    import std.range : iota;

    Host h = menuHost(200, 100);
    scope (exit)
    {
        h.close();
    }
    h.tree.theme = new Theme("[list]\ndragScroll = 0\n", "test");
    Signal!int sel = signal(-1);
    Signal!(int[]) picked = signal(cast(int[]) null);
    int[] items = iota(10).array;
    VirtualList!(int, int) list;
    /// Plain row.
    Node row(int delegate() it)
    {
        return listItem(selected: () => list.isSelected(it()))(new Fixed(Size(10, 10)));
    }

    list = virtualList!(int, int)(() => items, (int i) => i, &row, sel, multi: picked);
    ScrollView sv = scroll()(list);
    h.setRoot(sv);
    h.frame();
    /// Pointer at the middle of view row `i`.
    Point at(float i)
    {
        return Point(50, i * 16 + 8);
    }

    h.inject(PointerKind.move, at(1));
    h.inject(PointerKind.down, at(1));
    h.inject(PointerKind.move, at(8));
    assert(sel.peek == 7, "the move goes one row past the view");
    h.frame();
    assert(sel.peek == 8, "held still, a row a frame");
    h.frame();
    assert(sel.peek == 9 && picked.peek == iota(1, 10).array);
    h.frame();
    assert(sel.peek == 9 && sv.scrollY == 10 * 16 - 100 && h.tree.hasCall(list) == false,
        "no further than the last item");

    h.inject(PointerKind.move, at(3));
    h.frame();
    int inside = sel.peek;
    h.frame();
    h.frame();
    assert(sel.peek == inside && h.tree.hasCall(list) == false, "back inside the view it stops");

    h.inject(PointerKind.move, at(-2));
    foreach (int i; 0 .. 12)
    {
        h.frame();
    }
    assert(sel.peek == 0 && sv.scrollY == 0 && picked.peek == [0, 1] && h.tree.hasCall(list) == false,
        "up to the first item");

    h.inject(PointerKind.move, at(8));
    h.frame();
    assert(h.tree.hasCall(list));
    h.inject(PointerKind.up, at(8));
    assert(h.tree.hasCall(list) == false, "the release drops the timer");
    int released = sel.peek;
    h.frame();
    h.frame();
    assert(sel.peek == released, "the release stops it");
}

// A focused row stays bound with its item while scrolled out of view, and loses focus when its item goes.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.menu : menuHost;
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.range : iota;

    Host h = menuHost(200, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!(int[]) items = signal(iota(1000).array);
    VirtualList!(int, int) list = virtualList!(int, int)(&items.get, (int i) => i,
        (int delegate() it) => listItem()(new Fixed(Size(10, 4))));
    ScrollView sv = scroll()(list);
    h.setRoot(sv);
    h.frame();
    Node two = list[2];
    h.setFocus(two);
    sv.scrollTo(5000);
    h.frame();
    assert(list[2] is two && h.focused is two && two.bounds.y < 0, "kept above the view");
    assert(list.children[0] is two, "first, in item order");
    sv.scrollTo(0);
    h.frame();
    assert(list[2] is two && h.focused is two);
    sv.scrollTo(5000);
    h.frame();
    items.set(items.peek.filter!(i => i != 2).array);
    h.frame();
    assert(list[2] is null && h.focused is null);
}
