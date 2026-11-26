/// Layout containers: rows, columns, grids, stacks, padding, panels, fixed sizes, a vertical scroll view,
/// a width cap and a squeeze picking a child by the space it gets.
///
/// Builders take options by name in one call and children in a second call:
/// `row(gap: 4)(a, b)`. One call would bind a positional child after a named
/// option to the next parameter.
module dentrite.containers;

import core.time : Duration, MonoTime, msecs;
import dentrite.draw;
import dentrite.node;
import std.algorithm.comparison : clamp, max, min;
import std.math : abs, exp, floor, hypot, isInfinity, isNaN, log, round;

/// Main axis of a flex container.
enum Axis
{
    horizontal, /// children left to right, as in a row
    vertical,   /// children top to bottom, as in a column
}

/// Placement of a child on one axis of the space it is given.
enum CrossAlign
{
    start,   /// left or top
    center,  /// centered
    end,     /// right or bottom
    stretch, /// stretched to fill it
}

/// Offset of a child placed by `a` in `slack` spare pixels.
private float alignIn(CrossAlign a, float slack)
{
    return a == CrossAlign.center ? round(slack / 2) : a == CrossAlign.end ? slack : 0;
}

/// Single child inset by `insets`.
final class Padding : Node
{
    Insets insets; /// space around the child

    /// Wraps `child` with `insets`.
    this(Insets insets, Node child)
    {
        this.insets = insets;
        add(child);
    }

    /// Lays out the child in the deflated space and offsets it.
    protected override Size performLayout(Constraints c)
    {
        Node child = children[0];
        Size s = child.layout(c.deflate(insets));
        child.offset = Point(insets.left, insets.top);
        return Size(s.w + insets.left + insets.right, s.h + insets.top + insets.bottom);
    }
}

/// Flex child that takes a share of the remaining main-axis space.
final class Flexible : Node
{
    int flex = 1;      /// weight of its share of the remaining main-axis space
    bool tight = true; /// true fills the share, false allows smaller

    /// Wraps `child` with a flex weight.
    this(Node child, int flex = 1, bool tight = true)
    {
        this.flex = flex;
        this.tight = tight;
        add(child);
    }

    /// Passes constraints through to the child.
    protected override Size performLayout(Constraints c)
    {
        Node child = children[0];
        child.offset = Point.init;
        return child.layout(c);
    }
}

/// Flexible child that fills its share.
Flexible expanded(Node child, int flex = 1)
{
    return new Flexible(child, flex, true);
}

/// Empty flexible child, pushing its siblings apart.
Flexible spacer(int flex = 1)
{
    return new Flexible(new Fixed(Size.init), flex, true);
}

/// Row or column with gaps and flex children.
class Flex : Node
{
    Axis axis;        /// main axis
    float gap = 0;    /// space between children
    CrossAlign cross; /// placement of children across the main axis

    /// Creates a flex container with `kids`.
    this(Axis axis, float gap, CrossAlign cross, Node[] kids)
    {
        this.axis = axis;
        this.gap = gap;
        this.cross = cross;
        foreach (Node k; kids)
        {
            add(k);
        }
    }

    /// Main-axis extent of `s`.
    private float mainOf(Size s) const
    {
        return axis == Axis.horizontal ? s.w : s.h;
    }

    /// Cross-axis extent of `s`.
    private float crossOf(Size s) const
    {
        return axis == Axis.horizontal ? s.h : s.w;
    }

    /// Child constraints from main and cross ranges.
    private Constraints make(float mainMin, float mainMax, float crossMin, float crossMax) const
    {
        return axis == Axis.horizontal
            ? Constraints(mainMin, mainMax, crossMin, crossMax)
            : Constraints(crossMin, crossMax, mainMin, mainMax);
    }

    /// Inflexible children first, then flex shares of what is left, then positions.
    /// Flex children in an unbounded main axis get their natural size.
    protected override Size performLayout(Constraints c)
    {
        float mainMax = axis == Axis.horizontal ? c.maxW : c.maxH;
        float crossMax = axis == Axis.horizontal ? c.maxH : c.maxW;
        bool stretch = cross == CrossAlign.stretch && isInfinity(crossMax) == false;
        float crossMin = stretch ? crossMax : 0;
        bool bounded = isInfinity(mainMax) == false;

        float used = children.length > 1 ? gap * (children.length - 1) : 0;
        float crossSize = 0;
        int totalFlex;
        foreach (Node k; children)
        {
            Flexible f = cast(Flexible) k;
            if (bounded && f !is null && f.flex > 0)
            {
                totalFlex += f.flex;
                continue;
            }
            Size s = k.layout(make(0, float.infinity, crossMin, crossMax));
            used += mainOf(s);
            crossSize = max(crossSize, crossOf(s));
        }

        float free = bounded ? max(0f, mainMax - used) : 0;
        float perFlex = totalFlex > 0 ? free / totalFlex : 0;
        float handed = 0;
        int flexSeen;
        foreach (Node k; children)
        {
            Flexible f = cast(Flexible) k;
            if (bounded == false || f is null || f.flex <= 0)
            {
                continue;
            }
            flexSeen += f.flex;
            float share = round(perFlex * flexSeen) - handed;
            handed += share;
            Size s = k.layout(make(f.tight ? share : 0, share, crossMin, crossMax));
            used += mainOf(s);
            crossSize = max(crossSize, crossOf(s));
        }

        float mainSize = bounded ? max(mainMax, 0f) : used;
        if (bounded && totalFlex == 0)
        {
            mainSize = max(used, axis == Axis.horizontal ? c.minW : c.minH);
        }
        if (stretch)
        {
            crossSize = crossMax;
        }
        else
        {
            crossSize = max(crossSize, axis == Axis.horizontal ? c.minH : c.minW);
        }

        float pos = 0;
        foreach (Node k; children)
        {
            float across = alignIn(cross, crossSize - crossOf(k.size));
            k.offset = axis == Axis.horizontal ? Point(pos, across) : Point(across, pos);
            pos += mainOf(k.size) + gap;
        }
        return axis == Axis.horizontal ? Size(mainSize, crossSize) : Size(crossSize, mainSize);
    }
}

/// Options of a row or column, waiting for the children: `row(gap: 4)(a, b)`.
struct FlexSpec
{
    Axis axis;        /// main axis
    float gap;        /// space between children
    CrossAlign cross; /// placement of children across the main axis

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Axis axis, float gap, CrossAlign cross)
    {
        this.axis = axis;
        this.gap = gap;
        this.cross = cross;
    }

    /// The container holding `kids`.
    Flex opCall(Node[] kids...)
    {
        return new Flex(axis, gap, cross, kids.dup);
    }
}

/// Horizontal flex container: `row(gap: 4)(a, b)`.
FlexSpec row(float gap = 0, CrossAlign cross = CrossAlign.center)
{
    return FlexSpec(Axis.horizontal, gap, cross);
}

/// Vertical flex container: `column(gap: 4)(a, b)`.
FlexSpec column(float gap = 0, CrossAlign cross = CrossAlign.stretch)
{
    return FlexSpec(Axis.vertical, gap, cross);
}

/// Padding options, waiting for the child.
struct PadSpec
{
    Insets insets; /// space around the child

    /// Stores the insets. Needed because `opCall` hides the struct literal.
    this(Insets insets)
    {
        this.insets = insets;
    }

    /// The padding around `child`.
    Padding opCall(Node child)
    {
        return new Padding(insets, child);
    }
}

/// Padding of `all` on every side, or `x` and `y` when given: `pad(all: 8)(child)`.
PadSpec pad(float all = 0, float x = float.nan, float y = float.nan)
{
    import std.math : isNaN;

    return PadSpec(Insets.xy(isNaN(x) ? all : x, isNaN(y) ? all : y));
}

/// Child with fixed width, height or both. NaN leaves an axis to the parent.
final class Sized : Node
{
    float w; /// fixed width, NaN to leave it to the parent
    float h; /// fixed height, NaN to leave it to the parent

    /// Fixes `child` to `w` by `h`.
    this(float w, float h, Node child)
    {
        this.w = w;
        this.h = h;
        add(child);
    }

    /// Tightens the constraints on the fixed axes.
    protected override Size performLayout(Constraints c)
    {
        import std.math : isNaN;

        Constraints k = c;
        if (isNaN(w) == false)
        {
            k.minW = k.maxW = clamp(w, c.minW, c.maxW);
        }
        if (isNaN(h) == false)
        {
            k.minH = k.maxH = clamp(h, c.minH, c.maxH);
        }
        children[0].offset = Point.init;
        return children[0].layout(k);
    }
}

/// Size options, waiting for the child.
struct SizedSpec
{
    float w; /// fixed width, NaN to leave it to the parent
    float h; /// fixed height, NaN to leave it to the parent

    /// Stores the size. Needed because `opCall` hides the struct literal.
    this(float w, float h)
    {
        this.w = w;
        this.h = h;
    }

    /// The box around `child`.
    Sized opCall(Node child)
    {
        return new Sized(w, h, child);
    }
}

/// Fixed width and or height: `sized(w: 80)(child)`.
SizedSpec sized(float w = float.nan, float h = float.nan)
{
    return SizedSpec(w, h);
}

/// Cells of equal width in rows, filled left to right.
///
/// Each row is as tall as its tallest cell, and rows share the extra height of
/// a larger minimum, so an `expanded` grid fills its space.
final class Grid : Node
{
    int cols;          /// column count, 0 to fit as many columns of `minCell` as the width allows
    float minCell = 0; /// narrowest column when `cols` is 0
    float gap = 0;     /// space between cells, across and down
    CrossAlign cross;  /// vertical placement of each child in its row

    /// Creates a grid of `kids`.
    this(int cols, float minCell, float gap, CrossAlign cross, Node[] kids)
    {
        this.cols = cols;
        this.minCell = minCell;
        this.gap = gap;
        this.cross = cross;
        foreach (Node k; kids)
        {
            add(k);
        }
    }

    /// Column count for a grid at most `maxW` wide.
    private int columns(float maxW) const
    {
        if (cols > 0 || minCell <= 0)
        {
            return max(1, cols);
        }
        if (isInfinity(maxW))
        {
            return max(1, cast(int) children.length);
        }
        return max(1, cast(int) floor((maxW + gap) / (minCell + gap)));
    }

    /// Natural height of row `r` with `nc` columns, from the children's last layout.
    private float rowHeight(size_t r, int nc) const
    {
        float h = 0;
        foreach (const Node k; children[r * nc .. min((r + 1) * nc, children.length)])
        {
            h = max(h, k.size.h);
        }
        return h;
    }

    /// Measures the cells at their column width, then sizes the rows and places the cells.
    /// An unbounded width makes every column as wide as the widest child.
    protected override Size performLayout(Constraints c)
    {
        int nc = columns(c.maxW);
        size_t nr = (children.length + nc - 1) / nc;
        float gapsW = gap * (nc - 1);
        float cellsW;
        if (isInfinity(c.maxW))
        {
            float widest = minCell;
            foreach (Node k; children)
            {
                widest = max(widest, k.layout(Constraints.init).w);
            }
            cellsW = max(widest * nc, c.minW - gapsW);
        }
        else
        {
            cellsW = max(0f, c.maxW - gapsW);
        }

        float natural = nr > 1 ? gap * (nr - 1) : 0;
        foreach (size_t i, Node k; children)
        {
            int col = cast(int) (i % nc);
            float w = round(cellsW * (col + 1) / nc) - round(cellsW * col / nc);
            k.layout(Constraints(w, w, 0, float.infinity));
        }
        foreach (size_t r; 0 .. nr)
        {
            natural += rowHeight(r, nc);
        }

        float extra = nr > 0 ? max(0f, c.minH - natural) : 0;
        float y = 0;
        foreach (size_t r; 0 .. nr)
        {
            float rh = rowHeight(r, nc) + round(extra * (r + 1) / nr) - round(extra * r / nr);
            foreach (size_t i; r * nc .. min((r + 1) * nc, children.length))
            {
                Node k = children[i];
                int col = cast(int) (i % nc);
                if (cross == CrossAlign.stretch && k.size.h != rh)
                {
                    k.layout(Constraints(k.size.w, k.size.w, rh, rh));
                }
                k.offset = Point(round(cellsW * col / nc) + gap * col, y + alignIn(cross, rh - k.size.h));
            }
            y += rh + gap;
        }
        return Size(cellsW + gapsW, natural + extra);
    }
}

/// Grid options, waiting for the children.
struct GridSpec
{
    int cols;         /// column count, 0 to fit columns of `minCell`
    float minCell;    /// narrowest column when `cols` is 0
    float gap;        /// space between cells
    CrossAlign cross; /// vertical placement of each child in its row

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(int cols, float minCell, float gap, CrossAlign cross)
    {
        this.cols = cols;
        this.minCell = minCell;
        this.gap = gap;
        this.cross = cross;
    }

    /// The grid holding `kids`.
    Grid opCall(Node[] kids...)
    {
        return new Grid(cols, minCell, gap, cross, kids.dup);
    }
}

/// Grid of `cols` columns, or of as many `minCell` wide ones as fit: `grid(minCell: 120, gap: 8)(a, b, c)`.
GridSpec grid(int cols = 0, float minCell = 0, float gap = 0, CrossAlign cross = CrossAlign.stretch)
{
    assert(cols > 0 || minCell > 0, "grid needs cols or minCell");
    return GridSpec(cols, minCell, gap, cross);
}

/// Child at most `maxW` wide, centered in the width it gets, such as a form kept narrow in a wide window.
final class Clamped : Node
{
    float maxW; /// widest the child gets

    /// Caps `child` at `maxW`.
    this(float maxW, Node child)
    {
        this.maxW = maxW;
        add(child);
    }

    /// Lays out the child at most `maxW` wide and centers it. Takes the full width unless unbounded.
    protected override Size performLayout(Constraints c)
    {
        Node child = children[0];
        float cap = min(maxW, c.maxW);
        Size s = child.layout(Constraints(min(c.minW, cap), cap, c.minH, c.maxH));
        float w = isInfinity(c.maxW) ? max(c.minW, s.w) : c.maxW;
        child.offset = Point(round((w - s.w) / 2), 0);
        return Size(w, s.h);
    }
}

/// Width cap, waiting for the child.
struct ClampedSpec
{
    float maxW; /// widest the child gets

    /// Stores the cap. Needed because `opCall` hides the struct literal.
    this(float maxW)
    {
        this.maxW = maxW;
    }

    /// The centered child.
    Clamped opCall(Node child)
    {
        return new Clamped(maxW, child);
    }
}

/// Child at most `maxW` wide, centered: `clamped(maxW: 640)(form)`.
ClampedSpec clamped(float maxW)
{
    return ClampedSpec(maxW);
}

/// Child of a squeeze, shown while the space offered holds its ranges. Elsewhere it passes the space through.
final class Fits : Node
{
    float minW = 0;              /// smallest width offered
    float maxW = float.infinity; /// largest width offered
    float minH = 0;              /// smallest height offered
    float maxH = float.infinity; /// largest height offered

    /// Wraps `child` with the ranges.
    this(float minW, float maxW, float minH, float maxH, Node child)
    {
        this.minW = minW;
        this.maxW = maxW;
        this.minH = minH;
        this.maxH = maxH;
        add(child);
    }

    /// True if the largest size `c` allows is within the ranges, bounds included.
    bool holds(Constraints c) const
    {
        return c.maxW >= minW && c.maxW <= maxW && c.maxH >= minH && c.maxH <= maxH;
    }

    /// Passes constraints through to the child.
    protected override Size performLayout(Constraints c)
    {
        Node child = children[0];
        child.offset = Point.init;
        return child.layout(c);
    }
}

/// Size ranges, waiting for the child.
struct FitsSpec
{
    float minW; /// smallest width offered
    float maxW; /// largest width offered
    float minH; /// smallest height offered
    float maxH; /// largest height offered

    /// Stores the ranges. Needed because `opCall` hides the struct literal.
    this(float minW, float maxW, float minH, float maxH)
    {
        this.minW = minW;
        this.maxW = maxW;
        this.minH = minH;
        this.maxH = maxH;
    }

    /// The child of a squeeze shown while the space offered holds the ranges.
    Fits opCall(Node child)
    {
        return new Fits(minW, maxW, minH, maxH, child);
    }
}

/// Size ranges, in logical pixels, a squeeze checks before showing `child`: `fits(minW: 800)(wide)`.
FitsSpec fits(float minW = 0, float maxW = float.infinity, float minH = 0, float maxH = float.infinity)
{
    return FitsSpec(minW, maxW, minH, maxH);
}

/// Shows the first child that fits the space offered and detaches the others.
///
/// A `fits` child fits while the largest size offered is within its ranges, an
/// unbounded axis counting as infinitely large. Any other child always fits,
/// so the last is the fallback. With none fitting the squeeze is empty. The
/// pick happens during layout, from the constraints alone. Detached children
/// stay built and keep their state, as the pages of `tabs` do. Focus inside
/// a child that leaves is dropped.
final class Squeeze : Node
{
    private Node[] options; /// every child, the shown one included, in order

    /// Holds `kids`, none attached until the first layout.
    this(Node[] kids)
    {
        foreach (Node k; kids)
        {
            assert(k.parent is null, "node already has a parent");
        }
        options = kids;
    }

    /// Children to pick from, in order.
    const(Node)[] choices() const
    {
        return options;
    }

    /// Index in `choices` of the shown child, or -1.
    int shown() const
    {
        foreach (size_t i, const(Node) o; options)
        {
            if (children.length > 0 && o is children[0])
            {
                return cast(int) i;
            }
        }
        return -1;
    }

    /// First child that fits `c`, or null.
    private Node pick(Constraints c)
    {
        foreach (Node o; options)
        {
            Fits f = cast(Fits) o;
            if (f is null || f.holds(c))
            {
                return o;
            }
        }
        return null;
    }

    /// Attaches the child that fits and lays it out.
    protected override Size performLayout(Constraints c)
    {
        Node p = pick(c);
        if ((children.length > 0 ? children[0] : null) !is p)
        {
            setChildren(p is null ? null : [p]);
            if (p !is null)
            {
                // NOTE: the running flush may drop boundaries the attach queued, so lay out all of it.
                p.markSubtreeNeedsLayout();
            }
        }
        if (p is null)
        {
            return Size(c.minW, c.minH);
        }
        p.offset = Point.init;
        return p.layout(c);
    }
}

/// Squeeze options, waiting for the children.
struct SqueezeSpec
{
    /// The squeeze picking from `kids`, in order.
    Squeeze opCall(Node[] kids...)
    {
        return new Squeeze(kids.dup);
    }
}

/// First child that fits the space: `squeeze()(fits(minW: 800)(wide), fits(minW: 500)(medium), narrow)`.
SqueezeSpec squeeze()
{
    return SqueezeSpec.init;
}

/// Children on top of each other, the last on top.
///
/// The stack is as large as its children, not counting those stretched on an
/// axis, which fill it instead. With every child stretched it fills its space.
final class Stack : Node
{
    CrossAlign x; /// horizontal placement of children without their own
    CrossAlign y; /// vertical placement of children without their own

    /// Creates a stack of `kids`, the last on top.
    this(CrossAlign x, CrossAlign y, Node[] kids)
    {
        this.x = x;
        this.y = y;
        foreach (Node k; kids)
        {
            add(k);
        }
    }

    /// Placement of `k`, from its `Aligned` wrapper or the stack.
    private void placement(Node k, out CrossAlign ax, out CrossAlign ay) const
    {
        Aligned a = cast(Aligned) k;
        ax = a is null ? x : a.x;
        ay = a is null ? y : a.y;
    }

    /// Width from children not stretched across, then their heights, then stretched children fill.
    protected override Size performLayout(Constraints c)
    {
        CrossAlign ax, ay;
        float w = 0;
        bool sizesW;
        foreach (Node k; children)
        {
            placement(k, ax, ay);
            if (ax != CrossAlign.stretch)
            {
                w = max(w, k.layout(c.loosen()).w);
                sizesW = true;
            }
        }
        float width = sizesW ? clamp(w, c.minW, c.maxW) : isInfinity(c.maxW) ? c.minW : c.maxW;

        float h = 0;
        bool sizesH;
        foreach (Node k; children)
        {
            placement(k, ax, ay);
            if (ax == CrossAlign.stretch)
            {
                k.layout(Constraints(width, width, 0, c.maxH));
            }
            if (ay != CrossAlign.stretch)
            {
                h = max(h, k.size.h);
                sizesH = true;
            }
        }
        float height = sizesH ? clamp(h, c.minH, c.maxH) : isInfinity(c.maxH) ? c.minH : c.maxH;

        foreach (Node k; children)
        {
            placement(k, ax, ay);
            if (ay == CrossAlign.stretch)
            {
                k.layout(ax == CrossAlign.stretch ? Constraints.tight(Size(width, height))
                    : Constraints(0, c.maxW, height, height));
            }
            k.offset = Point(alignIn(ax, width - k.size.w), alignIn(ay, height - k.size.h));
        }
        return Size(width, height);
    }
}

/// Stack options, waiting for the children.
struct StackSpec
{
    CrossAlign x; /// horizontal placement of children
    CrossAlign y; /// vertical placement of children

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(CrossAlign x, CrossAlign y)
    {
        this.x = x;
        this.y = y;
    }

    /// The stack holding `kids`, the last on top.
    Stack opCall(Node[] kids...)
    {
        return new Stack(x, y, kids.dup);
    }
}

/// Children on top of each other: `stack(x: CrossAlign.center, y: CrossAlign.center)(disc, face)`.
StackSpec stack(CrossAlign x = CrossAlign.start, CrossAlign y = CrossAlign.start)
{
    return StackSpec(x, y);
}

/// Stack child placed on its own. Outside a stack it does nothing.
final class Aligned : Node
{
    CrossAlign x; /// horizontal placement in the stack
    CrossAlign y; /// vertical placement in the stack

    /// Wraps `child` with its placement.
    this(CrossAlign x, CrossAlign y, Node child)
    {
        this.x = x;
        this.y = y;
        add(child);
    }

    /// Passes constraints through to the child.
    protected override Size performLayout(Constraints c)
    {
        children[0].offset = Point.init;
        return children[0].layout(c);
    }
}

/// Placement options, waiting for the child.
struct AlignedSpec
{
    CrossAlign x; /// horizontal placement in the stack
    CrossAlign y; /// vertical placement in the stack

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(CrossAlign x, CrossAlign y)
    {
        this.x = x;
        this.y = y;
    }

    /// The wrapper around `child`.
    Aligned opCall(Node child)
    {
        return new Aligned(x, y, child);
    }
}

/// Stack child with its own placement, an axis left out is `start`: `aligned(x: CrossAlign.end)(badge)`.
AlignedSpec aligned(CrossAlign x = CrossAlign.start, CrossAlign y = CrossAlign.start)
{
    return AlignedSpec(x, y);
}

/// Look of a panel.
struct PanelStyle
{
    enum section = "panel"; /// section name in theme files

    /// Variants theme files can style as `[section.variant]`.
    enum Variants
    {
        toolbar, /// top bar
        pane,    /// dock pane body
        status,  /// bottom bar
        header,  /// strip above a list
        popup,   /// popup body
    }

    Color fill;           /// background
    Color border;         /// outline
    float borderWidth = 0; /// outline width
    float radius = 0;     /// corner radius
    float padX = 0;       /// horizontal padding
    float padY = 0;       /// vertical padding
    Color topLine;        /// one pixel line along the top edge
    Color bottomLine;     /// one pixel line along the bottom edge
    Color shadow;         /// soft shadow under the box
    float shadowBlur = 0; /// shadow fade width
    float shadowY = 0;    /// shadow drop below the box

    /// Look of `variant` without a theme. The base panel draws nothing.
    static void applyVariant(ref PanelStyle s, string variant)
    {
        enum Color bar = Color(0x22, 0x22, 0x27, 0xff);
        enum Color sunk = Color(0x1c, 0x1c, 0x20, 0xff);
        enum Color edge = Color(0x11, 0x11, 0x13, 0xff);
        switch (variant)
        {
        case "toolbar":
            s.fill = bar;
            s.bottomLine = edge;
            s.padX = 6;
            s.padY = 4;
            break;
        case "status":
            s.fill = bar;
            s.topLine = edge;
            s.padX = 10;
            s.padY = 3;
            break;
        case "header":
            s.fill = sunk;
            s.bottomLine = bar;
            s.padX = 8;
            s.padY = 6;
            break;
        case "pane":
            s.fill = sunk;
            break;
        case "popup":
            s.fill = bar;
            s.border = Color(0x43, 0x43, 0x4c, 0xff);
            s.borderWidth = 1;
            s.radius = 6;
            s.padX = 4;
            s.padY = 4;
            s.shadow = Color(0, 0, 0, 0x70);
            s.shadowBlur = 10;
            s.shadowY = 4;
            break;
        default:
            break;
        }
    }
}

/// Box with a themed background, outline and padding around one child.
final class Panel : Node
{
    string variant; /// PanelStyle variant

    /// Wraps `child` in a panel of `variant`.
    this(string variant, Node child)
    {
        this.variant = variant;
        add(child);
    }

    /// Lays out the child inside the style's padding.
    protected override Size performLayout(Constraints c)
    {
        PanelStyle s = tree.style!PanelStyle(variant);
        Insets i = Insets.xy(s.padX, s.padY);
        Size cs = children[0].layout(c.deflate(i));
        children[0].offset = Point(i.left, i.top);
        return Size(cs.w + s.padX * 2, cs.h + s.padY * 2);
    }

    /// Shadow, background, then children, then edge lines.
    override void paint(ref PaintContext ctx, Point origin)
    {
        PanelStyle s = ctx.style!PanelStyle(variant);
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (s.shadow.a > 0)
        {
            ctx.list.shadow(Rect(r.x, r.y + s.shadowY, r.w, r.h), s.radius, s.shadowBlur, s.shadow);
        }
        if (s.fill.a > 0 || s.border.a > 0)
        {
            ctx.list.rect(r, s.fill, s.radius, s.border, s.borderWidth);
        }
        paintChildren(ctx, origin);
        if (s.topLine.a > 0)
        {
            ctx.list.hline(r.x, r.right, r.y, s.topLine);
        }
        if (s.bottomLine.a > 0)
        {
            ctx.list.hline(r.x, r.right, r.bottom - 1, s.bottomLine);
        }
    }
}

/// Panel options, waiting for the child.
struct PanelSpec
{
    string variant; /// `PanelStyle` variant

    /// Stores the variant. Needed because `opCall` hides the struct literal.
    this(string variant)
    {
        this.variant = variant;
    }

    /// The panel around `child`.
    Panel opCall(Node child)
    {
        return new Panel(variant, child);
    }
}

/// Themed panel: `panel(variant: "toolbar")(child)`.
PanelSpec panel(string variant = null)
{
    return PanelSpec(variant);
}

/// Look of a separator line.
struct SeparatorStyle
{
    enum section = "separator"; /// section name in theme files
    Color color = Color(0x80, 0x80, 0x80, 0xff); /// line color
}

/// One pixel line across the cross axis of its parent flex.
final class Separator : Node
{
    bool vertical; /// true for a vertical line in a row

    /// Creates a separator.
    this(bool vertical)
    {
        this.vertical = vertical;
    }

    /// One pixel thick, as long as allowed.
    protected override Size performLayout(Constraints c)
    {
        return vertical ? Size(1, isInfinity(c.maxH) ? 0 : c.maxH) : Size(isInfinity(c.maxW) ? 0 : c.maxW, 1);
    }

    /// The line.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ctx.list.rect(Rect(origin.x, origin.y, size.w, size.h), ctx.style!SeparatorStyle().color);
    }
}

/// Horizontal line for a column.
Separator hrule()
{
    return new Separator(false);
}

/// Vertical line for a row.
Separator vrule()
{
    return new Separator(true);
}

/// Look of scroll bars.
struct ScrollStyle
{
    enum section = "scroll"; /// section name in theme files
    Color thumb = Color(0x80, 0x80, 0x80, 0x80);      /// thumb color
    Color thumbHover = Color(0x80, 0x80, 0x80, 0xc0); /// thumb under the pointer or dragged
    float width = 8;     /// bar width
    float minThumb = 24; /// shortest thumb length
    float wheelStep = 48; /// distance per wheel notch
    float dragStart = 8;  /// distance a press moves before a drag scrolls, see `DragScroller`
    float pressDelay = 120; /// milliseconds a press in a view scrolled by dragging waits before reaching the control
    float longPress = 500;  /// milliseconds a touch or pen press held still waits before opening a context menu
    float flingDecay = 325; /// milliseconds for a fling to slow to a third of its speed
    float flingMin = 50;  /// slowest fling, in logical pixels per second
}

/// Content dragged by a pointer, then coasting after a quick release and slowing down, for the views that scroll
/// by dragging. Distances are scroll distances, the opposite of the pointer's.
struct Fling
{
    enum float maxSpeed = 8000; /// fastest fling, in logical pixels per second
    enum Duration window = 100.msecs; /// span of pointer moves the release speed is taken over

    bool held;      /// a pointer is dragging the content
    Point velocity; /// coasting speed in logical pixels per second

    private Point last;       /// pointer at the last move
    private MonoTime stepped; /// time of the last coast step
    private Point[8] at;      /// recent pointer positions, a ring
    private MonoTime[8] when; /// times of `at`
    private size_t taken;     /// positions taken since the grab

    /// True while coasting.
    bool coasting() const
    {
        return held == false && (velocity.x != 0 || velocity.y != 0);
    }

    /// Follows the pointer from `p` at `t`, stopping a coast.
    void grab(Point p, MonoTime t)
    {
        held = true;
        velocity = Point(0, 0);
        last = p;
        taken = 0;
        sample(p, t);
    }

    /// Scroll distance for a pointer move to `p` at `t`.
    Point drag(Point p, MonoTime t)
    {
        Point d = last - p;
        last = p;
        sample(p, t);
        return d;
    }

    /// Lets go at `p` and `t`. Coasts at the pointer speed over the last `window` when that is `minSpeed` or more,
    /// true if it does.
    bool release(Point p, MonoTime t, float minSpeed)
    {
        held = false;
        sample(p, t);
        size_t newest = (taken - 1) % at.length;
        size_t oldest = newest;
        foreach (size_t back; 1 .. min(taken, at.length))
        {
            size_t i = (taken - 1 - back) % at.length;
            if (t - when[i] > window)
            {
                break;
            }
            oldest = i;
        }
        float dt = (when[newest] - when[oldest]).total!"usecs" / 1e6f;
        velocity = Point(0, 0);
        if (dt > 0)
        {
            velocity = Point((at[oldest].x - at[newest].x) / dt, (at[oldest].y - at[newest].y) / dt);
        }
        float speed = hypot(velocity.x, velocity.y);
        if (speed < minSpeed || isNaN(speed))
        {
            velocity = Point(0, 0);
            return false;
        }
        if (speed > maxSpeed)
        {
            velocity = Point(velocity.x * maxSpeed / speed, velocity.y * maxSpeed / speed);
        }
        stepped = t;
        return true;
    }

    /// Coast distance from the last step to `now`, slowing so the speed falls to a third in `decay` milliseconds.
    /// Stops below `minSpeed`.
    Point coast(MonoTime now, float decay, float minSpeed)
    {
        float dt = (now - stepped).total!"usecs" / 1e6f;
        if (dt <= 0)
        {
            return Point(0, 0);
        }
        stepped = now;
        float tau = decay / 1000 / log(3f);
        float k = exp(-dt / tau);
        Point d = Point(velocity.x * tau * (1 - k), velocity.y * tau * (1 - k));
        velocity = Point(velocity.x * k, velocity.y * k);
        if (hypot(velocity.x, velocity.y) < minSpeed)
        {
            velocity = Point(0, 0);
        }
        return d;
    }

    /// Stops coasting.
    void stop()
    {
        held = false;
        velocity = Point(0, 0);
    }

    /// Stops a coast and follows the pointer from `p` at `t`. True if it was coasting.
    bool catchAt(Point p, MonoTime t)
    {
        if (coasting == false)
        {
            return false;
        }
        grab(p, t);
        return true;
    }

    /// Runs `step` for `owner` on the next frame while coasting.
    void next(Node owner, void delegate() step)
    {
        if (coasting && owner.tree !is null && owner.tree.services !is null)
        {
            owner.tree.callAt(owner, owner.tree.services.now, step);
        }
    }

    /// Adds pointer position `p` at `t` to the ring.
    private void sample(Point p, MonoTime t)
    {
        at[taken % at.length] = p;
        when[taken % at.length] = t;
        ++taken;
    }
}

/// Child of a ScrollView that lays out only the part in view, such as a virtual list.
interface ViewportAware
{
    /// Takes the visible part of the content, `height` tall from `top`, before layout and on every scroll.
    void viewport(float top, float height);
    /// Distance to add to the scroll so the rows in view stay put after rows above them changed, then 0 until
    /// they change again.
    float takeShift();
}

/// Vertical scroll view over one child as tall as it wants.
final class ScrollView : Node, DragScroller
{
    float scrollY = 0;  /// distance scrolled from the top, in logical pixels
    bool follow;        /// true to keep showing the end while scrolled to it, for logs
    bool followTop;     /// true to keep showing the top while scrolled to it, for newest-first feeds
    ScrollDrag drag;    /// pointers that scroll it by dragging the content
    private Fling fling;    /// content drag and fling
    private bool dragging;  /// thumb is being dragged
    private float grabY;    /// pointer y minus thumb top at grab
    private bool atBottom = true; /// was at the bottom before the last layout
    private bool atTop = true;    /// was at the top before the last layout

    /// Wraps `child`.
    this(Node child, bool follow, bool followTop = false)
    {
        this.follow = follow;
        this.followTop = followTop;
        add(child);
        interactive = true;
    }

    /// Content height.
    private float contentH()
    {
        return children[0].size.h;
    }

    /// Largest scroll distance.
    private float maxScroll()
    {
        return max(0f, contentH - size.h);
    }

    /// Fills the constraints, lays the child out with unbounded height. A ViewportAware child is laid out again
    /// while its shift, following the end or clamping moved the view.
    protected override Size performLayout(Constraints c)
    {
        Size own = Size(isInfinity(c.maxW) ? c.minW : c.maxW, isInfinity(c.maxH) ? c.minH : c.maxH);
        Constraints cc = Constraints(own.w, own.w, 0, float.infinity);
        ViewportAware va = cast(ViewportAware) children[0];
        size = own;
        foreach (int pass; 0 .. 3)
        {
            float shown = scrollY;
            if (va !is null)
            {
                scrollY += keptShift(va);
                shown = scrollY;
                va.viewport(scrollY, own.h);
            }
            children[0].layout(cc);
            if (va !is null)
            {
                scrollY += keptShift(va);
            }
            if (follow && atBottom)
            {
                scrollY = maxScroll;
            }
            if (followTop && atTop)
            {
                scrollY = 0;
            }
            scrollY = clamp(scrollY, 0, maxScroll);
            if (va is null || scrollY == shown)
            {
                break;
            }
        }
        atTop = scrollY <= 0.5f;
        children[0].offset = contentOffset();
        return own;
    }

    /// Shift from `va` to add to the scroll, 0 while following the top.
    private float keptShift(ViewportAware va)
    {
        float shift = va.takeShift();
        return followTop && atTop ? 0 : shift;
    }

    /// Child offset for the scroll distance, on whole physical pixels so the content's layers move without
    /// tessellating again.
    private Point contentOffset()
    {
        float ppp = tree is null ? 1 : tree.ppp;
        return Point(0, -round(scrollY * ppp) / ppp);
    }

    /// Scrolls to `y`, clamped.
    void scrollTo(float y)
    {
        float before = scrollY;
        scrollY = clamp(y, 0, maxScroll);
        atBottom = scrollY >= maxScroll - 0.5f;
        atTop = scrollY <= 0.5f;
        children[0].offset = contentOffset();
        if (ViewportAware va = cast(ViewportAware) children[0])
        {
            va.viewport(scrollY, size.h);
        }
        if (scrollY != before)
        {
            markNeedsPaint();
        }
    }

    /// Scrolls the least distance that shows `r`, given in content coordinates. A rect taller than the view
    /// shows its top.
    void reveal(Rect r)
    {
        if (r.y < scrollY)
        {
            scrollTo(r.y);
        }
        else if (r.bottom > scrollY + size.h)
        {
            scrollTo(min(r.y, r.bottom - size.h));
        }
    }

    /// Thumb rect in window coordinates, empty when everything fits.
    private Rect thumb(Point origin, ScrollStyle s)
    {
        if (contentH <= size.h || size.h <= 0)
        {
            return Rect.init;
        }
        float h = max(s.minThumb, size.h * size.h / contentH);
        float y = (size.h - h) * scrollY / maxScroll;
        return Rect(origin.x + size.w - s.width - 2, origin.y + y, s.width, h);
    }

    /// Children clipped, then the thumb.
    override void paint(ref PaintContext ctx, Point origin)
    {
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        ctx.clipped(r, { paintChildren(ctx, origin); });
        ScrollStyle s = ctx.style!ScrollStyle();
        Rect t = thumb(origin, s);
        if (t.empty == false)
        {
            ctx.list.rect(t, dragging || hovered ? s.thumbHover : s.thumb, s.width / 2);
        }
    }

    /// The bar area belongs to the view, the rest to the children.
    override Node hitTest(Point p, Point origin)
    {
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (r.contains(p) == false)
        {
            return null;
        }
        ScrollStyle s = tree.style!ScrollStyle();
        if (contentH > size.h && p.x >= r.right - s.width - 4)
        {
            return this;
        }
        return super.hitTest(p, origin);
    }

    /// True if `source` drags it per `drag`, away from the bar, while there is more to show.
    bool scrollsDrag(PointerSource source, Point at, out bool onBar)
    {
        ScrollStyle s = tree.style!ScrollStyle();
        ScrollDrag mode = drag == ScrollDrag.inherit ? tree.scrollDrag : drag;
        onBar = contentH > size.h && at.x >= bounds.right - s.width - 4;
        return contentH > size.h && mode.scrollsWith(source) && onBar == false;
    }

    /// Takes a mostly vertical drag with room to scroll that way, or any when `edge` is set.
    bool takeDrag(Point at, Point moved, bool edge, MonoTime time)
    {
        if (abs(moved.y) <= abs(moved.x) || contentH <= size.h)
        {
            return false;
        }
        if (edge == false && (moved.y > 0 ? scrollY <= 0 : scrollY >= maxScroll))
        {
            return false;
        }
        fling.grab(at, time);
        return true;
    }

    /// Stops a fling and holds the content at `at`.
    bool catchFling(Point at, MonoTime time)
    {
        return fling.catchAt(at, time);
    }

    /// Moves the fling on to the frame time, until it stops or reaches an end.
    private void coast()
    {
        if (fling.coasting == false)
        {
            return;
        }
        ScrollStyle s = tree.style!ScrollStyle();
        float want = scrollY + fling.coast(tree.services.now, s.flingDecay, s.flingMin).y;
        scrollTo(want);
        if (scrollY != want)
        {
            fling.stop();
        }
        fling.next(this, &coast);
    }

    /// Thumb dragging, track clicks and content drags.
    override bool onPointer(ref const PointerEvent e)
    {
        ScrollStyle s = tree.style!ScrollStyle();
        Rect b = bounds;
        Rect t = thumb(b.pos, s);
        switch (e.kind)
        {
        case PointerKind.down:
            if (t.empty)
            {
                return false;
            }
            if (t.contains(e.pos) == false)
            {
                if (e.pos.x < b.right - s.width - 4)
                {
                    return false;
                }
                scrollTo(scrollY + (e.pos.y < t.y ? -size.h : size.h));
                return true;
            }
            dragging = true;
            grabY = e.pos.y - t.y;
            markNeedsPaint();
            return true;
        case PointerKind.move:
            if (fling.held)
            {
                scrollTo(scrollY + fling.drag(e.pos, e.time).y);
                return true;
            }
            if (dragging)
            {
                float track = size.h - t.h;
                float top = e.pos.y - grabY - b.y;
                scrollTo(track > 0 ? top / track * maxScroll : 0);
                return true;
            }
            return false;
        case PointerKind.up:
            if (fling.held && fling.release(e.pos, e.time, s.flingMin))
            {
                fling.next(this, &coast);
            }
            fling.held = false;
            dragging = false;
            markNeedsPaint();
            return true;
        case PointerKind.cancel:
            fling.held = false;
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

    /// Wheel scrolling, which stops a fling. Horizontal turns and Shift with the wheel go on to the parents.
    override bool onWheel(ref const WheelEvent e)
    {
        if (contentH <= size.h || e.dy == 0 || (e.mods & Mod.shift) != 0)
        {
            return false;
        }
        fling.stop();
        scrollTo(scrollY + e.dy);
        return true;
    }
}

/// Scrolls every scroll view holding `n` so that `n` shows, innermost first. A view's own content, such as a
/// focused virtual list, keeps its scroll.
void scrollIntoView(Node n)
{
    scrollIntoView(n, n.bounds);
}

/// Scrolls every scroll view holding `n` so that the window rect `r` inside `n` shows, innermost first. A view's
/// own content keeps its scroll when `r` is all of it.
void scrollIntoView(Node n, Rect r)
{
    Rect t = r;
    for (Node p = n.parent; p !is null; p = p.parent)
    {
        ScrollView sv = cast(ScrollView) p;
        if (sv is null)
        {
            continue;
        }
        Rect c = sv.children[0].bounds;
        if (t != c)
        {
            sv.reveal(Rect(t.x - c.x, t.y - c.y, t.w, t.h));
        }
        t = sv.bounds;
    }
}

/// Scroll options, waiting for the child.
struct ScrollSpec
{
    bool follow;    /// true to keep showing the end while scrolled to it, for logs
    bool followTop; /// true to keep showing the top while scrolled to it, for newest-first feeds
    ScrollDrag drag; /// pointers that scroll it by dragging the content

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(bool follow, bool followTop, ScrollDrag drag)
    {
        this.follow = follow;
        this.followTop = followTop;
        this.drag = drag;
    }

    /// The scroll view around `child`.
    ScrollView opCall(Node child)
    {
        ScrollView sv = new ScrollView(child, follow, followTop);
        sv.drag = drag;
        return sv;
    }
}

/// Vertical scroll view: `scroll(follow: true)(child)`. `drag` picks the pointers that scroll it by dragging the
/// content, touch and pen unless the window says otherwise, see `WindowOptions.scrollDrag`.
ScrollSpec scroll(bool follow = false, bool followTop = false, ScrollDrag drag = ScrollDrag.inherit)
{
    return ScrollSpec(follow, followTop, drag);
}

// Panel skeleton from research/examples/layout.d, now with default cross alignments and spacers.
unittest
{
    Fixed filter = new Fixed(Size(40, 16));
    Fixed box = new Fixed(Size(0, 20));
    Fixed summary = new Fixed(Size(96, 16));
    Fixed button = new Fixed(Size(120, 24));
    Flex top = row(gap: 4)(filter, expanded(box));
    Flex bottom = row(gap: 4)(summary, spacer(), button);
    Flex body = column(gap: 4)(top, expanded(new Fixed(Size.init)), bottom);
    Padding root = pad(all: 8)(body);
    Tree t = bareTree(root, Size(400, 300));
    t.flush();
    assert(top.bounds == Rect(8, 8, 384, 20));
    assert(filter.bounds == Rect(8, 10, 40, 16), "centered in a 20 px row");
    assert(box.bounds == Rect(52, 8, 340, 20));
    assert(button.bounds == Rect(272, 268, 120, 24));
}

// Flex shares are whole pixels and add up to the free space.
unittest
{
    Fixed[3] k;
    foreach (ref Fixed f; k)
    {
        f = new Fixed(Size.init);
    }
    Flex r = row()(expanded(k[0]), expanded(k[1]), expanded(k[2]));
    Tree t = bareTree(r, Size(100, 10));
    t.flush();
    assert(k[0].size.w + k[1].size.w + k[2].size.w == 100);
    assert(k[1].size.w == 34 && k[0].size.w == 33);
}

// Grid columns split the width in whole pixels, rows take their tallest cell and stretch the others.
unittest
{
    Fixed[5] k;
    foreach (size_t i, ref Fixed f; k)
    {
        f = new Fixed(Size(0, [10, 20, 15, 5, 5][i]));
    }
    Grid g = grid(cols: 3, gap: 4)(k[0], k[1], k[2], k[3], k[4]);
    Tree t = bareTree(column(cross: CrossAlign.stretch)(g), Size(100, 300));
    t.flush();
    assert(g.size == Size(100, 29));
    assert(k[0].bounds == Rect(0, 0, 31, 20));
    assert(k[1].bounds == Rect(35, 0, 30, 20));
    assert(k[2].bounds == Rect(69, 0, 31, 20));
    assert(k[3].bounds == Rect(0, 24, 31, 5));
}

// A grid given a minimum height shares it between the rows, and `cross` places cells in them.
unittest
{
    Fixed[3] k;
    foreach (ref Fixed f; k)
    {
        f = new Fixed(Size(10, 10));
    }
    Grid g = grid(cols: 2, gap: 4, cross: CrossAlign.center)(k[0], k[1], k[2]);
    Tree t = bareTree(g, Size(100, 60));
    t.flush();
    assert(g.size == Size(100, 60));
    assert(k[0].bounds == Rect(0, 9, 48, 10), "row of 28, two of the 36 extra");
    assert(k[2].bounds == Rect(0, 41, 48, 10), "row of 28 from 32");
}

// `minCell` fits as many columns as the width allows, an unbounded width puts every child in one row.
unittest
{
    foreach (int w, int cols; [263: 3, 264: 4])
    {
        Node[] kids;
        foreach (int i; 0 .. 5)
        {
            kids ~= new Fixed(Size(0, 10));
        }
        Grid g = grid(minCell: 60, gap: 8)(kids);
        Tree t = bareTree(column()(g), Size(w, 300));
        t.flush();
        assert(kids[cols].offset == Point(0, 18), "first cell of the second row");
    }
    Fixed narrow = new Fixed(Size(30, 10));
    Grid g = grid(minCell: 20, gap: 2)(narrow, new Fixed(Size(5, 10)));
    Tree t = bareTree(row()(g), Size(500, 100));
    t.flush();
    assert(g.size == Size(62, 10), "two columns as wide as the widest child");
}

// A stack sizes to its children, centers them, and the last child wins hits.
unittest
{
    Fixed disc = new Fixed(Size(40, 40));
    Fixed face = new Fixed(Size(20, 10));
    Stack s = stack(x: CrossAlign.center, y: CrossAlign.center)(disc, face);
    Tree t = bareTree(row()(s), Size(200, 100));
    t.flush();
    assert(s.size == Size(40, 40));
    assert(face.offset == Point(10, 15));
    assert(s.hitTest(Point(20, 50), Point(0, 30)) is face);
    assert(s.hitTest(Point(2, 32), Point(0, 30)) is disc);
}

// Stretched stack children fill the size the others give, `aligned` places one child on its own.
unittest
{
    Fixed back = new Fixed(Size(500, 500));
    Fixed content = new Fixed(Size(30, 20));
    Fixed badge = new Fixed(Size(8, 8));
    Stack s = stack()(aligned(x: CrossAlign.stretch, y: CrossAlign.stretch)(back), content,
        aligned(x: CrossAlign.end, y: CrossAlign.end)(badge));
    Tree t = bareTree(row()(s), Size(200, 100));
    t.flush();
    assert(s.size == Size(30, 20));
    assert(back.size == Size(30, 20));
    assert(badge.offset == Point(0, 0) && badge.parent.offset == Point(22, 12));

    Fixed fill = new Fixed(Size.init);
    Stack all = stack(x: CrossAlign.stretch, y: CrossAlign.stretch)(fill);
    t = bareTree(all, Size(100, 50));
    t.flush();
    assert(fill.size == Size(100, 50), "every child stretched fills the space");
}

// A column inside a scroll view gets unbounded height, and flex children keep their natural size.
unittest
{
    Node[] rows;
    foreach (int i; 0 .. 50)
    {
        rows ~= new Fixed(Size(10, 20));
    }
    Flex list = column()(rows);
    Flex withFlex = column()(expanded(new Fixed(Size(5, 7))));
    ScrollView sv = scroll()(column()(list, withFlex));
    Tree t = bareTree(sv, Size(200, 100));
    t.flush();
    assert(list.size == Size(200, 1000), "stretched across, as tall as the rows");
    assert(withFlex.size.h == 7);
    sv.scrollTo(5000);
    assert(sv.scrollY == 907);
    assert(sv.hitTest(Point(50, 50), Point(0, 0)) is rows[47]);
    sv.reveal(Rect(0, 40, 10, 20));
    assert(sv.scrollY == 40);
    sv.reveal(Rect(0, 300, 10, 400));
    assert(sv.scrollY == 300, "a tall rect shows its top");
    scrollIntoView(rows[49]);
    assert(sv.scrollY == 900);
    scrollIntoView(list);
    assert(sv.scrollY == 0);
    sv.scrollTo(50);
    scrollIntoView(sv.children[0]);
    assert(sv.scrollY == 50, "the content itself keeps the scroll");
}

// A fling takes the pointer speed over the last 100 ms, opposite to the pointer, and slows to a third in
// `decay` ms until below the slowest speed. A release after a pause does not fling, and the speed is capped.
unittest
{
    import std.math : isClose;

    MonoTime t = MonoTime.currTime;
    Fling f;
    f.grab(Point(0, 300), t);
    assert(f.drag(Point(0, 290), t + 10.msecs) == Point(0, 10));
    foreach (int i; 2 .. 30)
    {
        f.drag(Point(0, 300 - i * 10), t + (i * 10).msecs);
    }
    assert(f.release(Point(0, 10), t + 290.msecs, 50) && f.coasting);
    assert(isClose(f.velocity.y, 1000) && f.velocity.x == 0);
    Point d = f.coast(t + 615.msecs, 325, 50);
    assert(isClose(f.velocity.y, 1000.0 / 3, 1e-3) && isClose(d.y, 1000 * 0.325 / log(3.0) * 2 / 3, 1e-3));
    f.coast(t + 5000.msecs, 325, 50);
    assert(f.coasting == false, "stops below the slowest speed");

    f.grab(Point(0, 300), t);
    f.drag(Point(0, 200), t + 10.msecs);
    assert(f.release(Point(0, 200), t + 200.msecs, 50) == false && f.coasting == false);
    f.grab(Point(0, 300), t);
    f.drag(Point(0, 200), t + 10.msecs);
    assert(f.release(Point(0, 200), t + 10.msecs, 50) && f.velocity.y == Fling.maxSpeed, "capped");
    assert(f.catchAt(Point(0, 0), t) && f.held && f.coasting == false);
}

// A press on the content bubbling up to the view does not page it, only a press in the scrollbar strip does.
unittest
{
    Node[] rows;
    foreach (int i; 0 .. 50)
    {
        rows ~= new Fixed(Size(10, 20));
    }
    ScrollView sv = scroll()(column()(rows));
    Tree t = bareTree(sv, Size(200, 100));
    t.flush();
    PointerEvent e;
    e.kind = PointerKind.down;
    e.button = 1;
    e.pos = Point(100, 50);
    assert(sv.onPointer(e) == false && sv.scrollY == 0);
    e.pos = Point(199, 90);
    assert(sv.onPointer(e) && sv.scrollY == 100);
}

// A squeeze shows the first child whose ranges hold the offered size, bounds included, with a plain child as the
// fallback. The others stay detached and keep their state.
unittest
{
    Node wide = new Fixed(Size(30, 10));
    Node medium = new Fixed(Size(20, 10));
    Node narrow = new Fixed(Size(10, 10));
    Squeeze q = squeeze()(fits(minW: 800)(wide), fits(minW: 500, maxH: 300)(medium), narrow);
    Sized box = sized(w: 900, h: 200)(q);
    Tree t = bareTree(stack()(box), Size(1000, 1000));
    t.flush();
    assert(q.shown == 0 && wide.tree is t && medium.tree is null && narrow.parent is null);
    box.w = 800;
    box.markNeedsLayout();
    t.flush();
    assert(q.shown == 0);
    box.w = 799;
    box.markNeedsLayout();
    t.flush();
    assert(q.shown == 1 && wide.tree is null && medium.tree is t && q.size == Size(799, 200));
    box.h = 301;
    box.markNeedsLayout();
    t.flush();
    assert(q.shown == 2 && narrow.tree is t && medium.tree is null);
    box.w = 900;
    box.markNeedsLayout();
    t.flush();
    assert(q.shown == 0 && wide.tree is t && narrow.tree is null);
}

// A squeeze with nothing that fits is empty, and an unbounded axis counts as infinitely large.
unittest
{
    Node wide = new Fixed(Size(30, 10));
    Squeeze q = squeeze()(fits(maxW: 400)(new Fixed(Size(10, 10))));
    Tree t = bareTree(stack()(row()(q)), Size(300, 100));
    t.flush();
    assert(q.shown == -1 && q.children.length == 0 && q.size == Size(0, 0));
    Squeeze r = squeeze()(fits(minW: 5000)(wide));
    Tree u = bareTree(stack()(row()(r)), Size(300, 100));
    u.flush();
    assert(r.shown == 0 && r.size == Size(30, 10));
}

// A clamped child gets at most its cap and is centered, and gets the full width below the cap.
unittest
{
    Clamped k = clamped(maxW: 400)(new Fixed(Size(1000, 20)));
    Sized box = sized(w: 1000)(k);
    Tree t = bareTree(stack()(box), Size(1200, 100));
    t.flush();
    assert(k.size == Size(1000, 20) && k.children[0].size.w == 400 && k.children[0].offset.x == 300);
    box.w = 300;
    box.markNeedsLayout();
    t.flush();
    assert(k.size.w == 300 && k.children[0].size.w == 300 && k.children[0].offset.x == 0);
}
