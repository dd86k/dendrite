/// SDL3 subset used by dentrite. Checked against SDL 3.2.10 headers.
module dentrite.c.sdl;

extern (C) nothrow @nogc:

/// Opaque window.
struct SDL_Window;
/// Opaque GL context state.
struct SDL_GLContextState;
/// Opaque cursor.
struct SDL_Cursor;
/// GL context handle.
alias SDL_GLContext = SDL_GLContextState*;
/// Function pointer returned by `SDL_GL_GetProcAddress`.
alias SDL_FunctionPointer = void function();
/// Property group handle, 0 for none.
alias SDL_PropertiesID = uint;

/// Pixel buffer. Fields are read-only, `pixels` is writable.
struct SDL_Surface
{
    uint flags;     /// SDL_SurfaceFlags
    uint format;    /// SDL_PixelFormat
    int w;          /// width
    int h;          /// height
    int pitch;      /// bytes per row
    void* pixels;   /// rows
    int refcount;   /// application references
    void* reserved; /// internal
}

/// Integer rectangle.
struct SDL_Rect
{
    int x; /// left
    int y; /// top
    int w; /// width
    int h; /// height
}

enum uint SDL_PIXELFORMAT_ABGR8888 = 0x16762004; /// bytes R, G, B, A in memory on little-endian

enum uint SDL_INIT_VIDEO = 0x20; /// video and events

enum ulong SDL_WINDOW_OPENGL = 0x2;                /// usable with a GL context
enum ulong SDL_WINDOW_HIDDEN = 0x8;                /// not shown until `SDL_ShowWindow`
enum ulong SDL_WINDOW_RESIZABLE = 0x20;            /// user resizable
enum ulong SDL_WINDOW_MINIMIZED = 0x40;            /// minimized
enum ulong SDL_WINDOW_HIGH_PIXEL_DENSITY = 0x2000; /// full resolution back buffer on HiDPI
enum ulong SDL_WINDOW_TOOLTIP = 0x40000;           /// popup without input, needs a parent
enum ulong SDL_WINDOW_POPUP_MENU = 0x80000;        /// popup taking keyboard focus while topmost, needs a parent
enum ulong SDL_WINDOW_TRANSPARENT = 0x40000000;    /// framebuffer alpha shows what is below

/// GL context attributes, in header order.
enum SDL_GLAttr : int
{
    redSize, greenSize, blueSize, alphaSize, bufferSize, doubleBuffer, depthSize, stencilSize,
    accumRedSize, accumGreenSize, accumBlueSize, accumAlphaSize, stereo, multisampleBuffers,
    multisampleSamples, acceleratedVisual, retainedBacking, contextMajorVersion, contextMinorVersion,
    contextFlags, contextProfileMask, shareWithCurrentContext, framebufferSrgbCapable,
}

enum int SDL_GL_CONTEXT_PROFILE_CORE = 1; /// core profile mask

/// Event types used here.
enum SDL_EventType : uint
{
    quit = 0x100,
    systemThemeChanged = 0x108,
    windowShown = 0x202,
    windowHidden = 0x203,
    windowExposed = 0x204,
    windowMoved = 0x205,
    windowResized = 0x206,
    windowPixelSizeChanged = 0x207,
    windowMinimized = 0x209,
    windowMaximized = 0x20A,
    windowRestored = 0x20B,
    windowMouseLeave = 0x20D,
    windowFocusGained = 0x20E,
    windowFocusLost = 0x20F,
    windowCloseRequested = 0x210,
    windowDisplayScaleChanged = 0x214,
    keyDown = 0x300,
    keyUp = 0x301,
    textEditing = 0x302,
    textInput = 0x303,
    mouseMotion = 0x400,
    mouseButtonDown = 0x401,
    mouseButtonUp = 0x402,
    mouseWheel = 0x403,
    dropFile = 0x1000,
    dropText = 0x1001,
    dropBegin = 0x1002,
    dropComplete = 0x1003,
    dropPosition = 0x1004,
    user = 0x8000,
}

/// Fields shared by every event.
struct SDL_CommonEvent
{
    uint type;      /// SDL_EventType
    uint reserved;  /// unused
    ulong timestamp; /// nanoseconds
}

/// Window state change.
struct SDL_WindowEvent
{
    uint type;       /// SDL_EventType
    uint reserved;   /// unused
    ulong timestamp; /// nanoseconds
    uint windowID;   /// window
    int data1;       /// event dependent
    int data2;       /// event dependent
}

/// Key press or release.
struct SDL_KeyboardEvent
{
    uint type;       /// SDL_EventType
    uint reserved;   /// unused
    ulong timestamp; /// nanoseconds
    uint windowID;   /// window with focus
    uint which;      /// keyboard
    int scancode;    /// physical key
    uint key;        /// virtual key, SDLK_*
    ushort mod;      /// SDL_KMOD_* bits
    ushort raw;      /// platform scancode
    bool down;       /// pressed
    bool repeat;     /// auto-repeat
}

/// Committed text.
struct SDL_TextInputEvent
{
    uint type;         /// SDL_EventType
    uint reserved;     /// unused
    ulong timestamp;   /// nanoseconds
    uint windowID;     /// window with focus
    const(char)* text; /// UTF-8, owned by SDL
}

/// Text an input method is composing.
struct SDL_TextEditingEvent
{
    uint type;         /// SDL_EventType
    uint reserved;     /// unused
    ulong timestamp;   /// nanoseconds
    uint windowID;     /// window with focus
    const(char)* text; /// UTF-8, owned by SDL
    int start;         /// first selected code point, or the cursor, -1 if unset
    int length;        /// selected code points, -1 if unset
}

/// Pointer motion.
struct SDL_MouseMotionEvent
{
    uint type;       /// SDL_EventType
    uint reserved;   /// unused
    ulong timestamp; /// nanoseconds
    uint windowID;   /// window
    uint which;      /// mouse
    uint state;      /// button bits
    float x;         /// window coordinates
    float y;         /// window coordinates
    float xrel;      /// relative motion
    float yrel;      /// relative motion
}

/// Pointer button press or release.
struct SDL_MouseButtonEvent
{
    uint type;       /// SDL_EventType
    uint reserved;   /// unused
    ulong timestamp; /// nanoseconds
    uint windowID;   /// window
    uint which;      /// mouse
    ubyte button;    /// 1 left, 2 middle, 3 right
    bool down;       /// pressed
    ubyte clicks;    /// 2 for a double click
    ubyte padding;   /// unused
    float x;         /// window coordinates
    float y;         /// window coordinates
}

/// Wheel motion.
struct SDL_MouseWheelEvent
{
    uint type;       /// SDL_EventType
    uint reserved;   /// unused
    ulong timestamp; /// nanoseconds
    uint windowID;   /// window
    uint which;      /// mouse
    float x;         /// horizontal amount, positive right
    float y;         /// vertical amount, positive away from the user
    int direction;   /// 1 when flipped
    float mouseX;    /// pointer position
    float mouseY;    /// pointer position
}

/// Drag and drop.
struct SDL_DropEvent
{
    uint type;           /// SDL_EventType
    uint reserved;       /// unused
    ulong timestamp;     /// nanoseconds
    uint windowID;       /// window dropped on
    float x;             /// window coordinates, unset on begin
    float y;             /// window coordinates, unset on begin
    const(char)* source; /// app the drop came from, or null
    const(char)* data;   /// file name or text, owned by SDL, null on begin and complete
}

/// Application event.
struct SDL_UserEvent
{
    uint type;       /// from `SDL_RegisterEvents`
    uint reserved;   /// unused
    ulong timestamp; /// nanoseconds
    uint windowID;   /// window or 0
    int code;        /// user code
    void* data1;     /// user data
    void* data2;     /// user data
}

/// Any event, 128 bytes.
union SDL_Event
{
    uint type;                    /// SDL_EventType
    SDL_CommonEvent common;       /// shared fields
    SDL_WindowEvent window;       /// window events
    SDL_KeyboardEvent key;        /// key events
    SDL_TextInputEvent text;      /// text input
    SDL_TextEditingEvent edit;    /// input method composition
    SDL_MouseMotionEvent motion;  /// pointer motion
    SDL_MouseButtonEvent button;  /// pointer buttons
    SDL_MouseWheelEvent wheel;    /// wheel
    SDL_DropEvent drop;           /// drag and drop
    SDL_UserEvent user;           /// application events
    ubyte[128] padding;           /// full size
}

static assert(SDL_Event.sizeof == 128);
static assert(SDL_KeyboardEvent.sizeof == 40);
version (D_LP64)
{
    static assert(SDL_MouseButtonEvent.sizeof == 40);
    static assert(SDL_TextEditingEvent.sizeof == 40);
    static assert(SDL_DropEvent.sizeof == 48);
}
else version (X86) version (linux)
{
    // i386 aligns 64-bit fields to 4.
    static assert(SDL_MouseButtonEvent.sizeof == 36);
    static assert(SDL_TextEditingEvent.sizeof == 32);
}

enum ushort SDL_KMOD_SHIFT = 0x0003; /// either shift
enum ushort SDL_KMOD_CTRL = 0x00C0;  /// either ctrl
enum ushort SDL_KMOD_ALT = 0x0300;   /// either alt
enum ushort SDL_KMOD_GUI = 0x0C00;   /// either GUI key

/// System cursor shapes, in header order.
enum SDL_SystemCursor : int
{
    default_, text, wait, crosshair, progress, nwseResize, neswResize, ewResize, nsResize, move,
    notAllowed, pointer,
}

bool SDL_Init(uint flags);                              /// starts subsystems
int SDL_GetVersion();                                   /// loaded version, major * 1000000 + minor * 1000 + patch
void SDL_Quit();                                        /// stops everything
const(char)* SDL_GetError();                            /// last error text
const(char)* SDL_GetCurrentVideoDriver();               /// video driver name, such as "x11" or "wayland"
bool SDL_SetHint(const(char)* name, const(char)* value); /// sets a hint
void SDL_free(void* mem);                               /// frees SDL allocations
/// Opaque shared library.
struct SDL_SharedObject;
SDL_SharedObject* SDL_LoadObject(const(char)* file); /// opens a shared library, null on failure
SDL_FunctionPointer SDL_LoadFunction(SDL_SharedObject* handle, const(char)* name); /// symbol, or null
void SDL_UnloadObject(SDL_SharedObject* handle); /// closes a shared library

/// Opaque read and write stream.
struct SDL_IOStream;
SDL_IOStream* SDL_IOFromConstMem(const(void)* mem, size_t size); /// read-only stream over memory
SDL_Surface* SDL_ConvertSurface(SDL_Surface* surface, uint format); /// copy in pixel format `format`
bool SDL_LockSurface(SDL_Surface* surface);              /// makes `pixels` readable
void SDL_UnlockSurface(SDL_Surface* surface);            /// ends `SDL_LockSurface`

SDL_Window* SDL_CreateWindow(const(char)* title, int w, int h, ulong flags); /// new window
void SDL_DestroyWindow(SDL_Window* window);             /// closes a window
bool SDL_ShowWindow(SDL_Window* window);                /// maps a hidden window
bool SDL_HideWindow(SDL_Window* window);                /// unmaps a window
ulong SDL_GetWindowFlags(SDL_Window* window);           /// SDL_WINDOW_* bits
int SDL_GetSystemTheme();                                /// SDL_SYSTEM_THEME_*: 0 unknown, 1 light, 2 dark
bool SDL_RestoreWindow(SDL_Window* window);             /// unminimizes
bool SDL_RaiseWindow(SDL_Window* window);               /// brings to front and asks for focus
bool SDL_SetWindowTitle(SDL_Window* window, const(char)* title); /// sets the title bar text
bool SDL_SetWindowMinimumSize(SDL_Window* window, int w, int h); /// smallest size, 0 for no limit
bool SDL_SetWindowIcon(SDL_Window* window, SDL_Surface* icon);  /// window icon, copied
bool SDL_GetWindowSize(SDL_Window* window, int* w, int* h);         /// size in window coordinates
bool SDL_GetWindowSizeInPixels(SDL_Window* window, int* w, int* h); /// size in pixels
bool SDL_GetWindowPosition(SDL_Window* window, int* x, int* y);     /// position in screen coordinates
bool SDL_SetWindowPosition(SDL_Window* window, int x, int y);       /// moves, popups relative to their parent
bool SDL_SetWindowSize(SDL_Window* window, int w, int h);           /// resizes, in window coordinates
/// Popup window above `parent`, at `x`, `y` from its top left. Flags need `SDL_WINDOW_TOOLTIP` or
/// `SDL_WINDOW_POPUP_MENU`.
SDL_Window* SDL_CreatePopupWindow(SDL_Window* parent, int x, int y, int w, int h, ulong flags);
SDL_Window* SDL_GetKeyboardFocus();                     /// window with keyboard focus, or null
uint SDL_GetDisplayForWindow(SDL_Window* window);       /// display holding most of the window, 0 on failure
bool SDL_GetDisplayUsableBounds(uint displayID, SDL_Rect* rect); /// display area minus panels, screen coordinates
/// Size of the decorations around the window.
bool SDL_GetWindowBordersSize(SDL_Window* window, int* top, int* left, int* bottom, int* right);
float SDL_GetWindowDisplayScale(SDL_Window* window);    /// pixel density times content scale
uint SDL_GetWindowID(SDL_Window* window);               /// window id in events
uint SDL_GetWindowProperties(SDL_Window* window);       /// properties of a window, 0 on failure
void* SDL_GetPointerProperty(uint props, const(char)* name, void* fallback); /// pointer property or `fallback`

bool SDL_GL_SetAttribute(SDL_GLAttr attr, int value);   /// context attribute for the next context
SDL_GLContext SDL_GL_CreateContext(SDL_Window* window); /// new current context
bool SDL_GL_MakeCurrent(SDL_Window* window, SDL_GLContext context); /// binds a context
bool SDL_GL_DestroyContext(SDL_GLContext context);      /// frees a context
bool SDL_GL_SetSwapInterval(int interval);              /// 1 for vsync
bool SDL_GL_SwapWindow(SDL_Window* window);             /// presents
SDL_FunctionPointer SDL_GL_GetProcAddress(const(char)* proc); /// GL entry point

SDL_Surface* SDL_GetWindowSurface(SDL_Window* window);  /// software framebuffer, invalid after a resize
bool SDL_UpdateWindowSurface(SDL_Window* window);       /// presents the window surface
bool SDL_SetWindowSurfaceVSync(SDL_Window* window, int vsync); /// 1 for vsync on surface updates
SDL_Surface* SDL_CreateSurfaceFrom(int w, int h, uint format, void* pixels, int pitch); /// wraps pixels
void SDL_DestroySurface(SDL_Surface* surface);          /// frees a surface, not wrapped pixels
bool SDL_AddSurfaceAlternateImage(SDL_Surface* surface, SDL_Surface* image); /// adds another size, referenced
bool SDL_SetSurfaceBlendMode(SDL_Surface* surface, uint mode); /// how blits from it blend, 0 copies
/// Copies `src` into `dst` with format conversion, null rects for whole surfaces.
bool SDL_BlitSurface(SDL_Surface* src, const(SDL_Rect)* srcRect, SDL_Surface* dst, const(SDL_Rect)* dstRect);

bool SDL_PollEvent(SDL_Event* event);                   /// next event, false if none
bool SDL_WaitEventTimeout(SDL_Event* event, int timeoutMS); /// next event, false on timeout
bool SDL_PushEvent(SDL_Event* event);                   /// queues an event, any thread
uint SDL_RegisterEvents(int count);                     /// first of `count` user event types

bool SDL_StartTextInput(SDL_Window* window);            /// enables text events
bool SDL_StopTextInput(SDL_Window* window);             /// disables text events
/// Enables text events with properties such as `SDL_PROP_TEXTINPUT_TYPE_NUMBER`.
bool SDL_StartTextInputWithProperties(SDL_Window* window, SDL_PropertiesID props);
/// Where an input method places its windows, `cursor` from `rect.x`, all in window coordinates.
bool SDL_SetTextInputArea(SDL_Window* window, const(SDL_Rect)* rect, int cursor);

SDL_PropertiesID SDL_CreateProperties();               /// new empty property group, 0 on failure
void SDL_DestroyProperties(SDL_PropertiesID props);     /// frees a property group
/// Sets number property `name` of `props`.
bool SDL_SetNumberProperty(SDL_PropertiesID props, const(char)* name, long value);

enum SDL_PROP_TEXTINPUT_TYPE_NUMBER = "SDL.textinput.type"; /// text input property, an SDL_TextInputType
enum SDL_TEXTINPUT_TYPE_TEXT_PASSWORD_HIDDEN = 4;          /// SDL_TextInputType for a hidden password
ushort SDL_GetModState();                              /// held modifiers, SDL_KMOD_* bits
ulong SDL_GetTicksNS();                                /// nanoseconds since SDL started, the clock of event timestamps
enum uint SDL_TOUCH_MOUSEID = 0xffffffff;               /// mouse id of mouse events made from touches
enum uint SDL_PEN_MOUSEID = 0xfffffffe;                 /// mouse id of mouse events made from pens

char* SDL_GetClipboardText();                           /// clipboard, free with SDL_free
bool SDL_SetClipboardText(const(char)* text);           /// sets the clipboard

SDL_Cursor* SDL_CreateSystemCursor(SDL_SystemCursor id); /// stock cursor
bool SDL_SetCursor(SDL_Cursor* cursor);                 /// active cursor

/// File type offered by a file dialog.
struct SDL_DialogFileFilter
{
    const(char)* name;    /// shown name
    const(char)* pattern; /// extensions separated by ';', "*" for every file
}

/// File dialog answer: null `filelist` on error, empty on cancel. May run on any thread.
alias SDL_DialogFileCallback = void function(void* userdata, const(char*)* filelist, int filter);

/// Shows an open dialog. `filters` and `defaultLocation` must stay valid until the callback.
void SDL_ShowOpenFileDialog(SDL_DialogFileCallback callback, void* userdata, SDL_Window* window,
    const(SDL_DialogFileFilter)* filters, int nfilters, const(char)* defaultLocation, bool allowMany);
/// Shows a save dialog. `filters` and `defaultLocation` must stay valid until the callback.
void SDL_ShowSaveFileDialog(SDL_DialogFileCallback callback, void* userdata, SDL_Window* window,
    const(SDL_DialogFileFilter)* filters, int nfilters, const(char)* defaultLocation);
/// Shows a folder dialog. `defaultLocation` must stay valid until the callback.
void SDL_ShowOpenFolderDialog(SDL_DialogFileCallback callback, void* userdata, SDL_Window* window,
    const(char)* defaultLocation, bool allowMany);

struct SDL_Tray;      /// tray icon
struct SDL_TrayMenu;  /// menu of a tray icon or submenu
struct SDL_TrayEntry; /// entry of a tray menu

enum uint SDL_TRAYENTRY_BUTTON = 0x1;          /// plain entry
enum uint SDL_TRAYENTRY_CHECKBOX = 0x2;        /// entry with a check mark
enum uint SDL_TRAYENTRY_SUBMENU = 0x4;         /// entry opening a submenu
enum uint SDL_TRAYENTRY_DISABLED = 0x80000000; /// greyed out
enum uint SDL_TRAYENTRY_CHECKED = 0x40000000;  /// checked, checkboxes only

/// Tray entry press, on the main thread while SDL pumps events.
alias SDL_TrayCallback = void function(void* userdata, SDL_TrayEntry* entry);

SDL_Tray* SDL_CreateTray(SDL_Surface* icon, const(char)* tooltip); /// tray icon, copies `icon`, null on failure
void SDL_SetTrayIcon(SDL_Tray* tray, SDL_Surface* icon);           /// replaces the icon
void SDL_SetTrayTooltip(SDL_Tray* tray, const(char)* tooltip);     /// replaces the tooltip
SDL_TrayMenu* SDL_CreateTrayMenu(SDL_Tray* tray);                  /// menu of a tray icon
SDL_TrayMenu* SDL_CreateTraySubmenu(SDL_TrayEntry* entry);         /// submenu of a SUBMENU entry
/// Inserts an entry at `pos`, -1 to append, null `label` for a separator.
SDL_TrayEntry* SDL_InsertTrayEntryAt(SDL_TrayMenu* menu, int pos, const(char)* label, uint flags);
void SDL_SetTrayEntryLabel(SDL_TrayEntry* entry, const(char)* label); /// relabels, not on separators
void SDL_SetTrayEntryChecked(SDL_TrayEntry* entry, bool checked);  /// checks a checkbox entry
void SDL_SetTrayEntryEnabled(SDL_TrayEntry* entry, bool enabled);  /// enables or greys out
/// Sets what a press calls.
void SDL_SetTrayEntryCallback(SDL_TrayEntry* entry, SDL_TrayCallback callback, void* userdata);
void SDL_DestroyTray(SDL_Tray* tray);                              /// removes the icon and its menus
