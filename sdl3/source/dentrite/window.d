/// SDL3 window running a `Host`, drawn with GL 3.3 or in software.
module dentrite.window;

public import dentrite.host;
public import dentrite.platform;
import dentrite.c.sdl : SDL_Window;
import dentrite.sdl3 : SdlPlatform, SdlWindow;
import std.stdio : stderr;

/// Host on an SDL3 window. `scope Window w = new Window(o)` closes it at scope exit.
final class Window : Host
{
    private SdlWindow sdl; /// SDL side of this window

    /// Opens the main window with the renderer `o.renderer` names, loads fonts and the theme.
    this(WindowOptions o)
    {
        SdlPlatform p = new SdlPlatform(o);
        sdl = p.mainWindow;
        super(p, p.renderer, o);
        stderr.writeln("dentrite: ", renderer.description());
    }

    /// Opens another window in `owner`'s app, drawn as the main one, see `Host.openWindow`.
    this(Host owner, WindowOptions o)
    {
        super(owner, o);
        sdl = cast(SdlWindow) platformWindow;
    }

    /// SDL window, for SDL calls the library does not wrap. Cast it for other SDL bindings.
    /// NOTE: title, visibility, minimum size and icon have `Host` setters, which keep the host in step.
    SDL_Window* sdlWindow()
    {
        return sdl.handle;
    }
}
