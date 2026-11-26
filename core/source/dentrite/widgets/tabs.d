/// Tabs, a strip of titles choosing one page, on its own for app-managed content or in a view over fixed pages.
module dentrite.widgets.tabs;

import dentrite.access : AccessParts;
import dentrite.draw : DrawList;
import dentrite.node;
import dentrite.signals : Signal, effect;
import dentrite.text;
import dentrite.widgets.icons;
import std.algorithm.comparison : clamp, max, min;
import std.algorithm.searching : any;
import std.math : abs, ceil, isInfinity, isNaN, round;
import std.string : stripRight;
import std.utf : stride;

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
    float markGap = 6;      /// space before each mark after a title
    float maxTitle = 0;     /// widest title before it is shortened, 0 for no limit
    Color track = Color(0xff, 0xff, 0xff, 0x20);       /// unfilled part of a tab's progress bar
    Color progress = Color(0x4c, 0x8d, 0xf6, 0xff);    /// filled part of a tab's progress bar
    FontKind font = FontKind.ui; /// title font
    float size = 13;        /// title size
}

/// What a tab shows, for `TabBar.setTabs` and `DockView.tabInfo`. Marks follow the title in field order. The
/// modified dot sits where the close button goes and gives way to it on the chosen or hovered tab.
struct TabInfo
{
    string title;   /// title, in a dock null for the pane's title
    Icon icon;      /// icon before the title, `Icon.none` for none
    string tooltip; /// text shown while the pointer rests on the tab, null for none
    string badge;   /// short text after the title, such as "×2", null for none
    bool locked;    /// lock after the title, such as for a read-only file
    float progress = float.nan; /// small bar after the title, filled from 0 to 1, NaN for none
    bool modified;  /// dot for unsaved changes
}

/// Sizes and colors for drawing tabs, from `TabsStyle` or `DockStyle`.
package(dentrite) struct TabLook
{
    FontKind font;    /// title font
    float size;       /// title size
    float padX;       /// space between the content and the sides of a tab
    float iconSize;   /// icon and lock size
    float iconGap;    /// space after the icon
    float closeSize;  /// close icon size
    float closeGap;   /// space before the close icon
    float markGap;    /// space before each mark
    float maxTitle;   /// widest title before it is shortened, 0 for no limit
    Color closeHover; /// close button under the pointer
    Color track;      /// unfilled part of a progress bar
    Color progress;   /// filled part of a progress bar
}

/// Width of a tab's progress bar.
private enum float barW = 16;

/// Height of a tab's progress bar.
private enum float barH = 3;

/// `title` cut at a code point with an ellipsis added to fit `maxW`, whole when it fits or `maxW` is 0.
package(dentrite) string shortTitle(TextSystem t, FontKind font, float size, string title, float maxW)
{
    if (maxW <= 0 || t.measure(font, size, title) <= maxW)
    {
        return title;
    }
    size_t[] cuts;
    for (size_t i = 0; i < title.length; i += stride(title, i))
    {
        cuts ~= i;
    }
    size_t lo = 0;
    size_t hi = cuts.length - 1;
    while (lo < hi)
    {
        size_t mid = (lo + hi + 1) / 2;
        if (t.measure(font, size, title[0 .. cuts[mid]].stripRight ~ "…") <= maxW)
        {
            lo = mid;
        }
        else
        {
            hi = mid - 1;
        }
    }
    return title[0 .. cuts[lo]].stripRight ~ "…";
}

/// Width of the title line of `info`: the title shortened to `l.maxTitle`, then its marks.
package(dentrite) float lineWidth(TextSystem t, const ref TabLook l, const ref TabInfo info)
{
    float w = t.measure(l.font, l.size, shortTitle(t, l.font, l.size, info.title, l.maxTitle));
    if (info.badge.length > 0)
    {
        w += l.markGap + t.measure(l.font, l.size, info.badge);
    }
    if (info.locked)
    {
        w += l.markGap + l.iconSize;
    }
    if (isNaN(info.progress) == false)
    {
        w += l.markGap + barW;
    }
    return w;
}

/// Width of a tab laid out in a row: sides, icon, title line, and the close slot when `slot`.
package(dentrite) float rowWidth(TextSystem t, const ref TabLook l, const ref TabInfo info, bool slot)
{
    return ceil(l.padX * 2 + (info.icon.empty ? 0 : l.iconSize + l.iconGap) + lineWidth(t, l, info)
        + (slot ? l.closeGap + l.closeSize : 0));
}

/// Draws the title line of `info` from `x` on baseline `base`, marks centered on `mid`.
package(dentrite) void paintLine(ref PaintContext ctx, const ref TabLook l, const ref TabInfo info, float x,
    float base, float mid, Color ink)
{
    TextSystem t = ctx.text;
    string title = shortTitle(t, l.font, l.size, info.title, l.maxTitle);
    ctx.list.text(t.shape(l.font, l.size, title), Point(x, base), ink);
    x += t.measure(l.font, l.size, title);
    if (info.badge.length > 0)
    {
        x += l.markGap;
        ctx.list.text(t.shape(l.font, l.size, info.badge), Point(x, base), ink);
        x += t.measure(l.font, l.size, info.badge);
    }
    if (info.locked)
    {
        x += l.markGap;
        paintIcon(*ctx.list, Icon.lock, Rect(x, round(mid - l.iconSize / 2), l.iconSize, l.iconSize), ink);
        x += l.iconSize;
    }
    if (isNaN(info.progress) == false)
    {
        x += l.markGap;
        Rect bar = Rect(x, round(mid - barH / 2), barW, barH);
        ctx.list.rect(bar, l.track, barH / 2);
        float f = clamp(info.progress, 0f, 1f);
        if (f > 0)
        {
            ctx.list.rect(Rect(bar.x, bar.y, max(barH, round(barW * f)), barH), l.progress, barH / 2);
        }
    }
}

/// Draws the icon and title line of `info` in tab rect `r`, a picture icon at half strength when `faded`.
package(dentrite) void paintRow(ref PaintContext ctx, const ref TabLook l, TabInfo info, Rect r,
    Color ink, bool faded)
{
    TextSystem t = ctx.text;
    float mid = r.y + r.h / 2;
    float base = r.y + round((r.h - t.lineHeight(l.font, l.size)) / 2) + t.ascent(l.font, l.size);
    float x = r.x + l.padX;
    if (info.icon.empty == false)
    {
        Rect ir = Rect(x, r.y + round((r.h - l.iconSize) / 2), l.iconSize, l.iconSize);
        paintIcon(*ctx.list, info.icon, ir, ink, faded);
        x += l.iconSize + l.iconGap;
    }
    paintLine(ctx, l, info, x, base, mid, ink);
}

/// Place of the close button or modified dot in tab rect `r`.
package(dentrite) Rect slotRect(Rect r, const ref TabLook l)
{
    float c = l.closeSize;
    return Rect(r.right - l.padX - c, r.y + round((r.h - c) / 2), c, c);
}

/// Draws close slot `r`: the close button when `close`, highlighted when `hot`, else the dot when `modified`.
package(dentrite) void paintSlot(ref PaintContext ctx, const ref TabLook l, Rect r, bool close, bool hot,
    bool modified, Color ink)
{
    if (close)
    {
        if (hot)
        {
            ctx.list.rect(r.inset(-3), l.closeHover, 3);
        }
        paintIcon(*ctx.list, Icon.close, r, ink);
    }
    else if (modified)
    {
        float d = round(l.closeSize * 0.75f);
        ctx.list.rect(Rect(r.x + round((r.w - d) / 2), r.y + round((r.h - d) / 2), d, d), ink, d / 2);
    }
}

/// Horizontal scrolling of a row of tabs wider than its room, for `TabBar` and the dock.
package(dentrite) struct TabStrip
{
    float scrollX = 0;         /// shift of the row
    bool reveal = true;        /// scroll the chosen tab into view at the next `settle`
    size_t shown = size_t.max; /// chosen tab at the last `settle`

    /// Width of every tab together.
    static float total(const(float)[] widths)
    {
        float w = 0;
        foreach (float x; widths)
        {
            w += x;
        }
        return w;
    }

    /// Scrolls tab `chosen` into view when it changed or `reveal` is set, clear of edge fades `fade` wide, then
    /// keeps the scroll in range, for tabs `widths` in `room`.
    void settle(const(float)[] widths, size_t chosen, float room, float fade)
    {
        if ((reveal || chosen != shown) && chosen < widths.length)
        {
            float x0 = total(widths[0 .. chosen]);
            // its start first when it does not fit
            scrollX = min(max(scrollX, x0 + widths[chosen] - room + fade), x0 - fade);
        }
        reveal = false;
        shown = chosen;
        scrollX = clamp(scrollX, 0, max(0f, total(widths) - room));
    }

    /// Scrolls by `d` for tabs `widths` in `room`. False when they fit.
    bool wheel(float d, const(float)[] widths, float room)
    {
        float over = total(widths) - room;
        if (over <= 0)
        {
            return false;
        }
        scrollX = clamp(scrollX + d, 0, over);
        return true;
    }

    /// Fades the edges of `area` with tabs cut off past them, up to `fade` wide. True if it pushed a fade to pop.
    bool pushFade(ref DrawList list, Rect area, const(float)[] widths, float fade)
    {
        float over = total(widths) - area.w;
        if (over <= 0)
        {
            return false;
        }
        list.pushFade(area, min(fade, round(scrollX)), min(fade, over - round(scrollX)));
        return true;
    }
}

/// Strip of tab titles bound to the index of the chosen tab. Build it with `tabBar`, or get one inside `tabs`.
///
/// A press chooses a tab, arrows and Home and End move the choice, the wheel scrolls a strip wider than its
/// space, which fades out at an edge with more tabs past it, and the chosen tab scrolls into view. With `onClose`
/// set, tabs show a close button when chosen or under the pointer, and a middle click closes too.
/// Closing only calls `onClose`, which updates titles and index. Disabled tabs show dimmed, and presses, keys and
/// screen readers skip them. Disabling the chosen tab leaves it chosen, so move the choice first.
/// `setTabs` or the `TabInfo` form of `tabBar` adds tooltips and marks, and the `maxTitle` style shortens long titles.
final class TabBar : Node, AccessParts
{
    void delegate(size_t index) onClose; /// runs to close tab `index`, null for tabs without a close button
    bool stacked;                          /// icon above the title instead of before it, set before the first layout
    private Signal!size_t current; /// index of the chosen tab
    private TabInfo[] tabs;        /// title, icon, tooltip and marks of each tab
    private Icon[] icons;         /// tab icons, may be shorter than `tabs`
    private bool[] disabled;       /// disabled tabs, may be shorter than `tabs`
    private float[] widths;        /// tab widths from the last layout
    private size_t shown;          /// `current` last read
    private TabStrip strip;        /// scrolling
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
                strip.reveal = true;
                markNeedsPaint();
            }
        });
    }

    /// Replaces the titles.
    void setTitles(string[] titles)
    {
        bool same = titles.length == tabs.length;
        for (size_t i = 0; same && i < titles.length; ++i)
        {
            same = titles[i] == tabs[i].title;
        }
        if (same)
        {
            return;
        }
        tabs.length = titles.length;
        foreach (size_t i, string t; titles)
        {
            tabs[i].title = t;
        }
        hot = -1;
        strip.reveal = true;
        markNeedsLayout();
    }

    /// Replaces titles, icons, tooltips and marks. Icons from `setIcons` win over the ones here.
    void setTabs(TabInfo[] tabs)
    {
        if (tabs.length != this.tabs.length)
        {
            hot = -1;
            strip.reveal = true;
        }
        this.tabs = tabs.dup;
        markNeedsLayout();
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
        for (ptrdiff_t i = from; i >= 0 && i < tabs.length; i += step)
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
        foreach (size_t i; 0 .. tabs.length)
        {
            if (iconOf(i).empty == false)
            {
                return true;
            }
        }
        return false;
    }

    /// Icon of tab `i`, or `Icon.none`.
    private Icon iconOf(size_t i)
    {
        if (i < icons.length && icons[i].empty == false)
        {
            return icons[i];
        }
        return i < tabs.length ? tabs[i].icon : Icon.none;
    }

    /// Tab `i` with its icon from `iconOf`.
    private TabInfo infoOf(size_t i)
    {
        TabInfo t = tabs[i];
        t.icon = iconOf(i);
        return t;
    }

    /// True if tab `i` keeps room for the close button or the modified dot.
    private bool slotted(size_t i)
    {
        return onClose !is null || tabs[i].modified;
    }

    /// Drawing sizes and colors from `s`.
    private static TabLook lookOf(const ref TabsStyle s)
    {
        return TabLook(s.font, s.size, s.padX, s.iconSize, s.iconGap, s.closeSize, s.closeGap, s.markGap, s.maxTitle,
            s.closeHover, s.track, s.progress);
    }

    /// Number of tabs.
    size_t length() const
    {
        return tabs.length;
    }

    /// Rect of tab `i` in window coordinates, as laid out and scrolled.
    Rect tabRect(size_t i)
    {
        Rect b = bounds;
        float x = b.x - round(strip.scrollX);
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
        return min(tabs.length, widths.length);
    }

    /// Tab `i` named by its title, selected when chosen.
    void describePart(size_t i, ref AccessInfo a, ref Rect r)
    {
        a.role = Role.tab;
        a.label = tabs[i].title;
        a.description = tabs[i].tooltip;
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
        return focused && shown < tabs.length ? shown : -1;
    }

    /// Width of every tab together.
    private float total() const
    {
        return TabStrip.total(widths);
    }

    /// Text of the tab under window point `p`, else the bar's own.
    override string tooltipAt(Point p)
    {
        bool onClose_;
        ptrdiff_t i = tabAt(p, onClose_);
        return i >= 0 && tabs[i].tooltip.length > 0 ? tabs[i].tooltip : tooltip;
    }

    /// Tab widths from the titles, the bounded width or the sum, one line tall.
    protected override Size performLayout(Constraints c)
    {
        TabsStyle s = tree.style!TabsStyle();
        TabLook l = lookOf(s);
        TextSystem t = tree.text;
        widths.length = tabs.length;
        foreach (size_t i; 0 .. tabs.length)
        {
            TabInfo info = infoOf(i);
            if (stacked)
            {
                float content = max(lineWidth(t, l, info), info.icon.empty == false ? s.iconSize : 0f);
                widths[i] = ceil(s.padX * 2 + content + (slotted(i) ? s.closeGap + s.closeSize : 0));
            }
            else
            {
                widths[i] = rowWidth(t, l, info, slotted(i));
            }
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
        TabLook l = lookOf(s);
        foreach (size_t i; 0 .. min(tabs.length, widths.length))
        {
            Rect r = tabRect(i);
            if (r.contains(p))
            {
                onClose_ = onClose !is null && slotRect(r, l).inset(-3).contains(p);
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
        if (strip.wheel(e.dy != 0 ? e.dy : e.dx, widths, size.w) == false)
        {
            return false;
        }
        markNeedsPaint();
        return true;
    }

    /// Left and Right choose the neighbor enabled tab, Home and End the first and last enabled ones.
    override bool onKey(ref const KeyEvent e)
    {
        if (tabs.length == 0)
        {
            return false;
        }
        ptrdiff_t last = tabs.length - 1;
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

    /// Strip, tabs with icons, titles, marks and close buttons, the mark under the chosen tab and the focus ring.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TabsStyle s = ctx.style!TabsStyle();
        TabLook l = lookOf(s);
        TextSystem t = ctx.text;
        Rect b = Rect(origin.x, origin.y, size.w, size.h);
        strip.settle(widths, shown, size.w, s.fade);
        if (s.bar.a > 0)
        {
            ctx.list.rect(b, s.bar);
        }
        if (s.line.a > 0)
        {
            ctx.list.hline(b.x, b.right, b.bottom - 1, s.line);
        }
        ctx.clipped(b, {
            bool faded = strip.pushFade(*ctx.list, b, widths, s.fade);
            scope (exit)
            {
                if (faded)
                {
                    ctx.list.popFade();
                }
            }
            float x = b.x - round(strip.scrollX);
            foreach (size_t i; 0 .. min(tabs.length, widths.length))
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
                TabInfo info = infoOf(i);
                if (stacked)
                {
                    float lw = lineWidth(t, l, info);
                    float slotW = slotted(i) ? s.closeGap + s.closeSize : 0;
                    float cx = r.x + s.padX + (r.w - s.padX * 2 - slotW) / 2;
                    float top = r.y + s.stackPadY;
                    if (info.icon.empty == false)
                    {
                        Rect ir = Rect(cx - s.iconSize / 2, top, s.iconSize, s.iconSize);
                        paintIcon(*ctx.list, info.icon, ir, ink, on == false);
                    }
                    float lineTop = top + (anyIcon ? s.iconSize + s.stackGap : 0);
                    paintLine(ctx, l, info, cx - lw / 2, lineTop + t.ascent(s.font, s.size),
                        lineTop + t.lineHeight(s.font, s.size) / 2, ink);
                }
                else
                {
                    paintRow(ctx, l, info, r, ink, on == false);
                }
                if (slotted(i))
                {
                    bool close = onClose !is null && on && (active || over_);
                    paintSlot(ctx, l, slotRect(r, l), close, close && over_ && hotClose, info.modified, ink);
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

/// Tab strip over `tabs` with icons, tooltips and marks choosing `current`:
/// `tabBar(() => files.get.map!(f => TabInfo(f.name, tooltip: f.path, modified: f.dirty)).array, open)`. `onClose`
/// adds close buttons, `stacked` puts icons above the titles. `enabled` says whether tab `index` can be chosen,
/// null for all. The effect belongs to the current owner.
TabBar tabBar(TabInfo[] delegate() tabs, Signal!size_t current, void delegate(size_t index) onClose = null,
    bool stacked = false, bool delegate(size_t index) enabled = null)
{
    TabBar b = new TabBar(current);
    b.onClose = onClose;
    b.stacked = stacked;
    effect(() {
        TabInfo[] t = tabs();
        b.setTabs(t);
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

// A strip scrolls a newly chosen tab into view clear of the fades, and keeps the scroll in range.
unittest
{
    TabStrip s;
    float[] ws = [100, 100, 100, 100];
    s.settle(ws, 0, 250, 20);
    assert(s.scrollX == 0);
    s.settle(ws, 3, 250, 20);
    assert(s.scrollX == 150, "last tab at the right end");
    s.settle(ws, 1, 250, 20);
    assert(s.scrollX == 80, "start clear of the left fade");
    s.settle(ws, 1, 250, 20);
    assert(s.scrollX == 80, "unchanged choice, no reveal");
    assert(s.wheel(1000, ws, 250) && s.scrollX == 150);
    assert(s.wheel(10, ws, 500) == false);
}

// Long titles shorten to `maxTitle`, marks and the modified dot widen tabs, and each tab shows its own tooltip.
unittest
{
    import dentrite.containers : column, row;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.theme : Theme;
    import dentrite.widgets.menu : menuHost;
    import std.algorithm.searching : endsWith;

    Host h = menuHost(600, 100);
    scope (exit)
    {
        h.close();
    }
    h.tree.theme = new Theme("[tabs]\nmaxTitle = 80\n[tooltip]\ndelay = 0\n", "test");
    Signal!size_t cur = signal(size_t(0));
    Signal!bool dirty = signal(false);
    TabBar bar = tabBar(() => [TabInfo("A rather long file name.bin", tooltip: "/data/a.bin"),
        TabInfo("b.bin", tooltip: "/data/b.bin", badge: "×2", locked: true, progress: 0.5f, modified: dirty.get),
        TabInfo("c.bin")], cur);
    h.setRoot(column()(row()(bar)));
    h.frame();
    TextSystem t = h.tree.text;
    TabsStyle s = h.tree.style!TabsStyle();
    string cut = shortTitle(t, s.font, s.size, "A rather long file name.bin", 80);
    assert(cut.endsWith("…") && cut.length < 20 && t.measure(s.font, s.size, cut) <= 80);
    assert(shortTitle(t, s.font, s.size, "c.bin", 80) == "c.bin" && shortTitle(t, s.font, s.size, cut, 0) == cut);
    assert(bar.tabRect(0).w == ceil(s.padX * 2 + t.measure(s.font, s.size, cut)));
    float marks = s.markGap + t.measure(s.font, s.size, "×2") + s.markGap + s.iconSize + s.markGap + barW;
    assert(bar.tabRect(1).w == ceil(s.padX * 2 + t.measure(s.font, s.size, "b.bin") + marks));
    dirty.set(true);
    h.frame();
    assert(bar.tabRect(1).w == ceil(s.padX * 2 + t.measure(s.font, s.size, "b.bin") + marks + s.closeGap
        + s.closeSize), "room for the dot");

    h.inject(PointerKind.move, mid(bar.tabRect(0)));
    h.frame();
    h.frame();
    assert(h.tooltips.text == "/data/a.bin");
    h.inject(PointerKind.move, mid(bar.tabRect(1)));
    h.frame();
    assert(h.tooltips.text == "/data/b.bin", "moving on to the next tab");
    h.inject(PointerKind.move, mid(bar.tabRect(2)));
    h.frame();
    assert(h.tooltips.shown == false, "no text on the third tab");
}
