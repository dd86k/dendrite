/// Tables, rows of app data in columns with a header, over a virtual list. Columns resize by dragging their
/// header edge, sort by clicking their title, move by dragging their title, and hide from the header's menu.
/// The header is a Tab stop of its own, so all of that also works from the keyboard.
///
/// Cells are nodes built per column around a getter of the row's item, so any widget fits in a cell. Columns
/// wider than the table scroll sideways with Shift and the wheel, a horizontal wheel, the arrow keys or the bar
/// at the bottom.
module dentrite.widgets.table;

import core.time : MonoTime;
import dentrite.containers : Fling, ScrollStyle, ScrollView, scroll;
import dentrite.access : AccessPartTree, AccessParts, nodeText, textOnly;
import dentrite.node;
import dentrite.signals;
import dentrite.text;
import dentrite.widgets.icons : Icon, paintIcon;
import dentrite.widgets.list : asNodeMaker, ListStyle, VirtualList, virtualList;
import dentrite.widgets.menu : MenuItem, contextMenu, menuItem;
import std.algorithm.comparison : clamp, max, min;
import std.algorithm.mutation : remove;
import std.math : abs, isInfinity, round;

/// Look of a table. Row backgrounds come from `ListStyle`.
struct TableStyle
{
    enum section = "table"; /// section name in theme files

    Color header = Color(0x26, 0x26, 0x2a, 0xff);      /// header background
    Color headerHover = Color(0x30, 0x30, 0x35, 0xff); /// title under the pointer
    Color headerText = Color(0xbb, 0xbb, 0xbb, 0xff);  /// title text color
    Color line = Color(0x3a, 0x3a, 0x40, 0xff);        /// header bottom and title separators
    Color grid = Color(0, 0, 0, 0);                    /// lines between body columns, transparent for none
    Color arrow = Color(0x99, 0x99, 0x99, 0xff);       /// sort arrow color
    float padX = 8;        /// cell and title padding left and right
    float padY = 3;        /// cell padding top and bottom
    float headerPadY = 5;  /// title padding top and bottom
    float arrowSize = 7;   /// sort arrow size
    float grip = 4;        /// distance from a column edge that grabs it
    float minColumn = 32;  /// narrowest column
    float keyScroll = 40;  /// distance an arrow key scrolls sideways
    float keyResize = 10;  /// width change of Ctrl and an arrow key on a focused title
    float dragStart = 4;   /// pointer travel that turns a title press into a move
    Color drop = Color(0x4c, 0x8d, 0xf6, 0xff); /// marker showing where a moved column lands
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff); /// focus ring around the current title
    FontKind font = FontKind.ui; /// title font
    float size = 12;       /// title size
}

/// Column of a table: title, cell builder, width and optional sort order.
struct TableColumn(T)
{
    string title;                      /// header text
    Node delegate(T delegate()) cell;  /// builds a cell around a getter of the row's item
    float width = 120;                 /// starting width in logical pixels
    bool delegate(T, T) less;          /// sort order, null if the column does not sort
}

/// Column options: `tableColumn("Name", (Proc delegate() p) => label(() => p().name), width: 200,
/// less: (Proc a, Proc b) => a.name < b.name)`. The cell builder must read the getter inside effects, as rows
/// are reused.
TableColumn!T tableColumn(T, R : Node)(string title, R delegate(T delegate()) cell, float width = 120,
    bool delegate(T, T) less = null)
{
    return TableColumn!T(title, asNodeMaker(cell), width, less);
}

/// Column the table sorts by.
struct SortOrder
{
    ptrdiff_t column = -1; /// column index, -1 for the items' own order
    bool descending;       /// largest first
}

/// Table over app data. Build it with `table`.
final class Table(K, T) : Node, DragScroller
{
    VirtualList!(K, T) list; /// virtual list showing the rows
    ScrollView view;         /// scroll view around the rows

    private TableHeader!(K, T) head;   /// titles, inside the column menu
    private TableColumn!T[] columns;   /// columns in order
    private float[] widths;            /// current column widths
    private Signal!(size_t[]) shown;   /// shown columns, left to right
    private float scrollX = 0;         /// sideways scroll distance
    private Signal!SortOrder order;    /// sort column and direction
    private T[] delegate() source;     /// items in their own order
    private K delegate(T) keyOf;       /// item key
    private Signal!K selection;        /// selected key
    private void delegate(T) activated; /// Enter or a double click, or null
    private bool dragging;             /// horizontal thumb is being dragged
    private float grabX;               /// pointer x minus thumb left at grab
    private Fling fling;               /// sideways content drag and fling
    private float panX = 0;            /// unrounded scroll distance while dragged or flung

    /// Creates a table. Use `table`, which also builds the rows.
    this(T[] delegate() source, K delegate(T) keyOf, TableColumn!T[] columns, Signal!K selection,
        void delegate(T) activated)
    {
        this.source = source;
        this.keyOf = keyOf;
        this.columns = columns;
        this.selection = selection;
        this.activated = activated;
        foreach (ref TableColumn!T c; columns)
        {
            widths ~= c.width;
        }
        order = signal(SortOrder.init);
        size_t[] all;
        foreach (size_t i; 0 .. columns.length)
        {
            all ~= i;
        }
        shown = signal(all);
        interactive = true;
    }

    /// Table of the header and the bound rows, counting the header as a row.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.table;
        a.multiselectable = list.selectedKeys !is null;
        a.rowCount = cast(uint) list.count + 1;
        a.columnCount = cast(uint) shown.peek.length;
    }

    /// Current width of column `i`.
    float width(size_t i)
    {
        return widths[i];
    }

    /// Resizes column `i`, no narrower than the style's minimum.
    void setWidth(size_t i, float w)
    {
        float m = tree is null ? TableStyle.init.minColumn : tree.style!TableStyle().minColumn;
        w = max(m, round(w));
        if (w != widths[i])
        {
            widths[i] = w;
            columnsMoved();
        }
    }

    /// Sum of the shown column widths.
    float totalWidth()
    {
        float s = 0;
        foreach (size_t i; shown.peek)
        {
            s += widths[i];
        }
        return s;
    }

    /// Left edge of column `i` in the table, after the sideways scroll. A hidden column gives the right end.
    float columnX(size_t i)
    {
        float x = -scrollX;
        foreach (size_t k; shown.peek)
        {
            if (k == i)
            {
                break;
            }
            x += widths[k];
        }
        return x;
    }

    /// Shown columns from left to right, as indices into the columns passed to `table`.
    const(size_t)[] shownColumns()
    {
        return shown.peek;
    }

    /// True if column `i` shows. Tracked inside effects.
    bool isShown(size_t i)
    {
        foreach (size_t k; shown.get)
        {
            if (k == i)
            {
                return true;
            }
        }
        return false;
    }

    /// Shows or hides column `i`. A column coming back goes after the shown columns that come before it in the
    /// list passed to `table`. The last shown column stays.
    void showColumn(size_t i, bool on)
    {
        size_t[] now = shown.peek.dup;
        if (on == isShownNow(i))
        {
            return;
        }
        if (on)
        {
            size_t at = 0;
            foreach (size_t slot, size_t k; now)
            {
                if (k < i)
                {
                    at = slot + 1;
                }
            }
            now = now[0 .. at] ~ i ~ now[at .. $];
        }
        else if (now.length > 1)
        {
            now = now.remove!(k => k == i);
        }
        setShown(now);
    }

    /// Moves shown column `i` to place `slot` from the left.
    void moveColumn(size_t i, size_t slot)
    {
        size_t[] now = shown.peek.dup.remove!(k => k == i);
        if (now.length == shown.peek.length)
        {
            return;
        }
        slot = min(slot, now.length);
        setShown(now[0 .. slot] ~ i ~ now[slot .. $]);
    }

    /// True if column `i` shows, untracked.
    private bool isShownNow(size_t i)
    {
        foreach (size_t k; shown.peek)
        {
            if (k == i)
            {
                return true;
            }
        }
        return false;
    }

    /// Place of column `i` from the left, or -1 when hidden.
    private ptrdiff_t slotOf(size_t i)
    {
        foreach (size_t slot, size_t k; shown.peek)
        {
            if (k == i)
            {
                return slot;
            }
        }
        return -1;
    }

    /// Takes a new column order and lays the columns out again.
    private void setShown(size_t[] next)
    {
        shown.set(next);
        scrollX = clamp(scrollX, 0, maxScrollX);
        columnsMoved();
    }

    /// Menu entry showing or hiding column `i`. A function of its own so each entry keeps its column.
    private MenuItem columnItem(size_t i)
    {
        return menuItem(columns[i].title, () { showColumn(i, isShownNow(i) == false); },
            enabled: () => isShown(i) == false || shown.get.length > 1, checked: () => isShown(i));
    }

    /// Sideways scroll distance.
    float scrolledX()
    {
        return scrollX;
    }

    /// Scrolls sideways to `x`, clamped.
    void scrollXTo(float x)
    {
        x = clamp(round(x), 0, maxScrollX);
        if (x != scrollX)
        {
            scrollX = x;
            columnsMoved();
        }
    }

    /// Largest sideways scroll distance.
    private float maxScrollX()
    {
        return max(0f, totalWidth - size.w);
    }

    /// Sort column and direction.
    SortOrder sortOrder()
    {
        return order.peek;
    }

    /// Sorts by column `i`, or by the items' own order for -1.
    void sortBy(ptrdiff_t i, bool descending = false)
    {
        order.set(SortOrder(i, descending));
    }

    /// Items in the sort order, read by the list effect.
    private T[] sorted()
    {
        import std.algorithm.mutation : SwapStrategy;
        import std.algorithm.sorting : sort;

        T[] all = source();
        SortOrder o = order.get;
        if (o.column < 0 || columns[o.column].less is null)
        {
            return all;
        }
        bool delegate(T, T) less = columns[o.column].less;
        T[] copy = all.dup;
        if (o.descending)
        {
            copy.sort!((a, b) => less(b, a), SwapStrategy.stable);
        }
        else
        {
            copy.sort!((a, b) => less(a, b), SwapStrategy.stable);
        }
        return copy;
    }

    /// Lays the header and the bound rows out again after a resize or a sideways scroll.
    private void columnsMoved()
    {
        if (head !is null)
        {
            head.markNeedsLayout();
            head.markNeedsPaint();
        }
        if (list !is null)
        {
            foreach (Node r; list.children)
            {
                r.markNeedsLayout();
                r.markNeedsPaint();
            }
        }
        markNeedsPaint();
    }

    /// Header on top, rows below. Fills bounded constraints, like a scroll view, so give it a height.
    protected override Size performLayout(Constraints c)
    {
        float w = isInfinity(c.maxW) ? max(c.minW, totalWidth) : c.maxW;
        size.w = w;
        scrollX = clamp(scrollX, 0, maxScrollX);
        Size hs = children[0].layout(Constraints(w, w, 0, float.infinity));
        children[0].offset = Point.init;
        float h = max(hs.h, isInfinity(c.maxH) ? c.minH : c.maxH);
        view.layout(Constraints(w, w, h - hs.h, h - hs.h));
        view.offset = Point(0, hs.h);
        return Size(w, h);
    }

    /// Horizontal thumb in window coordinates, empty when the columns fit.
    private Rect thumb(Point origin, const ref ScrollStyle s)
    {
        float total = totalWidth;
        if (total <= size.w || size.w <= 0)
        {
            return Rect.init;
        }
        float tw = max(s.minThumb, size.w * size.w / total);
        float x = (size.w - tw) * scrollX / maxScrollX;
        return Rect(origin.x + x, origin.y + size.h - s.width - 2, tw, s.width);
    }

    /// Header and rows, then the horizontal thumb.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintChildren(ctx, origin);
        ScrollStyle s = ctx.style!ScrollStyle();
        Rect t = thumb(origin, s);
        if (t.empty == false)
        {
            ctx.list.rect(t, dragging || hovered ? s.thumbHover : s.thumb, s.width / 2);
        }
    }

    /// The horizontal bar belongs to the table, the rest to the children.
    override Node hitTest(Point p, Point origin)
    {
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (r.contains(p) == false)
        {
            return null;
        }
        ScrollStyle s = tree.style!ScrollStyle();
        if (totalWidth > size.w && p.y >= r.bottom - s.width - 4)
        {
            return this;
        }
        return super.hitTest(p, origin);
    }

    /// True if `source` drags it per the window, away from the bar, while the columns are wider than it.
    bool scrollsDrag(PointerSource source, Point at, out bool onBar)
    {
        ScrollStyle s = tree.style!ScrollStyle();
        onBar = totalWidth > size.w && at.y >= bounds.bottom - s.width - 4;
        return totalWidth > size.w && tree.scrollDrag.scrollsWith(source) && onBar == false;
    }

    /// Takes a mostly sideways drag with room to scroll that way, or any when `edge` is set.
    bool takeDrag(Point at, Point moved, bool edge, MonoTime time)
    {
        if (abs(moved.x) <= abs(moved.y) || totalWidth <= size.w)
        {
            return false;
        }
        if (edge == false && (moved.x > 0 ? scrollX <= 0 : scrollX >= maxScrollX))
        {
            return false;
        }
        fling.grab(at, time);
        panX = scrollX;
        return true;
    }

    /// Stops a fling and holds the content at `at`.
    bool catchFling(Point at, MonoTime time)
    {
        return fling.catchAt(at, time);
    }

    /// Scrolls sideways by `d` from the unrounded distance. False if that went past an end.
    private bool panBy(float d)
    {
        float want = panX + d;
        panX = clamp(want, 0, maxScrollX);
        scrollXTo(panX);
        return panX == want;
    }

    /// Moves the fling on to the frame time, until it stops or reaches an end.
    private void coast()
    {
        if (fling.coasting == false)
        {
            return;
        }
        ScrollStyle s = tree.style!ScrollStyle();
        if (panBy(fling.coast(tree.services.now, s.flingDecay, s.flingMin).x) == false)
        {
            fling.stop();
        }
        fling.next(this, &coast);
    }

    /// Thumb dragging, track clicks and content drags.
    override bool onPointer(ref const PointerEvent e)
    {
        if (fling.held)
        {
            switch (e.kind)
            {
            case PointerKind.move:
                panBy(fling.drag(e.pos, e.time).x);
                return true;
            case PointerKind.up:
                ScrollStyle fs = tree.style!ScrollStyle();
                if (fling.release(e.pos, e.time, fs.flingMin))
                {
                    fling.next(this, &coast);
                }
                return true;
            case PointerKind.cancel:
                fling.held = false;
                return true;
            default:
                break;
            }
        }
        ScrollStyle s = tree.style!ScrollStyle();
        Rect b = bounds;
        Rect t = thumb(b.pos, s);
        switch (e.kind)
        {
        case PointerKind.down:
            if (t.empty || e.button != 1)
            {
                return false;
            }
            if (t.contains(e.pos) == false)
            {
                scrollXTo(scrollX + (e.pos.x < t.x ? -size.w : size.w));
                return true;
            }
            dragging = true;
            grabX = e.pos.x - t.x;
            markNeedsPaint();
            return true;
        case PointerKind.move:
            if (dragging)
            {
                float track = size.w - t.w;
                scrollXTo(track > 0 ? (e.pos.x - grabX - b.x) / track * maxScrollX : 0);
            }
            return dragging;
        case PointerKind.up:
        case PointerKind.cancel:
            dragging = false;
            markNeedsPaint();
            return true;
        case PointerKind.enter:
        case PointerKind.leave:
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// A horizontal wheel, or Shift and the wheel, scrolls sideways.
    override bool onWheel(ref const WheelEvent e)
    {
        float d = e.dx != 0 ? e.dx : ((e.mods & Mod.shift) != 0 ? e.dy : 0);
        if (d == 0 || totalWidth <= size.w)
        {
            return false;
        }
        fling.stop();
        scrollXTo(scrollX + d);
        return true;
    }

    /// Left and right scroll sideways when the columns do not fit.
    override bool onKey(ref const KeyEvent e)
    {
        if (e.mods != 0 || (e.key != Key.left && e.key != Key.right) || totalWidth <= size.w)
        {
            return false;
        }
        float step = tree.style!TableStyle().keyScroll;
        scrollXTo(scrollX + (e.key == Key.left ? -step : step));
        return true;
    }
}

/// Column titles: a press and release on a title sorts, a drag on a title moves its column, and a drag on a
/// column's right edge resizes it. With focus, Left and Right pick a title, Enter or Space sorts by it, Ctrl
/// and an arrow resize it, Alt and an arrow move it, and Down goes to the rows.
private final class TableHeader(K, T) : Node, AccessParts
{
    private Table!(K, T) table;      /// owning table
    private ptrdiff_t hot = -1;      /// title under the pointer
    private ptrdiff_t hotEdge = -1;  /// column whose right edge is under the pointer
    private ptrdiff_t pressedOn = -1; /// title pressed
    private ptrdiff_t resizing = -1; /// column being resized
    private bool moving;             /// the pressed title is being dragged to another place
    private size_t dropSlot;         /// place the moved column lands, among the other columns
    private float grabX;             /// pointer x at the press
    private float startW;            /// width at the resize press
    private size_t current;          /// title the keys act on

    /// Creates the header of `table`.
    this(Table!(K, T) table)
    {
        this.table = table;
        interactive = true;
        focusable = true;
        drags = DragAxes.horizontal;
    }

    /// Header row named by the shown titles, the first row of the table.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.row;
        a.rowIndex = 1;
        foreach (size_t i; table.shown.peek)
        {
            string s = table.columns[i].title;
            a.label ~= a.label.length > 0 ? ", " ~ s : s;
        }
    }

    /// Shown columns.
    size_t accessPartCount()
    {
        return table.shown.peek.length;
    }

    /// Header of the `i`th shown column, named by its title.
    void describePart(size_t i, ref AccessInfo a, ref Rect r)
    {
        size_t col = table.shown.peek[i];
        a.role = Role.columnHeader;
        a.label = table.columns[col].title;
        a.rowIndex = 1;
        a.columnIndex = cast(uint) i + 1;
        if (table.columns[col].less !is null)
        {
            a.allow(AccessAction.click);
        }
        r = Rect(r.x + table.columnX(col), r.y, table.widths[col], r.h);
    }

    /// Click sorts by the `i`th shown column, focus makes it current.
    bool accessPartAction(size_t i, ref const AccessRequest r)
    {
        size_t col = table.shown.peek[i];
        switch (r.action)
        {
        case AccessAction.click:
            current = col;
            sort(col);
            return true;
        case AccessAction.focus:
            current = col;
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// The current column while the header has focus.
    ptrdiff_t accessFocusPart()
    {
        if (focused == false)
        {
            return -1;
        }
        size_t col = currentColumn;
        foreach (size_t i, size_t c; table.shown.peek)
        {
            if (c == col)
            {
                return i;
            }
        }
        return -1;
    }

    /// Full width, one title line tall.
    protected override Size performLayout(Constraints c)
    {
        TableStyle s = tree.style!TableStyle();
        float h = tree.text.lineHeight(s.font, s.size) + s.headerPadY * 2;
        return c.constrain(Size(isInfinity(c.maxW) ? table.totalWidth : c.maxW, h));
    }

    /// Column whose title is under window x `x`, or -1.
    private ptrdiff_t columnAt(float x)
    {
        float lx = x - bounds.x;
        foreach (size_t i; table.shown.peek)
        {
            float l = table.columnX(i);
            if (lx >= l && lx < l + table.widths[i])
            {
                return i;
            }
        }
        return -1;
    }

    /// Column whose right edge is within the grip of window x `x`, or -1. The rightmost wins.
    private ptrdiff_t edgeAt(float x)
    {
        float grip = tree.style!TableStyle().grip;
        float lx = x - bounds.x;
        ptrdiff_t found = -1;
        foreach (size_t i; table.shown.peek)
        {
            float r = table.columnX(i) + table.widths[i];
            if (lx >= r - grip && lx <= r + grip)
            {
                found = i;
            }
        }
        return found;
    }

    /// Place among the columns other than the moved one where window x `x` drops it.
    private size_t slotAt(float x)
    {
        float lx = x - bounds.x;
        size_t slot = 0;
        foreach (size_t i; table.shown.peek)
        {
            if (i != pressedOn && table.columnX(i) + table.widths[i] / 2 < lx)
            {
                ++slot;
            }
        }
        return slot;
    }

    /// Table x of the drop line for `dropSlot`.
    private float dropX()
    {
        size_t n = 0;
        float end = -table.scrollX;
        foreach (size_t i; table.shown.peek)
        {
            if (i == pressedOn)
            {
                continue;
            }
            if (n == dropSlot)
            {
                return table.columnX(i);
            }
            ++n;
            end = table.columnX(i) + table.widths[i];
        }
        return end;
    }

    /// The title the keys act on, kept on a shown column.
    private size_t currentColumn()
    {
        if (table.isShownNow(current) == false)
        {
            current = table.shown.peek[0];
        }
        return current;
    }

    /// Titles, the sort arrow, separators, the drop line of a move, the focus ring and the bottom line.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TableStyle s = ctx.style!TableStyle();
        TextSystem t = ctx.text;
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        ctx.list.rect(r, s.header);
        SortOrder o = table.order.peek;
        float base = origin.y + s.headerPadY + t.ascent(s.font, s.size);
        ctx.clipped(r, {
            foreach (size_t i; table.shown.peek)
            {
                TableColumn!T c = table.columns[i];
                Rect col = Rect(origin.x + table.columnX(i), origin.y, table.widths[i], size.h);
                if (col.right < r.x || col.x > r.right)
                {
                    continue;
                }
                bool lit = moving ? i == pressedOn : i == hot && c.less !is null && resizing < 0;
                if (lit)
                {
                    ctx.list.rect(col, s.headerHover);
                }
                float room = col.w - s.padX * 2;
                if (o.column == i)
                {
                    room -= s.arrowSize + 4;
                    Rect a = Rect(col.right - s.padX - s.arrowSize, origin.y + round((size.h - s.arrowSize) / 2),
                        s.arrowSize, s.arrowSize);
                    paintIcon(*ctx.list, o.descending ? Icon.chevronDown : Icon.chevronUp, a, s.arrow);
                }
                ctx.clipped(Rect(col.x + s.padX, col.y, max(0f, room), col.h), {
                    ctx.list.text(t.shape(s.font, s.size, c.title), Point(col.x + s.padX, base), s.headerText);
                });
                ctx.list.rect(Rect(col.right - 1, col.y + 4, 1, col.h - 8), s.line);
                if (focusRing && i == currentColumn)
                {
                    ctx.list.rect(col.inset(1), Color.init, 0, s.focus, 1);
                }
            }
            if (moving)
            {
                ctx.list.rect(Rect(origin.x + round(dropX) - 1, origin.y, 2, size.h), s.drop);
            }
        });
        ctx.list.rect(Rect(r.x, r.bottom - 1, r.w, 1), s.line);
    }

    /// Hover, resizing, moving and sorting.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.move:
            if (resizing >= 0)
            {
                table.setWidth(resizing, startW + e.pos.x - grabX);
                return true;
            }
            if (pressedOn >= 0 && (moving || abs(e.pos.x - grabX) >= tree.style!TableStyle().dragStart))
            {
                moving = true;
                dropSlot = slotAt(e.pos.x);
                markNeedsPaint();
                return true;
            }
            ptrdiff_t edge = edgeAt(e.pos.x);
            ptrdiff_t over = edge >= 0 ? -1 : columnAt(e.pos.x);
            cursor = edge >= 0 ? CursorShape.ewResize : CursorShape.arrow;
            if (edge != hotEdge || over != hot)
            {
                hotEdge = edge;
                hot = over;
                markNeedsPaint();
            }
            return true;
        case PointerKind.leave:
            if (resizing < 0 && pressedOn < 0)
            {
                hot = -1;
                hotEdge = -1;
                markNeedsPaint();
            }
            return true;
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            grabX = e.pos.x;
            if (hotEdge >= 0)
            {
                resizing = hotEdge;
                startW = table.widths[resizing];
            }
            else
            {
                pressedOn = hot;
                if (hot >= 0)
                {
                    current = hot;
                }
            }
            return true;
        case PointerKind.up:
            if (resizing >= 0)
            {
                resizing = -1;
                markNeedsPaint();
                return true;
            }
            ptrdiff_t col = columnAt(e.pos.x);
            if (moving)
            {
                table.moveColumn(pressedOn, dropSlot);
            }
            else if (pressedOn >= 0 && col == pressedOn && hovered)
            {
                sort(col);
            }
            moving = false;
            pressedOn = -1;
            markNeedsPaint();
            return true;
        case PointerKind.cancel:
            if (resizing >= 0)
            {
                table.setWidth(resizing, startW);
            }
            resizing = -1;
            moving = false;
            pressedOn = -1;
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// Sorts by column `i`, flipping the direction if it already sorts by it. Columns without an order do not
    /// sort.
    private void sort(size_t i)
    {
        if (table.columns[i].less is null)
        {
            return;
        }
        SortOrder o = table.order.peek;
        table.sortBy(i, o.column == i && o.descending == false);
        markNeedsPaint();
    }

    /// Escape during a move puts the column back, the other keys act on the current title.
    override bool onKey(ref const KeyEvent e)
    {
        if (moving && e.key == Key.escape)
        {
            moving = false;
            pressedOn = -1;
            markNeedsPaint();
            return true;
        }
        size_t at = currentColumn;
        const(size_t)[] order = table.shown.peek;
        ptrdiff_t slot = table.slotOf(at);
        bool left = e.key == Key.left;
        if (e.key != Key.left && e.key != Key.right)
        {
            if (e.mods != 0)
            {
                return false;
            }
            switch (e.key)
            {
            case Key.enter:
            case Key.space:
                sort(at);
                return true;
            case Key.home:
                show(order[0]);
                return true;
            case Key.end:
                show(order[$ - 1]);
                return true;
            case Key.down:
                if (table.list.focusable && tree.services !is null)
                {
                    tree.services.setFocus(table.list);
                }
                return true;
            default:
                return false;
            }
        }
        switch (e.mods)
        {
        case 0:
            show(order[clamp(slot + (left ? -1 : 1), 0, cast(ptrdiff_t) order.length - 1)]);
            return true;
        case Mod.ctrl:
            float step = tree.style!TableStyle().keyResize;
            table.setWidth(at, table.widths[at] + (left ? -step : step));
            show(at);
            return true;
        case Mod.alt:
            table.moveColumn(at, left ? max(0, slot - 1) : slot + 1);
            show(at);
            return true;
        default:
            return false;
        }
    }

    /// Makes column `i` current and scrolls it into view.
    private void show(size_t i)
    {
        current = i;
        float l = table.columnX(i);
        float r = l + table.widths[i];
        if (l < 0)
        {
            table.scrollXTo(table.scrollX + l);
        }
        else if (r > size.w)
        {
            table.scrollXTo(table.scrollX + min(l, r - size.w));
        }
        markNeedsPaint();
    }

    /// Repaints the focus ring.
    override void onFocus(bool on)
    {
        markNeedsPaint();
    }
}

/// Row of a table: one cell per column, clipped to its column. Press selects, a double click activates.
private final class TableRow(K, T) : Node, AccessPartTree
{
    private Table!(K, T) table; /// owning table
    private T delegate() item;  /// row's item
    private bool selected;      /// drawn as selected

    /// Builds the cells for the item `item` returns. The effects belong to the current owner.
    this(Table!(K, T) table, T delegate() item)
    {
        this.table = table;
        this.item = item;
        interactive = true;
        foreach (ref TableColumn!T c; table.columns)
        {
            add(c.cell(item));
        }
        effect(() {
            bool sel = table.list.isSelected(table.keyOf(item()));
            if (sel != selected)
            {
                selected = sel;
                markNeedsPaint();
            }
        });
    }

    /// Row named by its shown cells. Each one is a cell holding its content, which stays out unless a cell holds
    /// more than text.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.row;
        foreach (size_t i; table.shown.peek)
        {
            string s = nodeText(children[i]);
            a.label ~= a.label.length > 0 && s.length > 0 ? ", " ~ s : s;
        }
        a.selected = tri(selected);
        a.leaf = textOnly(this);
        a.allow(AccessAction.click);
        table.list.describeRow(this, a);
        a.rowIndex = a.position + 1;
    }

    /// Click selects the row.
    override bool accessAction(ref const AccessRequest r)
    {
        if (r.action != AccessAction.click)
        {
            return false;
        }
        table.list.press(table.list.indexOf(table.keyOf(item())), 0, this);
        table.list.endDrag();
        return true;
    }

    /// Shown cells.
    size_t accessPartCount()
    {
        return table.shown.peek.length;
    }

    /// Cell of the `i`th shown column, named by its text when the row holds only text.
    void describePart(size_t i, ref AccessInfo a, ref Rect r)
    {
        size_t col = table.shown.peek[i];
        AccessInfo row;
        table.list.describeRow(this, row);
        a.role = Role.cell;
        a.rowIndex = row.position + 1;
        a.columnIndex = cast(uint) i + 1;
        if (textOnly(this))
        {
            a.label = nodeText(children[col]);
        }
        a.allow(AccessAction.click);
        r = Rect(r.x + table.columnX(col), r.y, table.widths[col], r.h);
    }

    /// Click selects the row.
    bool accessPartAction(size_t i, ref const AccessRequest r)
    {
        return accessAction(r);
    }

    /// No cell takes focus.
    ptrdiff_t accessFocusPart()
    {
        return -1;
    }

    /// Cells are not nested.
    ptrdiff_t partParent(size_t i)
    {
        return -1;
    }

    /// Cell holding content node `c`, or -1 for a hidden column's.
    ptrdiff_t childPart(Node c)
    {
        foreach (size_t i, size_t col; table.shown.peek)
        {
            if (children[col] is c)
            {
                return i;
            }
        }
        return -1;
    }

    /// Shown cells at their column's left edge inside the padding, centered on the tallest.
    protected override Size performLayout(Constraints c)
    {
        TableStyle s = tree.style!TableStyle();
        float tallest = 0;
        foreach (size_t i; table.shown.peek)
        {
            float room = max(0f, table.widths[i] - s.padX * 2);
            tallest = max(tallest, children[i].layout(Constraints(0, room, 0, float.infinity)).h);
        }
        foreach (size_t i; table.shown.peek)
        {
            Node cell = children[i];
            cell.offset = Point(table.columnX(i) + s.padX, s.padY + round((tallest - cell.size.h) / 2));
        }
        return c.constrain(Size(isInfinity(c.maxW) ? table.totalWidth : c.maxW, tallest + s.padY * 2));
    }

    /// Rect of column `i` when the row sits at `origin`.
    private Rect columnRect(size_t i, Point origin)
    {
        return Rect(origin.x + table.columnX(i), origin.y, table.widths[i], size.h);
    }

    /// Background for the state, then each cell clipped to its column.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ListStyle l = ctx.style!ListStyle();
        TableStyle s = ctx.style!TableStyle();
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
        foreach (size_t i; table.shown.peek)
        {
            Node cell = children[i];
            Rect col = columnRect(i, origin);
            if (col.right <= r.x || col.x >= r.right)
            {
                continue;
            }
            ctx.clipped(intersect(col, r), { paintChild(ctx, origin, cell); });
            if (s.grid.a > 0)
            {
                ctx.list.rect(Rect(col.right - 1, r.y, 1, r.h), s.grid);
            }
        }
    }

    /// Cells only where their column shows, the row elsewhere.
    override Node hitTest(Point p, Point origin)
    {
        if (Rect(origin.x, origin.y, size.w, size.h).contains(p) == false)
        {
            return null;
        }
        foreach (size_t i; table.shown.peek)
        {
            if (columnRect(i, origin).contains(p))
            {
                Node hit = children[i].hitTest(p, origin + children[i].offset);
                return hit is null ? this : hit;
            }
        }
        return this;
    }

    /// Hover, a press selecting the row, a drag selecting a range, and a double click activating it.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.leave:
            markNeedsPaint();
            return true;
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            table.list.press(table.list.indexOf(table.keyOf(item())), e.mods, this);
            if (e.clicks == 2 && e.mods == 0 && table.activated !is null)
            {
                table.activated(item());
            }
            return true;
        case PointerKind.move:
            if (pressed)
            {
                table.list.dragTo(e.pos.y);
            }
            return pressed;
        case PointerKind.up:
        case PointerKind.cancel:
            table.list.endDrag();
            return true;
        default:
            return false;
        }
    }
}

/// Table options, waiting for the columns.
struct TableSpec(K, T)
{
    T[] delegate() items;        /// items shown as rows, in their own order
    K delegate(T) key;           /// key of an item, stable across updates
    Signal!K selected;           /// key of the selected item
    void delegate(T) onActivate; /// runs on Enter or a double click on a row
    string delegate(T) text;     /// row text for typing to select, or null
    Signal!(K[]) multi;          /// selected keys when more than one may be, or null

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(T[] delegate() items, K delegate(T) key, Signal!K selected, void delegate(T) onActivate,
        string delegate(T) text, Signal!(K[]) multi)
    {
        this.text = text;
        this.multi = multi;
        this.items = items;
        this.key = key;
        this.selected = selected;
        this.onActivate = onActivate;
    }

    /// The table with `columns`. Its scopes belong to the current owner.
    Table!(K, T) opCall(TableColumn!T[] columns...)
    {
        Table!(K, T) t = new Table!(K, T)(items, key, columns.dup, selected, onActivate);
        t.list = virtualList!(K, T)(&t.sorted, key, (T delegate() it) => new TableRow!(K, T)(t, it),
            selected, onActivate, text, multi);
        t.list.accessRole = Role.none;
        t.view = scroll()(t.list);
        t.head = new TableHeader!(K, T)(t);
        Node[] items;
        foreach (size_t i; 0 .. t.columns.length)
        {
            items ~= t.columnItem(i);
        }
        t.add(contextMenu(items)(t.head));
        t.add(t.view);
        return t;
    }
}

/// Table of `items` keyed by `key`, one Tab stop moving `selected` with the arrow keys:
/// `table(items: () => procs.get, key: (Proc p) => p.pid, selected: sel)(tableColumn(...), ...)`. With `text`
/// typing selects the next row, in shown order, whose text starts with the typed letters. With `multi` more than
/// one row may be selected, see `VirtualList.setMultiple`.
TableSpec!(K, T) table(K, T)(T[] delegate() items, K delegate(T) key, Signal!K selected,
    void delegate(T) onActivate = null, string delegate(T) text = null, Signal!(K[]) multi = null)
{
    return TableSpec!(K, T)(items, key, selected, onActivate, text, multi);
}

version (unittest)
{
    /// Row of the test table.
    private struct Planet
    {
        string name; /// key
        int moons;   /// second column
    }
}

// Clicking a title sorts and flips, dragging an edge resizes, wide columns scroll sideways, and rows select
// and activate.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.label : Label, label;
    import dentrite.widgets.menu : menuHost;
    import std.conv : to;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Planet[] planets = [Planet("Mars", 2), Planet("Earth", 1), Planet("Jupiter", 95), Planet("Venus", 0)];
    Signal!string sel = signal("");
    string opened;
    Table!(string, Planet) t = table(items: () => planets, key: (Planet p) => p.name, selected: sel,
        onActivate: (Planet p) { opened = p.name; }, text: (Planet p) => p.name)(
        tableColumn("Name", (Planet delegate() p) => label(() => p().name), width: 120,
            less: (Planet a, Planet b) => a.name < b.name),
        tableColumn("Moons", (Planet delegate() p) => label(() => p().moons.to!string), width: 80,
            less: (Planet a, Planet b) => a.moons < b.moons),
        tableColumn("Notes", (Planet delegate() p) => label("-"), width: 60),
    );
    h.setRoot(t);
    h.frame();
    assert(t.size == Size(300, 200) && t.list.children.length == 4);

    /// Name in row `i` as shown.
    string nameAt(size_t i)
    {
        foreach (Node r; t.list.children)
        {
            if (cast(int)(r.offset.y / r.size.h) == i)
            {
                return (cast(Label) r.children[0]).text;
            }
        }
        return null;
    }

    /// Window point inside the header over table x `x`.
    Point headerAt(float x)
    {
        Rect b = t.head.bounds;
        return Point(b.x + x, b.y + b.h / 2);
    }

    /// Press, optionally move, and release, then a frame.
    void drag(Point from, Point to, ubyte clicks = 1)
    {
        h.inject(PointerKind.move, from);
        h.inject(PointerKind.down, from, clicks);
        h.inject(PointerKind.move, to);
        h.inject(PointerKind.up, to, clicks);
        h.frame();
    }

    assert(nameAt(0) == "Mars");
    drag(headerAt(160), headerAt(160));
    assert(t.sortOrder == SortOrder(1, false) && nameAt(0) == "Venus" && nameAt(3) == "Jupiter");
    drag(headerAt(160), headerAt(160));
    assert(t.sortOrder == SortOrder(1, true) && nameAt(0) == "Jupiter");
    drag(headerAt(230), headerAt(230));
    assert(t.sortOrder == SortOrder(1, true), "Notes does not sort");

    drag(headerAt(120), headerAt(180));
    assert(t.width(0) == 180 && t.width(1) == 80 && t.columnX(1) == 180, "dragging the first edge resizes it");
    assert(t.sortOrder == SortOrder(1, true), "a resize does not sort");
    drag(headerAt(180), headerAt(0));
    assert(t.width(0) == TableStyle.init.minColumn, "no narrower than the minimum");
    t.setWidth(0, 300);
    h.frame();
    assert(t.totalWidth == 440);

    Node first = t.list.children[0];
    h.injectWheel(Point(150, 60), 50, 0, Mod.shift);
    h.frame();
    assert(t.scrolledX == 50 && t.columnX(0) == -50, "Shift and the wheel scroll sideways");
    assert(first.children[0].bounds.x == first.bounds.x + TableStyle.init.padX - 50, "cells move with it");
    h.injectWheel(Point(150, 60), 0, 500);
    h.frame();
    assert(t.scrolledX == 140, "clamped to the overflow");

    Rect r0 = t.list.children[0].bounds;
    drag(Point(150, r0.y + 5), Point(150, r0.y + 5));
    assert(h.focused is t.list && sel.peek.length > 0);
    string chosen = sel.peek;
    h.injectKey(Key.left, 0);
    h.frame();
    assert(t.scrolledX == 100 && sel.peek == chosen, "left scrolls sideways");
    h.injectKey(Key.down, 0);
    h.injectKey(Key.enter, 0);
    assert(opened == sel.peek && opened != chosen);
    drag(Point(150, r0.y + 5), Point(150, r0.y + 5), 2);
    assert(opened == chosen, "a double click activates");
    h.injectText("ma");
    assert(sel.peek == "Mars", "typing selects");
}

// Dragging a title moves its column, the header menu hides and shows columns, and the header takes keys.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : ContextMenu, menuHost;
    import std.conv : to;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Planet[] planets = [Planet("Mars", 2), Planet("Earth", 1)];
    Signal!string sel = signal("");
    Table!(string, Planet) t = table(items: () => planets, key: (Planet p) => p.name, selected: sel)(
        tableColumn("Name", (Planet delegate() p) => label(() => p().name), width: 120,
            less: (Planet a, Planet b) => a.name < b.name),
        tableColumn("Moons", (Planet delegate() p) => label(() => p().moons.to!string), width: 80),
        tableColumn("Notes", (Planet delegate() p) => label("-"), width: 60),
    );
    h.setRoot(t);
    h.frame();
    TableStyle s;
    Rect hb = t.head.bounds;
    /// Press at table x `from`, move to `to` and release, then a frame.
    void drag(float from, float to)
    {
        Point a = Point(hb.x + from, hb.y + hb.h / 2);
        Point b = Point(hb.x + to, a.y);
        h.inject(PointerKind.move, a);
        h.inject(PointerKind.down, a);
        h.inject(PointerKind.move, b);
        h.inject(PointerKind.up, b);
        h.frame();
    }

    drag(230, 10);
    assert(t.shownColumns == [2, 0, 1] && t.columnX(2) == 0 && t.columnX(0) == 60, "Notes moved to the front");
    assert(t.sortOrder.column == -1, "a move does not sort");
    Node row = t.list.children[0];
    assert(row.children[2].bounds.x == row.bounds.x + s.padX && row.children[0].bounds.x == row.bounds.x + 60 + s.padX);
    drag(10, 290);
    assert(t.shownColumns == [0, 1, 2], "and back to the end");

    t.showColumn(1, false);
    h.frame();
    assert(t.shownColumns == [0, 2] && t.totalWidth == 180 && t.columnX(2) == 120);
    t.showColumn(0, false);
    t.showColumn(2, false);
    assert(t.shownColumns == [2], "the last column stays");
    t.showColumn(1, true);
    t.showColumn(0, true);
    assert(t.shownColumns == [0, 1, 2], "columns come back in their own order");

    h.setFocus(t.head);
    h.injectKey(Key.menu);
    h.frame();
    ContextMenu cm = cast(ContextMenu) t.children[0];
    assert(cm.menu.isOpen, "the menu key opens the column menu");
    h.injectKey(Key.down);
    h.injectKey(Key.enter);
    h.frame();
    assert(t.shownColumns == [0, 2] && h.focused is t.head, "its second entry hid Moons");
    t.showColumn(1, true);

    h.injectKey(Key.home);
    h.injectKey(Key.enter);
    assert(t.sortOrder == SortOrder(0, false), "Enter sorts by the current title");
    h.injectKey(Key.right);
    h.injectKey(Key.right, Mod.ctrl);
    assert(t.width(1) == 80 + s.keyResize, "Ctrl and an arrow widen the current column");
    h.injectKey(Key.left, Mod.alt);
    assert(t.shownColumns == [1, 0, 2], "Alt and an arrow move it");
    h.injectKey(Key.end);
    h.injectKey(Key.space);
    assert(t.sortOrder == SortOrder(0, false), "Notes does not sort");
    h.injectKey(Key.down);
    assert(h.focused is t.list, "Down goes to the rows");
}

// With `multi` a Shift press or a drag picks rows in shown order, and a double click with Shift held does not
// activate.
unittest
{
    import dentrite.host : Host;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Planet[] planets = [Planet("Mars", 2), Planet("Earth", 1), Planet("Jupiter", 95), Planet("Venus", 0)];
    Signal!string sel = signal("");
    Signal!(string[]) picked = signal(cast(string[]) null);
    string opened;
    Table!(string, Planet) t = table(items: () => planets, key: (Planet p) => p.name, selected: sel,
        onActivate: (Planet p) { opened = p.name; }, multi: picked)(
        tableColumn("Name", (Planet delegate() p) => label(() => p().name), width: 120,
            less: (Planet a, Planet b) => a.name < b.name),
    );
    h.setRoot(t);
    t.sortBy(0, false);
    h.frame();
    clickOn(h, t.list["Earth"]);
    clickOn(h, t.list["Mars"], 1, Mod.shift);
    assert(picked.peek == ["Earth", "Jupiter", "Mars"] && sel.peek == "Mars");
    Rect b = t.list["Venus"].bounds;
    Point p = Point(b.x + 10, b.y + b.h / 2);
    h.inject(PointerKind.down, p, 2, 1, Mod.shift);
    h.inject(PointerKind.up, p, 2, 1, Mod.shift);
    assert(opened.length == 0 && picked.peek.length == 4);
    Point earth = Point(b.x + 10, t.list["Earth"].bounds.y + b.h / 2);
    Point mars = Point(b.x + 10, t.list["Mars"].bounds.y + b.h / 2);
    h.inject(PointerKind.move, earth);
    h.inject(PointerKind.down, earth);
    h.inject(PointerKind.move, mars);
    h.inject(PointerKind.up, mars);
    assert(picked.peek == ["Earth", "Jupiter", "Mars"], "a drag picks the rows passed");
}

// Rows bound past the edges of the view stay out of the screen reader tree, which then holds only rows on screen.
unittest
{
    import dentrite.access : AccessNode, AccessTree, AccessUpdate, Role;
    import dentrite.host : Host;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : menuHost;
    import std.format : format;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Planet[] planets;
    foreach (int i; 0 .. 60)
    {
        planets ~= Planet(format("P%02d", i), i);
    }
    Table!(string, Planet) t = table(items: () => planets, key: (Planet p) => p.name, selected: signal(""))(
        tableColumn("Name", (Planet delegate() p) => label(() => p().name), width: 120));
    h.setRoot(t);
    h.frame();
    h.injectWheel(Point(100, 100), 300);
    h.frame();
    AccessUpdate u = new AccessTree().update(h.tree, null, true);
    size_t rows;
    foreach (ref AccessNode n; u.nodes)
    {
        if (n.info.role == Role.row && n.info.label != "Name")
        {
            ++rows;
            assert(intersect(n.bounds, t.view.bounds).empty == false, n.info.label ~ " is off screen");
        }
    }
    assert(rows > 0 && rows < t.list.children.length, "some bound rows are hidden");
}

// Rows expose a cell per shown column with its row and column, named by its text, or holding its content when a
// cell holds more than text.
unittest
{
    import dentrite.access : AccessNode, AccessTree, AccessUpdate, Role;
    import dentrite.host : Host;
    import dentrite.widgets.checkbox : checkbox;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : menuHost;
    import std.conv : to;

    Host h = menuHost(400, 200);
    scope (exit)
    {
        h.close();
    }
    Planet[] planets = [Planet("Mars", 2), Planet("Earth", 1)];
    Table!(string, Planet) t = table(items: () => planets, key: (Planet p) => p.name, selected: signal(""))(
        tableColumn("Name", (Planet delegate() p) => label(() => p().name), width: 120),
        tableColumn("Moons", (Planet delegate() p) => label(() => p().moons.to!string), width: 80));
    h.setRoot(t);
    h.frame();
    AccessTree tree = new AccessTree();
    tree.update(h.tree, null, true);
    const(AccessNode)* tab = tree.find(Role.table, null);
    assert(tab.info.rowCount == 3 && tab.info.columnCount == 2, "the header counts as a row");
    assert(tree.find(Role.columnHeader, "Moons").info.columnIndex == 2);
    const(AccessNode)* earth = tree.find(Role.cell, "Earth");
    const(AccessNode)* moon = tree.find(Role.cell, "1");
    assert(earth.info.rowIndex == 3 && earth.info.columnIndex == 1 && earth.children.length == 0);
    assert(moon.info.rowIndex == 3 && moon.info.columnIndex == 2);
    assert(moon.bounds.x == earth.bounds.right, "cells sit in their columns");
    assert(tree.find(Role.row, "Earth, 1").children == [earth.id, moon.id]);

    Table!(string, Planet) c = table(items: () => planets, key: (Planet p) => p.name, selected: signal(""))(
        tableColumn("Name", (Planet delegate() p) => label(() => p().name), width: 120),
        tableColumn("Seen", (Planet delegate() p) => checkbox(signal(false), "Seen"), width: 80));
    h.setRoot(c);
    h.frame();
    AccessUpdate u = tree.update(h.tree, null, true);
    assert(tree.find(Role.label, "Mars") !is null && tree.find(Role.cell, "Mars") is null,
        "content speaks for itself");
    ulong seen = tree.find(Role.checkBox, "Seen").id;
    bool held;
    foreach (ref AccessNode n; u.nodes)
    {
        held = held || (n.info.role == Role.cell && n.info.columnIndex == 2 && n.children == [seen]);
    }
    assert(held, "the cell holds its content");
}

// A sideways touch drag on the rows scrolls the columns without selecting, and one on the header resizes.
unittest
{
    import core.time : MonoTime, msecs;
    import dentrite.host : Host;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Planet[] planets = [Planet("Mars", 2), Planet("Earth", 1)];
    Signal!string sel = signal("");
    Table!(string, Planet) t = table(items: () => planets, key: (Planet p) => p.name, selected: sel)(
        tableColumn("Name", (Planet delegate() p) => label(() => p().name), width: 300),
        tableColumn("Notes", (Planet delegate() p) => label("-"), width: 200),
    );
    h.setRoot(t);
    h.frame();
    MonoTime at = MonoTime.currTime;
    int ms;
    void swipe(Point from, float dx)
    {
        float s = dx < 0 ? -1 : 1;
        foreach (float x; [0, s * 4, s * 20, dx])
        {
            ms += 200;
            h.inject(x == 0 ? PointerKind.down : PointerKind.move, Point(from.x + x, from.y), 1, 1, 0,
                PointerSource.touch, at + ms.msecs);
        }
        h.inject(PointerKind.up, Point(from.x + dx, from.y), 1, 1, 0, PointerSource.touch, at + ms.msecs);
        h.frame();
    }

    Rect r0 = t.list.children[0].bounds;
    swipe(Point(200, r0.y + 5), -60);
    assert(t.scrolledX == 60 - 8 && sel.peek == "", "scrolled sideways, nothing selected");
    Rect hb = t.head.bounds;
    swipe(Point(hb.x + 300 - 52, hb.y + hb.h / 2), 30);
    assert(t.width(0) == 330 && t.scrolledX == 52, "the header keeps sideways drags");
}
