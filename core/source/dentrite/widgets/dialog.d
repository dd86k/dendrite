/// Modal dialog: a titled box over a scrim with a row of buttons. Escape cancels, Enter presses the main
/// button, Tab stays inside, and focus goes back where it was on close.
module dentrite.widgets.dialog;

import dentrite.containers : Flex, ScrollView, pad, row, scroll;
import dentrite.host : Host;
import dentrite.node;
import dentrite.overlay : Popup, popup;
import dentrite.text;
import dentrite.widgets.button : Button, button;
import std.algorithm.comparison : clamp, max, min;
import std.math : isInfinity, round;

/// Look of a dialog. The scrim is `PopupStyle.scrim`.
struct DialogStyle
{
    enum section = "dialog"; /// section name in theme files

    Color fill = Color(0x2c, 0x2c, 0x31, 0xff);   /// background
    Color border = Color(0x4a, 0x4a, 0x52, 0xff); /// outline
    Color title = Color(0xf0, 0xf0, 0xf0, 0xff);  /// title text
    Color shadow = Color(0, 0, 0, 0x80);          /// soft shadow under the box
    float shadowBlur = 24; /// shadow fade width
    float shadowY = 8;     /// shadow drop below the box
    float radius = 8;      /// corner radius
    float padX = 20;       /// side padding
    float padY = 16;       /// top and bottom padding
    float gap = 14;        /// space between the title, the content and the buttons
    float buttonGap = 8;   /// space between buttons
    float minWidth = 320;  /// narrowest dialog
    float maxWidth = 560;  /// widest dialog, content wraps inside
    float margin = 24;     /// room kept above and below a dialog as tall as the window, whose content scrolls
    float ringRoom = 3;    /// room around the content for focus rings, which the scroll view clips
    FontKind font = FontKind.uiStrong; /// title font
    float size = 15;       /// title size
}

/// Dialog box. Build it once with `dialog(...)(content)`, then `open` it as needed. Content taller than the window
/// scrolls between the title and the buttons.
final class Dialog : Node
{
    string title;            /// title text
    Popup popup;             /// modal popup holding the dialog
    void delegate(int) onClose; /// runs after closing with the chosen button, -1 for Escape or `cancel`
    int primary;             /// index of the button Enter presses, -1 for none
    float width = 0;         /// fixed width, 0 to fit the content between the style's widths

    private Button[] buttons; /// in order
    private int result = -1;  /// button that closed the dialog

    /// Creates a dialog around `content` with buttons captioned `captions`.
    this(string title, Node content, string[] captions, int primary, string primaryVariant, string[] variants,
        void delegate(int) onClose)
    {
        this.title = title;
        this.primary = primary;
        this.onClose = onClose;
        Node[] row_;
        foreach (size_t i, string c; captions)
        {
            string v = i < variants.length ? variants[i] : null;
            if (v is null && i == primary)
            {
                v = primaryVariant;
            }
            Button b = .button(c, onClick: closer(cast(int) i), variant: v);
            buttons ~= b;
            row_ ~= b;
        }
        add(scroll()(pad(all: DialogStyle.init.ringRoom)(content)));
        add(row(gap: DialogStyle.init.buttonGap)(row_));
        popup = .popup(dismiss: false, modal: true, onClose: &closed)(this);
    }

    /// Handler closing with button `i`. A function of its own so each button keeps its index.
    private void delegate() closer(int i)
    {
        return () { close(i); };
    }

    /// Button `i`, to bind its enabled state.
    Button button(size_t i)
    {
        return buttons[i];
    }

    /// Content passed to `dialog`.
    Node content()
    {
        return children[0].children[0].children[0];
    }

    /// True while open.
    bool isOpen()
    {
        return popup.isOpen;
    }

    /// Opens centered over the window of `t`. Focus goes to the first Tab stop of the content, else to the main
    /// button.
    void open(Tree t)
    {
        if (popup.isOpen)
        {
            return;
        }
        result = -1;
        popup.open(t);
        Node first = firstStop(content);
        if (first is null && primary >= 0 && primary < buttons.length)
        {
            first = buttons[primary];
        }
        if (first !is null && t.services !is null)
        {
            t.services.setFocus(first);
        }
    }

    /// Opens centered over the window of `h`.
    void open(Host h)
    {
        open(h.tree);
    }

    /// Opens centered over the window holding `near`, any node shown in it.
    void open(Node near)
    {
        assert(near.tree !is null, "open(near) needs a node in a tree");
        open(near.tree);
    }

    /// Closes with button `chosen`, -1 to cancel.
    void close(int chosen = -1)
    {
        result = chosen;
        popup.close();
    }

    /// Runs the close handler, after the popup closed.
    private void closed()
    {
        if (onClose !is null)
        {
            onClose(result);
        }
    }

    /// Escape cancels and Enter presses the main button, when the focused node did not take them.
    override bool onKey(ref const KeyEvent e)
    {
        if (e.mods != 0)
        {
            return false;
        }
        if (e.key == Key.escape)
        {
            close(-1);
            return true;
        }
        if (e.key == Key.enter && primary >= 0 && primary < buttons.length && buttons[primary].enabled)
        {
            close(primary);
            return true;
        }
        return false;
    }

    /// Height of the title line.
    private float titleHeight(TextSystem t, const ref DialogStyle s)
    {
        return title.length == 0 ? 0 : t.lineHeight(s.font, s.size);
    }

    /// Modal dialog named by its title.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.dialog;
        a.label = title;
        a.modal = true;
    }

    /// Title, content, and the buttons at the bottom right, between the style's widths. Content keeps its natural
    /// width unless it scrolls, then it spans the dialog.
    protected override Size performLayout(Constraints c)
    {
        DialogStyle s = tree.style!DialogStyle();
        TextSystem t = tree.text;
        float widest = width > 0 ? min(width, c.maxW) : max(min(s.maxWidth, c.maxW), s.minWidth);
        float room = widest - s.padX * 2;
        Size bs = children[1].layout(Constraints(0, room, 0, float.infinity));
        Node framed = children[0].children[0];
        float ring = s.ringRoom;
        Size fs = framed.layout(Constraints(0, room + ring * 2, 0, float.infinity));
        float titleW = title.length == 0 ? 0 : t.measure(s.font, s.size, title);
        float w = width > 0 ? widest : clamp(max(fs.w - ring * 2, bs.w, titleW) + s.padX * 2, s.minWidth, widest);
        float th = titleHeight(t, s);
        float y = s.padY + (th > 0 ? th + s.gap : 0);
        float fixed = y + s.gap + bs.h + s.padY;
        float most = isInfinity(c.maxH) ? float.infinity : max(0f, c.maxH - s.margin * 2 - fixed) + ring * 2;
        float fh = framed.layout(Constraints(fs.w, fs.w, 0, float.infinity)).h;
        float sw = fh > most ? w - s.padX * 2 + ring * 2 : fs.w;
        float sh = min(fh, most);
        children[0].layout(Constraints(sw, sw, sh, sh));
        children[0].offset = Point(s.padX - ring, y - ring);
        y += sh - ring * 2 + s.gap;
        children[1].offset = Point(w - s.padX - bs.w, y);
        return c.constrain(Size(w, y + bs.h + s.padY));
    }

    /// Box, title and children.
    override void paint(ref PaintContext ctx, Point origin)
    {
        DialogStyle s = ctx.style!DialogStyle();
        TextSystem t = ctx.text;
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (s.shadow.a > 0)
        {
            ctx.list.shadow(Rect(r.x, r.y + s.shadowY, r.w, r.h), s.radius, s.shadowBlur, s.shadow);
        }
        ctx.list.rect(r, s.fill, s.radius, s.border, 1);
        if (title.length > 0)
        {
            ctx.list.text(t.shape(s.font, s.size, title), Point(origin.x + s.padX,
                origin.y + s.padY + t.ascent(s.font, s.size)), s.title);
        }
        paintChildren(ctx, origin);
    }
}

/// Dialog options, waiting for the content.
struct DialogSpec
{
    string title;              /// title text
    string[] buttons;          /// button captions, left to right
    int primary;               /// index of the button Enter presses, -1 for none
    string primaryVariant;     /// button variant of the main button
    string[] variants;         /// button variants by index, null entries leave the main button to `primaryVariant`
    float width;               /// fixed width, 0 to fit the content
    void delegate(int) onClose; /// runs with the chosen button, -1 for Escape

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(string title, string[] buttons, int primary, string primaryVariant, string[] variants, float width,
        void delegate(int) onClose)
    {
        this.width = width;
        this.title = title;
        this.buttons = buttons;
        this.primary = primary;
        this.primaryVariant = primaryVariant;
        this.variants = variants;
        this.onClose = onClose;
    }

    /// The closed dialog around `content`.
    Dialog opCall(Node content)
    {
        Dialog d = new Dialog(title, content, buttons, primary, primaryVariant, variants, onClose);
        d.width = width;
        return d;
    }
}

/// Closed dialog: `dialog("Remove breakpoints?", buttons: ["Cancel", "Remove"], primary: 1,
/// primaryVariant: "danger", onClose: (int b) { if (b == 1) remove(); })(label(...))`, then `open(tree)`. Content
/// that fills its width, such as a text box, makes the dialog as wide as the style allows unless `width` is set.
/// `variants` styles other buttons, such as `["danger", null, null]` for a red `Don't Save` beside a blue main Save.
DialogSpec dialog(string title, string[] buttons = ["OK"], int primary = 0, string primaryVariant = "primary",
    string[] variants = null, float width = 0, void delegate(int) onClose = null)
{
    return DialogSpec(title, buttons, primary, primaryVariant, variants, width, onClose);
}

// Opening focuses the content, Tab stays inside, presses below do nothing, Escape cancels, Enter presses the
// main button unless disabled, and focus returns.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.label : label;
    import dentrite.widgets.menu : clickOn, menuHost;
    import dentrite.widgets.textbox : TextBox, textBox;

    Host h = menuHost(600, 400);
    scope (exit)
    {
        h.close();
    }
    int below;
    int[] closes;
    Button opener = .button("Open", onClick: () { ++below; });
    h.setRoot(column()(opener));
    h.frame();
    Signal!string name = signal("");
    TextBox field = textBox(name);
    Dialog d = dialog("Rename", buttons: ["Cancel", "Rename"], primary: 1, width: 360,
        onClose: (int b) { closes ~= b; })(
        column(gap: 8)(label("New name"), field));
    h.setFocus(opener);
    d.open(h);
    h.frame();
    assert(d.isOpen && h.focused is field, "focus goes to the first Tab stop");
    assert(d.bounds.w == 360 && d.bounds.x == 120, "centered");
    h.injectKey(Key.tab, 0);
    h.injectKey(Key.tab, 0);
    assert(h.focused is d.button(1));
    h.injectKey(Key.tab, 0);
    assert(h.focused is field, "Tab stays inside");

    clickOn(h, opener);
    assert(below == 0 && d.isOpen, "a press outside does nothing");
    h.setFocus(field);
    h.injectKey(Key.escape, 0);
    assert(d.isOpen == false && closes == [-1] && h.focused is opener, "Escape cancels and focus returns");

    d.button(1).setEnabled(false);
    d.open(h);
    h.frame();
    h.injectKey(Key.enter, 0);
    assert(d.isOpen, "Enter does nothing while the main button is disabled");
    d.button(1).setEnabled(true);
    h.injectKey(Key.enter, 0);
    assert(d.isOpen == false && closes == [-1, 1]);
    d.open(h);
    h.frame();
    clickOn(h, d.button(0));
    assert(closes == [-1, 1, 0]);
}

// Content taller than the window scrolls between the title and the buttons, and Tab scrolls to the focused box.
unittest
{
    import dentrite.containers : column;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;
    import dentrite.widgets.textbox : TextBox, textBox;

    Host h = menuHost(600, 400);
    scope (exit)
    {
        h.close();
    }
    h.setRoot(column()());
    h.frame();
    Node[] boxes;
    foreach (int i; 0 .. 30)
    {
        boxes ~= textBox(signal(""));
    }
    Dialog d = dialog("Many", width: 300)(column(gap: 4)(boxes));
    d.open(h);
    h.frame();
    ScrollView sv = cast(ScrollView) d.children[0];
    DialogStyle s;
    assert(d.bounds.h == 400 - s.margin * 2 && d.bounds.y == s.margin, "as tall as the window allows");
    assert(sv.size.w == 300 - s.padX * 2 + s.ringRoom * 2 && d.button(0).bounds.bottom <= d.bounds.bottom);
    assert(h.focused is boxes[0] && sv.scrollY == 0);
    foreach (int i; 0 .. 29)
    {
        h.injectKey(Key.tab, 0);
    }
    h.frame();
    assert(h.focused is boxes[29] && sv.scrollY > 0 && boxes[29].bounds.bottom <= sv.bounds.bottom,
        "Tab scrolls to the focused box");
    h.injectKey(Key.tab, 0);
    h.frame();
    assert(h.focused is d.button(0) && sv.scrollY > 0, "the buttons stay in view");
    h.injectWheel(sv.bounds.pos + Point(10, 10), -10_000);
    assert(sv.scrollY == 0);
}

// Variants style buttons by index, and a null entry leaves the main button to primaryVariant.
unittest
{
    import dentrite.widgets.label : label;

    Dialog d = dialog("Unsaved changes", buttons: ["Don't Save", "Cancel", "Save"], primary: 2,
        variants: ["danger"])(label("Save first?"));
    assert(d.button(0).variant == "danger" && d.button(1).variant is null && d.button(2).variant == "primary");
    d = dialog("Unsaved changes", buttons: ["Don't Save", "Save"], primary: 1, variants: [null, "toolbar"])(
        label("Save first?"));
    assert(d.button(0).variant is null && d.button(1).variant == "toolbar", "an entry overrides primaryVariant");
}
