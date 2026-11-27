/// Chapter 5: rows from data: keyed lists, virtual lists, tables and trees.
module guide.collections;

import dentrite.containers;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.checkbox;
import dentrite.widgets.label;
import dentrite.widgets.list;
import dentrite.widgets.table;
import dentrite.widgets.textbox;
import dentrite.widgets.tree;
import std.algorithm.iteration : filter;
import std.array : array;
import std.format : format;

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

/// To-do list: rows keyed by task id, so adding or removing a task leaves the other rows alone.
final class Todo
{
    Signal!(Task[]) tasks; /// in order
    Signal!string entry;   /// text of the next task
    private int next;      /// id of the next task

    /// Empty list.
    this()
    {
        tasks = signal(cast(Task[]) null);
        entry = signal("");
    }

    /// Adds a task titled with the entry text, and clears it.
    void add()
    {
        if (entry.peek.length == 0)
        {
            return;
        }
        batch(() {
            tasks.set(tasks.peek ~ new Task(++next, entry.peek));
            entry.set("");
        });
    }

    /// Drops `t`.
    void remove(Task t)
    {
        tasks.set(tasks.peek.filter!(x => x !is t).array);
    }

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

    /// Row of `t`: its check box and a remove button.
    private Node taskRow(Task t)
    {
        return row(gap: 8)(
            expanded(checkbox(t.done, t.title)),
            button("Remove", onClick: () { remove(t); }, variant: "toolbar", accessName: "Remove " ~ t.title),
        );
    }
}

/// Adding keeps existing rows, removing disposes the row and its bindings.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    Todo todo = new Todo;
    scope Scope root = effectScope(() { h.setRoot(todo.view()); });
    h.frame();
    foreach (string title; ["Milk", "Eggs", "Bread"])
    {
        todo.entry.set(title);
        h.click(Role.button, "Add");
    }
    assert(todo.tasks.peek.length == 3 && shows(h, Role.label, "3 open"));
    Node list = h.tree.content.children[1];
    Node eggs = list.children[1];
    h.click(Role.checkBox, "Milk");
    assert(shows(h, Role.label, "2 open"));
    h.click(Role.button, "Remove Milk");
    assert(list.children.length == 2 && list.children[0] is eggs, "Eggs kept its row");
    assert(shows(h, Role.label, "2 open"));
}

/// Log entry for the virtual list and the table.
struct Entry
{
    uint id;       /// key, also the order
    string level;  /// info, warn or error
    string text;   /// message
}

/// `n` made-up log entries.
Entry[] entries(uint n)
{
    static immutable string[] levels = ["info", "info", "info", "warn", "error"];
    Entry[] es;
    foreach (uint i; 0 .. n)
    {
        es ~= Entry(i, levels[i % levels.length], format("Message number %d", i));
    }
    return es;
}

/// Virtual list of `log`: only the rows in view exist. A row gets a getter of its entry, since a row node is
/// reused for other entries as the list scrolls.
Node logList(Entry[] log, Signal!uint selected)
{
    return scroll()(virtualList!(uint, Entry)(items: () => log, key: (Entry e) => e.id,
        row: (Entry delegate() e) => logRow(selected, e), selected: selected));
}

/// Row reading its entry through `e`, inside bindings.
Node logRow(Signal!uint selected, Entry delegate() e)
{
    return listItem(onClick: () { selected.set(e().id); }, selected: () => selected.get == e().id)(row(gap: 8)(
        sized(w: 48)(label(() => e().level, "muted")),
        expanded(label(() => e().text)),
    ));
}

/// A long list builds only the rows in view, and pooled rows show the entry they took.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    Signal!uint selected = signal(uint.max);
    scope Scope root = effectScope(() { h.setRoot(logList(entries(100_000), selected)); });
    h.frame();
    VirtualList!(uint, Entry) list = cast(VirtualList!(uint, Entry)) h.tree.content.children[0];
    assert(list.built < 40);
    h.click(Role.listBoxOption, "info Message number 2");
    assert(selected.peek == 2);
    h.injectKey(Key.end);
    h.frame();
    assert(selected.peek == 99_999 && shows(h, Role.listBoxOption, "error Message number 99999"));
    assert(list.built < 60, "the end of the list reuses the rows that left the view");
}

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

/// Folder for the tree.
final class Folder
{
    string path;     /// key
    string name;     /// shown
    Folder[] kids;   /// subfolders

    /// Creates a folder.
    this(string path, Folder[] kids...)
    {
        import std.path : baseName;

        this.path = path;
        name = baseName(path);
        this.kids = kids.dup;
    }
}

/// Tree of folders under `root`.
Node folderTree(Folder root, Signal!string selected)
{
    return treeView!(string, Folder)(() => root.kids, (Folder f) => f.kids, (Folder f) => f.path,
        (Folder delegate() f) => label(() => f().name), selected);
}

/// The table sorts by a title click, and the tree shows children once expanded.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(600, 400);
    scope (exit)
    {
        h.close();
    }
    Signal!uint row = signal(uint.max);
    Signal!string folder = signal("");
    Folder root = new Folder("", new Folder("src", new Folder("src/app"), new Folder("src/lib")), new Folder("docs"));
    TreeView!(string, Folder) tree;
    scope Scope s = effectScope(() {
        tree = cast(TreeView!(string, Folder)) folderTree(root, folder);
        h.setRoot(column()(sized(h: 200)(logTable(entries(50), row)), expanded(tree)));
    });
    h.frame();
    h.click(Role.columnHeader, "Level");
    assert(h.find(Role.row, "4, error, Message number 4").bounds.y == h.find(Role.columnHeader, "#").bounds.bottom);
    assert(shows(h, Role.treeItem, "app") == false);
    tree.expand("src");
    h.frame();
    assert(shows(h, Role.treeItem, "app"));
}
