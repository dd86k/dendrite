# dentriteui

Dentrite is a retained, signal-based UI library.

Research exercise iterated over checking different patterns and existing
libraries.

> [!WARNING]
> **WORK IN PROGRESS**: Under heavy development.

Why:
- ddui is immediate-mode only and less suited for a full GUI app.
- Personal curiosity, learning modern UI architectures and syntax.
- D source makes some optimizations available.

## Features

- Retained node tree driven by signals.
- Immediate-mode islands on the same layout and renderer.
- Responsive layouts: window breakpoints, a squeeze picking a child by
  the space it gets, split views and width caps.
- Raw GL islands for custom drawing.
- SDL3 window, OpenGL 3.3 or software renderer.
- FreeType and HarfBuzz text, OpenType features per style.
- AccessKit accessibility, opt-in.
- No UI library underneath.

Design: path C of `research/report.html`, section 11.

## Screenshots

![Table with sortable, resizable columns over 5,000 rows](screenshots/tables.png)
![Menu bar with a submenu open over a tree view](screenshots/menu.png)
![Debugger demo: docked panes, disassembly, registers and console](screenshots/debugger.png)

<!-- `rdmd tools/screenshots.d` writes screenshots. -->

## Status

- No releases yet, the API can change.
- Only Linux and Windows have been tested.

## Documentation

- [Usage guide](https://dd86k.github.io/dendrite/), a chapter per topic.
- [API reference](https://dd86k.github.io/dendrite/api/), every module.

## Layout

| Path | What |
|---|---|
| `core/` | `dentrite:core`: no SDL or GL. Host, headless platform, software renderer. |
| `gl33/` | `dentrite:gl33`: GL 3.3 renderer. GL loads through the platform. |
| `sdl3/` | `dentrite:sdl3`: SDL3 platform and `Window`. |
| `examples/debugger/` | Debugger-shaped demo. Its README has timings. |
| `examples/gallery/` | One page per widget, with screenshots. |
| `guide/` | Usage guide, a chapter per topic, see `guide/README.md`. |
| `fonts/` | Inter, JetBrains Mono and a few Noto Color Emoji, for tests and examples. |
| `research/` | Architecture study, see `research/README.md`. |

## Build

Needs SDL3 3.2+, FreeType, HarfBuzz and dub.
Tested with ldc2 1.40 and dmd 2.110 on Debian 13.

```sh
apt install libsdl3-dev libfreetype-dev libharfbuzz-dev # required deps
apt install libsdl3-image-dev      # optional, image files, loaded at run time
dub test                           # test every subpackage, from the repo root
dub test :core                     # test core library, no SDL needed
rdmd tools/apidoc.d                # builds API reference into bin/apidoc/
cd examples/debugger && dub        # build and run debugger example
```

As a dependency:

```sdl
dependency "dentrite" path="path/to/dentriteui"        # everything
dependency "dentrite:core" path="path/to/dentriteui"   # custom platform or headless
```

Bindings are hand-written `extern(C)` in `*/source/dentrite/c/`, no ImportC (finicky
on Windows).

### Static SDL

On Linux and Windows, SDL3 can be linked in from `winlibs/` (needs CMake, uses
Ninja when found):

```sh
rdmd tools/winlibs.d --sdl3                # 3.4.20, or --sdl3=VERSION, or --sdl3=path/to/SDL
dub build --override-config=dentrite:sdl3/static
dub test -c unittest-static                # test every subpackage against it
```

The tool warns when SDL lists a system library the `static` configuration in
`dub.sdl` lacks. On Windows it also builds `SDL3.lib` and `SDL3.dll` for the
dynamic configuration.

### Windows

- dub links `SDL3.lib`, `freetype.lib`, `harfbuzz.lib`, also from `winlibs/`.
- `rdmd tools/winlibs.d --freetype --harfbuzz` builds static FreeType and
  HarfBuzz into `winlibs/` (needs Visual Studio C++ tools). FreeType gets zlib
  and libpng compiled in, for color emoji.
- `rdmd tools/winlibs.d --sdl3` builds `SDL3.lib` and `SDL3.dll`, or take them
  from SDL's VC release. DLLs in `winlibs/`, such as `SDL3.dll` and the
  optional `SDL3_image.dll`, are copied next to the program.

## Modules

`core/source/dentrite/`:

| Module | What |
|---|---|
| `geom.d` | Point, Size, Rect, Insets, Color. |
| `signals.d` | Signals and effects. |
| `node.d` | Retained tree: layout, cached layers, input, focus, owner scopes. |
| `containers.d` | Row, column, grid, stack, padding, panel, sized box, separator, scroll view. |
| `widgets/` | Widgets, one module each. See the gallery. |
| `immediate.d` | Island core: builds retained nodes, opens popups. |
| `island.d` | Island node and raw view. |
| `overlay.d` | Popups: anchoring, flip and clamp, light dismiss, modal. |
| `command.d` | Commands and shortcuts. |
| `tray.d` | System tray icon with a menu of menu items. |
| `dock.d` | Docking: tabs, splitters, floating panes, layout save and restore. |
| `access.d` | Accessibility tree, diffed per frame. |
| `text.d` | Fonts with fallback, shaping cache, wrapping, glyph atlas. |
| `image.d` | Premultiplied RGBA8 images. |
| `draw.d` | Draw commands, tessellator, batches, layer compositor. |
| `host.d` | Window contents: input routing, focus, keys, frames, screenshots. |
| `platform.d` | `Platform` and `Renderer` interfaces, events, window options. |
| `loop.d` | Frame scheduling: requests, timers, frame cap. |
| `headless.d` | Platform without a window. |
| `script.d` | Scripted input for headless runs. |
| `backend/software.d` | CPU renderer. |
| `theme.d`, `mailbox.d`, `virtual.d` | Theme files, UI thread mailbox, list virtualization. |
| `c/` | FreeType and HarfBuzz bindings. |

`gl33/source/dentrite/`:

| Module | What |
|---|---|
| `backend/gl33.d`, `c/gl.d` | GL 3.3 renderer and bindings. |

`sdl3/source/dentrite/`:

| Module | What |
|---|---|
| `window.d` | `Window`, a host on the SDL3 platform. |
| `sdl3.d`, `c/sdl.d` | SDL3 platform: window, events, clipboard, cursors, file dialogs, tray icons. |
| `deadkeys.d`, `c/wayland.d` | Dead keys on Wayland without an input method. |
| `accesskit.d`, `c/accesskit.d` | AccessKit adapter. |
| `sdlimage.d`, `c/sdlimage.d` | Image files through SDL3_image. |

### Environment variables

| Variable | Effect |
|---|---|
| `DENTRITE_LOG_INPUT=1` | Print key, text and composition events. |
| `DENTRITE_ACCESSKIT` | Path to libaccesskit, if not on the library path. |
| `DENTRITE_SDL_IMAGE` | Path to SDL3_image, if not on the library path. |

libaccesskit, SDL3_image, libwayland-client and libxkbcommon load at run time.
