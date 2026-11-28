/// Gallery pages: one function per page, each showing a widget in its variants and states.
///
/// Pages are built once and kept, so their state survives switching. Each loop body that makes closures
/// calls a helper function, because closures made directly in a loop body share one frame.
module gallery.pages;

import dentrite.command;
import dentrite.containers;
import dentrite.dock;
import dentrite.host : Host, LibraryStyles;
import dentrite.image : Image;
import dentrite.draw;
import dentrite.immediate;
import dentrite.island : island;
import dentrite.platform : FileDialogKind, FileFilter;
import dentrite.node;
import dentrite.signals;
import dentrite.sdlimage : canLoadImages, loadImage;
import dentrite.theme : Variants;
import dentrite.tray : Tray, tray;
import dentrite.widgets.button;
import dentrite.widgets.checkbox;
import dentrite.widgets.combobox;
import dentrite.widgets.dialog;
import dentrite.widgets.icons;
import dentrite.widgets.image;
import dentrite.widgets.label;
import dentrite.widgets.link;
import dentrite.widgets.list;
import dentrite.widgets.menu;
import dentrite.widgets.progress;
import dentrite.widgets.radio;
import dentrite.widgets.slider;
import dentrite.widgets.spinbox;
import dentrite.widgets.splitview;
import dentrite.widgets.table;
import dentrite.widgets.tabs;
import dentrite.widgets.textarea;
import dentrite.widgets.textbox;
import dentrite.widgets.tooltip : commandTip;
import dentrite.widgets.tree;
import std.algorithm.iteration : map;
import std.algorithm.searching : canFind, count, countUntil;
import std.algorithm.comparison : clamp, max, min;
import std.array : array, join;
import std.format : format;
import std.meta : AliasSeq;
import std.path : baseName;
import std.random : Random, choice, uniform;
import std.range : iota;
import std.math : abs, sin, sqrt;
import std.string : toLower;

/// Styles the gallery theme may set: the library's, its own button variant and the chat page's.
alias GalleryStyles = AliasSeq!(LibraryStyles, Variants!(ButtonStyle, "large"),
    Variants!(PanelStyle, "bubble", "bubbleMine"),
    Variants!(TextStyle, "bubbleMine", "bubbleTime", "name0", "name1", "name2", "name3"),
    Variants!(TextStyle, "tabular", "fractions", "superscript", "slashedZero", "ss01", "noContextual"),
    Variants!(TextAreaStyle, "codePlain"));

/// Gallery page: sidebar title, one line about it, and its content.
struct Page
{
    string name;           /// sidebar title, also the `--page` name and `--shots` file name
    string blurb;          /// line under the page title
    Node delegate() build; /// content, built once
}

/// State shared by the pages and the window's menu bar.
final class Gallery
{
    Signal!string lastAction; /// label of the menu item chosen last
    Signal!bool wrap;         /// "Word wrap" in the View menu
    Host host;                /// window, for dialogs

    /// Creates the signals, with window `h` for dialogs.
    this(Host h)
    {
        lastAction = signal("none yet");
        wrap = signal(true);
        host = h;
    }

    /// Action recording that `label` was chosen.
    void delegate() note(string label)
    {
        return () { lastAction.set(label); };
    }
}

/// Every page, in sidebar order.
Page[] pages(Gallery g)
{
    return [
        Page("Buttons", "Variants, icons, the disabled look and a click counter.", () => buttonsPage()),
        Page("Check boxes", "Boxes bound to signals, with and without captions.", () => checkboxesPage()),
        Page("Radio buttons", "One choice among options, grouped by the signal they share.", () => radiosPage()),
        Page("Text", "Label variants from the theme, wrapping and alignment.", () => textPage()),
        Page("Links", "Text that opens an address in the browser or runs an action.", () => linksPage()),
        Page("Text boxes", "Single-line editing bound to signals.", () => textBoxesPage()),
        Page("Text areas", "Multi-line editing: wrapping, code with line numbers, undo.", () => textAreasPage()),
        Page("Spin boxes", "Numbers typed or stepped with buttons, keys and the wheel.", () => spinBoxesPage()),
        Page("Combo boxes", "Drop-down lists, editable boxes with suggestions, long lists.", () => comboPage()),
        Page("Sliders", "A number in a range, dragged or stepped with keys.", () => slidersPage()),
        Page("Progress bars", "Work done as a fraction, or busy when unknown.", () => progressPage()),
        Page("Images", "Pictures in each fit, tinted, at 2x, as icons and opened from files.", () => imagesPage(g)),
        Page("Tabs", "Tab views over pages, and tab bars with closable tabs.", () => tabsPage()),
        Page("Menus", "Menu bar, popup menus from a button, context menus.", () => menusPage(g)),
        Page("Dialogs", "Modal dialogs over a scrim, and the system's file dialogs.", () => dialogsPage(g)),
        Page("Tray icon", "An icon in the system tray with a menu that brings the window back.",
            () => trayPage(g)),
        Page("Tooltips", "Text shown after resting the pointer on a node.", () => tooltipsPage()),
        Page("Lists", "Keyed rows rebuilt from a signal, and a virtual list of 100,000 rows.", () => listsPage()),
        Page("Chat feed", "A feed that follows new messages, loads older ones above and caps what it keeps.",
            () => chatPage()),
        Page("Trees", "Hierarchies that expand and collapse, listing only the rows in view.", () => treesPage()),
        Page("Tables", "Columns that sort and resize over a virtual list of rows.", () => tablesPage()),
        Page("Layout", "Rows, columns, padding, panels, separators, flex and scrolling.", () => layoutPage()),
        Page("Grids and stacks", "Cells in rows of equal columns, and children on top of each other.",
            () => gridsPage()),
        Page("Adaptive", "Layouts that change with the window size or the space they get.", () => adaptivePage(g)),
        Page("Dock", "Tab stacks and splits. Drag tabs to dock or float them, double click a tab bar for a new tab, "
            ~ "drop files on a stack to open them there.", () => dockPage(g)),
        Page("Islands", "Immediate-mode code on the same layout and renderer.", () => islandsPage()),
    ];
}

/// Page `p` built, under its title and blurb, in a scroll view.
Node pageView(Page p)
{
    return panel(variant: "pane")(scroll()(pad(x: 24, y: 20)(column(gap: 22)(
        column(gap: 4)(label(p.name, "title"), label(p.blurb, "muted")),
        p.build(),
    ))));
}

/// Titled group of examples.
Node section(string title, Node content)
{
    return column(gap: 10)(label(title, "strong"), content);
}

/// Row of examples, centered on the cross axis.
Node line(Node[] kids...)
{
    return row(gap: 10)(kids.dup);
}

/// `n` at width `w`, also inside a column that stretches its children.
Node narrow(float w, Node n)
{
    return row()(sized(w: w)(n));
}

/// Example with a caption under it.
Node captioned(string caption, Node example)
{
    return column(gap: 4, cross: CrossAlign.start)(example, label(caption, "muted"));
}

/// Buttons: variants, icons, enabling and a counter.
Node buttonsPage()
{
    Signal!bool on = signal(true);
    Signal!int clicks = signal(0);
    return column(gap: 40)(
        section("Variants", line(
            button("Default"),
            button("Primary", variant: "primary"),
            button("Danger", variant: "danger"),
            button("Toolbar", variant: "toolbar"),
            button("Large, the gallery's own", variant: "large"),
        )),
        section("Icons", line(
            button("Run", icon: Icon.play),
            button("Pause", icon: Icon.pause),
            button("Step", icon: Icon.stepOver, variant: "toolbar"),
            button("Add", icon: Icon.plus, variant: "toolbar"),
            button(null, icon: Icon.stop, variant: "toolbar", tooltip: "Icon only"),
        )),
        section("Enabled", column(gap: 10, cross: CrossAlign.start)(
            checkbox(on, "Enable the buttons below"),
            line(
                button("Default", enabled: &on.get),
                button("Primary", variant: "primary", enabled: &on.get),
                button("Danger", variant: "danger", enabled: &on.get),
                button("Toolbar", icon: Icon.plus, variant: "toolbar", enabled: &on.get),
            ),
        )),
        section("Clicks", line(
            button("Click me", onClick: () { clicks.set(clicks.peek + 1); }),
            button("Reset", onClick: () { clicks.set(0); }, variant: "toolbar"),
            label(() => clicks.get == 1 ? "Clicked once" : format("Clicked %d times", clicks.get), "muted"),
        )),
    );
}

/// Check boxes bound to signals.
Node checkboxesPage()
{
    Signal!bool bold = signal(true);
    Signal!bool italic = signal(false);
    Signal!bool under = signal(false);
    Signal!bool bare = signal(true);
    Signal!bool enabled = signal(false);
    return column(gap: 22)(
        section("Bound to signals", column(gap: 8, cross: CrossAlign.start)(
            checkbox(bold, "Bold"),
            checkbox(italic, "Italic"),
            checkbox(under, "Underline", tooltip: "Underline the text"),
            label(() => format("Style: %s%s%s", bold.get ? "bold " : "", italic.get ? "italic " : "",
                under.get ? "underline" : ""), "muted"),
        )),
        section("Without a caption", line(checkbox(bare), label(() => bare.get ? "on" : "off", "mono"))),
        section("Two boxes, one signal", line(checkbox(italic, "Italic"), checkbox(italic, "Italic again"))),
        section("Disabled", column(gap: 8, cross: CrossAlign.start)(
            checkbox(enabled, "Enable the boxes below"),
            line(checkbox(bold, "Bold", enabled: &enabled.get), checkbox(under, "Underline", enabled: &enabled.get)),
        )),
    );
}

/// Links to addresses, links running actions, inside a sentence and disabled.
Node linksPage()
{
    enum string repo = "https://github.com/dd86k/dentrite";
    enum string guide = "https://dd86k.github.io/dendrite/";
    Signal!int count = signal(0);
    Signal!bool enabled = signal(false);
    return column(gap: 22)(
        section("To an address", column(gap: 8, cross: CrossAlign.start)(
            link("dentrite on GitHub", repo, tooltip: repo),
            label("Opens with the system's browser. The tooltip shows where it goes.", "muted"),
        )),
        section("Running an action", line(link("Count", onActivate: () { count.set(count.peek + 1); }),
            label(() => format("clicked %d times", count.get), "mono"))),
        section("In a sentence", row()(label("Read the "), link("usage guide", guide), label(" first."))),
        section("Disabled", column(gap: 8, cross: CrossAlign.start)(
            checkbox(enabled, "Enable the link below"),
            link("API reference", guide ~ "api/", enabled: &enabled.get),
        )),
    );
}

/// Label variants, wrapping and alignment.
Node textPage()
{
    Node[] variants;
    foreach (string v; ["", "muted", "strong", "heading", "title", "accent", "warn", "error", "mono", "monoMuted",
        "changed"])
    {
        variants ~= row(gap: 16)(sized(w: 110)(label(v.length == 0 ? "(default)" : v, "monoMuted")),
            label("The quick brown fox jumps over the lazy dog", v));
    }
    Node[] features;
    foreach (string[3] f; [["tabular", "", "11:11 08:47"], ["fractions", "", "1/2 3/4 15/16"],
        ["superscript", "", "123"], ["slashedZero", "", "0x0040_1000"], ["ss01", "", "1234567890"],
        ["noContextual", "mono", "a -> b != c <= d"]])
    {
        features ~= row(gap: 16)(sized(w: 110)(label(f[0], "monoMuted")), sized(w: 160)(label(f[2], f[1])),
            label(f[2], f[0]));
    }
    string para = "Labels wrap at word boundaries when given wrap: true. This paragraph wraps to the width of "
        ~ "the page, so resizing the window rewraps it. Only labels whose width changed are measured again.";
    return column(gap: 22)(
        section("Variants", column(gap: 6)(variants)),
        section("Wrapping", label(para, wrap: true)),
        section("Fallback fonts", column(gap: 6)(
            label("Characters the theme font lacks come from fallback files or system fonts."),
            label("Ελληνικά, Кириллица, 中文, 日本語, 한국어, ∑ ∫ ≠ → ★ ☂"),
            label("Mono: Ελληνικά 中文 ★", "mono"),
            label("Emoji: 😀 ⭐ 👍🏽 🇯🇵 ❤️ 1️⃣ 👩‍💻 ★ ☂"),
        )),
        section("OpenType features", column(gap: 6)(features)),
        section("Alignment", column(gap: 6, cross: CrossAlign.start)(
            alignedLabel("Start", TextAlign.start),
            alignedLabel("Center", TextAlign.center),
            alignedLabel("End", TextAlign.end),
        )),
    );
}

/// Label aligned by `a` in a 320 px panel.
private Node alignedLabel(string text, TextAlign a)
{
    return sized(w: 320)(panel(variant: "header")(label(text, align_: a)));
}

/// Text boxes bound to signals.
Node textBoxesPage()
{
    Signal!string name = signal("");
    Signal!string shared_ = signal("Edit me in either box");
    Signal!bool editable = signal(false);
    Signal!string secret = signal("");
    TextBox nameBox = textBox(name, placeholder: "Your name");
    return column(gap: 22)(
        section("Placeholder and binding", column(gap: 8)(
            row(gap: 8)(label("Name", for_: nameBox), narrow(272, nameBox)),
            label(() => name.get.length == 0 ? "Type a name above" : "Hello, " ~ name.get ~ "!", "muted",
                live: Live.polite),
        )),
        section("Two boxes, one signal", column(gap: 8)(
            narrow(320, textBox(shared_)),
            narrow(320, textBox(shared_, tooltip: "Same signal as the box above")),
            label(() => format("%d characters", shared_.get.length), "muted"),
        )),
        section("Disabled", column(gap: 8, cross: CrossAlign.start)(
            checkbox(editable, "Editable"),
            narrow(320, textBox(shared_, enabled: &editable.get)),
        )),
        section("Password", column(gap: 8)(
            narrow(320, textBox(secret, placeholder: "Password", password: true)),
            label(() => format("%d characters, kept off the clipboard", secret.get.count), "muted"),
        )),
        section("Keys", label("Arrows, Home and End move, Shift selects, Ctrl moves by word, Ctrl+A selects all, "
            ~ "Ctrl+C, X and V use the clipboard, Ctrl+Backspace deletes a word. A dead key's accent or other "
            ~ "input method text shows underlined until the next key commits it.", "muted", wrap: true)),
    );
}

/// Fruit for the enum combo box.
enum Fruit
{
    apple,  /// red
    banana, /// yellow
    cherry, /// dark red
    grape,  /// purple
}

/// Color names suggested by the editable combo box.
immutable string[] colorNames = ["amber", "aqua", "azure", "beige", "black", "blue", "bronze", "brown", "coral",
    "crimson", "cyan", "gold", "gray", "green", "indigo", "ivory", "khaki", "lavender", "lemon", "lilac", "lime",
    "magenta", "maroon", "mint", "navy", "olive", "orange", "orchid", "peach", "pink", "plum", "purple", "red",
    "rose", "ruby", "salmon", "sand", "silver", "tan", "teal", "turquoise", "violet", "white", "yellow"];

/// Combo boxes: enum, fixed strings, editable, long and disabled.
Node comboPage()
{
    Signal!Fruit fruit = signal(Fruit.banana);
    Signal!string build = signal("Release");
    Signal!string color = signal("");
    Signal!size_t item = signal(size_t(4242));
    size_t[] many = iota(size_t(0), size_t(100_000)).array;
    return column(gap: 22)(
        section("Enum and strings", line(
            captioned("Enum members", comboBox(fruit)),
            captioned("Fixed strings", comboBox(["Debug", "Release", "Profile"], build)),
            label(() => format("%s, %s", fruit.get, build.get), "muted"),
        )),
        section("Editable", column(gap: 8, cross: CrossAlign.start)(
            sized(w: 240)(comboBox(colorNames.dup, color, editable: true, placeholder: "Type a color")),
            label(() => color.get.length == 0 ? "Typing filters the suggestions"
                : canFind(colorNames, color.get) ? "Known color: " ~ color.get : "Not in the list: " ~ color.get,
                "muted"),
        )),
        section("100,000 items", line(
            sized(w: 200)(comboBox(many, item, label: (size_t i) => format("Item %,d", i))),
            label("The popup is a virtual list. Type to jump to an item.", "muted"),
        )),
        section("Disabled", line(comboBox(fruit, enabled: () => false))),
    );
}

/// Menus: popup from a button, context menu, and the menu bar's last action.
Node menusPage(Gallery g)
{
    Button options = button("Options", icon: Icon.chevronDown);
    Menu m = popupMenu(
        menuItem("&Rename", g.note("Rename"), keys: "F2"),
        menuItem("&Duplicate", g.note("Duplicate"), keys: "Ctrl+D"),
        menuSeparator(),
        menu("&Export as")(menuItem("&PNG", g.note("Export as PNG")), menuItem("&SVG", g.note("Export as SVG"))),
        menuSeparator(),
        menuItem("De&lete", g.note("Delete"), enabled: () => false),
    );
    options.onClick = () { m.toggle(options); };
    Button recent = button("Open recent", icon: Icon.chevronDown);
    Node[] files;
    foreach (int i; 1 .. 41)
    {
        string name = format("project-%02d.d", i);
        files ~= menuItem(name, g.note("Open " ~ name));
    }
    Menu long_ = popupMenu(files);
    recent.onClick = () { long_.toggle(recent); };
    Button cornerButton = button("Corner menu", icon: Icon.chevronDown);
    Menu corner = popupMenu(
        menuItem("&First", g.note("First")),
        menuItem("&Second", g.note("Second")),
        menu("&More")(menuItem("&Third", g.note("Third")), menuItem("F&ourth", g.note("Fourth"))),
    );
    cornerButton.onClick = () {
        Size vp = cornerButton.tree.viewport;
        corner.openAt(cornerButton.tree, Point(vp.w - 4, vp.h - 4));
    };
    Node area = contextMenu(
        menuItem("&Cut", g.note("Cut"), keys: "Ctrl+X"),
        menuItem("C&opy", g.note("Copy"), keys: "Ctrl+C"),
        menuItem("&Paste", g.note("Paste"), keys: "Ctrl+V"),
        menuSeparator(),
        menuItem("&Word wrap", () { g.wrap.set(g.wrap.peek == false); }, checked: &g.wrap.get),
    )(sized(h: 90)(panel(variant: "header")(column(cross: CrossAlign.center)(
        spacer(), label("Right-click here, or focus and press Shift+F10", "muted"), spacer()))));
    return column(gap: 22)(
        section("Last action", label(() => "Last chosen: " ~ g.lastAction.get, "accent")),
        section("Menu bar", label("The menu bar above has submenus, shortcuts, a checked item and a disabled one. "
            ~ "Alt plus the underlined letter opens a menu, then arrows, Enter and letters.", "muted", wrap: true)),
        section("Popup menu", line(options, label("Opens below the button, flips up near the bottom.", "muted"))),
        section("Long menu", line(recent, label("Items past the room scroll, with the wheel, the thumb or the "
            ~ "arrow keys.", "muted"))),
        section("Past the window", line(cornerButton,
            label("Opens at the window's bottom-right corner and reaches past it.", "muted"))),
        section("Context menu", area),
        section("Word wrap", label(() => g.wrap.get ? "Word wrap is on" : "Word wrap is off", "muted")),
    );
}

/// Tooltips on buttons and labels.
Node tooltipsPage()
{
    Command save = command("&Save", () {}, keys: "Ctrl+S");
    string tall = "Tooltips wrap past their maximum width. This one is long enough to show it. Near the "
        ~ "window edges it reaches past them in a popup window of its own.";
    return column(gap: 22)(
        section("On buttons", line(
            button("Plain", tooltip: "A short tooltip"),
            button("Save", tooltip: commandTip(save)),
            button("Long", tooltip: tall),
            button("None"),
        )),
        section("On labels", line(label("Hover this label", "accent", tooltip: "Labels take tooltips too"))),
        section("Behavior", label("A tooltip shows after resting 500 ms. Moving to another node while one is "
            ~ "shown shows the next at once. Pressing a button or a key hides it until the pointer leaves. Tab to "
            ~ "a button shows its tooltip below it.",
            "muted", wrap: true)),
    );
}

/// Keyed list with add and remove, and a virtual list.
Node listsPage()
{
    Signal!(string[]) tasks = signal(["Write the gallery", "Add radio buttons", "Add a slider"]);
    Signal!string entry = signal("");
    Signal!string picked = signal("");
    Signal!size_t selected = signal(size_t.max);
    size_t[] rows = iota(size_t(0), size_t(100_000)).array;
    void add()
    {
        if (entry.peek.length > 0 && canFind(tasks.peek, entry.peek) == false)
        {
            tasks.set(tasks.peek ~ entry.peek);
            entry.set("");
        }
    }

    VirtualList!(size_t, size_t) big = virtualList!(size_t, size_t)(items: () => rows, key: (size_t i) => i,
        row: (size_t delegate() r) => bigRow(selected, r), selected: selected);
    return column(gap: 22)(
        section("Keyed list", column(gap: 8)(
            row(gap: 8)(sized(w: 260)(textBox(entry, placeholder: "New task")), button("Add", onClick: &add,
                icon: Icon.plus)),
            narrow(420, panel(variant: "header")(keyedColumn(() => tasks.get, (string t) => t,
                (string t) => taskRow(tasks, picked, t)))),
            label(() => picked.get.length == 0 ? "Click a row to select it" : "Selected: " ~ picked.get, "muted"),
        )),
        section("Virtual list", column(gap: 8)(
            narrow(420, sized(h: 240)(panel(variant: "pane")(scroll()(big)))),
            label(() => selected.get == size_t.max ? "Only the rows in view exist as nodes"
                : format("Selected row %,d", selected.get), "muted"),
        )),
        section("Keys", label("Each list is one Tab stop, at its selected row. Up and Down move the selection, "
            ~ "Home and End go to the ends, and in the virtual list Page Up and Page Down move by a view. "
            ~ "Typing selects the next row starting with the typed letters, such as the page names on the left.",
            "muted", wrap: true)),
    );
}

/// Row of task `t`: selectable, with a remove button.
private Node taskRow(Signal!(string[]) tasks, Signal!string picked, string t)
{
    import std.algorithm.iteration : filter;

    return listItem(onClick: () { picked.set(t); }, selected: () => picked.get == t)(row(gap: 8)(
        iconView(Icon.check, variant: "muted"),
        expanded(label(t)),
        button("Remove", onClick: () { tasks.set(tasks.peek.filter!(x => x != t).array); }, variant: "toolbar"),
    ));
}

/// Row of the virtual list showing the index `r` returns.
private Node bigRow(Signal!size_t selected, size_t delegate() r)
{
    return listItem(onClick: () { selected.set(r()); }, selected: () => selected.get == r())(row(gap: 8)(
        bigIcon(r),
        expanded(label(() => format("Row %,d", r()))),
        label(() => format("%08X", r() * 2_654_435_761 & 0xffff_ffff), "monoMuted"),
    ));
}


/// Senders of the sample chat messages, each with a name color in the theme.
private immutable string[] chatAuthors = ["Ada", "Brook", "Cyd", "Dee"];

/// Message of the chat page.
private struct Message
{
    long id;       /// order, older messages lower
    string author; /// sender
    string text;   /// body, wrapped in its bubble
    bool first;    /// first of a run from one sender, which shows the name and time
}

/// Sample message `id`, with a body whose length varies with the id. Senders write two or three in a row, and
/// the next run is always someone else, since `run * 2 + bit` differs by 1 to 3.
private Message sampleMessage(long id)
{
    static immutable string[] words = ["the", "build", "passed", "again", "after", "moving", "rows", "into", "a",
        "pool", "so", "memory", "stays", "flat", "while", "messages", "keep", "coming", "in"];
    Random rng = Random(cast(uint) id);
    string[] w;
    foreach (_; 0 .. uniform(2, 32, rng))
    {
        w ~= choice(words, rng);
    }
    long run = id >= 0 ? id * 2 / 5 : (id * 2 - 4) / 5;
    Random runRng = Random(cast(uint) run);
    long bit = uniform(0, 2, runRng);
    return Message(id, chatAuthors[((run * 2 + bit) % 4 + 4) % 4], w.join(" "));
}

/// `ms` with `first` set on each message whose sender differs from the one before, changed in place.
private Message[] grouped(Message[] ms)
{
    foreach (size_t i, ref Message m; ms)
    {
        m.first = i == 0 || ms[i - 1].author != m.author;
    }
    return ms;
}

/// Time of day shown for message `id`, three messages a minute from noon.
private string clockOf(long id)
{
    long t = ((12 * 60 + id / 3) % 1440 + 1440) % 1440;
    return format("%02d:%02d", t / 60, t % 60);
}

/// Chat feed: a virtual list following the end, older messages loaded above, and a cap on kept messages.
Node chatPage()
{
    enum size_t keep = 1000; /// messages kept once twice as many arrived
    Signal!(Message[]) log = signal(grouped(iota(-200L, 0L).map!sampleMessage.array));
    Signal!string draft = signal("");
    long next = 0;
    /// Appends `more`, dropping the oldest past the cap.
    void post(Message[] more)
    {
        Message[] all = log.peek ~ more;
        log.set(grouped(all.length > 2 * keep ? all[$ - keep .. $] : all));
    }

    /// Sends the draft as a message from "You".
    void send()
    {
        if (draft.peek.length > 0)
        {
            post([Message(next++, "You", draft.peek)]);
            draft.set("");
        }
    }

    /// Prepends 50 messages older than the oldest kept.
    void loadOlder()
    {
        long oldest = log.peek.length > 0 ? log.peek[0].id : next;
        log.set(grouped(iota(oldest - 50, oldest).map!sampleMessage.array ~ log.peek));
    }

    /// Appends 100 sample messages.
    void burst()
    {
        post(iota(next, next + 100).map!sampleMessage.array);
        next += 100;
    }

    Command sendCmd = command("Send", &send, keys: "Enter");
    VirtualList!(long, Message) feed = virtualList!(long, Message)(items: () => log.get,
        key: (Message m) => m.id, row: (Message delegate() m) => messageRow(m));
    return column(gap: 22)(
        section("Feed", column(gap: 8)(
            narrow(520, sized(h: 360)(panel(variant: "pane")(scroll(follow: true)(feed)))),
            row(gap: 8)(
                sized(w: 240)(shortcuts([sendCmd])(textBox(draft, placeholder: "Message", accessName: "Message"))),
                button("Send", onClick: &send),
                button("Burst of 100", onClick: &burst),
                button("Load older", onClick: &loadOlder),
            ),
            label(() => format("%,d messages kept, #%d to #%d", log.get.length,
                log.get.length > 0 ? log.get[0].id : 0, log.get.length > 0 ? log.get[$ - 1].id : 0), "muted"),
        )),
        section("Memory", label("Row nodes exist only for the messages in view and are reused as the feed "
            ~ "scrolls, so a long feed costs its messages, not its widgets. The page keeps at most "
            ~ format("%,d", 2 * keep) ~ " messages and drops the oldest down to " ~ format("%,d", keep) ~ ". "
            ~ "Measured heights follow their messages, and the message at the top of the view stays in place "
            ~ "when older ones load above or are dropped. Scrolled to the end, the feed follows new messages.",
            "muted", wrap: true)),
    );
}

/// Line of the chat feed holding one bubble, at most three quarters of the width, on the right for the user's
/// own messages. A run from one sender sits closer together.
private final class BubbleLine : Node
{
    bool mine;  /// the user's own message, placed on the right
    bool first; /// first of a run, with more space above

    /// Wraps `bubble`.
    this(Node bubble)
    {
        add(bubble);
    }

    /// Bubble at its natural width up to three quarters of the line, clear of the scroll bar on the right.
    protected override Size performLayout(Constraints c)
    {
        import std.math : isInfinity;

        float w = isInfinity(c.maxW) ? c.minW : c.maxW;
        float inner = max(0f, w - 28);
        Size s = children[0].layout(Constraints(0, inner * 0.75f, 0, float.infinity));
        float above = first ? 10 : 3;
        children[0].offset = Point(mine ? 10 + inner - s.w : 10, above);
        return Size(w, above + s.h + 3);
    }
}

/// Inside of a chat bubble: the text, under the sender's name on the left and the time on the right when the
/// head shows. As wide as the wider of the text and the head.
private final class BubbleBody : Node
{
    private Node name; /// sender's name
    private Node time; /// time of day
    private Node text; /// message body

    /// Creates the body with its head shown.
    this(Node name, Node time, Node text)
    {
        this.name = name;
        this.time = time;
        this.text = text;
        setChildren([name, time, text]);
    }

    /// Shows or hides the name and time.
    void showHead(bool on)
    {
        setChildren(on ? [name, time, text] : [text]);
    }

    /// Text wrapped to the width allowed, head spread over the bubble's width.
    protected override Size performLayout(Constraints c)
    {
        Size t = text.layout(Constraints(0, c.maxW, 0, float.infinity));
        if (children.length == 1)
        {
            text.offset = Point.init;
            return t;
        }
        Constraints loose = Constraints(0, float.infinity, 0, float.infinity);
        Size n = name.layout(loose);
        Size m = time.layout(loose);
        float w = min(c.maxW, max(t.w, n.w + 16 + m.w));
        float headH = max(n.h, m.h);
        name.offset = Point(0, headH - n.h);
        time.offset = Point(w - m.w, headH - m.h);
        text.offset = Point(0, headH + 2);
        return Size(w, headH + 2 + t.h);
    }
}

/// Row of the chat feed: a bubble around the message `m` returns. Other senders' runs start with the name, in
/// the sender's color, and the time. The row is reused for other messages, so an effect restyles it.
private Node messageRow(Message delegate() m)
{
    import std.algorithm.searching : countUntil;

    Label name = label(() => m().author, "name0");
    Label text = label(() => m().text, wrap: true);
    BubbleBody content = new BubbleBody(name, label(() => clockOf(m().id), "bubbleTime"), text);
    Panel bubble = panel(variant: "bubble")(content);
    BubbleLine line = new BubbleLine(bubble);
    effect(() {
        Message msg = m();
        bool mine = msg.author == "You";
        untracked(() {
            line.mine = mine;
            line.first = msg.first;
            bubble.variant = mine ? "bubbleMine" : "bubble";
            text.setVariant(mine ? "bubbleMine" : null);
            name.setVariant(format("name%d", max(0, chatAuthors.countUntil(msg.author))));
            content.showHead(msg.first && mine == false);
            line.markNeedsLayout();
        });
    });
    return line;
}

/// Containers: rows and columns, padding, panels, separators, flex and scrolling.
Node layoutPage()
{
    Node[] panels;
    foreach (string v; ["header", "toolbar", "pane", "status", "popup"])
    {
        panels ~= captioned(v, sized(w: 120, h: 48)(panel(variant: v)(label("panel", "muted"))));
    }
    Node[] lines;
    foreach (int i; 1 .. 31)
    {
        lines ~= label(format("Line %d of 30", i));
    }
    return column(gap: 22)(
        section("Panel variants", line(panels)),
        section("Cross alignment", line(
            captioned("start", box(CrossAlign.start)),
            captioned("center", box(CrossAlign.center)),
            captioned("end", box(CrossAlign.end)),
        )),
        section("Flex", column(gap: 6)(
            row(gap: 6)(expanded(block("1")), expanded(block("2"), 2), expanded(block("1"))),
            row(gap: 6)(block("fixed"), spacer(), block("pushed right")),
        )),
        section("Separators", sized(h: 40)(row(gap: 12)(label("left"), vrule(), label("middle"), vrule(),
            label("right")))),
        section("Scroll view", narrow(260, sized(h: 140)(panel(variant: "pane")(scroll()(pad(x: 10, y: 6)(
            column(gap: 2)(lines))))))),
    );
}

/// Row of three blocks of different heights placed by `a`, in a panel.
private Node box(CrossAlign a)
{
    return sized(h: 80)(panel(variant: "header")(row(gap: 6, cross: a)(
        sized(w: 24, h: 20)(panel(variant: "popup")(new Fixed(Size.init))),
        sized(w: 24, h: 40)(panel(variant: "popup")(new Fixed(Size.init))),
        sized(w: 24, h: 60)(panel(variant: "popup")(new Fixed(Size.init))),
    )));
}

/// Panel holding `text`, for the flex examples.
private Node block(string text)
{
    return panel(variant: "popup")(pad(x: 8, y: 6)(label(text, "muted")));
}


/// Grids with fixed and fitted columns, and stacks.
Node gridsPage()
{
    Node[] buttons;
    foreach (string s; ["New", "Open", "Save", "Import", "Export", "Quit"])
    {
        buttons ~= button(s, variant: "large");
    }
    Node[] tiles;
    foreach (int i; 1 .. 15)
    {
        tiles ~= sized(h: 64)(panel(variant: "popup")(pad(x: 8, y: 6)(label(format("Tile %d", i), "muted"))));
    }
    return column(gap: 22)(
        section("Fixed columns", sized(h: 160)(grid(cols: 3, gap: 8)(buttons))),
        section("Columns that fit", column(gap: 6)(
            label("At least 120 px each, as many as the width allows. Resize the window.", "muted"),
            grid(minCell: 120, gap: 8)(tiles),
        )),
        section("Stack", line(
            captioned("centered", stack(x: CrossAlign.center, y: CrossAlign.center)(
                sized(w: 64, h: 64)(panel(variant: "popup")(new Fixed(Size.init))),
                label("DD", "title"),
            )),
            captioned("aligned badge", stack()(
                sized(w: 64, h: 64)(panel(variant: "popup")(new Fixed(Size.init))),
                aligned(x: CrossAlign.end, y: CrossAlign.end)(panel(variant: "header")(pad(x: 5, y: 1)(
                    label("3", "accent")))),
            )),
            captioned("stretched background", stack()(
                aligned(x: CrossAlign.stretch, y: CrossAlign.stretch)(panel(variant: "popup")(new Fixed(Size.init))),
                pad(x: 14, y: 10)(label("Sized by this text")),
            )),
        )),
    );
}
/// Window breakpoint, and a squeeze, split views and a width cap at the width a slider sets.
Node adaptivePage(Gallery g)
{
    Computed!bool narrowWindow = g.host.breakpoint(maxW: 900);
    Signal!float width = signal(640f);
    Node bar = panel(variant: "toolbar")(squeeze()(
        fits(minW: 560)(row(gap: 6)(
            button("Play", icon: Icon.play, variant: "toolbar"),
            button("Pause", icon: Icon.pause, variant: "toolbar"),
            button("Stop", icon: Icon.stop, variant: "toolbar"),
            spacer(),
            label("Track 3 of 12: Night Drive", "muted"),
        )),
        fits(minW: 300)(row(gap: 6)(
            button("", icon: Icon.play, variant: "toolbar", accessName: "Play"),
            button("", icon: Icon.pause, variant: "toolbar", accessName: "Pause"),
            button("", icon: Icon.stop, variant: "toolbar", accessName: "Stop"),
            spacer(),
            label("Track 3 of 12", "muted"),
        )),
        row(gap: 6)(button("", icon: Icon.play, variant: "toolbar", accessName: "Play"), label("3/12", "muted")),
    ));
    return column(gap: 22)(
        section("Window breakpoint", column(gap: 6, cross: CrossAlign.start)(
            label("True while the window is at most 900 px wide. Resize the window.", "muted"),
            label(() => narrowWindow.get ? "Narrow window" : "Wide window", "accent"),
        )),
        column(gap: 6, cross: CrossAlign.start)(
            label("The examples below take the width this slider sets.", "muted"),
            row(gap: 10)(label("Width"), sized(w: 240)(slider(width, 200f, 800f, 10f, accessName: "Width")),
                label(() => format("%.0f px", width.get), "muted")),
        ),
        section("Squeeze", column(gap: 6, cross: CrossAlign.start)(
            label("The first bar that fits: 560 px and up, 300 px and up, else the last.", "muted"),
            atWidth(width, bar),
        )),
        section("Split view, navigating", column(gap: 6, cross: CrossAlign.start)(
            label("Below 500 px, one side at a time. Pick a folder, then go back.", "muted"),
            atWidth(width, sized(h: 200)(mailSplit())),
        )),
        section("Split view, drawer", column(gap: 6, cross: CrossAlign.start)(
            label("Below 500 px, the sidebar opens over the content from the menu button.", "muted"),
            atWidth(width, sized(h: 200)(drawerSplit())),
        )),
        section("Width cap", column(gap: 6, cross: CrossAlign.start)(
            label("At most 360 px wide, centered.", "muted"),
            atWidth(width, panel(variant: "pane")(pad(y: 8)(clamped(maxW: 360)(label(
                "Long text reads better in a narrow column. The cap keeps it narrow in a wide space and lets it "
                ~ "shrink with a narrow one.", wrap: true))))),
        )),
    );
}

/// `n` as wide as `width` says.
private Node atWidth(Signal!float width, Node n)
{
    Sized box = sized(w: width.peek)(n);
    effect(() {
        box.w = width.get;
        box.markNeedsLayout();
    });
    return box;
}

/// Folders beside the open folder, one at a time when narrow.
private Node mailSplit()
{
    Signal!string folder = signal("Inbox");
    Signal!bool shown = signal(true);
    Node[] items;
    foreach (string f; ["Inbox", "Sent", "Drafts"])
    {
        items ~= folderButton(f, folder, shown);
    }
    Node side = panel(variant: "pane")(pad(all: 6)(column(gap: 2, cross: CrossAlign.start)(items)));
    Node content = pad(x: 14, y: 10)(column(gap: 6)(
        label(() => folder.get, "strong"),
        label(() => format("Messages in %s would list here.", folder.get), "muted"),
    ));
    return splitView(shown, minW: 500, sideW: 160)(side, content);
}

/// Button opening folder `f` and showing it when collapsed.
private Node folderButton(string f, Signal!string folder, Signal!bool shown)
{
    return button(f, () {
        folder.set(f);
        shown.set(false);
    }, variant: "toolbar");
}

/// Sidebar as a drawer when narrow, opened by a menu button shown only then.
private Node drawerSplit()
{
    Signal!bool open = signal(false);
    Signal!bool folded = signal(false);
    Node toggle = button("", () { open.set(true); }, icon: Icon.menu, variant: "toolbar", accessName: "Sidebar");
    Flex head = row(gap: 6)();
    Node title = label("Document", "strong");
    effect(() {
        bool f = folded.get;
        head.setChildren(f ? [toggle, title] : [title]);
    });
    Node side = panel(variant: "pane")(pad(x: 10, y: 8)(column(gap: 4)(
        label("Outline", "strong"), label("Introduction"), label("Usage"), label("Limits"))));
    Node content = column()(panel(variant: "toolbar")(head), pad(x: 14, y: 10)(label("Body text.", "muted")));
    return splitView(open, minW: 500, sideW: 180, mode: Collapse.drawer, collapsed: folded)(side, content);
}

/// Dock view with four panes, opening files dropped on it through `g`'s window.
Node dockPage(Gallery g)
{
    DockSpace space = new DockSpace(DockNode.split(false, DockNode.stack("files", "search"),
        DockNode.split(true, DockNode.stack("editor"), DockNode.stack("output"))));
    space.root.shares = [1, 2.5f];
    space.root.children[1].shares = [2, 1];
    Node[string] panes = ["files": dockPane("Files", "A file tree would go here."),
        "search": dockPane("Search", "Search results would go here."),
        "editor": dockPane("Editor", "Drag a tab onto a drop button to dock it, onto a tab bar to move it there, "
            ~ "anywhere else to float it. Escape cancels. Ctrl+Shift+M moves the focused pane by the arrow keys, "
            ~ "Enter docks it. Ctrl+Shift+PgUp and PgDn reorder its tab."),
        "output": dockPane("Output", "Floating windows move by their tab bar and resize by their border.")];
    string[string] titles = ["files": "Files", "search": "Search", "editor": "Editor", "output": "Output"];
    DockView view = new DockView(space, panes, titles);
    Signal!int moved = signal(0);
    view.onLayout = () { moved.set(moved.peek + 1); };
    view.onCloseRequest = (string pane) {
        view.removePane(pane);
        moved.set(moved.peek + 1);
    };
    view.closable = (string pane) => pane != "editor";
    int notes;
    view.onBarDoubleClick = (DockNode stack) {
        string id = format("notes%d", ++notes);
        view.addPane(id, dockPane("Notes", "Double click a tab bar's empty part for another."), "Notes", stack);
        view.select(id);
        moved.set(moved.peek + 1);
    };
    g.host.onFileHover = (Point p) {
        if (view.tree !is null)
        {
            view.fileHover(p);
        }
    };
    g.host.onFileLeave = () { view.fileLeave(); };
    g.host.onFileDrop = (string[] paths, Point p) {
        DockNode stack = view.tree is null ? null : view.stackAt(p);
        if (stack is null)
        {
            return;
        }
        foreach (string path; paths)
        {
            view.addPane(path, dockPane(baseName(path), path), baseName(path), stack);
            view.select(path);
        }
        moved.set(moved.peek + 1);
    };
    view.setTabInfo((string pane) {
        switch (pane)
        {
        case "editor":
            return TabInfo(null, tooltip: "~/notes/editor.txt, unsaved", modified: true);
        case "search":
            return TabInfo(null, tooltip: "12 results", badge: "12");
        case "output":
            return TabInfo(null, tooltip: "Read only, building", locked: true, progress: 0.6f);
        default:
            return TabInfo.init;
        }
    });
    view.setTrailing((DockNode stack) => pad(x: 8)(label(() {
        moved.get;
        return format("%d", view.space.stacks().countUntil(stack) + 1);
    }, "muted")));
    view.tabMenu = (string pane) {
        MenuItem move = menuItem("&Move", () { view.startMove(pane); });
        return new Menu(pane == "editor" ? [move] : [move, menuItem("&Close", () { view.removePane(pane); })]);
    };
    Command move = command("Move pane", () { view.startMove(); }, keys: "Ctrl+Shift+M");
    Command left = command("Tab left", () { view.shiftTab(-1); }, keys: "Ctrl+Shift+PgUp");
    Command right = command("Tab right", () { view.shiftTab(1); }, keys: "Ctrl+Shift+PgDn");
    return shortcuts([move, left, right], window: true)(sized(h: 420)(view));
}

/// Pane content for the dock page.
private Node dockPane(string title, string text)
{
    return panel(variant: "pane")(pad(x: 14, y: 10)(column(gap: 6)(label(title, "strong"),
        label(text, "muted", wrap: true))));
}

/// Island with immediate widgets and a canvas that draws where it was clicked, and one without controls that
/// takes the arrow keys.
Node islandsPage()
{
    int clicks;
    bool grid = true;
    Point[] dots;
    bool round_ = true;
    float dotSize = 10;
    string caption = "Dots";
    string[] goals = ["10 dots", "20 dots", "50 dots"];
    int[] goalDots = [10, 20, 50];
    ptrdiff_t goal = 1;
    Menu dotsMenu = popupMenu(menuItem("&Clear dots", () { dots = null; }),
        menuItem("&Toggle grid", () { grid = grid == false; }));
    void view(Ui ui)
    {
        ui.padded(14, 12, {
            ui.column(gap: 10)({
                ui.label("This panel is one island: plain code that runs again when its input changes.", "muted");
                ui.row(gap: 10)({
                    if (ui.button("Click", Icon.plus))
                    {
                        ++clicks;
                    }
                    ui.label(format("%d clicks", clicks));
                    if (ui.link("Reset", enabled: clicks > 0))
                    {
                        clicks = 0;
                    }
                    ui.checkbox(grid, "Grid");
                    if (ui.button("Clear dots", variant: "toolbar", enabled: dots.length > 0))
                    {
                        dots = null;
                    }
                });
                ui.row(gap: 16)({
                    ui.radio(round_, true, "Dots");
                    ui.radio(round_, false, "Squares");
                    ui.label("Size", "muted", forNext: true);
                    ui.slider(dotSize, 4f, 24f, 2f);
                    ui.label(format("%g px", dotSize), "monoMuted");
                });
                ui.row(gap: 10)({
                    ui.label("Caption", "muted", forNext: true);
                    ui.expand({ ui.textBox(caption, "Name the dots"); });
                    ui.label("Goal", "muted", forNext: true);
                    ui.comboBox(goals, goal);
                    ui.menuButton("Dots", dotsMenu, variant: "toolbar");
                });
                CanvasState c;
                ui.contextMenu(dotsMenu)({
                    c = ui.canvas((ref PaintContext ctx, Rect r) {
                        paintDots(ctx, r, grid, dots, round_ ? dotSize / 2 : 2, dotSize);
                    }, h: 200);
                });
                if (c.press.clicked)
                {
                    dots ~= Point(ui.mouse.x - c.rect.x, ui.mouse.y - c.rect.y);
                }
                ui.row(gap: 10)({
                    int want = goalDots[goal];
                    ui.expand({ ui.progressBar(min(dots.length, want) / cast(double) want); });
                    ui.label(format("%s: %d of %d", caption, min(dots.length, want), want), "monoMuted");
                });
            });
        });
    }

    int col = 2;
    int line = 1;
    void keysView(Ui ui)
    {
        Rect last = ui.area;
        int cols = max(1, cast(int) (last.w / 20));
        int lines = max(1, cast(int) (last.h / 20));
        col = clamp(col + ui.takeKey(Key.right) - ui.takeKey(Key.left), 0, cols - 1);
        line = clamp(line + ui.takeKey(Key.down) - ui.takeKey(Key.up), 0, lines - 1);
        ui.canvas((ref PaintContext ctx, Rect r) {
            paintDots(ctx, r, true, [Point(col * 20 + 10, line * 20 + 10)], 2, 16);
        }, h: last.h);
    }

    return column(gap: 22)(
        section("Immediate widgets and a canvas", sized(h: 380)(panel(variant: "header")(island(&view)))),
        section("Keys without controls", column(gap: 8)(
            sized(h: 120)(island(&keysView)),
            label("This island declares no controls, so Tab stops on the island itself and rings it. The arrows "
                ~ "move the square.", "muted", wrap: true),
        )),
        section("Notes", label("Island widgets share paint code with the retained ones, so they look the same. "
            ~ "The canvas reads last pass's rect for hit testing. Click it to add dots. Tab moves through the "
            ~ "controls, and the radios are one stop with arrows inside. The caption box keeps its caret and "
            ~ "selection in the island's memory. The goal list and the Dots menu are popups opened from the "
            ~ "island, and a right click on the canvas opens the same menu.", "muted", wrap: true)),
    );
}

/// Canvas of the island page: a background, an optional grid, and `dots` relative to `r`, `size` wide with
/// corner `radius`.
private void paintDots(ref PaintContext ctx, Rect r, bool grid, const Point[] dots, float radius, float size)
{
    ctx.list.rect(r, Color(0x17, 0x17, 0x1a, 0xff), 4);
    if (grid)
    {
        for (float x = r.x + 20; x < r.right; x += 20)
        {
            ctx.list.vline(x, r.y, r.bottom, Color(0xff, 0xff, 0xff, 0x0c));
        }
        for (float y = r.y + 20; y < r.bottom; y += 20)
        {
            ctx.list.hline(r.x, r.right, y, Color(0xff, 0xff, 0xff, 0x0c));
        }
    }
    foreach (Point p; dots)
    {
        ctx.list.rect(Rect(r.x + p.x - size / 2, r.y + p.y - size / 2, size, size), Color(0x3b, 0x82, 0xf6, 0xff),
            radius);
    }
}

/// Sizes for the radio page.
enum Shirt
{
    small,  /// S
    medium, /// M
    large,  /// L
}

/// Radio buttons: groups over an enum and strings, single radios, disabled.
Node radiosPage()
{
    Signal!Shirt shirt = signal(Shirt.medium);
    Signal!string side = signal("Left");
    Signal!int speed = signal(1);
    Signal!bool on = signal(false);
    Signal!string quality = signal("Draft");
    return column(gap: 22)(
        section("Group over an enum", line(
            radioGroup(shirt),
            label(() => format("Shirt: %s", shirt.get), "muted"),
        )),
        section("Horizontal group over strings", column(gap: 8, cross: CrossAlign.start)(
            radioGroup(["Left", "Center", "Right"], side, horizontal: true),
            label(() => "Aligned " ~ side.get.toLower, "muted"),
        )),
        section("Single radios with tooltips", line(
            radio(speed, 0, "Slow", tooltip: "Half speed"),
            radio(speed, 1, "Normal"),
            radio(speed, 2, "Fast", tooltip: "Double speed"),
        )),
        section("Disabled", column(gap: 8, cross: CrossAlign.start)(
            checkbox(on, "Enable the group below"),
            radioGroup(["Draft", "Normal", "Best"], quality, horizontal: true, enabled: &on.get),
        )),
        section("Keys", label("Arrows move the choice inside a group. Tab stops at the chosen radio only, so a "
            ~ "group is one Tab stop.", "muted", wrap: true)),
    );
}

/// Sliders: integer and float ranges, steps, disabled, and one linked to a spin box.
Node slidersPage()
{
    Signal!int volume = signal(40);
    Signal!double opacity = signal(0.8);
    Signal!double free = signal(0.5);
    Signal!int tens = signal(30);
    Signal!bool on = signal(false);
    Signal!int linked = signal(12);
    return column(gap: 22)(
        section("Integers, 0 to 100", line(narrow(260, slider(volume, 0, 100)),
            label(() => format("%d", volume.get), "mono"))),
        section("Floats in steps of 0.05", line(narrow(260, slider(opacity, 0.0, 1.0, 0.05)),
            label(() => format("%.2f", opacity.get), "mono"))),
        section("Continuous", line(narrow(260, slider(free, 0.0, 1.0)),
            label(() => format("%.4f", free.get), "mono"))),
        section("Steps of 10", line(narrow(260, slider(tens, 0, 100, 10)),
            label(() => format("%d", tens.get), "mono"))),
        section("Disabled", column(gap: 8, cross: CrossAlign.start)(
            checkbox(on, "Enable the slider below"),
            narrow(260, slider(volume, 0, 100, enabled: &on.get)),
        )),
        section("Linked to a spin box", line(narrow(260, slider(linked, 0, 50)), spinBox(linked, 0, 50))),
        section("Keys", label("Arrows step, Page Up and Page Down move a tenth of the range, Home and End go to "
            ~ "the ends. With focus the wheel steps too, otherwise it scrolls the page. Escape during a drag puts back "
            ~ "the value from before it.", "muted", wrap: true)),
    );
}

/// Progress bars: driven by a slider, busy, and fixed fractions.
Node progressPage()
{
    Signal!double done = signal(0.35);
    Signal!bool busy = signal(true);
    return column(gap: 22)(
        section("Driven by a slider", column(gap: 10, cross: CrossAlign.start)(
            narrow(320, progressBar(() => done.get)),
            line(narrow(200, slider(done, 0.0, 1.0, 0.01)), label(() => format("%.0f%%", done.get * 100), "mono")),
        )),
        section("Busy", column(gap: 10, cross: CrossAlign.start)(
            narrow(320, progressBar(() => busy.get ? double.nan : 1.0, tooltip: "NaN means busy")),
            checkbox(busy, "Busy, the amount of work is unknown"),
        )),
        section("Fixed fractions", column(gap: 10, cross: CrossAlign.start)(
            captioned("0%", narrow(320, progressBar(() => 0.0))),
            captioned("60%", narrow(320, progressBar(() => 0.6))),
            captioned("100%", narrow(320, progressBar(() => 1.0))),
            captioned("Full width", progressBar(() => 0.75)),
        )),
    );
}

/// Images: pictures drawn in code shown in each fit, tinted, at 2x density and in an island, and files opened
/// through SDL3_image when it is there.
Node imagesPage(Gallery g)
{
    Image land = landscape(96, 64);
    Image sharp = landscape(192, 128);
    Image ring = ringImage(32);
    Image scene = landscape(24, 24);
    Image dot = ringImage(24);
    Signal!Image opened = signal!Image(null);
    Signal!string status = signal(canLoadImages() ? "Nothing opened yet" : "SDL3_image was not found, so files "
        ~ "cannot be opened. DENTRITE_SDL_IMAGE names its file.");
    Signal!bool canOpen = signal(canLoadImages());

    /// Loads the first chosen file, or shows why not.
    void picked(string[] paths)
    {
        if (paths.length == 0)
        {
            return;
        }
        try
        {
            Image img = loadImage(paths[0]);
            opened.set(img);
            status.set(format("%s, %d by %d", paths[0], img.width, img.height));
        }
        catch (Exception e)
        {
            status.set(e.msg);
        }
    }

    /// `n` in a box with a background, 140 by 70 unless given, so the fit shows.
    Node framed(Node n, float w = 140, float h = 70)
    {
        return panel("header")(sized(w, h)(n));
    }

    FileFilter[] types = [FileFilter("Images", "png;jpg;jpeg;webp;bmp;gif;tga;qoi"), FileFilter("All files", "*")];
    Signal!size_t tab = signal!size_t(0);
    Button pick = button("Pictures", icon: Icon.chevronDown);
    Menu pictures = popupMenu(menuItem("&Scene", g.note("Scene"), icon: Icon(scene)),
        menuItem("&Ring", g.note("Ring"), icon: Icon(dot, mono: true)),
        menuItem("&Disabled", g.note("Disabled"), icon: Icon(scene), enabled: () => false));
    pick.onClick = () { pictures.toggle(pick); };
    return column(gap: 22)(
        section("Fits in a 140 by 70 box", line(
            captioned("Contain", framed(imageView(land, Fit.contain, accessName: "Landscape"))),
            captioned("Cover", framed(imageView(land, Fit.cover))),
            captioned("Fill", framed(imageView(land, Fit.fill))),
            captioned("None", framed(imageView(sharp, Fit.none))),
        )),
        section("Tint and density", line(
            captioned("White, tinted", line(imageView(ring), imageView(ring, tint: Color(0x3a, 0x7b, 0xe8, 0xff)),
                imageView(ring, tint: Color(0xe8, 0x5a, 0x3a, 0xff)), imageView(ring, tint: Color(255, 255, 255, 96)))),
            captioned("96 by 64 at 1x", imageView(land)),
            captioned("192 by 128 at 2x", imageView(sharp, density: 2)),
        )),
        section("As icons, 24 pixels in a 12 pixel box", column(gap: 10, cross: CrossAlign.start)(
            line(button("Scene", g.note("Scene"), icon: Icon(scene)),
                button("Disabled", icon: Icon(scene), enabled: () => false),
                button("One color", g.note("One color"), icon: Icon(dot, mono: true), variant: "primary"),
                button(null, g.note("Toolbar"), icon: Icon(dot, mono: true), variant: "toolbar"), pick),
            narrow(360, tabBar(["Scene", "Ring", "Shape"], tab,
                icons: [Icon(scene), Icon(dot, mono: true), Icon.plus])),
        )),
        section("In an island", line(
            captioned("ui.imageView, cover", framed(island((Ui ui) { ui.imageView(land, Fit.cover); }), 200, 60)),
        )),
        section("From a file", column(gap: 8, cross: CrossAlign.start)(
            button("Open image", onClick: () { g.host.fileDialog(FileDialogKind.open, &picked, types); },
                enabled: &canOpen.get),
            framed(imageView(() => opened.get), 320, 200),
            label(&status.get, "muted", wrap: true),
        )),
    );
}

/// Landscape of `w` by `h` pixels drawn in code: sky, sun and hills.
private Image landscape(int w, int h)
{
    Image img = new Image(w, h);
    foreach (int y; 0 .. h)
    {
        foreach (int x; 0 .. w)
        {
            float t = cast(float) y / h;
            float[3] c = [70 + 170 * t, 120 + 70 * t, 210 - 80 * t];
            float dx = x - w * 0.7f;
            float dy = y - h * 0.4f;
            float sun = clamp(h * 0.14f - sqrt(dx * dx + dy * dy), 0f, 1f);
            c = [c[0] + (255 - c[0]) * sun, c[1] + (235 - c[1]) * sun, c[2] + (160 - c[2]) * sun];
            float hill = h * (0.68f + 0.07f * sin(x * 6.0f / w) + 0.04f * sin(x * 17.0f / w));
            float ground = clamp(y - hill, 0f, 1f);
            c = [c[0] + (50 - c[0]) * ground, c[1] + (110 - c[1]) * ground, c[2] + (60 - c[2]) * ground];
            img.set(x, y, byte8(c[0]), byte8(c[1]), byte8(c[2]), 255);
        }
    }
    return img;
}

/// White ring `side` pixels across on transparency, for tinting.
private Image ringImage(int side)
{
    Image img = new Image(side, side);
    float mid = side / 2.0f;
    foreach (int y; 0 .. side)
    {
        foreach (int x; 0 .. side)
        {
            float d = sqrt((x + 0.5f - mid) ^^ 2 + (y + 0.5f - mid) ^^ 2);
            float a = clamp(side * 0.09f - abs(d - side * 0.34f) + 0.5f, 0f, 1f);
            img.set(x, y, 255, 255, 255, byte8(a * 255));
        }
    }
    return img;
}

/// `v` rounded and clamped to a byte.
private ubyte byte8(float v)
{
    return cast(ubyte) clamp(cast(int)(v + 0.5f), 0, 255);
}

/// Spin boxes: integers, floats, negative ranges, disabled, and one linked to a slider.
Node spinBoxesPage()
{
    Signal!int port = signal(8080);
    Signal!double zoom = signal(1.0);
    Signal!int degrees = signal(-5);
    Signal!int fives = signal(25);
    Signal!bool on = signal(false);
    Signal!int linked = signal(12);
    return column(gap: 22)(
        section("Integers", line(spinBox(port, 1, 65535), label(() => format("Port %d", port.get), "muted"))),
        section("Floats in steps of 0.25", line(spinBox(zoom, 0.25, 4.0, 0.25),
            label(() => format("Zoom %g", zoom.get), "muted"))),
        section("Negative values", line(spinBox(degrees, -40, 40), label("-40 to 40, so a minus sign can be typed",
            "muted"))),
        section("Steps of 5", line(spinBox(fives, 0, 100, 5), label("Typed values snap to the step", "muted"))),
        section("Disabled", column(gap: 8, cross: CrossAlign.start)(
            checkbox(on, "Enable the box below"),
            spinBox(port, 1, 65535, enabled: &on.get),
        )),
        section("Linked to a slider", line(spinBox(linked, 0, 50), narrow(260, slider(linked, 0, 50)))),
        section("Keys", label("Up and Down step, Page Up and Page Down move a tenth of the range, and the wheel "
            ~ "steps while the box has focus. Enter or leaving takes the typed text, Escape puts it back. Holding "
            ~ "a button repeats.", "muted", wrap: true)),
    );
}

/// Tabs: a view over fixed pages, a bar with closable tabs, and a bar wider than its space.
Node tabsPage()
{
    Signal!size_t settings = signal(size_t(0));
    Signal!bool sync = signal(true);
    Signal!string user = signal("dd");
    Signal!int fontSize = signal(13);
    Signal!double scaleBy = signal(1.0);
    Signal!bool verbose = signal(false);
    Signal!(string[]) files = signal(["app.d", "pages.d", "shell.d"]);
    Signal!size_t open = signal(size_t(0));
    int made;
    Signal!size_t far = signal(size_t(0));
    Signal!size_t toolTab = signal(size_t(0));
    Signal!size_t toolBar = signal(size_t(0));
    Signal!size_t stackTab = signal(size_t(0));
    Signal!size_t marked = signal(size_t(0));

    void close(size_t i)
    {
        string[] f = files.peek.dup;
        f = f[0 .. i] ~ f[i + 1 .. $];
        batch(() {
            files.set(f);
            if (open.peek >= f.length || (open.peek > i))
            {
                open.set(open.peek > 0 ? open.peek - 1 : 0);
            }
        });
    }

    void add()
    {
        ++made;
        files.set(files.peek ~ format("untitled-%d.d", made));
        open.set(files.peek.length - 1);
    }

    string[] months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December"];
    return column(gap: 22)(
        section("Tab view over fixed pages", narrow(480, tabs(settings)(
            tab("General", pad(all: 12)(column(gap: 10, cross: CrossAlign.start)(
                checkbox(sync, "Sync settings"),
                row(gap: 8)(label("User"), narrow(200, textBox(user))),
            ))),
            tab("Appearance", pad(all: 12)(column(gap: 10, cross: CrossAlign.start)(
                row(gap: 8)(label("Font size"), spinBox(fontSize, 8, 32)),
                row(gap: 8)(label("Scale"), narrow(200, slider(scaleBy, 0.5, 3.0, 0.25)),
                    label(() => format("%gx", scaleBy.get), "mono")),
            ))),
            tab("Advanced", pad(all: 12)(column(gap: 10, cross: CrossAlign.start)(
                checkbox(verbose, "Verbose logging"),
                label("Pages keep their state when hidden. Verbose logging enables Log.", "muted"),
            ))),
            tab("Log", pad(all: 12)(label("Shown while verbose logging is on.")), enabled: () => verbose.get),
        ))),
        section("Icon and text", column(gap: 8, cross: CrossAlign.start)(
            narrow(480, tabs(toolTab)(
                tab("Run", pad(all: 12)(label("Icon tabs work in a view.")), Icon.play),
                tab("Break", pad(all: 12)(label("Icons follow the title color.")), Icon.pause),
                tab("Stop", pad(all: 12)(label("Tabs without an icon are fine too.")), Icon.stop),
                tab("Notes", pad(all: 12)(label("Mixed with a text only tab.")), Icon.none),
            )),
            narrow(480, tabBar(["Add", "Check", "Dot"], toolBar, icons: [Icon.plus, Icon.check, Icon.breakpoint])),
        )),
        section("Icon above text", narrow(480, tabs(stackTab, stacked: true)(
            tab("Run", pad(all: 12)(label("Stacked tabs put the icon over the title.")), Icon.play),
            tab("Break", pad(all: 12)(label("The bar gets the extra padding.")), Icon.pause),
            tab("Stop", pad(all: 12)(label("A tab without an icon keeps the row.")), Icon.stop),
            tab("Notes", pad(all: 12)(label("Text only.")), Icon.none),
        ))),
        section("Closable tabs, the bar alone", column(gap: 8, cross: CrossAlign.start)(
            narrow(480, tabBar(&files.get, open, &close)),
            line(
                button("New file", onClick: &add, icon: Icon.plus, variant: "toolbar"),
                label(() => open.get < files.get.length ? "Editing " ~ files.get[open.get] : "No file open",
                    "muted"),
            ),
        )),
        section("Marks and tooltips", narrow(480, tabBar(() => [
            TabInfo("app.d", tooltip: "~/src/app.d, unsaved", modified: true),
            TabInfo("pages.d", tooltip: "~/src/pages.d, open twice", badge: "×2"),
            TabInfo("shell.d", tooltip: "~/src/shell.d, read only", locked: true),
            TabInfo("build.log", tooltip: "Building", progress: 0.6f),
        ], marked))),
        section("Wider than its space", column(gap: 8, cross: CrossAlign.start)(
            narrow(300, tabBar(months, far)),
            label("The wheel scrolls the strip, an edge with more tabs past it fades, and the chosen tab "
                ~ "scrolls into view.", "muted", wrap: true),
        )),
        section("Keys", label("Left and Right choose the neighbor tab, Home and End the first and last. A middle "
            ~ "click closes a closable tab.", "muted", wrap: true)),
    );
}

/// Notes, code with line numbers, a read-only log and a disabled area.
Node textAreasPage()
{
    Signal!string notes = signal("Text areas hold several lines. This one wraps long lines at spaces and grows "
        ~ "with its text, since the page gives it no height.\n\nTry Ctrl+Z after typing.");
    Signal!string code = signal(sampleCode);
    Signal!string log = signal(sampleLog);
    Signal!string draft = signal("Tick the box to edit this text.");
    Signal!bool editable = signal(false);
    Signal!bool ligatures = signal(true);
    TextArea codeArea = textArea(code, variant: "code", lineNumbers: true, tabSpaces: 4);
    effect(() { codeArea.setVariant(ligatures.get ? "code" : "codePlain"); });
    return column(gap: 22)(
        section("Wrapped, growing with its text", column(gap: 8)(
            narrow(480, textArea(notes, placeholder: "Notes", wrap: true)),
            label(() => format("%d lines, %d characters", notes.get.count('\n') + 1, notes.get.length), "muted"),
        )),
        section("Code: line numbers, Tab inserts spaces, no wrapping", column(gap: 8, cross: CrossAlign.start)(
            checkbox(ligatures, "Ligatures", tooltip: "Code ligatures such as => and == in the mono font"),
            narrow(560, sized(h: 220)(codeArea)),
        )),
        section("Read only", narrow(560, sized(h: 110)(textArea(log, readOnly: true, variant: "code")))),
        section("Disabled", column(gap: 8, cross: CrossAlign.start)(
            checkbox(editable, "Editable"),
            narrow(480, textArea(draft, wrap: true, enabled: &editable.get)),
        )),
        section("Keys", label("Arrows move, Ctrl by word, Shift selects. Home and End go to the row ends, Ctrl+Home "
            ~ "and Ctrl+End to the text ends. Enter keeps the indent. Ctrl+Z undoes, Ctrl+Shift+Z or Ctrl+Y redoes. "
            ~ "A double click selects a word, a triple click a line.", "muted", wrap: true)),
    );
}

/// D source shown in the code area.
enum sampleCode = `/// Sums the squares of the even numbers in a range.
module squares;

import std.algorithm : filter, map, sum;
import std.range : iota;

/// Sum of the squares of the even numbers below n.
long evenSquares(long n)
{
    return iota(n).filter!(x => x % 2 == 0).map!(x => x * x).sum;
}

void main()
{
    import std.stdio : writeln;

    foreach (long n; [10, 100, 1000])
    {
        writeln(n, ": ", evenSquares(n)); // a long line, wider than the area, to show the sideways scroll bar
    }
}
`;

/// Log lines shown in the read-only area.
enum sampleLog = "12:00:01 target started, pid 4242\n12:00:01 breakpoint 1 at main.d:42\n"
    ~ "12:00:02 hit breakpoint 1, thread 1\n12:00:05 step over\n12:00:05 stopped at main.d:43\n"
    ~ "12:00:09 continue\n12:00:10 target exited with code 0";

/// Confirmation, a form with a disabled main button, a message, and the system's file dialogs.
Node dialogsPage(Gallery g)
{
    Signal!string result = signal("No dialog closed yet");
    Signal!string name = signal("notes.txt");
    Signal!string files = signal("Nothing chosen yet");
    Dialog confirm = dialog("Remove 3 breakpoints?", buttons: ["Cancel", "Remove"], primary: 1,
        primaryVariant: "danger", onClose: (int b) { result.set(b == 1 ? "Removed them" : "Kept them"); })(
        label("They stop at main.d:42, parser.d:118 and lexer.d:7. Removing them cannot be undone.", wrap: true));
    Dialog rename = dialog("Rename file", buttons: ["Cancel", "Rename"], primary: 1, width: 380,
        onClose: (int b) { result.set(b == 1 ? "Renamed to " ~ name.peek : "Not renamed"); })(
        column(gap: 6)(label("New name", "muted"), textBox(name, placeholder: "File name")));
    effect(() { rename.button(1).setEnabled(name.get.length > 0); });
    Dialog about = dialog("About the gallery")(label("One page per widget, each showing its variants and states. "
        ~ "Pages are built once, so they keep their state while you switch.", wrap: true));
    Node[] options;
    foreach (string group; ["Editor", "Debugger", "Terminal", "Files"])
    {
        options ~= label(group, "strong");
        foreach (string what; ["Show line numbers", "Wrap long lines", "Restore on start", "Confirm on close",
            "Follow the cursor", "Use the system font"])
        {
            options ~= checkbox(signal(what.length % 2 == 0), what);
        }
    }
    Dialog unsaved = dialog("Save changes to notes.txt?", buttons: ["Don't Save", "Cancel", "Save"], primary: 2,
        variants: ["danger"], onClose: (int b) {
            result.set(b == 2 ? "Saved" : b == 0 ? "Discarded the changes" : "Kept editing");
        })(
        label("Your changes are lost if you don't save them.", wrap: true));
    Dialog settings = dialog("Settings", buttons: ["Cancel", "Save"], primary: 1, width: 360,
        onClose: (int b) { result.set(b == 1 ? "Saved the settings" : "Settings unchanged"); })(
        column(gap: 6, cross: CrossAlign.start)(options));

    /// Handler showing what a file dialog returned.
    void shown(string[] paths)
    {
        files.set(paths.length == 0 ? "Cancelled, or this system has no file dialog" : paths.join(", "));
    }

    /// Opens a file dialog of `kind`.
    void pick(FileDialogKind kind)
    {
        FileFilter[] types = [FileFilter("D source", "d"), FileFilter("Text", "txt;md"), FileFilter("All files", "*")];
        g.host.fileDialog(kind, &shown, kind == FileDialogKind.folder ? null : types);
    }

    return column(gap: 22)(
        section("Modal dialogs", column(gap: 8, cross: CrossAlign.start)(
            line(
                button("Remove breakpoints", onClick: () { confirm.open(g.host); }, variant: "danger"),
                button("Rename", onClick: () { rename.open(g.host); }),
                button("Close file", onClick: () { unsaved.open(g.host); }),
                button("About", onClick: () { about.open(g.host); }),
                button("Settings", onClick: () { settings.open(g.host); }),
            ),
            label("Settings is taller than a small window, so its content scrolls.", "muted"),
            label(&result.get, "muted"),
        )),
        section("File dialogs from the system", column(gap: 8, cross: CrossAlign.start)(
            line(
                button("Open file", onClick: () { pick(FileDialogKind.open); }),
                button("Open files", onClick: () { pick(FileDialogKind.openMany); }),
                button("Save as", onClick: () { pick(FileDialogKind.save); }),
                button("Choose folder", onClick: () { pick(FileDialogKind.folder); }),
            ),
            label(&files.get, "muted", wrap: true),
        )),
        section("Behavior", label("Presses outside a dialog do nothing, and Tab stays inside it. Escape cancels, "
            ~ "Enter presses the main button unless it is disabled, and focus goes back where it was on close. "
            ~ "File dialogs answer later on the UI thread.", "muted", wrap: true)),
    );
}

/// Tray icon page: a checkbox shows the icon, whose menu toggles the window, counts pings and picks a mode.
Node trayPage(Gallery g)
{
    Signal!bool wanted = signal(false);
    Signal!bool closeHides = signal(true);
    Signal!int pings = signal(0);
    Signal!string mode = signal("Normal");
    Signal!string status = signal("No tray icon");
    Tray shown;

    /// Menu item picking mode `m`, checked while it is the mode.
    MenuItem modeItem(string m)
    {
        return menuItem(m, () { mode.set(m); }, checked: () => mode.get == m);
    }

    effect(() {
        bool on = wanted.get;
        untracked(() {
            if (on && shown is null)
            {
                shown = g.host.tray(icon: ringImage(32), tooltip: "dentrite gallery")(
                    menuItem("&Show window", () { g.host.visible = g.host.visible == false; },
                        checked: () => g.host.visible),
                    menuItem("&Ping", () { pings.set(pings.peek + 1); }),
                    menu("&Mode")(modeItem("Normal"), modeItem("Quiet"), modeItem("Busy")),
                    menuSeparator(),
                    menuItem("&Quit", () { g.host.running = false; }),
                );
                status.set(shown is null ? "This system has no tray, or SDL could not reach it"
                    : "Tray icon shown");
            }
            else if (on == false && shown !is null)
            {
                shown.close();
                shown = null;
                status.set("No tray icon");
            }
        });
    });
    g.host.onCloseRequest = () {
        if (shown is null || closeHides.peek == false)
        {
            return true;
        }
        g.host.visible = false;
        return false;
    };

    return column(gap: 22)(
        section("System tray", column(gap: 8, cross: CrossAlign.start)(
            checkbox(wanted, "Show a tray icon"),
            checkbox(closeHides, "Closing the window hides it while the icon shows"),
            label(&status.get, "muted"),
            label(() => format("Pings: %d, mode: %s", pings.get, mode.get)),
        )),
        section("Behavior", label("Most trays open the menu on any click, so Show window brings the window back. "
            ~ "Entries follow their command's label, enabled and checked states every frame. On Linux the tray "
            ~ "needs an AppIndicator library and a desktop that shows StatusNotifier items.", "muted",
            wrap: true)),
    );
}

/// File or folder in the gallery's file tree.
final class FileNode
{
    string path;     /// key
    string name;     /// last path part
    long bytes;      /// size, files only
    FileNode[] kids; /// children, folders only
    bool folder;     /// has children

    /// Creates a node.
    this(string path, string name, bool folder, long bytes)
    {
        this.path = path;
        this.name = name;
        this.folder = folder;
        this.bytes = bytes;
    }
}

/// Folder tree of `paths`, folders first, each level sorted by name.
FileNode fileTree(string[] paths)
{
    import std.algorithm.sorting : sort;
    import std.string : split;

    FileNode root = new FileNode("", "", true, 0);
    FileNode[string] byPath;
    foreach (string p; paths)
    {
        FileNode at = root;
        string[] parts = p.split("/");
        foreach (size_t i, string part; parts)
        {
            string sub = parts[0 .. i + 1].join("/");
            if (FileNode* found = sub in byPath)
            {
                at = *found;
                continue;
            }
            bool folder = i + 1 < parts.length;
            FileNode n = new FileNode(sub, part, folder, folder ? 0 : 400 + (sub.length * 7919) % 60_000);
            byPath[sub] = n;
            at.kids ~= n;
            at = n;
        }
    }
    foreach (FileNode n; byPath.values ~ root)
    {
        n.kids.sort!((a, b) => a.folder != b.folder ? a.folder : a.name < b.name);
    }
    return root;
}

/// Group or item of the generated tree.
struct GenNode
{
    int group; /// group number
    int item;  /// item number, -1 for the group itself
}

/// A file tree and a generated tree of 200,000 items.
Node treesPage()
{
    FileNode root = fileTree(["README.md", "dub.sdl", ".gitignore", "core/dub.sdl", "core/source/dentrite/node.d",
        "core/source/dentrite/host.d", "core/source/dentrite/signals.d", "core/source/dentrite/text.d",
        "core/source/dentrite/overlay.d", "core/source/dentrite/widgets/button.d",
        "core/source/dentrite/widgets/list.d", "core/source/dentrite/widgets/table.d",
        "core/source/dentrite/widgets/tree.d", "core/source/dentrite/widgets/textarea.d",
        "core/source/dentrite/backend/software.d", "gl33/source/dentrite/backend/gl33.d",
        "sdl3/source/dentrite/sdl3.d", "sdl3/source/dentrite/window.d", "examples/gallery/source/app.d",
        "examples/gallery/source/gallery/pages.d", "examples/debugger/source/app.d", "fonts/Inter-Regular.otf",
        "fonts/JetBrainsMono-Regular.ttf"]);
    Signal!string picked = signal("");
    Signal!string opened = signal("");
    TreeView!(string, FileNode) files = treeView!(string, FileNode)(() => root.kids, (FileNode n) => n.kids,
        (FileNode n) => n.path, (FileNode delegate() n) => fileRow(n), picked,
        (FileNode n) { opened.set(n.path); }, text: (FileNode n) => n.name);
    files.expand("core");
    files.expand("core/source");
    files.expand("core/source/dentrite");

    Signal!GenNode gen = signal(GenNode(-1, -1));
    GenNode[] groups;
    foreach (int g; 0 .. 1000)
    {
        groups ~= GenNode(g, -1);
    }
    TreeView!(GenNode, GenNode) big = treeView!(GenNode, GenNode)(() => groups,
        (GenNode n) => n.item >= 0 ? null : genItems(n.group), (GenNode n) => n, (GenNode delegate() n) =>
        label(() => n().item < 0 ? format("Group %d", n().group) : format("Item %d.%d", n().group,
        n().item)), gen, hasChildren: (GenNode n) => n.item < 0);
    return column(gap: 22)(
        section("Files", column(gap: 8)(
            narrow(420, sized(h: 300)(panel(variant: "pane")(files))),
            label(() => opened.get.length > 0 ? "Opened " ~ opened.get : picked.get.length > 0
                ? "Selected " ~ picked.get : "Double click a file to open it", "muted"),
        )),
        section("Generated: 1,000 groups of 200 items", column(gap: 8)(
            narrow(420, sized(h: 220)(panel(variant: "pane")(big))),
            label("Children are listed only when a group expands.", "muted"),
        )),
        section("Keys", label("Up and Down move, Right expands or goes to the first child, Left collapses or goes "
            ~ "to the parent. Enter or a double click expands a folder and opens a file. Collapsing a folder moves "
            ~ "the selection out of it. Typing a name selects the next shown node starting with it.", "muted",
            wrap: true)),
    );
}

/// Items of generated group `g`.
private GenNode[] genItems(int g)
{
    GenNode[] items;
    foreach (int i; 0 .. 200)
    {
        items ~= GenNode(g, i);
    }
    return items;
}

/// Row content of the file tree: name, then a size or an item count.
private Node fileRow(FileNode delegate() n)
{
    return row(gap: 8)(
        expanded(label(() => n().name)),
        label(() => n().folder ? format("%d item%s", n().kids.length, n().kids.length == 1 ? "" : "s")
            : format("%,d B", n().bytes), "monoMuted"),
    );
}

/// Process of the generated table.
struct Proc
{
    int pid;       /// key
    string name;   /// command
    string user;   /// owner
    double cpu;    /// percent
    long memory;   /// KiB
}

/// Watch expression of the small table.
final class Watch
{
    int id;          /// key
    string expr;     /// expression
    string value;    /// last value
    Signal!bool on;  /// evaluated at every stop

    /// Creates a watch.
    this(int id, string expr, string value, bool on)
    {
        this.id = id;
        this.expr = expr;
        this.value = value;
        this.on = signal(on);
    }
}

/// A sortable table of 5,000 processes, and a small one with widgets in its cells.
Node tablesPage()
{
    static immutable string[] names = ["dentrite-gallery", "dub", "ldc2", "dmd", "bash", "sshd", "Xvfb", "pipewire",
        "systemd", "podman", "gdb", "lldb-server", "perl", "make", "git", "less"];
    static immutable string[] users = ["dd", "root", "daemon", "nobody"];
    Proc[] procs;
    uint seed = 12_345;
    foreach (int i; 0 .. 5000)
    {
        seed = seed * 1_103_515_245 + 12_345;
        procs ~= Proc(100 + i * 3, names[seed % names.length] ~ (i < names.length ? "" : format("-%d", i)),
            users[(seed >> 8) % users.length], ((seed >> 4) % 1000) / 10.0, 512 + (seed >> 6) % 400_000);
    }
    Signal!int sel = signal(-1);
    Signal!(int[]) picked = signal(cast(int[]) null);
    Signal!string opened = signal("");
    Table!(int, Proc) t = table(items: () => procs, key: (Proc p) => p.pid, selected: sel,
        onActivate: (Proc p) { opened.set(format("Opened %s (%d)", p.name, p.pid)); }, text: (Proc p) => p.name,
        multi: picked)(
        tableColumn("PID", (Proc delegate() p) => label(() => format("%d", p().pid), "mono"), width: 70,
            less: (Proc a, Proc b) => a.pid < b.pid),
        tableColumn("Name", (Proc delegate() p) => label(() => p().name), width: 200,
            less: (Proc a, Proc b) => a.name < b.name),
        tableColumn("User", (Proc delegate() p) => label(() => p().user, "muted"), width: 90,
            less: (Proc a, Proc b) => a.user < b.user),
        tableColumn("CPU %", (Proc delegate() p) => label(() => format("%.1f", p().cpu), "mono"),
            width: 70, less: (Proc a, Proc b) => a.cpu < b.cpu),
        tableColumn("Memory", (Proc delegate() p) => label(() => format("%,d K", p().memory), "mono"),
            width: 110, less: (Proc a, Proc b) => a.memory < b.memory),
    );

    Watch[] watches = [new Watch(1, "argc", "3", true), new Watch(2, "argv[0]", `"./app"`, true),
        new Watch(3, "config.verbose", "false", false), new Watch(4, "buffer.length", "4096", true)];
    Signal!int watchSel = signal(-1);
    Table!(int, Watch) w = table(items: () => watches, key: (Watch x) => x.id, selected: watchSel)(
        tableColumn("On", (Watch delegate() x) => checkbox(() => x().on), width: 44),
        tableColumn("Expression", (Watch delegate() x) => label(() => x().expr, "mono"), width: 160,
            less: (Watch a, Watch b) => a.expr < b.expr),
        tableColumn("Value", (Watch delegate() x) => label(() => x().on.get ? x().value : "not evaluated",
            "monoMuted"), width: 160),
    );
    return column(gap: 22)(
        section("5,000 processes", column(gap: 8)(
            narrow(560, sized(h: 300)(t)),
            label(() => opened.get.length > 0 ? opened.get : sel.get < 0 ? "Click a title to sort, drag it to move "
                ~ "the column, drag its edge to resize. Right-click the titles to hide columns."
                : picked.get.length == 1 ? format("Selected PID %d", sel.get)
                : format("%d processes selected", picked.get.length), "muted"),
        )),
        section("Widgets in cells", narrow(380, sized(h: 130)(w))),
        section("Keys", label("Up and Down move the selection, Page Up and Page Down by a view, Home and End to the "
            ~ "ends, Enter or a double click opens. Ctrl and Shift with a click or an arrow, or a drag over "
            ~ "rows, select more than one row, Ctrl and Space adds or removes the current row, Ctrl and A "
            ~ "selects every row. Left and Right scroll sideways when the columns are wider than the table, and so "
            ~ "do Shift with the wheel and a horizontal wheel. Typing a "
            ~ "name selects the next process starting with it, in the shown order.", "muted", wrap: true)),
        section("Header keys", label("The titles are a Tab stop before the rows. Left and Right pick a title, Enter "
            ~ "or Space sorts by it, Ctrl with an arrow resizes it, Alt with an arrow moves it, the menu key opens the "
            ~ "column menu, and Down goes to the rows.", "muted", wrap: true)),
    );
}

/// Icon for the row `r` returns, switching as the pooled row changes items.
private Node bigIcon(size_t delegate() r)
{
    IconView v = iconView(Icon.play, variant: "muted");
    effect(() { v.setIcon(r() % 2 == 0 ? Icon.play : Icon.pause); });
    return v;
}
