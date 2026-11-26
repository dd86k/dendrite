/// Combo box: a field showing the chosen item and a drop-down list of the items, or a text box with a list
/// filtered by what is typed.
///
/// Focus stays in the field while the list is open and the field moves the list's highlight, so an editable
/// box keeps its caret. The list is a virtual list, so long item lists cost only the rows in view.
module dentrite.widgets.combobox;

import core.time : MonoTime, msecs;
import dentrite.containers : CrossAlign, Panel, ScrollStyle, ScrollView;
import dentrite.immediate : Id, Press, Ui;
import dentrite.node;
import dentrite.overlay;
import dentrite.signals;
import dentrite.text;
import dentrite.widgets.button : ButtonState, ButtonStyle, paintButton;
import dentrite.widgets.icons;
import dentrite.widgets.list : VirtualList, virtualList;
import dentrite.widgets.menu : MenuStyle;
import dentrite.widgets.textbox : TextBox, TextBoxStyle;
import std.algorithm.comparison : clamp, max, min;
import std.math : ceil, isNaN, round;

/// Look of combo boxes. The field is a button of the box's variant, or a text box when editable. List rows
/// look like menu items, and the list body is the `popup` panel variant.
struct ComboBoxStyle
{
    enum section = "combobox"; /// section name in theme files

    Color arrow; /// drop-down arrow, the text color when transparent
    Color placeholder = Color(0x78, 0x78, 0x80, 0xff); /// hint when nothing is chosen
    float arrowSize = 8; /// size of the drop-down arrow
    float gap = 6;       /// space between the text and the arrow
    float minWidth = 80; /// narrowest field
    int maxRows = 12;    /// rows shown before the list scrolls
    int typeAhead = 1000; /// milliseconds between typed letters that still extend one search prefix
}

/// Labels measured for the natural width. NOTE: longer lists need a width from the parent.
enum size_t measureLimit = 1000;

/// Height of a list row in `t`.
private float rowHeight(Tree t)
{
    MenuStyle s = t.style!MenuStyle();
    return s.padY * 2 + t.text.lineHeight(s.font, s.size);
}

/// True if `a` and `b` are the same value: classes by identity, the rest by `==`, as signals compare.
private bool same(T)(T a, T b)
{
    static if (is(T == class) || is(T == interface))
    {
        return a is b;
    }
    else
    {
        return a == b;
    }
}

/// True if `text` starts with `prefix`, ignoring case.
private bool startsNoCase(string text, string prefix)
{
    import std.algorithm.searching : startsWith;
    import std.uni : toLower;

    return text.startsWith!((dchar a, dchar b) => toLower(a) == toLower(b))(prefix);
}

/// Widest label in one font, cached until the labels, the style or the scale change.
private struct Widest
{
    FontKind font;     /// font measured
    float size = 0;    /// size measured
    uint styleVersion; /// tree style version measured with
    float ppp = 0;     /// scale measured at
    float w = float.nan; /// widest label, NaN when stale
}

/// Row of the list, showing one item.
private final class ComboRow : Node
{
    private ComboList list; /// list holding it
    private size_t index;   /// item shown

    /// Row of `list` showing the item `item` returns, followed by an effect as pooled rows change items.
    this(ComboList list, size_t delegate() item)
    {
        this.list = list;
        interactive = true;
        effect(() {
            index = item();
            markNeedsPaint();
        });
    }

    /// Option named by its item.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.listBoxOption;
        a.label = index < list.labels.length ? list.labels[index] : null;
        a.selected = tri(list.chosen == index);
        a.allow(AccessAction.click);
    }

    /// Click chooses the item.
    override bool accessAction(ref const AccessRequest r)
    {
        if (r.action != AccessAction.click || index >= list.labels.length)
        {
            return false;
        }
        list.pick(index);
        return true;
    }

    /// As wide as the list, one line tall.
    protected override Size performLayout(Constraints c)
    {
        return Size(c.maxW, rowHeight(tree));
    }

    /// Highlight, check mark on the chosen item, and the label.
    override void paint(ref PaintContext ctx, Point origin)
    {
        if (index >= list.labels.length)
        {
            return;
        }
        MenuStyle s = ctx.style!MenuStyle();
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        bool hot = list.hotIndex == index;
        if (hot)
        {
            ctx.list.rect(r, s.highlight, s.radius);
        }
        Color ink = hot ? s.highlightText : s.text;
        if (index == list.chosen)
        {
            float k = s.iconSize;
            Rect box = Rect(r.x + s.padX + round((s.gutter - k) / 2), r.y + round((r.h - k) / 2), k, k);
            paintIcon(*ctx.list, Icon.check, box, ink);
        }
        TextSystem t = ctx.text;
        float base = r.y + round((r.h - t.lineHeight(s.font, s.size)) / 2) + t.ascent(s.font, s.size);
        float x = r.x + s.padX + s.gutter;
        string label = list.labels[index];
        ctx.clipped(Rect(x, r.y, max(0f, r.right - s.padX - x), r.h), {
            ctx.list.text(t.shape(s.font, s.size, label), Point(x, base), ink);
        });
    }

    /// The pointer highlights, a release over the row picks it.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.move:
            list.hoverRow(index);
            return true;
        case PointerKind.down:
            return e.button == 1;
        case PointerKind.up:
            if (e.button == 1 && hovered)
            {
                list.pick(index);
            }
            return true;
        default:
            return false;
        }
    }
}

/// Sizes the list: as wide as the field or the widest label, as tall as the rows up to `maxRows`.
private final class DropBody : Node
{
    private ComboList list; /// list holding it

    /// Body around the scroll view of the rows.
    this(ComboList list, Node scroll)
    {
        this.list = list;
        add(scroll);
    }

    /// List of the items.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.listBox;
    }

    /// The scroll view at the list's size.
    protected override Size performLayout(Constraints c)
    {
        ComboBoxStyle cs = tree.style!ComboBoxStyle();
        size_t rows = max(1, cs.maxRows);
        size_t n = list.shown.length;
        float h = min(min(n, rows) * rowHeight(tree), c.maxH);
        float w = min(max(c.minW, list.listWidth(tree, n > rows)), c.maxW);
        children[0].offset = Point.init;
        children[0].layout(Constraints.tight(Size(w, h)));
        return Size(w, h);
    }
}

/// Typed letters that add up to a prefix, for choosing items by their label.
private struct TypeAhead
{
    string prefix; /// letters typed so far, lowercase
    MonoTime at;   /// time of the last letter

    /// True while a letter typed at `now` still adds to the prefix, `window` milliseconds after the last.
    bool typing(MonoTime now, int window) const
    {
        return prefix.length > 0 && now - at <= msecs(window);
    }

    /// Adds `key` typed at `now` and returns the position in `list` of the next item whose label starts with the
    /// prefix, counting from position `cur`, or -1. Repeating one letter steps through the items starting with it.
    ptrdiff_t next(uint key, MonoTime now, int window, const string[] labels, const size_t[] list, ptrdiff_t cur)
    {
        import std.algorithm.searching : count;
        import std.uni : toLower;
        import std.utf : encode;

        if (now - at > msecs(window))
        {
            prefix = null;
        }
        at = now;
        char[4] buf;
        size_t len = encode(buf, toLower(cast(dchar) key));
        prefix ~= buf[0 .. len];
        bool repeat = prefix.count(prefix[0]) == prefix.length;
        string want = repeat ? prefix[0 .. len] : prefix;
        if (list.length == 0)
        {
            return -1;
        }
        size_t from = repeat || cur < 0 ? cur + 1 : cur;
        foreach (size_t k; 0 .. list.length)
        {
            size_t p = (from + k) % list.length;
            if (startsNoCase(labels[list[p]], want))
            {
                return p;
            }
        }
        return -1;
    }
}

/// Widest of `labels` in `t` for `font` at `fontSize`, measuring at most `measureLimit` labels, cached in `c`.
private float widest(ref Widest c, Tree t, const string[] labels, FontKind font, float fontSize)
{
    if (isNaN(c.w) || c.font != font || c.size != fontSize || c.styleVersion != t.styleVersion || c.ppp != t.ppp)
    {
        c = Widest(font, fontSize, t.styleVersion, t.ppp, 0);
        foreach (string l; labels[0 .. min($, measureLimit)])
        {
            c.w = max(c.w, t.text.measure(font, fontSize, l));
        }
    }
    return c.w;
}

/// Space at the right end of a field for the arrow, from the field edge.
private float arrowZone(const ref ComboBoxStyle cs, float padX)
{
    return padX + cs.arrowSize + cs.gap;
}

/// Widest of `labels` and `placeholder` in `t` for `font` at `fontSize`, the labels cached in `c`.
private float fieldText(ref Widest c, Tree t, const string[] labels, string placeholder, FontKind font,
    float fontSize)
{
    float w = widest(c, t, labels, font, fontSize);
    return placeholder.length > 0 ? max(w, t.text.measure(font, fontSize, placeholder)) : w;
}

/// Natural size of a field without a text box, for text `textW` wide.
private Size fieldNatural(Tree t, const ref ButtonStyle bs, const ref ComboBoxStyle cs, float textW)
{
    float h = bs.padY * 2 + max(t.text.lineHeight(bs.font, bs.size), cs.arrowSize);
    float w = max(max(cs.minWidth, bs.minWidth), ceil(textW + bs.padX + arrowZone(cs, bs.padX)));
    return Size(w, h);
}

/// Paints a field without a text box: a button showing `text`, dimmed if it is the `placeholder`, and the arrow.
private void paintField(ref PaintContext ctx, Rect r, const ref ButtonStyle bs, const ref ComboBoxStyle cs,
    string text, bool placeholder, ButtonState st)
{
    paintButton(ctx, r, bs, null, Icon.none, st);
    Color ink = st.enabled ? bs.text : bs.textDisabled;
    TextSystem t = ctx.text;
    float base = r.y + round((r.h - t.lineHeight(bs.font, bs.size)) / 2) + t.ascent(bs.font, bs.size);
    Color tc = placeholder == false || st.enabled == false ? ink : cs.placeholder;
    Rect inner = Rect(r.x + bs.padX, r.y, max(0f, r.w - bs.padX - arrowZone(cs, bs.padX)), r.h);
    if (text.length > 0)
    {
        ctx.clipped(inner, { ctx.list.text(t.shape(bs.font, bs.size, text), Point(inner.x, base), tc); });
    }
    float a = cs.arrowSize;
    Color ac = st.enabled == false ? bs.textDisabled : cs.arrow.a > 0 ? cs.arrow : ink;
    paintIcon(*ctx.list, Icon.chevronDown, Rect(r.right - bs.padX - a, r.y + round((r.h - a) / 2), a, a), ac);
}

/// Drop-down list of a combo box: a popup of rows looking like menu items, with the chosen item checked and a
/// highlight that keys and the pointer move. The retained and island combo boxes each own one. Positions count
/// rows of the list, indices count items.
private final class ComboList
{
    Popup popup;                        /// popup holding the rows
    void delegate(size_t index) onPick; /// a row was released on or clicked by an assistive technology
    void delegate() onClose;            /// runs after closing

    private string[] labels;            /// item labels
    private ptrdiff_t chosen = -1;      /// chosen item, or -1
    private size_t[] shown;             /// items in the list, ascending
    private Signal!(size_t[]) shownSignal; /// `shown`, read by the virtual list
    private ptrdiff_t hot = -1;         /// highlighted position, or -1
    private ScrollView scroller;        /// scrolls the rows
    private DropBody body_;             /// sizes the list
    private VirtualList!(size_t, size_t) rows; /// rows in view
    private Widest rowWidest;           /// widest label in the row font

    /// Closed empty list, as wide as what it opens next to. Its effects belong to the current owner.
    this()
    {
        shownSignal = signal!(size_t[])(null);
        rows = virtualList!(size_t, size_t)(&shownSignal.get, (size_t i) => i,
            (size_t delegate() item) => new ComboRow(this, item));
        scroller = new ScrollView(rows, false);
        body_ = new DropBody(this, scroller);
        popup = new Popup(new Panel("popup", body_));
        popup.align_ = CrossAlign.stretch;
        popup.focus = false;
        popup.keepFocus = true;
        popup.onClose = &closed;
    }

    /// True while open.
    bool isOpen()
    {
        return popup.isOpen;
    }

    /// Closes the popup.
    void close()
    {
        popup.close();
    }

    /// Takes new item labels, then `setShown` should follow. Equal labels keep the measured width.
    void setLabels(string[] labels)
    {
        if (labels == this.labels)
        {
            return;
        }
        this.labels = labels;
        rowWidest.w = float.nan;
        body_.markNeedsLayout();
        repaintRows();
    }

    /// Marks item `at` chosen, -1 for none.
    void setChosen(ptrdiff_t at)
    {
        if (at != chosen)
        {
            chosen = at;
            repaintRows();
        }
    }

    /// Shows `items`, ascending, keeping the highlight inside them.
    void setShown(size_t[] items)
    {
        shown = items;
        shownSignal.set(items);
        body_.markNeedsLayout();
        hot = min(hot, cast(ptrdiff_t) items.length - 1);
    }

    /// Highlights position `at`, or nothing for -1, scrolled to the middle of the view. Comes before opening, with
    /// the window's tree `t`.
    void reset(Tree t, ptrdiff_t at)
    {
        hot = at;
        float rowH = rowHeight(t);
        float view = min(shown.length, cast(size_t) max(1, t.style!ComboBoxStyle().maxRows)) * rowH;
        scroller.scrollY = hot < 0 ? 0 : max(0f, hot * rowH - round((view - rowH) / 2));
        scroller.markNeedsLayout();
        repaintRows();
    }

    /// Item highlighted, or `size_t.max`.
    size_t hotIndex()
    {
        return hot >= 0 && hot < shown.length ? shown[hot] : size_t.max;
    }

    /// Position of item `index`, or -1.
    ptrdiff_t positionOf(size_t index)
    {
        import std.range : assumeSorted;

        size_t p = assumeSorted(shown).lowerBound(index).length;
        return p < shown.length && shown[p] == index ? p : -1;
    }

    /// Highlights position `pos`, clamped into the list, and scrolls it into view once open.
    void moveHot(ptrdiff_t pos)
    {
        if (shown.length == 0)
        {
            return;
        }
        hot = clamp(pos, 0, cast(ptrdiff_t) shown.length - 1);
        repaintRows();
        if (popup.tree !is null)
        {
            float rowH = rowHeight(popup.tree);
            scroller.reveal(Rect(0, hot * rowH, scroller.size.w, rowH));
        }
    }

    /// Moves the highlight on Down, Up, Page Down and Page Up, and on Home and End if `homeEnd`. True if taken.
    bool navigate(ref const KeyEvent e, bool homeEnd)
    {
        if (e.mods != 0 || popup.tree is null)
        {
            return false;
        }
        ptrdiff_t last = cast(ptrdiff_t) shown.length - 1;
        ptrdiff_t page = max(1, cast(ptrdiff_t) (scroller.size.h / rowHeight(popup.tree)) - 1);
        switch (e.key)
        {
        case Key.down:
            moveHot(hot < 0 ? 0 : hot + 1);
            return true;
        case Key.up:
            moveHot(hot < 0 ? last : hot - 1);
            return true;
        case Key.pageDown:
            moveHot(max(hot, 0) + page);
            return true;
        case Key.pageUp:
            moveHot(hot - page);
            return true;
        case Key.home:
        case Key.end:
            if (homeEnd == false)
            {
                return false;
            }
            moveHot(e.key == Key.home ? 0 : last);
            return true;
        default:
            return false;
        }
    }

    /// Repaints the rows in view, after the highlight, the choice or the labels changed.
    private void repaintRows()
    {
        foreach (Node r; rows.children)
        {
            r.markNeedsPaint();
        }
    }

    /// Pointer over the row of item `index`.
    private void hoverRow(size_t index)
    {
        ptrdiff_t p = positionOf(index);
        if (p != hot)
        {
            hot = p;
            repaintRows();
        }
    }

    /// Tells the owner that the row of item `index` was picked.
    private void pick(size_t index)
    {
        if (onPick !is null)
        {
            onPick(index);
        }
    }

    /// Width the list needs in `t` for its labels, with room for the scroll bar if it `scrolls`.
    private float listWidth(Tree t, bool scrolls)
    {
        MenuStyle s = t.style!MenuStyle();
        float w = ceil(widest(rowWidest, t, labels, s.font, s.size) + s.padX * 2 + s.gutter);
        if (scrolls)
        {
            w += t.style!ScrollStyle().width + 2;
        }
        return w;
    }

    /// Clears the highlight and tells the owner once the popup closed.
    private void closed()
    {
        hot = -1;
        if (onClose !is null)
        {
            onClose();
        }
    }
}

/// Text box of an editable combo box. The box sees keys before the text box, and edits filter the list.
private final class ComboEdit : TextBox
{
    private ComboBox combo; /// box holding it

    /// Text box over `value` inside `combo`.
    this(ComboBox combo, Signal!string value, string placeholder)
    {
        super(value, placeholder);
        this.combo = combo;
    }

    /// The box's keys, then editing keys. Edits filter the list.
    override bool onKey(ref const KeyEvent e)
    {
        if (combo.enabled == false)
        {
            return false;
        }
        if (combo.fieldKey(e))
        {
            return true;
        }
        string before = text;
        bool took = super.onKey(e);
        if (text != before)
        {
            combo.edited();
        }
        return took;
    }

    /// Typed text, which filters the list.
    override bool onText(string s)
    {
        if (combo.enabled == false)
        {
            return false;
        }
        string before = text;
        bool took = super.onText(s);
        if (text != before)
        {
            combo.edited();
        }
        return took;
    }

    /// Ignores the pointer while the box is disabled.
    override bool onPointer(ref const PointerEvent e)
    {
        return combo.enabled && super.onPointer(e);
    }

    /// Tells the box, which settles the text when focus leaves.
    override void onFocus(bool gained)
    {
        super.onFocus(gained);
        combo.editFocus(gained);
    }
}

/// Field showing the chosen item and opening a list of the items. Build it with `comboBox`, which binds it to a
/// signal. Item indices refer to the labels given to `setItems`.
final class ComboBox : Node
{
    void delegate(size_t index) onChoose; /// runs when the user chooses item `index`
    void delegate(string text) onType;    /// runs when the user edits the text, set when the text is the value
    string placeholder;  /// hint when nothing is chosen
    string variant;      /// ButtonStyle variant of the field
    bool enabled = true; /// opens and takes input

    private string[] labels;       /// item labels
    private size_t[] indices;      /// every item index, in order
    private ptrdiff_t chosen = -1; /// chosen item, or -1
    private ComboList list;        /// the drop-down list, showing all items or those matching the text
    private ComboEdit edit;        /// text box of an editable box, or null
    private Signal!string editText; /// text of `edit`
    private bool filtering;        /// text typed since the last pick, so the list shows matches only
    private TypeAhead ahead;       /// type-ahead letters
    private Widest fieldWidest;    /// widest label in the field font

    /// Empty box, with a text box if `editable`. The list's effects belong to the current owner.
    this(bool editable, string placeholder, string variant)
    {
        this.placeholder = placeholder;
        this.variant = variant;
        interactive = true;
        list = new ComboList;
        list.popup.anchor = this;
        list.popup.source = this;
        list.onPick = &pick;
        list.onClose = &closed;
        if (editable)
        {
            editText = signal("");
            edit = new ComboEdit(this, editText, placeholder);
            add(edit);
            keepFocus = true;
        }
        else
        {
            focusable = true;
        }
    }

    /// True while the list is open.
    bool isOpen()
    {
        return list.isOpen;
    }

    /// Chosen item, or -1.
    ptrdiff_t chosenIndex() const
    {
        return chosen;
    }

    /// Text of an editable box, else the chosen label or empty.
    string text()
    {
        if (edit !is null)
        {
            return edit.text;
        }
        return chosen >= 0 ? labels[chosen] : null;
    }

    /// Takes new item labels. An open list follows them.
    void setItems(string[] labels)
    {
        import std.array : array;
        import std.range : iota;

        this.labels = labels;
        indices = iota(labels.length).array;
        fieldWidest.w = float.nan;
        list.setLabels(labels);
        if (chosen >= cast(ptrdiff_t) labels.length)
        {
            chosen = -1;
            list.setChosen(-1);
        }
        markNeedsLayout();
        markNeedsPaint();
        if (list.isOpen)
        {
            refilter();
            if (list.shown.length == 0)
            {
                close();
            }
        }
    }

    /// Marks item `at` chosen, -1 for none. An editable box whose text is not the value shows its label,
    /// unless the user is typing.
    void setChosen(ptrdiff_t at)
    {
        if (at != chosen)
        {
            chosen = at;
            markNeedsPaint();
            list.setChosen(at);
        }
        if (edit !is null && onType is null && filtering == false)
        {
            setText(at >= 0 ? labels[at] : "");
        }
    }

    /// Sets the text of an editable box, with the caret at the end.
    void setText(string s)
    {
        if (edit is null || editText.peek == s)
        {
            return;
        }
        editText.set(s);
        edit.caret = edit.anchor = s.length;
    }

    /// Enables or disables. A disabled box closes its list.
    void setEnabled(bool on)
    {
        if (on == enabled)
        {
            return;
        }
        enabled = on;
        if (on == false)
        {
            close();
        }
        if (edit !is null)
        {
            edit.setEnabled(on);
        }
        markNeedsPaint();
    }

    /// Opens the list with the chosen item highlighted and in view. Does nothing when disabled.
    void open()
    {
        filtering = false;
        openList(true);
    }

    /// Closes the list.
    void close()
    {
        list.close();
    }

    /// Combo box showing its text, open while the list is. An editable box's field stays out.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.comboBox;
        a.value = text();
        a.placeholder = placeholder;
        a.expanded = tri(list.isOpen);
        a.disabled = enabled == false;
        a.leaf = true;
        a.allow(AccessAction.click);
        a.allow(list.isOpen ? AccessAction.collapse : AccessAction.expand);
        if (edit !is null)
        {
            a.allow(AccessAction.focus);
        }
    }

    /// Click and expand open the list, click and collapse close it. Focus goes to the field of an editable box.
    override bool accessAction(ref const AccessRequest r)
    {
        if (enabled == false)
        {
            return false;
        }
        switch (r.action)
        {
        case AccessAction.click:
            if (list.isOpen)
            {
                close();
            }
            else
            {
                open();
            }
            return true;
        case AccessAction.expand:
            open();
            return true;
        case AccessAction.collapse:
            close();
            return true;
        case AccessAction.focus:
            if (edit is null || tree.services is null)
            {
                return false;
            }
            tree.services.setFocus(edit);
            return true;
        default:
            return false;
        }
    }

    /// Fills `shown`: the items whose label contains the typed text, or all of them.
    private void refilter()
    {
        import std.string : CaseSensitive, indexOf;

        size_t[] next = indices;
        if (filtering && edit !is null && edit.text.length > 0)
        {
            next = null;
            string want = edit.text;
            foreach (size_t i, string l; labels)
            {
                if (indexOf(l, want, CaseSensitive.no) >= 0)
                {
                    next ~= i;
                }
            }
        }
        list.setShown(next);
    }

    /// Opens or updates the list. `showChosen` highlights the chosen item, else an editable box whose text is not
    /// the value highlights the first match. Closes when nothing matches.
    private void openList(bool showChosen)
    {
        if (enabled == false || tree is null)
        {
            return;
        }
        refilter();
        if (list.shown.length == 0)
        {
            close();
            return;
        }
        list.reset(tree, showChosen ? (chosen >= 0 ? list.positionOf(chosen) : -1) : onType is null ? 0 : -1);
        if (list.isOpen == false)
        {
            list.popup.open();
        }
        markNeedsPaint();
    }

    /// Chooses item `index` from the list and closes it.
    private void pick(size_t index)
    {
        filtering = false;
        close();
        setText(labels[index]);
        choose(index);
    }

    /// Tells the owner that item `index` was chosen.
    private void choose(size_t index)
    {
        if (onChoose !is null)
        {
            onChoose(index);
        }
    }

    /// The text box's text changed: an editable box whose text is the value writes it, and the list shows the
    /// matching items. Emptied text closes the list.
    private void edited()
    {
        filtering = true;
        if (onType !is null)
        {
            onType(edit.text);
        }
        if (edit.text.length == 0)
        {
            close();
            return;
        }
        openList(false);
    }

    /// Focus left or entered the text box. Leaving closes the list and settles the text.
    private void editFocus(bool gained)
    {
        if (gained == false)
        {
            close();
            settleText();
        }
    }

    /// For editable boxes whose text is not the value: chooses the item labelled with the text, ignoring case,
    /// or shows the chosen label again. False if the text was already the chosen label.
    private bool settleText()
    {
        import std.uni : icmp;

        if (edit is null || onType !is null)
        {
            return false;
        }
        filtering = false;
        string before = edit.text;
        string after = chosen >= 0 ? labels[chosen] : "";
        foreach (size_t i, string l; labels)
        {
            if (icmp(l, before) == 0)
            {
                after = l;
                if (i != chosen)
                {
                    choose(i);
                }
                break;
            }
        }
        setText(after);
        return before != after;
    }

    /// Adds `key` to the typed prefix and moves to the next item starting with it: the highlight while open,
    /// the choice while closed. Repeating one letter steps through the items starting with it.
    private void typeAhead(uint key)
    {
        MonoTime now = tree.services is null ? MonoTime.currTime : tree.services.now;
        int window = tree.style!ComboBoxStyle().typeAhead;
        bool open = list.isOpen;
        size_t[] items = open ? list.shown : indices;
        ptrdiff_t p = ahead.next(key, now, window, labels, items, open ? list.hot : chosen);
        if (p < 0)
        {
            return;
        }
        if (open)
        {
            list.moveHot(p);
        }
        else
        {
            choose(items[p]);
        }
    }

    /// True while typed letters still add up to one prefix.
    private bool typing()
    {
        MonoTime now = tree.services is null ? MonoTime.currTime : tree.services.now;
        return ahead.typing(now, tree.style!ComboBoxStyle().typeAhead);
    }

    /// Keys of the field. Alt+Down and F4 open, Alt+Up closes. While open: arrows, Page Up and Down move the
    /// highlight, Enter picks it, Escape closes, Tab closes and moves on. While closed, a box without a text
    /// box chooses with the arrows, Home, End and letters, and Space opens. True if taken.
    private bool fieldKey(ref const KeyEvent e)
    {
        if (enabled == false)
        {
            return false;
        }
        bool open = list.isOpen;
        if ((e.key == Key.down && e.mods == Mod.alt) || (e.key == Key.f4 && e.mods == 0))
        {
            if (open)
            {
                close();
            }
            else
            {
                filtering = false;
                openList(true);
            }
            return true;
        }
        if (e.key == Key.up && e.mods == Mod.alt)
        {
            close();
            return open;
        }
        if (e.key == Key.tab)
        {
            close();
            return false;
        }
        if (open)
        {
            return listKey(e);
        }
        return edit is null ? closedKey(e) : closedEditKey(e);
    }

    /// Keys while the list is open.
    private bool listKey(ref const KeyEvent e)
    {
        if (list.navigate(e, edit is null))
        {
            return true;
        }
        if (e.mods == 0)
        {
            switch (e.key)
            {
            case Key.enter:
                if (list.hot >= 0)
                {
                    pick(list.shown[list.hot]);
                }
                else
                {
                    close();
                    settleText();
                }
                return true;
            case Key.escape:
                close();
                return true;
            default:
                break;
            }
        }
        if (edit is null && (e.mods & (Mod.ctrl | Mod.alt | Mod.gui)) == 0)
        {
            if (e.key == Key.space && typing == false)
            {
                if (list.hot >= 0)
                {
                    pick(list.shown[list.hot]);
                }
                return true;
            }
            if (e.key >= Key.space && e.key < 0x40000000)
            {
                typeAhead(e.key);
                return true;
            }
        }
        return false;
    }

    /// Keys of a closed box without a text box.
    private bool closedKey(ref const KeyEvent e)
    {
        if ((e.mods & (Mod.ctrl | Mod.alt | Mod.gui)) != 0)
        {
            return false;
        }
        ptrdiff_t last = cast(ptrdiff_t) labels.length - 1;
        if (e.mods == 0)
        {
            switch (e.key)
            {
            case Key.down:
            case Key.up:
            case Key.home:
            case Key.end:
                if (last < 0)
                {
                    return true;
                }
                ptrdiff_t to = e.key == Key.home ? 0 : e.key == Key.end ? last
                    : chosen < 0 ? 0 : chosen + (e.key == Key.down ? 1 : -1);
                to = clamp(to, 0, last);
                if (to != chosen)
                {
                    choose(to);
                }
                return true;
            case Key.space:
                if (typing == false)
                {
                    open();
                    return true;
                }
                break;
            default:
                break;
            }
        }
        if (e.key >= Key.space && e.key < 0x40000000)
        {
            typeAhead(e.key);
            return true;
        }
        return false;
    }

    /// Keys of a closed editable box: Down and Up open the list, Escape puts back the chosen label, and Enter
    /// settles the text and goes on to the parents.
    private bool closedEditKey(ref const KeyEvent e)
    {
        if (e.mods != 0)
        {
            return false;
        }
        switch (e.key)
        {
        case Key.down:
        case Key.up:
            openList(true);
            if (list.hot < 0)
            {
                list.moveHot(e.key == Key.down ? 0 : cast(ptrdiff_t) list.shown.length - 1);
            }
            return true;
        case Key.escape:
            return settleText();
        case Key.enter:
            settleText();
            return false;
        default:
            return false;
        }
    }

    /// Clears the typed prefix once the list closed.
    private void closed()
    {
        ahead.prefix = null;
        markNeedsPaint();
    }

    /// Field size: a width from the parent, else wide enough for the widest label and the placeholder.
    protected override Size performLayout(Constraints c)
    {
        ComboBoxStyle cs = tree.style!ComboBoxStyle();
        bool free = c.minW != c.maxW;
        if (edit is null)
        {
            ButtonStyle bs = tree.style!ButtonStyle(variant);
            float textW = free ? fieldText(fieldWidest, tree, labels, placeholder, bs.font, bs.size) : 0;
            Size n = fieldNatural(tree, bs, cs, textW);
            return c.constrain(Size(free ? n.w : c.minW, n.h));
        }
        TextBoxStyle ts = tree.style!TextBoxStyle();
        float w = c.minW;
        if (free)
        {
            float textW = fieldText(fieldWidest, tree, labels, placeholder, ts.font, ts.size);
            w = max(cs.minWidth, ceil(textW + ts.padX + arrowZone(cs, ts.padX)));
        }
        Size s = c.constrain(Size(w, tree.text.lineHeight(ts.font, ts.size) + ts.padY * 2));
        edit.trailing = cs.arrowSize + cs.gap;
        edit.offset = Point.init;
        edit.layout(Constraints.tight(s));
        return s;
    }

    /// A button with the chosen label and an arrow, or the text box with an arrow.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ComboBoxStyle cs = ctx.style!ComboBoxStyle();
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        float a = cs.arrowSize;
        if (edit !is null)
        {
            paintChildren(ctx, origin);
            TextBoxStyle ts = ctx.style!TextBoxStyle();
            Color ac = enabled == false ? ts.placeholder : cs.arrow.a > 0 ? cs.arrow : ts.text;
            paintIcon(*ctx.list, Icon.chevronDown, Rect(r.right - ts.padX - a, r.y + round((r.h - a) / 2), a, a), ac);
            return;
        }
        ButtonStyle bs = ctx.style!ButtonStyle(variant);
        string text = chosen >= 0 ? labels[chosen] : placeholder;
        paintField(ctx, r, bs, cs, text, chosen < 0, ButtonState(hovered || list.isOpen, false, enabled, focusRing));
    }

    /// The arrow of an editable box belongs to the box, the rest to the text box.
    override Node hitTest(Point p, Point origin)
    {
        if (edit !is null && tree !is null)
        {
            ComboBoxStyle cs = tree.style!ComboBoxStyle();
            float zone = arrowZone(cs, tree.style!TextBoxStyle().padX);
            if (Rect(origin.x + size.w - zone, origin.y, zone, size.h).contains(p))
            {
                return this;
            }
        }
        return super.hitTest(p, origin);
    }

    /// A press opens or closes the list, showing every item, and a drag from it to a row and release picks the row.
    /// On an editable box it also focuses the text.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.leave:
            markNeedsPaint();
            return true;
        case PointerKind.down:
            if (e.button != 1 || enabled == false)
            {
                return false;
            }
            if (edit !is null && tree.services !is null)
            {
                tree.services.setFocus(edit);
            }
            if (list.isOpen)
            {
                close();
            }
            else
            {
                open();
                if (tree.services !is null)
                {
                    tree.services.slidePress();
                }
            }
            return true;
        case PointerKind.up:
            return true;
        default:
            return false;
        }
    }

    /// Handles keys for a box that is not editable, which has no text box.
    override bool onKey(ref const KeyEvent e)
    {
        return edit is null && fieldKey(e);
    }

    /// Focus ring changes, and losing focus closes the list.
    override void onFocus(bool gained)
    {
        markNeedsPaint();
        if (gained == false)
        {
            close();
        }
    }
}

/// Combo box choosing `value` among `items`: `comboBox(&targets.get, target, label: (Target t) => t.name)`.
/// The field shows the chosen item's label, or `placeholder` when the value is not one of the items. `label`
/// defaults to `to!string`.
///
/// `editable` puts a text box in the field, and typing shows the items whose label contains the text. With
/// strings the text is the value and the items are suggestions. With other types, Enter or leaving chooses the
/// item labelled with the text, or puts back the chosen label. The effects belong to the current owner.
/// NOTE: the natural width measures the first `measureLimit` labels, so give longer lists a width.
ComboBox comboBox(T)(T[] delegate() items, Signal!T value, string delegate(T) label = null, bool editable = false,
    string placeholder = null, string variant = null, bool delegate() enabled = null, string tooltip = null,
    string accessName = null)
{
    import std.conv : to;

    string delegate(T) name = label !is null ? label : (T x) => x.to!string;
    ComboBox c = new ComboBox(editable, placeholder, variant);
    c.setTooltip(tooltip);
    c.accessName = accessName;
    T[] current;
    Signal!uint version_ = signal(0u);
    c.onChoose = (size_t i) { value.set(current[i]); };
    static if (is(T == string))
    {
        if (editable)
        {
            c.onType = (string s) { value.set(s); };
        }
    }
    effect(() {
        current = items();
        string[] labels = new string[current.length];
        foreach (size_t i, T x; current)
        {
            labels[i] = name(x);
        }
        c.setItems(labels);
        version_.set(version_.peek + 1);
    });
    effect(() {
        version_.get;
        T v = value.get;
        ptrdiff_t at = -1;
        foreach (size_t i, T x; current)
        {
            if (same(x, v))
            {
                at = i;
                break;
            }
        }
        c.setChosen(at);
        static if (is(T == string))
        {
            if (editable)
            {
                c.setText(v);
            }
        }
    });
    if (enabled !is null)
    {
        effect(() { c.setEnabled(enabled()); });
    }
    return c;
}

/// Combo box over fixed `items`: `comboBox(["Debug", "Release"], config)`.
ComboBox comboBox(T)(T[] items, Signal!T value, string delegate(T) label = null, bool editable = false,
    string placeholder = null, string variant = null, bool delegate() enabled = null, string tooltip = null,
    string accessName = null)
{
    T[] fixed = items;
    return comboBox!T(() => fixed, value, label, editable, placeholder, variant, enabled, tooltip, accessName);
}

/// Combo box over the members of enum `E`: `comboBox(renderer)`.
ComboBox comboBox(E)(Signal!E value, string delegate(E) label = null, string placeholder = null,
    string variant = null, bool delegate() enabled = null, string tooltip = null,
    string accessName = null)
if (is(E == enum))
{
    import std.traits : EnumMembers;

    return comboBox!E([EnumMembers!E], value, label, false, placeholder, variant, enabled, tooltip, accessName);
}

/// Field of an island combo box, sized and painted as the retained one.
private final class ComboField : Node
{
    string text;        /// chosen label or the placeholder
    bool isPlaceholder; /// `text` is the placeholder
    float textW = 0;    /// widest label or placeholder
    bool open;          /// the list is open
    ButtonStyle bs;     /// resolved look of the field
    ComboBoxStyle cs;   /// resolved look of the arrow
    ButtonState state;  /// interaction state from last pass's rects

    /// Combo box showing its text, open while the list is.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.comboBox;
        a.value = isPlaceholder ? null : text;
        a.placeholder = isPlaceholder ? text : null;
        a.expanded = tri(open);
        a.disabled = state.enabled == false;
        a.leaf = true;
        a.allow(AccessAction.click);
    }

    /// A width from the parent, else wide enough for the widest label and the placeholder.
    protected override Size performLayout(Constraints c)
    {
        Size n = fieldNatural(tree, bs, cs, textW);
        return c.constrain(Size(c.minW != c.maxW ? n.w : c.minW, n.h));
    }

    /// A button with the text and an arrow.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintField(ctx, Rect(origin.x, origin.y, size.w, size.h), bs, cs, text, isPlaceholder, state);
    }
}

/// Retained part of an island combo box, in the island's memory.
private struct IslandCombo
{
    ComboList list;        /// the drop-down list
    Scope owner;           /// owns the list's effects
    string[] labels;       /// copy of the labels the list shows
    size_t[] all;          /// every item index
    TypeAhead ahead;       /// typed letters
    Widest fieldWidest;    /// widest label in the field font
    ptrdiff_t picked = -1; /// item picked in the list since the last pass, or -1

    /// Closes the list and drops its effects once a pass skips the box.
    void dropped()
    {
        list.close();
        owner.dispose();
    }
}

/// Makes the list of `st`, owned by nothing outside it. A pick or a close asks `ui` for a pass.
private void startCombo(IslandCombo* st, Ui ui)
{
    runWithOwner(null, {
        st.owner = effectScope({ st.list = new ComboList; });
    });
    st.list.onPick = (size_t index) {
        st.picked = index;
        st.list.close();
    };
    st.list.onClose = () {
        if (ui.wake !is null)
        {
            ui.wake();
        }
    };
}

/// Island combo box choosing `chosen` among `items`, -1 for none, true on the pass the user changed it. A press,
/// Space, F4 or Alt+Down opens the list. Closed, arrows, Home, End and letters choose. Open, they move the
/// highlight, Enter or Space picks it and Escape closes. NOTE: islands have no editable combo box.
bool comboBox(Ui ui, string[] items, ref ptrdiff_t chosen, string placeholder = null, string variant = null,
    bool enabled = true, string accessName = null, string file = __FILE__, size_t line = __LINE__)
{
    import std.array : array;
    import std.range : iota;

    Id i = ui.id(file, line);
    IslandCombo* st = ui.memoryFor(i, IslandCombo.init);
    if (st.list is null)
    {
        startCombo(st, ui);
    }
    if (items != st.labels)
    {
        st.labels = items.dup;
        st.fieldWidest.w = float.nan;
        st.all = iota(items.length).array;
        ComboList l = st.list;
        string[] labels = st.labels;
        size_t[] all = st.all;
        runWithOwner(null, {
            l.setLabels(labels);
            l.setShown(all);
        });
    }
    ptrdiff_t at = chosen >= 0 && chosen < items.length ? chosen : -1;
    ptrdiff_t before = at;
    if (st.picked >= 0)
    {
        at = st.picked < items.length ? st.picked : at;
        st.picked = -1;
    }
    bool viaAccess = ui.accessClick == i;
    Press p = ui.clickable(i, enabled);
    bool focused = ui.focusStop(i, enabled);
    ComboList list = st.list;
    bool open = list.isOpen;
    bool wantOpen = open && focused && enabled;
    if (p.pressedNow || viaAccess)
    {
        wantOpen = open == false;
    }
    if (focused && enabled)
    {
        int window = ui.style!ComboBoxStyle().typeAhead;
        KeyEvent[] rest;
        foreach (KeyEvent e; ui.keys)
        {
            bool plain = (e.mods & (Mod.ctrl | Mod.alt | Mod.gui)) == 0;
            bool letter = plain && e.key >= Key.space && e.key < 0x40000000;
            bool space = e.key == Key.space && e.mods == 0 && st.ahead.typing(ui.now, window) == false;
            if ((e.key == Key.down && e.mods == Mod.alt) || (e.key == Key.f4 && e.mods == 0))
            {
                wantOpen = wantOpen == false;
            }
            else if (e.key == Key.up && e.mods == Mod.alt && wantOpen)
            {
                wantOpen = false;
            }
            else if (open && list.navigate(e, true))
            {
            }
            else if (open && ((e.key == Key.enter && e.mods == 0) || space))
            {
                at = list.hot >= 0 ? list.shown[list.hot] : at;
                wantOpen = false;
            }
            else if (open && e.key == Key.escape && e.mods == 0)
            {
                wantOpen = false;
            }
            else if (open == false && space)
            {
                wantOpen = true;
            }
            else if (open == false && e.mods == 0 && items.length > 0
                && (e.key == Key.down || e.key == Key.up || e.key == Key.home || e.key == Key.end))
            {
                ptrdiff_t last = cast(ptrdiff_t) items.length - 1;
                ptrdiff_t to = e.key == Key.home ? 0 : e.key == Key.end ? last
                    : at < 0 ? 0 : at + (e.key == Key.down ? 1 : -1);
                at = clamp(to, 0, last);
            }
            else if (letter)
            {
                ptrdiff_t found = st.ahead.next(e.key, ui.now, window, items, st.all, open ? list.hot : at);
                if (found >= 0 && open)
                {
                    list.moveHot(found);
                }
                else if (found >= 0)
                {
                    at = found;
                }
            }
            else
            {
                rest ~= e;
                continue;
            }
            ui.again = true;
        }
        ui.keys = rest;
    }
    list.setChosen(at);
    if (wantOpen && open == false && items.length > 0 && ui.window !is null)
    {
        Tree w = ui.window;
        runWithOwner(null, { list.reset(w, list.positionOf(at)); });
        ui.openPopup(i, list.popup);
    }
    else if (wantOpen == false && open)
    {
        runWithOwner(null, { list.close(); });
    }
    bool changed = at != before;
    if (changed)
    {
        chosen = at;
    }
    ComboField n = new ComboField;
    n.bs = ui.style!ButtonStyle(variant);
    n.cs = ui.style!ComboBoxStyle();
    n.text = at >= 0 ? items[at] : placeholder;
    n.isPlaceholder = at < 0;
    n.textW = fieldText(st.fieldWidest, ui.tree, items, placeholder, n.bs.font, n.bs.size);
    n.open = list.isOpen;
    n.state = ButtonState(p.hovered || n.open, false, enabled, ui.focusRing(i));
    n.accessName = accessName;
    ui.put(n);
    ui.track(n, i);
    return changed;
}

version (unittest)
{
    import dentrite.host : Host;

    /// Headless host with the test fonts, no hover delay and no type-ahead memory between frames.
    Host comboHost()
    {
        import dentrite.theme : Theme;
        import dentrite.widgets.menu : menuHost;

        Host h = menuHost(400, 500);
        h.tree.theme = new Theme("[menu]\nhoverDelay = 0\n[combobox]\ntypeAhead = 0\n"
            ~ "[panel.popup]\nborderWidth = 0\npadX = 0\n", "test");
        return h;
    }

    /// Presses and releases at window point `p`, then runs a frame.
    void clickAt(Host h, Point p)
    {
        h.inject(PointerKind.move, p);
        h.inject(PointerKind.down, p);
        h.inject(PointerKind.up, p);
        h.frame();
    }
}

// The field fits the widest label, the list opens below as wide as the field with the chosen item highlighted,
// a click on a row chooses it and closes with focus kept, a press on the field closes, and so does one outside.
unittest
{
    import dentrite.containers : column, CrossAlign;
    import dentrite.widgets.menu : clickOn;

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    Signal!string config = signal("Release");
    ComboBox c = comboBox(["Debug", "Release", "Release with debug info"], config);
    h.setRoot(column(cross: CrossAlign.start)(c));
    h.frame();
    ButtonStyle bs;
    ComboBoxStyle cs;
    float textW = h.tree.text.measure(bs.font, bs.size, "Release with debug info");
    assert(c.size.w == ceil(textW + bs.padX * 2 + cs.gap + cs.arrowSize));
    assert(c.chosenIndex == 1 && c.text == "Release");

    clickOn(h, c);
    assert(c.isOpen && h.focused is c && c.list.hotIndex == 1);
    assert(c.list.popup.bounds.y == c.bounds.bottom && c.list.popup.bounds.x == 0 && c.list.popup.bounds.w == c.size.w);
    assert(c.list.rows.children.length == 3 && c.list.scroller.size.h == 3 * rowHeight(h.tree));
    clickOn(h, c.list.rows[0]);
    assert(config.peek == "Debug" && c.isOpen == false && h.focused is c && c.text == "Debug");

    clickOn(h, c);
    assert(c.isOpen && c.list.hotIndex == 0);
    clickOn(h, c);
    assert(c.isOpen == false, "a press on the field closes");
    clickOn(h, c);
    clickAt(h, Point(390, 490));
    assert(c.isOpen == false && config.peek == "Debug");
}

// Drag: a press on the field opens the list, a release on a row picks it, a release on the field keeps the list
// open, and a release elsewhere closes it without choosing.
unittest
{
    import dentrite.containers : column, CrossAlign;
    import dentrite.widgets.menu : clickOn;

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    Signal!string config = signal("Release");
    ComboBox c = comboBox(["Debug", "Release", "Profile"], config);
    h.setRoot(column(cross: CrossAlign.start)(c));
    h.frame();

    /// Middle of `n`.
    Point mid(Node n)
    {
        return Point(n.bounds.x + n.bounds.w / 2, n.bounds.y + n.bounds.h / 2);
    }

    h.inject(PointerKind.move, mid(c));
    h.inject(PointerKind.down, mid(c));
    h.frame();
    assert(c.isOpen);
    Point row = mid(c.list.rows[2]);
    h.inject(PointerKind.move, row);
    h.frame();
    assert(c.list.hotIndex == 2, "held press highlights");
    h.inject(PointerKind.up, row);
    h.frame();
    assert(config.peek == "Profile" && c.isOpen == false, "release picked it");

    h.inject(PointerKind.down, mid(c));
    h.inject(PointerKind.move, row);
    h.inject(PointerKind.move, mid(c));
    h.inject(PointerKind.up, mid(c));
    h.frame();
    assert(c.isOpen && config.peek == "Profile", "release on the field keeps it open");
    clickOn(h, c);
    assert(c.isOpen == false);

    h.inject(PointerKind.down, mid(c));
    h.inject(PointerKind.move, Point(390, 490));
    h.inject(PointerKind.up, Point(390, 490));
    h.frame();
    assert(c.isOpen == false && config.peek == "Profile", "released outside");
}

// Island combo box: the field has the retained field's size, a press opens the list below it as wide with the
// chosen item highlighted and focus kept, a click on a row chooses it, closed keys choose, open keys move the
// highlight and Enter picks, F4 and Escape open and close, a press outside closes, and so does a pass without
// the box.
unittest
{
    import dentrite.containers : column, CrossAlign, sized;
    import dentrite.immediate : row;
    import dentrite.island : Island, island;
    import dentrite.overlay : Stage;
    import dentrite.widgets.menu : clickOn;

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    string[] items = ["Debug", "Release", "Profile"];
    ComboBox retained = comboBox(items, signal("Release"));
    ptrdiff_t chosen = 1;
    int changes;
    bool shown = true;
    Island isl = island((Ui ui) {
        ui.row()({
            if (shown && ui.comboBox(items, chosen))
            {
                ++changes;
            }
        });
    });
    h.setRoot(column(cross: CrossAlign.start)(retained, sized(h: 300)(isl)));
    h.frame();

    /// Field as last laid out.
    ComboField field()
    {
        return cast(ComboField) isl.ui.content.children[0].children[0];
    }

    /// List of the open popup.
    ComboList list()
    {
        Popup[] open = (cast(Stage) h.tree.root).popups;
        Node n = open.length > 0 ? open[$ - 1] : null;
        while (n !is null && cast(DropBody) n is null)
        {
            n = n.children.length > 0 ? n.children[0] : null;
        }
        return n is null ? null : (cast(DropBody) n).list;
    }

    void key(uint k, ubyte mods = 0)
    {
        h.injectKey(k, mods);
        h.frame();
    }

    assert(field.size == retained.size && field.text == "Release");
    clickOn(h, field);
    ComboList l = list();
    Rect f = field.bounds;
    assert(l !is null && l.isOpen && l.hotIndex == 1 && h.focused is isl && field.open);
    assert(l.popup.bounds.y == f.bottom && l.popup.bounds.x == f.x && l.popup.bounds.w == f.w);
    clickOn(h, l.rows[2]);
    assert(chosen == 2 && changes == 1 && l.isOpen == false && field.text == "Profile" && field.open == false);

    key(Key.up);
    assert(chosen == 1);
    key(Key.end);
    assert(chosen == 2);
    key(Key.home);
    assert(chosen == 0);
    key('p');
    assert(chosen == 2 && changes == 5, "type-ahead");
    key(Key.space);
    assert(l.isOpen && l.hotIndex == 2);
    key(Key.up);
    assert(l.hotIndex == 1 && chosen == 2, "the highlight moved, the value did not");
    key(Key.enter);
    assert(chosen == 1 && l.isOpen == false);
    key(Key.f4);
    assert(l.isOpen);
    key(Key.escape);
    assert(l.isOpen == false && chosen == 1 && h.focused is isl);

    clickOn(h, field);
    h.inject(PointerKind.move, Point(390, 490));
    h.frame();
    assert(l.isOpen);
    h.inject(PointerKind.down, Point(390, 490));
    h.inject(PointerKind.up, Point(390, 490));
    h.frame();
    assert(l.isOpen == false && field.open == false, "a press outside closes, and the field shows it");
    clickOn(h, field);
    key(Key.tab);
    assert(l.isOpen == false && h.focused is retained, "Tab closes and moves on");
    clickOn(h, field);
    h.setFocus(retained);
    h.frame();
    assert(l.isOpen == false, "losing focus closes");
    clickOn(h, field);
    shown = false;
    isl.invalidate();
    h.requestFrame();
    h.frame();
    assert(l.isOpen == false, "closed with the box gone");
}

// Keys: closed, arrows, Home, End and letters choose. Space, F4 and Alt+Down open with the chosen item
// highlighted, arrows move only the highlight, Enter picks it, Escape closes without choosing, Tab closes and
// moves on. Repeating a letter steps through the items starting with it.
unittest
{
    import dentrite.containers : column, CrossAlign;
    import dentrite.widgets.button : Button, button;

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    Signal!string fruit = signal("Banana");
    ComboBox c = comboBox(["Apple", "Apricot", "Banana", "Blueberry", "Cherry"], fruit);
    Button after = button("After");
    h.setRoot(column(cross: CrossAlign.start)(c, after));
    h.frame();
    h.setFocus(c);

    h.injectKey(Key.down);
    assert(fruit.peek == "Blueberry" && c.isOpen == false);
    h.injectKey(Key.up);
    h.injectKey(Key.up);
    assert(fruit.peek == "Apricot");
    h.injectKey(Key.end);
    assert(fruit.peek == "Cherry");
    h.injectKey(Key.down);
    assert(fruit.peek == "Cherry", "stops at the end");
    h.injectKey(Key.home);
    assert(fruit.peek == "Apple");

    h.frame();
    h.injectKey('b');
    assert(fruit.peek == "Banana");
    h.injectKey('l');
    assert(fruit.peek == "Blueberry", "typed prefix bl");
    h.frame();
    h.injectKey('a');
    h.frame();
    h.injectKey('a');
    assert(fruit.peek == "Apricot", "a again steps to the next item starting with a");

    h.frame();
    h.injectKey(Key.space);
    h.frame();
    assert(c.isOpen && c.list.hotIndex == 1);
    h.injectKey(Key.down);
    h.injectKey(Key.down);
    assert(c.list.hotIndex == 3 && fruit.peek == "Apricot", "the highlight moved, the value did not");
    h.injectKey(Key.enter);
    assert(fruit.peek == "Blueberry" && c.isOpen == false && h.focused is c);

    h.injectKey(Key.f4);
    h.frame();
    h.injectKey(Key.up);
    h.injectKey(Key.escape);
    assert(c.isOpen == false && fruit.peek == "Blueberry" && h.focused is c);

    h.injectKey(Key.down, Mod.alt);
    h.frame();
    assert(c.isOpen);
    h.injectKey(Key.tab);
    assert(c.isOpen == false && h.focused is after);
}

// A long list builds only the rows in view, opens with the chosen item in view, and End, Page Up and Enter
// work far from it.
unittest
{
    import dentrite.containers : column, CrossAlign;
    import std.array : array;
    import std.conv : to;
    import std.range : iota;

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    Signal!int pick = signal(5000);
    ComboBox c = comboBox(iota(10_000).array, pick, label: (int i) => "Item " ~ i.to!string);
    h.setRoot(column(cross: CrossAlign.start)(c));
    h.frame();
    h.setFocus(c);
    h.injectKey(Key.f4);
    h.frame();
    float rowH = rowHeight(h.tree);
    ComboBoxStyle cs;
    assert(c.list.scroller.size.h == cs.maxRows * rowH);
    assert(c.list.rows.built < 30, "the rows in view and the overscan");

    /// True if the row of item `i` is bound and fully inside the view.
    bool inView(size_t i)
    {
        Node r = c.list.rows[i];
        Rect v = c.list.scroller.bounds;
        return r !is null && r.bounds.y >= v.y && r.bounds.bottom <= v.bottom;
    }

    assert(inView(5000) && c.list.hotIndex == 5000);
    h.injectKey(Key.end);
    h.frame();
    assert(c.list.hotIndex == 9999 && inView(9999));
    h.injectKey(Key.pageUp);
    h.frame();
    assert(c.list.hotIndex == 9999 - (cs.maxRows - 1) && inView(c.list.hotIndex));
    h.injectKey(Key.enter);
    assert(pick.peek == 9988 && c.text == "Item 9988");
    assert(c.list.rows.built < 40);
}

// Editable with strings: typing writes the value and shows the matching suggestions without a highlight,
// Down highlights, Enter picks, the arrow shows every suggestion, and text without matches closes the list.
unittest
{
    import dentrite.command : command, shortcuts;
    import dentrite.containers : column, CrossAlign;
    import dentrite.widgets.menu : clickOn;

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    Signal!string path = signal("");
    Signal!(string[]) recent = signal(["main.d", "model.d", "panels.d", "app.d"]);
    ComboBox c = comboBox(&recent.get, path, editable: true, placeholder: "File");
    int saved;
    h.setRoot(shortcuts([command("Save", () { ++saved; }, keys: "Ctrl+S")], window: true)(
        column(cross: CrossAlign.start)(c)));
    h.frame();
    clickOn(h, c.edit);
    assert(h.focused is c.edit && c.isOpen == false);

    h.injectText("m");
    h.frame();
    assert(path.peek == "m" && c.isOpen && c.list.shown == [0, 1] && c.list.hotIndex == size_t.max);
    h.injectKey('s', Mod.ctrl);
    assert(saved == 1 && c.isOpen, "window shortcuts work while the list is open");
    h.injectText("a");
    h.frame();
    assert(path.peek == "ma" && c.list.shown == [0]);
    h.injectKey(Key.down);
    h.injectKey(Key.enter);
    assert(path.peek == "main.d" && c.text == "main.d" && c.isOpen == false && h.focused is c.edit);

    Rect b = c.bounds;
    clickAt(h, Point(b.right - 4, b.y + b.h / 2));
    assert(c.isOpen && c.list.shown.length == 4 && c.list.hotIndex == 0 && h.focused is c.edit);
    h.injectKey(Key.escape);
    assert(c.isOpen == false && c.text == "main.d");

    h.injectText("x");
    h.frame();
    assert(path.peek == "main.dx" && c.isOpen == false, "nothing matches");
    recent.set(["main.dx", "x.d"]);
    h.injectKey(Key.escape);
    assert(path.peek == "" && c.isOpen == false, "Escape cleared the text, which closed the list");
}

// Editable with another type: typing highlights the first match and Enter picks it, leaving puts back the
// chosen label, and leaving with an item's label in another case chooses that item.
unittest
{
    import dentrite.containers : column, CrossAlign;
    import dentrite.widgets.button : Button, button;

    enum Fruit
    {
        apple,
        banana,
        cherry,
    }

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    Signal!Fruit f = signal(Fruit.banana);
    ComboBox c = comboBox([Fruit.apple, Fruit.banana, Fruit.cherry], f, editable: true);
    Button other = button("Other");
    h.setRoot(column(cross: CrossAlign.start)(c, other));
    h.frame();
    assert(c.text == "banana");
    h.setFocus(c.edit);

    h.injectKey('a', Mod.ctrl);
    h.injectText("ch");
    h.frame();
    assert(c.isOpen && c.list.shown == [2] && c.list.hotIndex == 2 && f.peek == Fruit.banana);
    h.injectKey(Key.enter);
    assert(f.peek == Fruit.cherry && c.text == "cherry" && c.isOpen == false);

    h.injectKey('a', Mod.ctrl);
    h.injectText("pp");
    h.frame();
    h.setFocus(other);
    assert(f.peek == Fruit.cherry && c.text == "cherry", "no item is called pp");

    h.setFocus(c.edit);
    h.injectKey('a', Mod.ctrl);
    h.injectText("APPLE");
    h.injectKey(Key.escape);
    assert(c.isOpen == false && c.text == "APPLE");
    h.setFocus(other);
    assert(f.peek == Fruit.apple && c.text == "apple");

    f.set(Fruit.banana);
    assert(c.text == "banana", "outside writes show");
}

// Enum members, items changing while open, a value outside the items, and a disabled box.
unittest
{
    import dentrite.containers : column, CrossAlign;
    import dentrite.widgets.menu : clickOn;

    enum Renderer
    {
        gl,
        software,
    }

    Host h = comboHost();
    scope (exit)
    {
        h.close();
    }
    Signal!Renderer r = signal(Renderer.software);
    ComboBox e = comboBox(r);
    Signal!(string[]) names = signal(["one", "two", "three"]);
    Signal!string name = signal("two");
    Signal!bool on = signal(true);
    ComboBox c = comboBox(&names.get, name, placeholder: "None", enabled: &on.get);
    h.setRoot(column(cross: CrossAlign.start)(e, c));
    h.frame();
    assert(e.labels == ["gl", "software"] && e.chosenIndex == 1);

    clickOn(h, c);
    assert(c.isOpen && c.list.rows.children.length == 3);
    names.set(["two", "four"]);
    h.frame();
    assert(c.isOpen && c.list.shown == [0, 1] && c.chosenIndex == 0 && c.list.rows.children.length == 2);
    names.set(["four"]);
    h.frame();
    assert(c.chosenIndex == -1 && c.text is null, "the value is not an item, so the field shows the placeholder");
    h.injectKey(Key.escape);

    on.set(false);
    clickOn(h, c);
    h.injectKey(Key.down);
    assert(c.isOpen == false && name.peek == "two");
}
