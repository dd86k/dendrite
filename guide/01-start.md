# 1. Getting started

## Dependency

dentrite needs SDL3 (3.2 or newer), FreeType and HarfBuzz, see the
repository README for packages and Windows notes. Add it to `dub.sdl`:

```sdl
dependency "dentrite" path="path/to/dentriteui"
```

`dentrite` pulls in everything: the core, the GL 3.3 renderer and the SDL3
window. `dentrite:core` alone has no SDL or GL, for headless use or a
platform of your own.

## The first window

<!-- src="examples/hello/hello.d" from="void main()" -->
```d
/// Opens the window and runs until it closes.
void main()
{
    WindowOptions o;
    o.title = "Hello";
    o.width = 320;
    o.height = 200;
    o.fonts = ["../../fonts/Inter-Regular.otf", "../../fonts/Inter-SemiBold.otf",
        "../../fonts/JetBrainsMono-Regular.ttf"];
    scope Window w = new Window(o);

    Signal!int count = signal(0);
    scope Scope root = effectScope(() {
        w.setRoot(pad(all: 16)(column(gap: 8, cross: CrossAlign.start)(
            label(() => format("Count: %d", count.get)),
            button("Add one", onClick: () { count.set(count.peek + 1); }),
        )));
    });
    w.run();
}
```

Imports are `dentrite.window` (which brings the host and platform types),
`dentrite.signals`, `dentrite.containers` and one module per widget under
`dentrite.widgets`.

What each part does:

- `WindowOptions.fonts` takes three files: body text, strong text (buttons,
  headers) and monospace. No font is built in. `fonts/` in the repository
  has Inter and JetBrains Mono with their licenses. Characters missing from
  them come from `fallbackFonts`, then from well-known system fonts. Emoji
  prefer a color font among those, such as Noto Color Emoji.
- `scope Window w` opens the window and closes it at scope exit. One window
  per process for now.
- The UI is built once, inside `effectScope`. Builders like `label` and
  `button` create bindings (effects) that belong to the scope current when
  they run, so `root` owns every binding of the window. Chapter 2 covers
  this.
- `label(() => ...)` takes a delegate, so the label follows `count`. A
  plain string makes a fixed label.
- `w.run()` returns when the window closes or `w.running` is set to false.
  `w.onCloseRequest` returning false keeps the window open, such as to hide
  it or ask about unsaved changes. It draws a frame only when something
  asked for one: input, a changed signal that a node shows, a timer, or a
  wake from another thread.

Without a theme every widget uses the dark look built into its style
struct, variants included. Set `o.themePath` to a theme file to change it,
see [chapter 8](08-themes.md). The examples use
`examples/themes/dark.theme`, which is a good file to copy.

Once open, `w.title`, `w.visible`, `w.minimumSize` and `w.icon`, which
takes one image per size, change the window. `WindowOptions.minWidth` and
`minHeight` set the minimum size up front. `w.sdlWindow` gives the SDL window
for anything else, but use the setters where they exist: the title also names
the window for screen readers, and hiding ends presses and hover.

## Builders

Every retained widget has a builder function returning the node. Options
are named, required arguments come first. Containers take their children
in a second call:

```d
row(gap: 8, cross: CrossAlign.start)(a, b, c)
pad(x: 12, y: 8)(child)
panel(variant: "toolbar")(child)
```

The second call exists because D binds a positional argument after a named
one to the next parameter, so `row(gap: 8, a)` would pass `a` as `cross`.

Builders return the concrete class (`Button`, `Label`, `Flex`), so you can
keep a node and change it later. The usual shape of a component is a
function that builds its nodes once, binds them to signals with effects,
and returns the root node:

<!-- src="examples/source/guide/counter.d" from="Node counter()" -->
```d
/// Counter: a label showing the count and buttons changing it.
Node counter()
{
    Signal!int count = signal(0);
    return pad(all: 16)(column(gap: 8, cross: CrossAlign.start)(
        label(() => format("Count: %d", count.get)),
        row(gap: 8)(
            button("Add one", onClick: () { count.set(count.peek + 1); }, variant: "primary"),
            button("Reset", onClick: () { count.set(0); }, enabled: () => count.get > 0),
        ),
    ));
}
```

`enabled:` takes a delegate too: Reset greys out while the count is 0.
