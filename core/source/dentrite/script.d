/// Scripted input for headless runs: `click:200,102; type:main; wait:3; key:F5`, a frame after each step.
module dentrite.script;

import core.time : MonoTime, msecs;
import dentrite.command : Chord, chord;
import dentrite.geom : Point;
import dentrite.host : Host;
import dentrite.node : PointerKind, PointerSource;
import std.conv : to;
import std.format : format;
import std.string : indexOf, split, strip;

/// Steps `runScript` takes, for help texts.
enum string scriptSteps = "click:X,Y[,Ctrl+Shift] dclick:X,Y rclick:X,Y down:X,Y move:X,Y up:X,Y drag:X0,Y0,X1,Y1 "
    ~ "wheel:X,Y,DY hwheel:X,Y,DX tap:X,Y hold:X,Y swipe:X0,Y0,X1,Y1 type:TEXT compose:TEXT key:SHORTCUT wait:FRAMES";

/// Handles waiting platform events and renders `n` frames 16 ms apart, so timers, animations and answers from
/// other threads move on.
void settle(Host h, int n)
{
    import core.thread : Thread;

    foreach (int i; 0 .. n)
    {
        h.pump();
        h.requestFrame();
        h.frame();
        Thread.sleep(16.msecs);
    }
}

/// Runs the `;` separated steps of `script` on `h` after two settling frames, rendering a frame after each
/// step. Coordinates are logical pixels, `wheel` distances too. A click may name held modifiers, as
/// `click:10,20,Ctrl`. `tap`, `hold` and `swipe` touch, a hold staying still for 600 ms and a swipe moving over
/// 6 frames before letting go. `onStep` hears each step after its frame, with the times it began and its input
/// was handled. Throws on an unknown or malformed step.
void runScript(Host h, string script, void delegate(string step, MonoTime began, MonoTime handled) onStep = null)
{
    settle(h, 2);
    foreach (string raw; script.split(";"))
    {
        string step = raw.strip;
        if (step.length == 0)
        {
            continue;
        }
        ptrdiff_t colon = step.indexOf(':');
        string name = colon < 0 ? step : step[0 .. colon];
        string arg = colon < 0 ? null : step[colon + 1 .. $];
        MonoTime began = MonoTime.currTime;
        switch (name)
        {
        case "click":
        case "dclick":
        case "rclick":
            string[] parts = arg.split(",");
            ubyte mods;
            if (parts.length == 3)
            {
                mods = chord(parts[2] ~ "+A").mods;
                arg = parts[0] ~ "," ~ parts[1];
            }
            Point p = point(numbers(step, arg, 2));
            h.inject(PointerKind.move, p);
            ubyte clicks = name == "dclick" ? 2 : 1;
            ubyte button = name == "rclick" ? 3 : 1;
            h.inject(PointerKind.down, p, clicks, button, mods);
            h.inject(PointerKind.up, p, clicks, button, mods);
            break;
        case "move":
            h.inject(PointerKind.move, point(numbers(step, arg, 2)));
            break;
        case "down":
        case "up":
            Point p = point(numbers(step, arg, 2));
            h.inject(PointerKind.move, p);
            h.inject(name == "down" ? PointerKind.down : PointerKind.up, p);
            break;
        case "drag":
            float[] n = numbers(step, arg, 4);
            Point a = point(n[0 .. 2]);
            Point b = point(n[2 .. 4]);
            h.inject(PointerKind.move, a);
            h.inject(PointerKind.down, a);
            settle(h, 1);
            h.inject(PointerKind.move, b);
            settle(h, 1);
            h.inject(PointerKind.up, b);
            break;
        case "tap":
            Point p = point(numbers(step, arg, 2));
            h.inject(PointerKind.down, p, 1, 1, 0, PointerSource.touch);
            h.inject(PointerKind.up, p, 1, 1, 0, PointerSource.touch);
            break;
        case "hold":
            Point p = point(numbers(step, arg, 2));
            h.inject(PointerKind.down, p, 1, 1, 0, PointerSource.touch);
            MonoTime until = MonoTime.currTime + 600.msecs;
            while (MonoTime.currTime < until)
            {
                settle(h, 1);
            }
            h.inject(PointerKind.up, p, 1, 1, 0, PointerSource.touch);
            break;
        case "swipe":
            float[] n = numbers(step, arg, 4);
            Point a = point(n[0 .. 2]);
            Point b = point(n[2 .. 4]);
            h.inject(PointerKind.down, a, 1, 1, 0, PointerSource.touch);
            foreach (int i; 1 .. 7)
            {
                settle(h, 1);
                float f = i / 6.0f;
                Point at = Point(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f);
                h.inject(PointerKind.move, at, 1, 1, 0, PointerSource.touch);
            }
            h.inject(PointerKind.up, b, 1, 1, 0, PointerSource.touch);
            break;
        case "wheel":
            float[] n = numbers(step, arg, 3);
            h.injectWheel(point(n[0 .. 2]), n[2]);
            break;
        case "hwheel":
            float[] m = numbers(step, arg, 3);
            h.injectWheel(point(m[0 .. 2]), 0, m[2]);
            break;
        case "type":
            h.injectText(arg);
            break;
        case "compose":
            h.injectCompose(arg);
            break;
        case "key":
            Chord c = chord(arg);
            if (c == Chord.init)
            {
                throw new Exception(format("script step %s: unknown key", step));
            }
            h.injectKey(c.key, c.mods);
            break;
        case "wait":
            settle(h, numbers(step, arg, 1)[0].to!int);
            break;
        default:
            throw new Exception(format("unknown script step %s, expected one of: %s", step, scriptSteps));
        }
        MonoTime handled = MonoTime.currTime;
        h.requestFrame();
        h.frame();
        if (onStep !is null)
        {
            onStep(step, began, handled);
        }
    }
}

/// The `n` comma separated numbers of `arg` in `step`. Throws when there are not `n` numbers.
private float[] numbers(string step, string arg, size_t n)
{
    import std.conv : ConvException;

    string[] parts = arg.split(",");
    if (parts.length != n)
    {
        throw new Exception(format("script step %s: expected %d numbers", step, n));
    }
    float[] v = new float[n];
    try
    {
        foreach (size_t i, string s; parts)
        {
            v[i] = s.strip.to!float;
        }
    }
    catch (ConvException e)
    {
        throw new Exception(format("script step %s: %s", step, e.msg));
    }
    return v;
}

/// Point of the first two of `v`.
private Point point(const float[] v)
{
    return Point(v[0], v[1]);
}

// Steps click, type and press keys, and bad steps throw.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.platform : WindowOptions;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.button : button;
    import dentrite.widgets.textbox : textBox;
    import std.exception : assertThrown;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(200, 100), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    Signal!string text = signal("");
    h.setRoot(column()(button("Go", onClick: () { ++clicks; }), textBox(text)));
    h.frame();
    string[] seen;
    runScript(h, "click:10,10; click:100,40; type:ab; key:Backspace; wait:1",
        (string s, MonoTime began, MonoTime handled) { seen ~= s; });
    assert(clicks == 1 && text.peek == "a");
    assert(seen == ["click:10,10", "click:100,40", "type:ab", "key:Backspace", "wait:1"]);
    assertThrown(runScript(h, "click:1"));
    assertThrown(runScript(h, "jump:1,2"));
    assertThrown(runScript(h, "wheel:1,2,x"));
}
