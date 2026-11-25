/// Slop dot: a small glowing status light, with rings that grow out of it and fade while it pulses.
module dentrite.widgets.slopdot;

import core.time : MonoTime, msecs;
import dentrite.immediate;
import dentrite.node;
import dentrite.signals : effect;
import std.algorithm.comparison : clamp, max;
import std.math : abs, floor;

/// What a slop dot shows.
enum DotState : ubyte
{
    off,     /// unlit, no glow
    on,      /// lit with its glow, still
    pulsing, /// lit, with rings that grow out of it and fade
}

/// Look of a slop dot.
struct SlopDotStyle
{
    enum section = "slopdot"; /// section name in theme files

    /// Variants theme files can style as `[section.variant]`, each a color.
    enum Variants
    {
        green,  /// emerald, the default color
        purple, /// purple
        cyan,   /// cyan
        amber,  /// amber
        pink,   /// pink
        red,    /// rose red
        indigo, /// indigo
    }

    Color on = Color(0x10, 0xb9, 0x81, 0xff);  /// dot, glow and rings
    Color off = Color(0x3a, 0x3a, 0x40, 0xff); /// unlit dot, transparent to leave a gap
    float size = 9;          /// dot diameter
    float glow = 10;         /// width of the glow fading out from the dot's edge, 0 for none
    float glowAlpha = 0.15;  /// glow opacity at the dot's edge, 0 to 1
    float ringInset = 2;     /// how far a ring starts outside the dot's edge
    float ringScale = 2.8;   /// ring diameter at its largest, relative to its start
    float ringAlpha = 0.6;   /// ring opacity as it starts, 0 to 1
    float ringGrow = 0.75;   /// part of the period a ring takes to grow and fade, the rest it is gone
    int rings = 2;           /// rings in flight
    float ringDelay = 0.45;  /// part of the period between one ring and the next
    int period = 2000;       /// milliseconds from one ring to the next start of the same ring

    /// Look of `variant` without a theme: its color.
    static void applyVariant(ref SlopDotStyle s, string variant)
    {
        switch (variant)
        {
        case "green":
            s.on = Color(0x10, 0xb9, 0x81, 0xff);
            break;
        case "purple":
            s.on = Color(0xa8, 0x55, 0xf7, 0xff);
            break;
        case "cyan":
            s.on = Color(0x06, 0xb6, 0xd4, 0xff);
            break;
        case "amber":
            s.on = Color(0xf5, 0x9e, 0x0b, 0xff);
            break;
        case "pink":
            s.on = Color(0xec, 0x48, 0x99, 0xff);
            break;
        case "red":
            s.on = Color(0xf4, 0x3f, 0x5e, 0xff);
            break;
        case "indigo":
            s.on = Color(0x63, 0x66, 0xf1, 0xff);
            break;
        default:
            break;
        }
    }
}

/// Size of a slop dot under `c`: the dot alone. Glow and rings paint past it, as box shadows do on a web page.
Size measureSlopDot(Constraints c, const ref SlopDotStyle s)
{
    return c.constrain(Size(s.size, s.size));
}

/// CSS `cubic-bezier(0, 0, 0.2, 1)`, the ease out of a ping, at `x` from 0 to 1.
double easeOutPing(double x)
{
    // Control points (0, 0) and (0.2, 1) give x = 0.6 (1 - t) t^2 + t^3 and y = 3 (1 - t) t^2 + t^3.
    // x rises with t, so bisection finds the t for `x`.
    if (x <= 0 || x >= 1)
    {
        return x <= 0 ? 0 : 1;
    }
    double lo = 0, hi = 1, t = x;
    foreach (i; 0 .. 30)
    {
        t = (lo + hi) / 2;
        double xt = 0.6 * (1 - t) * t * t + t * t * t;
        if (abs(xt - x) < 1e-7)
        {
            break;
        }
        if (xt < x)
        {
            lo = t;
        }
        else
        {
            hi = t;
        }
    }
    return 3 * (1 - t) * t * t + t * t * t;
}

/// Ring `i` of a dot pulsing for `elapsed` milliseconds: its diameter relative to its start and its opacity.
/// False while it has not started yet or has faded out.
bool ringAt(const ref SlopDotStyle s, int i, long elapsed, out float scale, out float alpha)
{
    long period = max(1, s.period);
    double t = cast(double) elapsed / period - i * s.ringDelay;
    if (t < 0)
    {
        return false;
    }
    double p = (t - floor(t)) / max(1e-6, s.ringGrow);
    if (p >= 1)
    {
        return false;
    }
    double k = easeOutPing(p);
    scale = cast(float)(1 + (s.ringScale - 1) * k);
    alpha = cast(float)(s.ringAlpha * (1 - k));
    return alpha > 0;
}

/// `c` with its alpha times `f`.
private Color faded(Color c, float f)
{
    c.a = cast(ubyte) clamp(c.a * f + 0.5f, 0, 255);
    return c;
}

/// Paints a dot centered in `r` in `state`, its rings as at `elapsed` milliseconds of pulsing. Shared by the
/// retained node and the island function.
void paintSlopDot(ref PaintContext ctx, Rect r, const ref SlopDotStyle s, DotState state, long elapsed)
{
    float d = s.size;
    float cx = r.x + r.w / 2;
    float cy = r.y + r.h / 2;
    Rect dot = Rect(cx - d / 2, cy - d / 2, d, d);
    if (state == DotState.off)
    {
        if (s.off.a > 0)
        {
            ctx.list.rect(dot, s.off, d / 2);
        }
        return;
    }
    if (s.glow > 0 && s.glowAlpha > 0)
    {
        // The fade straddles the shadow's edge, so grow it by half the blur to start the fade at the dot's edge.
        float g = s.glow / 2;
        ctx.list.shadow(dot.inset(-g), d / 2 + g, s.glow, faded(s.on, s.glowAlpha));
    }
    ctx.list.rect(dot, s.on, d / 2);
    if (state != DotState.pulsing)
    {
        return;
    }
    foreach (int i; 0 .. max(0, s.rings))
    {
        float scale, alpha;
        if (ringAt(s, i, elapsed, scale, alpha))
        {
            float rd = (d + 2 * s.ringInset) * scale;
            ctx.list.rect(Rect(cx - rd / 2, cy - rd / 2, rd, rd), faded(s.on, alpha), rd / 2);
        }
    }
}

/// Fills `a` for a dot in `state`.
private void describeSlopDot(ref AccessInfo a, DotState state)
{
    a.role = Role.image;
    a.value = state == DotState.off ? "off" : state == DotState.on ? "on" : "pulsing";
}

/// Retained slop dot. Build it with `slopDot`.
final class SlopDot : Node
{
    string variant;         /// SlopDotStyle variant
    private DotState shown; /// state last read
    private MonoTime start; /// when pulsing began, the first ring starts then

    /// Creates a dot following `state`. The binding effect belongs to the current owner.
    this(DotState delegate() state, string variant)
    {
        this.variant = variant;
        repaintBoundary = true;
        effect(() {
            DotState v = state();
            if (v != shown)
            {
                if (v == DotState.pulsing)
                {
                    start = MonoTime.init;
                }
                shown = v;
                markNeedsPaint();
            }
        });
    }

    /// State shown.
    DotState state() const
    {
        return shown;
    }

    /// Off, on or pulsing, for screen readers.
    override void describe(ref AccessInfo a)
    {
        describeSlopDot(a, shown);
    }

    /// The style's diameter, square.
    protected override Size performLayout(Constraints c)
    {
        SlopDotStyle s = tree.style!SlopDotStyle(variant);
        return measureSlopDot(c, s);
    }

    /// Dot and glow, and while pulsing the rings with a repaint scheduled for the next frame.
    override void paint(ref PaintContext ctx, Point origin)
    {
        SlopDotStyle s = ctx.style!SlopDotStyle(variant);
        long elapsed = 0;
        if (shown == DotState.pulsing && tree.services !is null)
        {
            MonoTime now = tree.services.now;
            if (start == MonoTime.init)
            {
                start = now;
            }
            elapsed = (now - start).total!"msecs";
            markNeedsPaintAt(now + 16.msecs);
        }
        paintSlopDot(ctx, Rect(origin.x, origin.y, size.w, size.h), s, shown, elapsed);
    }
}

/// Retained slop dot following `state`: `slopDot(() => live.get ? DotState.pulsing : DotState.off, "green")`.
SlopDot slopDot(DotState delegate() state, string variant = null, string tooltip = null, string accessName = null)
{
    SlopDot d = new SlopDot(state, variant);
    d.setTooltip(tooltip);
    d.accessName = accessName;
    return d;
}

/// Paint-only slop dot declared by an island pass.
final class SlopDotBox : Node
{
    SlopDotStyle style; /// style in use, resolved from the theme
    DotState state;     /// state shown
    long elapsed;       /// milliseconds of pulsing, where the rings are

    /// Creates a box.
    this(SlopDotStyle style, DotState state, long elapsed)
    {
        this.style = style;
        this.state = state;
        this.elapsed = elapsed;
    }

    /// Off, on or pulsing, for screen readers.
    override void describe(ref AccessInfo a)
    {
        describeSlopDot(a, state);
    }

    /// Same size as the retained dot.
    protected override Size performLayout(Constraints c)
    {
        return measureSlopDot(c, style);
    }

    /// Same look as the retained dot.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintSlopDot(ctx, Rect(origin.x, origin.y, size.w, size.h), style, state, elapsed);
    }
}

/// Island slop dot in `state`. While pulsing it asks for a pass every frame, with its rings in step with every
/// other pulsing island dot.
void slopDot(Ui ui, DotState state, string variant = null)
{
    SlopDotStyle s = ui.style!SlopDotStyle(variant);
    long elapsed = 0;
    if (state == DotState.pulsing)
    {
        elapsed = (ui.now - MonoTime.zero).total!"msecs";
        ui.requestFrame();
    }
    ui.put(new SlopDotBox(s, state, elapsed));
}

// The dot follows its state and takes its diameter. Off is a plain dot, on adds the glow, pulsing adds rings.
unittest
{
    import dentrite.containers : row;
    import dentrite.draw : DrawList, Op;
    import dentrite.host : Host;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!DotState st = signal(DotState.on);
    SlopDot d = slopDot(() => st.get, "green");
    h.setRoot(row()(d));
    h.frame();
    SlopDotStyle s;
    assert(d.size == Size(s.size, s.size) && d.state == DotState.on);

    PaintContext ctx;
    DrawList list;
    ctx.list = &list;
    paintSlopDot(ctx, Rect(0, 0, 21, 11), s, DotState.off, 0);
    assert(list.cmds.length == 1 && list.cmds[0].r == Rect(6, 1, 9, 9), "off: the dot alone, centered");
    list.clear();
    paintSlopDot(ctx, Rect(0, 0, 9, 9), s, DotState.on, 0);
    assert(list.cmds.length == 2 && list.cmds[0].op == Op.shadow && list.cmds[0].r == Rect(-5, -5, 19, 19),
        "on: the glow under the dot, fading out from its edge");
    list.clear();
    paintSlopDot(ctx, Rect(0, 0, 9, 9), s, DotState.pulsing, 0);
    assert(list.cmds.length == 3 && list.cmds[2].r == Rect(-2, -2, 13, 13), "the first ring starts at the inset");
    list.clear();
    paintSlopDot(ctx, Rect(0, 0, 9, 9), s, DotState.pulsing, 900);
    assert(list.cmds.length == 4, "the second ring joins after its delay");

    st.set(DotState.pulsing);
    h.frame();
    assert(d.state == DotState.pulsing);
    st.set(DotState.off);
    h.frame();
    assert(d.state == DotState.off);
}

// Rings grow with an ease out and fade, are gone for the end of each period, and follow each other by the delay.
unittest
{
    SlopDotStyle s;
    float scale, alpha;
    assert(ringAt(s, 0, 0, scale, alpha) && scale == 1 && abs(alpha - 0.8) < 1e-6);
    assert(ringAt(s, 0, 375, scale, alpha) && scale > 1.9 && alpha < 0.4, "ease out: past halfway at a third");
    assert(ringAt(s, 0, 1124, scale, alpha) && scale > 2.79 && alpha < 0.01);
    assert(ringAt(s, 0, 1200, scale, alpha) == false, "gone for the last quarter");
    assert(ringAt(s, 0, 1500, scale, alpha) && scale == 1, "starts over each period");
    assert(ringAt(s, 1, 600, scale, alpha) == false, "the second ring waits for its delay");
    assert(ringAt(s, 1, 680, scale, alpha) && scale < 1.1, "then starts small");
    assert(abs(easeOutPing(0)) < 1e-6 && abs(easeOutPing(1) - 1) < 1e-6 && easeOutPing(0.5) > 0.8);
}

// Variants change only the color.
unittest
{
    SlopDotStyle plain;
    SlopDotStyle red;
    SlopDotStyle.applyVariant(red, "red");
    assert(red.on == Color(0xf4, 0x3f, 0x5e, 0xff) && red.off == plain.off && red.size == plain.size);
}
