/// Commands and keyboard shortcuts. A command is an action with a label, a shortcut, and enabled and checked
/// states. Menus show it, and shortcut nodes and menu bars fire it.
///
/// Keys go to the focused node and its parents first, so a focused text box keeps Ctrl+C. Shortcuts on that
/// path fire next, then nodes listening to the whole window, unless a popup that grabs input is open.
module dentrite.command;

import dentrite.node;
import dentrite.widgets.icons : Icon;
import std.ascii : isAlpha, isDigit, toLower, toUpper;
import std.format : format;
import std.string : split, strip;

/// Key with modifiers, such as Ctrl+S.
struct Chord
{
    uint key;   /// Key value or lowercase code point, 0 for none
    ubyte mods; /// `Mod` flags, combined with `|`

    /// True if `e` is this key with exactly these modifiers.
    bool matches(ref const KeyEvent e) const
    {
        return key != 0 && e.key == key && e.mods == mods;
    }

    /// Text such as "Ctrl+Shift+S" or "F5", empty for none.
    string toString() const
    {
        if (key == 0)
        {
            return "";
        }
        string s;
        if (mods & Mod.ctrl)
        {
            s ~= "Ctrl+";
        }
        if (mods & Mod.shift)
        {
            s ~= "Shift+";
        }
        if (mods & Mod.alt)
        {
            s ~= "Alt+";
        }
        if (mods & Mod.gui)
        {
            version (OSX)
            {
                s ~= "Cmd+";
            }
            else
            {
                s ~= "Super+";
            }
        }
        return s ~ keyName(key);
    }
}

/// Key code and the names `chord` accepts for it, the first one shown by `Chord.toString`.
private struct KeyName
{
    uint key;       /// key code
    string[] names; /// accepted names
}

/// Named keys.
private immutable KeyName[] keyNames = [
    KeyName(Key.backspace, ["Backspace"]), KeyName(Key.tab, ["Tab"]), KeyName(Key.enter, ["Enter", "Return"]),
    KeyName(Key.escape, ["Esc", "Escape"]), KeyName(Key.space, ["Space"]), KeyName(Key.delete_, ["Del", "Delete"]),
    KeyName(Key.insert, ["Ins", "Insert"]), KeyName(Key.home, ["Home"]), KeyName(Key.end, ["End"]),
    KeyName(Key.pageUp, ["PgUp", "PageUp"]), KeyName(Key.pageDown, ["PgDn", "PageDown"]),
    KeyName(Key.left, ["Left"]), KeyName(Key.right, ["Right"]), KeyName(Key.up, ["Up"]), KeyName(Key.down, ["Down"]),
    KeyName(Key.menu, ["Menu"]), KeyName('+', ["Plus"]), KeyName('-', ["Minus"]),
];

/// Display name of key code `k`.
private string keyName(uint k)
{
    foreach (ref immutable KeyName n; keyNames)
    {
        if (n.key == k)
        {
            return n.names[0];
        }
    }
    if (k >= Key.f1 && k <= Key.f12)
    {
        return format("F%d", k - Key.f1 + 1);
    }
    if (k < 0x80)
    {
        return [cast(char) toUpper(cast(char) k)];
    }
    if (k < 0x40000000)
    {
        import std.conv : to;

        return to!string(cast(dchar) k);
    }
    return format("Key %X", k);
}

/// Shortcut from text such as "Ctrl+Shift+S", "F5" or "Alt+Left", any case. Modifiers are Ctrl, Shift, Alt and
/// Super (also Cmd, Gui or Meta). Null or empty gives no shortcut. Throws on anything else.
Chord chord(string text)
{
    Chord c;
    if (text.length == 0)
    {
        return c;
    }
    string[] parts = text.split("+");
    foreach (string raw; parts[0 .. $ - 1])
    {
        switch (lower(raw.strip))
        {
        case "ctrl":
        case "control":
            c.mods |= Mod.ctrl;
            break;
        case "shift":
            c.mods |= Mod.shift;
            break;
        case "alt":
            c.mods |= Mod.alt;
            break;
        case "super":
        case "cmd":
        case "gui":
        case "meta":
            c.mods |= Mod.gui;
            break;
        default:
            throw new Exception(format("shortcut %s: unknown modifier %s", text, raw));
        }
    }
    string name = parts[$ - 1].strip;
    string low = lower(name);
    foreach (ref immutable KeyName k; keyNames)
    {
        foreach (string n; k.names)
        {
            if (lower(n) == low)
            {
                c.key = k.key;
                return c;
            }
        }
    }
    if (name.length >= 2 && low[0] == 'f' && name[1 .. $].isNumber)
    {
        import std.conv : to;

        int f = to!int(name[1 .. $]);
        if (f >= 1 && f <= 12)
        {
            c.key = Key.f1 + f - 1;
            return c;
        }
    }
    if (name.length == 1 && name[0] > 0x20 && name[0] < 0x7f)
    {
        c.key = toLower(name[0]);
        return c;
    }
    throw new Exception(format("shortcut %s: unknown key %s", text, name));
}

/// Parsing and display: modifiers in any order and case, names, function keys and single characters.
unittest
{
    assert(chord("Ctrl+S") == Chord('s', Mod.ctrl));
    assert(chord("shift+ctrl+z") == Chord('z', Mod.ctrl | Mod.shift));
    assert(chord("F5") == Chord(Key.f5, 0));
    assert(chord("Alt+Left") == Chord(Key.left, Mod.alt));
    assert(chord("Ctrl+Plus") == Chord('+', Mod.ctrl));
    assert(chord("Ctrl+/") == Chord('/', Mod.ctrl));
    assert(chord("") == Chord.init && chord("").toString == "");
    assert(chord("ctrl+shift+s").toString == "Ctrl+Shift+S");
    assert(chord("Escape").toString == "Esc");
    assert(chord("F12").toString == "F12");
    assert(Chord('+', Mod.ctrl).toString == "Ctrl+Plus");
    bool threw;
    try
    {
        chord("Hyper+S");
    }
    catch (Exception)
    {
        threw = true;
    }
    assert(threw);
    KeyEvent e = KeyEvent('s', Mod.ctrl);
    assert(chord("Ctrl+S").matches(e));
    assert(chord("Ctrl+Shift+S").matches(e) == false);
    assert(chord("S").matches(e) == false);
}

/// ASCII lowercase copy of `s`.
private string lower(string s)
{
    char[] r = s.dup;
    foreach (ref char ch; r)
    {
        ch = toLower(ch);
    }
    return cast(string) r;
}

/// True if `s` is all decimal digits.
private bool isNumber(string s)
{
    foreach (char ch; s)
    {
        if (isDigit(ch) == false)
        {
            return false;
        }
    }
    return s.length > 0;
}

/// Action with a label, a shortcut, and enabled and checked states. Build it once and hand it to menus and
/// shortcut nodes. `enabled` and `checked` may read signals, and menus follow them.
final class Command
{
    string label;            /// menu text, `&` before the mnemonic letter and `&&` for a literal &
    Chord keys;              /// shortcut, `Chord.init` for none
    string keysLabel;        /// shortcut text shown in place of `keys`, for keys the app handles itself
    Icon icon;               /// icon in menus
    void delegate() action;  /// runs when the command fires
    bool delegate() enabled; /// true when the command may run, null for always
    bool delegate() checked; /// true to show a check mark, null for none

    /// Shortcut text for menus, tooltips and screen readers: `keysLabel`, else `keys`, empty for none.
    string shortcut()
    {
        return keysLabel.length > 0 ? keysLabel : keys.toString;
    }

    /// True if it can run.
    bool isEnabled()
    {
        return enabled is null || enabled();
    }

    /// True if it shows a check mark.
    bool isChecked()
    {
        return checked !is null && checked();
    }

    /// Runs the action if enabled. True if it ran.
    bool run()
    {
        if (action is null || isEnabled == false)
        {
            return false;
        }
        action();
        return true;
    }
}

/// New command, such as `command("&Save", &save, keys: "Ctrl+S", enabled: () => dirty.get)`. `keysLabel`
/// shows a shortcut that the command does not fire.
Command command(string label, void delegate() action, string keys = null, Icon icon = Icon.none,
    bool delegate() enabled = null, bool delegate() checked = null, string keysLabel = null)
{
    Command c = new Command;
    c.label = label;
    c.action = action;
    c.keys = chord(keys);
    c.keysLabel = keysLabel;
    c.icon = icon;
    c.enabled = enabled;
    c.checked = checked;
    return c;
}

/// Runs the first enabled command of `commands` whose shortcut is `e`. True if one ran.
bool fire(Command[] commands, ref const KeyEvent e)
{
    foreach (Command c; commands)
    {
        if (c.keys.matches(e) && c.run())
        {
            return true;
        }
    }
    return false;
}

/// Content with shortcuts for keys that nothing on the focus path used. Without `window`, they fire while
/// focus is inside the content, or when nothing has focus and the content is the app root. With `window`,
/// they fire from anywhere.
final class Shortcuts : Node, WindowKeys
{
    Command[] commands; /// commands fired by their shortcuts
    bool window;        /// true to take keys from the whole window, not only the focus path. Set before attaching

    /// Wraps `content`.
    this(Command[] commands, bool window, Node content)
    {
        this.commands = commands;
        this.window = window;
        add(content);
    }

    /// The content's size.
    protected override Size performLayout(Constraints c)
    {
        children[0].offset = Point.init;
        return children[0].layout(c);
    }

    /// Fires a command for a key from the focus path.
    override bool onKey(ref const KeyEvent e)
    {
        return fire(commands, e);
    }

    /// Fires a command for a key from anywhere.
    bool windowKey(ref const KeyEvent e)
    {
        return fire(commands, e);
    }

    /// Starts listening to the window if asked.
    override void onAttach()
    {
        if (window)
        {
            tree.addWindowKeys(this);
        }
    }

    /// Stops listening to the window.
    override void onDetach()
    {
        tree.removeWindowKeys(this);
    }
}

/// Shortcut options, waiting for the content.
struct ShortcutsSpec
{
    Command[] commands; /// commands fired by their shortcuts
    bool window;        /// true to take keys from the whole window, not only the focus path

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Command[] commands, bool window)
    {
        this.commands = commands;
        this.window = window;
    }

    /// The content with these shortcuts.
    Shortcuts opCall(Node content)
    {
        return new Shortcuts(commands, window, content);
    }
}

/// Shortcuts for `content`: `shortcuts([save, find])(editor)`, or `window: true` to listen to the whole window.
ShortcutsSpec shortcuts(Command[] commands, bool window = false)
{
    return ShortcutsSpec(commands.dup, window);
}

// A command runs only when enabled, and shortcut nodes fire it from the focus path or the window.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.textbox : TextBox, textBox;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    Host h = new Host(new HeadlessPlatform(300, 200), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int saved;
    int found;
    Signal!bool canSave = signal(true);
    Command save = command("&Save", () { ++saved; }, keys: "Ctrl+S", enabled: &canSave.get);
    Command find = command("&Find", () { ++found; }, keys: "Ctrl+F");
    Signal!string text = signal("");
    TextBox box = textBox(text);
    Button inside = button("In");
    Button outside = button("Out");
    h.setRoot(shortcuts([save], window: true)(column()(shortcuts([find])(column()(box, inside)), outside)));
    h.frame();

    h.injectKey('s', Mod.ctrl);
    h.injectKey('f', Mod.ctrl);
    assert(saved == 1 && found == 0, "nothing focused: window shortcut only");
    h.setFocus(inside);
    h.injectKey('f', Mod.ctrl);
    assert(found == 1, "focus inside");
    h.setFocus(outside);
    h.injectKey('f', Mod.ctrl);
    assert(found == 1, "focus outside");
    canSave.set(false);
    h.injectKey('s', Mod.ctrl);
    assert(saved == 1, "disabled");
    canSave.set(true);
    h.setFocus(box);
    h.injectKey('a', Mod.ctrl);
    h.injectKey('s', Mod.ctrl);
    assert(saved == 2, "a text box keeps Ctrl+A and passes Ctrl+S on");
}
