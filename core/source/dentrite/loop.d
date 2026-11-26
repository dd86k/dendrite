/// Loop scheduling: when a frame is due, when alarms run and how long the loop may wait for events until then.
module dentrite.loop;

import core.time : Duration, MonoTime, dur, msecs;
import std.algorithm.comparison : max, min;
import std.algorithm.mutation : SwapStrategy;
import std.algorithm.sorting : sort;

/// Frame requests, frame timers and the frame cap.
struct FrameClock
{
    Duration minInterval;      /// shortest time between frame starts
    bool requested = true;     /// true when a frame should start as soon as the cap allows
    MonoTime last;             /// start of the previous frame
    private MonoTime[] timers; /// requested frame times, unordered

    /// Clock capped at `maxFps` frames per second, uncapped for 0.
    this(double maxFps)
    {
        minInterval = maxFps > 0 ? dur!"usecs"(cast(long)(1_000_000 / maxFps)) : Duration.zero;
    }

    /// Asks for a frame as soon as the cap allows.
    void request()
    {
        requested = true;
    }

    /// Asks for a frame at `t`.
    void requestAt(MonoTime t)
    {
        foreach (MonoTime have; timers)
        {
            if (have == t)
            {
                return;
            }
        }
        timers ~= t;
    }

    /// How long the loop may wait for events at `now`, `Duration.max` when no frame is pending.
    Duration timeout(MonoTime now) const
    {
        Duration d = Duration.max;
        if (requested)
        {
            d = max(Duration.zero, last + minInterval - now);
        }
        foreach (MonoTime at; timers)
        {
            d = min(d, max(Duration.zero, at - now));
        }
        return d;
    }

    /// Turns timers that passed by `now` into a request, then true if a frame should start.
    bool due(MonoTime now)
    {
        size_t kept;
        foreach (MonoTime at; timers)
        {
            if (at <= now)
            {
                requested = true;
            }
            else
            {
                timers[kept++] = at;
            }
        }
        timers = timers[0 .. kept];
        return requested && now - last >= minInterval;
    }

    /// Marks the start of a frame at `t`, which settles the request.
    void started(MonoTime t)
    {
        last = t;
        requested = false;
    }
}

// The cap delays a request, a timer wakes the loop at its time, and nothing pending means no limit.
unittest
{
    FrameClock c = FrameClock(100);
    MonoTime t0 = MonoTime.currTime;
    assert(c.due(t0), "first frame at once");
    c.started(t0);
    assert(c.timeout(t0) == Duration.max);
    assert(c.due(t0 + msecs(500)) == false);

    c.request();
    assert(c.timeout(t0 + msecs(4)) == msecs(6));
    assert(c.due(t0 + msecs(4)) == false);
    assert(c.timeout(t0 + msecs(12)) == Duration.zero);
    assert(c.due(t0 + msecs(12)));
    c.started(t0 + msecs(12));

    c.requestAt(t0 + msecs(500));
    c.requestAt(t0 + msecs(500));
    c.requestAt(t0 + msecs(300));
    assert(c.timeout(t0 + msecs(100)) == msecs(200));
    assert(c.due(t0 + msecs(299)) == false);
    assert(c.due(t0 + msecs(300)));
    c.started(t0 + msecs(300));
    assert(c.timeout(t0 + msecs(300)) == msecs(200), "one timer left, the duplicate dropped");
    assert(c.due(t0 + msecs(500)));
    c.started(t0 + msecs(500));
    assert(c.timeout(t0 + msecs(500)) == Duration.max);
}

/// Call the loop makes at a set time, apart from frames, see `Host.at`.
final class Alarm
{
    MonoTime time;              /// when it runs
    private void delegate() fn; /// what runs, null once it ran or was cancelled

    /// Call of `fn` at `t`.
    this(MonoTime t, void delegate() fn)
    {
        time = t;
        this.fn = fn;
    }

    /// Drops the call if it has not run yet.
    void cancel()
    {
        fn = null;
    }

    /// True until it runs or is cancelled.
    bool pending() const
    {
        return fn !is null;
    }
}

/// Alarms waiting to run.
struct Alarms
{
    private Alarm[] list; /// unordered, cancelled ones dropped on the next `fire`

    /// Adds `a`.
    void add(Alarm a)
    {
        list ~= a;
    }

    /// How long the loop may wait at `now` until the next alarm, `Duration.max` with none.
    Duration timeout(MonoTime now) const
    {
        Duration d = Duration.max;
        foreach (const(Alarm) a; list)
        {
            if (a.pending)
            {
                d = min(d, max(Duration.zero, a.time - now));
            }
        }
        return d;
    }

    /// Runs the alarms due by `now`, earliest first. Alarms added meanwhile wait for the next call.
    void fire(MonoTime now)
    {
        if (list.length == 0)
        {
            return;
        }
        Alarm[] due;
        Alarm[] left;
        foreach (Alarm a; list)
        {
            if (a.pending == false)
            {
                continue;
            }
            if (a.time <= now)
            {
                due ~= a;
            }
            else
            {
                left ~= a;
            }
        }
        list = left;
        due.sort!((Alarm a, Alarm b) => a.time < b.time, SwapStrategy.stable)();
        foreach (Alarm a; due)
        {
            void delegate() fn = a.fn;
            if (fn !is null) // an earlier one may have cancelled it
            {
                a.fn = null;
                fn();
            }
        }
    }
}

// Alarms run once at their time, earliest first, skip when cancelled, and ones added while running wait.
unittest
{
    MonoTime t0 = MonoTime.currTime;
    Alarms s;
    assert(s.timeout(t0) == Duration.max);
    string ran;
    Alarm late = new Alarm(t0 + msecs(20), () { ran ~= "l"; });
    Alarm gone = new Alarm(t0 + msecs(15), () { ran ~= "g"; });
    s.add(late);
    s.add(gone);
    s.add(new Alarm(t0 + msecs(10), () {
        ran ~= "e";
        gone.cancel();
        s.add(new Alarm(t0, () { ran ~= "n"; }));
    }));
    assert(s.timeout(t0) == msecs(10));
    s.fire(t0 + msecs(5));
    assert(ran == "");
    s.fire(t0 + msecs(30));
    assert(ran == "el" && late.pending == false && gone.pending == false);
    assert(s.timeout(t0 + msecs(30)) == Duration.zero, "the added one waits for the next call");
    s.fire(t0 + msecs(30));
    assert(ran == "eln" && s.timeout(t0) == Duration.max);
}
