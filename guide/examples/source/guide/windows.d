/// Chapter 12: a second window sharing the main window's state.
module guide.windows;

import dentrite.containers;
import dentrite.host : Host;
import dentrite.node;
import dentrite.platform : WindowOptions;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.label;
import std.format : format;

/// A count shown in the main window and in an inspector window opened beside it.
final class Inspector
{
    Signal!int count;       /// shared by both windows
    Host window;            /// inspector window while open, else null
    private Scope bindings; /// bindings of the inspector's nodes

    /// Count starting at 0, no inspector open.
    this()
    {
        count = signal(0);
    }

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

    /// Drops the inspector's bindings and the window, which closes after.
    private void forget()
    {
        bindings.dispose();
        window = null;
    }
}

/// Main window of `h`: the count, a button adding one and one opening the inspector.
Node counterWithInspector(Host h, Inspector ins)
{
    return pad(all: 16)(column(gap: 8, cross: CrossAlign.start)(
        label(() => format("Count: %d", ins.count.get)),
        row(gap: 8)(
            button("Add one", onClick: () { ins.count.set(ins.count.peek + 1); }),
            button("Inspector", onClick: () { ins.show(h); }),
        ),
    ));
}

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
