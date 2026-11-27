# 5. Collections

Rows built from data come in two kinds:

- `keyedColumn` builds one row per item and keeps it while the item's key stays.
  For short lists, up to a few hundred rows.
- `virtualList`, `table` and `treeView` build rows only for the items in
  view, and reuse them as the view scrolls. For any length.

## Keyed lists

<!-- src="examples/source/guide/collections.d" from="    Node view()" -->
```d
/// The view: an entry row, the keyed rows, and a count.
Node view()
{
    return column(gap: 8)(
        row(gap: 8)(expanded(textBox(entry, placeholder: "New task", accessName: "New task")),
            button("Add", onClick: &add)),
        keyedColumn(() => tasks.get, (Task t) => t.id, (Task t) => taskRow(t), gap: 2),
        label(() => format("%d open", tasks.get.filter!(t => t.done.get == false).array.length), "muted"),
    );
}
```

`keyedColumn(items, key, row)` reads `items` in an effect. When the array
changes, rows whose key is still there keep their node, new keys get a row,
and rows of removed keys are disposed with their bindings. It returns the
column itself, and `list[key]` gives the row of a key.

A row is built once for its item, so anything about an item that changes
must be a signal the row binds to. Here a task's title is fixed and its
state is `Signal!bool done`:

<!-- src="examples/source/guide/collections.d" from="final class Task" -->
```d
/// To-do item. The title never changes, the state is a signal so its row can follow it.
final class Task
{
    int id;            /// key
    string title;      /// text
    Signal!bool done;  /// ticked off

    /// Creates an open task.
    this(int id, string title)
    {
        this.id = id;
        this.title = title;
        done = signal(false);
    }
}
```

<!-- src="examples/source/guide/collections.d" from="    private Node taskRow(" -->
```d
/// Row of `t`: its check box and a remove button.
private Node taskRow(Task t)
{
    return row(gap: 8)(
        expanded(checkbox(t.done, t.title)),
        button("Remove", onClick: () { remove(t); }, variant: "toolbar", accessName: "Remove " ~ t.title),
    );
}
```

Changing the list means setting a new array: `tasks.set(tasks.peek ~ t)`.
Appending in place does not notify anyone.

## Virtual lists

<!-- src="examples/source/guide/collections.d" from="Node logList(" -->
```d
/// Virtual list of `log`: only the rows in view exist. A row gets a getter of its entry, since a row node is
/// reused for other entries as the list scrolls.
Node logList(Entry[] log, Signal!uint selected)
{
    return scroll()(virtualList!(uint, Entry)(items: () => log, key: (Entry e) => e.id,
        row: (Entry delegate() e) => logRow(selected, e), selected: selected));
}
```

The row builder gets `Entry delegate()`, not an `Entry`. A row node moves
to another entry when its own scrolls out of view, so it must read its
entry through the getter, inside bindings:

<!-- src="examples/source/guide/collections.d" from="Node logRow(" -->
```d
/// Row reading its entry through `e`, inside bindings.
Node logRow(Signal!uint selected, Entry delegate() e)
{
    return listItem(onClick: () { selected.set(e().id); }, selected: () => selected.get == e().id)(row(gap: 8)(
        sized(w: 48)(label(() => e().level, "muted")),
        expanded(label(() => e().text)),
    ));
}
```

`label(e().text)` would show the first entry forever. Widgets that take a
signal have getter forms for this, such as `checkbox(() => item().enabled)`.

`selected:` makes the list one Tab stop with arrow keys, Page Up and Down,
Home and End. More options on `virtualList`, `table` and `treeView`:

- `onActivate:` runs on Enter or a double click.
- `text:` gives each item's text, so typing selects the next item starting
  with it.
- `multi:` takes a `Signal!(K[])` and allows selecting several items with
  Ctrl, Shift or a drag.

Place a virtual list in a `scroll()`. Row heights come from measuring the
rows, so they may differ.

Measured heights follow their keys when the items change. In a scroll view,
the row at the top of the view stays in place when items are added or removed
above it, such as older messages loaded at the top. `scroll(follow: true)`
keeps showing the end while scrolled to it, for chats and logs.
`scroll(followTop: true)` keeps showing the top while scrolled to it, for
newest-first feeds.

Only the rows in view are nodes, reused as the list scrolls, so a long feed
costs its items and not its widgets. Cap the items in the app, such as keeping
the newest 1,000 once 2,000 arrived.

## Tables

<!-- src="examples/source/guide/collections.d" from="Node logTable(" -->
```d
/// Table of `log`: titles that sort, columns that resize, move and hide.
Node logTable(Entry[] log, Signal!uint selected)
{
    return table(items: () => log, key: (Entry e) => e.id, selected: selected, stretchLast: true)(
        tableColumn("#", (Entry delegate() e) => label(() => format("%d", e().id), "mono"), width: 60,
            less: (Entry a, Entry b) => a.id < b.id),
        tableColumn("Level", (Entry delegate() e) => label(() => e().level), width: 70,
            less: (Entry a, Entry b) => a.level < b.level),
        tableColumn("Message", (Entry delegate() e) => label(() => e().text), width: 240),
    );
}
```

A table is a virtual list with a header. Cells follow the same getter rule.
A column with `less:` sorts when its title is clicked. The table scrolls on
its own, so do not wrap it in `scroll()`, but give it a bounded height.

`stretchLast: true` lets the last shown column fill a wider table, its
`width:` staying the least it shows. To keep column changes across runs, set
`onColumns`, which runs after the user resizes, moves, shows or hides a
column, and read `shownColumns` and `width(i)` there.

## Trees

<!-- src="examples/source/guide/collections.d" from="Node folderTree(" -->
```d
/// Tree of folders under `root`.
Node folderTree(Folder root, Signal!string selected)
{
    return treeView!(string, Folder)(() => root.kids, (Folder f) => f.kids, (Folder f) => f.path,
        (Folder delegate() f) => label(() => f().name), selected);
}
```

`treeView(roots, children, key, row, selected)` lists children only when
their parent expands. `hasChildren:` answers whether a node has any
without listing them. `expand(key)` opens a node from code.
