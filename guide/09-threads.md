# 9. Threads

Signals and nodes belong to the UI thread. Other threads never touch them.
They post into a box from `dentrite.mailbox`, and the UI thread drains the
boxes at the start of each frame and sets signals there.

- `Mailbox!(K, V)` keeps the latest value per key. Values that only matter
  as "latest", such as progress or a register, coalesce: a thousand posts
  between two frames become one update.
- `Queue!T` keeps every entry in order, for log lines and events.

Both wake the UI loop when they go from empty to not empty, so it draws a
frame. Pass a function of your own to the constructor to do something
else:

<!-- src="examples/source/guide/threads.d" from="final class Inbox" -->
```d
/// Worker side: boxes the worker posts into. Nothing here is a signal, since signals belong to the UI thread.
final class Inbox
{
    Mailbox!(string, double) progress; /// latest fraction done per file, coalesced
    Queue!string log;                  /// every line, in order

    /// Boxes that wake the UI loop when they get their first entry.
    this()
    {
        progress = new Mailbox!(string, double);
        log = new Queue!string;
    }
}
```

The UI side drains in one batch, so views see every change of the frame at
once:

<!-- src="examples/source/guide/threads.d" from="    void drain(Inbox box)" -->
```d
/// Applies what the worker posted since the last frame, in one batch.
void drain(Inbox box)
{
    double[string] done = box.progress.drain();
    string[] lines = box.log.drain();
    batch(() {
        foreach (string f, double d; done)
        {
            progress[f].set(d);
        }
        if (lines.length > 0)
        {
            log.set(log.peek ~ lines);
        }
    });
}
```

`Host.beforeFrame` runs delegates at the start of each frame. Changes made
there show in the same frame:

<!-- src="examples/source/guide/threads.d" from="void startDownloads(" -->
```d
/// Starts the worker and drains its boxes before every frame of `h`.
void startDownloads(Host h, Downloads d, immutable string[] files)
{
    Inbox box = new Inbox;
    h.beforeFrame ~= () { d.drain(box); };
    Thread t = new Thread(() { fetch(box, files, 20); });
    t.isDaemon = true;
    t.start();
}
```

The worker only posts:

<!-- src="examples/source/guide/threads.d" from="void fetch(" -->
```d
/// Worker: fetches `files` in `steps` steps each, posting as it goes.
void fetch(Inbox box, immutable string[] files, int steps)
{
    foreach (string f; files)
    {
        box.log.post("Fetching " ~ f);
        foreach (int i; 1 .. steps + 1)
        {
            Thread.sleep(1.msecs);
            box.progress.post(f, cast(double) i / steps);
        }
        box.log.post("Done " ~ f);
    }
}
```

Data crossing threads should be immutable or copied, such as
`immutable(ubyte)[]` for a memory snapshot. The boxes lock around every
access, but do not make what you post safe to share.

Frames, and so `beforeFrame`, pause while the window is hidden or minimized.
Boxes keep filling and drain once it shows again. For work due at a set time
even then, `Host.after(d, fn)` and `Host.at(t, fn)` call `fn` on the UI
thread, and the returned `Alarm` cancels it.
