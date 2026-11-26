# Limitations

Known gaps, by area.

## Platform

- One top-level window per process, no second window with its own UI tree.
  The SDL3 platform owns SDL, reads the events of every window (its popup
  windows included) and quits SDL when it closes.
- Popup windows: only tried on X11. Without a compositor the shadow room
  around them shows black. Each opens its own GL context, about 10 ms with
  llvmpipe. Dialogs and other centered popups stay inside the window.
  Screenshots hold the main window only.
- Popup windows on Wayland: the window's place on screen is unknown, so
  popups are placed as if it sat at its display's top left. The compositor
  moves those that do not fit, and a press in the main window where the
  popup would have been still reaches the popup.
- File dialogs on Linux need an XDG portal or zenity, else they answer as
  cancelled.
- Wayland does not report minimizing, so a minimized window still draws the
  frames asked for, such as animations.
- Tray icons: no click on the icon itself, only menu entries. No icons in
  entries, and entries cannot be added or removed once shown, close and
  open the tray again. Linux needs an AppIndicator library and a desktop
  showing StatusNotifier items. Outside Windows the loop wakes every 50 ms
  while a tray shows, as SDL runs it only while pumping events.
- File drops: the files and the drop point, once the drop ends. No dropped
  text and nothing while a drag hovers, so no drop target highlight.
- `Host.colorScheme` comes from SDL, `unknown` where it cannot tell, such as
  on Linux without an XDG portal.
- Tray submenus on SDL before 3.2.16 rely on a workaround that reads SDL's
  private menu struct, see `holdSubmenu` in `sdl3.d`.

## Rendering

- No Vulkan renderer. Everything above the renderer sees only `FrameMesh`.
- A changed layer uploads its whole mesh, and batches never merge across
  layers, one VAO bind per visible layer.
- Glyph quads cost about 350 ns each, most of a changed island's cost.
- Software renderer: one thread, whole frame every time, skips raw views.

## Images

- SDL3_image is only loaded at run time, no configuration links it.
- One texture per image, no atlas, so many images split batches.
- SVGs load at their own size, not the display scale.
- No mipmaps (below half size aliases), no rounded corners.
- Animations show their first frame.
- A scaled sub-image blends in pixels just outside it.

## Text

- Fallback glyphs take the slot font's line height and regular weight.
- Color glyphs: CBDT bitmap (Noto) and COLRv0 (Segoe, Twemoji) fonts. COLRv1
  and SVG fonts draw nothing, sbix (Apple) is untested and not in the system
  list. Color glyphs snap to whole pixels, bitmaps scale up without smoothing.
- Emoji presentation comes from a built-in table, not Unicode data.
- OpenType features apply to a whole label, text box or text area, not a
  range. Other widgets shape with the font defaults. Variable font axes stay at
  their defaults.
- System fonts come from a fixed path list, no fontconfig.
- Input methods: the platform draws the candidate list. A press in a text
  area waits for the commit. Lists show no composition.
- X11 without an input method: dead key accents do not show.
- Password boxes ask SDL for password text input. Whether the input method
  turns off is up to SDL and the platform. Where it stays on, the composition
  is hidden and only its commit lands. The text stays in memory as a plain
  string.
- `Host.setFont` swaps slot fonts only, fallback fonts are fixed once the
  window opens.
- With `Host.onText` set and focus outside text fields, an input method's
  composition shows nowhere, only its commit reaches the handler.
- `ui.withStyle` edits do not reach island labels, which resolve their style
  at layout.

## Accessibility

- A label names a control only when linked by `label(..., for_: control)`,
  or in an island by `forNext: true` on a label declared right before it.
  Over AT-SPI the control gets the name but no labelled-by relation, which
  accesskit-c 0.23 does not map.
- Character bounds follow code points, not grapheme clusters, and assume left
  to right text. A text area reports none while an input method composes.
- Table cells carry their row and column, but accesskit-c 0.23 has no AT-SPI
  table interface, so Orca reads them as plain cells.
- Island text boxes take no `setValue` or `setSelection`.
- Only the Linux adapter has been run (AT-SPI). Windows and macOS follow
  accesskit-c's SDL example.

## Touch

- One pointer, from the mouse events SDL makes of touches and pens. No pinch
  zoom or other multi-touch gestures.
- Touch selection handles are for retained text boxes and text areas, not
  island text boxes. They follow the text one frame late, and dragging one to
  the edge of a text area does not scroll it. There is no cut, copy or paste
  bar, give the field a context menu for those.
- Drag scrolling covers scroll views, tables and text areas. Tab strips and
  island scroll areas take the wheel only.
- No overscroll bounce. A drag goes to the innermost view that can scroll
  its way and does not pass to the outer one when that view reaches its end.
- A touch press inside a view that scrolls by dragging shows no press until
  it lifts, moves a way the view does not scroll, or `pressDelay` passes.

## Widgets

- Lists, trees, tables: type-ahead matches the text start only.
- Trees: no drag and drop.
- Tables need a bounded height.
- Virtual list: a width or theme change measures rows again, from the one at
  the top of the view.
- Text areas: plain text, no colors, tabs become spaces. Every edit writes the
  whole text to the signal. Relayout shapes every line, fine for thousands of
  lines, not huge files.
- Sliders: horizontal only, no tick marks.
- Tab bars: no tab dragging, within a bar or between bars. Tabs show an icon,
  a title and a close button, no marks such as a modified dot, a count,
  progress or a lock.
- Spin boxes: plain decimals only, no units, separators or hex.
- Tooltips: text only.
- Popups: a plain column stretches to the window width, give it a width.
  Menus size to their items.
- Menus: mnemonics show only after a menu opened from the keyboard (Alt alone
  is not seen without key releases). A press on an island menu button cannot
  be dragged onto an item.
- Combo boxes: natural width measures the first 1000 labels, give longer lists
  a width. Filtering is substring in item order, no ranking. Island combo
  boxes are not editable, and a press on them cannot be dragged onto an item.

## Dock

- Floating windows stay inside the main window.
- No keyboard way to move panes.
- Losing window focus mid-drag drops the tab.
- Tabs show their title only, no icons or marks.
