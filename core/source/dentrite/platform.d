/// What the host needs from a window system and a renderer, and the events a platform delivers.
///
/// A platform owns the window, its events, the clipboard, the cursor and presenting. A renderer draws a
/// `FrameMesh` into what the platform presents. Platforms translate their input to `Event`, with positions
/// in physical pixels and key codes as in `Key`.
module dentrite.platform;

import core.atomic : atomicLoad, atomicStore;
import core.time : Duration, MonoTime;
import dentrite.access : AccessRequest;
import dentrite.draw : FrameMesh;
import dentrite.geom;
import dentrite.image : Image;
import dentrite.node : CursorShape, PointerKind, PointerSource, ScrollDrag;
import dentrite.text : FontKind, GlyphAtlas;
import dentrite.theme : Theme;

/// Renderers a platform can set up.
enum RendererKind
{
    gl33,     /// OpenGL 3.3 core
    software, /// CPU rasterizer
}

/// Window settings, read by the platform and the host.
struct WindowOptions
{
    string title = "dentrite";   /// window title
    int width = 1280;            /// window width in logical pixels
    int height = 800;            /// window height in logical pixels
    int minWidth;                /// smallest width the user can resize to, in logical pixels, 0 for no limit
    int minHeight;               /// smallest height the user can resize to, in logical pixels, 0 for no limit
    float scale = 0;             /// display scale to use, 0 to take the display's own
    bool vsync = true;           /// wait for vertical blank
    double maxFps = 120;         /// frame rate cap, for when vsync does not limit it
    RendererKind renderer;       /// renderer drawing the frames
    string[FontKind.max + 1] fonts; /// font file for each `FontKind` slot
    string[] fallbackFonts;      /// files for characters the slot fonts lack, tried in order
    bool systemFallbacks = true; /// after `fallbackFonts`, try well-known system fonts, see `systemFallbackFonts`
    string themePath;            /// theme file, reloadable with Ctrl+R
    /// Validates every style the app reads, throws on errors. By default checks `LibraryStyles` only, so app
    /// sections fail it.
    void delegate(Theme) checkTheme;
    bool hidden;                 /// do not show, for screenshots
    bool cachePaint = true;      /// reuse unchanged layers, false repaints everything every frame for comparisons
    /// Exposes the UI to screen readers, see `dentrite.access`. The SDL3 platform loads AccessKit for it at run
    /// time and goes on without it if missing.
    bool accessibility;
    /// Shows a popup that would not fit in the window in an OS window of its own, when the platform can. Hidden
    /// windows keep popups inside.
    bool popupWindows = true;
    /// Pointers that scroll a view by dragging its content, for views left at `ScrollDrag.inherit`. Set `always`
    /// for a pointer that cannot tell the platform it is not a mouse, such as a VR overlay. See `Host.scrollDrag`
    /// to change it later.
    ScrollDrag scrollDrag = ScrollDrag.touch;
}

/// Framebuffer size and display density, from `Platform.metrics`.
struct Metrics
{
    int pixelW;      /// framebuffer width in physical pixels
    int pixelH;      /// framebuffer height in physical pixels
    float scale = 1; /// display scale, physical pixels per logical pixel
}

/// What happened, for `Event`.
enum EventKind
{
    none,        /// nothing the host needs
    close,       /// the user asked to close the window, see `Host.onCloseRequest`
    quit,        /// the system asked the app to quit, such as on a signal or logout
    resized,     /// size or scale changed, `Platform.metrics` has the new values
    exposed,     /// contents lost, draw again
    pointerLeft, /// pointer left the window
    focusLost,   /// window lost keyboard focus
    pointer,     /// pointer moved or a button changed
    wheel,       /// wheel turned
    key,         /// key pressed
    text,        /// text typed
    compose,     /// text an input method has not committed yet, empty when it ends
    wake,        /// `wakeUi` from another thread
    call,        /// run `call` on the UI thread, such as a file dialog's handler
    access,      /// an assistive technology asks for `request`
    dismissed,   /// the system closed popup window `surface`, such as on a press outside the app
    hidden,      /// window hidden or minimized, `Host.run` draws no frames until it shows
    shown,       /// window shown or restored
}

/// Input or window event from a platform. A field doc starting with an event kind, such as `pointer:`, says which
/// kinds set it.
struct Event
{
    EventKind kind;      /// kind of event
    uint surface;        /// popup window the event came from, see `PopupWindow.id`, 0 for the main window
    PointerKind pointer; /// `pointer`: move, down or up
    Point pos;           /// `pointer` and `wheel`: position in physical pixels within `surface`
    ubyte button;        /// `pointer`: 1 left, 2 middle, 3 right
    ubyte clicks;        /// `pointer`: 2 for a double click
    ubyte mods;          /// `Mod` flags, combined with `|`
    PointerSource source; /// `pointer`: device it came from
    MonoTime time;       /// `pointer`: when it happened, `MonoTime.init` for when it is handled
    float dx = 0;        /// `wheel`: notches, positive moves content left
    float dy = 0;        /// `wheel`: notches, positive moves content up
    uint key;            /// `key`: Key value or another key code
    bool repeat;         /// `key`: auto-repeat
    string text;         /// `text` and `compose`: UTF-8
    int start = -1;      /// `compose`: first code point the input method is converting, or the caret, -1 if unset
    int length = -1;     /// `compose`: code points it is converting, -1 or 0 for none
    void delegate() call; /// `call`: work for the UI thread
    AccessRequest request; /// `access`: what to do
}

/// What a file dialog asks for.
enum FileDialogKind
{
    open,     /// one existing file
    openMany, /// one or more existing files
    save,     /// a file name to write, existing or not
    folder,   /// one folder
}

/// File type offered by a file dialog: `FileFilter("Images", "png;jpg")`. `*` matches every file.
struct FileFilter
{
    string name;    /// filter name shown to the user
    string pattern; /// extensions without dots, separated by `;`
}

/// Platform with native file dialogs.
interface FileDialogs
{
    /// Shows a dialog of `kind` over the window, starting in `start` if not null. `done` gets the chosen paths
    /// later on the UI thread, through an event of kind `call`, and none if cancelled or failed.
    void fileDialog(FileDialogKind kind, const(FileFilter)[] filters, string start, void delegate(string[]) done);
}

/// Platform whose window the app can change once open. Sizes are in logical pixels.
interface WindowControl
{
    void setTitle(string title);       /// sets the title bar text
    void setVisible(bool on);          /// shows, unminimizes and raises the window, or hides it
    bool visible();                    /// true unless hidden
    void setMinimumSize(int w, int h); /// smallest size the user can resize to, 0 for no limit
    void setIcon(Image[] icons);       /// sets the icon the window system shows, one image per size
}

/// Entry of a tray icon's menu.
struct TrayEntry
{
    string label;        /// plain text, no mnemonic marker, null for a separator
    bool enabled = true; /// accepts presses
    bool checkable;      /// has a check mark, fixed once shown
    bool checked;        /// check mark on
    bool submenu;        /// opens `sub`, fixed once shown
    TrayEntry[] sub;     /// submenu entries
}

/// Tray icon shown by a platform, from `Trays.openTray`. Entries are numbered depth first: an entry, its
/// submenu's entries, then the next entry.
interface TrayIcon
{
    void setIcon(Image icon);    /// replaces the icon
    void setTooltip(string tip); /// replaces the tooltip
    /// Updates the label, enabled and checked states of entry `index`. Not for separators.
    void setEntry(size_t index, ref const TrayEntry e);
    void close();                /// removes the icon, safe to call twice
}

/// Platform with system tray icons.
interface Trays
{
    /// Shows a tray icon with `menu`, or null when the system has no tray. A press on entry `i` comes back from
    /// `wait` as a `call` event running `pressed(i)`. `icon` may be null.
    TrayIcon openTray(Image icon, string tooltip, const(TrayEntry)[] menu, void delegate(size_t) pressed);
}

/// OS window showing one popup, from `PopupWindows.openPopup`. Rectangles are in physical pixels from the main
/// window's top left.
interface PopupWindow
{
    uint id();                                   /// `Event.surface` of the events from this window, not 0
    void move(Rect r);                           /// moves and resizes the window to `r`
    void draw(FrameMesh mesh, GlyphAtlas atlas); /// clears to transparent, draws `mesh` and presents
    void close();                                /// destroys the window, safe to call twice
}

/// Platform that can show popups in OS windows of their own, so they reach past the main window.
interface PopupWindows
{
    /// Room popups may take, such as the display's work area, in physical pixels from the main window's top
    /// left. Empty for none.
    Rect popupArea();
    /// Opens a window at `r` above `parent`, or above the main window if null. `input` false lets the pointer
    /// through and leaves keyboard focus alone, as for a tooltip. Null if it failed.
    PopupWindow openPopup(PopupWindow parent, Rect r, bool input);
}

/// Window system side of a host: window, events, clipboard, cursor, presenting.
interface Platform
{
    Metrics metrics();                        /// framebuffer size and display scale
    bool wait(ref Event e, Duration timeout); /// next event within `timeout`, no limit for `Duration.max`
    void present();                           /// shows what the renderer drew
    void setCursor(CursorShape shape);        /// pointer shape over the window
    /// Starts or stops text events, which drops any composition. `hidden` for a password, input methods off.
    void textInput(bool on, bool hidden);
    void textInputArea(Rect caret);           /// caret in physical pixels, where an input method shows candidates
    string clipboard();                       /// clipboard text, or null
    void setClipboard(string s);              /// sets the clipboard
    void close();                             /// closes the window and frees what the platform holds
}

/// Draws frames for a platform.
interface Renderer
{
    void render(FrameMesh mesh, GlyphAtlas atlas, Color clear); /// clears to premultiplied `clear`, draws `mesh`
    ubyte[] readPixels();  /// last frame as RGBA8 rows, top row first
    string description();  /// renderer and driver, for logs
    void dispose();        /// frees what the renderer holds, before the platform closes
}

/// Wakes the UI loop from any thread. Does nothing while no platform is open.
void wakeUi() nothrow
{
    void function() nothrow w = atomicLoad(waker);
    if (w !is null)
    {
        w();
    }
}

/// Sets what `wakeUi` calls, null when the platform closes.
void setWaker(void function() nothrow w) nothrow
{
    atomicStore(waker, w);
}

/// Platform wake function, called by `wakeUi` from any thread.
private shared void function() nothrow waker;
