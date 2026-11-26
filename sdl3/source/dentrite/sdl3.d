/// SDL3 platform: window, events, clipboard and cursors, presenting frames drawn with GL 3.3 or in software.
module dentrite.sdl3;

import core.stdc.stdlib : free, malloc;
import core.stdc.string : strdup;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, nsecs;
import dentrite.access : AccessAdapter, AccessDemand, AccessUpdate;
import dentrite.accesskit : AccessKitAdapter;
import dentrite.backend.gl33 : GL33Renderer;
import dentrite.backend.software : SoftwareRenderer;
import dentrite.c.gl : GL_RENDERER, GL_VERSION, glGetString, loadGL;
import dentrite.c.sdl;
import dentrite.deadkeys : DeadKeys;
import dentrite.draw : FrameMesh;
import dentrite.geom;
import dentrite.image : Image;
import dentrite.node : CursorShape, Mod, PointerKind, PointerSource;
import dentrite.platform;
import dentrite.text : GlyphAtlas;
import std.math : ceil;
import std.algorithm.comparison : max, min;
import std.algorithm.mutation : remove;
import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.process : environment;
import std.stdio : stderr;
import std.string : fromStringz, toStringz;

/// SDL3 user event type that wakes the loop, set once SDL is up.
private __gshared uint wakeEvent;

/// Pushes the wake event, any thread.
private void wakeSdl() nothrow
{
    SDL_Event e;
    e.type = wakeEvent;
    SDL_PushEvent(&e);
}

/// SDL3 user event type carrying an AccessKit action request, set once SDL is up.
private __gshared uint accessEvent;

/// SDL3 user event type carrying a tray entry press, its key in `code`, set once SDL is up.
private __gshared uint trayEvent;

/// Key of the next tray entry, so a press queued before its tray closed matches no tray.
private __gshared uint nextTrayKey = 1;

/// Longest wait in milliseconds while a tray is open. Outside Windows SDL runs trays only while it pumps events,
/// which a blocking wait does not do.
version (Windows)
    private enum int trayWaitMs = int.max;
else
    private enum int trayWaitMs = 50;

/// Pushes a press on the tray entry with key `userdata` as `trayEvent`. Main thread, while SDL pumps events.
private extern (C) void trayPressed(void* userdata, SDL_TrayEntry* entry) nothrow @nogc
{
    SDL_Event e;
    e.type = trayEvent;
    e.user.code = cast(int) cast(size_t) userdata;
    SDL_PushEvent(&e);
}

/// Runs `fn` with an SDL surface wrapping `img`, null for a null or empty image or when SDL fails.
private void withSurface(Image img, scope void delegate(SDL_Surface*) fn)
{
    if (img is null || img.empty)
    {
        fn(null);
        return;
    }
    ubyte[] px = img.straight();
    SDL_Surface* s = SDL_CreateSurfaceFrom(img.width, img.height, SDL_PIXELFORMAT_ABGR8888, px.ptr, img.width * 4);
    fn(s);
    if (s !is null)
    {
        SDL_DestroySurface(s);
    }
}

/// Tray entry text for SDL, which Windows reads with `&` marking a mnemonic.
private const(char)* trayLabel(string label)
{
    version (Windows)
    {
        import std.array : replace;

        label = label.replace("&", "&&");
    }
    return label.toStringz;
}

/// Takes the GTK reference on submenu `m` that SDL before 3.2.16 forgets, so destroying the tray does not free the
/// menu twice and crash. Does nothing outside Linux or on a null menu.
/// HACK: reads the GtkMenu from the first field of SDL's private `SDL_TrayMenu`, as laid out up to 3.2.14.
private void holdSubmenu(SDL_TrayMenu* m)
{
    version (linux)
    {
        import core.sys.posix.dlfcn : RTLD_LAZY, RTLD_NOLOAD, dlclose, dlopen, dlsym;

        if (m is null || SDL_GetVersion() >= 3_002_016)
        {
            return;
        }
        void* lib = dlopen("libgobject-2.0.so.0", RTLD_LAZY | RTLD_NOLOAD);
        alias Sink = extern (C) void* function(void*) nothrow @nogc;
        Sink sink = lib is null ? null : cast(Sink) dlsym(lib, "g_object_ref_sink");
        if (sink !is null)
        {
            sink(*cast(void**) m);
        }
        if (lib !is null)
        {
            dlclose(lib);
        }
    }
}

/// SDL tray icon. Entries carry keys `firstKey` and up, depth first.
private final class SdlTray : TrayIcon
{
    SdlPlatform platform;            /// platform listing it while open
    SDL_Tray* tray;                  /// SDL tray, null once closed
    SDL_TrayEntry*[] entries;        /// entries depth first, null where SDL made none
    uint firstKey;                   /// key of the first entry
    void delegate(size_t) pressed;   /// app handler, given the entry index

    /// Adds `list` to `menu` and its submenus, null `menu` to only count the entries.
    void add(SDL_TrayMenu* menu, const(TrayEntry)[] list)
    {
        foreach (ref const TrayEntry e; list)
        {
            uint flags = e.submenu ? SDL_TRAYENTRY_SUBMENU : e.checkable ? SDL_TRAYENTRY_CHECKBOX
                : SDL_TRAYENTRY_BUTTON;
            if (e.label !is null && e.enabled == false)
            {
                flags |= SDL_TRAYENTRY_DISABLED;
            }
            if (e.checkable && e.checked)
            {
                flags |= SDL_TRAYENTRY_CHECKED;
            }
            uint key = cast(uint)(firstKey + entries.length);
            SDL_TrayEntry* t = menu is null ? null
                : SDL_InsertTrayEntryAt(menu, -1, e.label is null ? null : trayLabel(e.label), flags);
            entries ~= t;
            if (t !is null && e.label !is null && e.submenu == false)
            {
                SDL_SetTrayEntryCallback(t, &trayPressed, cast(void*) cast(size_t) key);
            }
            if (e.submenu)
            {
                SDL_TrayMenu* sub = t is null ? null : SDL_CreateTraySubmenu(t);
                holdSubmenu(sub);
                add(sub, e.sub);
            }
        }
    }

    /// Index of the entry with `key`, or -1.
    ptrdiff_t indexOf(uint key)
    {
        return key >= firstKey && key - firstKey < entries.length ? key - firstKey : -1;
    }

    /// Replaces the icon.
    void setIcon(Image img)
    {
        if (tray !is null)
        {
            withSurface(img, (SDL_Surface* s) { SDL_SetTrayIcon(tray, s); });
        }
    }

    /// Replaces the tooltip.
    void setTooltip(string tip)
    {
        if (tray !is null)
        {
            SDL_SetTrayTooltip(tray, tip.toStringz);
        }
    }

    /// Updates the label and states of entry `index`.
    void setEntry(size_t index, ref const TrayEntry e)
    {
        SDL_TrayEntry* t = tray is null || e.label is null ? null : entries[index];
        if (t is null)
        {
            return;
        }
        SDL_SetTrayEntryLabel(t, trayLabel(e.label));
        SDL_SetTrayEntryEnabled(t, e.enabled);
        if (e.checkable)
        {
            SDL_SetTrayEntryChecked(t, e.checked);
        }
    }

    /// Removes the icon and its menus.
    void close()
    {
        if (tray is null)
        {
            return;
        }
        SDL_DestroyTray(tray);
        tray = null;
        entries = null;
        platform.dropTray(this);
    }
}

/// File dialog waiting for its answer. The SDL callback fills it on any thread, `wait` hands it to the UI.
private final class FileRequest
{
    void delegate(string[]) done;   /// app handler
    SDL_DialogFileFilter[] filters; /// kept alive until the answer
    const(char)* start;             /// kept alive until the answer
    char** paths;   /// answer copied with malloc, freed on the UI thread
    size_t count;   /// entries in `paths`
    bool answered;  /// set by the callback under `answerLock`
}

/// Guards `FileRequest.answered` and the answer fields.
private __gshared Mutex answerLock;

/// Copies the answer of a file dialog into its request and wakes the loop. Any thread, so no GC.
private extern (C) void fileAnswered(void* userdata, const(char*)* list, int filter) nothrow @nogc
{
    FileRequest r = cast(FileRequest) userdata;
    size_t n;
    while (list !is null && list[n] !is null)
    {
        ++n;
    }
    char** copy = n == 0 ? null : cast(char**) malloc(n * (char*).sizeof);
    foreach (size_t i; 0 .. n)
    {
        copy[i] = strdup(list[i]);
    }
    answerLock.lock_nothrow();
    r.paths = copy;
    r.count = n;
    r.answered = true;
    answerLock.unlock_nothrow();
    SDL_Event e;
    e.type = wakeEvent;
    SDL_PushEvent(&e);
}

/// Popup window of an `SdlPlatform`, transparent, drawn with a GL context or a software renderer of its own.
/// NOTE: X11 cannot draw a transparent window with the main window's context, so each popup has one.
private final class SdlPopup : PopupWindow
{
    SdlPlatform platform;     /// owner
    SDL_Window* win;          /// SDL window, null once closed
    SdlPopup parent;          /// window it sits above, null for the main window
    Rect at;                  /// rectangle in physical pixels from the main window's top left
    uint number;              /// SDL window id
    SDL_GLContext gl;         /// own GL context, null in software
    Renderer renderer;        /// draws its frames
    bool shown;               /// shown, which waits for the first frame

    /// SDL window id.
    uint id()
    {
        return number;
    }

    /// Moves and resizes the window to `r`.
    void move(Rect r)
    {
        if (win is null)
        {
            return;
        }
        at = r;
        SDL_Rect w = platform.popupRect(r, parent);
        SDL_SetWindowPosition(win, w.x, w.y);
        SDL_SetWindowSize(win, w.w, w.h);
    }

    /// Clears to transparent, draws `mesh`, shows the window if new and presents.
    void draw(FrameMesh mesh, GlyphAtlas atlas)
    {
        if (win is null)
        {
            return;
        }
        if (shown == false)
        {
            shown = true;
            SDL_ShowWindow(win);
        }
        if (gl !is null)
        {
            SDL_GL_MakeCurrent(win, gl);
            renderer.render(mesh, atlas, Color(0, 0, 0, 0));
            SDL_GL_SwapWindow(win);
            SDL_GL_MakeCurrent(platform.win, platform.gl);
            return;
        }
        renderer.render(mesh, atlas, Color(0, 0, 0, 0));
        SoftwareRenderer soft = cast(SoftwareRenderer) renderer;
        SdlPlatform.blit(win, soft);
    }

    /// Closes the popups above it, frees its renderer and destroys the window. Safe to call twice.
    void close()
    {
        if (win is null)
        {
            return;
        }
        foreach_reverse (SdlPopup p; platform.popups)
        {
            if (p.parent is this)
            {
                p.close();
            }
        }
        if (gl !is null)
        {
            SDL_GL_MakeCurrent(win, gl);
            renderer.dispose();
            SDL_GL_DestroyContext(gl);
            SDL_GL_MakeCurrent(platform.win, platform.gl);
            gl = null;
        }
        SDL_DestroyWindow(win);
        win = null;
        platform.popups = platform.popups.remove!(p => p is this);
    }
}

/// SDL3 window with a GL 3.3 context or a software surface.
final class SdlPlatform : Platform, FileDialogs, AccessAdapter, WindowControl, Trays, PopupWindows, Appearance
{
    Renderer renderer;              /// renderer drawing into this window, created along with it
    /// Called with every SDL event on the UI thread, before the library handles it.
    void delegate(ref const SDL_Event) onSdlEvent;

    private SDL_Window* win;        /// SDL window
    private SDL_GLContext gl;       /// GL context, null in software
    private SoftwareRenderer soft;  /// software renderer, null with GL
    private int windowW;            /// width in window coordinates
    private int pixelW;             /// framebuffer width
    private SDL_Cursor*[CursorShape.max + 1] cursors; /// stock cursors, made on first use
    private bool closed;            /// `close` already ran
    private FileRequest[] requests; /// file dialogs not answered or not handed out yet
    private bool logInput;          /// DENTRITE_LOG_INPUT is set, so input events go to stderr
    private DeadKeys deadKeys;      /// dead key accents on Wayland, null elsewhere
    private bool wayland;           /// SDL runs on Wayland
    private bool textOn;            /// text input started
    private bool textHidden;        /// text input started for a password
    private bool deadShown;         /// a dead key's accent is shown as composition
    private AccessKitAdapter access; /// screen reader bridge with `WindowOptions.accessibility`, else null
    private Event queued;           /// event `wait` hands out next, after one translated into two
    private bool hasQueued;         /// `queued` is waiting
    private float forced = 0;       /// `WindowOptions.scale`, 0 for the display's own
    private SdlTray[] trays;        /// tray icons open
    private SdlPopup[] popups;      /// popup windows open, parents before their children
    private int upScancode;         /// scancode of the last key up
    private ulong upAt;             /// SDL time stamp of the last key up
    private int imeRepeating;       /// scancode an input method repeats with its own presses, 0 for none
    private bool dropText;          /// the next text event belongs to a dropped key repeat
    private bool dragging;          /// files are arriving between a drop's begin and complete
    private Event dropped;          /// files of the drop arriving, as one `fileDrop` event

    /// Opens the window and sets up the renderer `o.renderer` names.
    this(WindowOptions o)
    {
        SDL_SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "0");
        // NOTE: without it XIM and IBus show nothing until text is committed, such as a dead key's accent.
        SDL_SetHint("SDL_IME_IMPLEMENTED_UI", "composition");
        // NOTE: else closing the window also sends a quit, which `Host.onCloseRequest` cannot cancel.
        SDL_SetHint("SDL_QUIT_ON_LAST_WINDOW_CLOSE", "0");
        enforce(SDL_Init(SDL_INIT_VIDEO), "SDL_Init: " ~ error());
        wakeEvent = SDL_RegisterEvents(3);
        accessEvent = wakeEvent + 1;
        trayEvent = wakeEvent + 2;
        logInput = environment.get("DENTRITE_LOG_INPUT").length > 0;
        if (logInput)
        {
            stderr.writefln("dentrite: SDL video driver %s", fromStringz(SDL_GetCurrentVideoDriver()));
        }
        if (answerLock is null)
        {
            answerLock = new Mutex;
        }
        bool useGL = o.renderer == RendererKind.gl33;
        if (useGL)
        {
            SDL_GL_SetAttribute(SDL_GLAttr.contextMajorVersion, 3);
            SDL_GL_SetAttribute(SDL_GLAttr.contextMinorVersion, 3);
            SDL_GL_SetAttribute(SDL_GLAttr.contextProfileMask, SDL_GL_CONTEXT_PROFILE_CORE);
            SDL_GL_SetAttribute(SDL_GLAttr.doubleBuffer, 1);
            SDL_GL_SetAttribute(SDL_GLAttr.depthSize, 24);
        }
        forced = o.scale;
        int w = toWindow(o.width);
        int h = toWindow(o.height);
        ulong flags = SDL_WINDOW_RESIZABLE | (useGL ? SDL_WINDOW_OPENGL : 0)
            | (forced > 0 ? 0 : SDL_WINDOW_HIGH_PIXEL_DENSITY) | (o.hidden ? SDL_WINDOW_HIDDEN : 0);
        win = SDL_CreateWindow(o.title.toStringz, w, h, flags);
        enforce(win !is null, "SDL_CreateWindow: " ~ error());
        if (useGL)
        {
            string why = startGL(o.vsync);
            if (why is null)
            {
                renderer = new GL33Renderer;
            }
            else
            {
                stderr.writefln("dentrite: %s, drawing in software", why);
                useGL = false;
                SDL_DestroyWindow(win);
                win = SDL_CreateWindow(o.title.toStringz, w, h, flags & ~SDL_WINDOW_OPENGL);
                enforce(win !is null, "SDL_CreateWindow: " ~ error());
            }
        }
        if (useGL == false)
        {
            SDL_SetWindowSurfaceVSync(win, o.vsync ? 1 : 0);
            soft = new SoftwareRenderer;
            renderer = soft;
        }
        setMinimumSize(o.minWidth, o.minHeight);
        readSizes();
        setWaker(&wakeSdl);
        wayland = fromStringz(SDL_GetCurrentVideoDriver()) == "wayland";
        if (wayland)
        {
            deadKeys = DeadKeys.open(SDL_GetPointerProperty(SDL_GetWindowProperties(win),
                "SDL.window.wayland.display", null));
        }
        if (o.accessibility)
        {
            string path = environment.get("DENTRITE_ACCESSKIT");
            access = AccessKitAdapter.open(win, accessEvent, path.length > 0 ? path.toStringz : null);
            if (access is null)
            {
                stderr.writeln("dentrite: accessibility off, AccessKit not found. DENTRITE_ACCESSKIT names its file");
            }
        }
        if (logInput)
        {
            stderr.writefln("dentrite: dead key accents %s", deadKeys is null ? "off" : "on");
        }
    }

    /// Makes a GL 3.3 context for the window and loads GL. Null on success, else why not, with no context left.
    /// NOTE: without a GPU driver Windows gives an OpenGL 1.1 context, and SDL returns it in place of 3.3.
    private string startGL(bool vsync)
    {
        gl = SDL_GL_CreateContext(win);
        if (gl is null)
        {
            return "no OpenGL 3.3 context: " ~ error();
        }
        SDL_GL_MakeCurrent(win, gl);
        string why;
        glGetString = cast(typeof(glGetString)) SDL_GL_GetProcAddress("glGetString");
        const(char)* ver = glGetString is null ? null : glGetString(GL_VERSION);
        string v = ver is null ? null : fromStringz(ver).idup;
        if (v.length < 3 || v[0] < '3' || (v[0] == '3' && v[2] < '3'))
        {
            const(char)* by = v is null ? null : glGetString(GL_RENDERER);
            why = "OpenGL 3.3 needed, the driver gives " ~ (v is null ? "none" : v ~ " from " ~ fromStringz(by).idup);
        }
        else
        {
            string missing = loadGL((const(char)* name) => cast(void*) SDL_GL_GetProcAddress(name));
            why = missing is null ? null : "GL entry point missing: " ~ missing;
        }
        if (why !is null)
        {
            SDL_GL_DestroyContext(gl);
            gl = null;
            return why;
        }
        SDL_GL_SetSwapInterval(vsync ? 1 : 0);
        return null;
    }

    /// What the next accessibility update must hold, none without AccessKit.
    AccessDemand demand()
    {
        return access is null ? AccessDemand.none : access.demand();
    }

    /// Sends an accessibility update to AccessKit.
    void update(ref const AccessUpdate u, float scale)
    {
        if (access !is null)
        {
            access.update(u, scale);
        }
    }

    /// Last SDL error.
    private static string error()
    {
        return fromStringz(SDL_GetError()).idup;
    }

    /// Caches the sizes that map window coordinates to pixels.
    private void readSizes()
    {
        int unused;
        SDL_GetWindowSize(win, &windowW, &unused);
        SDL_GetWindowSizeInPixels(win, &pixelW, &unused);
    }

    /// Window coordinates to physical pixels.
    private Point toPixels(float x, float y)
    {
        float k = windowW > 0 ? cast(float) pixelW / windowW : 1;
        return Point(x * k, y * k);
    }

    /// Framebuffer size and display scale.
    Metrics metrics()
    {
        Metrics m;
        SDL_GetWindowSizeInPixels(win, &m.pixelW, &m.pixelH);
        m.scale = SDL_GetWindowDisplayScale(win);
        return m;
    }

    /// Next SDL event within `timeout`, translated. Kind `none` for events the host does not need.
    /// SDL waits in whole milliseconds, so the last part of a wait sleeps without seeing events.
    bool wait(ref Event e, Duration timeout)
    {
        int ms = timeout == Duration.max ? -1 : cast(int) timeout.total!"msecs";
        if (ms == 0 && timeout > Duration.zero)
        {
            Thread.sleep(timeout);
        }
        if (hasQueued)
        {
            e = queued;
            hasQueued = false;
            return true;
        }
        if (takeAnswer(e))
        {
            return true;
        }
        SDL_Event s;
        if (waitSdl(s, ms) == false)
        {
            return false;
        }
        if (dropStaleRepeat(s))
        {
            e = Event.init;
            return true;
        }
        if (onSdlEvent !is null)
        {
            onSdlEvent(s);
        }
        e = translate(s);
        if (e.kind == EventKind.wake)
        {
            takeAnswer(e);
        }
        return true;
    }

    /// Next SDL event within `ms` milliseconds, -1 for no limit. While a tray is open, waits in slices of
    /// `trayWaitMs` so SDL pumps it.
    private bool waitSdl(ref SDL_Event s, int ms)
    {
        if (ms == 0)
        {
            return SDL_PollEvent(&s);
        }
        if (trays.length == 0 || (ms > 0 && ms <= trayWaitMs))
        {
            return SDL_WaitEventTimeout(&s, ms);
        }
        MonoTime end = MonoTime.currTime + msecs(ms);
        while (true)
        {
            long left = ms < 0 ? trayWaitMs : (end - MonoTime.currTime).total!"msecs";
            if (left <= 0)
            {
                return SDL_PollEvent(&s);
            }
            if (SDL_WaitEventTimeout(&s, cast(int) min(left, trayWaitMs)))
            {
                return true;
            }
        }
    }

    /// True if `s` is a stale key repeat SDL made up, or the text of one, which is then dropped.
    /// HACK: for fcitx5 on Wayland. fcitx5 repeats a held key itself, as a release and a press each time,
    /// all stamped with the Wayland time of the first press. Each press restarts SDL's own repeat from that
    /// time, so on the real release SDL sends every repeat due since the first press, and the text doubles.
    /// Such a press carries the same time stamp as the release just before it, which a real one never does,
    /// and while a key is pressed like that, SDL's repeats of it are all stale. Their own time stamps can't
    /// tell, as SDL 3.4 clamps them to the current time. Remove once fcitx5 or SDL fixes it.
    private bool dropStaleRepeat(ref const SDL_Event s)
    {
        if (wayland == false)
        {
            return false;
        }
        bool text = dropText;
        dropText = false;
        switch (s.type)
        {
        case SDL_EventType.keyUp:
            upScancode = s.key.scancode;
            upAt = s.key.timestamp;
            return false;
        case SDL_EventType.keyDown:
            if (s.key.repeat == false)
            {
                bool fake = s.key.scancode == upScancode && s.key.timestamp <= upAt;
                imeRepeating = fake ? s.key.scancode : 0;
                return false;
            }
            if (imeRepeating == 0 || s.key.scancode != imeRepeating)
            {
                return false;
            }
            if (logInput)
            {
                stderr.writefln("dentrite: dropped a stale repeat of scancode %d", s.key.scancode);
            }
            dropText = true;
            return true;
        case SDL_EventType.textInput:
            return text;
        default:
            return false;
        }
    }

    /// Shows a tray icon, or null when SDL has none here, such as on Linux without an AppIndicator library.
    TrayIcon openTray(Image icon, string tooltip, const(TrayEntry)[] menu, void delegate(size_t) pressed)
    {
        SDL_Tray* t;
        withSurface(icon, (SDL_Surface* s) { t = SDL_CreateTray(s, tooltip.toStringz); });
        if (t is null)
        {
            stderr.writefln("dentrite: no tray icon, %s", error());
            return null;
        }
        SdlTray tray = new SdlTray;
        tray.platform = this;
        tray.tray = t;
        tray.pressed = pressed;
        tray.firstKey = nextTrayKey;
        tray.add(SDL_CreateTrayMenu(t), menu);
        nextTrayKey += cast(uint) tray.entries.length;
        trays ~= tray;
        return tray;
    }

    /// Forgets closed tray `t`.
    private void dropTray(SdlTray t)
    {
        foreach (size_t i, SdlTray k; trays)
        {
            if (k is t)
            {
                trays = trays[0 .. i] ~ trays[i + 1 .. $];
                return;
            }
        }
    }

    /// Shows an SDL file dialog over the window. The answer comes back from `wait` as a `call` event.
    void fileDialog(FileDialogKind kind, const(FileFilter)[] filters, string start, void delegate(string[]) done)
    {
        FileRequest r = new FileRequest;
        r.done = done;
        foreach (ref const FileFilter f; filters)
        {
            r.filters ~= SDL_DialogFileFilter(f.name.toStringz, f.pattern.toStringz);
        }
        r.start = start is null ? null : start.toStringz;
        requests ~= r;
        void* u = cast(void*) r;
        const(SDL_DialogFileFilter)* fs = r.filters.length == 0 ? null : r.filters.ptr;
        int n = cast(int) r.filters.length;
        final switch (kind)
        {
        case FileDialogKind.open:
        case FileDialogKind.openMany:
            SDL_ShowOpenFileDialog(&fileAnswered, u, win, fs, n, r.start, kind == FileDialogKind.openMany);
            break;
        case FileDialogKind.save:
            SDL_ShowSaveFileDialog(&fileAnswered, u, win, fs, n, r.start);
            break;
        case FileDialogKind.folder:
            SDL_ShowOpenFolderDialog(&fileAnswered, u, win, r.start, false);
            break;
        }
    }

    /// Turns the first answered file dialog into a `call` event and frees its copy. False if none is answered.
    private bool takeAnswer(ref Event e)
    {
        FileRequest found;
        answerLock.lock_nothrow();
        foreach (size_t i, FileRequest r; requests)
        {
            if (r.answered)
            {
                found = r;
                requests = requests[0 .. i] ~ requests[i + 1 .. $];
                break;
            }
        }
        answerLock.unlock_nothrow();
        if (found is null)
        {
            return false;
        }
        string[] paths;
        foreach (size_t i; 0 .. found.count)
        {
            paths ~= fromStringz(found.paths[i]).idup;
            free(found.paths[i]);
        }
        free(found.paths);
        void delegate(string[]) done = found.done;
        e = Event.init;
        e.kind = EventKind.call;
        e.call = () { done(paths); };
        return true;
    }

    /// Sets the device and time of pointer event `e` from SDL mouse id `which` and timestamp `ns`.
    private static void stamp(ref Event e, uint which, ulong ns)
    {
        e.source = which == SDL_TOUCH_MOUSEID ? PointerSource.touch
            : which == SDL_PEN_MOUSEID ? PointerSource.pen : PointerSource.mouse;
        ulong at = SDL_GetTicksNS();
        e.time = MonoTime.currTime - nsecs(cast(long) (at > ns ? at - ns : 0));
    }

    /// SDL id of the window that window or pointer event `s` came from, 0 for other events.
    private static uint windowOf(ref const SDL_Event s)
    {
        switch (s.type)
        {
        case SDL_EventType.mouseMotion:
            return s.motion.windowID;
        case SDL_EventType.mouseButtonDown:
        case SDL_EventType.mouseButtonUp:
            return s.button.windowID;
        case SDL_EventType.mouseWheel:
            return s.wheel.windowID;
        case SDL_EventType.dropFile:
        case SDL_EventType.dropText:
        case SDL_EventType.dropBegin:
        case SDL_EventType.dropComplete:
            return s.drop.windowID;
        default:
            return s.type >= 0x200 && s.type < 0x300 ? s.window.windowID : 0;
        }
    }

    /// Event for SDL event `s`.
    private Event translate(ref SDL_Event s)
    {
        Event e;
        if (logInput)
        {
            logEvent(s);
        }
        SdlPopup from = popupOf(windowOf(s));
        if (from !is null)
        {
            e.surface = from.number;
        }
        switch (s.type)
        {
        case SDL_EventType.quit:
            e.kind = EventKind.quit;
            break;
        case SDL_EventType.windowCloseRequested:
            e.kind = from is null ? EventKind.close : EventKind.none;
            break;
        case SDL_EventType.windowMoved:
        case SDL_EventType.windowShown:
        case SDL_EventType.windowMaximized:
        case SDL_EventType.windowRestored:
            if (from !is null)
            {
                break;
            }
            // the popup area moved with it
            e.kind = s.type == SDL_EventType.windowMoved ? EventKind.resized : EventKind.shown;
            if (access !is null)
            {
                access.windowMoved(win);
            }
            break;
        case SDL_EventType.windowHidden:
        case SDL_EventType.windowMinimized:
            e.kind = from is null ? EventKind.hidden : EventKind.dismissed;
            break;
        case SDL_EventType.windowFocusGained:
            if (access !is null)
            {
                access.windowFocus(true);
            }
            break;
        case SDL_EventType.windowResized:
        case SDL_EventType.windowPixelSizeChanged:
        case SDL_EventType.windowDisplayScaleChanged:
            if (from !is null)
            {
                break;
            }
            readSizes();
            e.kind = EventKind.resized;
            if (access !is null)
            {
                access.windowMoved(win);
            }
            break;
        case SDL_EventType.windowExposed:
            e.kind = EventKind.exposed;
            break;
        case SDL_EventType.windowMouseLeave:
            e.kind = EventKind.pointerLeft;
            break;
        case SDL_EventType.windowFocusLost:
            if (ours(SDL_GetKeyboardFocus()))
            {
                break; // moved between the window and its popups
            }
            e.kind = EventKind.focusLost;
            deadShown = false;
            if (access !is null)
            {
                access.windowFocus(false);
            }
            break;
        case SDL_EventType.mouseMotion:
            e.kind = EventKind.pointer;
            e.pointer = PointerKind.move;
            e.pos = toPixels(s.motion.x, s.motion.y);
            stamp(e, s.motion.which, s.motion.timestamp);
            break;
        case SDL_EventType.mouseButtonDown:
        case SDL_EventType.mouseButtonUp:
            e.kind = EventKind.pointer;
            e.pointer = s.type == SDL_EventType.mouseButtonDown ? PointerKind.down : PointerKind.up;
            e.pos = toPixels(s.button.x, s.button.y);
            e.button = s.button.button;
            e.clicks = s.button.clicks;
            stamp(e, s.button.which, s.button.timestamp);
            e.mods = modsOf(SDL_GetModState());
            break;
        case SDL_EventType.mouseWheel:
            float dir = s.wheel.direction == 1 ? -1 : 1;
            e.kind = EventKind.wheel;
            e.pos = toPixels(s.wheel.mouseX, s.wheel.mouseY);
            e.dx = s.wheel.x * dir;
            e.dy = -s.wheel.y * dir;
            e.mods = modsOf(SDL_GetModState());
            break;
        case SDL_EventType.keyDown:
            e.kind = EventKind.key;
            e.key = s.key.key;
            e.mods = modsOf(s.key.mod);
            e.repeat = s.key.repeat;
            deadKey(s.key, e);
            break;
        case SDL_EventType.textEditing:
            if (deadShown && *s.edit.text == 0)
            {
                break; // the compositor ending a composition it never showed, which would hide the accent
            }
            deadShown = false;
            e.kind = EventKind.compose;
            e.text = fromStringz(s.edit.text).idup;
            e.start = s.edit.start;
            e.length = s.edit.length;
            break;
        case SDL_EventType.textInput:
            deadShown = false;
            e.kind = EventKind.text;
            e.text = fromStringz(s.text.text).idup;
            break;
        case SDL_EventType.dropBegin:
            dragging = true;
            dropped = Event(EventKind.fileDrop);
            break;
        case SDL_EventType.dropFile:
            if (s.drop.data is null)
            {
                break;
            }
            dropped.kind = EventKind.fileDrop;
            dropped.surface = e.surface;
            dropped.pos = toPixels(s.drop.x, s.drop.y);
            dropped.paths ~= fromStringz(s.drop.data).idup;
            if (dragging == false)
            {
                e = takeDrop(); // a file the system opens with the app, with no begin
            }
            break;
        case SDL_EventType.dropComplete:
            dragging = false;
            e = takeDrop();
            break;
        case SDL_EventType.systemThemeChanged:
            e.kind = EventKind.colorScheme;
            break;
        default:
            if (s.type == wakeEvent)
            {
                e.kind = EventKind.wake;
            }
            else if (s.type == accessEvent)
            {
                e.kind = EventKind.access;
                if (access !is null)
                {
                    e.request = access.request(s);
                }
            }
            else if (s.type == trayEvent)
            {
                trayPress(cast(uint) s.user.code, e);
            }
            break;
        }
        return e;
    }

    /// The files dropped so far as one `fileDrop` event, kind `none` if there are none. Clears them.
    private Event takeDrop()
    {
        Event e = dropped.paths.length > 0 ? dropped : Event.init;
        dropped = Event.init;
        return e;
    }

    /// System light or dark appearance.
    ColorScheme colorScheme()
    {
        switch (SDL_GetSystemTheme())
        {
        case 1:
            return ColorScheme.light;
        case 2:
            return ColorScheme.dark;
        default:
            return ColorScheme.unknown;
        }
    }

    /// Turns a press on the tray entry with `key` into a `call` event, none if its tray closed.
    private void trayPress(uint key, ref Event e)
    {
        foreach (SdlTray t; trays)
        {
            ptrdiff_t i = t.indexOf(key);
            if (i >= 0)
            {
                void delegate(size_t) pressed = t.pressed;
                e.kind = EventKind.call;
                e.call = () { pressed(i); };
                return;
            }
        }
    }

    /// Writes key, text and composition events to stderr.
    private static void logEvent(ref SDL_Event s)
    {
        switch (s.type)
        {
        case SDL_EventType.keyDown:
        case SDL_EventType.keyUp:
            stderr.writefln("dentrite: key %s scancode %d key 0x%x raw %d mods 0x%x%s at %d",
                s.type == SDL_EventType.keyDown ? "down" : "up", s.key.scancode, s.key.key, s.key.raw, s.key.mod,
                s.key.repeat ? " repeat" : "", s.key.timestamp);
            break;
        case SDL_EventType.textEditing:
            stderr.writefln("dentrite: compose \"%s\" start %d length %d", fromStringz(s.edit.text),
                s.edit.start, s.edit.length);
            break;
        case SDL_EventType.textInput:
            stderr.writefln("dentrite: text \"%s\"", fromStringz(s.text.text));
            break;
        default:
            break;
        }
    }

    /// Turns a dead key into composition showing its accent, and clears that ahead of the next key, which
    /// commits it. Backspace and Escape only cancel it.
    private void deadKey(ref const SDL_KeyboardEvent k, ref Event e)
    {
        bool modifier = (k.scancode >= 224 && k.scancode <= 231) || k.scancode == 57 || k.scancode == 257;
        if (deadKeys is null || textOn == false || modifier)
        {
            return;
        }
        string accent = deadKeys.accent(k.raw);
        if (accent is null && deadShown == false)
        {
            return;
        }
        bool cancel = k.scancode == 42 || k.scancode == 41;
        if (accent is null && cancel == false)
        {
            queued = e;
            hasQueued = true;
        }
        deadShown = accent !is null;
        e = Event.init;
        e.kind = EventKind.compose;
        e.text = accent is null ? "" : accent;
    }

    /// Mod bits from SDL's modifier bits.
    private static ubyte modsOf(ushort m)
    {
        return cast(ubyte)(((m & SDL_KMOD_SHIFT) ? Mod.shift : 0) | ((m & SDL_KMOD_CTRL) ? Mod.ctrl : 0)
            | ((m & SDL_KMOD_ALT) ? Mod.alt : 0) | ((m & SDL_KMOD_GUI) ? Mod.gui : 0));
    }

    /// Swaps GL buffers, or copies the software frame to the window surface.
    void present()
    {
        if (gl !is null)
        {
            SDL_GL_SwapWindow(win);
            return;
        }
        blit(win, soft);
    }

    /// Copies the last frame of `r` to the surface of `w`, alpha included, and presents it.
    private static void blit(SDL_Window* w, SoftwareRenderer r)
    {
        SDL_Surface* dst = SDL_GetWindowSurface(w);
        if (dst is null || r.pixels.length == 0)
        {
            return;
        }
        SDL_Surface* src = SDL_CreateSurfaceFrom(r.width, r.height, SDL_PIXELFORMAT_ABGR8888, r.pixels.ptr,
            r.width * 4);
        if (src is null)
        {
            return;
        }
        SDL_SetSurfaceBlendMode(src, 0);
        SDL_BlitSurface(src, null, dst, null);
        SDL_DestroySurface(src);
        SDL_UpdateWindowSurface(w);
    }

    /// Display work area in physical pixels from the window's top left, empty if SDL does not know it.
    /// NOTE: on Wayland the window position reads as 0, 0, so the area is a guess the compositor corrects.
    Rect popupArea()
    {
        SDL_Rect u;
        uint d = SDL_GetDisplayForWindow(win);
        if (d == 0 || SDL_GetDisplayUsableBounds(d, &u) == false)
        {
            return Rect.init;
        }
        int x;
        int y;
        SDL_GetWindowPosition(win, &x, &y);
        Point from = toPixels(u.x - x, u.y - y);
        Point size = toPixels(u.w, u.h);
        return Rect(from.x, from.y, size.x, size.y);
    }

    /// Opens a hidden popup window at `r` above `parent`, shown by its first frame. A menu when `input`, else a
    /// tooltip. Null if SDL or GL failed.
    PopupWindow openPopup(PopupWindow parent, Rect r, bool input)
    {
        SdlPopup up = cast(SdlPopup) parent;
        SDL_Rect w = popupRect(r, up);
        ulong flags = (input ? SDL_WINDOW_POPUP_MENU : SDL_WINDOW_TOOLTIP) | SDL_WINDOW_TRANSPARENT | SDL_WINDOW_HIDDEN
            | (gl is null ? 0 : SDL_WINDOW_OPENGL) | (forced > 0 ? 0 : SDL_WINDOW_HIGH_PIXEL_DENSITY);
        SDL_Window* made = SDL_CreatePopupWindow(up is null ? win : up.win, w.x, w.y, w.w, w.h, flags);
        if (made is null)
        {
            stderr.writeln("dentrite: SDL_CreatePopupWindow: ", error());
            return null;
        }
        SdlPopup p = new SdlPopup;
        p.platform = this;
        p.win = made;
        p.parent = up;
        p.at = r;
        p.number = SDL_GetWindowID(made);
        if (gl is null)
        {
            p.renderer = new SoftwareRenderer;
            SDL_GetWindowSurface(made); // NOTE: may recreate the window, which would read as a dismissal once shown
        }
        else
        {
            p.gl = SDL_GL_CreateContext(made);
            if (p.gl is null)
            {
                stderr.writeln("dentrite: popup GL context: ", error());
                SDL_DestroyWindow(made);
                SDL_GL_MakeCurrent(win, gl);
                return null;
            }
            SDL_GL_SetSwapInterval(0);
            p.renderer = new GL33Renderer;
            SDL_GL_MakeCurrent(win, gl);
        }
        if (textOn)
        {
            startText(made);
        }
        popups ~= p;
        return p;
    }

    /// Window rectangle for physical pixels `r` from the main window's top left, relative to `parent`, or to the
    /// main window if null.
    private SDL_Rect popupRect(Rect r, SdlPopup parent)
    {
        float k = pixelW > 0 ? cast(float) windowW / pixelW : 1;
        Point o = parent is null ? Point(0, 0) : parent.at.pos;
        return SDL_Rect(cast(int)((r.x - o.x) * k), cast(int)((r.y - o.y) * k), cast(int) ceil(r.w * k),
            cast(int) ceil(r.h * k));
    }

    /// Popup window with SDL id `id`, or null.
    private SdlPopup popupOf(uint id)
    {
        foreach (SdlPopup p; popups)
        {
            if (p.number == id)
            {
                return p;
            }
        }
        return null;
    }

    /// True if `w` is the main window or one of its popups.
    private bool ours(SDL_Window* w)
    {
        return w !is null && (w is win || popupOf(SDL_GetWindowID(w)) !is null);
    }

    /// Shows the stock cursor for `shape`.
    void setCursor(CursorShape shape)
    {
        if (cursors[shape] is null)
        {
            static immutable SDL_SystemCursor[CursorShape.max + 1] map = [SDL_SystemCursor.default_,
                SDL_SystemCursor.text, SDL_SystemCursor.pointer, SDL_SystemCursor.ewResize,
                SDL_SystemCursor.nsResize, SDL_SystemCursor.nwseResize, SDL_SystemCursor.neswResize,
                SDL_SystemCursor.move];
            cursors[shape] = SDL_CreateSystemCursor(map[shape]);
        }
        SDL_SetCursor(cursors[shape]);
    }

    /// SDL window, for SDL calls the library does not wrap.
    SDL_Window* handle()
    {
        return win;
    }

    /// Logical pixels `n` in window coordinates, as the window size is given at creation.
    private int toWindow(int n)
    {
        return forced > 0 ? cast(int)(n * forced) : n;
    }

    /// Sets the title bar text.
    void setTitle(string title)
    {
        SDL_SetWindowTitle(win, title.toStringz);
    }

    /// Shows, unminimizes and raises the window, or hides it.
    void setVisible(bool on)
    {
        if (on == false)
        {
            SDL_HideWindow(win);
            return;
        }
        SDL_ShowWindow(win);
        if (SDL_GetWindowFlags(win) & SDL_WINDOW_MINIMIZED)
        {
            SDL_RestoreWindow(win);
        }
        SDL_RaiseWindow(win);
    }

    /// True unless hidden.
    bool visible()
    {
        return (SDL_GetWindowFlags(win) & SDL_WINDOW_HIDDEN) == 0;
    }

    /// Sets the smallest size the user can resize to, in logical pixels, 0 for no limit.
    void setMinimumSize(int w, int h)
    {
        SDL_SetWindowMinimumSize(win, toWindow(max(0, w)), toWindow(max(0, h)));
    }

    /// Sets the window icon from `icons`, which SDL copies. The smallest is the icon at 100% scale, the others
    /// its alternate sizes.
    void setIcon(Image[] icons)
    {
        Image[] bySize = icons.dup;
        bySize.sort!((a, b) => a.width < b.width);
        ubyte[][] pixels; // NOTE: SDL wraps these until the icon is set, so they stay referenced here
        SDL_Surface*[] surfaces;
        foreach (Image img; bySize)
        {
            ubyte[] px = img.straight();
            SDL_Surface* s = SDL_CreateSurfaceFrom(img.width, img.height, SDL_PIXELFORMAT_ABGR8888, px.ptr,
                img.width * 4);
            if (s !is null)
            {
                pixels ~= px;
                surfaces ~= s;
            }
        }
        if (surfaces.length > 0)
        {
            foreach (SDL_Surface* a; surfaces[1 .. $])
            {
                SDL_AddSurfaceAlternateImage(surfaces[0], a);
            }
            SDL_SetWindowIcon(win, surfaces[0]);
        }
        foreach (SDL_Surface* s; surfaces)
        {
            SDL_DestroySurface(s);
        }
    }

    /// Starts or stops SDL text events, on the popup windows too, as the topmost popup menu takes keyboard focus.
    void textInput(bool on, bool hidden)
    {
        textOn = on;
        textHidden = on && hidden;
        deadShown = false;
        foreach (SDL_Window* w; [win] ~ popupWindows())
        {
            if (on)
            {
                startText(w);
            }
            else
            {
                SDL_StopTextInput(w);
            }
        }
    }

    /// Starts text events on `w`, as a hidden password while `textHidden` is set.
    private void startText(SDL_Window* w)
    {
        if (textHidden == false)
        {
            SDL_StartTextInput(w);
            return;
        }
        SDL_PropertiesID props = SDL_CreateProperties();
        SDL_SetNumberProperty(props, SDL_PROP_TEXTINPUT_TYPE_NUMBER, SDL_TEXTINPUT_TYPE_TEXT_PASSWORD_HIDDEN);
        SDL_StartTextInputWithProperties(w, props);
        SDL_DestroyProperties(props);
    }

    /// Tells the input method where the caret is, given in physical pixels, on the popup windows too.
    void textInputArea(Rect caret)
    {
        float k = pixelW > 0 ? cast(float) windowW / pixelW : 1;
        SDL_Rect r = SDL_Rect(cast(int)(caret.x * k), cast(int)(caret.y * k), max(1, cast(int)(caret.w * k)),
            max(1, cast(int)(caret.h * k)));
        SDL_SetTextInputArea(win, &r, 0);
        foreach (SdlPopup p; popups)
        {
            SDL_Rect pr = SDL_Rect(r.x - cast(int)(p.at.x * k), r.y - cast(int)(p.at.y * k), r.w, r.h);
            SDL_SetTextInputArea(p.win, &pr, 0);
        }
    }

    /// SDL windows of the open popups.
    private SDL_Window*[] popupWindows()
    {
        SDL_Window*[] list;
        foreach (SdlPopup p; popups)
        {
            list ~= p.win;
        }
        return list;
    }

    /// Clipboard text.
    string clipboard()
    {
        char* c = SDL_GetClipboardText();
        if (c is null)
        {
            return null;
        }
        string s = fromStringz(c).idup;
        SDL_free(c);
        return s;
    }

    /// Sets the clipboard.
    void setClipboard(string s)
    {
        SDL_SetClipboardText(s.toStringz);
    }

    /// Destroys the context and window and quits SDL. Safe to call twice.
    void close()
    {
        if (closed)
        {
            return;
        }
        closed = true;
        setWaker(null);
        if (access !is null)
        {
            access.close();
            access = null;
        }
        foreach (SdlTray t; trays.dup)
        {
            t.close();
        }
        foreach_reverse (SdlPopup p; popups.dup)
        {
            p.close();
        }
        if (deadKeys !is null)
        {
            deadKeys.close();
            deadKeys = null;
        }
        if (gl !is null)
        {
            SDL_GL_DestroyContext(gl);
        }
        SDL_DestroyWindow(win);
        SDL_Quit();
    }
}
