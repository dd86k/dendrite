/// Windows without a window system: the app they share, their trees, input routing, focus, frame scheduling.
///
/// No frame runs unless something asked for one: input, a node change, a timer or
/// a wake from another thread. A frame drains the app's hooks, relays out dirty
/// boundaries, runs dirty islands, composes the layers (recording and tessellating
/// the stale ones), renders and presents.
module dentrite.host;

import core.memory : GC;
import core.time : Duration, MonoTime, usecs;
import dentrite.access;
import dentrite.containers : PanelStyle, ScrollStyle, SeparatorStyle, scrollIntoView;
import dentrite.dock : DockStyle;
import dentrite.draw;
import dentrite.image : Image;
import dentrite.island : IslandStyle;
import dentrite.loop : Alarms, FrameClock;
public import dentrite.loop : Alarm;
import dentrite.node;
import dentrite.overlay : Popup, PopupStyle;
import dentrite.platform;
import dentrite.png : encodePNG;
import dentrite.signals : Computed, Signal, computed, signal;
import dentrite.text;
import dentrite.theme : Theme;
import dentrite.widgets.button : ButtonStyle;
import dentrite.widgets.checkbox : CheckboxStyle;
import dentrite.widgets.label : TextStyle;
import dentrite.widgets.link : LinkStyle;
import dentrite.widgets.list : ListStyle;
import dentrite.widgets.combobox : ComboBoxStyle;
import dentrite.widgets.dialog : DialogStyle;
import dentrite.widgets.handles : HandleStyle;
import dentrite.widgets.menu : MenuBarStyle, MenuStyle;
import dentrite.widgets.progress : ProgressStyle;
import dentrite.widgets.radio : RadioStyle;
import dentrite.widgets.slider : SliderStyle;
import dentrite.widgets.spinbox : SpinBoxStyle;
import dentrite.widgets.splitview : SplitViewStyle;
import dentrite.widgets.table : TableStyle;
import dentrite.widgets.tabs : TabsStyle;
import dentrite.widgets.textarea : TextAreaStyle;
import dentrite.widgets.textbox : TextBoxStyle;
import dentrite.widgets.tooltip : TooltipStyle, Tooltips;
import dentrite.widgets.tree : TreeStyle;
import std.algorithm.comparison : max, min;
import std.algorithm.mutation : remove;
import std.algorithm.searching : all, any, canFind;
import std.math : abs, ceil, round;
import std.meta : AliasSeq;
import std.stdio : stderr;
import std.utf : stride;

/// Look of the window itself.
struct WindowStyle
{
    enum section = "window"; /// section name in theme files
    Color background = Color(0x1b, 0x1b, 0x1e, 0xff); /// window background, the color each frame clears to
}

/// Style structs of the library, checked when a theme loads.
alias LibraryStyles = AliasSeq!(WindowStyle, TextStyle, ButtonStyle, CheckboxStyle, TextBoxStyle, ListStyle,
    PanelStyle, ScrollStyle, SeparatorStyle, DockStyle, PopupStyle, MenuStyle, MenuBarStyle, ComboBoxStyle,
    TooltipStyle, RadioStyle, SliderStyle, ProgressStyle, TabsStyle, SpinBoxStyle, TreeStyle, TableStyle,
    DialogStyle, TextAreaStyle, IslandStyle, SplitViewStyle, HandleStyle, LinkStyle);

/// Timings and sizes of the last frame.
struct FrameStats
{
    ulong frames;        /// frames rendered so far
    Duration layout;     /// time relaying out dirty boundaries
    Duration islands;    /// time in island passes
    Duration paint;      /// time recording stale layers
    Duration tessellate; /// time tessellating stale layers
    Duration compose;    /// time building the frame's batches from the layers
    Duration render;     /// time in the renderer
    Duration total;      /// time laying out, composing and rendering the frame, the app's hooks left out
    size_t commands;     /// draw commands recorded
    int layersRecorded;  /// layers painted and tessellated
    int layersReused;    /// layers copied from their cache
    size_t vertices;     /// vertices of the layers drawn
    size_t meshBytes;    /// vertex and index bytes of those layers
    size_t batches;      /// draw batches sent to the renderer
    int boundaries;      /// relayout boundaries laid out
    int islandPasses;    /// islands that ran a pass
}

/// Popup in an OS window of its own.
private struct Shown
{
    Popup popup;        /// popup shown
    PopupWindow window; /// its window
    Rect at;            /// window rectangle in physical pixels from the main window's top left
    FrameMesh mesh;     /// its frame
}

/// Duration of `ms` milliseconds, such as a `ScrollStyle` delay.
private Duration millis(float ms)
{
    return usecs(cast(long) (ms * 1000));
}

/// What a process shares between its windows: the platform, fonts, theme, alarms, frame hooks and the loop. Made
/// by the main window's `Host`, reached from any window as `Host.app`.
final class App
{
    Platform platform;   /// window system side, see `Platform`
    Theme theme;         /// theme of every window, see `setTheme`
    bool running = true; /// set to false to make `run` return after the current frame
    /// App work at frame start, such as draining mailboxes. Tree changes made here show in the same frame and ask
    /// for no other, `Host.requestFrame` still does. While every window is hidden `run` calls them with no frame
    /// after a wake, a call or an alarm.
    void delegate()[] beforeFrame;

    private WindowOptions opts;   /// main window settings, for the theme file and check
    private immutable(ubyte)[][FontKind.max + 1] fonts; /// font file bytes per slot, with `setFont` changes
    private FontFile[] fallbacks; /// fallback fonts in the order they are tried
    private TextSystem[] texts;   /// text systems, one per scale in use
    private Alarms alarms;        /// calls from `at` and `after`
    private bool woke;            /// a wake or call came since the hooks last ran
    private bool closed;          /// `close` already ran
    private Host[] hosts;         /// open windows, the main one first
    private Host pointerHost;     /// window of the last pointer event
    private Signal!ColorScheme schemeNow; /// system appearance, for `colorScheme`

    /// Takes over `p`, loads the fonts and the theme of `o`.
    private this(Platform p, WindowOptions o)
    {
        import std.file : readText;

        platform = p;
        opts = o;
        fonts = fontBytes(o);
        fallbacks = fallbackFiles(o);
        texts ~= new TextSystem(fonts, fallbacks);
        if (o.themePath.length > 0)
        {
            theme = new Theme(readText(o.themePath), o.themePath);
            check(theme);
        }
        Appearance look = cast(Appearance) p;
        schemeNow = signal(look is null ? ColorScheme.unknown : look.colorScheme());
    }

    /// Font file bytes of each slot in `o`, read from `o.fonts` where `o.fontData` has none.
    private static immutable(ubyte)[][FontKind.max + 1] fontBytes(ref const WindowOptions o)
    {
        import std.file : read;

        immutable(ubyte)[][FontKind.max + 1] slots;
        foreach (size_t i; 0 .. slots.length)
        {
            slots[i] = o.fontData[i].length > 0 ? o.fontData[i] : cast(immutable(ubyte)[]) read(o.fonts[i]);
        }
        return slots;
    }

    /// Fallback fonts of `o` in the order they are tried.
    private static FontFile[] fallbackFiles(ref const WindowOptions o)
    {
        FontFile[] files = o.fallbackFontData.dup;
        foreach (string p; o.fallbackFonts ~ (o.systemFallbacks ? systemFallbackFonts() : null))
        {
            files ~= FontFile(p);
        }
        return files;
    }

    /// Open windows, the main one first.
    Host[] windows()
    {
        return hosts.dup;
    }

    /// Closes every window, the main one last, and frees the fonts and the platform. Safe to call twice.
    void close()
    {
        if (closed)
        {
            return;
        }
        closed = true;
        foreach_reverse (Host h; hosts.dup)
        {
            h.closeWindow();
        }
        foreach (TextSystem t; texts)
        {
            t.dispose();
        }
        platform.close();
    }

    /// Forgets window `h`, which closed.
    private void leave(Host h)
    {
        hosts = hosts.remove!(k => k is h);
        if (pointerHost is h)
        {
            pointerHost = null;
        }
    }

    /// Open window with `Event.window` value `id`, or null.
    private Host hostOf(uint id)
    {
        foreach (Host h; hosts)
        {
            if (h.id == id)
            {
                return h;
            }
        }
        return null;
    }

    /// Text system at scale `s` for window `asker`: one at that scale, else one no other window uses, rescaled,
    /// else a new one.
    private TextSystem textFor(float s, Host asker)
    {
        foreach (TextSystem t; texts)
        {
            if (t.ppp == s)
            {
                return t;
            }
        }
        foreach (TextSystem t; texts)
        {
            if (hosts.all!(h => h is asker || h.text !is t))
            {
                t.setScale(s);
                return t;
            }
        }
        TextSystem t = new TextSystem(fonts, fallbacks);
        t.setContrast(texts[0].contrast);
        t.setScale(s);
        texts ~= t;
        return t;
    }

    /// Calls `fn` on the UI thread at `t`, even while every window is hidden. Tree changes it makes show in the
    /// next frame. Call from the UI thread, the returned alarm cancels it.
    Alarm at(MonoTime t, void delegate() fn)
    {
        assert(fn !is null);
        Alarm a = new Alarm(t, fn);
        alarms.add(a);
        return a;
    }

    /// Calls `fn` on the UI thread once `d` passed, see `at`.
    Alarm after(Duration d, void delegate() fn)
    {
        return at(MonoTime.currTime + d, fn);
    }

    /// Runs frames until `running` is set to false, the main window closes or the system asks to quit. A window
    /// draws when it asks for a frame, not while hidden or minimized. Alarms from `at` still run, and so do the
    /// `beforeFrame` hooks after a wake, a call or an alarm while every window is hidden.
    void run()
    {
        while (running)
        {
            Event e;
            MonoTime now = MonoTime.currTime;
            if (platform.wait(e, min(alarms.timeout(now), frameTimeout(now))))
            {
                handle(e);
                while (platform.wait(e, Duration.zero))
                {
                    handle(e);
                }
            }
            MonoTime t = MonoTime.currTime;
            bool rang = alarms.fire(t);
            if (hosts.all!(h => h.hidden))
            {
                if (rang || woke)
                {
                    runHooks();
                }
            }
            else if (hosts.any!(h => h.due(t)))
            {
                frame(null);
            }
        }
    }

    /// How long `run` may wait at `now` before a window wants a frame, `Duration.max` for none.
    private Duration frameTimeout(MonoTime now)
    {
        Duration d = Duration.max;
        foreach (Host h; hosts)
        {
            if (h.hidden == false)
            {
                d = min(d, h.clock.timeout(now));
            }
        }
        return d;
    }

    /// Handles the platform events waiting now, without blocking, for loops of their own such as scripted runs.
    void pump()
    {
        Event e;
        while (platform.wait(e, Duration.zero))
        {
            handle(e);
        }
    }

    /// Runs the `beforeFrame` hooks.
    private void runHooks()
    {
        woke = false;
        foreach (void delegate() hook; beforeFrame)
        {
            hook();
        }
    }

    /// One frame for every window that wants one and for `forced`, even hidden, if not null: due alarms and the
    /// hooks once, then the layout and compose of each window, then the render and present of each.
    private void frame(Host forced)
    {
        MonoTime t = MonoTime.currTime;
        Host[] due;
        foreach (Host h; hosts)
        {
            if ((h is forced && h.closed == false) || h.due(t))
            {
                due ~= h;
                h.beginFrame(t);
            }
        }
        alarms.fire(t);
        runHooks();
        foreach (Host h; hosts)
        {
            if (due.canFind(h) == false && h.due(t))
            {
                due ~= h; // woken by the alarms or hooks
                h.beginFrame(t);
            }
        }
        foreach (Host h; due)
        {
            if (h.closed == false)
            {
                h.prepareFrame();
            }
        }
        foreach (Host h; due)
        {
            if (h.closed == false)
            {
                h.drawFrame();
            }
        }
        foreach (TextSystem s; texts)
        {
            s.endFrame();
        }
        foreach (Host h; due)
        {
            h.endFrame();
        }
    }

    /// Handles one platform event: those about the whole app here, the others by the window they came from, if
    /// still open.
    void handle(ref const Event e)
    {
        switch (e.kind)
        {
        case EventKind.quit:
            running = false;
            break;
        case EventKind.wake:
            woke = true;
            wantHooks();
            break;
        case EventKind.call:
            woke = true;
            if (e.call !is null)
            {
                e.call();
            }
            wantHooks();
            break;
        case EventKind.colorScheme:
            if (Appearance look = cast(Appearance) platform)
            {
                schemeNow.set(look.colorScheme());
                wantHooks();
            }
            break;
        default:
            Host h = hostOf(e.window);
            if (h is null)
            {
                break;
            }
            bool pointing = e.kind == EventKind.pointer || e.kind == EventKind.wheel;
            if (pointing && h !is pointerHost)
            {
                h.cursorStale = pointerHost !is null; // the cursor is shared
                pointerHost = h;
            }
            h.handle(e);
            break;
        }
    }

    /// Asks a shown window for a frame so the hooks run, or the main one if all are hidden.
    private void wantHooks()
    {
        foreach (Host h; hosts)
        {
            if (h.hidden == false)
            {
                h.requestFrame();
                return;
            }
        }
        if (hosts.length > 0)
        {
            hosts[0].requestFrame();
        }
    }

    /// Runs the app's theme check, or the library's.
    private void check(Theme t)
    {
        if (opts.checkTheme !is null)
        {
            opts.checkTheme(t);
        }
        else
        {
            t.check!LibraryStyles();
        }
    }

    /// Reloads `WindowOptions.themePath` of the main window, keeping the old theme if the new one has errors.
    void reloadTheme()
    {
        import std.file : readText;

        if (opts.themePath.length == 0)
        {
            return;
        }
        try
        {
            setTheme(new Theme(readText(opts.themePath), opts.themePath));
            stderr.writeln("dentrite: reloaded ", opts.themePath);
        }
        catch (Exception ex)
        {
            stderr.writeln("dentrite: theme not reloaded: ", ex.msg);
        }
    }

    /// Checks theme `t` as a loaded one is checked and restyles every window with it. Throws on errors, keeping
    /// the old theme. Ctrl+R still reloads `WindowOptions.themePath` over it.
    void setTheme(Theme t)
    {
        check(t);
        theme = t;
        foreach (Host h; hosts)
        {
            h.tree.theme = t;
            h.tree.restyle();
            h.requestFrame();
        }
    }

    /// Replaces the font of slot `kind` with font file bytes `data` and lays every window out again. Throws if
    /// the bytes are not a font, keeping the old one.
    void setFont(FontKind kind, immutable(ubyte)[] data)
    {
        texts[0].setFont(kind, data);
        foreach (TextSystem t; texts[1 .. $])
        {
            t.setFont(kind, data);
        }
        fonts[kind] = data;
        foreach (Host h; hosts)
        {
            h.tree.restyle();
            h.requestFrame();
        }
    }

    /// Replaces the font of slot `kind` with font file `path`. Throws if it cannot be read or is not a font.
    void setFont(FontKind kind, string path)
    {
        import std.file : read;

        setFont(kind, cast(immutable(ubyte)[]) read(path));
    }

    /// System light or dark appearance, `unknown` when the platform does not say. Effects reading it rerun when
    /// the system switches.
    ColorScheme colorScheme()
    {
        return schemeNow.get;
    }

    /// Opens `url` with the system's handler, such as the default browser. False if the platform cannot open
    /// URLs or the system refused it.
    bool openUrl(string url)
    {
        Urls u = cast(Urls) platform;
        return u !is null && u.openUrl(url);
    }
}

/// Retained UI in one top-level window: its tree, input routing, focus and frames. The first one opened on a
/// platform is the main window, which makes the `App` the others share, see `openWindow`.
class Host : Services
{
    App app;              /// fonts, theme and loop shared with the other windows
    Tree tree;            /// retained node tree
    TextSystem text;      /// text system at this window's scale: fonts, shaping and the glyph atlas
    FrameStats stats;     /// timings of the last frame
    /// Runs when the user asks to close the window, return false to keep it open. Null closes it. Closing the
    /// main window makes `run` return.
    bool delegate() onCloseRequest;
    /// Runs with the files dropped on the window and the drop point in logical pixels.
    void delegate(string[] paths, Point at) onFileDrop;
    /// Runs while something is dragged over the window, with the pointer in logical pixels. Whether it holds files
    /// shows only at the drop.
    void delegate(Point at) onFileHover;
    void delegate() onFileLeave; /// runs when the drag over the window leaves or ends, before `onFileDrop`
    string screenshotPath; /// PNG file written after the next frame, then cleared
    Platform platform;    /// window system side shared by every window, see `Platform`
    PlatformWindow platformWindow; /// this window's side of the platform, `platform` itself for the main window
    Renderer renderer;    /// renderer drawing the frames
    Tooltips tooltips;    /// tooltip of the node under the pointer
    AccessTree access;    /// what assistive technologies were last told

    private WindowOptions opts;     /// settings
    private FrameMesh mesh;         /// tessellated frame
    private Compositor compositor;  /// layers to frame mesh
    private uint id;                /// `Event.window` of this window, 0 for the main one
    private FrameClock clock;       /// frame requests and cap
    private float scale = 1;        /// physical pixels per logical pixel
    private int pixelW;             /// framebuffer width
    private int pixelH;             /// framebuffer height
    private Node hoverNode;         /// node under the pointer
    private Node captureNode;       /// node that saw the press
    private bool sliding;           /// the held press let go of its node, see `slidePress`
    private bool holding;           /// `held` waits to see if a drag scroller takes it, see `DragScroller`
    private PointerEvent held;      /// left press held back
    private bool mayTake;           /// a drag scroller may take the last left press until it moves `dragStart`
    private Point pressAt;          /// where the last left press went down
    private bool longArmed;         /// `longFrom` may still become a long press, see `ScrollStyle.longPress`
    private PointerEvent longFrom;  /// last touch or pen press on content with a context menu
    private PointerSource source;   /// device of the last pointer event
    private MonoTime pointerTime;   /// time of the last pointer event
    private Node focusNode;         /// keyboard focus
    private bool revealFocus;       /// scroll the focused node into view after the next layout
    private Point mouse;            /// pointer, logical
    private bool pointerIn;         /// pointer is over the window
    private MonoTime frameTime;     /// start of the current frame
    private bool hidden;            /// window hidden or minimized, `run` draws no frames
    private CursorShape cursorShown; /// cursor last set on the platform
    private bool cursorStale;       /// another window set the shared cursor since
    private bool missed;            /// the last frame lacked glyphs, so draw another
    private bool textInputOn;       /// platform text input enabled
    private bool fileOver;          /// something is dragged over the window, see `onFileHover`
    private bool textHiddenOn;      /// platform text input is for a password
    private string composing;       /// input method text not committed yet
    private Rect inputArea;         /// caret last given to the input method
    private bool keyboardFocus;     /// focus last moved by Tab
    private bool closed;            /// `close` already ran
    private AccessAdapter accessAdapter; /// platform side when `WindowOptions.accessibility` is set
    private ulong accessFocus;      /// focus id last sent to the adapter
    private AccessTree lookup;      /// description for `find`, apart from what the adapter was sent
    private PopupWindows popupWindows; /// platform side of popups in windows of their own, null without
    private Shown[] shown;          /// popups in windows of their own, bottom first
    private uint pointerSurface;    /// surface of the last pointer event, 0 for the main window
    private Signal!Size sizeNow;    /// window size in logical pixels, for `windowSize`
    private void delegate(string) textHandler; /// see `onText`

    /// Takes over `p` and `r` as the main window, loads fonts and the theme.
    this(Platform p, Renderer r, WindowOptions o)
    {
        app = new App(p, o);
        setUp(p, r, o, 0);
    }

    /// Opens a window of its own in `owner`'s app, sharing its fonts, theme, hooks and loop. Throws if the
    /// platform cannot open windows. See `openWindow`.
    this(Host owner, WindowOptions o)
    {
        import std.exception : enforce;

        Windows ws = cast(Windows) owner.app.platform;
        enforce(ws !is null, "the platform cannot open windows");
        TopWindow w = ws.openWindow(o);
        enforce(w !is null, "the window did not open");
        app = owner.app;
        setUp(w, w.renderer, o, w.id);
    }

    /// Sets up the window `w` drawn by `r`, with `Event.window` value `id`, and adds it to the app.
    private void setUp(PlatformWindow w, Renderer r, WindowOptions o, uint id)
    {
        platform = app.platform;
        platformWindow = w;
        renderer = r;
        opts = o;
        this.id = id;
        scale = scaleOf(w.metrics());
        text = app.textFor(scale, this);
        tree = new Tree(text, app.theme, this);
        tree.scrollDrag = o.scrollDrag;
        tooltips = new Tooltips(tree);
        access = new AccessTree;
        access.title = o.title;
        if (o.accessibility)
        {
            accessAdapter = cast(AccessAdapter) w;
        }
        if (o.popupWindows)
        {
            popupWindows = cast(PopupWindows) w;
        }
        mesh = new FrameMesh;
        compositor.cache = o.cachePaint;
        clock = FrameClock(o.maxFps);
        hidden = o.hidden;
        sizeNow = signal(Size.init);
        app.hosts ~= this;
        updateSize();
    }

    /// Opens another top-level window sharing this one's app, with the title, size and window settings of `o`,
    /// see `WindowOptions`. Throws if the platform cannot open windows. It closes with `close`, with the user's
    /// close request unless `onCloseRequest` says no, or with the main window.
    Host openWindow(WindowOptions o)
    {
        return new Host(this, o);
    }

    /// Closes the window unless the GC is finalizing it, so `scope Window w = new Window(o)` cleans up.
    /// NOTE: a GC finalizer may run on any thread after the platform is gone, so it leaks instead.
    ~this()
    {
        if (GC.inFinalizer == false)
        {
            close();
        }
    }

    /// Closes the window, its popups and renderer. For the main window, closes every other window and frees the
    /// fonts and the platform too. Safe to call twice.
    void close()
    {
        if (closed)
        {
            return;
        }
        if (id == 0)
        {
            app.close();
            return;
        }
        closeWindow();
    }

    /// Closes the popup windows, frees the renderer, leaves the app and closes the window unless it is the main
    /// one, which the platform closes.
    private void closeWindow()
    {
        if (closed)
        {
            return;
        }
        closed = true;
        foreach_reverse (ref Shown s; shown)
        {
            s.window.close();
        }
        shown = null;
        renderer.dispose();
        app.leave(this);
        if (id != 0)
        {
            platformWindow.close();
        }
    }

    /// True once `close` ran, such as after the user closed the window.
    bool isClosed() const
    {
        return closed;
    }

    /// Sets the app's root node. Open popups stay open.
    void setRoot(Node root)
    {
        tree.setRoot(root);
    }

    /// Scale to draw at for metrics `m`: `WindowOptions.scale`, else the display's, else 1.
    private float scaleOf(Metrics m) const
    {
        float s = opts.scale > 0 ? opts.scale : m.scale;
        return s > 0 ? s : 1;
    }

    /// Reads the framebuffer size and the scale, moving to the app's text system for a new scale.
    private void updateSize()
    {
        Metrics m = platformWindow.metrics();
        pixelW = m.pixelW;
        pixelH = m.pixelH;
        float s = scaleOf(m);
        if (s != scale || text.ppp != s)
        {
            scale = s;
            text = app.textFor(s, this);
            tree.text = text;
            tree.restyle();
        }
        tree.viewport = Size(pixelW / scale, pixelH / scale);
        Rect area = popupWindows is null || visible == false ? Rect.init : popupWindows.popupArea();
        tree.root.screen = Rect(area.x / scale, area.y / scale, area.w / scale, area.h / scale);
        requestFrame();
        sizeNow.set(tree.viewport);
    }

    // Services

    /// Asks for a frame as soon as the frame cap allows.
    void requestFrame()
    {
        clock.request();
    }

    /// Asks for a frame at `t`. Frames pause while the window is hidden, `at` runs work then too.
    void requestFrameAt(MonoTime t)
    {
        clock.requestAt(t);
    }

    /// Calls `fn` on the UI thread at `t`, see `App.at`.
    Alarm at(MonoTime t, void delegate() fn)
    {
        return app.at(t, fn);
    }

    /// Calls `fn` on the UI thread once `d` passed, see `App.at`.
    Alarm after(Duration d, void delegate() fn)
    {
        return app.after(d, fn);
    }

    /// Whether `run` goes on, false to make it return after the current frame, see `App.running`.
    ref bool running()
    {
        return app.running;
    }

    /// App work at frame start, see `App.beforeFrame`.
    ref void delegate()[] beforeFrame()
    {
        return app.beforeFrame;
    }

    /// Current theme, shared by every window, see `setTheme`.
    Theme theme()
    {
        return app.theme;
    }

    /// Moves keyboard focus to `n`, or clears it.
    void setFocus(Node n)
    {
        if (n is focusNode)
        {
            return;
        }
        Node old = focusNode;
        focusNode = n;
        inputArea = Rect.init;
        if (composing.length > 0)
        {
            endComposition(old);
            if (textInputOn)
            {
                textInputOn = false;
                textHiddenOn = false;
                platformWindow.textInput(false, false);
            }
        }
        if (old !is null)
        {
            old.focused = false;
            old.markNeedsPaint();
            old.onFocus(false);
        }
        if (n !is null)
        {
            n.focused = true;
            n.markNeedsPaint();
            n.onFocus(true);
            for (Node a = n.parent; a !is null; a = a.parent)
            {
                a.onFocusWithin(n);
            }
        }
        syncTextInput();
        requestFrame();
    }

    /// Starts, stops or restarts platform text input to match the focused node, ending any composition.
    private void syncTextInput()
    {
        bool field = focusNode !is null && focusNode.textInput;
        bool want = field || textHandler !is null;
        bool hidden = field && focusNode.hiddenText;
        if (want == textInputOn && hidden == textHiddenOn)
        {
            return;
        }
        if (composing.length > 0)
        {
            endComposition(focusNode);
        }
        textInputOn = want;
        textHiddenOn = hidden;
        platformWindow.textInput(want, hidden);
    }

    /// Clears the composition `n` shows, if it is a `Composer`.
    private void endComposition(Node n)
    {
        composing = null;
        Composer c = cast(Composer) n;
        if (c !is null)
        {
            c.compose(null, 0, 0);
        }
    }

    /// Hands input method text to the focused node, with SDL style code point `start` and `length` turned into
    /// bytes.
    private void compose(string s, int start, int length)
    {
        composing = s;
        Composer c = cast(Composer) focusNode;
        if (c is null)
        {
            return;
        }
        size_t from = start < 0 ? s.length : byteOffset(s, start);
        size_t to = length <= 0 ? from : byteOffset(s, start + length);
        c.compose(s.length == 0 ? null : s, from, to);
        requestFrame();
    }

    /// Node with keyboard focus.
    Node focused()
    {
        return focusNode;
    }

    /// Clipboard text.
    string clipboard()
    {
        return platform.clipboard();
    }

    /// Sets the clipboard.
    void setClipboard(string s)
    {
        platform.setClipboard(s);
    }

    /// True if focus last moved by keyboard.
    bool focusVisible()
    {
        return keyboardFocus;
    }

    /// Sets whether focus last moved by keyboard, repainting the focused node when its ring changes.
    private void setKeyboardFocus(bool on)
    {
        if (on != keyboardFocus && focusNode !is null)
        {
            focusNode.markNeedsPaint();
        }
        keyboardFocus = on;
    }

    /// Drops hover, capture and focus held by `n`, which is leaving the tree.
    void forget(Node n)
    {
        if (n.hoverInside && hoverNode !is null)
        {
            hoverNode.hovered = false;
            moveHoverInside(hoverNode, null);
            hoverNode = null;
        }
        if (n is captureNode)
        {
            n.pressed = false;
            captureNode = null;
        }
        if (n is focusNode)
        {
            setFocus(null);
        }
    }

    /// Start of the current frame.
    MonoTime now()
    {
        return frameTime == MonoTime.init ? MonoTime.currTime : frameTime;
    }

    // Loop

    /// Runs every window until `running` is set to false, the main window closes or the system asks to quit, see
    /// `App.run`.
    void run()
    {
        app.run();
    }

    /// Handles the platform events waiting now, without blocking, for loops of their own such as scripted runs.
    void pump()
    {
        app.pump();
    }

    /// One frame of this window, and of the others that want one: due alarms, hooks, layout, islands, compose,
    /// render, present.
    void frame()
    {
        app.frame(this);
    }

    /// True if this window wants a frame at `t`, false while hidden.
    private bool due(MonoTime t)
    {
        return closed == false && hidden == false && clock.due(t);
    }

    /// Starts a frame at `t`, before the app's alarms and hooks, where paint requests need no new frame.
    private void beginFrame(MonoTime t)
    {
        frameTime = t;
        clock.started(t);
        tree.frameStart = true;
    }

    /// Lays out and composes this window's frame, after the app's alarms and hooks, ahead of any render.
    private void prepareFrame()
    {
        tree.firePaintTimers(frameTime);
        if (holding && frameTime - held.time >= millis(tree.style!ScrollStyle().pressDelay))
        {
            holding = false;
            mayTake = held.source != PointerSource.mouse;
            deliverPress(held);
        }
        if (longArmed && frameTime - longFrom.time >= millis(tree.style!ScrollStyle().longPress))
        {
            longArmed = false;
            openHeldMenu();
        }
        tooltips.tick(frameTime);
        tree.frameStart = false;
        MonoTime t0 = MonoTime.currTime;
        tree.flush();
        int boundaries = tree.boundaryLayouts;
        if (revealFocus && focusNode !is null && focusNode.tree is tree)
        {
            FocusScope inner = cast(FocusScope) focusNode;
            scrollIntoView(focusNode, inner is null ? focusNode.bounds : inner.focusRect);
        }
        revealFocus = false;
        MonoTime t1 = MonoTime.currTime;
        foreach (int round; 0 .. 2)
        {
            foreach (Updatable u; tree.updaters.dup)
            {
                u.update();
            }
            if (tree.needsLayout == false)
            {
                break;
            }
            tree.flush();
            boundaries += tree.boundaryLayouts;
        }
        if (pointerIn && captureNode is null && holding == false)
        {
            setHover(interactiveAt(mouse));
            if (sliding == false)
            {
                tooltips.pointer(reachableAt(mouse), mouse);
            }
        }
        syncPopups();
        MonoTime t2 = MonoTime.currTime;
        compositor.tess.ppp = scale;
        compositor.tess.text = text;
        compositor.compose(tree.root.paintLayer, mesh, pixelW, pixelH);
        stats.commands = compositor.commands;
        stats.layersRecorded = compositor.recorded;
        stats.layersReused = compositor.reused;
        stats.vertices = compositor.vertices;
        stats.meshBytes = compositor.meshBytes;
        stats.batches = mesh.batches.length;
        Duration painting = compositor.painting;
        Duration tessellating = compositor.tessellating;
        bool missedNow = mesh.missedGlyphs;
        // NOTE: every mesh of every window before any render, as composing can add atlas rows a renderer misses
        foreach (ref Shown s; shown)
        {
            Rect b = s.popup.bounds;
            Point origin = Point(b.x - s.at.x / scale, b.y - s.at.y / scale);
            compositor.compose(s.popup.paintLayer, s.mesh, cast(int) s.at.w, cast(int) s.at.h, origin);
            painting += compositor.painting;
            tessellating += compositor.tessellating;
            stats.commands += compositor.commands;
            stats.layersRecorded += compositor.recorded;
            stats.layersReused += compositor.reused;
            stats.vertices += compositor.vertices;
            stats.meshBytes += compositor.meshBytes;
            stats.batches += s.mesh.batches.length;
            missedNow = missedNow || s.mesh.missedGlyphs;
        }
        tree.paintRequested = false;
        syncTextInput();
        placeInputArea();
        updateAccess();
        MonoTime t4 = MonoTime.currTime;
        missed = missedNow;
        stats.layout = t1 - t0;
        stats.islands = t2 - t1;
        stats.paint = painting;
        stats.tessellate = tessellating;
        stats.compose = t4 - t2 - painting - tessellating;
        stats.boundaries = boundaries;
        stats.total = t4 - t0;
    }

    /// Renders the composed frame and its popups, writes a pending screenshot and presents.
    private void drawFrame()
    {
        MonoTime t4 = MonoTime.currTime;
        Color clear = tree.style!WindowStyle().background;
        clear.a = 0xff;
        renderer.render(mesh, text.atlas, clear);
        foreach (ref Shown s; shown)
        {
            s.window.draw(s.mesh, text.atlas);
        }
        MonoTime t5 = MonoTime.currTime;
        if (screenshotPath.length > 0)
        {
            import std.file : write;

            write(screenshotPath, encodePNG(renderer.readPixels(), pixelW, pixelH));
            stderr.writeln("dentrite: wrote ", screenshotPath);
            screenshotPath = null;
        }
        platformWindow.present();
        stats.frames += 1;
        stats.render = t5 - t4;
        stats.total += stats.render;
    }

    /// Asks for another frame if the last one lacked glyphs, after the text systems ended theirs.
    private void endFrame()
    {
        if (missed)
        {
            requestFrame();
        }
    }

    /// Opens, moves and closes popup windows to match the popups that `Stage.place` gave windows of their own.
    /// Each sits above the window of the one below it, so a window and the ones above it close together.
    private void syncPopups()
    {
        if (popupWindows is null && shown.length == 0)
        {
            return;
        }
        Popup[] want;
        foreach (Popup p; tree.root.popups)
        {
            if (p.windowed)
            {
                want ~= p;
            }
        }
        size_t keep;
        while (keep < shown.length && keep < want.length && shown[keep].popup is want[keep])
        {
            ++keep;
        }
        foreach_reverse (ref Shown s; shown[keep .. $])
        {
            s.window.close();
        }
        shown.length = keep;
        foreach (ref Shown s; shown)
        {
            Rect r = popupRect(s.popup);
            if (r != s.at)
            {
                s.at = r;
                s.window.move(r);
            }
        }
        foreach (Popup p; want[keep .. $])
        {
            Rect r = popupRect(p);
            PopupWindow w = popupWindows.openPopup(shown.length > 0 ? shown[$ - 1].window : null, r,
                p.passPointer == false);
            if (w is null)
            {
                stderr.writeln("dentrite: popup window failed, keeping popups inside the window");
                popupWindows = null;
                tree.root.screen = Rect.init;
                tree.root.markNeedsLayout();
                return;
            }
            shown ~= Shown(p, w, r, new FrameMesh);
        }
    }

    /// Window rectangle for `p` in physical pixels from the main window's top left, with room for its shadow.
    private Rect popupRect(Popup p)
    {
        Rect b = p.bounds;
        float room = round(tree.style!PopupStyle().room * scale);
        return Rect(round(b.x * scale) - room, round(b.y * scale) - room, ceil(b.w * scale) + room * 2,
            ceil(b.h * scale) + room * 2);
    }

    /// Popup in a window of its own with `id`, or null.
    private Shown* shownWith(uint id)
    {
        foreach (ref Shown s; shown)
        {
            if (s.window.id == id)
            {
                return &s;
            }
        }
        return null;
    }

    /// Tells the platform where the focused node's caret is, if it changed since last time.
    private void placeInputArea()
    {
        if (textInputOn == false || focusNode is null || focusNode.tree !is tree)
        {
            return;
        }
        Composer c = cast(Composer) focusNode;
        Rect at = c is null ? focusNode.bounds : c.caretRect;
        if (at != inputArea)
        {
            inputArea = at;
            platformWindow.textInputArea(Rect(at.x * scale, at.y * scale, at.w * scale, at.h * scale));
        }
    }

    /// Sends the adapter what changed in the tree, while an assistive technology listens.
    private void updateAccess()
    {
        if (accessAdapter is null)
        {
            return;
        }
        AccessDemand d = accessAdapter.demand();
        if (d == AccessDemand.none)
        {
            return;
        }
        AccessUpdate u = access.update(tree, focusNode, d == AccessDemand.full);
        if (u.full || u.nodes.length > 0 || u.focus != accessFocus)
        {
            accessFocus = u.focus;
            accessAdapter.update(u, scale);
        }
    }

    /// Runs what an assistive technology asked for: focus and scrolling here, the rest by the node or the
    /// `AccessActions` node holding it, and a context menu by the nearest node with one.
    private void runAccess(ref const AccessRequest r)
    {
        Node n = access.nodeOf(r.target);
        if (n is null || n.tree is null)
        {
            return;
        }
        ptrdiff_t part = access.partOf(r.target);
        AccessParts parts = cast(AccessParts) n;
        if (part >= 0 && parts !is null)
        {
            if (r.action == AccessAction.focus && n.focusable)
            {
                setKeyboardFocus(true);
                setFocus(n);
            }
            parts.accessPartAction(part, r);
        }
        else if (r.action == AccessAction.focus && n.focusable)
        {
            setKeyboardFocus(true);
            setFocus(n);
            revealFocus = true;
        }
        else if (r.action == AccessAction.scrollIntoView)
        {
            scrollIntoView(n, n.bounds);
        }
        else if (n.accessAction(r) == false)
        {
            AccessActions h = access.handlerOf(r.target);
            bool done = h !is null && h.accessActionFor(n, r);
            if (done == false && r.action == AccessAction.showContextMenu)
            {
                Rect b = n.bounds;
                for (Node m = n; m !is null; m = m.parent)
                {
                    if (m.onContextMenu(Point(b.x, b.y + min(b.h, 32f)), true))
                    {
                        break;
                    }
                }
            }
        }
        requestFrame();
    }

    /// Handles one platform event for this window, whatever its `Event.window`. Events for the whole app, such as
    /// `quit`, `wake` and `call`, go to `App.handle`.
    void handle(ref const Event e)
    {
        final switch (e.kind)
        {
        case EventKind.none:
            break;
        case EventKind.close:
            if (onCloseRequest !is null && onCloseRequest() == false)
            {
                break;
            }
            if (id == 0)
            {
                app.running = false;
            }
            else
            {
                close();
            }
            break;
        case EventKind.quit:
        case EventKind.wake:
        case EventKind.call:
        case EventKind.colorScheme:
            app.handle(e);
            break;
        case EventKind.resized:
            updateSize();
            break;
        case EventKind.hidden:
            hidden = true;
            break;
        case EventKind.shown:
            hidden = false;
            updateSize();
            break;
        case EventKind.exposed:
            hidden = false;
            requestFrame();
            break;
        case EventKind.pointerLeft:
            if (e.surface != pointerSurface)
            {
                break;
            }
            pointerIn = false;
            if (captureNode is null)
            {
                setHover(null);
            }
            tooltips.pointer(null, mouse);
            break;
        case EventKind.focusLost:
            tooltips.hush();
            holding = false;
            longArmed = false;
            mayTake = false;
            endComposition(focusNode);
            if (captureNode !is null)
            {
                PointerEvent up = PointerEvent(PointerKind.up, mouse, 1, 0, 0, source, pointerTime);
                release(up);
            }
            sliding = false;
            tree.root.dismissAll();
            break;
        case EventKind.pointer:
            Point to;
            if (fromSurface(e, to) == false)
            {
                break;
            }
            pointerSurface = e.surface;
            pointer(e.pointer, to, e.clicks, e.button, e.mods, e.source, e.time);
            break;
        case EventKind.wheel:
            Point at;
            if (fromSurface(e, at))
            {
                routeWheel(WheelEvent(at, e.dx * 48, e.dy * 48, e.mods));
            }
            break;
        case EventKind.key:
            key(KeyEvent(e.key, e.mods, e.repeat));
            break;
        case EventKind.text:
            composing = null;
            if ((focusNode is null || focusNode.onText(e.text) == false) && textHandler !is null
                && tree.root.holdsKeys(focusNode) == false)
            {
                textHandler(e.text);
            }
            break;
        case EventKind.fileHover:
            Point hoverAt;
            if (fromSurface(e, hoverAt))
            {
                fileOver = true;
                if (onFileHover !is null)
                {
                    onFileHover(hoverAt);
                    requestFrame();
                }
            }
            break;
        case EventKind.fileLeave:
            endFileHover();
            break;
        case EventKind.fileDrop:
            endFileHover();
            Point dropAt;
            if (onFileDrop !is null && e.paths.length > 0 && fromSurface(e, dropAt))
            {
                onFileDrop(e.paths.dup, dropAt);
                requestFrame();
            }
            break;
        case EventKind.compose:
            compose(e.text, e.start, e.length);
            break;
        case EventKind.access:
            runAccess(e.request);
            break;
        case EventKind.dismissed:
            if (Shown* s = shownWith(e.surface))
            {
                s.popup.close();
            }
            requestFrame();
            break;
        }
    }

    /// Ends a drag over the window, running `onFileLeave`.
    private void endFileHover()
    {
        if (fileOver == false)
        {
            return;
        }
        fileOver = false;
        if (onFileLeave !is null)
        {
            onFileLeave();
            requestFrame();
        }
    }

    /// Sets `at` to the position of `e` in logical window coordinates. False if it came from a popup window
    /// closed since.
    private bool fromSurface(ref const Event e, out Point at)
    {
        Point p = e.pos;
        if (e.surface != 0)
        {
            Shown* s = shownWith(e.surface);
            if (s is null)
            {
                return false;
            }
            p = p + s.at.pos;
        }
        at = Point(p.x / scale, p.y / scale);
        return true;
    }

    /// Deepest node under `p` that a popup does not block, or null.
    private Node reachableAt(Point p)
    {
        Node hit = tree.root.hitTest(p, Point(0, 0));
        return tree.root.blocks(hit) ? null : hit;
    }

    /// Deepest interactive node under `p` that a popup does not block, or null.
    private Node interactiveAt(Point p)
    {
        for (Node n = reachableAt(p); n !is null; n = n.parent)
        {
            if (n.interactive)
            {
                return n;
            }
        }
        return null;
    }

    /// Changes the hovered node, sending leave and enter.
    private void setHover(Node n)
    {
        if (n is hoverNode)
        {
            return;
        }
        Node old = hoverNode;
        hoverNode = n;
        moveHoverInside(old, n);
        if (old !is null)
        {
            old.hovered = false;
            old.markNeedsPaint();
            PointerEvent leave = PointerEvent(PointerKind.leave, mouse);
            old.onPointer(leave);
        }
        if (n !is null)
        {
            n.hovered = true;
            n.markNeedsPaint();
            PointerEvent enter = PointerEvent(PointerKind.enter, mouse);
            n.onPointer(enter);
        }
    }

    /// Moves `hoverInside` from `old` and its ancestors to `n` and its ancestors, repainting interactive nodes
    /// whose flag changes.
    private void moveHoverInside(Node old, Node n)
    {
        /// True if `a` is `d` or holds it.
        static bool holds(Node a, Node d)
        {
            for (; d !is null; d = d.parent)
            {
                if (d is a)
                {
                    return true;
                }
            }
            return false;
        }

        for (Node a = old; a !is null; a = a.parent)
        {
            if (a.hoverInside && holds(a, n) == false)
            {
                a.hoverInside = false;
                if (a.interactive)
                {
                    a.markNeedsPaint();
                }
            }
        }
        for (Node a = n; a !is null; a = a.parent)
        {
            if (a.hoverInside == false)
            {
                a.hoverInside = true;
                if (a.interactive)
                {
                    a.markNeedsPaint();
                }
            }
        }
    }

    /// Hover update and move delivery, to the captured node while a button is held. A press a drag scroller may
    /// take goes to it once it moved far enough, and a held press gets nothing until then.
    private void pointerMoved()
    {
        if ((holding || (mayTake && captureNode !is null)) && decideDrag())
        {
            return;
        }
        PointerEvent move = PointerEvent(PointerKind.move, mouse, 0, 0, 0, source, pointerTime);
        if (captureNode !is null)
        {
            bool inside = captureNode.bounds.contains(mouse);
            if (inside != captureNode.hovered)
            {
                captureNode.hovered = inside;
                captureNode.markNeedsPaint();
            }
            captureNode.onPointer(move);
            showCursor(captureNode.cursor);
            return;
        }
        setHover(interactiveAt(mouse));
        if (sliding == false)
        {
            tooltips.pointer(reachableAt(mouse), mouse);
        }
        if (hoverNode !is null)
        {
            hoverNode.onPointer(move);
        }
        showCursor(hoverNode is null ? CursorShape.arrow : hoverNode.cursor);
    }

    /// Handles a press: closes popups it is outside of, catches a fling or holds a left press back for a drag
    /// scroller, else delivers it. A right press that closed popups goes on, so it can open another context menu.
    private void press(PointerEvent e)
    {
        sliding = false;
        holding = false;
        mayTake = false;
        longArmed = false;
        tooltips.hush();
        Node under = tree.root.hitTest(e.pos, Point(0, 0));
        if (tree.root.pressOutside(under) && (e.button != 3 || tree.root.blocks(under)))
        {
            setHover(interactiveAt(e.pos));
            return;
        }
        Node[] path;
        for (Node n = reachableAt(e.pos); n !is null; n = n.parent)
        {
            path ~= n;
        }
        foreach (Node n; path)
        {
            n.onPressInside(e.pos);
        }
        bool holds = path.any!((Node n) => n.hasContextMenu || n.longPress);
        if (e.button == 1 && e.source != PointerSource.mouse && holds)
        {
            longArmed = true;
            longFrom = e;
            requestFrameAt(e.time + millis(tree.style!ScrollStyle().longPress));
        }
        if (e.button == 1 && holdPress(e))
        {
            return;
        }
        deliverPress(e);
    }

    /// Gives left press `e` to a fling under it, or holds it back while a drag scroller under it may take it.
    /// True if the press goes no further for now. A press on a node keeping drags is not held, but may still be
    /// taken. One on a scroll bar is neither.
    private bool holdPress(ref PointerEvent e)
    {
        pressAt = e.pos;
        bool scrolls;
        for (Node n = reachableAt(e.pos); n !is null; n = n.parent)
        {
            DragScroller d = cast(DragScroller) n;
            if (d is null)
            {
                continue;
            }
            if (d.catchFling(e.pos, e.time))
            {
                setHover(null);
                captureNode = n;
                n.pressed = true;
                return true;
            }
            bool onBar;
            scrolls = d.scrollsDrag(e.source, e.pos, onBar) || scrolls;
            if (onBar)
            {
                return false;
            }
        }
        if (scrolls == false)
        {
            return false;
        }
        mayTake = true;
        Node target = interactiveAt(e.pos);
        if (target !is null && target.drags != DragAxes.none)
        {
            return false;
        }
        holding = true;
        held = e;
        ScrollStyle s = tree.style!ScrollStyle();
        requestFrameAt(e.time + millis(s.pressDelay));
        return true;
    }

    /// Once the press moved `ScrollStyle.dragStart`, gives the drag to the innermost drag scroller that can scroll
    /// that way, or else along that axis at all, and cancels the press its node had. The scroll starts from where
    /// the pointer crossed that distance. Else delivers a held press.
    /// True if the move goes no further: the press is still held or a scroller took it.
    private bool decideDrag()
    {
        Point moved = mouse - pressAt;
        float far = max(abs(moved.x), abs(moved.y));
        float start = tree.style!ScrollStyle().dragStart;
        if (far < start)
        {
            return holding;
        }
        mayTake = false;
        DragAxes way = abs(moved.y) > abs(moved.x) ? DragAxes.vertical : DragAxes.horizontal;
        Node had = holding ? null : captureNode;
        Node from = had is null ? reachableAt(pressAt) : had;
        PointerSource by = holding ? held.source : source;
        Point crossed = Point(pressAt.x + moved.x * start / far, pressAt.y + moved.y * start / far);
        if (had is null || (had.drags & way) == 0)
        {
            foreach (bool edge; [false, true])
            {
                for (Node n = from; n !is null; n = n.parent)
                {
                    DragScroller d = cast(DragScroller) n;
                    bool onBar;
                    if (d is null || d.scrollsDrag(by, pressAt, onBar) == false
                        || d.takeDrag(crossed, moved, edge, pointerTime) == false)
                    {
                        continue;
                    }
                    if (had !is null)
                    {
                        PointerEvent c = PointerEvent(PointerKind.cancel, mouse, 1, 0, 0, source, pointerTime);
                        had.onPointer(c);
                        had.pressed = false;
                        had.markNeedsPaint();
                    }
                    holding = false;
                    captureNode = n;
                    n.pressed = true;
                    PointerEvent move = PointerEvent(PointerKind.move, mouse, 0, 0, 0, source, pointerTime);
                    n.onPointer(move);
                    return true;
                }
            }
        }
        if (holding)
        {
            holding = false;
            deliverPress(held);
        }
        return false;
    }

    /// Runs a touch or pen press held still, cancelling the press its node had: `Node.onLongPress` on the nodes
    /// under it that hear it, then the context menu unless one took it.
    private void openHeldMenu()
    {
        if (sliding)
        {
            return;
        }
        holding = false;
        mayTake = false;
        if (captureNode !is null)
        {
            PointerEvent c = PointerEvent(PointerKind.cancel, mouse, 1, 0, 0, source, pointerTime);
            captureNode.onPointer(c);
            captureNode.pressed = false;
            captureNode.markNeedsPaint();
            captureNode = null;
        }
        for (Node n = reachableAt(longFrom.pos); n !is null; n = n.parent)
        {
            if (n.longPress && n.onLongPress(longFrom.pos))
            {
                return;
            }
        }
        for (Node n = reachableAt(longFrom.pos); n !is null; n = n.parent)
        {
            if (n.onContextMenu(longFrom.pos, false))
            {
                break;
            }
        }
    }

    /// Delivers a press: focus, a context menu for the right button, then capture and delivery.
    private void deliverPress(PointerEvent e)
    {
        Node hit = reachableAt(e.pos);
        for (Node n = hit; n !is null; n = n.parent)
        {
            if (n.focusable || n.keepFocus || n.parent is null)
            {
                if (n.keepFocus == false)
                {
                    setKeyboardFocus(false);
                    setFocus(n.focusable ? n : null);
                }
                break;
            }
        }
        for (Node n = e.button == 3 ? hit : null; n !is null; n = n.parent)
        {
            if (n.onContextMenu(e.pos, false))
            {
                setHover(interactiveAt(e.pos));
                return;
            }
        }
        Node target = interactiveAt(e.pos);
        setHover(target);
        if (target is null)
        {
            return;
        }
        captureNode = target;
        target.pressed = true;
        target.onPointer(e);
        target.markNeedsPaint();
    }

    /// Handles a release: delivered to the captured node, or after a slide to the node under it, then hover is
    /// recomputed. A slid release over nothing interactive closes the popups it is outside of, as a press would.
    private void release(ref PointerEvent e)
    {
        longArmed = false;
        if (holding)
        {
            holding = false;
            deliverPress(held);
        }
        mayTake = false;
        if (sliding)
        {
            Node t = interactiveAt(mouse);
            sliding = false;
            setHover(t);
            if (t !is null)
            {
                t.onPointer(e);
            }
            else
            {
                tree.root.pressOutside(tree.root.hitTest(e.pos, Point(0, 0)));
            }
            pointerMoved();
            return;
        }
        Node c = captureNode;
        captureNode = null;
        if (c !is null)
        {
            c.onPointer(e);
            c.pressed = false;
            c.markNeedsPaint();
        }
        if (c !is null && c.hovered && c.bounds.contains(mouse) == false)
        {
            c.hovered = false;
            c.markNeedsPaint();
            moveHoverInside(hoverNode, null);
            hoverNode = null;
        }
        pointerMoved();
    }

    /// Wheel event to the deepest node under it, then its parents until one handles it. A diagonal touchpad
    /// scroll goes out as a vertical and a horizontal event, so a table inside a scroll view gets its share.
    private void routeWheel(WheelEvent e)
    {
        tooltips.hush();
        if (e.dx != 0 && e.dy != 0)
        {
            routeWheel(WheelEvent(e.pos, 0, e.dy, e.mods));
            routeWheel(WheelEvent(e.pos, e.dx, 0, e.mods));
            return;
        }
        for (Node n = reachableAt(e.pos); n !is null; n = n.parent)
        {
            if (n.onWheel(e))
            {
                break;
            }
        }
    }

    /// Key press for the focused node, or for the grabbing popup or the app root when nothing has focus.
    private void key(KeyEvent e)
    {
        tooltips.hush();
        // NOTE: some platforms still send the keys an input method uses, such as Enter to commit.
        if (composing.length > 0)
        {
            return;
        }
        Node start = focusNode;
        if (start is null)
        {
            start = tree.root.grabber();
        }
        routeKey(start is null ? tree.content : start, e);
    }

    /// Lets go of the held press: hover follows the pointer and the node under it gets the release.
    void slidePress()
    {
        if (captureNode is null)
        {
            return;
        }
        captureNode.pressed = false;
        captureNode.markNeedsPaint();
        captureNode = null;
        sliding = true;
    }

    /// Sends a key `from` did not use to its parents, then to the window.
    void passKey(Node from, KeyEvent e)
    {
        if (from.tree is tree)
        {
            routeKey(from.parent, e);
        }
    }

    /// Key press for `start` and its parents, then Tab, Escape for popups, the context menu keys, nodes
    /// listening to the window unless focus is in a popup that grabs input, and the window's own keys.
    private void routeKey(Node start, ref const KeyEvent e)
    {
        for (Node n = start; n !is null; n = n.parent)
        {
            if (n.onKey(e))
            {
                return;
            }
        }
        if (e.key == Key.tab)
        {
            moveFocus((e.mods & Mod.shift) != 0);
            return;
        }
        if (e.key == Key.escape && tree.root.escape())
        {
            return;
        }
        if ((e.key == Key.menu && e.mods == 0) || (e.key == Key.f10 && e.mods == Mod.shift))
        {
            Node at = focusNode is null ? start : focusNode;
            Rect b = at is null ? Rect.init : at.bounds;
            for (Node n = at; n !is null; n = n.parent)
            {
                if (n.onContextMenu(Point(b.x, b.y + min(b.h, 32f)), true))
                {
                    return;
                }
            }
        }
        if (tree.root.holdsKeys(focusNode) == false)
        {
            foreach (WindowKeys w; tree.windowKeys.dup)
            {
                if (w.windowKey(e))
                {
                    return;
                }
            }
        }
        if (e.key == Key.f12)
        {
            import std.datetime.systime : Clock;
            import std.format : format;

            screenshotPath = format("dentrite-%s.png", Clock.currTime.toISOString()[0 .. 15]);
            requestFrame();
            return;
        }
        if (e.key == Key.r && (e.mods & Mod.ctrl) != 0)
        {
            reloadTheme();
            return;
        }
        if (e.key == Key.escape && focusNode !is null)
        {
            setFocus(null);
        }
    }

    /// Moves focus to the next or previous stop inside the focused node, else to the next or previous focusable
    /// node in tree order, inside the grabbing popup if one is open, and scrolls it into view at the next frame.
    private void moveFocus(bool backward)
    {
        FocusScope inner = cast(FocusScope) focusNode;
        if (inner !is null && inner.stepFocus(backward))
        {
            setKeyboardFocus(true);
            revealFocus = true;
            requestFrame();
            return;
        }
        Node[] order;
        void walk(Node n)
        {
            if (n.tabStop && n.size.w > 0 && n.size.h > 0)
            {
                order ~= n;
            }
            foreach (Node c; n.children)
            {
                walk(c);
            }
        }

        Popup trap = tree.root.grabber();
        walk(trap is null ? tree.root : trap);
        if (order.length == 0)
        {
            return;
        }
        size_t at = order.length;
        foreach (size_t i, Node n; order)
        {
            if (n is focusNode)
            {
                at = i;
            }
        }
        size_t next;
        if (at == order.length)
        {
            next = backward ? order.length - 1 : 0;
        }
        else
        {
            next = backward ? (at + order.length - 1) % order.length : (at + 1) % order.length;
        }
        setKeyboardFocus(true);
        setFocus(order[next]);
        tooltips.focus(order[next]);
        inner = cast(FocusScope) order[next];
        if (inner !is null)
        {
            inner.enterFocus(backward);
        }
        revealFocus = true;
        requestFrame();
    }

    /// Reloads the theme file of every window, see `App.reloadTheme`.
    void reloadTheme()
    {
        app.reloadTheme();
    }

    /// Restyles every window with theme `t`, see `App.setTheme`.
    void setTheme(Theme t)
    {
        app.setTheme(t);
    }

    /// Replaces the font of slot `kind` in every window, see `App.setFont`.
    void setFont(FontKind kind, immutable(ubyte)[] data)
    {
        app.setFont(kind, data);
    }

    /// Replaces the font of slot `kind` in every window with font file `path`, see `App.setFont`.
    void setFont(FontKind kind, string path)
    {
        app.setFont(kind, path);
    }

    /// System light or dark appearance, see `App.colorScheme`.
    ColorScheme colorScheme()
    {
        return app.colorScheme();
    }

    /// Handler for typed text the focused node did not take, or null.
    void delegate(string) onText()
    {
        return textHandler;
    }

    /// Sets a handler for typed text the focused node did not take, such as keys bound to characters, or null.
    /// While set, platform text input stays on with focus outside text fields, which may show an on-screen
    /// keyboard. Not called while a popup holds the keys.
    void onText(void delegate(string) fn)
    {
        textHandler = fn;
        syncTextInput();
    }

    /// Sets the platform cursor for `shape` if it changed or another window set it since.
    private void showCursor(CursorShape shape)
    {
        if (shape == cursorShown && cursorStale == false)
        {
            return;
        }
        cursorShown = shape;
        cursorStale = false;
        platformWindow.setCursor(shape);
    }

    /// Physical pixels per logical pixel.
    float pixelScale() const
    {
        return scale;
    }

    /// Logical window size.
    Size logicalSize() const
    {
        return tree.viewport;
    }

    /// Node a screen reader would see with `role` and `label`, as the tree was last laid out, or null. Finds
    /// controls by what they show for tests: `h.find(Role.button, "Save")`.
    const(AccessNode)* find(Role role, string label)
    {
        if (lookup is null)
        {
            lookup = new AccessTree;
        }
        lookup.update(tree, focusNode, true);
        return lookup.find(role, label);
    }

    /// Clicks the middle of the node `find` gives for `role` and `label`, then renders a frame. Asserts it is
    /// there.
    void click(Role role, string label)
    {
        import std.format : format;

        const(AccessNode)* n = find(role, label);
        assert(n !is null, format("no %s named \"%s\"", role, label));
        Point p = Point(n.bounds.x + n.bounds.w / 2, n.bounds.y + n.bounds.h / 2);
        inject(PointerKind.move, p);
        inject(PointerKind.down, p);
        inject(PointerKind.up, p);
        frame();
    }

    /// Sends a synthetic pointer event for `button` at logical `p` with `mods` held, as platform input would,
    /// for scripted runs. `time` defaults to now.
    void inject(PointerKind kind, Point p, ubyte clicks = 1, ubyte button = 1, ubyte mods = 0,
        PointerSource from = PointerSource.mouse, MonoTime time = MonoTime.init)
    {
        pointerIn = true;
        pointer(kind, p, clicks, button, mods, from, time);
    }

    /// Handles pointer event `kind` at logical `p` from device `from` at `time`, now when unset.
    private void pointer(PointerKind kind, Point p, ubyte clicks, ubyte button, ubyte mods, PointerSource from,
        MonoTime time)
    {
        mouse = p;
        source = from;
        pointerTime = time == MonoTime.init ? MonoTime.currTime : time;
        final switch (kind)
        {
        case PointerKind.move:
        case PointerKind.enter:
        case PointerKind.leave:
            pointerIn = true;
            Point moved = p - longFrom.pos;
            if (longArmed && max(abs(moved.x), abs(moved.y)) >= tree.style!ScrollStyle().dragStart)
            {
                longArmed = false;
            }
            pointerMoved();
            break;
        case PointerKind.down:
            press(PointerEvent(PointerKind.down, p, button, clicks, mods, from, pointerTime));
            break;
        case PointerKind.up:
            PointerEvent up = PointerEvent(PointerKind.up, p, button, clicks, mods, from, pointerTime);
            release(up);
            break;
        case PointerKind.cancel:
            break;
        }
    }

    /// Shows a native file dialog over the window: `w.fileDialog(FileDialogKind.open, (string[] paths) { ... },
    /// [FileFilter("D source", "d")])`. `done` runs later on the UI thread with the chosen paths, none if
    /// cancelled, or at once with none when the platform has no file dialogs.
    void fileDialog(FileDialogKind kind, void delegate(string[]) done, const(FileFilter)[] filters = null,
        string start = null)
    {
        FileDialogs d = cast(FileDialogs) platformWindow;
        if (d is null)
        {
            d = cast(FileDialogs) platform;
        }
        if (d !is null)
        {
            d.fileDialog(kind, filters, start, done);
        }
        else
        {
            done(null);
        }
    }

    /// Opens `url` with the system's handler, see `App.openUrl`.
    bool openUrl(string url)
    {
        return app.openUrl(url);
    }

    /// Window size in logical pixels, tracked by the running effect or computed.
    Size windowSize()
    {
        return sizeNow.get;
    }

    /// True while the window size is within the ranges, bounds included, in logical pixels. Its readers rerun
    /// only when the window crosses a bound.
    Computed!bool breakpoint(float minW = 0, float maxW = float.infinity, float minH = 0,
        float maxH = float.infinity)
    {
        return computed(() {
            Size s = sizeNow.get;
            return s.w >= minW && s.w <= maxW && s.h >= minH && s.h <= maxH;
        });
    }

    /// Window title.
    string title()
    {
        return access.title;
    }

    /// Sets the window title, which also names the window for screen readers.
    void title(string t)
    {
        access.title = t;
        if (WindowControl c = cast(WindowControl) platformWindow)
        {
            c.setTitle(t);
        }
        requestFrame();
    }

    /// Pointers that scroll views left at `ScrollDrag.inherit` by dragging their content.
    ScrollDrag scrollDrag()
    {
        return tree.scrollDrag;
    }

    /// Sets the pointers that drag views left at `inherit`, at any time: `always` while a VR overlay drives the
    /// mouse, `touch` after. Starts as `WindowOptions.scrollDrag`.
    void scrollDrag(ScrollDrag mode)
    {
        tree.scrollDrag = mode;
    }

    /// True unless the window is hidden, always true when the platform cannot hide it.
    bool visible()
    {
        WindowControl c = cast(WindowControl) platformWindow;
        return c is null || c.visible();
    }

    /// Shows the window, unminimized and raised, or hides it. Hiding ends presses, input method text and hover, as
    /// losing focus and the pointer does.
    void visible(bool on)
    {
        WindowControl c = cast(WindowControl) platformWindow;
        if (c is null || (on == false && c.visible() == false))
        {
            return;
        }
        if (on == false)
        {
            Event left = Event(EventKind.pointerLeft);
            Event blur = Event(EventKind.focusLost);
            handle(blur);
            handle(left);
        }
        c.setVisible(on);
        hidden = on == false;
        updateSize();
    }

    /// Sets the smallest size the user can resize the window to, in logical pixels, 0 for no limit.
    void minimumSize(int w, int h)
    {
        if (WindowControl c = cast(WindowControl) platformWindow)
        {
            c.setMinimumSize(w, h);
        }
    }

    /// Sets the icon the window system shows for the window, such as one from `loadImage`. Several sizes let
    /// it pick the closest: `h.icon(icon16, icon32, icon64)`.
    void icon(Image[] sizes...)
    {
        assert(sizes.length > 0 && sizes.all!(i => i !is null && i.empty == false));
        if (WindowControl c = cast(WindowControl) platformWindow)
        {
            c.setIcon(sizes.dup);
        }
    }

    /// Sends a synthetic wheel scroll of `dy` and `dx` logical pixels at logical `p`, for scripted runs.
    void injectWheel(Point p, float dy, float dx = 0, ubyte mods = 0)
    {
        mouse = p;
        pointerIn = true;
        routeWheel(WheelEvent(p, dx, dy, mods));
    }

    /// Sends synthetic text, as platform text input would, for scripted runs.
    void injectText(string s)
    {
        Event e = { kind: EventKind.text, text: s };
        handle(e);
    }

    /// Sends synthetic input method text, as a platform would while composing, for scripted runs.
    void injectCompose(string s, int start = -1, int length = -1)
    {
        Event e = { kind: EventKind.compose, text: s, start: start, length: length };
        handle(e);
    }

    /// Sends a synthetic key press, for scripted runs.
    void injectKey(uint k, ubyte m = 0)
    {
        Event e = { kind: EventKind.key, key: k, mods: m };
        handle(e);
    }
}

/// Byte offset of code point `n` in `s`, clamped to its length.
private size_t byteOffset(string s, int n)
{
    size_t i;
    foreach (int k; 0 .. n)
    {
        if (i >= s.length)
        {
            break;
        }
        i += stride(s, i);
    }
    return min(i, s.length);
}

// Headless host: frames draw in software, platform events click a button, Tab and typing reach a text box,
// and `run` returns on close.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.textbox : TextBox, textBox;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100, 2);
    SoftwareRenderer r = new SoftwareRenderer;
    Host h = new Host(p, r, o);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    Signal!string name = signal("");
    Button b = button("Go", () { ++clicks; });
    TextBox t = textBox(name);
    h.setRoot(column()(b, t));
    h.frame();
    assert(r.width == 400 && r.height == 200 && p.presented == 1);
    Color bg = WindowStyle.init.background;
    assert(r.pixels[$ - 1] == (bg.r | bg.g << 8 | bg.b << 16 | 0xff000000), "background below the content");

    Point at = Point((b.bounds.x + b.bounds.w / 2) * 2, (b.bounds.y + b.bounds.h / 2) * 2);
    Event move = { kind: EventKind.pointer, pointer: PointerKind.move, pos: at };
    Event down = { kind: EventKind.pointer, pointer: PointerKind.down, pos: at, button: 1, clicks: 1 };
    Event up = { kind: EventKind.pointer, pointer: PointerKind.up, pos: at, button: 1, clicks: 1 };
    Event tab = { kind: EventKind.key, key: Key.tab };
    Event text = { kind: EventKind.text, text: "hi" };
    p.queue = [move, down, up, tab, text, Event(EventKind.close)];
    h.run();
    assert(clicks == 1);
    assert(p.cursor == CursorShape.pointer);
    assert(h.focused is t && h.focusVisible && p.textOn);
    assert(name.peek == "hi");

    string[][] got;
    p.fileAnswers = [["/tmp/a.txt", "/tmp/b.txt"]];
    h.fileDialog(FileDialogKind.openMany, (string[] paths) { got ~= paths; }, [FileFilter("Text", "txt")]);
    h.fileDialog(FileDialogKind.save, (string[] paths) { got ~= paths; });
    assert(got.length == 0, "answers arrive as events");
    p.queue ~= Event(EventKind.close);
    h.running = true;
    h.run();
    assert(got == [["/tmp/a.txt", "/tmp/b.txt"], []] && p.fileAsks == [FileDialogKind.openMany,
        FileDialogKind.save]);
}

// `onCloseRequest` can keep the window open on close, a quit stops regardless.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(100, 100, 1), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int asked;
    bool allow;
    h.onCloseRequest = () { ++asked; return allow; };
    Event close = Event(EventKind.close);
    Event quit = Event(EventKind.quit);
    h.handle(close);
    assert(asked == 1 && h.running);
    h.handle(quit);
    assert(asked == 1 && h.running == false);
    h.running = true;
    allow = true;
    h.handle(close);
    assert(asked == 2 && h.running == false);
}

// Window setters reach the platform, the title names the window for screen readers, and hiding ends a press
// and stops frames until the window shows or is exposed.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.image : Image;
    import dentrite.widgets.button : Button, button;

    WindowOptions o;
    o.title = "One";
    o.accessibility = true;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Button b = button("Go", () {});
    h.setRoot(column()(b));
    p.listening = AccessDemand.full;
    h.frame();
    assert(h.title == "One" && h.access.find(Role.window, "One") !is null);

    h.title = "Two";
    h.frame();
    assert(p.title == "Two" && h.access.find(Role.window, "Two") !is null);

    h.minimumSize(320, 200);
    assert(p.minSize == [320, 200]);
    Image img = new Image(2, 2);
    Image big = new Image(4, 4);
    h.icon(img, big);
    assert(p.icon == [img, big]);

    Point at = Point(b.bounds.x + 4, b.bounds.y + 4);
    h.inject(PointerKind.down, at);
    assert(b.pressed);
    h.visible = false;
    assert(h.visible == false && p.hidden && b.pressed == false && b.hovered == false);
    assert(h.hidden, "frames wait while hidden");
    h.visible = true;
    assert(h.visible && h.hidden == false);

    Event e = Event(EventKind.hidden);
    h.handle(e);
    assert(h.hidden, "minimized");
    e.kind = EventKind.exposed;
    h.handle(e);
    assert(h.hidden == false && h.clock.requested, "exposed draws again");
}

// A frame-start hook changing the tree asks for no new frame, `requestFrame` in it does.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.label : label;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(200, 100), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Signal!string s = signal("a");
    h.setRoot(label(() => s.get));
    h.frame();
    bool again;
    h.beforeFrame ~= () {
        s.set(s.peek ~ "a");
        if (again)
        {
            h.requestFrame();
        }
    };
    h.frame();
    assert(h.clock.requested == false);
    again = true;
    h.frame();
    assert(h.clock.requested);
}

// Alarms run while the window is hidden with no frame drawn, skip once cancelled, and run at the start of a
// frame drawn by hand, its tree changes in that frame.
unittest
{
    import core.time : msecs;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.label : label;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Signal!string s = signal("a");
    h.setRoot(label(() => s.get));
    h.frame();
    h.visible = false;
    int ran;
    Alarm off = h.after(msecs(1), () { ran += 10; });
    off.cancel();
    h.after(msecs(2), () {
        ++ran;
        s.set("b");
        h.running = false;
    });
    int drawn = p.presented;
    h.run();
    assert(ran == 1 && p.presented == drawn && h.clock.requested, "ran hidden, the change waits for a frame");

    h.visible = true;
    h.frame();
    h.at(MonoTime.currTime, () { s.set("c"); });
    h.frame();
    assert(s.peek == "c" && h.clock.requested == false);
}

// A wake from another thread runs the hooks while the window is hidden, so a box drains with no frame drawn,
// and a hook asking for a frame does not make the loop spin.
unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.mailbox : Queue;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.label : label;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Signal!string s = signal("");
    h.setRoot(label(() => s.get));
    h.frame();
    h.visible = false;
    Queue!string box = new Queue!string;
    int runs;
    h.beforeFrame ~= () {
        ++runs;
        foreach (string line; box.drain())
        {
            s.set(s.peek ~ line);
        }
        h.requestFrame();
        if (runs == 1)
        {
            h.after(msecs(20), () { h.running = false; });
        }
    };
    Thread t = new Thread(() { box.post("ab"); });
    int drawn = p.presented;
    t.start();
    h.run();
    t.join();
    assert(s.peek == "ab" && p.presented == drawn, "drained hidden");
    assert(runs == 2, "once for the wake and once for the alarm");
}

// A popup past the window edge draws in a window of its own, with room for its shadow, and not in the main frame.
// Its input maps back to window coordinates, events from a closed one are dropped, and a system dismissal closes
// it.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform, HeadlessPopup;
    import dentrite.overlay : popup;
    import dentrite.widgets.button : Button, button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100, 2);
    p.screen = Rect(-400, -200, 1200, 800);
    SoftwareRenderer r = new SoftwareRenderer;
    Host h = new Host(p, r, o);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    Button item = button("Item", () { ++clicks; });
    Popup menu = popup()(item);
    h.setRoot(column()());
    menu.openAt(h.tree, Point(190, 90));
    h.frame();
    assert(menu.windowed && p.popups.length == 1);
    HeadlessPopup w = p.popups[0];
    Rect b = menu.bounds;
    assert(b.x == 190 && b.y == 90 && w.input && w.parent is null);
    assert(w.at == Rect(380 - 32, 180 - 32, ceil(b.w * 2) + 64, b.h * 2 + 64) && w.drawn == 1 && w.batches > 0);
    Color bg = WindowStyle.init.background;
    assert(r.pixels[$ - 1] == (bg.r | bg.g << 8 | bg.b << 16 | 0xff000000), "not in the main frame");

    Point local = Point((item.bounds.x + item.bounds.w / 2) * 2 - w.at.x, (item.bounds.y + 4) * 2 - w.at.y);
    Event down = { kind: EventKind.pointer, surface: 1, pointer: PointerKind.down, pos: local, button: 1, clicks: 1 };
    Event up = { kind: EventKind.pointer, surface: 1, pointer: PointerKind.up, pos: local, button: 1, clicks: 1 };
    h.handle(down);
    h.handle(up);
    assert(clicks == 1);

    Event dismissed = { kind: EventKind.dismissed, surface: 1 };
    h.handle(dismissed);
    assert(menu.isOpen == false);
    h.frame();
    assert(w.closed);
    h.handle(down);
    h.handle(up);
    assert(clicks == 1, "dropped");

    menu.openAt(h.tree, Point(10, 10));
    h.frame();
    assert(menu.windowed == false && p.popups.length == 1, "fits");
    menu.openAt(h.tree, Point(190, 90));
    h.frame();
    assert(p.popups.length == 2 && p.popups[1].id == 2);
    h.close();
    assert(p.popups[1].closed);
}

// Breakpoints follow resizes in logical pixels, bounds included, and rerun their readers only on crossing one.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.signals : Scope, effect, effectScope;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(500, 300, 2);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    assert(h.windowSize == Size(500, 300));
    void resize(int w, int hh)
    {
        p.size = Metrics(w * 2, hh * 2, 2);
        Event e = Event(EventKind.resized);
        h.handle(e);
    }

    bool narrow;
    bool tall;
    int runs;
    scope Scope s = effectScope(() {
        Computed!bool n = h.breakpoint(maxW: 600);
        Computed!bool t = h.breakpoint(minH: 400);
        effect(() { narrow = n.get; tall = t.get; ++runs; });
    });
    assert(narrow && tall == false && runs == 1);
    resize(600, 300);
    assert(narrow && runs == 1);
    resize(601, 300);
    assert(narrow == false && runs == 2);
    resize(900, 350);
    assert(runs == 2);
    resize(900, 400);
    assert(narrow == false && tall && runs == 3);
    resize(320, 200);
    assert(narrow && tall == false && runs == 4);
    assert(h.windowSize == Size(320, 200));
}

// A touch swipe on a button in a scroll view scrolls from where it passed `dragStart` without pressing the button,
// a tap clicks it, and the mouse drags only with `ScrollDrag.always`, unless held still first.
unittest
{
    import core.time : msecs;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : ScrollView, column, scroll;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.widgets.button : button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(200, 100, 1), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    Node[] rows;
    foreach (int i; 0 .. 20)
    {
        rows ~= button("Row", () { ++clicks; });
    }
    ScrollView sv = scroll()(column()(rows));
    h.setRoot(sv);
    h.frame();
    MonoTime t = MonoTime.currTime;
    void touch(PointerKind k, float y, int ms)
    {
        h.inject(k, Point(50, y), 1, 1, 0, PointerSource.touch, t + ms.msecs);
    }

    touch(PointerKind.down, 50, 0);
    touch(PointerKind.move, 45, 10);
    assert(sv.scrollY == 0 && h.captureNode is null, "held back below dragStart");
    touch(PointerKind.move, 30, 20);
    assert(sv.scrollY == 12 && h.captureNode is sv, "taken, scrolled past where it crossed dragStart");
    touch(PointerKind.move, 10, 30);
    assert(sv.scrollY == 32);
    touch(PointerKind.up, 10, 230);
    h.frame();
    assert(clicks == 0 && sv.scrollY == 32, "no click, and no fling after a pause");

    touch(PointerKind.down, 50, 300);
    touch(PointerKind.move, 47, 310);
    touch(PointerKind.up, 47, 320);
    assert(clicks == 1, "a tap clicks");

    h.inject(PointerKind.move, Point(50, 50));
    h.inject(PointerKind.down, Point(50, 50));
    h.inject(PointerKind.move, Point(50, 10));
    h.inject(PointerKind.up, Point(50, 10));
    assert(sv.scrollY == 32 && clicks == 1, "the mouse does not drag by default");
    sv.drag = ScrollDrag.always;
    void mouse(PointerKind k, float y, int ms)
    {
        h.inject(k, Point(50, y), 1, 1, 0, PointerSource.mouse, t + ms.msecs);
    }

    mouse(PointerKind.down, 50, 400);
    mouse(PointerKind.move, 10, 410);
    mouse(PointerKind.up, 10, 610);
    assert(sv.scrollY == 32 + 40 - 8 && clicks == 1, "no fling after a pause");

    sv.drag = ScrollDrag.inherit;
    h.scrollDrag = ScrollDrag.always;
    MonoTime past = MonoTime.currTime - 1000.msecs;
    h.inject(PointerKind.down, Point(50, 50), 1, 1, 0, PointerSource.mouse, past);
    h.frame();
    assert(h.captureNode !is sv && h.captureNode.pressed, "delivered after the delay");
    h.inject(PointerKind.move, Point(50, 10));
    assert(sv.scrollY == 64 && h.captureNode !is sv, "a mouse press held still keeps its drag");
    h.inject(PointerKind.up, Point(50, 10));
}

// A touch press held past `pressDelay` reaches the button, a drag after it cancels the press and scrolls. A quick
// release flings on through the next frames, and a press during the fling only stops it.
unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : ScrollView, column, scroll;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.widgets.button : Button, button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(200, 100, 1), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    Button[] rows;
    foreach (int i; 0 .. 40)
    {
        rows ~= button("Row", () { ++clicks; });
    }
    ScrollView sv = scroll()(column()(cast(Node[]) rows));
    h.setRoot(sv);
    h.frame();
    MonoTime t = MonoTime.currTime - 1000.msecs;
    void touch(PointerKind k, float y, int ms)
    {
        h.inject(k, Point(50, y), 1, 1, 0, PointerSource.touch, t + ms.msecs);
    }

    touch(PointerKind.down, 50, 0);
    h.frame();
    Button held = cast(Button) h.captureNode;
    assert(held !is null && held.pressed, "delivered after the delay");
    touch(PointerKind.move, 40, 300);
    touch(PointerKind.move, 30, 310);
    assert(held.pressed == false && h.captureNode is sv && sv.scrollY == 12);
    touch(PointerKind.up, 30, 320);
    assert(clicks == 0);

    touch(PointerKind.down, 90, 900);
    foreach (int i; 1 .. 5)
    {
        touch(PointerKind.move, 90 - i * 20, 900 + i * 10);
    }
    float dragged = sv.scrollY;
    touch(PointerKind.up, 10, 940);
    assert(sv.scrollY == dragged);
    Thread.sleep(20.msecs);
    h.frame();
    assert(sv.scrollY > dragged, "flinging");
    float flung = sv.scrollY;
    h.inject(PointerKind.down, Point(50, 50), 1, 1, 0, PointerSource.touch);
    h.inject(PointerKind.up, Point(50, 50), 1, 1, 0, PointerSource.touch);
    Thread.sleep(20.msecs);
    h.frame();
    assert(clicks == 0 && sv.scrollY == flung, "the press stopped the fling and clicked nothing");
}

// A touch drag on an inner scroll view's bar moves its thumb and leaves the outer view alone. On the content,
// it scrolls the inner view.
unittest
{
    import core.time : msecs;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : CrossAlign, ScrollView, column, scroll, sized;
    import dentrite.headless : HeadlessPlatform;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(200, 200, 1), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    ScrollView inner = scroll()(new Fixed(Size(10, 1000)));
    Node page = column(cross: CrossAlign.start)(sized(w: 150, h: 100)(inner), new Fixed(Size(10, 1000)));
    ScrollView outer = scroll()(page);
    h.setRoot(outer);
    h.frame();
    MonoTime t = MonoTime.currTime;
    int ms;
    void touch(PointerKind k, float x, float y)
    {
        ms += 200;
        h.inject(k, Point(x, y), 1, 1, 0, PointerSource.touch, t + ms.msecs);
    }

    touch(PointerKind.down, 145, 5);
    touch(PointerKind.move, 145, 30);
    touch(PointerKind.up, 145, 30);
    assert(inner.scrollY > 0 && outer.scrollY == 0, "the thumb moved down");
    inner.scrollTo(0);
    touch(PointerKind.down, 50, 80);
    touch(PointerKind.move, 50, 40);
    touch(PointerKind.up, 50, 40);
    assert(inner.scrollY == 40 - 8 && outer.scrollY == 0);
}

// Drops reach `onFileDrop` in logical pixels, the color scheme follows the platform, and typed text nothing
// focused took reaches `onText`, which keeps text input on.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.signals : effect;
    import dentrite.widgets.button : Button, button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100, 2);
    p.scheme = ColorScheme.light;
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Button b = button("Go", () {});
    h.setRoot(b);
    h.frame();

    string[] dropped;
    Point at;
    h.onFileDrop = (string[] paths, Point p) { dropped = paths; at = p; };
    Event drop = Event(EventKind.fileDrop);
    drop.paths = ["/tmp/a.bin", "/tmp/b.bin"];
    drop.pos = Point(40, 60);
    h.handle(drop);
    assert(dropped == ["/tmp/a.bin", "/tmp/b.bin"] && at == Point(20, 30));

    ColorScheme seen;
    effect(() { seen = h.colorScheme; });
    assert(seen == ColorScheme.light);
    p.scheme = ColorScheme.dark;
    Event changed = Event(EventKind.colorScheme);
    h.handle(changed);
    assert(seen == ColorScheme.dark);

    Event typed = Event(EventKind.text);
    typed.text = "[";
    h.handle(typed);
    assert(p.textOn == false, "no text input without a handler");
    string got;
    h.onText = (string s) { got ~= s; };
    assert(p.textOn);
    h.handle(typed);
    h.setFocus(b);
    h.handle(typed);
    assert(got == "[[", "with and without focus");
    h.onText = null;
    assert(p.textOn == false);
}

// `setTheme` restyles and refuses a theme that fails the check, `setFont` lays out at the new font's widths.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.theme : Theme;
    import dentrite.containers : row;
    import dentrite.widgets.label : Label, label;
    import std.exception : assertThrown;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100, 1);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Label l = label("illegal");
    h.setRoot(row()(l));
    h.frame();
    float before = l.bounds.w;
    assertThrown(h.setTheme(new Theme("[window]\nnoSuchField = 1\n", "test")));
    assert(h.theme is null);
    h.setTheme(new Theme("[window]\nbackground = #ff0000\n", "test"));
    h.frame();
    assert(h.theme.style!WindowStyle("").background == Color(0xff, 0, 0, 0xff));

    h.setFont(FontKind.ui, "fonts/JetBrainsMono-Regular.ttf");
    h.frame();
    assert(l.bounds.w > before * 1.2, "mono is wider");
    assertThrown(h.setFont(FontKind.ui, "fonts/missing.ttf"));
}

// A drag over the window reaches `onFileHover` in logical pixels, and leaving or dropping ends it once, before
// `onFileDrop`.
unittest
{
    import std.format : format;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(200, 100, 2), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    h.setRoot(new Fixed(Size(10, 10)));
    h.frame();
    string[] log;
    h.onFileHover = (Point p) { log ~= format("hover %g,%g", p.x, p.y); };
    h.onFileLeave = () { log ~= "leave"; };
    h.onFileDrop = (string[] paths, Point p) { log ~= "drop " ~ paths[0]; };

    Event hover = Event(EventKind.fileHover);
    hover.pos = Point(40, 60);
    h.handle(hover);
    hover.pos = Point(80, 60);
    h.handle(hover);
    Event leave = Event(EventKind.fileLeave);
    h.handle(leave);
    h.handle(leave);
    assert(log == ["hover 20,30", "hover 40,30", "leave"]);

    log = null;
    h.handle(hover);
    Event drop = Event(EventKind.fileDrop);
    drop.paths = ["/tmp/a.bin"];
    drop.pos = Point(80, 60);
    h.handle(drop);
    assert(log == ["hover 40,30", "leave", "drop /tmp/a.bin"]);
}

// A second window shares the app: events reach the window they name, each window draws and keeps its own focus,
// hooks run once a frame, another scale gets its own text system, and closing it, or the main window, closes it.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform, HeadlessWindow;
    import dentrite.widgets.button : Button, button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    WindowOptions o2;
    o2.title = "Two";
    o2.width = 150;
    o2.height = 80;
    o2.scale = 2;
    Host h2 = h.openWindow(o2);
    HeadlessWindow w = p.windows[0];
    assert(h2.app is h.app && h.app.windows == [h, h2]);
    assert(w.title == "Two" && w.size.pixelW == 300 && h2.windowSize == Size(150, 80));
    assert(h2.text !is h.text && h2.text.ppp == 2 && h.text.ppp == 1, "a text system per scale");
    assert(h2.theme is h.theme);

    int one;
    int two;
    int hooks;
    h.beforeFrame ~= () { ++hooks; };
    Button b1 = button("One", () { ++one; });
    Button b2 = button("Two", () { ++two; });
    h.setRoot(column()(b1));
    h2.setRoot(column()(b2));
    h.frame();
    assert(hooks == 1 && p.presented == 1 && w.presented == 1, "one frame draws both, hooks once");
    assert(h2.renderer.readPixels().length == 300 * 160 * 4);

    Point at = Point((b2.bounds.x + 4) * 2, (b2.bounds.y + 4) * 2);
    Event down = { kind: EventKind.pointer, window: w.id, pointer: PointerKind.down, pos: at, button: 1, clicks: 1 };
    Event up = { kind: EventKind.pointer, window: w.id, pointer: PointerKind.up, pos: at, button: 1, clicks: 1 };
    p.queue ~= [down, up];
    h.pump();
    assert(one == 0 && two == 1, "the press reaches the window it came from");

    Event tab = { kind: EventKind.key, window: w.id, key: Key.tab };
    h.app.handle(tab);
    assert(h2.focused is b2 && h.focused is null, "focus is per window");
    h.app.handle(tab);
    assert(h2.focused is b2);

    int asked;
    bool allow;
    h2.onCloseRequest = () { ++asked; return allow; };
    Event close = { kind: EventKind.close, window: w.id };
    h.app.handle(close);
    assert(asked == 1 && h2.isClosed == false && w.closed == false);
    allow = true;
    h.app.handle(close);
    assert(h2.isClosed && w.closed && h.app.windows == [h] && h.running, "a second window closes alone");
    p.queue ~= [down, up];
    h.pump();
    assert(two == 1, "events of a closed window are dropped");
    h.frame();
    assert(w.presented == 1 && p.presented == 2);

    Host h3 = h.openWindow(o2);
    assert(h3.text is h2.text, "the unused text system is taken again");
    h.close();
    assert(h3.isClosed && p.windows[1].closed, "the main window closes the others");
}

// Without window support `openWindow` throws, and a hidden second window draws no frames while the main one does.
unittest
{
    import std.exception : assertThrown;
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform, HeadlessWindow;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform p = new HeadlessPlatform(200, 100);
    Host h = new Host(p, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    p.windowless = true;
    assertThrown(h.openWindow(o));
    p.windowless = false;
    WindowOptions o2;
    o2.hidden = true;
    Host h2 = h.openWindow(o2);
    h.frame();
    assert(p.presented == 1 && p.windows[0].presented == 0);
    h2.visible = true;
    h.frame();
    assert(p.windows[0].presented == 1, "shown, it draws with the main window");
    h2.frame();
    assert(p.windows[0].presented == 2 && h2.text is h.text, "same scale, same text system");
}
