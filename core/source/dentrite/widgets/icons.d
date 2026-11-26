/// Icons for controls: vector shapes drawn with polygons and lines, or pictures, sized to a square box.
module dentrite.widgets.icons;

import dentrite.draw;
import dentrite.geom;
import dentrite.image : Image;
import dentrite.node;
import dentrite.widgets.image : Fit, fitRect;
import dentrite.widgets.label : TextStyle;

/// Built-in shapes.
enum IconShape
{
    none,     /// no shape
    play,     /// triangle pointing right, for run or play
    pause,    /// two bars, for pause or break
    stepOver, /// arc over a dot, for step over
    stop,     /// rounded square, for stop
    plus,     /// plus sign, for add
    breakpoint, /// filled circle, for a breakpoint
    check,    /// check mark
    chevronRight, /// chevron pointing right, for submenus
    chevronDown,  /// chevron pointing down, for drop-downs
    chevronUp,    /// chevron pointing up, for a spin box up button
    minus,    /// minus sign, for remove or decrease
    close,    /// cross, for closing a tab or window
    chevronLeft, /// chevron pointing left, for going back
    menu,     /// three bars, for showing a sidebar or a menu
    lock,     /// padlock, for read-only or locked content
}

/// What a control shows in its icon box: `Icon.play`, a picture `Icon(img)`, or a one color picture drawn in
/// the control's ink `Icon(img, mono: true)`. Pictures shrink or grow to the box, so make them the box size
/// times the display scale for sharp edges.
struct Icon
{
    IconShape shape; /// built-in shape, drawn in the control's ink
    Image image;     /// picture, drawn instead of `shape` when set
    bool mono;       /// picture's colors times the ink, for white or gray pictures

    enum Icon none = Icon(IconShape.none);                 /// no shape
    enum Icon play = Icon(IconShape.play);                 /// triangle pointing right, for run or play
    enum Icon pause = Icon(IconShape.pause);               /// two bars, for pause or break
    enum Icon stepOver = Icon(IconShape.stepOver);         /// arc over a dot, for step over
    enum Icon stop = Icon(IconShape.stop);                 /// rounded square, for stop
    enum Icon plus = Icon(IconShape.plus);                 /// plus sign, for add
    enum Icon breakpoint = Icon(IconShape.breakpoint);     /// filled circle, for a breakpoint
    enum Icon check = Icon(IconShape.check);               /// check mark
    enum Icon chevronRight = Icon(IconShape.chevronRight); /// chevron pointing right, for submenus
    enum Icon chevronDown = Icon(IconShape.chevronDown);   /// chevron pointing down, for drop-downs
    enum Icon chevronUp = Icon(IconShape.chevronUp);       /// chevron pointing up, for a spin box up button
    enum Icon minus = Icon(IconShape.minus);               /// minus sign, for remove or decrease
    enum Icon close = Icon(IconShape.close);               /// cross, for closing a tab or window
    enum Icon chevronLeft = Icon(IconShape.chevronLeft);   /// chevron pointing left, for going back
    enum Icon menu = Icon(IconShape.menu);                 /// three bars, for showing a sidebar or a menu
    enum Icon lock = Icon(IconShape.lock);                 /// padlock, for read-only or locked content

    /// Built-in `shape`.
    this(IconShape shape)
    {
        this.shape = shape;
    }

    /// Picture `image`, in the ink when `mono`.
    this(Image image, bool mono = false)
    {
        this.image = image;
        this.mono = mono;
    }

    /// True if there is nothing to draw.
    bool empty() const
    {
        return image is null ? shape == IconShape.none : image.empty;
    }
}

/// Draws `icon` centered in `box`, shapes in `c`. Pictures keep their colors, at half strength when `faded`.
void paintIcon(ref DrawList list, Icon icon, Rect box, Color c, bool faded = false)
{
    if (icon.image !is null)
    {
        if (icon.image.empty == false)
        {
            Color tint = icon.mono ? c : Color(255, 255, 255, faded ? 128 : 255);
            list.image(fitRect(box, icon.image.size, Fit.contain), icon.image, tint);
        }
        return;
    }
    float s = box.w < box.h ? box.w : box.h;
    float x = box.x + (box.w - s) / 2;
    float y = box.y + (box.h - s) / 2;

    /// Point at fractions of the box.
    Point at(float fx, float fy)
    {
        return Point(x + fx * s, y + fy * s);
    }

    final switch (icon.shape)
    {
    case IconShape.none:
        break;
    case IconShape.play:
        list.polygon([at(0.2, 0.1), at(0.9, 0.5), at(0.2, 0.9)], c);
        break;
    case IconShape.pause:
        list.rect(Rect(x + 0.18 * s, y + 0.12 * s, 0.22 * s, 0.76 * s), c, 1);
        list.rect(Rect(x + 0.6 * s, y + 0.12 * s, 0.22 * s, 0.76 * s), c, 1);
        break;
    case IconShape.stepOver:
        list.polyline([at(0.12, 0.62), at(0.12, 0.38), at(0.3, 0.2), at(0.62, 0.2), at(0.8, 0.38), at(0.8, 0.6)],
            0.12 * s, c);
        list.polygon([at(0.62, 0.52), at(0.98, 0.52), at(0.8, 0.78)], c);
        list.rect(Rect(x + 0.38 * s, y + 0.74 * s, 0.2 * s, 0.2 * s), c, 0.1 * s);
        break;
    case IconShape.stop:
        list.rect(Rect(x + 0.15 * s, y + 0.15 * s, 0.7 * s, 0.7 * s), c, 0.12 * s);
        break;
    case IconShape.plus:
        list.rect(Rect(x + 0.42 * s, y + 0.12 * s, 0.16 * s, 0.76 * s), c);
        list.rect(Rect(x + 0.12 * s, y + 0.42 * s, 0.76 * s, 0.16 * s), c);
        break;
    case IconShape.breakpoint:
        list.rect(Rect(x + 0.1 * s, y + 0.1 * s, 0.8 * s, 0.8 * s), c, 0.4 * s);
        break;
    case IconShape.check:
        list.polyline([at(0.15, 0.52), at(0.4, 0.76), at(0.86, 0.24)], 0.14 * s, c);
        break;
    case IconShape.chevronRight:
        list.polyline([at(0.3, 0.05), at(0.75, 0.5), at(0.3, 0.95)], 0.1875 * s, c);
        break;
    case IconShape.chevronDown:
        list.polyline([at(0.1, 0.3), at(0.5, 0.72), at(0.9, 0.3)], 0.1875 * s, c);
        break;
    case IconShape.chevronUp:
        list.polyline([at(0.1, 0.7), at(0.5, 0.28), at(0.9, 0.7)], 0.1875 * s, c);
        break;
    case IconShape.minus:
        list.rect(Rect(x + 0.12 * s, y + 0.42 * s, 0.76 * s, 0.16 * s), c);
        break;
    case IconShape.close:
        list.polyline([at(0.2, 0.2), at(0.8, 0.8)], 0.14 * s, c);
        list.polyline([at(0.8, 0.2), at(0.2, 0.8)], 0.14 * s, c);
        break;
    case IconShape.chevronLeft:
        list.polyline([at(0.7, 0.05), at(0.25, 0.5), at(0.7, 0.95)], 0.1875 * s, c);
        break;
    case IconShape.menu:
        list.rect(Rect(x + 0.1 * s, y + 0.18 * s, 0.8 * s, 0.13 * s), c, 0.06 * s);
        list.rect(Rect(x + 0.1 * s, y + 0.435 * s, 0.8 * s, 0.13 * s), c, 0.06 * s);
        list.rect(Rect(x + 0.1 * s, y + 0.69 * s, 0.8 * s, 0.13 * s), c, 0.06 * s);
        break;
    case IconShape.lock:
        list.polyline([at(0.32, 0.5), at(0.32, 0.3), at(0.4, 0.14), at(0.5, 0.1), at(0.6, 0.14), at(0.68, 0.3),
            at(0.68, 0.5)], 0.12 * s, c);
        list.rect(Rect(x + 0.18 * s, y + 0.44 * s, 0.64 * s, 0.48 * s), c, 0.08 * s);
        break;
    }
}

/// Leaf drawing one icon in a square, for rows and other free layouts.
final class IconView : Node
{
    Icon icon;          /// icon to draw
    float size;         /// side of the square
    string variant;     /// TextStyle variant giving the ink when `ink` is unset
    Color ink;          /// icon color, alpha 0 to use the text color

    /// Creates an icon leaf.
    this(Icon icon, float size, string variant, Color ink)
    {
        this.icon = icon;
        this.size = size;
        this.variant = variant;
        this.ink = ink;
    }

    /// Replaces the icon. Only repaints.
    void setIcon(Icon i)
    {
        if (i == icon)
        {
            return;
        }
        icon = i;
        markNeedsPaint();
    }

    /// The square.
    protected override Size performLayout(Constraints c)
    {
        return Size(size, size);
    }

    /// The icon.
    override void paint(ref PaintContext ctx, Point origin)
    {
        Color c = ink.a > 0 ? ink : ctx.style!TextStyle(variant).color;
        paintIcon(*ctx.list, icon, Rect(origin.x, origin.y, size, size), c);
    }
}

/// Icon leaf: `row(gap: 6)(iconView(Icon.play), label(name))`. Ink follows the text variant unless `ink` is set.
IconView iconView(Icon icon, float size = 14, string variant = null, Color ink = Color.init)
{
    return new IconView(icon, size, variant, ink);
}

// Pictures fit the box with their aspect, keep their colors or take the ink, and fade on request.
unittest
{
    Image img = new Image(4, 2);
    DrawList list;
    Color ink = Color(10, 20, 30, 255);
    paintIcon(list, Icon(img), Rect(0, 0, 12, 12), ink);
    paintIcon(list, Icon(img), Rect(0, 0, 12, 12), ink, true);
    paintIcon(list, Icon(img, mono: true), Rect(0, 0, 12, 12), ink);
    assert(list.cmds.length == 3 && list.cmds[0].op == Op.image && list.cmds[0].image is img);
    assert(list.cmds[0].r == Rect(0, 3, 12, 6) && list.cmds[0].fill == Color(255, 255, 255, 255));
    assert(list.cmds[1].fill == Color(255, 255, 255, 128) && list.cmds[2].fill == ink);
    list.clear();
    paintIcon(list, Icon(new Image(0, 0)), Rect(0, 0, 12, 12), ink);
    assert(list.cmds.length == 0 && Icon(new Image(0, 0)).empty && Icon.none.empty && Icon.play.empty == false);
    paintIcon(list, Icon.stop, Rect(0, 0, 12, 12), ink);
    assert(list.cmds.length == 1 && list.cmds[0].op == Op.rect);
}

// Buttons, tabs and menu items draw picture icons in their colors, faded when disabled, and one color pictures
// in the ink.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column, row;
    import dentrite.host : Host;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.menu : Menu, menuHost, menuItem, popupMenu;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.tabs : TabBar, tabBar;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Image red = new Image(12, 12);
    Image white = new Image(12, 12);
    foreach (int y; 0 .. 12)
    {
        foreach (int x; 0 .. 12)
        {
            red.set(x, y, 255, 0, 0, 255);
            white.set(x, y, 255, 255, 255, 255);
        }
    }
    Button a = button(null, icon: Icon(red));
    Button b = button(null, icon: Icon(red), enabled: () => false);
    Button c = button(null, icon: Icon(white, mono: true));
    Signal!size_t cur = signal!size_t(0);
    TabBar bar = tabBar(["A", "B"], cur, icons: [Icon(red), Icon(red)], enabled: (size_t i) => i == 0);
    h.setRoot(column()(row()(a, b, c), bar));
    h.frame();
    SoftwareRenderer r = cast(SoftwareRenderer) h.renderer;
    uint mid(Button n)
    {
        Rect k = n.bounds;
        return r.pixels[cast(int)(k.y + k.h / 2) * r.width + cast(int)(k.x + k.w / 2)];
    }

    assert(mid(a) == 0xff0000ff);
    uint f = mid(b);
    assert(f != 0xff0000ff && (f & 0xff) > ((f >> 8) & 0xff) + 40, "half red over the fill");
    assert(mid(c) == 0xffeeeeee, "the caption color");

    size_t reds()
    {
        size_t n;
        foreach (uint p; r.pixels)
        {
            n += p == 0xff0000ff;
        }
        return n;
    }

    assert(reds() == 288, "the enabled button and tab only");
    Menu m = popupMenu(menuItem("On", null, icon: Icon(red)), menuItem("Off", null, icon: Icon(red),
        enabled: () => false));
    m.openAt(h.tree, Point(150, 100));
    h.frame();
    assert(reds() == 432, "one more from the enabled menu item only");
}
