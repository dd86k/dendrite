# 4. Widgets

Each widget has a module under `dentrite.widgets` and a builder of the same
name. The gallery (`examples/gallery/`) has a page per widget with every
option in use, so this chapter covers what they share.

## Common options

- Editing widgets take the `Signal` they edit, and write it on input.
- `enabled: () => ...` greys the widget out and stops input while false.
- `tooltip: "..."` shows text after the pointer rests on it.
- `variant: "..."` picks a theme variant, such as `"primary"`, `"danger"` or
  `"toolbar"` for buttons, `"muted"` or `"mono"` for labels.
- `onClick:` on buttons, and `onClose:` or `onActivate:` where it applies,
  are plain delegates.

<!-- src="examples/source/guide/widgets.d" from="Node exportForm(" -->
```d
/// Form over `s`: each widget takes the signal it edits.
Node exportForm(ExportSettings s)
{
    return column(gap: 10, cross: CrossAlign.start)(
        row(gap: 8)(label("Name"), sized(w: 200)(textBox(s.name, placeholder: "File name", accessName: "File name")),
            comboBox(["PNG", "JPEG", "WebP"], s.format, tooltip: "File type")),
        radioGroup(s.quality, label: (Quality q) => capitalize(q.to!string), horizontal: true),
        row(gap: 8)(label("Width"), sized(w: 200)(slider(s.width, 16, 4096, 16)), spinBox(s.width, 16, 4096, 16)),
        checkbox(s.keepAspect, "Keep the aspect ratio"),
        row(gap: 8)(
            button("Export", onClick: () { s.done.set(double.nan); }, icon: Icon.play, variant: "primary",
                enabled: () => s.name.get.length > 0, tooltip: "Writes the file"),
            sized(w: 160)(progressBar(() => s.done.get)),
        ),
        label(() => format("%s.%s at %d px, %s", s.name.get, s.format.get, s.width.get, s.quality.get), "muted"),
    );
}
```

The slider and the spin box share `s.width`, so either one moves the other.
`radioGroup` and `comboBox` over an enum signal list its members, with
`label:` to name them. A progress bar shows NaN as busy.

## The widgets

| Builder | Module | Gallery page |
|---|---|---|
| `label(text)`, `label(() => text)` | `label` | Text |
| `button(caption, onClick:)` | `button` | Buttons |
| `checkbox(signal, caption)` | `checkbox` | Check boxes |
| `radio(signal, option, caption)`, `radioGroup(signal)` | `radio` | Radio buttons |
| `textBox(signal, password:)` | `textbox` | Text boxes |
| `textArea(signal, wrap:)` | `textarea` | Text areas |
| `spinBox(signal, min, max, step)` | `spinbox` | Spin boxes |
| `slider(signal, min, max, step)` | `slider` | Sliders |
| `comboBox(items, signal)`, `comboBox(enumSignal)` | `combobox` | Combo boxes |
| `progressBar(() => fraction)` | `progress` | Progress bars |
| `iconView(icon)`, `imageView(image, fit)` | `icons`, `image` | Images |
| `tabs(signal)(tab(title, page)...)`, `tabBar(titles, signal)` | `tabs` | Tabs |
| `listItem(onClick:, selected:)(content)` | `list` | Lists |

Lists, trees and tables are in [chapter 5](05-collections.md); menus,
dialogs and tooltips in [chapter 6](06-commands.md).

## Setters

Builders return the node, and each node has setters for what changes after
it is built: `setText` and `setVariant` on labels, `setCaption`, `setIcon`
and `setEnabled` on buttons, `setTooltip` on every node. Drive them from an
effect when a binding option does not cover it:

<!-- src="examples/source/guide/widgets.d" from="Node runButton(" -->
```d
/// Tool bar button whose caption, icon and tooltip follow `running`.
Node runButton(Signal!bool running)
{
    Button b = button("Run", onClick: () { running.set(running.peek == false); }, variant: "toolbar");
    effect(() {
        bool on = running.get;
        b.setCaption(on ? "Pause" : "Run");
        b.setIcon(on ? Icon.pause : Icon.play);
        b.setTooltip(on ? "Pause the target" : "Run the target");
    });
    return b;
}
```

Some options are fixed when built. `textArea`'s `wrap`, `readOnly` and
`lineNumbers`, for instance, have no setters.

## Accessibility

Widgets describe themselves to screen readers (enable with
`WindowOptions.accessibility`). A widget is named by its caption. One
without a caption, such as a text box, an icon button or a slider, needs an
`accessName:`, as `exportForm` gives the name box. Every builder takes it.
A label names the control it is for, and a click on it focuses that
control: `label("Name", for_: box)`. In an island, `ui.label("Name",
forNext: true)` does the same for the control declared next.
`label(() => status.get, live: Live.polite)` makes screen readers announce
its changes, for a status line. `Live.assertive` interrupts them, for
urgent alerts. A dock view exposes each stack as a tab list followed by a
pane named by the chosen tab, and choosing a tab from a screen reader
switches it.
Text fields report where each character is, and screen readers can move
their caret and selection. Table rows expose a cell per column, with its
row and column.

On a touch screen, a long press or a double tap in a text box or text area
selects a word and shows a handle under each end, which a drag moves. A
context menu around the field opens along with it.
