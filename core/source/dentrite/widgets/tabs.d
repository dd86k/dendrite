/// Tabs, a strip of titles choosing one page, on its own for app-managed content or in a view over fixed pages.
module dentrite.widgets.tabs;

import dentrite.access : AccessParts;
import dentrite.node;
import dentrite.signals : Signal, effect;
import dentrite.text;
import dentrite.widgets.icons;
import std.algorithm.comparison : clamp, max, min;
import std.algorithm.searching : any;
import std.math : abs, ceil, isInfinity, round;

/// Look of a tab strip.
struct TabsStyle
{
    enum section = "tabs"; /// section name in theme files

    Color bar;                                         /// strip background, none when transparent
    Color line = Color(0x3a, 0x3a, 0x40, 0xff);        /// line under the strip, none when transparent
    Color tabHover = Color(0xff, 0xff, 0xff, 0x0a);    /// tab under the pointer
    Color tabActive;                                   /// chosen tab background, none when transparent
    Color text = Color(0x9a, 0x9a, 0xa2, 0xff);        /// title
    Color textHover = Color(0xdd, 0xdd, 0xdd, 0xff);   /// title under the pointer
    Color textActive = Color(0xee, 0xee, 0xee, 0xff);  /// chosen title
    Color textDisabled = Color(0x5c, 0x5c, 0x62, 0xff); /// title of a disabled tab
    Color accent = Color(0x3a, 0x7b, 0xe8, 0xff);      /// mark under the chosen tab
    Color closeHover = Color(0xff, 0xff, 0xff, 0x1a);  /// close button under the pointer
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff);       /// focus ring around the chosen tab
    float padX = 12;        /// space between the title and the sides of its tab
    float padY = 7;         /// space between the title and the top and bottom of the strip
    float accentHeight = 2; /// thickness of the mark under the chosen tab
    float closeSize = 8;    /// close icon size
    float closeGap = 8;     /// space between the title and the close icon
    float iconSize = 12;    /// tab icon size
    float iconGap = 6;      /// space between the tab icon and the title
    float stackPadY = 10;   /// in stacked tabs, space above the icon and below the title
    float stackGap = 5;     /// in stacked tabs, space between the icon and the title
    float fade = 24;        /// fade at a cut edge of a strip wider than its space
    FontKind font = FontKind.ui; /// title font
    float size = 13;        /// title size
}

/// Strip of tab titles bound to the index of the chosen tab. Build it with `tabBar`, or get one inside `tabs`.
///
/// A press chooses a tab, arrows and Home and End move the choice, the wheel scrolls a strip wider than its
/// space, which fades out at an edge with more tabs past it, and the chosen tab scrolls into view. With `onClose`
/// set, tabs show a close button when chosen or under the pointer, and a middle click closes too.
/// Closing only calls `onClose`, which updates titles and index. Disabled tabs show dimmed, and presses, keys and
/// screen readers skip them. Disabling the chosen tab leaves it chosen, so move the choice first.
final class TabBar : Node, AccessParts
{
    void delegate(size_t index) onClose; /// runs to close tab `index`, null for tabs without a close button
    bool stacked;                          /// icon above the title instead of before it, set before the first layout
    private Signal!size_t current; /// index of the chosen tab
    private string[] titles;       /// tab titles
    private Icon[] icons;         /// tab icons, may be shorter than `titles`
    private bool[] disabled;       /// disabled tabs, may be shorter than `titles`
    private float[] widths;        /// tab widths from the last layout
    private size_t shown;          /// `current` last read
    private float scrollX = 0;     /// strip shift
    private bool reveal = true;    /// scroll the chosen tab into view at the next paint
    private ptrdiff_t hot = -1;    /// tab under the pointer, or -1
    private bool hotClose;         /// pointer over the close button of `hot`
    private ptrdiff_t pressedClose = -1; /// tab whose close button or middle button was pressed, or -1

    /// Strip over `current`. The binding effect belongs to the current owner.
    this(Signal!size_t current)
    {
        this.current = current;
        interactive = true;
        focusable = true;
        effect(() {
            size_t v = current.get;
            if (v != shown)
            {
                shown = v;
                reveal = true;
                markNeedsPaint();
            }
        });
    }

    /// Replaces the titles.
    void setTitles(string[] titles)
    {
        if (titles != this.titles)
        {
            this.titles = titles.dup;
            hot = -1;
            reveal = true;
            markNeedsLayout();
        }
    }

    /// Replaces the icons, empty or missing entries leave a tab text only.
    void setIcons(Icon[] icons)
    {
        if (icons != this.icons)
        {
            this.icons = icons.dup;
            markNeedsLayout();
        }
    }

    /// Replaces which tabs are disabled, missing entries are enabled.
    void setDisabled(bool[] disabled)
    {
        if (disabled != this.disabled)
        {
            this.disabled = disabled.dup;
            if (hot >= 0 && enabledAt(hot) == false)
            {
                hot = -1;
            }
            markNeedsPaint();
        }
    }

    /// Whether tab `i` can be chosen.
    bool enabledAt(size_t i) const
    {
        return i >= disabled.length || disabled[i] == false;
    }

    /// Nearest enabled tab from `from` stepping by `step` (1 or -1), `from` included, or -1.
    private ptrdiff_t enabledFrom(ptrdiff_t from, ptrdiff_t step) const
    {
        for (ptrdiff_t i = from; i >= 0 && i < titles.length; i += step)
        {
            if (enabledAt(i))
            {
                return i;
            }
        }
        return -1;
    }

    /// Whether any tab has an icon.
    private bool anyIcon()
    {
        foreach (ref const Icon i; icons)
        {
            if (i.empty == false)
            {
                return true;
            }
        }
        return false;
    }

    /// Icon of tab `i`, or `Icon.none`.
    private Icon iconOf(size_t i)
    {
        return i < icons.length ? icons[i] : Icon.none;
    }

    /// Number of tabs.
    size_t length() const
    {
        return titles.length;
    }

    /// Rect of tab `i` in window coordinates, as laid out and scrolled.
    Rect tabRect(size_t i)
    {
        Rect b = bounds;
        float x = b.x - round(scrollX);
        foreach (size_t k; 0 .. i)
        {
            x += widths[k];
        }
        return Rect(x, b.y, widths[i], b.h);
    }

    /// Tab list, its tabs are parts.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.tabList;
    }

    /// Number of tabs, each one an access part.
    size_t accessPartCount()
    {
        return min(titles.length, widths.length);
    }

    /// Tab `i` named by its title, selected when chosen.
    void describePart(size_t i, ref AccessInfo a, ref Rect r)
    {
        a.role = Role.tab;
        a.label = titles[i];
        a.selected = tri(i == shown);
        a.disabled = enabledAt(i) == false;
        a.allow(AccessAction.click);
        r = tabRect(i);
    }

    /// Click and focus choose tab `i`.
    bool accessPartAction(size_t i, ref const AccessRequest r)
    {
        if ((r.action != AccessAction.click && r.action != AccessAction.focus) || enabledAt(i) == false)
        {
            return false;
        }
        current.set(i);
        return true;
    }

    /// The chosen tab while the strip has focus.
    ptrdiff_t accessFocusPart()
    {
        return focused && shown < titles.length ? shown : -1;
    }

    /// Close button of tab rect `r`.
    private Rect closeRect(Rect r, const ref TabsStyle s)
    {
        float c = s.closeSize;
        return Rect(r.right - s.padX - c, r.y + round((r.h - c) / 2), c, c);
    }

    /// Width of every tab together.
    private float total() const
    {
        float w = 0;
        foreach (float x; widths)
        {
            w += x;
        }
        return w;
    }

    /// Tab widths from the titles, the bounded width or the sum, one line tall.
    protected override Size performLayout(Constraints c)
    {
        TabsStyle s = tree.style!TabsStyle();
        TextSystem t = tree.text;
        widths.length = titles.length;
        foreach (size_t i, string title; titles)
        {
            float tw = t.measure(s.font, s.size, title);
            float content = stacked ? max(tw, iconOf(i).empty == false ? s.iconSize : 0f)
                : tw + (iconOf(i).empty == false ? s.iconSize + s.iconGap : 0);
            widths[i] = ceil(s.padX * 2 + content
                + (onClose !is null ? s.closeGap + s.closeSize : 0));
        }
        float h = t.lineHeight(s.font, s.size) + s.padY * 2;
        if (stacked)
        {
            h = t.lineHeight(s.font, s.size) + s.stackPadY * 2 + (anyIcon ? s.iconSize + s.stackGap : 0);
        }
        return c.constrain(Size(isInfinity(c.maxW) ? total : c.maxW, h));
    }

    /// Tab under window point `p`, or -1, and whether it is over its close button.
    private ptrdiff_t tabAt(Point p, out bool onClose_)
    {
        TabsStyle s = tree.style!TabsStyle();
        if (bounds.contains(p) == false)
        {
            return -1;
        }
        foreach (size_t i; 0 .. titles.length)
        {
            Rect r = tabRect(i);
            if (r.contains(p))
            {
                onClose_ = onClose !is null && closeRect(r, s).inset(-3).contains(p);
                return i;
            }
        }
        return -1;
    }

    /// Hover tracking, a press chooses a tab or arms its close button, a release on the armed button closes.
    override bool onPointer(ref const PointerEvent e)
    {
        bool overClose;
        ptrdiff_t at = tabAt(e.pos, overClose);
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.move:
        case PointerKind.leave:
            if (e.kind == PointerKind.leave || (at >= 0 && enabledAt(at) == false))
            {
                at = -1;
                overClose = false;
            }
            if (at != hot || overClose != hotClose)
            {
                hot = at;
                hotClose = overClose;
                markNeedsPaint();
            }
            return true;
        case PointerKind.down:
            if (at < 0)
            {
                return false;
            }
            if (enabledAt(at) == false)
            {
                return true;
            }
            if (e.button == 1 && overClose == false)
            {
                current.set(at);
            }
            else if (onClose !is null && (e.button == 2 || (e.button == 1 && overClose)))
            {
                pressedClose = at;
            }
            return true;
        case PointerKind.up:
            ptrdiff_t armed = pressedClose;
            pressedClose = -1;
            if (armed >= 0 && armed == at && (overClose || e.button == 2))
            {
                onClose(armed);
            }
            return true;
        case PointerKind.cancel:
            pressedClose = -1;
            return true;
        default:
            return false;
        }
    }

    /// Scrolls a strip wider than its space.
    override bool onWheel(ref const WheelEvent e)
    {
        float over = total - size.w;
        if (over <= 0)
        {
            return false;
        }
        scrollX = clamp(scrollX + (e.dy != 0 ? e.dy : e.dx), 0, over);
        markNeedsPaint();
        return true;
    }

    /// Left and Right choose the neighbor enabled tab, Home and End the first and last enabled ones.
    override bool onKey(ref const KeyEvent e)
    {
        if (titles.length == 0)
        {
            return false;
        }
        ptrdiff_t last = titles.length - 1;
        ptrdiff_t at = min(shown, last);
        ptrdiff_t to;
        switch (e.key)
        {
        case Key.left:
            to = enabledFrom(at - 1, -1);
            break;
        case Key.right:
            to = enabledFrom(at + 1, 1);
            break;
        case Key.home:
            to = enabledFrom(0, 1);
            break;
        case Key.end:
            to = enabledFrom(last, -1);
            break;
        default:
            return false;
        }
        if (to >= 0)
        {
            current.set(to);
        }
        return true;
    }

    /// Repaints to show or hide the focus ring.
    override void onFocus(bool gained)
    {
        markNeedsPaint();
    }

    /// Strip, tabs with titles and close buttons, the mark under the chosen tab and the focus ring.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TabsStyle s = ctx.style!TabsStyle();
        TextSystem t = ctx.text;
        Rect b = Rect(origin.x, origin.y, size.w, size.h);
        float over = max(0f, total - size.w);
        if (reveal && shown < widths.length)
        {
            float x0 = 0;
            foreach (size_t k; 0 .. shown)
            {
                x0 += widths[k];
            }
            // keep the chosen tab clear of the fades, its start first when it does not fit
            scrollX = min(max(scrollX, x0 + widths[shown] - size.w + s.fade), x0 - s.fade);
            reveal = false;
        }
        scrollX = clamp(scrollX, 0, over);
        if (s.bar.a > 0)
        {
            ctx.list.rect(b, s.bar);
        }
        if (s.line.a > 0)
        {
            ctx.list.hline(b.x, b.right, b.bottom - 1, s.line);
        }
        float base = b.y + round((b.h - t.lineHeight(s.font, s.size)) / 2) + t.ascent(s.font, s.size);
        ctx.clipped(b, {
            if (over > 0)
            {
                ctx.list.pushFade(b, min(s.fade, round(scrollX)), min(s.fade, over - round(scrollX)));
            }
            scope (exit)
            {
                if (over > 0)
                {
                    ctx.list.popFade();
                }
            }
            float x = b.x - round(scrollX);
            foreach (size_t i, string title; titles)
            {
                Rect r = Rect(x, b.y, widths[i], b.h);
                x += widths[i];
                if (r.right < b.x || r.x > b.right)
                {
                    continue;
                }
                bool active = i == shown;
                bool over_ = i == hot;
                if (active && s.tabActive.a > 0)
                {
                    ctx.list.rect(r, s.tabActive);
                }
                else if (over_)
                {
                    ctx.list.rect(r, s.tabHover);
                }
                bool on = enabledAt(i);
                Color ink = on == false ? s.textDisabled : active ? s.textActive : over_ ? s.textHover : s.text;
                float tx = r.x + s.padX;
                float tbase = base;
                if (stacked)
                {
                    float tw = t.measure(s.font, s.size, title);
                    float closeW = onClose !is null ? s.closeGap + s.closeSize : 0;
                    float cx = r.x + s.padX + (r.w - s.padX * 2 - closeW) / 2;
                    tx = cx - tw / 2;
                    float top = r.y + s.stackPadY;
                    if (iconOf(i).empty == false)
                    {
                        Rect ir = Rect(cx - s.iconSize / 2, top, s.iconSize, s.iconSize);
                        paintIcon(*ctx.list, iconOf(i), ir, ink, on == false);
                    }
                    tbase = top + (anyIcon ? s.iconSize + s.stackGap : 0) + t.ascent(s.font, s.size);
                }
                else if (iconOf(i).empty == false)
                {
                    float iy = b.y + round((b.h - s.iconSize) / 2);
                    paintIcon(*ctx.list, iconOf(i), Rect(tx, iy, s.iconSize, s.iconSize), ink, on == false);
                    tx += s.iconSize + s.iconGap;
                }
                ctx.list.text(t.shape(s.font, s.size, title), Point(tx, tbase), ink);
                if (onClose !is null && on && (active || over_))
                {
                    Rect cr = closeRect(r, s);
                    if (over_ && hotClose)
                    {
                        ctx.list.rect(cr.inset(-3), s.closeHover, 3);
                    }
                    paintIcon(*ctx.list, Icon.close, cr, ink);
                }
                if (active)
                {
                    ctx.list.rect(Rect(r.x, r.bottom - s.accentHeight, r.w, s.accentHeight), s.accent);
                    if (focusRing)
                    {
                        ctx.list.rect(r.inset(Insets(2, 2, 2, 2 + s.accentHeight)), Color.init, 3, s.focus, 1);
                    }
                }
            }
        });
    }
}

/// Tab strip over `titles` choosing `current`: `tabBar(() => files.get.map!(f => f.name).array, open)`.
/// `onClose` adds close buttons, `icons` go before the titles, or above them with `stacked`. `enabled` says
/// whether tab `index` can be chosen, null for all. The effects belong to the current owner.
TabBar tabBar(string[] delegate() titles, Signal!size_t current, void delegate(size_t index) onClose = null,
    Icon[] icons = null, bool stacked = false, bool delegate(size_t index) enabled = null)
{
    TabBar b = new TabBar(current);
    b.onClose = onClose;
    b.setIcons(icons);
    b.stacked = stacked;
    effect(() {
        string[] t = titles();
        b.setTitles(t);
        b.setDisabled(disabledOf(t.length, enabled));
    });
    return b;
}

/// Which of `n` tabs `enabled` turns off, or null for none.
private bool[] disabledOf(size_t n, bool delegate(size_t index) enabled)
{
    if (enabled is null)
    {
        return null;
    }
    bool[] off = new bool[n];
    foreach (size_t i; 0 .. n)
    {
        off[i] = enabled(i) == false;
    }
    return off;
}

/// Tab strip over fixed `titles`: `tabBar(["Output", "Problems"], panel)`.
TabBar tabBar(string[] titles, Signal!size_t current, void delegate(size_t index) onClose = null,
    Icon[] icons = null, bool stacked = false, bool delegate(size_t index) enabled = null)
{
    TabBar b = new TabBar(current);
    b.onClose = onClose;
    b.setIcons(icons);
    b.stacked = stacked;
    b.setTitles(titles);
    if (enabled !is null)
    {
        effect(() { b.setDisabled(disabledOf(titles.length, enabled)); });
    }
    return b;
}

/// Title and page of a tab in `tabs`.
struct Tab
{
    string title; /// strip title
    Node page;    /// page shown while this tab is chosen
    Icon icon;    /// icon before the title, `Icon.none` for text only
    bool delegate() enabled; /// whether the tab can be chosen, null for always
}

/// Tab for `tabs`: `tab("General", generalPage())`. `icon` shows before the title, `enabled` may read signals.
Tab tab(string title, Node page, Icon icon = Icon.none, bool delegate() enabled = null)
{
    return Tab(title, page, icon, enabled);
}

/// Strip over the chosen page. Pages not shown are detached, so they keep their state.
final class TabView : Node
{
    TabBar bar;          /// tab strip above the pages
    private Node[] pages; /// every page, in tab order

    /// View over `tabs` choosing with `current`. The effects belong to the current owner.
    this(Signal!size_t current, Tab[] tabs, bool stacked = false)
    {
        bar = new TabBar(current);
        bar.stacked = stacked;
        string[] titles;
        Icon[] icons;
        foreach (Tab t; tabs)
        {
            titles ~= t.title;
            icons ~= t.icon;
            pages ~= t.page;
        }
        bar.setTitles(titles);
        bar.setIcons(icons);
        add(bar);
        if (tabs.any!(t => t.enabled !is null))
        {
            effect(() {
                bool[] off = new bool[tabs.length];
                foreach (size_t k, Tab t; tabs)
                {
                    off[k] = t.enabled !is null && t.enabled() == false;
                }
                bar.setDisabled(off);
            });
        }
        effect(() {
            size_t i = current.get;
            setChildren(i < pages.length ? [bar, pages[i]] : [cast(Node) bar]);
        });
    }

    /// Page `i`.
    Node page(size_t i)
    {
        return pages[i];
    }

    /// The strip on top at the full width, the page under it filling the rest of a bounded height or at its own.
    /// Unbounded, the width is the wider of the strip and the page.
    protected override Size performLayout(Constraints c)
    {
        float w = c.maxW;
        Node p = children.length > 1 ? children[1] : null;
        if (isInfinity(w))
        {
            w = bar.layout(Constraints.init).w;
            if (p !is null)
            {
                w = max(w, p.layout(Constraints(0, float.infinity, 0, max(0f, c.maxH - bar.size.h))).w);
            }
            w = max(w, c.minW);
        }
        Size bs = bar.layout(Constraints(w, w, 0, float.infinity));
        bar.offset = Point.init;
        float h = bs.h;
        if (p !is null)
        {
            Size ps = p.layout(Constraints(w, w, max(0f, c.minH - bs.h), max(0f, c.maxH - bs.h)));
            p.offset = Point(0, bs.h);
            h += ps.h;
        }
        return c.constrain(Size(w, h));
    }
}

/// Options of `tabs`, waiting for the tabs.
struct TabsSpec
{
    Signal!size_t current; /// index of the chosen tab
    bool stacked;          /// icons above the titles

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Signal!size_t current, bool stacked = false)
    {
        this.current = current;
        this.stacked = stacked;
    }

    /// The view over `kids`.
    TabView opCall(Tab[] kids...)
    {
        return new TabView(current, kids.dup, stacked);
    }
}

/// Tab view over fixed pages: `tabs(current)(tab("General", general), tab("Advanced", advanced))`.
TabsSpec tabs(Signal!size_t current, bool stacked = false)
{
    return TabsSpec(current, stacked);
}

// A press chooses, keys move the choice, the view shows the chosen page only, and a close button press and
// release on it calls `onClose`.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(400, 200);
    scope (exit)
    {
        h.close();
    }
    Signal!size_t cur = signal(size_t(0));
    Node a = label("first page");
    Node b = label("second page");
    TabView v = tabs(cur)(tab("One", a), tab("Two", b), tab("Three", label("third")));
    h.setRoot(column()(v));
    h.frame();
    assert(v.size.w == 400 && v.children.length == 2 && v.children[1] is a && b.parent is null);
    assert(a.bounds.y == v.bar.size.h);

    Rect two = v.bar.tabRect(1);
    h.inject(PointerKind.move, mid(two));
    h.inject(PointerKind.down, mid(two));
    h.inject(PointerKind.up, mid(two));
    h.frame();
    assert(cur.peek == 1 && v.children[1] is b && a.parent is null && h.focused is v.bar);
    h.injectKey(Key.end, 0);
    assert(cur.peek == 2);
    h.injectKey(Key.left, 0);
    h.injectKey(Key.left, 0);
    h.injectKey(Key.left, 0);
    assert(cur.peek == 0, "Left stops at the first tab");

    string[] names = ["a.d", "b.d", "c.d"];
    Signal!(string[]) files = signal(names);
    size_t closed = size_t.max;
    TabBar bar = tabBar(() => files.get, cur, (size_t i) { closed = i; });
    h.setRoot(column()(bar));
    h.frame();
    TabsStyle s;
    Rect r = bar.tabRect(0);
    Point x = Point(r.right - s.padX - s.closeSize / 2, r.y + r.h / 2);
    h.inject(PointerKind.move, x);
    h.inject(PointerKind.down, x);
    assert(cur.peek == 0 && closed == size_t.max, "the press only arms the close button");
    h.inject(PointerKind.up, x);
    assert(closed == 0);
    files.set(["a.d", "b.d"]);
    h.frame();
    assert(bar.length == 2);
}

// Disabled tabs ignore presses, keys skip them, and they follow their `enabled` signal.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(400, 200);
    scope (exit)
    {
        h.close();
    }
    Signal!size_t cur = signal(size_t(0));
    Signal!bool twoOn = signal(false);
    TabView v = tabs(cur)(tab("One", label("1")), tab("Two", label("2"), enabled: () => twoOn.get),
        tab("Three", label("3")));
    h.setRoot(column()(v));
    h.frame();
    Rect two = v.bar.tabRect(1);
    h.inject(PointerKind.move, mid(two));
    h.inject(PointerKind.down, mid(two));
    h.inject(PointerKind.up, mid(two));
    assert(cur.peek == 0, "press on a disabled tab");
    h.setFocus(v.bar);
    h.injectKey(Key.right, 0);
    assert(cur.peek == 2, "Right skips it");
    h.injectKey(Key.left, 0);
    assert(cur.peek == 0, "so does Left");
    h.injectKey(Key.home, 0);
    assert(cur.peek == 0);
    AccessInfo a;
    Rect ar;
    v.bar.describePart(1, a, ar);
    assert(a.disabled, "screen readers see it disabled");
    twoOn.set(true);
    h.frame();
    h.injectKey(Key.right, 0);
    assert(cur.peek == 1, "enabled again");
    v.bar.describePart(1, a, ar);
    assert(a.disabled == false);

    TabBar bar = tabBar(["a", "b", "c"], cur, enabled: (size_t i) => i != 2);
    h.setRoot(column()(bar));
    h.frame();
    h.setFocus(bar);
    h.injectKey(Key.end, 0);
    assert(cur.peek == 1, "End stops at the last enabled tab");
}

// Icons widen a tab by the icon and its gap, and tabs without one keep the title width.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!size_t cur = signal(size_t(0));
    TabBar plain = tabBar(["Run", "Stop"], cur);
    TabBar icon = tabBar(["Run", "Stop"], cur, icons: [Icon.play]);
    h.setRoot(column()(plain, icon));
    h.frame();
    TabsStyle s;
    assert(icon.tabRect(0).w == plain.tabRect(0).w + s.iconSize + s.iconGap);
    assert(icon.tabRect(1).w == plain.tabRect(1).w);
}

// A strip wider than its space scrolls the chosen tab into view and scrolls with the wheel.
unittest
{
    import dentrite.containers : column, row, sized;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!size_t cur = signal(size_t(0));
    TabBar bar = tabBar(["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"], cur);
    h.setRoot(column()(row()(sized(w: 150)(bar))));
    h.frame();
    assert(bar.size.w == 150 && bar.tabRect(0).x == 0);
    cur.set(5);
    h.frame();
    assert(bar.tabRect(5).right == 150, "the last tab scrolled in at the right end");
    WheelEvent w = WheelEvent(mid(bar.tabRect(5)), 0, -1e6);
    bar.onWheel(w);
    h.frame();
    assert(bar.tabRect(0).x == 0);
}

// A strip wider than its space fades out at an edge with more tabs past it, and keeps the chosen tab clear.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column, row, sized;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.theme : Theme;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 100);
    scope (exit)
    {
        h.close();
    }
    h.tree.theme = new Theme("[tabs]\ntabHover = #ffffff\nfade = 24\n", "test");
    Signal!size_t cur = signal(size_t(0));
    TabBar bar = tabBar(["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"], cur);
    h.setRoot(column()(row()(sized(w: 150)(bar))));
    SoftwareRenderer r = cast(SoftwareRenderer) h.renderer;
    /// Share of the hover color over the background at `x`, at the top of the strip.
    float hover(int x)
    {
        float bg = r.pixels[50 * r.width + 200] & 0xff;
        return ((r.pixels[2 * r.width + x] & 0xff) - bg) / (255 - bg);
    }

    h.inject(PointerKind.move, Point(10, bar.size.h / 2));
    h.frame();
    assert(hover(1) == 1 && hover(20) == 1, "nothing cut on the left");
    h.inject(PointerKind.move, Point(140, bar.size.h / 2));
    h.frame();
    assert(hover(149) < 0.1f, "cut on the right");
    cur.set(2);
    h.frame();
    assert(bar.tabRect(2).x >= 24 && bar.tabRect(2).right <= 150 - 24, "the chosen tab is clear of both fades");
    cur.set(5);
    h.frame();
    h.inject(PointerKind.move, Point(11, bar.size.h / 2));
    h.frame();
    assert(abs(hover(1) - 1.5f / 24) < 0.02f && abs(hover(20) - 20.5f / 24) < 0.02f, "the left edge fades");
}

version (unittest)
{
    /// Middle of `r`.
    private Point mid(Rect r)
    {
        return Point(r.x + r.w / 2, r.y + r.h / 2);
    }
}
