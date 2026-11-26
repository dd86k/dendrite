/// System tray icon with a menu built from menu items.
///
/// Most trays open their menu on any click and report no click on the icon itself, so give the menu an entry
/// that shows the window.
module dentrite.tray;

import dentrite.host : Host;
import dentrite.image : Image;
import dentrite.node : Node;
import dentrite.platform : TrayEntry, TrayIcon, Trays;
import dentrite.widgets.menu : MenuItem, MenuSeparator, mnemonic;

/// Tray icon of a host, from `tray`. Entries follow their command's label, enabled and checked states through
/// `Host.beforeFrame`, which also runs while the window is hidden.
final class Tray
{
    private Host host;          /// host syncing it each frame
    private TrayIcon shown;     /// platform icon, null once closed
    private MenuItem[] items;   /// entries depth first, null for separators
    private TrayEntry[] sent;   /// last states given to the platform, depth first

    /// Tray of `host` showing `shown`, for `items` depth first and their entries `sent`.
    private this(Host host, TrayIcon shown, MenuItem[] items, TrayEntry[] sent)
    {
        this.host = host;
        this.shown = shown;
        this.items = items;
        this.sent = sent;
        host.beforeFrame ~= &sync;
    }

    /// True until closed.
    bool isOpen()
    {
        return shown !is null;
    }

    /// Replaces the icon, null for none.
    void icon(Image img)
    {
        if (shown !is null)
        {
            shown.setIcon(img);
        }
    }

    /// Replaces the tooltip.
    void tooltip(string tip)
    {
        if (shown !is null)
        {
            shown.setTooltip(tip);
        }
    }

    /// Removes the icon. Safe to call twice.
    void close()
    {
        if (shown is null)
        {
            return;
        }
        shown.close();
        shown = null;
        foreach (size_t i, void delegate() hook; host.beforeFrame)
        {
            if (hook == &sync)
            {
                host.beforeFrame = host.beforeFrame[0 .. i] ~ host.beforeFrame[i + 1 .. $];
                break;
            }
        }
    }

    /// Sends the entries whose command changed since last sent.
    private void sync()
    {
        foreach (size_t i; 0 .. items.length)
        {
            send(i, false);
        }
    }

    /// Sends entry `i` if its command changed since last sent, or `always`. Skips separators and submenus.
    private void send(size_t i, bool always)
    {
        MenuItem it = items[i];
        if (shown is null || it is null || it.command is null)
        {
            return;
        }
        TrayEntry e = sent[i];
        e.label = mnemonic(it.command.label).text;
        e.enabled = it.command.isEnabled;
        e.checked = it.command.isChecked;
        if (always || e.label != sent[i].label || e.enabled != sent[i].enabled || e.checked != sent[i].checked)
        {
            sent[i] = e;
            shown.setEntry(i, e);
        }
    }

    /// Runs the command of entry `index`, then sends its states, since some trays flip a check mark on a press.
    private void pressed(size_t index)
    {
        MenuItem it = index < items.length ? items[index] : null;
        if (it !is null && it.command !is null)
        {
            it.command.run();
            send(index, true);
        }
    }
}

/// Tray icon options, waiting for the menu items.
struct TraySpec
{
    Host host;      /// host showing it
    Image icon;     /// icon, null for none
    string tooltip; /// text shown on hover

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Host host, Image icon, string tooltip)
    {
        this.host = host;
        this.icon = icon;
        this.tooltip = tooltip;
    }

    /// Shows the icon with a menu of `items`: menu items, submenus and separators, other nodes are skipped.
    /// Null when the platform or the system has no tray.
    Tray opCall(Node[] items...)
    {
        Trays t = cast(Trays) host.platform;
        if (t is null)
        {
            return null;
        }
        MenuItem[] flat;
        TrayEntry[] sent;
        TrayEntry[] menu = entries(items, flat, sent);
        Tray tray;
        TrayIcon shown = t.openTray(icon, tooltip, menu, (size_t i) { tray.pressed(i); });
        if (shown is null)
        {
            return null;
        }
        tray = new Tray(host, shown, flat, sent);
        return tray;
    }
}

/// Tray icon on `host`: `h.tray(icon: img, tooltip: "App")(menuItem(show), menuSeparator(), menuItem(quit))`.
TraySpec tray(Host host, Image icon = null, string tooltip = null)
{
    return TraySpec(host, icon, tooltip);
}

/// Entries for menu `items`, appending each entry's item to `flat` and the entry to `sent`, depth first.
private TrayEntry[] entries(Node[] items, ref MenuItem[] flat, ref TrayEntry[] sent)
{
    TrayEntry[] list;
    foreach (Node n; items)
    {
        TrayEntry e;
        MenuItem it = cast(MenuItem) n;
        if (it is null && cast(MenuSeparator) n is null)
        {
            continue;
        }
        size_t at = sent.length;
        flat ~= it;
        sent ~= e;
        if (it !is null && it.sub !is null)
        {
            e.label = it.text;
            e.submenu = true;
            e.sub = entries(it.sub.list.children, flat, sent);
        }
        else if (it !is null)
        {
            e.label = mnemonic(it.command.label).text;
            e.enabled = it.command.isEnabled;
            e.checkable = it.command.checked !is null;
            e.checked = it.command.isChecked;
        }
        sent[at] = e;
        list ~= e;
    }
    return list;
}

// Builds the menu depth first, follows command states each frame, runs presses and closes.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.command : Command, command;
    import dentrite.headless : HeadlessPlatform, HeadlessTray;
    import dentrite.platform : WindowOptions;
    import dentrite.widgets.menu : menu, menuItem, menuSeparator;

    HeadlessPlatform p = new HeadlessPlatform(200, 100);
    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    bool on;
    int quits;
    Command toggle = command("&Show", () { on = !on; }, checked: () => on);
    Tray t = h.tray(tooltip: "App")(menuItem(toggle), menu("&More")(menuItem("A&&B", () {})), menuSeparator(),
        menuItem("&Quit", () { ++quits; }));
    assert(t !is null && p.trays.length == 1);
    HeadlessTray shown = p.trays[0];
    assert(shown.tooltip == "App");
    assert(shown.menu.length == 4 && shown.menu[1].submenu && shown.menu[1].sub[0].label == "A&B");
    assert(shown.entries.length == 5 && shown.entries[0].label == "Show" && shown.entries[0].checkable);
    assert(shown.entries[3].label is null && shown.entries[4].label == "Quit");

    shown.press(0);
    shown.press(4);
    h.pump();
    assert(on && quits == 1);
    toggle.label = "&Hide";
    h.frame();
    assert(shown.entries[0].checked && shown.entries[0].label == "Hide");

    // A press re-sends the entry, undoing a check mark the tray flipped itself.
    toggle.action = () {};
    shown.entries[0].checked = false;
    shown.press(0);
    h.pump();
    assert(shown.entries[0].checked);

    t.close();
    t.close();
    assert(shown.closed && t.isOpen == false);
    size_t hooks = h.beforeFrame.length;
    h.frame();
    assert(h.beforeFrame.length == hooks);
}

// Null without a tray.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.platform : WindowOptions;
    import dentrite.widgets.menu : menuItem;

    HeadlessPlatform p = new HeadlessPlatform(200, 100);
    p.trayless = true;
    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    assert(h.tray()(menuItem("&Quit", () {})) is null);
}
