# 12. Windows

A process has one main window and may open more top-level windows beside
it. Each window has a tree of its own, with its own focus, hover, popups and
screen reader view. All windows share one `App`: the platform, fonts, theme,
signals, alarms, `beforeFrame` hooks and the loop. They all run on the UI
thread, so a signal read by nodes in two windows updates both.

## Opening one

`Host.openWindow` takes `WindowOptions` and returns the new window's
`Host`. With SDL3, `new Window(owner, o)` does the same and gives a
`Window`, for `sdlWindow`. A second window reads its title, sizes, `scale`,
`maxFps`, `hidden`, `accessibility`, `popupWindows` and `scrollDrag` from
the options. Fonts, the theme and the renderer follow the main window.

<!-- src="examples/source/guide/windows.d" from="    void show(Host main)" -->
```d
/// Opens the inspector next to `main`, or shows and raises it if open.
void show(Host main)
{
    if (window !is null)
    {
        window.visible = true;
        return;
    }
    WindowOptions o;
    o.title = "Inspector";
    o.width = 240;
    o.height = 120;
    window = main.openWindow(o);
    window.onCloseRequest = () {
        forget();
        return true;
    };
    bindings = effectScope(() {
        window.setRoot(pad(all: 12)(column(gap: 8, cross: CrossAlign.start)(
            label(() => format("Count is %d", count.get)),
            button("Reset", onClick: () { count.set(0); }),
        )));
    });
}
```

The window's nodes get an `effectScope` of their own, disposed when the
window goes, so the bindings to the shared count end with it.

## Closing

The user closing a second window runs its `onCloseRequest`, which may keep
it open by returning false, then closes it. `close()` closes it from code.
Either way the `Host` is done: `isClosed` turns true, and events still on
their way for it are dropped. dentrite does not remember where a window was,
apps that want that save the size themselves.

Closing the main window ends `run`, and `close()` on it closes every other
window too. An app that wants to ask about unsaved work in other windows
does it from the main window's `onCloseRequest`.

## Frames

A window draws only when its tree asks for a frame and it is shown. One
frame runs the alarms and hooks once, then lays out and composes each window
that asks, then renders each. `h.frame()` draws window `h` and every other
that wants a frame.

`stats` and `screenshotPath` are per window. App-wide calls, such as
`setTheme`, `setFont`, `reloadTheme`, `at`, `after`, `run` and
`beforeFrame`, work from any window's `Host` and act on the app, also
reachable as `h.app`.

## Displays

Each window draws at its own display's scale. Windows on displays with
different scales get a text system each, so text is sharp in both.

## Testing

`HeadlessPlatform` opens windows as `HeadlessWindow`, drawing in software.
Tests drive a second window through its `Host` as they do the main one:

<!-- src="examples/source/guide/windows.d" from="/// Both windows show the shared count" -->
```d
/// Both windows show the shared count, either one changes it, and closing the inspector leaves the main window.
unittest
{
    import dentrite.platform : Event, EventKind;
    import guide.harness;

    Host h = testHost();
    scope (exit)
    {
        h.close();
    }
    Inspector ins = new Inspector;
    scope Scope root = effectScope(() { h.setRoot(counterWithInspector(h, ins)); });
    h.frame();
    h.click(Role.button, "Inspector");
    assert(h.app.windows.length == 2 && shows(ins.window, Role.label, "Count is 0"));
    h.click(Role.button, "Add one");
    assert(shows(ins.window, Role.label, "Count is 1"), "the inspector redraws with the main window");
    ins.window.click(Role.button, "Reset");
    assert(shows(h, Role.label, "Count: 0"));

    Host inspector = ins.window;
    Event close = Event(EventKind.close);
    inspector.handle(close);
    assert(ins.window is null && inspector.isClosed && h.app.windows == [h]);
}
```
