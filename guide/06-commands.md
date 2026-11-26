# 6. Commands and menus

A `Command` (`dentrite.command`) is an action with a label, a shortcut, an
icon, and optional enabled and checked states. Menu items, tool bar buttons
and shortcuts all run the same command, so its state shows the same
everywhere.

<!-- src="examples/source/guide/commands.d" from="Node editor(" -->
```d
/// Editor window contents in `h`: a menu bar, a tool bar, the text with a context menu and a shortcut of its own,
/// and a confirmation.
Node editor(Host h, Notes n)
{
    Dialog confirm = dialog("Clear the notes?", buttons: ["Cancel", "Clear"], primary: 1, primaryVariant: "danger",
        onClose: (int b) {
            if (b == 1)
            {
                n.text.set("");
            }
        })(label("The text goes away for good.", wrap: true));
    NoteCommands c;
    c.save = command("&Save", &n.save, keys: "Ctrl+S", enabled: &n.dirty.get);
    c.clear = command("C&lear", () { confirm.open(h); }, icon: Icon.stop, enabled: () => n.text.get.length > 0);
    c.autosave = command("&Autosave", () { n.autosave.set(n.autosave.peek == false); }, checked: &n.autosave.get);
    c.quit = command("&Quit", () { h.running = false; }, keys: "Ctrl+Q");
    c.upper = command("&Upper case", () { n.text.set(n.text.peek.toUpper); }, keys: "Ctrl+U");
    effect(() {
        if (n.autosave.get && n.dirty.get)
        {
            n.save();
        }
    });

    return column()(
        menuBar(
            menu("&File")(menuItem(c.save), menuItem(c.autosave), menuSeparator(), menuItem(c.quit)),
            menu("&Edit")(menuItem(c.clear)),
        ),
        panel(variant: "toolbar")(row(gap: 4)(
            button("Save", onClick: () { c.save.run(); }, variant: "toolbar", enabled: &c.save.isEnabled,
                tooltip: commandTip(c.save)),
            button("Clear", onClick: () { c.clear.run(); }, icon: Icon.stop, variant: "toolbar",
                enabled: &c.clear.isEnabled, tooltip: "Clears the notes, after asking"),
            spacer(),
            label(() => n.dirty.get ? "Changed" : "Saved", "muted"),
        )),
        expanded(shortcuts([c.upper])(contextMenu(menuItem(c.upper), menuItem(c.clear))(
            textArea(n.text, placeholder: "Notes", wrap: true, accessName: "Notes")))),
    );
}
```

## Commands

`command(label, action, keys:, icon:, enabled:, checked:)`:

- `&` in the label marks the mnemonic letter, `&&` is a literal `&`.
- `keys:` is a chord such as `"Ctrl+S"`, `"Shift+Ctrl+Z"`, `"F5"` or
  `"Alt+Left"`.
- `enabled:` and `checked:` are delegates read where the command shows. A
  button bound with `enabled: &c.save.isEnabled` greys out with the
  command.
- `c.run()` runs the action if enabled, and returns whether it ran.

## Shortcuts

Where a shortcut fires depends on where its command sits:

- Items in a menu bar fire their shortcuts from anywhere in the window. Save
  and Quit above need nothing more.
- `shortcuts([cmds])(content)` fires them while focus is inside `content`.
  Ctrl+U above works only in the text area.
- `shortcuts([cmds], window: true)(content)` fires them from anywhere, for
  commands in no menu bar.

A key goes to the focused node first, then up its parents, then to the
window-wide handlers. A text box keeps the keys it uses, such as Ctrl+A, and
passes on the rest.

## Menus

- `menuBar(menu("&File")(items...), ...)`: Alt and a mnemonic opens a menu.
- `menuItem(cmd)` shows a command. `menuItem(label, action, keys:, ...)`
  makes a one-off item, and `menu(label)(items...)` inside a menu is a
  submenu.
- `popupMenu(items...)` makes a menu to open from code, such as from a
  button: `m.toggle(button)` opens it below the button, or closes it.
- `contextMenu(items...)(content)` opens on a right click or a long touch
  or pen press in `content`, or Shift+F10 and the menu key while it has
  focus. Screen readers can open it from any control inside.

A menu, combo box list or tooltip that does not fit in the window opens in
a popup window of its own, past the window edges, along with the popups
above it. `WindowOptions.popupWindows = false` keeps them inside, as does a
hidden window.

## Dialogs

`dialog(title, buttons:, primary:, primaryVariant:, width:, onClose:)(content)`
builds a closed modal dialog. `d.open(tree)` shows it centered over the
window. `onClose` gets the index of the pressed button, or -1 for Escape.
Enter presses the primary button unless it is disabled, Tab stays inside,
and focus goes back where it was. `d.button(i)` returns a button, to bind
its enabled state:

```d
effect(() { rename.button(1).setEnabled(name.get.length > 0); });
```

`host.fileDialog(FileDialogKind.open, (string[] paths) { ... }, filters)`
shows the system's file dialog. The handler runs later on the UI thread,
with no paths when cancelled.

## Tooltips

`tooltip:` on a builder, or `node.setTooltip(text)` later. `commandTip(cmd)`
makes the text from a command, with its shortcut. A tooltip shows after the
pointer rests 500 ms, and Tab to a button shows its tooltip below it.

## Tray icon

`h.tray(icon:, tooltip:)(items...)` (`dentrite.tray`) shows an icon in the
system tray with a menu of the same `menuItem`, `menu` and `menuSeparator`
builders. Entries follow their command's label, enabled and checked states,
while the window is hidden too. It returns null when the system has no
tray, such as on Linux without an AppIndicator library or a desktop showing
StatusNotifier items.

Most trays open the menu on any click and say nothing about a click on the
icon itself, so the menu needs an entry that brings the window back:

<!-- src="examples/source/guide/commands.d" from="Tray notesTray(" -->
```d
/// Tray icon of `h` with a menu that shows or hides the window and quits. While it shows, closing the window hides
/// it. Null without a tray.
Tray notesTray(Host h, Image icon)
{
    Command show = command("&Show window", () { h.visible = h.visible == false; }, checked: () => h.visible);
    Tray t = h.tray(icon: icon, tooltip: "Notes")(menuItem(show), menuSeparator(),
        menuItem("&Quit", () { h.running = false; }));
    if (t !is null)
    {
        h.onCloseRequest = () {
            h.visible = false;
            return false;
        };
    }
    return t;
}
```

`h.visible = true` also unminimizes and raises the window. `t.icon(img)`
and `t.tooltip(text)` change the icon later, `t.close()` removes it.
