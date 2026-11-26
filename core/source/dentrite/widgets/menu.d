/// Menus, items in a popup with keyboard navigation and submenus, menu bars and context menus.
///
/// Items take their label, shortcut and states from a `Command`. A menu bar fires the shortcuts of all its
/// commands from anywhere in the window, a context menu fires its own while focus is inside its content.
/// A menu closes before its command runs, so the command sees the focus from before the menu opened.
module dentrite.widgets.menu;

import core.time : MonoTime, msecs;
import dentrite.command;
import dentrite.containers : Axis, CrossAlign, Flex, Panel, ScrollStyle, ScrollView, scrollIntoView;
import dentrite.access : AccessFocus;
import dentrite.node;
import dentrite.overlay;
import dentrite.immediate : Id, Press, Ui;
import dentrite.signals : effect, runWithOwner;
import dentrite.text;
import dentrite.widgets.button : ButtonBox, ButtonState, ButtonStyle;
import dentrite.widgets.icons;
import std.algorithm.comparison : max, min;
import std.math : ceil, isInfinity, round;

/// Look of menus. The popup body is the `popup` panel variant.
struct MenuStyle
{
    enum section = "menu"; /// section name in theme files

    Color text = Color(0xdd, 0xdd, 0xdd, 0xff);         /// item label
    Color textDisabled = Color(0x80, 0x80, 0x80, 0xff); /// label and shortcut of a disabled item
    Color keys = Color(0x99, 0x99, 0x99, 0xff);         /// shortcut text
    Color highlight = Color(0x3a, 0x7b, 0xe8, 0xff);    /// background of the row highlighted by the pointer or keys
    Color highlightText = Color(0xff, 0xff, 0xff, 0xff); /// label, shortcut and marks on the highlight
    Color separator = Color(0x50, 0x50, 0x55, 0xff);    /// line between groups
    float padX = 6;         /// row padding left and right
    float padY = 4;         /// row padding top and bottom
    float radius = 4;       /// corner radius of the highlight
    float gutter = 18;      /// column for check marks and icons, after the left padding
    float iconSize = 12;    /// size of check marks and icons
    float keysGap = 24;     /// least space between the label and the shortcut
    float arrow = 8;        /// submenu arrow size
    float separatorPad = 4; /// space above and below a separator
    float minWidth = 120;   /// narrowest menu
    float hoverDelay = 200; /// milliseconds of hover before a submenu opens or closes
    FontKind font = FontKind.ui; /// label font
    float size = 13;        /// label size
}

/// Look of menu bars.
struct MenuBarStyle
{
    enum section = "menubar"; /// section name in theme files

    Color fill;       /// background
    Color bottomLine; /// one pixel line along the bottom edge
    Color text = Color(0xdd, 0xdd, 0xdd, 0xff);  /// title text color
    Color hover = Color(0x50, 0x50, 0x55, 0xff); /// title under the pointer
    Color open = Color(0x3a, 0x3a, 0x3f, 0xff);  /// title whose menu is open
    float padX = 4;     /// bar padding left and right
    float padY = 2;     /// bar padding top and bottom
    float itemPadX = 8; /// title padding left and right
    float itemPadY = 3; /// title padding top and bottom
    float radius = 4;   /// corner radius of the title background
    FontKind font = FontKind.ui; /// title font
    float size = 13;    /// title size
}

/// Label with its `&` marks taken out.
struct Mnemonic
{
    string text;       /// shown text
    ptrdiff_t at = -1; /// byte offset of the marked letter in `text`, or -1
    size_t len;        /// byte length of the marked letter
    uint key;          /// lowercase code point of the marked letter, 0 for none
}

/// Splits `label` into its shown text and mnemonic: `&` marks the next letter, `&&` is a literal &.
Mnemonic mnemonic(string label)
{
    import std.uni : toLower;
    import std.utf : decode;

    Mnemonic m;
    char[] t;
    size_t i;
    while (i < label.length)
    {
        if (label[i] == '&' && i + 1 < label.length)
        {
            if (label[i + 1] == '&')
            {
                t ~= '&';
                i += 2;
                continue;
            }
            if (m.at < 0)
            {
                size_t j = i + 1;
                dchar ch = decode(label, j);
                m.at = t.length;
                m.len = j - i - 1;
                m.key = toLower(ch);
            }
            ++i;
            continue;
        }
        t ~= label[i];
        ++i;
    }
    m.text = t.idup;
    return m;
}

/// In labels `&` marks the mnemonic and `&&` is a literal &.
unittest
{
    Mnemonic m = mnemonic("Save &As");
    assert(m.text == "Save As" && m.at == 5 && m.len == 1 && m.key == 'a');
    m = mnemonic("R&&D");
    assert(m.text == "R&D" && m.at == -1 && m.key == 0);
    m = mnemonic("&Ébauche");
    assert(m.text == "Ébauche" && m.at == 0 && m.len == 2 && m.key == 'é');
}

/// Draws `m.text` with its left end at `x` and baseline at `base`, underlining the marked letter if `marks`.
private void paintLabel(ref PaintContext ctx, const ref Mnemonic m, FontKind font, float size, float x, float base,
    Color c, bool marks)
{
    TextSystem t = ctx.text;
    ctx.list.text(t.shape(font, size, m.text), Point(x, base), c);
    if (marks && m.at >= 0)
    {
        float x0 = x + t.measure(font, size, m.text[0 .. m.at]);
        float x1 = x + t.measure(font, size, m.text[0 .. m.at + m.len]);
        ctx.list.hline(round(x0), round(x1), round(base) + 1, c);
    }
}

/// Row of a menu: runs a command or opens a submenu.
final class MenuItem : Node
{
    Command command; /// label, shortcut, states and action, null for a submenu
    Menu sub;        /// submenu, null for a command

    private Mnemonic label; /// shown text and mnemonic
    private bool enabled = true; /// accepts activation
    private bool checked;  /// shows a check mark

    /// Row running `c`.
    this(Command c)
    {
        command = c;
        label = mnemonic(c.label);
        enabled = c.isEnabled;
        checked = c.isChecked;
        interactive = true;
    }

    /// Row opening `sub`.
    this(string label, Menu sub)
    {
        this.sub = sub;
        this.label = mnemonic(label);
        sub.owner = this;
        interactive = true;
    }

    /// True if it can be highlighted and activated.
    bool isEnabled() const
    {
        return enabled;
    }

    /// Shown text, without the mnemonic marker.
    string text() const
    {
        return label.text;
    }

    /// Sets the enabled and checked states, repainting on change.
    void setState(bool enabled, bool checked)
    {
        if (enabled != this.enabled || checked != this.checked)
        {
            this.enabled = enabled;
            this.checked = checked;
            markNeedsPaint();
        }
    }

    /// Menu item with its shortcut and check state, expanded while its submenu is open.
    override void describe(ref AccessInfo a)
    {
        a.role = command !is null && command.checked !is null ? Role.menuItemCheckBox : Role.menuItem;
        a.label = label.text;
        a.shortcut = keysText();
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
        if (command !is null && command.checked !is null)
        {
            a.toggled = checked ? Toggle.on : Toggle.off;
        }
        if (sub !is null)
        {
            a.expanded = tri(sub.isOpen);
        }
    }

    /// Click runs the command or opens the submenu, as Enter does.
    override bool accessAction(ref const AccessRequest r)
    {
        MenuList l = cast(MenuList) parent;
        if (r.action != AccessAction.click || l is null || enabled == false)
        {
            return false;
        }
        l.activate(this, true);
        return true;
    }

    /// Shortcut text, empty for none.
    private string keysText()
    {
        return command is null ? "" : command.shortcut;
    }

    /// Width the row needs and its height.
    Size natural()
    {
        MenuStyle s = tree.style!MenuStyle();
        TextSystem t = tree.text;
        float w = s.padX * 2 + s.gutter + t.measure(s.font, s.size, label.text);
        string k = keysText();
        if (k.length > 0)
        {
            w += s.keysGap + t.measure(s.font, s.size, k);
        }
        if (sub !is null)
        {
            w += s.keysGap / 2 + s.arrow;
        }
        return Size(w, s.padY * 2 + t.lineHeight(s.font, s.size));
    }

    /// Natural size, as wide as the menu makes it.
    protected override Size performLayout(Constraints c)
    {
        return natural();
    }

    /// Highlight, check mark or icon, label, shortcut and submenu arrow.
    override void paint(ref PaintContext ctx, Point origin)
    {
        MenuStyle s = ctx.style!MenuStyle();
        MenuList l = cast(MenuList) parent;
        bool hot = l !is null && l.hotItem is this;
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (hot)
        {
            ctx.list.rect(r, s.highlight, s.radius);
        }
        Color ink = enabled == false ? s.textDisabled : hot ? s.highlightText : s.text;
        TextSystem t = ctx.text;
        float base = r.y + round((r.h - t.lineHeight(s.font, s.size)) / 2) + t.ascent(s.font, s.size);
        float k = s.iconSize;
        Rect box = Rect(r.x + s.padX + round((s.gutter - k) / 2), r.y + round((r.h - k) / 2), k, k);
        if (checked)
        {
            paintIcon(*ctx.list, Icon.check, box, ink);
        }
        else if (command !is null && command.icon.empty == false)
        {
            paintIcon(*ctx.list, command.icon, box, ink, enabled == false);
        }
        paintLabel(ctx, label, s.font, s.size, r.x + s.padX + s.gutter, base, ink, l !is null && l.keyboard);
        float right = r.right - s.padX;
        if (sub !is null)
        {
            float ax = right - s.arrow;
            paintIcon(*ctx.list, Icon.chevronRight, Rect(ax, r.y + (r.h - s.arrow) / 2, s.arrow, s.arrow), ink);
            right = ax - s.keysGap / 2;
        }
        string keys = keysText();
        if (keys.length > 0)
        {
            Color kc = enabled == false ? s.textDisabled : hot ? s.highlightText : s.keys;
            float kw = t.measure(s.font, s.size, keys);
            ctx.list.text(t.shape(s.font, s.size, keys), Point(right - kw, base), kc);
        }
    }

    /// Hover highlights, release over the row activates.
    override bool onPointer(ref const PointerEvent e)
    {
        MenuList l = cast(MenuList) parent;
        if (l is null)
        {
            return false;
        }
        switch (e.kind)
        {
        case PointerKind.enter:
            l.hover(this);
            return true;
        case PointerKind.leave:
            l.unhover(this);
            return true;
        case PointerKind.down:
            return e.button == 1;
        case PointerKind.up:
            if (e.button == 1 && hovered)
            {
                l.activate(this, false);
            }
            return true;
        default:
            return false;
        }
    }
}

/// Line between groups of menu items.
final class MenuSeparator : Node
{
    /// Separator.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.separator;
    }

    /// One pixel and the padding around it.
    protected override Size performLayout(Constraints c)
    {
        MenuStyle s = tree.style!MenuStyle();
        return Size(0, s.separatorPad * 2 + 1);
    }

    /// The line, inset by the row padding.
    override void paint(ref PaintContext ctx, Point origin)
    {
        MenuStyle s = ctx.style!MenuStyle();
        ctx.list.hline(origin.x + s.padX, origin.x + size.w - s.padX, origin.y + s.separatorPad, s.separator);
    }
}

/// Items of an open menu, as wide as the widest. Holds keyboard focus and the highlight.
final class MenuList : Node, AccessFocus
{
    Menu menu;     /// menu showing these items
    int hot = -1;  /// index of the highlighted child, or -1
    bool keyboard; /// driven by keys, so mnemonics show
    private float barRoom = 0; /// strip at the right kept clear for the scroll thumb

    /// List of `items` for `menu`.
    this(Menu menu, Node[] items)
    {
        this.menu = menu;
        focusable = true;
        foreach (Node k; items)
        {
            add(k);
        }
    }

    /// Highlighted item, or null.
    MenuItem hotItem()
    {
        return hot >= 0 && hot < children.length ? cast(MenuItem) children[hot] : null;
    }

    /// Items stacked at the widest natural width.
    protected override Size performLayout(Constraints c)
    {
        MenuStyle s = tree.style!MenuStyle();
        float w = s.minWidth;
        foreach (Node k; children)
        {
            if (MenuItem it = cast(MenuItem) k)
            {
                w = max(w, it.natural().w);
            }
        }
        w = min(max(ceil(w), c.minW), c.maxW);
        float iw = max(0f, w - barRoom);
        float y = 0;
        foreach (Node k; children)
        {
            Size cs = k.layout(Constraints(iw, iw, 0, float.infinity));
            k.offset = Point(0, y);
            y += cs.h;
        }
        return Size(w, y);
    }

    /// Menu of the items.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.menu;
    }

    /// The highlighted item, which has the focus the list holds.
    Node accessFocus()
    {
        return hot >= 0 && hot < children.length ? children[hot] : null;
    }

    /// Highlights child `i`, or nothing for -1.
    void setHot(int i)
    {
        if (i != hot)
        {
            hot = i;
            markNeedsPaint();
        }
    }

    /// Scrolls the highlighted item into view.
    private void revealHot()
    {
        if (hot >= 0 && hot < children.length)
        {
            scrollIntoView(children[hot]);
        }
    }

    /// Next enabled item from child `from` in direction `dir`, wrapping, or -1. `from` -1 starts at an end.
    private int step(int from, int dir)
    {
        int n = cast(int) children.length;
        if (from < 0)
        {
            from = dir > 0 ? -1 : n;
        }
        foreach (int i; 1 .. n + 1)
        {
            int j = ((from + dir * i) % n + n) % n;
            MenuItem it = cast(MenuItem) children[j];
            if (it !is null && it.enabled)
            {
                return j;
            }
        }
        return -1;
    }

    /// Index of child `n`, or -1.
    private int indexOf(Node n)
    {
        foreach (size_t i, Node k; children)
        {
            if (k is n)
            {
                return cast(int) i;
            }
        }
        return -1;
    }

    /// Sets keyboard mode, repainting for the mnemonics when it changes.
    private void setKeyboard(bool on)
    {
        if (on != keyboard)
        {
            keyboard = on;
            markNeedsPaint();
        }
    }

    /// Takes focus with the first item highlighted, for a submenu the pointer opened.
    private void enter()
    {
        setKeyboard(true);
        setHot(step(-1, 1));
        if (tree !is null && tree.services !is null)
        {
            tree.services.setFocus(this);
        }
    }

    /// Pointer entered `it`: highlights it, keeps the parent's item highlighted, and after the hover delay opens
    /// its submenu or closes another one.
    private void hover(MenuItem it)
    {
        if (menu.owner !is null)
        {
            if (MenuList up = cast(MenuList) menu.owner.parent)
            {
                up.tree.cancelCall(up);
                up.setHot(up.indexOf(menu.owner));
            }
        }
        setHot(it.enabled ? indexOf(it) : -1);
        MenuStyle s = tree.style!MenuStyle();
        tree.callAt(this, MonoTime.currTime + msecs(cast(long) s.hoverDelay), &settle);
    }

    /// Pointer left `it`: drops the highlight unless its submenu is open.
    private void unhover(MenuItem it)
    {
        if (hotItem is it && (it.sub is null || it.sub.isOpen == false))
        {
            setHot(-1);
        }
    }

    /// Opens the highlighted item's submenu, or closes the open one if the highlighted item has none.
    private void settle()
    {
        MenuItem it = hotItem;
        if (it is null)
        {
            return;
        }
        if (it.sub !is null)
        {
            openSubmenu(it, false);
        }
        else
        {
            closeSubmenu();
        }
    }

    /// Opens `it`'s submenu next to it, closing another. `select` moves focus in and highlights its first item.
    private void openSubmenu(MenuItem it, bool select)
    {
        if (tree !is null)
        {
            tree.cancelCall(this);
        }
        if (it.sub.isOpen)
        {
            if (select)
            {
                it.sub.list.enter();
            }
            return;
        }
        closeSubmenu();
        setHot(indexOf(it));
        it.sub.show(it, Side.right, this, select);
    }

    /// Closes the open submenu, if any.
    private void closeSubmenu()
    {
        foreach (Node k; children)
        {
            MenuItem it = cast(MenuItem) k;
            if (it !is null && it.sub !is null && it.sub.isOpen)
            {
                it.sub.close();
            }
        }
    }

    /// Runs `it`: opens its submenu, or closes every menu up to the first and runs its command.
    private void activate(MenuItem it, bool keyboard)
    {
        if (it.enabled == false)
        {
            return;
        }
        if (it.sub !is null)
        {
            openSubmenu(it, keyboard);
            return;
        }
        menu.root.close();
        if (it.command !is null)
        {
            it.command.run();
        }
    }

    /// Typed letter `key`: activates the only item with that mnemonic, else highlights the next item with that
    /// mnemonic or first letter.
    private bool typed(uint key)
    {
        import std.uni : toLower;
        import std.utf : decodeFront;

        dchar want = toLower(cast(dchar) key);
        int[] marks;
        int[] firsts;
        foreach (size_t i, Node k; children)
        {
            MenuItem it = cast(MenuItem) k;
            if (it is null || it.enabled == false)
            {
                continue;
            }
            string text = it.label.text;
            if (it.label.key == want)
            {
                marks ~= cast(int) i;
            }
            else if (text.length > 0 && toLower(decodeFront(text)) == want)
            {
                firsts ~= cast(int) i;
            }
        }
        if (marks.length == 1)
        {
            setHot(marks[0]);
            revealHot();
            activate(cast(MenuItem) children[marks[0]], true);
            return true;
        }
        int[] pool = marks.length > 0 ? marks : firsts;
        if (pool.length > 0)
        {
            int next = pool[0];
            foreach (int i; pool)
            {
                if (i > hot)
                {
                    next = i;
                    break;
                }
            }
            closeSubmenu();
            setHot(next);
            revealHot();
        }
        return true;
    }

    /// Arrows, Home and End move the highlight, Enter and Space activate, Right opens a submenu or the next
    /// menu of the bar, Left closes a submenu or opens the previous menu of the bar, letters pick by mnemonic.
    /// Keys with Ctrl, Alt or Super go to the menu bar, or fire a command of this menu.
    override bool onKey(ref const KeyEvent e)
    {
        MenuItem it = hotItem;
        if (e.mods == 0)
        {
            switch (e.key)
            {
            case Key.down:
            case Key.up:
            case Key.home:
            case Key.end:
                setKeyboard(true);
                closeSubmenu();
                int from = e.key == Key.home || e.key == Key.end ? -1 : hot;
                setHot(step(from, e.key == Key.down || e.key == Key.home ? 1 : -1));
                revealHot();
                return true;
            case Key.enter:
            case Key.space:
                if (it !is null)
                {
                    activate(it, true);
                }
                return true;
            case Key.right:
                setKeyboard(true);
                if (it !is null && it.sub !is null && it.enabled)
                {
                    openSubmenu(it, true);
                }
                else if (MenuBar b = menu.root.bar)
                {
                    b.step(1);
                }
                return true;
            case Key.left:
                setKeyboard(true);
                if (menu.owner !is null)
                {
                    menu.close();
                }
                else if (menu.bar !is null)
                {
                    menu.bar.step(-1);
                }
                return true;
            default:
                break;
            }
        }
        if ((e.mods & (Mod.ctrl | Mod.alt | Mod.gui)) == 0)
        {
            if (e.key > Key.space && e.key < 0x40000000)
            {
                setKeyboard(true);
                return typed(e.key);
            }
            return false;
        }
        Menu r = menu.root;
        if (r.bar !is null)
        {
            return r.bar.windowKey(e);
        }
        if (Command c = r.find(e))
        {
            r.close();
            c.run();
            return true;
        }
        return false;
    }

    /// Closes an open submenu, then leaves the wheel to the scroll view.
    override bool onWheel(ref const WheelEvent e)
    {
        closeSubmenu();
        return false;
    }

    /// Drops a pending submenu change.
    override void onDetach()
    {
        tree.cancelCall(this);
    }
}

/// Scroll view of a menu's items, at their natural size or as tall as the popup's room, with a strip for the
/// thumb when they do not fit.
private final class MenuBody : Node
{
    private MenuList list;        /// list node holding the items
    private ScrollView scroller;  /// scrolls `list`

    /// Body around `list`.
    this(MenuList list)
    {
        this.list = list;
        scroller = new ScrollView(list, false);
        add(scroller);
    }

    /// Measures the items, then sizes the scroll view to them, capped at the room.
    protected override Size performLayout(Constraints c)
    {
        // NOTE: the measure and the final layout differ in their constraints, so `barRoom` always applies.
        list.barRoom = 0;
        Size n = list.layout(Constraints(0, c.maxW, 0, float.infinity));
        Size s = n;
        if (n.h > c.maxH)
        {
            ScrollStyle ss = tree.style!ScrollStyle();
            list.barRoom = ss.width + 4;
            s = Size(min(n.w + list.barRoom, c.maxW), c.maxH);
        }
        scroller.offset = Point.init;
        scroller.layout(Constraints.tight(s));
        return s;
    }
}

/// Items in a popup, opened next to a node, at a point, from a menu bar or as a submenu. Build it once.
/// Items taller than the room next to the anchor scroll.
final class Menu
{
    MenuList list;           /// list node holding the items
    private MenuBody body_;  /// scrolls the items
    Popup popup;             /// popup holding the items
    MenuItem owner;          /// item opening it as a submenu, or null
    MenuBar bar;             /// bar it drops from, or null
    void delegate() onClose; /// runs after closing

    /// Menu of `items`: menu items, separators or other nodes.
    this(Node[] items)
    {
        list = new MenuList(this, items);
        body_ = new MenuBody(list);
        popup = new Popup(new Panel("popup", body_));
        popup.onClose = &closed;
    }

    /// True while open.
    bool isOpen()
    {
        return popup.isOpen;
    }

    /// Opens next to `anchor`, which keeps pointer input meanwhile. `select` highlights the first item.
    void open(Node anchor, Side side = Side.below, bool select = false)
    {
        show(anchor, side, anchor, select);
    }

    /// Opens on `t` at window point `p`, such as the pointer. `select` highlights the first item.
    void openAt(Tree t, Point p, bool select = false)
    {
        openAt(t, Rect(p.x, p.y, 0, 0), Side.below, select);
    }

    /// Opens on `t` next to window rectangle `r` on `side`, such as a control of an island. `select` highlights
    /// the first item.
    void openAt(Tree t, Rect r, Side side, bool select = false)
    {
        close();
        popup.anchor = null;
        popup.source = null;
        popup.side = side;
        popup.focus = true;
        reset(select);
        popup.openAt(t, r);
    }

    /// Opens below `anchor` if closed, closes if open.
    void toggle(Node anchor)
    {
        if (isOpen)
        {
            close();
        }
        else
        {
            open(anchor);
        }
    }

    /// Closes this menu and its submenus. Does nothing if closed.
    void close()
    {
        popup.close();
    }

    /// Replaces the items, closing the menu first.
    void setItems(Node[] items)
    {
        close();
        list.setChildren(items);
    }

    /// First menu of the chain this one is a submenu of, or this one.
    Menu root()
    {
        Menu m = this;
        while (m.owner !is null)
        {
            MenuList up = cast(MenuList) m.owner.parent;
            if (up is null)
            {
                break;
            }
            m = up.menu;
        }
        return m;
    }

    /// First enabled command of this menu and its submenus whose shortcut is `e`, or null.
    Command find(ref const KeyEvent e)
    {
        foreach (Node k; list.children)
        {
            MenuItem it = cast(MenuItem) k;
            if (it is null)
            {
                continue;
            }
            if (it.sub !is null)
            {
                if (Command c = it.sub.find(e))
                {
                    return c;
                }
            }
            else if (it.command !is null && it.command.keys.matches(e) && it.command.isEnabled)
            {
                return it.command;
            }
        }
        return null;
    }

    /// Opens next to `anchor` with `source` keeping input. Submenus the pointer opens leave focus in the parent.
    private void show(Node anchor, Side side, Node source, bool select)
    {
        close();
        popup.anchor = anchor;
        popup.side = side;
        popup.source = source;
        popup.focus = owner is null || select;
        reset(select);
        popup.open();
    }

    /// Sets keyboard mode and highlights the first item if `select`, nothing otherwise.
    private void reset(bool select)
    {
        list.keyboard = select;
        list.hot = select ? list.step(-1, 1) : -1;
        body_.scroller.scrollTo(0);
    }

    /// Tells the bar and the owner after the popup closed.
    private void closed()
    {
        if (bar !is null)
        {
            bar.closed(this);
        }
        if (onClose !is null)
        {
            onClose();
        }
    }
}

/// Title of a menu in a menu bar.
final class MenuTitle : Node
{
    private MenuBar bar;     /// bar holding it
    private Menu menu;       /// menu it opens
    private Mnemonic label;  /// shown text and mnemonic

    /// Title showing `label` and opening `menu`.
    this(MenuBar bar, Mnemonic label, Menu menu)
    {
        this.bar = bar;
        this.label = label;
        this.menu = menu;
        interactive = true;
    }

    /// Menu bar title, expanded while its menu is open.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.menuItem;
        a.label = label.text;
        a.expanded = tri(bar.active is menu);
        a.allow(AccessAction.click);
    }

    /// Click opens the menu with its first item highlighted, or closes it.
    override bool accessAction(ref const AccessRequest r)
    {
        if (r.action != AccessAction.click)
        {
            return false;
        }
        if (bar.active is menu)
        {
            menu.close();
        }
        else
        {
            bar.open(this, true);
        }
        return true;
    }

    /// Text and padding.
    protected override Size performLayout(Constraints c)
    {
        MenuBarStyle s = tree.style!MenuBarStyle();
        TextSystem t = tree.text;
        return Size(ceil(t.measure(s.font, s.size, label.text)) + s.itemPadX * 2,
            t.lineHeight(s.font, s.size) + s.itemPadY * 2);
    }

    /// Background while hovered or open, and the text.
    override void paint(ref PaintContext ctx, Point origin)
    {
        MenuBarStyle s = ctx.style!MenuBarStyle();
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        bool open = bar.active is menu;
        if (open || hovered)
        {
            ctx.list.rect(r, open ? s.open : s.hover, s.radius);
        }
        TextSystem t = ctx.text;
        float base = r.y + s.itemPadY + t.ascent(s.font, s.size);
        paintLabel(ctx, label, s.font, s.size, r.x + s.itemPadX, base, s.text, bar.keyboard);
    }

    /// A press opens or closes the menu, and a drag from it to an item and release runs the item. Hover switches
    /// to this menu while another is open.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            if (bar.active is menu)
            {
                menu.close();
            }
            else
            {
                bar.open(this, false);
                if (tree.services !is null)
                {
                    tree.services.slidePress();
                }
            }
            return true;
        case PointerKind.enter:
            if (bar.active !is null && bar.active !is menu)
            {
                bar.open(this, false);
            }
            markNeedsPaint();
            return true;
        case PointerKind.leave:
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }
}

/// Row of menu titles. Alt and a title's mnemonic opens it, and the shortcuts of every command in its menus
/// fire from anywhere in the window. A press on the bar leaves focus where it is.
final class MenuBar : Node, WindowKeys
{
    private Menu active;   /// open menu, or null
    private bool keyboard; /// opened by keys, so mnemonics show

    /// Bar of `menus`, each made by `menu("&File")(...)`.
    this(MenuItem[] menus)
    {
        keepFocus = true;
        foreach (MenuItem m; menus)
        {
            assert(m.sub !is null, "menu bar entries are menus: menu(\"&File\")(...)");
            m.sub.owner = null;
            m.sub.bar = this;
            add(new MenuTitle(this, m.label, m.sub));
        }
    }

    /// Menu bar of the titles.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.menuBar;
    }

    /// Open menu, or null.
    Menu openMenu()
    {
        return active;
    }

    /// Titles in a row, as wide as allowed.
    protected override Size performLayout(Constraints c)
    {
        MenuBarStyle s = tree.style!MenuBarStyle();
        float x = s.padX;
        float h = 0;
        foreach (Node k; children)
        {
            Size cs = k.layout(Constraints.init);
            k.offset = Point(x, s.padY);
            x += cs.w;
            h = max(h, cs.h);
        }
        return Size(isInfinity(c.maxW) ? x + s.padX : c.maxW, h + s.padY * 2);
    }

    /// Background, titles and bottom line.
    override void paint(ref PaintContext ctx, Point origin)
    {
        MenuBarStyle s = ctx.style!MenuBarStyle();
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (s.fill.a > 0)
        {
            ctx.list.rect(r, s.fill);
        }
        paintChildren(ctx, origin);
        if (s.bottomLine.a > 0)
        {
            ctx.list.hline(r.x, r.right, r.bottom - 1, s.bottomLine);
        }
    }

    /// Opens the menu of `t` below it, closing the open one. `select` highlights its first item.
    void open(MenuTitle t, bool select)
    {
        if (active is t.menu)
        {
            if (select)
            {
                t.menu.list.enter();
            }
            return;
        }
        if (active !is null)
        {
            active.close();
        }
        t.menu.show(t, Side.below, this, select);
        active = t.menu;
        keyboard = select;
        markNeedsPaint();
    }

    /// Opens the menu `dir` titles from the open one, wrapping, with its first item highlighted.
    void step(int dir)
    {
        int n = cast(int) children.length;
        int at;
        foreach (size_t i, Node k; children)
        {
            if ((cast(MenuTitle) k).menu is active)
            {
                at = cast(int) i;
            }
        }
        open(cast(MenuTitle) children[((at + dir) % n + n) % n], true);
    }

    /// Alt and a mnemonic opens that menu, a command's shortcut closes the open menu and runs it.
    bool windowKey(ref const KeyEvent e)
    {
        foreach (Node k; children)
        {
            MenuTitle t = cast(MenuTitle) k;
            if (e.mods == Mod.alt && t.label.key != 0 && e.key == t.label.key)
            {
                open(t, true);
                return true;
            }
        }
        foreach (Node k; children)
        {
            if (Command c = (cast(MenuTitle) k).menu.find(e))
            {
                if (active !is null)
                {
                    active.close();
                }
                c.run();
                return true;
            }
        }
        return false;
    }

    /// Notes that `m` closed.
    private void closed(Menu m)
    {
        if (active is m)
        {
            active = null;
            keyboard = false;
            markNeedsPaint();
        }
    }

    /// Starts listening to the window.
    override void onAttach()
    {
        tree.addWindowKeys(this);
    }

    /// Stops listening to the window.
    override void onDetach()
    {
        tree.removeWindowKeys(this);
    }
}

/// Content with a context menu, opened by a right press or the menu key inside it. Its commands' shortcuts
/// fire while focus is inside the content.
final class ContextMenu : Node
{
    Menu menu; /// menu it opens, possibly shared with other content

    /// Wraps `content`.
    this(Menu menu, Node content)
    {
        this.menu = menu;
        hasContextMenu = true;
        add(content);
    }

    /// The content's size.
    protected override Size performLayout(Constraints c)
    {
        children[0].offset = Point.init;
        return children[0].layout(c);
    }

    /// Opens the menu at `p`.
    override bool onContextMenu(Point p, bool keyboard)
    {
        menu.openAt(tree, p, keyboard);
        return true;
    }

    /// Fires a command of the menu by its shortcut.
    override bool onKey(ref const KeyEvent e)
    {
        if (Command c = menu.find(e))
        {
            c.run();
            return true;
        }
        return false;
    }
}

/// Menu item running `c`, following its enabled and checked states.
MenuItem menuItem(Command c)
{
    MenuItem it = new MenuItem(c);
    if (c.enabled !is null || c.checked !is null)
    {
        effect(() { it.setState(c.isEnabled, c.isChecked); });
    }
    return it;
}

/// Menu item with its own command: `menuItem("&Copy", &copy, keys: "Ctrl+C")`.
MenuItem menuItem(string label, void delegate() action, string keys = null, Icon icon = Icon.none,
    bool delegate() enabled = null, bool delegate() checked = null)
{
    return menuItem(command(label, action, keys, icon, enabled, checked));
}

/// Line between groups of menu items.
MenuSeparator menuSeparator()
{
    return new MenuSeparator;
}

/// Submenu or menu bar entry, waiting for the items.
struct MenuSpec
{
    string label; /// title, `&` before the mnemonic letter

    /// Stores the label. Needed because `opCall` hides the struct literal.
    this(string label)
    {
        this.label = label;
    }

    /// Entry opening a menu of `items`.
    MenuItem opCall(Node[] items...)
    {
        return new MenuItem(label, new Menu(items.dup));
    }
}

/// Submenu, or a menu for a menu bar: `menu("&File")(menuItem(open), menuSeparator(), menuItem(quit))`.
MenuSpec menu(string label)
{
    return MenuSpec(label);
}

/// Menu to open from a button or at a point: `popupMenu(menuItem(a), menuItem(b))`, then `toggle` or `openAt`.
Menu popupMenu(Node[] items...)
{
    return new Menu(items.dup);
}

/// Menu bar: `menuBar(menu("&File")(...), menu("&Edit")(...))`.
MenuBar menuBar(MenuItem[] menus...)
{
    return new MenuBar(menus.dup);
}

/// Context menu options, waiting for the content.
struct ContextMenuSpec
{
    Menu menu; /// menu to open

    /// Stores the menu. Needed because `opCall` hides the struct literal.
    this(Menu menu)
    {
        this.menu = menu;
    }

    /// The content with this menu.
    ContextMenu opCall(Node content)
    {
        return new ContextMenu(menu, content);
    }
}

/// Context menu for some content: `contextMenu(menuItem(copy), menuItem(paste))(view)`.
ContextMenuSpec contextMenu(Node[] items...)
{
    return ContextMenuSpec(new Menu(items.dup));
}

/// Context menu sharing `m`: `contextMenu(rowMenu)(row)`.
ContextMenuSpec contextMenu(Menu m)
{
    return ContextMenuSpec(m);
}

/// Island button opening `m` below it, with its first item highlighted when opened by Enter, Space or Down.
/// True on the pass it opened. A press on it while the menu is open closes the menu.
bool menuButton(Ui ui, string caption, Menu m, Icon icon = Icon.none, string variant = null, bool enabled = true,
    string accessName = null, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    bool viaAccess = ui.accessClick == i;
    Press p = ui.clickable(i, enabled);
    bool keys = ui.focusStop(i, enabled) && (ui.takeKey(Key.enter) || ui.takeKey(Key.space)
        || ui.takeKey(Key.down));
    bool opened;
    if ((p.pressedNow || keys || viaAccess) && m.isOpen == false && ui.window !is null)
    {
        Rect r = ui.lastRect(i);
        runWithOwner(null, { m.openAt(ui.window, r, Side.below, keys); });
        ui.keepPopup(i, m.popup);
        opened = true;
    }
    ButtonBox n = new ButtonBox(caption, icon, ui.style!ButtonStyle(variant),
        ButtonState(p.hovered || ui.keeps(i, m.popup), p.held && p.hovered, enabled, ui.focusRing(i)));
    n.accessName = accessName;
    ui.put(n);
    ui.track(n, i);
    return opened;
}

/// Island area with a context menu, waiting for the children. From `contextMenu`.
struct IslandContextMenu
{
    private Ui ui;     /// context to declare into
    private Menu menu; /// menu to open
    private Id id;     /// the area's ID

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Ui ui, Menu menu, Id id)
    {
        this.ui = ui;
        this.menu = menu;
        this.id = id;
    }

    /// Declares the area as a column of `children`, then fires the menu's commands by their shortcuts while
    /// focus is inside it.
    void opCall(scope void delegate() children)
    {
        Ui u = ui;
        Menu m = menu;
        Flex n = new Flex(Axis.vertical, 0, CrossAlign.stretch, null);
        n.hasContextMenu = true;
        ui.put(n);
        ui.track(n, id);
        ui.contextArea(id, (Point p, bool keyboard) {
            if (u.window is null)
            {
                return false;
            }
            m.openAt(u.window, p, keyboard);
            return true;
        });
        ui.inside(n, children);
        if (ui.focused == false || (ui.focus != 0 && ui.lastRect(id).contains(ui.lastRect(ui.focus).pos) == false))
        {
            return;
        }
        KeyEvent[] rest;
        foreach (KeyEvent e; ui.keys)
        {
            Command c = m.find(e);
            if (c is null)
            {
                rest ~= e;
                continue;
            }
            runWithOwner(null, { c.run(); });
            ui.again = true;
        }
        ui.keys = rest;
    }
}

/// Island area with a context menu, opened by a right press or the menu key inside it. Its commands' shortcuts
/// fire while focus is inside: `ui.contextMenu(m)({ ... })`.
IslandContextMenu contextMenu(Ui ui, Menu m, string file = __FILE__, size_t line = __LINE__)
{
    return IslandContextMenu(ui, m, ui.id(file, line));
}

// Items taller than the room scroll: the popup stays in the window, the thumb gets its own strip, keys scroll
// the highlight into view, the wheel scrolls, and reopening starts at the top.
unittest
{
    import dentrite.containers : column;
    import dentrite.widgets.button : Button, button;
    import std.conv : to;

    Host h = menuHost(400, 200);
    scope (exit)
    {
        h.close();
    }
    string ran;
    Node[] items;
    foreach (int i; 0 .. 30)
    {
        string name = "Item " ~ i.to!string;
        items ~= menuItem(name, () { ran = name; });
    }
    Menu m = popupMenu(items);
    Button b = button("Open");
    h.setRoot(column()(b));
    h.frame();
    m.open(b);
    h.frame();
    Rect pb = m.popup.bounds;
    assert(pb.y == b.bounds.bottom && pb.bottom <= 200, "below the button, inside the window");
    MenuItem first = cast(MenuItem) items[0];
    MenuItem last = cast(MenuItem) items[$ - 1];
    float bar = ScrollStyle.init.width + 4;
    assert(m.list.size.w == first.size.w + bar, "a strip for the thumb");
    Rect view = m.body_.scroller.bounds;
    h.injectKey(Key.up, 0);
    h.frame();
    assert(m.list.hotItem is last && last.bounds.bottom <= view.bottom + 0.5 && last.bounds.y >= view.y,
        "Up wraps to the last item and shows it");
    h.injectKey(Key.home, 0);
    h.frame();
    assert(first.bounds.y == view.y, "Home goes back to the top");
    h.injectWheel(Point(view.x + 20, view.y + 20), 1e6);
    h.frame();
    assert(last.bounds.bottom == view.bottom, "the wheel scrolls to the end");
    clickOn(h, last);
    h.frame();
    assert(ran == "Item 29" && m.isOpen == false, "a scrolled item runs");
    m.open(b);
    h.frame();
    assert(first.bounds.y == m.body_.scroller.bounds.y, "reopens at the top");

    Menu small = popupMenu(menuItem("One", null), menuItem("Two", null));
    small.open(b);
    h.frame();
    assert(small.list.size.w == small.list.children[0].size.w, "no strip when the items fit");
    small.close();

    MenuItem more = menu("More")(menuItem("Deep", null));
    Node[] rest;
    foreach (int i; 0 .. 30)
    {
        rest ~= menuItem("Other " ~ i.to!string, null);
    }
    Menu withSub = popupMenu(cast(Node[]) [more] ~ rest);
    h.inject(PointerKind.move, Point(390, 10));
    withSub.open(b, select: true);
    h.frame();
    h.injectKey(Key.right, 0);
    h.frame();
    assert(more.sub.isOpen);
    h.injectWheel(Point(view.x + 20, view.y + 40), 48);
    h.frame();
    assert(more.sub.isOpen == false, "the wheel closes the submenu");
}

version (unittest)
{
    import dentrite.host : Host;

    /// Headless host with the test fonts and a theme without hover delay.
    Host menuHost(int w = 400, int ht = 300)
    {
        import dentrite.backend.software : SoftwareRenderer;
        import dentrite.headless : HeadlessPlatform;
        import dentrite.platform : WindowOptions;
        import dentrite.theme : Theme;

        WindowOptions o;
        o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
        Host h = new Host(new HeadlessPlatform(w, ht), new SoftwareRenderer, o);
        h.tree.theme = new Theme("[menu]\nhoverDelay = 0\n", "test");
        return h;
    }

    /// Moves to the middle of `n`, presses and releases `button` with `mods` held, and runs a frame.
    void clickOn(Host h, Node n, ubyte button = 1, ubyte mods = 0)
    {
        Rect b = n.bounds;
        Point c = Point(b.x + b.w / 2, b.y + b.h / 2);
        h.inject(PointerKind.move, c);
        h.inject(PointerKind.down, c, 1, button, mods);
        h.inject(PointerKind.up, c, 1, button, mods);
        h.frame();
    }

    /// Moves the pointer to the middle of `n` and runs two frames, so a hover timer fires.
    void hoverOn(Host h, Node n)
    {
        Rect b = n.bounds;
        h.inject(PointerKind.move, Point(b.x + b.w / 2, b.y + b.h / 2));
        h.frame();
        h.frame();
    }
}

// A menu is as wide as its widest item, items fill that width, and the shortcut sits at the right edge.
unittest
{
    import dentrite.containers : column;
    import dentrite.widgets.button : Button, button;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    MenuItem shortItem = menuItem("Go", null);
    MenuItem longItem = menuItem("A much longer label here", null, keys: "Ctrl+Shift+L");
    MenuSeparator line = menuSeparator();
    Menu m = popupMenu(shortItem, line, longItem);
    Button b = button("Open");
    h.setRoot(column()(b));
    h.frame();
    m.open(b);
    h.frame();
    assert(m.isOpen && h.focused is m.list);
    float w = ceil(longItem.natural().w);
    assert(w > MenuStyle.init.minWidth && m.list.size.w == w);
    assert(shortItem.size.w == w && line.size.w == w);
    assert(line.size.h == MenuStyle.init.separatorPad * 2 + 1);
    assert(longItem.offset.y == shortItem.size.h + line.size.h);
    assert(m.popup.bounds.y == b.bounds.bottom, "below the button");
}

// Menu bar: a press opens a menu, hover switches menus while one is open, a click on an item closes all and
// runs it with focus back where it was, a second press on the title closes, the bar keeps focus.
unittest
{
    import dentrite.containers : column;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.textbox : TextBox, textBox;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    string[] ran;
    MenuItem open = menuItem("&Open", () { ran ~= "open"; }, keys: "Ctrl+O");
    MenuItem undo = menuItem("&Undo", () { ran ~= "undo"; }, keys: "Ctrl+Z");
    MenuBar bar = menuBar(menu("&File")(open), menu("&Edit")(undo));
    Signal!string text = signal("");
    TextBox box = textBox(text);
    h.setRoot(column()(bar, box));
    h.frame();
    MenuTitle file = cast(MenuTitle) bar.children[0];
    MenuTitle edit = cast(MenuTitle) bar.children[1];
    h.setFocus(box);

    clickOn(h, file);
    Menu fileMenu = file.menu;
    assert(bar.openMenu is fileMenu && h.focused is fileMenu.list && fileMenu.list.hot == -1);
    assert(fileMenu.popup.bounds.y == bar.bounds.bottom - MenuBarStyle.init.padY);
    hoverOn(h, edit);
    assert(bar.openMenu is edit.menu && fileMenu.isOpen == false, "switched by hover");
    clickOn(h, undo);
    assert(ran == ["undo"] && bar.openMenu is null && h.focused is box, "ran with focus back");

    clickOn(h, file);
    clickOn(h, file);
    assert(bar.openMenu is null && h.focused is box, "second press closes");
}

// Menu bar drag: a press on a title opens its menu, dragging onto another title switches, a release on an item
// runs it, a release on a title keeps the menu open, and a release elsewhere closes it without clicking what
// is there, which the drag did not hover.
unittest
{
    import dentrite.containers : column;
    import dentrite.widgets.button : Button, button;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    string[] ran;
    MenuItem open = menuItem("&Open", () { ran ~= "open"; });
    MenuItem undo = menuItem("&Undo", () { ran ~= "undo"; });
    MenuBar bar = menuBar(menu("&File")(open), menu("&Edit")(undo));
    Button other = button("Other", () { ran ~= "other"; });
    h.setRoot(column()(bar, new Swatch(Size(0, 150), Color.init), other));
    h.frame();
    MenuTitle file = cast(MenuTitle) bar.children[0];
    MenuTitle edit = cast(MenuTitle) bar.children[1];

    /// Middle of `n`.
    Point mid(Node n)
    {
        return Point(n.bounds.x + n.bounds.w / 2, n.bounds.y + n.bounds.h / 2);
    }

    h.inject(PointerKind.move, mid(file));
    h.inject(PointerKind.down, mid(file));
    h.frame();
    assert(bar.openMenu is file.menu);
    h.inject(PointerKind.move, mid(edit));
    h.frame();
    assert(bar.openMenu is edit.menu, "dragged onto another title");
    h.inject(PointerKind.move, mid(undo));
    h.frame();
    assert(edit.menu.list.hotItem is undo, "held press highlights");
    h.inject(PointerKind.up, mid(undo));
    h.frame();
    assert(ran == ["undo"] && bar.openMenu is null, "release ran it");

    h.inject(PointerKind.move, mid(file));
    h.inject(PointerKind.down, mid(file));
    h.inject(PointerKind.move, mid(open));
    h.inject(PointerKind.move, mid(file));
    h.inject(PointerKind.up, mid(file));
    h.frame();
    assert(bar.openMenu is file.menu && ran == ["undo"], "release on the title keeps it open");
    h.inject(PointerKind.down, mid(file));
    h.inject(PointerKind.up, mid(file));
    h.frame();
    assert(bar.openMenu is null, "a second press closes");

    h.inject(PointerKind.down, mid(file));
    h.inject(PointerKind.move, mid(other));
    h.frame();
    assert(other.hovered == false, "not hovered while held");
    h.inject(PointerKind.up, mid(other));
    h.frame();
    assert(bar.openMenu is null && ran == ["undo"], "closed, the button did not click");
    clickOn(h, other);
    assert(ran == ["undo", "other"], "input is back to normal");
}

// Island menus: a press on a menu button opens its menu below it with focus inside, a click on an item runs it
// and gives focus back, Down opens it with the first item highlighted, and a pass without the button closes
// it. A right press in a context area opens its menu there, the menu key opens it from the focus, and its
// shortcuts fire while focus is inside the area.
unittest
{
    import dentrite.immediate : canvas;
    import dentrite.widgets.button : button;
    import dentrite.island : Island, island;
    import dentrite.signals : Signal, signal;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    string[] ran;
    MenuItem open = menuItem("&Open", () { ran ~= "open"; });
    MenuItem cut = menuItem("Cu&t", () { ran ~= "cut"; }, keys: "Ctrl+X");
    Menu file = popupMenu(open);
    Menu edit = popupMenu(cut);
    Signal!bool shown = signal(true);
    int opened;
    Island isl = island((Ui ui) {
        if (shown.get && ui.menuButton("File", file))
        {
            ++opened;
        }
        ui.contextMenu(edit)({
            ui.canvas(null, float.nan, 60);
            ui.button("In");
        });
    });
    h.setRoot(isl);
    h.frame();

    /// Node of the button as last laid out.
    Node fileButton()
    {
        return isl.ui.content.children[0];
    }

    Rect b = fileButton.bounds;
    clickOn(h, fileButton);
    assert(opened == 1 && file.isOpen && h.focused is file.list && file.list.hot == -1);
    assert(file.popup.bounds.y == b.bottom && file.popup.bounds.x == b.x, "below the button");
    clickOn(h, open);
    assert(ran == ["open"] && file.isOpen == false && h.focused is isl, "ran with focus back");
    h.injectKey('x', Mod.ctrl);
    h.inject(PointerKind.move, Point(390, 290));
    h.frame();
    assert(ran == ["open"], "no shortcut from outside the area");
    file.openAt(h.tree, Point(300, 250));
    isl.invalidate();
    h.frame();
    assert((cast(ButtonBox) fileButton).state.hovered == false, "opened elsewhere, the button stays closed");
    file.close();
    h.frame();
    h.injectKey(Key.down);
    h.frame();
    assert(opened == 2 && file.isOpen && file.list.hotItem is open, "opened by Down");
    assert((cast(ButtonBox) fileButton).state.hovered, "the button shows its menu open");
    shown.set(false);
    h.frame();
    assert(file.isOpen == false && h.focused is isl, "closed with the button gone");

    Rect area = isl.ui.content.children[0].bounds;
    Point p = Point(area.x + 20, area.y + 30);
    h.inject(PointerKind.move, p);
    h.inject(PointerKind.down, p, 1, 3);
    h.inject(PointerKind.up, p, 1, 3);
    h.frame();
    assert(edit.isOpen && edit.popup.bounds.x == p.x && edit.popup.bounds.y == p.y, "at the right press");
    h.injectKey(Key.escape);
    h.frame();
    assert(edit.isOpen == false && h.focused is isl);
    Node inside = isl.ui.content.children[0].children[1];
    clickOn(h, inside);
    h.injectKey(Key.menu);
    h.frame();
    Rect ib = inside.bounds;
    assert(edit.isOpen && edit.list.hotItem is cut, "menu key");
    assert(edit.popup.bounds.x == ib.x && edit.popup.bounds.y == ib.y + min(ib.h, 32f), "at the focused control");
    h.injectKey(Key.escape);
    h.injectKey('x', Mod.ctrl);
    h.frame();
    assert(ran == ["open", "cut"], "shortcut inside the area");
}

// Keyboard: Alt and a mnemonic opens with the first item highlighted, arrows skip separators and disabled
// items, Right opens a submenu and Left closes it, Right on a command moves to the next menu, letters pick by
// mnemonic, Escape closes, and shortcuts fire from anywhere unless a disabled command owns them.
unittest
{
    import dentrite.containers : column;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.button : Button, button;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    string[] ran;
    Signal!bool canSave = signal(false);
    Signal!bool wrap = signal(false);
    MenuItem open = menuItem("&Open", () { ran ~= "open"; }, keys: "Ctrl+O");
    MenuItem save = menuItem("&Save", () { ran ~= "save"; }, keys: "Ctrl+S", enabled: &canSave.get);
    MenuItem recentA = menuItem("a.d", () { ran ~= "a"; });
    MenuItem recent = menu("&Recent")(recentA, menuItem("b.d", () { ran ~= "b"; }));
    MenuItem quit = menuItem("&Quit", () { ran ~= "quit"; }, keys: "Ctrl+Q");
    MenuItem wrapItem = menuItem("&Wrap", () { wrap.set(wrap.peek == false); }, checked: &wrap.get);
    MenuBar bar = menuBar(menu("&File")(open, save, menuSeparator(), recent, menuSeparator(), quit),
        menu("&View")(wrapItem));
    Button other = button("Other");
    h.setRoot(column()(bar, other));
    h.frame();
    Menu file = (cast(MenuTitle) bar.children[0]).menu;
    Menu view = (cast(MenuTitle) bar.children[1]).menu;

    h.setFocus(other);
    h.injectKey('f', Mod.alt);
    h.frame();
    assert(bar.openMenu is file && file.list.hotItem is open && file.list.keyboard);
    h.injectKey(Key.down);
    assert(file.list.hotItem is recent, "skipped the disabled item and the separator");
    h.injectKey(Key.up);
    assert(file.list.hotItem is open);
    h.injectKey(Key.end);
    assert(file.list.hotItem is quit);
    h.injectKey(Key.down);
    assert(file.list.hotItem is open, "wraps");

    h.injectKey('r');
    h.frame();
    Menu sub = recent.sub;
    assert(sub.isOpen && h.focused is sub.list && sub.list.hotItem is recentA, "mnemonic opened the submenu");
    assert(sub.popup.bounds.x == recent.bounds.right, "to the right");
    h.injectKey(Key.left);
    assert(sub.isOpen == false && h.focused is file.list && file.list.hotItem is recent);
    h.injectKey(Key.right);
    h.frame();
    assert(sub.isOpen && sub.list.hotItem is recentA);
    h.injectKey(Key.enter);
    assert(ran == ["a"] && bar.openMenu is null && h.focused is other);

    h.injectKey('f', Mod.alt);
    h.injectKey(Key.right);
    h.frame();
    assert(bar.openMenu is view && view.list.hotItem is wrapItem, "Right on a command: next menu");
    h.injectKey(Key.space);
    assert(wrap.peek && wrapItem.checked, "checked follows the signal");
    h.injectKey('v', Mod.alt);
    h.injectKey(Key.escape);
    assert(bar.openMenu is null && h.focused is other);

    h.injectKey('s', Mod.ctrl);
    h.injectKey('q', Mod.ctrl);
    assert(ran == ["a", "quit"], "disabled Save did not fire");
    canSave.set(true);
    assert(save.isEnabled);
    h.injectKey('s', Mod.ctrl);
    assert(ran == ["a", "quit", "save"]);
    h.injectKey('f', Mod.alt);
    h.injectKey('o', Mod.ctrl);
    assert(ran == ["a", "quit", "save", "open"] && bar.openMenu is null, "shortcut while open closes it first");
}

// Pointer and submenus: hovering an item opens its submenu after the delay without taking focus, moving
// into the submenu keeps it, resting on another item closes it, and a click on a submenu item runs it.
unittest
{
    import dentrite.containers : column;
    import dentrite.widgets.button : Button, button;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    string[] ran;
    MenuItem first = menuItem("First", () { ran ~= "first"; });
    MenuItem deep = menuItem("Deep", () { ran ~= "deep"; });
    MenuItem more = menu("More")(deep);
    MenuItem last = menuItem("Last", () { ran ~= "last"; });
    Menu m = popupMenu(first, more, last);
    Button b = button("Open");
    h.setRoot(column()(b));
    h.frame();
    m.open(b);
    h.frame();
    hoverOn(h, more);
    assert(more.sub.isOpen && h.focused is m.list && m.list.hotItem is more);
    hoverOn(h, deep);
    assert(more.sub.list.hotItem is deep && m.list.hotItem is more, "parent keeps its item highlighted");
    hoverOn(h, last);
    assert(more.sub.isOpen == false && m.list.hotItem is last);
    hoverOn(h, more);
    clickOn(h, deep);
    assert(ran == ["deep"] && m.isOpen == false && more.sub.isOpen == false);
}

// Context menus: a right press opens at the pointer, another right press elsewhere opens there, a left press
// outside closes and stops, the menu key opens at the focused node with the first item highlighted, and the
// menu's shortcuts fire while focus is inside the content.
unittest
{
    import dentrite.containers : column, sized;
    import dentrite.widgets.button : Button, button;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    int copied;
    int clicks;
    MenuItem copy = menuItem("&Copy", () { ++copied; }, keys: "Ctrl+C");
    Button target = button("Target");
    Button plain = button("Plain", onClick: () { ++clicks; });
    ContextMenu cm = contextMenu(copy)(column()(target, sized(h: 100)(new Fixed(Size.init))));
    h.setRoot(column()(cm, plain));
    h.frame();
    Menu m = cm.menu;

    Point p = Point(30, 60);
    h.inject(PointerKind.move, p);
    h.inject(PointerKind.down, p, 1, 3);
    h.inject(PointerKind.up, p, 1, 3);
    h.frame();
    assert(m.isOpen && m.popup.bounds.x == 30 && m.popup.bounds.y == 60 && copied == 0, "the release ran nothing");
    Point q = Point(250, 40);
    h.inject(PointerKind.move, q);
    h.inject(PointerKind.down, q, 1, 3);
    h.inject(PointerKind.up, q, 1, 3);
    h.frame();
    assert(m.isOpen && m.popup.bounds.x == 250, "reopened at the second press");
    clickOn(h, plain);
    assert(m.isOpen == false && clicks == 0, "left press outside closed and stopped");

    h.setFocus(target);
    h.injectKey(Key.menu);
    h.frame();
    assert(m.isOpen && m.list.hotItem is copy && m.popup.bounds.x == target.bounds.x);
    h.injectKey(Key.enter);
    assert(copied == 1 && h.focused is target);
    h.injectKey('c', Mod.ctrl);
    assert(copied == 2);
    h.setFocus(plain);
    h.injectKey('c', Mod.ctrl);
    assert(copied == 2, "focus outside the content");
}

// Screen readers: nodes inside a context menu, in an island area too, offer to open it, and asking opens it
// below the node with the first item highlighted. Nodes outside and disabled ones do not offer it.
unittest
{
    import dentrite.access : AccessDemand, AccessNode;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.island : island;
    import dentrite.platform : Event, EventKind, WindowOptions;
    import dentrite.widgets.button : Button, button;

    WindowOptions o;
    o.accessibility = true;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(400, 300);
    p.listening = AccessDemand.full;
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }

    /// Exposed node with `role` and `label` as last sent.
    const(AccessNode)* sent(Role role, string label)
    {
        const(AccessNode)* n = h.access.find(role, label);
        assert(n !is null, label);
        return n;
    }

    /// Asks for the context menu of the button named `label`.
    void ask(string label)
    {
        Event e = {kind: EventKind.access, request: AccessRequest(sent(Role.button, label).id,
            AccessAction.showContextMenu)};
        h.handle(e);
        h.frame();
    }

    MenuItem copy = menuItem("&Copy", () {});
    Button inner = button("Inner");
    Button off = button("Off");
    off.enabled = false;
    ContextMenu cm = contextMenu(copy)(column()(inner, off));
    h.setRoot(column()(cm, button("Outside")));
    h.frame();
    assert(sent(Role.button, "Inner").info.allows(AccessAction.showContextMenu));
    assert(sent(Role.button, "Off").info.allows(AccessAction.showContextMenu) == false, "disabled");
    assert(sent(Role.button, "Outside").info.allows(AccessAction.showContextMenu) == false, "outside");
    ask("Inner");
    assert(cm.menu.isOpen && cm.menu.list.hotItem is copy);
    assert(cm.menu.popup.bounds.x == inner.bounds.x && cm.menu.popup.bounds.y > inner.bounds.y);
    cm.menu.close();

    Menu edit = popupMenu(menuItem("Cu&t", () {}));
    h.setRoot(island((Ui ui) {
        ui.button("Plain");
        ui.contextMenu(edit)({ ui.button("In"); });
    }));
    h.frame();
    h.frame();
    assert(sent(Role.button, "Plain").info.allows(AccessAction.showContextMenu) == false);
    assert(sent(Role.button, "In").info.allows(AccessAction.showContextMenu));
    ask("In");
    assert(edit.isOpen && edit.list.hot == 0, "island area");
}

// Rows of a virtual list take focus on press, so Delete reaches their context menu. Removing the focused row
// clears focus, though its pooled node stays in the tree with another item.
unittest
{
    import dentrite.containers : scroll, sized;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.list : ListItem, VirtualList, listItem, virtualList;
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.range : iota;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    Signal!(int[]) items = signal(iota(30).array);
    Signal!int selected = signal(-1);

    /// Row for the item `it` returns, removed by its context menu.
    Node row(int delegate() it)
    {
        MenuItem remove = menuItem("&Remove", () { items.set(items.peek.filter!(i => i != it()).array); },
            keys: "Delete");
        return contextMenu(remove)(listItem(onClick: () { selected.set(it()); })(new Fixed(Size(100, 20))));
    }

    VirtualList!(int, int) rows = virtualList!(int, int)(() => items.get, (int i) => i, &row);
    h.setRoot(sized(h: 100)(scroll()(rows)));
    h.frame();
    Node two = rows[2];
    ListItem item = cast(ListItem) two.children[0];
    clickOn(h, item);
    assert(selected.peek == 2 && h.focused is item);
    h.injectKey(Key.delete_);
    h.frame();
    assert(items.peek.length == 29 && items.peek[2] == 3);
    assert(two.tree !is null && rows[2] is null, "pooled node took another item");
    assert(h.focused is null);
    h.injectKey(Key.delete_);
    assert(items.peek.length == 29, "nothing focused");

    ListItem five = cast(ListItem) rows[5].children[0];
    h.setFocus(five);
    h.injectKey(' ');
    assert(selected.peek == 5, "space selects");
}

// With a selection the list holds focus, and Delete and the menu key reach the selected row's context menu.
unittest
{
    import dentrite.containers : scroll, sized;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.list : ListItem, VirtualList, listItem, virtualList;
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.range : iota;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    Signal!(int[]) items = signal(iota(30).array);
    Signal!int selected = signal(-1);
    Menu shown;

    /// Row for the item `it` returns, removed by its context menu.
    Node row(int delegate() it)
    {
        MenuItem remove = menuItem("&Remove", () { items.set(items.peek.filter!(i => i != it()).array); },
            keys: "Delete");
        return contextMenu(remove)(listItem(onClick: () { selected.set(it()); },
            selected: () => selected.get == it())(new Fixed(Size(100, 20))));
    }

    VirtualList!(int, int) rows = virtualList!(int, int)(() => items.get, (int i) => i, &row, selected);
    h.setRoot(sized(h: 100)(scroll()(rows)));
    h.frame();
    clickOn(h, rows[2].children[0]);
    assert(selected.peek == 2 && h.focused is rows);
    h.injectKey(Key.down);
    h.injectKey(Key.delete_);
    h.frame();
    assert(items.peek.length == 29 && items.peek[3] == 4, "the selected row 3 is gone");
    selected.set(4);
    h.frame();
    h.injectKey(Key.menu);
    h.frame();
    ContextMenu cm = cast(ContextMenu) rows[4];
    assert(cm.menu.isOpen, "menu key opens the selected row's menu");
}

// A touch press held still opens the context menu where it went down and cancels the button's press, and its
// release runs nothing. One that moves, lifts early or comes from the mouse clicks as usual.
unittest
{
    import core.time : msecs;
    import dentrite.containers : column;
    import dentrite.widgets.button : Button, button;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    int copied;
    int clicks;
    Button target = button("Target", onClick: () { ++clicks; });
    ContextMenu cm = contextMenu(menuItem("&Copy", () { ++copied; }))(target);
    h.setRoot(column()(cm));
    h.frame();
    Menu m = cm.menu;
    Point p = Point(target.bounds.x + 10, target.bounds.y + 5);
    MonoTime t = MonoTime.currTime - 2000.msecs;
    void touch(PointerKind k, Point at, int ms, PointerSource from = PointerSource.touch)
    {
        h.inject(k, at, 1, 1, 0, from, t + ms.msecs);
    }

    touch(PointerKind.down, p, 0);
    assert(target.pressed);
    h.frame();
    assert(m.isOpen && m.popup.bounds.x == p.x && target.pressed == false, "opened, the press cancelled");
    touch(PointerKind.up, p, 600);
    h.frame();
    assert(m.isOpen && clicks == 0 && copied == 0, "the release ran nothing");
    m.close();
    h.frame();

    touch(PointerKind.down, p, 1000);
    touch(PointerKind.move, Point(p.x + 20, p.y), 1010);
    h.frame();
    assert(m.isOpen == false, "moved");
    touch(PointerKind.up, Point(p.x + 20, p.y), 1020);
    assert(clicks == 1, "the moved press still clicks");
    touch(PointerKind.down, p, 1100);
    touch(PointerKind.up, p, 1200);
    h.frame();
    assert(m.isOpen == false && clicks == 2, "a tap clicks");
    touch(PointerKind.down, p, 1300, PointerSource.mouse);
    h.frame();
    assert(m.isOpen == false, "not for the mouse");
    touch(PointerKind.up, p, 1400, PointerSource.mouse);
}

// A command with only `keysLabel` shows its shortcut in the menu and to screen readers, and the bar does not
// fire it.
unittest
{
    import dentrite.command : command;

    Host h = menuHost();
    scope (exit)
    {
        h.close();
    }
    int ran;
    MenuItem prev = menuItem(command("&Previous", () { ++ran; }, keysLabel: "["));
    MenuItem save = menuItem(command("&Save", () { ++ran; }, keys: "Ctrl+S", keysLabel: "Ctrl+S, F2"));
    MenuBar bar = menuBar(menu("&Go")(prev, save));
    h.setRoot(bar);
    h.frame();
    assert(prev.keysText == "[" && save.keysText == "Ctrl+S, F2");
    h.injectKey('[');
    assert(ran == 0, "a label alone binds nothing");
    h.injectKey('s', Mod.ctrl);
    assert(ran == 1, "keys still fire");
}
