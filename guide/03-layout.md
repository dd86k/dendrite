# 3. Layout

Layout is box constraints, as in Flutter: a parent hands each child a
minimum and maximum size, the child picks a size in that range, and the
parent places it. Each node caches its last layout. A change relays out
the nodes up to the nearest one whose size cannot change, such as one with
fixed or tight constraints, not the whole window.

## Containers

All in `dentrite.containers`:

| Builder | What |
|---|---|
| `row(gap:, cross:)(kids...)` | Children left to right. `cross` defaults to `center`. |
| `column(gap:, cross:)(kids...)` | Children top to bottom. `cross` defaults to `stretch`. |
| `expanded(child, flex)` | Takes a share of the space left on the main axis. |
| `spacer(flex)` | Empty `expanded`, pushes its neighbors apart. |
| `pad(all:, x:, y:)(child)` | Space around the child. |
| `sized(w:, h:)(child)` | Fixed width, height or both. A missing one is left to the parent. |
| `panel(variant:)(child)` | Themed background, border and padding. |
| `hrule()`, `vrule()` | One pixel separators. |
| `scroll(follow:, followTop:, drag:)(child)` | Vertical scroll view. `follow: true` sticks to the bottom, for logs. `followTop: true` sticks to the top, for newest-first feeds. `drag:` picks the pointers that scroll it by dragging the content, see below. |
| `grid(cols:, minCell:, gap:, cross:)(kids...)` | Rows of equal columns: `cols` of them, or as many at least `minCell` wide as fit. |
| `stack(x:, y:)(kids...)` | Children on top of each other, the last on top. |
| `aligned(x:, y:)(child)` | Stack child with its own placement. |

`CrossAlign` places children across the main axis, in a grid row, or on
each axis of a stack: `start`, `center`, `end` or `stretch`. The library's
panel variants are `toolbar`, `pane`, `status`, `header` and `popup`, and
their look comes from the theme.

## A window shell

<!-- src="examples/source/guide/layout.d" from="Node shell()" -->
```d
/// Window shell: a tool bar, a sidebar of fixed width, scrolling content and a status bar.
Node shell()
{
    Node[] lines;
    foreach (int i; 1 .. 61)
    {
        lines ~= label(format("Line %d", i));
    }
    return column()(
        panel(variant: "toolbar")(row(gap: 4)(
            button("Open", icon: Icon.plus, variant: "toolbar"),
            button("Run", icon: Icon.play, variant: "toolbar"),
            spacer(),
            label("main.d", "muted"),
        )),
        expanded(row(cross: CrossAlign.stretch)(
            sized(w: 180)(panel(variant: "pane")(pad(all: 8)(column(gap: 4)(
                label("Files", "strong"),
                label("main.d"),
                label("util.d"),
            )))),
            vrule(),
            expanded(scroll()(pad(x: 12, y: 8)(column(gap: 2)(lines)))),
        )),
        panel(variant: "status")(row()(label("Ready", "muted"), spacer(), label("60 lines", "muted"))),
    );
}
```

The middle row is `expanded`, so it takes the height the bars leave. Its
`cross: CrossAlign.stretch` makes the sidebar and the scroll view as tall
as the row. The scroll view is `expanded` in turn, so it takes the width
the sidebar leaves.

Touch and pen drags on the content scroll it, and a quick release flings it
on. Scroll views, tables and text areas all do this. A press waits until
it moves (scroll) or lifts (tap), so a swipe never presses a button or
selects a row. `WindowOptions.scrollDrag` picks the pointers for the whole
window, and `Host.scrollDrag` changes them later. `ScrollDrag.always` adds
the mouse, for a VR overlay that drives the mouse cursor, and `never` turns
dragging off. With the mouse, a press held still for a moment keeps its
drag, so text can still be selected. `scroll(drag:)` overrides it for one
view. The distances and times are in the theme's `[scroll]` section.

## Sharing space

`expanded` children split what fixed children and gaps leave, by their
`flex`:

<!-- src="examples/source/guide/layout.d" from="/// Shares of the width" -->
```d
/// Shares of the width: flex 1, 2 and 1, with fixed parts left alone.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(444, 100);
    scope (exit)
    {
        h.close();
    }
    h.setRoot(row(gap: 4)(sized(w: 32)(spacer()), expanded(spacer()), expanded(spacer(), 2), expanded(spacer())));
    h.frame();
    Node r = h.tree.content;
    assert(r.children[1].size.w == 100 && r.children[2].size.w == 200 && r.children[3].size.w == 100);
}
```

## Grids and stacks

`grid` lays out its children in rows of equal columns. `cols:` fixes the
count. `minCell:` fits as many columns of at least that width as the row
allows, so the count follows the window width. Each row is as tall as its
tallest cell, and rows share any height beyond that, so
`expanded(grid(cols: 3, gap: 8)(...))` makes big buttons that fill the window.

`stack` puts its children on top of each other. The last is drawn on top and
gets the pointer first. `x:` and `y:` place the children, and
`aligned(x:, y:)(child)` places one on its own. A child stretched on an axis
fills the stack on that axis and does not count toward its size, so a
stretched background takes the size of the content over it:

<!-- src="examples/source/guide/layout.d" from="Node tiles(" -->
```d
/// Tiles at least 120 px wide, as many per row as fit, each a name over a stretched background.
Node tiles(string[] names)
{
    Node[] cells;
    foreach (string n; names)
    {
        cells ~= sized(h: 80)(stack(y: CrossAlign.end)(
            aligned(x: CrossAlign.stretch, y: CrossAlign.stretch)(panel(variant: "popup")(new Fixed(Size.init))),
            pad(all: 8)(label(n)),
        ));
    }
    return grid(minCell: 120, gap: 8)(cells);
}
```

## Sizes to watch

Some nodes fill whatever they are offered, and get nothing when offered an
unbounded axis. Give them a bound with `expanded` or `sized`:

- Islands (chapter 7) take the full offered size. In a plain column they
  get a height of 0.
- Tables need a bounded height.
- A plain column in a popup stretches to the window width, so give it a
  width.

Labels wrap only with `label(text, wrap: true)`, at the width they get.

## Window size

`h.breakpoint(minW:, maxW:, minH:, maxH:)` is a computed value, true while
the window size is within the ranges, bounds included, in logical pixels.
Its readers rerun only when the window crosses a bound, so an effect on it
changes the layout like a CSS media query. `h.windowSize` is the size
itself, also tracked.

<!-- src="examples/source/guide/layout.d" from="Node adaptive(" -->
```d
/// Sidebar beside the content while the window is over 600 px wide, the content alone otherwise. Both are built
/// once and only attached, so they keep their state.
Node adaptive(Host h, Node side, Node content)
{
    Computed!bool narrow = h.breakpoint(maxW: 600);
    Node rule = vrule();
    Node main = expanded(content);
    Flex holder = row(cross: CrossAlign.stretch)();
    effect(() {
        holder.setChildren(narrow.get ? [main] : [side, rule, main]);
    });
    return holder;
}
```

Breakpoints follow the window, not the space a node gets, such as a pane
the user resized in a dock. For that, use a squeeze.

## Space a node gets

`squeeze()(...)` shows the first child that fits the space it is offered.
`fits(minW:, maxW:, minH:, maxH:)` gives a child ranges in logical pixels,
bounds included, and a child without it always fits, so the last is the
fallback:

<!-- src="examples/source/guide/layout.d" from="Node searchBar(" -->
```d
/// Search bar with a caption and a button when given 500 px or more, the text box alone otherwise.
Node searchBar(Signal!string query)
{
    return squeeze()(
        fits(minW: 500)(row(gap: 6)(label("Search"), expanded(textBox(query)), button("Go"))),
        textBox(query),
    );
}
```

The pick happens during layout, from the largest size offered. An
unbounded axis, such as the width in a plain `row`, counts as infinitely
large, so give the squeeze `expanded` or `sized` there. The children not
shown stay built and detached, like the pages of `tabs`, so they keep their
state. Focus inside a child that leaves is dropped.

## Split views and width caps

`splitView(sideShown, minW:, sideW:, mode:)(side, content)` shows a
sidebar `sideW` wide beside the content while it gets at least `minW`, and
collapses when narrower. With `Collapse.navigate`, the default, it shows
the sidebar or the content, with a back bar over the content. With
`Collapse.drawer` it shows the content, and the sidebar opens over it as a
drawer that a press outside or Escape closes. `sideShown` picks what shows
while collapsed, so the app sets it when a sidebar item is chosen:

<!-- src="examples/source/guide/layout.d" from="Node mail(" -->
```d
/// Folders beside the open folder, one at a time below 500 px. Choosing a folder shows it when collapsed.
Node mail(Signal!string folder)
{
    Signal!bool shown = signal(true);
    Node side = column(cross: CrossAlign.start)(
        button("Inbox", () { folder.set("Inbox"); shown.set(false); }),
        button("Sent", () { folder.set("Sent"); shown.set(false); }),
    );
    Node content = pad(all: 12)(label(() => folder.get));
    return splitView(shown, minW: 500, sideW: 160)(side, content);
}
```

`collapsed:` takes a signal that follows whether it collapsed, set after
each layout, such as to show a button opening the drawer only then.

`clamped(maxW: 640)(child)` keeps a child at most that wide, centered in
a wider space, such as a form or long text in a wide window.

## Other layouts

The dock (`dentrite.dock`) arranges panes in tab stacks and splits that the
user can drag, with floating windows and JSON save and restore. See the
gallery's Dock page and `examples/debugger/source/app.d`. A `DockView`:

- changes panes from code with `addPane`, `removePane`, `select` and
  `setTitle`,
- holds the shown pane of the focused stack in `current`, and runs
  `onLayout` after the user rearranges panes,
- asks `onCloseRequest` on a close button or middle click, `tabMenu` for a
  tab's context menu, and runs `onBarDoubleClick` on a double click on an
  empty part of a tab bar,
- takes icons, tooltips and marks for its tabs from `setTabInfo`, and a
  node for the end of each tab bar from `setTrailing`,
- keeps panes at least `minPane` big, and floats nothing with
  `floating = false`,
- moves a pane by keyboard with `startMove`, where the arrow keys pick a
  drop button and Enter docks, and reorders tabs with `shiftTab`, both
  bound to commands by the app,
- lights the stack a dragged file would go to with `fileHover` and
  `fileLeave`, called from the window's `onFileHover` and `onFileLeave`,
  and finds it again for `onFileDrop` with `stackAt`.

For a layout none of these give, write a node (chapter 10): its
`performLayout` gets the constraints and positions the children.
