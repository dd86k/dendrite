/// Platform without a window, for tests and offscreen frames. Pair it with the software renderer.
module dentrite.headless;

import core.sync.semaphore : Semaphore;
import core.time : Duration;
import dentrite.access : AccessAdapter, AccessDemand, AccessUpdate;
import dentrite.draw : FrameMesh;
import dentrite.geom : Rect;
import dentrite.image : Image;
import dentrite.node : CursorShape;
import dentrite.platform;
import dentrite.text : GlyphAtlas;

/// Fixed size framebuffer with events queued by the app.
final class HeadlessPlatform : Platform, FileDialogs, AccessAdapter, WindowControl, Trays, PopupWindows, Appearance
{
    Metrics size;        /// framebuffer size and scale
    Event[] queue;       /// events `wait` hands out, oldest first
    string[][] fileAnswers; /// paths the next file dialogs return, oldest first, none once used up
    FileDialogKind[] fileAsks; /// kinds of the file dialogs shown
    string clip;         /// clipboard contents
    CursorShape cursor;  /// last cursor set
    bool textOn;         /// true while text input is on
    bool textHidden;     /// true while text input is on for a password
    Rect inputArea;      /// last caret for an input method
    int presented;       /// frames presented
    AccessDemand listening; /// what `demand` answers, `full` turns into `changes` once read
    AccessUpdate[] accessUpdates; /// updates sent while listening, oldest first
    string title;        /// last title set
    bool hidden;         /// true while hidden
    int[2] minSize;      /// last minimum size, width then height
    Image[] icon;        /// last icon set, one image per size
    HeadlessTray[] trays; /// tray icons opened, closed ones included
    bool trayless;       /// true to answer `openTray` with null, as without a system tray
    Rect screen;         /// what `popupArea` answers, empty for no popup windows
    HeadlessPopup[] popups; /// popup windows opened, closed ones included
    ColorScheme scheme;  /// what `colorScheme` answers

    /// Platform `w` by `h` logical pixels at `scale`.
    this(int w, int h, float scale = 1)
    {
        size = Metrics(cast(int)(w * scale), cast(int)(h * scale), scale);
        wakes = new Semaphore;
        setWaker(&wakeHeadless);
    }

    /// Framebuffer size and scale.
    Metrics metrics()
    {
        return size;
    }

    /// Next queued event, or a wake from `wakeUi`, waiting up to `timeout`.
    bool wait(ref Event e, Duration timeout)
    {
        if (queue.length > 0)
        {
            e = queue[0];
            queue = queue[1 .. $];
            return true;
        }
        if (timeout == Duration.max)
        {
            wakes.wait();
        }
        else if (wakes.wait(timeout) == false)
        {
            return false;
        }
        e = Event(EventKind.wake);
        return true;
    }

    /// Queues the next of `fileAnswers` for `done`, as a `call` event.
    void fileDialog(FileDialogKind kind, const(FileFilter)[] filters, string start, void delegate(string[]) done)
    {
        string[] paths;
        if (fileAnswers.length > 0)
        {
            paths = fileAnswers[0];
            fileAnswers = fileAnswers[1 .. $];
        }
        fileAsks ~= kind;
        Event e = { kind: EventKind.call, call: () { done(paths); } };
        queue ~= e;
    }

    /// `listening`, which drops from `full` to `changes` once read.
    AccessDemand demand()
    {
        AccessDemand d = listening;
        if (d == AccessDemand.full)
        {
            listening = AccessDemand.changes;
        }
        return d;
    }

    /// Records `u`.
    void update(ref const AccessUpdate u, float scale)
    {
        accessUpdates ~= cast(AccessUpdate) u;
    }

    /// Records the title.
    void setTitle(string t)
    {
        title = t;
    }

    /// Records whether the window is shown.
    void setVisible(bool on)
    {
        hidden = on == false;
    }

    /// False while hidden.
    bool visible()
    {
        return hidden == false;
    }

    /// Records the minimum size.
    void setMinimumSize(int w, int h)
    {
        minSize = [w, h];
    }

    /// Records the icon.
    void setIcon(Image[] icons)
    {
        icon = icons;
    }

    /// Records a tray icon, null when `trayless`.
    TrayIcon openTray(Image icon, string tooltip, const(TrayEntry)[] menu, void delegate(size_t) pressed)
    {
        if (trayless)
        {
            return null;
        }
        HeadlessTray t = new HeadlessTray;
        t.platform = this;
        t.icon = icon;
        t.tooltip = tooltip;
        t.menu = (cast(TrayEntry[]) menu).dup;
        t.pressed = pressed;
        flatten(t.menu, t.entries);
        trays ~= t;
        return t;
    }

    /// `screen`.
    Rect popupArea()
    {
        return screen;
    }

    /// Records a popup window.
    PopupWindow openPopup(PopupWindow parent, Rect r, bool input)
    {
        HeadlessPopup w = new HeadlessPopup;
        w.number = cast(uint) popups.length + 1;
        w.parent = cast(HeadlessPopup) parent;
        w.at = r;
        w.input = input;
        popups ~= w;
        return w;
    }

    /// Counts the frame.
    void present()
    {
        ++presented;
    }

    /// Records the cursor.
    void setCursor(CursorShape shape)
    {
        cursor = shape;
    }

    /// Records whether text input is on, and for a password.
    void textInput(bool on, bool hidden)
    {
        textOn = on;
        textHidden = on && hidden;
    }

    /// System appearance set in `scheme`.
    ColorScheme colorScheme()
    {
        return scheme;
    }

    /// Records the input method caret.
    void textInputArea(Rect caret)
    {
        inputArea = caret;
    }

    /// Clipboard contents.
    string clipboard()
    {
        return clip;
    }

    /// Sets the clipboard contents.
    void setClipboard(string s)
    {
        clip = s;
    }

    /// Stops `wakeUi` from reaching this platform.
    void close()
    {
        setWaker(null);
    }
}

/// Tray icon recorded by `HeadlessPlatform`.
final class HeadlessTray : TrayIcon
{
    Image icon;          /// last icon set
    string tooltip;      /// last tooltip set
    TrayEntry[] menu;    /// menu as opened
    TrayEntry[] entries; /// entries depth first, with their updates, submenus flattened
    bool closed;         /// true once closed

    private HeadlessPlatform platform;        /// platform queueing presses
    private void delegate(size_t) pressed; /// press handler

    /// Queues a press on entry `index`, as a `call` event.
    void press(size_t index)
    {
        void delegate(size_t) p = pressed;
        Event e = { kind: EventKind.call, call: () { p(index); } };
        platform.queue ~= e;
    }

    /// Records the icon.
    void setIcon(Image img)
    {
        icon = img;
    }

    /// Records the tooltip.
    void setTooltip(string tip)
    {
        tooltip = tip;
    }

    /// Records the states of entry `index`.
    void setEntry(size_t index, ref const TrayEntry e)
    {
        entries[index].label = e.label;
        entries[index].enabled = e.enabled;
        entries[index].checked = e.checked;
    }

    /// Marks it closed.
    void close()
    {
        closed = true;
    }
}

/// Popup window recorded by `HeadlessPlatform`.
final class HeadlessPopup : PopupWindow
{
    HeadlessPopup parent; /// window it opened above, null for the main window
    Rect at;              /// last rectangle, in physical pixels from the main window's top left
    bool input;           /// takes pointer input
    int drawn;            /// frames drawn
    size_t batches;       /// draw batches of the last frame
    bool closed;          /// true once closed

    private uint number;  /// `id`

    /// Number in `Event.surface`, counting from 1.
    uint id()
    {
        return number;
    }

    /// Records the rectangle.
    void move(Rect r)
    {
        at = r;
    }

    /// Counts the frame.
    void draw(FrameMesh mesh, GlyphAtlas atlas)
    {
        ++drawn;
        batches = mesh.batches.length;
    }

    /// Marks it closed.
    void close()
    {
        closed = true;
    }
}

/// Appends `menu` to `flat` depth first.
private void flatten(TrayEntry[] menu, ref TrayEntry[] flat)
{
    foreach (ref TrayEntry e; menu)
    {
        flat ~= e;
        flatten(e.sub, flat);
    }
}

/// Signalled by `wakeUi` while a headless platform is open.
private __gshared Semaphore wakes;

/// Releases a waiting `HeadlessPlatform.wait`. A failed post means the count is at its limit, so a wake is
/// pending anyway.
private void wakeHeadless() nothrow
{
    try
    {
        wakes.notify();
    }
    catch (Exception e)
    {
        return;
    }
}
