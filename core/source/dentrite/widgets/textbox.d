/// Single-line text box bound to a string signal: caret, selection, clipboard, word movement, and input method
/// text shown in place of the selection until committed. The retained box and the island function share
/// `LineEdit` for editing and `paintTextBox` for the look.
module dentrite.widgets.textbox;

import core.time : MonoTime, msecs;
import dentrite.immediate;
import dentrite.node;
import dentrite.signals : Signal, effect;
import dentrite.text;
import dentrite.widgets.handles : HandleTarget, SelectionHandles;
import std.algorithm.comparison : clamp, max, min;
import std.array : replicate;
import std.ascii : isAlphaNum;
import std.range.primitives : walkLength;
import std.math : isInfinity, round;
import std.utf : stride, strideBack;

/// Look of a text box.
struct TextBoxStyle
{
    enum section = "textbox"; /// section name in theme files

    Color fill = Color(0x1e, 0x1e, 0x21, 0xff);        /// background
    Color fillFocus = Color(0x1a, 0x1a, 0x1d, 0xff);   /// background while focused
    Color fillDisabled = Color(0x24, 0x24, 0x27, 0xff); /// background when disabled
    Color border = Color(0x48, 0x48, 0x4e, 0xff);      /// outline
    Color borderFocus = Color(0x4c, 0x8d, 0xf6, 0xff); /// outline while focused
    Color text = Color(0xdd, 0xdd, 0xdd, 0xff);        /// text color
    Color textDisabled = Color(0x80, 0x80, 0x80, 0xff); /// text color when disabled
    Color placeholder = Color(0x78, 0x78, 0x80, 0xff); /// placeholder text color
    Color selection = Color(0x2f, 0x5c, 0xa8, 0xff);   /// selection highlight
    Color caret = Color(0xff, 0xff, 0xff, 0xff);       /// caret color
    float radius = 4;     /// corner radius
    float padX = 6;       /// horizontal padding
    float padY = 4;       /// vertical padding
    float minWidth = 80;  /// width when the parent leaves the width open
    FontKind font = FontKind.ui; /// text font
    float size = 13;      /// text size
    Features features;    /// OpenType features
}

/// True if `e` is a key that types text, so shortcuts without Ctrl, Alt or Super do not fire while typing.
private bool typesText(ref const KeyEvent e)
{
    return e.key >= Key.space && e.key < 0x40000000 && (e.mods & (Mod.ctrl | Mod.alt | Mod.gui)) == 0;
}

/// Content, caret, selection and input method text of a single-line box, with its editing.
struct LineEdit
{
    string text;          /// text being edited
    size_t caret;         /// byte offset of the caret
    size_t anchor;        /// byte offset of the other end of the selection, equal to `caret` for none
    string composing;     /// input method text, not in `text` yet
    size_t composeFrom;   /// byte offset into `composing` where the part being converted starts
    size_t composeTo;     /// byte offset into `composing` where that part ends, also the caret
    float scrollX = 0;    /// horizontal scroll of the text, keeping the caret visible
    float caretX = 0;     /// caret x from the text start as last painted, in logical pixels
    MonoTime blinkStart;  /// when the caret blink last restarted, shown from then
    bool dragging;        /// selecting with the pointer
    bool password;        /// shows a dot per character, keeps the text off the clipboard and hides compositions

    /// Takes `v` from outside, keeping the caret and selection inside it.
    void setText(string v)
    {
        text = v;
        caret = min(caret, text.length);
        anchor = min(anchor, text.length);
    }

    /// Editing key `e`, using the clipboard of `sv` when not null. True if handled, also for keys that type
    /// text, so shortcuts without Ctrl, Alt or Super do not fire while typing.
    bool key(ref const KeyEvent e, Services sv)
    {
        bool shift = (e.mods & Mod.shift) != 0;
        bool word = (e.mods & Mod.ctrl) != 0;
        switch (e.key)
        {
        case Key.left:
            if (caret != anchor && shift == false)
            {
                caret = anchor = min(caret, anchor);
            }
            else
            {
                move(word ? wordStart(caret) : prev(caret), shift);
            }
            return true;
        case Key.right:
            if (caret != anchor && shift == false)
            {
                caret = anchor = max(caret, anchor);
            }
            else
            {
                move(word ? wordEnd(caret) : next(caret), shift);
            }
            return true;
        case Key.home:
            move(0, shift);
            return true;
        case Key.end:
            move(text.length, shift);
            return true;
        case Key.backspace:
            if (caret == anchor)
            {
                anchor = word ? wordStart(caret) : prev(caret);
            }
            replace("");
            return true;
        case Key.delete_:
            if (caret == anchor)
            {
                anchor = word ? wordEnd(caret) : next(caret);
            }
            replace("");
            return true;
        case Key.a:
            if (word == false)
            {
                return typesText(e);
            }
            anchor = 0;
            caret = text.length;
            return true;
        case Key.c:
        case Key.x:
            if (word == false)
            {
                return typesText(e);
            }
            if (caret != anchor && sv !is null && password == false)
            {
                sv.setClipboard(text[min(caret, anchor) .. max(caret, anchor)]);
                if (e.key == Key.x)
                {
                    replace("");
                }
            }
            return true;
        case Key.v:
            if (word == false)
            {
                return typesText(e);
            }
            if (sv !is null)
            {
                replace(singleLine(sv.clipboard));
            }
            return true;
        case Key.escape:
            if (text.length == 0)
            {
                return false;
            }
            anchor = 0;
            caret = text.length;
            replace("");
            return true;
        default:
            return typesText(e);
        }
    }

    /// Replaces the selection with typed `s`, line breaks and tabs as spaces, ending any composition.
    void type(string s)
    {
        composing = null;
        replace(singleLine(s));
    }

    /// Shows input method text `s` in place of the selection, single line, null to clear. Bytes `from .. to` of
    /// it are the part being converted, or the caret when equal. Nothing for a password.
    void compose(string s, size_t from, size_t to)
    {
        composing = password ? null : singleLine(s);
        composeFrom = min(from, composing.length);
        composeTo = min(to, composing.length);
    }

    /// Press at byte `i`: places the caret, extends the selection with Shift in `mods`, selects a word on a
    /// double click and everything on a triple. A single click starts a drag.
    void press(size_t i, ubyte clicks, ubyte mods)
    {
        caret = i;
        if ((mods & Mod.shift) == 0)
        {
            anchor = caret;
        }
        if (clicks == 2)
        {
            size_t[2] w = wordAt(caret);
            anchor = w[0];
            caret = w[1];
        }
        else if (clicks >= 3)
        {
            anchor = 0;
            caret = text.length;
        }
        dragging = clicks < 2;
    }

    /// Moves the caret to `to`, extending the selection when `extend`.
    private void move(size_t to, bool extend)
    {
        caret = to;
        if (extend == false)
        {
            anchor = caret;
        }
    }

    /// Replaces the selection with `s`.
    void replace(string s)
    {
        size_t a = min(caret, anchor);
        size_t b = max(caret, anchor);
        text = text[0 .. a] ~ s ~ text[b .. $];
        caret = anchor = a + s.length;
    }

    /// Character boundary before `i`.
    private size_t prev(size_t i)
    {
        return i == 0 ? 0 : i - strideBack(text, i);
    }

    /// Character boundary after `i`.
    private size_t next(size_t i)
    {
        return i >= text.length ? text.length : i + stride(text, i);
    }

    /// Start of the word at or before `i`, 0 for a password.
    private size_t wordStart(size_t i)
    {
        if (password)
        {
            return 0;
        }
        while (i > 0 && isAlphaNum(text[i - 1]) == false && text[i - 1] < 0x80)
        {
            --i;
        }
        while (i > 0 && (isAlphaNum(text[i - 1]) || text[i - 1] >= 0x80))
        {
            --i;
        }
        return i;
    }

    /// Word holding the character at `i` or just before it, else the run of other characters there, everything
    /// for a password. For selecting a word under a press.
    private size_t[2] wordAt(size_t i)
    {
        if (password)
        {
            return [0, text.length];
        }
        bool word(size_t k)
        {
            return isAlphaNum(text[k]) || text[k] >= 0x80;
        }

        bool inWord = (i < text.length && word(i)) || (i > 0 && word(i - 1));
        size_t a = i;
        size_t b = i;
        while (a > 0 && word(a - 1) == inWord)
        {
            --a;
        }
        while (b < text.length && word(b) == inWord)
        {
            ++b;
        }
        return [a, b];
    }

    /// End of the word at or after `i`, the text end for a password.
    private size_t wordEnd(size_t i)
    {
        if (password)
        {
            return text.length;
        }
        while (i < text.length && isAlphaNum(text[i]) == false && text[i] < 0x80)
        {
            ++i;
        }
        while (i < text.length && (isAlphaNum(text[i]) || text[i] >= 0x80))
        {
            ++i;
        }
        return i;
    }

    /// Text as drawn: the text, or a dot per character for a password.
    string shown() const
    {
        return password ? mask.replicate(text.walkLength) : text;
    }

    /// Byte offset into `shown` of byte `i` of the text.
    size_t toShown(size_t i) const
    {
        return password ? mask.length * text[0 .. min(i, text.length)].walkLength : i;
    }

    /// Byte offset into the text of byte `j` of `shown`.
    size_t fromShown(size_t j) const
    {
        if (password == false)
        {
            return j;
        }
        size_t i;
        foreach (size_t k; 0 .. j / mask.length)
        {
            if (i >= text.length)
            {
                break;
            }
            i += stride(text, i);
        }
        return i;
    }

    /// Selects from `anchor` to `caret`, byte offsets into `shown`, as a screen reader asks. False when `caret`
    /// is past the end.
    bool selectShown(size_t anchor, size_t caret)
    {
        size_t n = toShown(text.length);
        if (caret > n)
        {
            return false;
        }
        this.caret = fromShown(caret);
        this.anchor = fromShown(anchor <= n ? anchor : caret);
        dragging = false;
        return true;
    }
}

/// Dot drawn for each character of a password.
private enum string mask = "•";

/// Size of a text box under `c`: the bounded width or the minimum, one line tall.
Size measureTextBox(Constraints c, const ref TextBoxStyle s, TextSystem t)
{
    return Size(isInfinity(c.maxW) ? s.minWidth : c.maxW, t.lineHeight(s.font, s.size) + s.padY * 2);
}

/// Byte offset of `e` under window x `wx` in a box at `r`, with the scroll of the last paint.
size_t indexAtX(ref const LineEdit e, Rect r, const ref TextBoxStyle s, TextSystem t, float wx)
{
    float local = wx - (r.x + s.padX - round(e.scrollX));
    return e.fromShown(t.shape(s.font, s.size, e.shown, s.features).indexAt(local * t.ppp));
}

/// Line of `e` for screen readers in a box at window rect `r`, with the scroll of the last paint.
AccessLine[] accessLinesOf(ref const LineEdit e, Rect r, const ref TextBoxStyle s, TextSystem t)
{
    string shown = e.shown;
    float[] edges = t.shape(s.font, s.size, shown, s.features).charEdges(0, shown.length, 0, t.ppp);
    Rect box = Rect(r.x + s.padX - round(e.scrollX), r.y + s.padY, edges[$ - 1], t.lineHeight(s.font, s.size));
    return [AccessLine(0, shown.length, box, edges)];
}

/// Caret of `e` in a box at `r` as last painted, in window coordinates.
Rect caretRectOf(ref const LineEdit e, Rect r, const ref TextBoxStyle s, TextSystem t)
{
    return Rect(r.x + s.padX - round(e.scrollX) + e.caretX, r.y + s.padY, 1, t.lineHeight(s.font, s.size));
}

/// True if a caret blinking since `start` shows at `now`, with `next` set to when that changes.
bool caretBlink(MonoTime start, MonoTime now, out MonoTime next)
{
    long ms = (now - start).total!"msecs";
    next = now + msecs(530 - ms % 530);
    return ms % 1000 < 530;
}

/// Paints a text box of `e` in `r`: box, selection, text, input method text, and the caret when `caretOn`.
/// Scrolls `e` so the caret stays in view and records where it went. `trailing` is kept clear at the right.
/// Shared by the retained node and the island function.
void paintTextBox(ref PaintContext ctx, Rect r, const ref TextBoxStyle s, ref LineEdit e, string placeholder,
    float trailing, bool focused, bool enabled, bool caretOn)
{
    TextSystem t = ctx.text;
    ctx.list.rect(r, enabled == false ? s.fillDisabled : focused ? s.fillFocus : s.fill, s.radius,
        focused ? s.borderFocus : s.border, 1);
    Rect inner = r.inset(Insets(s.padX, 0, s.padX + trailing, 0));
    float top = r.y + s.padY;
    float lineH = t.lineHeight(s.font, s.size);
    float baseline = top + t.ascent(s.font, s.size);
    size_t a = e.toShown(min(e.caret, e.anchor));
    size_t b = e.toShown(max(e.caret, e.anchor));
    bool composes = e.composing.length > 0;
    string drawn = e.shown;
    string shown = composes ? drawn[0 .. a] ~ e.composing ~ drawn[b .. $] : drawn;
    ShapedRun run = t.shape(s.font, s.size, shown, s.features);
    float caretPx = run.caretX(composes ? a + e.composeTo : e.toShown(e.caret)) / t.ppp;
    e.caretX = caretPx;
    float viewW = inner.w;
    if (caretPx - e.scrollX > viewW - 1)
    {
        e.scrollX = caretPx - viewW + 1;
    }
    if (caretPx - e.scrollX < 0)
    {
        e.scrollX = caretPx;
    }
    e.scrollX = clamp(e.scrollX, 0, max(0f, run.width / t.ppp - viewW + 1));
    float x0 = inner.x - round(e.scrollX);
    ctx.clipped(inner, {
        if (shown.length == 0 && placeholder.length > 0)
        {
            ctx.list.text(t.shape(s.font, s.size, placeholder, s.features), Point(inner.x, baseline), s.placeholder);
        }
        if (focused && e.caret != e.anchor && composes == false)
        {
            float sa = run.caretX(a) / t.ppp;
            float sb = run.caretX(b) / t.ppp;
            ctx.list.rect(Rect(x0 + sa, top, sb - sa, lineH), s.selection);
        }
        ctx.list.text(run, Point(x0, baseline), enabled ? s.text : s.textDisabled);
        if (composes)
        {
            underline(ctx, run, a, a + e.composing.length, x0, top + lineH - 1, 1, s.text);
            underline(ctx, run, a + e.composeFrom, a + e.composeTo, x0, top + lineH - 2, 2, s.text);
        }
        if (focused && caretOn)
        {
            ctx.list.rect(Rect(x0 + caretPx, top, 1, lineH), s.caret);
        }
    });
}

/// Line under bytes `from .. to` of `run`, `thick` pixels from `y` down, none when empty.
private void underline(ref PaintContext ctx, ShapedRun run, size_t from, size_t to, float x0, float y,
    float thick, Color c)
{
    float ua = run.caretX(from) / ctx.text.ppp;
    float ub = run.caretX(to) / ctx.text.ppp;
    if (ub > ua)
    {
        ctx.list.rect(Rect(x0 + ua, y, ub - ua, thick), c);
    }
}

/// Retained single-line text box. Open for the combo box, which takes keys before the box does.
class TextBox : Node, Composer, HandleTarget
{
    Signal!string value;  /// bound text
    string placeholder;   /// placeholder text shown while empty
    LineEdit line;        /// content, caret and selection
    float trailing = 0;   /// space at the right end kept clear of text, for a combo box arrow
    bool enabled = true;  /// takes focus and input
    private SelectionHandles handles; /// touch selection handles, made on first use

    /// Creates a box over `value`. The binding effect belongs to the current owner.
    this(Signal!string value, string placeholder)
    {
        this.value = value;
        this.placeholder = placeholder;
        interactive = true;
        focusable = true;
        textInput = true;
        longPress = true;
        cursor = CursorShape.text;
        effect(() {
            string v = value.get;
            if (v != line.text)
            {
                line.setText(v);
                markNeedsPaint();
            }
        });
    }

    /// Current content.
    ref string text() return
    {
        return line.text;
    }

    /// Byte offset of the caret.
    ref size_t caret() return
    {
        return line.caret;
    }

    /// Other end of the selection.
    ref size_t anchor() return
    {
        return line.anchor;
    }

    /// Enables or disables. Disabling drops focus.
    void setEnabled(bool on)
    {
        if (on == enabled)
        {
            return;
        }
        enabled = on;
        focusable = on;
        cursor = on ? CursorShape.text : CursorShape.arrow;
        if (on == false && focused && tree !is null && tree.services !is null)
        {
            tree.services.setFocus(null);
        }
        markNeedsPaint();
    }

    /// Text field with its text and hint. Name it with `accessName` or a label.
    override void describe(ref AccessInfo a)
    {
        a.role = line.password ? Role.passwordInput : Role.textInput;
        a.value = line.shown;
        a.placeholder = placeholder;
        a.disabled = enabled == false;
        a.caret = line.toShown(line.caret);
        a.anchor = line.toShown(line.anchor);
        a.allow(AccessAction.setValue);
        a.allow(AccessAction.setSelection);
        if (tree !is null)
        {
            TextBoxStyle s = tree.style!TextBoxStyle();
            a.lines = accessLinesOf(line, bounds, s, tree.text);
        }
    }

    /// Replaces the text, or moves the caret and selection.
    override bool accessAction(ref const AccessRequest r)
    {
        if (enabled && r.action == AccessAction.setSelection && line.selectShown(r.anchor, r.caret))
        {
            touch();
            return true;
        }
        if (r.action != AccessAction.setValue || enabled == false || r.text is null)
        {
            return false;
        }
        line.setText(r.text);
        value.set(r.text);
        markNeedsPaint();
        return true;
    }

    /// Bounded width or the minimum, one line tall.
    protected override Size performLayout(Constraints c)
    {
        TextBoxStyle s = tree.style!TextBoxStyle();
        return measureTextBox(c, s, tree.text);
    }

    /// Box, selection, text, caret.
    override void paint(ref PaintContext ctx, Point origin)
    {
        TextBoxStyle s = ctx.style!TextBoxStyle();
        bool caretOn;
        if (focused && tree.services !is null)
        {
            MonoTime next;
            caretOn = caretBlink(line.blinkStart, tree.services.now, next);
            markNeedsPaintAt(next);
        }
        paintTextBox(ctx, Rect(origin.x, origin.y, size.w, size.h), s, line, placeholder, trailing, focused,
            enabled, caretOn);
        if (handles !is null && handles.shown)
        {
            ShapedRun run = ctx.text.shape(s.font, s.size, line.shown, s.features);
            float x0 = bounds.x + s.padX - round(line.scrollX);
            float left = bounds.x + s.padX;
            float right = bounds.right - s.padX - trailing;
            Rect at(size_t i)
            {
                return Rect(x0 + run.caretX(line.toShown(i)) / ctx.text.ppp, bounds.y + s.padY, 1,
                    ctx.text.lineHeight(s.font, s.size));
            }

            Rect a = at(line.anchor);
            Rect c = at(line.caret);
            handles.place(a, focused && a.x >= left && a.x <= right, c, focused && c.x >= left && c.x <= right);
        }
    }

    /// Selects the word under `p` with handles to change it. A context menu around it still opens.
    override bool onLongPress(Point p)
    {
        if (enabled == false || tree is null)
        {
            return false;
        }
        if (tree.services !is null)
        {
            tree.services.setFocus(this);
        }
        TextBoxStyle s = tree.style!TextBoxStyle();
        line.press(indexAtX(line, bounds, s, tree.text, p.x), 2, 0);
        showHandles();
        touch();
        return false;
    }

    /// Moves an end of the selection to the text under `p`, from a handle.
    void dragHandle(bool caretEnd, Point p)
    {
        TextBoxStyle s = tree.style!TextBoxStyle();
        size_t i = indexAtX(line, bounds, s, tree.text, p.x);
        if (caretEnd)
        {
            line.caret = i;
        }
        else
        {
            line.anchor = i;
        }
        touch();
    }

    /// True while touch selection handles show.
    bool handlesShown()
    {
        return handles !is null && handles.shown;
    }

    /// Shows the touch selection handles.
    private void showHandles()
    {
        if (handles is null)
        {
            handles = new SelectionHandles(this, this);
        }
        handles.show();
    }

    /// Hides the touch selection handles.
    private void hideHandles()
    {
        if (handles !is null)
        {
            handles.hide();
        }
    }

    /// Drops the handles with the box.
    override void onDetach()
    {
        hideHandles();
    }

    /// Shows input method text in place of the selection, single line, until committed or cleared.
    void compose(string s, size_t from, size_t to)
    {
        line.compose(enabled ? s : null, from, to);
        touch();
    }

    /// Caret in window coordinates as last painted.
    Rect caretRect()
    {
        TextBoxStyle s = tree.style!TextBoxStyle();
        return caretRectOf(line, bounds, s, tree.text);
    }

    /// Restarts the blink so the caret shows right after a change.
    private void touch()
    {
        if (tree !is null && tree.services !is null)
        {
            line.blinkStart = tree.services.now;
        }
        markNeedsPaint();
    }

    /// Caret placement, word or full selection on double click, drag selection.
    override bool onPointer(ref const PointerEvent e)
    {
        if (enabled == false)
        {
            return false;
        }
        TextBoxStyle s = tree.style!TextBoxStyle();
        switch (e.kind)
        {
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            line.press(indexAtX(line, bounds, s, tree.text, e.pos.x), e.clicks, e.mods);
            if (e.source != PointerSource.mouse && e.clicks == 2)
            {
                showHandles();
            }
            else
            {
                hideHandles();
            }
            touch();
            return true;
        case PointerKind.move:
            if (line.dragging)
            {
                line.caret = indexAtX(line, bounds, s, tree.text, e.pos.x);
                touch();
            }
            return line.dragging;
        case PointerKind.cancel:
        case PointerKind.up:
            line.dragging = false;
            return true;
        default:
            return false;
        }
    }

    /// Editing keys.
    override bool onKey(ref const KeyEvent e)
    {
        if (enabled == false)
        {
            return false;
        }
        string before = line.text;
        if (line.key(e, tree is null ? null : tree.services) == false)
        {
            return false;
        }
        if (line.text != before)
        {
            value.set(line.text);
        }
        hideHandles();
        touch();
        return true;
    }

    /// Inserts typed text.
    override bool onText(string s)
    {
        line.composing = null;
        if (enabled == false)
        {
            return false;
        }
        hideHandles();
        line.type(s);
        value.set(line.text);
        touch();
        return true;
    }

    /// Restarts the blink and repaints, and drops the handles when focus leaves.
    override void onFocus(bool gained)
    {
        line.dragging = false;
        line.composing = null;
        if (gained == false)
        {
            hideHandles();
        }
        touch();
    }
}

/// `s` with line breaks and tabs turned into spaces.
private string singleLine(string s)
{
    char[] o = s.dup;
    foreach (ref char c; o)
    {
        if (c == '\n' || c == '\r' || c == '\t')
        {
            c = ' ';
        }
    }
    return o.idup;
}

/// Retained text box: `textBox(query, placeholder: "Filter")`. `enabled` greys it out and stops input when false.
/// `password` draws a dot per character, keeps the text off the clipboard and asks for input methods off.
TextBox textBox(Signal!string value, string placeholder = null, bool delegate() enabled = null,
    string tooltip = null, string accessName = null, bool password = false)
{
    TextBox b = new TextBox(value, placeholder);
    b.line.password = password;
    b.hiddenText = password;
    b.setTooltip(tooltip);
    b.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { b.setEnabled(enabled()); });
    }
    return b;
}

/// Paint-only text box declared by an island pass, over editing state kept in the island's memory.
final class TextBoxBox : Node
{
    TextBoxStyle style; /// style in use, resolved from the theme
    LineEdit* line;     /// editing state, scrolled by paint
    string placeholder; /// placeholder text shown while empty
    bool hasFocus;      /// focused inside the island
    bool enabled;       /// takes input
    bool caretOn;       /// caret shown at this blink phase
    Ui ui;              /// island context told where the caret is for the input method, null when not focused

    /// Creates a box.
    this(TextBoxStyle style, LineEdit* line, string placeholder, bool hasFocus, bool enabled, bool caretOn)
    {
        this.style = style;
        this.line = line;
        this.placeholder = placeholder;
        this.hasFocus = hasFocus;
        this.enabled = enabled;
        this.caretOn = caretOn;
    }

    /// Text field with its text and hint.
    override void describe(ref AccessInfo a)
    {
        a.role = line.password ? Role.passwordInput : Role.textInput;
        a.value = line.shown;
        a.placeholder = placeholder;
        a.disabled = enabled == false;
        a.caret = line.toShown(line.caret);
        a.anchor = line.toShown(line.anchor);
        if (tree !is null)
        {
            a.lines = accessLinesOf(*line, bounds, style, tree.text);
        }
    }

    /// Same size as the retained box.
    protected override Size performLayout(Constraints c)
    {
        return measureTextBox(c, style, tree.text);
    }

    /// Same look as the retained box.
    override void paint(ref PaintContext ctx, Point origin)
    {
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        paintTextBox(ctx, r, style, *line, placeholder, 0, hasFocus, enabled, caretOn);
        if (ui !is null)
        {
            ui.caret = caretRectOf(*line, r, style, ctx.text);
        }
    }
}

/// Island text box over `value`. A press places the caret, a drag selects, and double and triple clicks select a
/// word and everything. With focus it takes typed text, editing keys, the clipboard and input method text, and
/// leaves other keys, such as Enter, to the pass. True on the passes it changes `value`. `password` draws a dot per
/// character, keeps the text off the clipboard and asks for input methods off.
bool textBox(Ui ui, ref string value, string placeholder = null, bool enabled = true, string accessName = null,
    bool password = false, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i, enabled);
    TextBoxStyle s = ui.style!TextBoxStyle();
    LineEdit* ed = ui.memoryFor(i, LineEdit.init);
    ed.password = password;
    if (ed.text != value)
    {
        ed.setText(value);
    }
    bool has = ui.focusStop(i, enabled);
    Rect r = ui.lastRect(i);
    TextSystem t = ui.tree.text;
    bool touched;
    if (p.pressedNow)
    {
        ed.press(indexAtX(*ed, r, s, t, ui.mouse.x), ui.clicks, ui.mods);
        touched = true;
    }
    else if (p.held && ed.dragging)
    {
        size_t at = indexAtX(*ed, r, s, t, ui.mouse.x);
        touched = at != ed.caret;
        ed.caret = at;
    }
    if (p.held == false)
    {
        ed.dragging = false;
    }
    ed.composing = null;
    if (has)
    {
        ui.hiddenText = password;
        if (ui.typed.length > 0)
        {
            ed.type(ui.typed);
            ui.typed = null;
            touched = true;
        }
        KeyEvent[] left;
        foreach (KeyEvent k; ui.keys)
        {
            if (ed.key(k, ui.services))
            {
                touched = true;
            }
            else
            {
                left ~= k;
            }
        }
        ui.keys = left;
        if (ui.composing.length > 0)
        {
            ed.compose(ui.composing, ui.composeFrom, ui.composeTo);
        }
    }
    if (touched)
    {
        ed.blinkStart = ui.now;
    }
    bool changed = ed.text != value;
    value = ed.text;
    ui.again = ui.again || changed;
    bool caretOn;
    if (has)
    {
        MonoTime next;
        caretOn = caretBlink(ed.blinkStart, ui.now, next);
        ui.requestFrameAt(next);
    }
    TextBoxBox n = new TextBoxBox(s, ed, placeholder, has, enabled, caretOn);
    n.ui = has ? ui : null;
    n.accessName = accessName;
    ui.put(n);
    ui.track(n, i);
    return changed;
}

// Typing, selection and word deletion write the signal, and outside writes show up.
unittest
{
    import dentrite.signals : signal;

    Signal!string q = signal("");
    TextBox b = textBox(q);
    b.onText("main.d");
    assert(q.peek == "main.d" && b.caret == 6);
    KeyEvent k = KeyEvent(Key.left, Mod.shift);
    b.onKey(k);
    b.onKey(k);
    b.onText("x");
    assert(q.peek == "mainx" && b.caret == 5);
    KeyEvent wordBack = KeyEvent(Key.backspace, Mod.ctrl);
    b.onKey(wordBack);
    assert(q.peek == "" && b.caret == 0);
    q.set("parser.d");
    assert(b.text == "parser.d" && b.caret == 0);
    KeyEvent end = KeyEvent(Key.end, 0);
    b.onKey(end);
    KeyEvent left = KeyEvent(Key.left, Mod.ctrl);
    b.onKey(left);
    assert(b.caret == 7, "start of the word d");
    b.onText("é");
    KeyEvent bs = KeyEvent(Key.backspace, 0);
    b.onKey(bs);
    assert(q.peek == "parser.d", "a two-byte character removed whole");
    b.setEnabled(false);
    assert(b.onText("x") == false && b.onKey(bs) == false && q.peek == "parser.d" && b.focusable == false);
}

// A password shows a dot per character, moves by character only, keeps the clipboard and input methods out, and
// maps carets between the text and its dots.
unittest
{
    import dentrite.signals : signal;

    Signal!string q = signal("");
    TextBox b = textBox(q, password: true);
    b.onText("hé!");
    assert(q.peek == "hé!" && b.line.shown == "•••");
    assert(b.line.toShown(3) == 6 && b.line.fromShown(6) == 3 && b.line.fromShown(9) == 4);
    AccessInfo a;
    b.describe(a);
    assert(a.role == Role.passwordInput && a.value == "•••" && a.caret == 9);
    KeyEvent left = KeyEvent(Key.left, Mod.ctrl);
    b.onKey(left);
    assert(b.caret == 0, "the whole password is one word");
    KeyEvent all = KeyEvent(Key.a, Mod.ctrl);
    b.onKey(all);
    KeyEvent cut = KeyEvent(Key.x, Mod.ctrl);
    b.onKey(cut);
    assert(q.peek == "hé!", "cutting does nothing");
    b.compose("か", 0, 3);
    assert(b.line.composing.length == 0);
}

// Focus on a password box, retained or in an island, asks the platform for hidden text input, and focus on a plain
// box asks for plain text input again.
unittest
{
    import dentrite.containers : column, expanded;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.island : Island, island;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    HeadlessPlatform p = cast(HeadlessPlatform) h.platform;
    TextBox plain = textBox(signal(""));
    TextBox secret = textBox(signal(""), password: true);
    string name, pass;
    Island isl = island((Ui ui) {
        ui.textBox(name);
        ui.textBox(pass, password: true);
    });
    h.setRoot(column()(plain, secret, expanded(isl)));
    h.frame();
    h.setFocus(secret);
    assert(p.textOn && p.textHidden);
    h.setFocus(plain);
    assert(p.textOn && p.textHidden == false);
    h.setFocus(isl);
    isl.enterFocus(false);
    h.frame();
    assert(p.textOn && p.textHidden == false, "the island's first box is plain");
    h.injectKey(Key.tab);
    h.frame();
    assert(p.textOn && p.textHidden, "its second is a password");
}

// Input method text shows in place of the selection without editing, keys wait until it is committed, the
// caret reaches the platform, and moving focus drops the composition.
unittest
{
    import dentrite.containers : column;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    HeadlessPlatform p = cast(HeadlessPlatform) h.platform;
    Signal!string q = signal("fort");
    Signal!string other = signal("");
    TextBox b = textBox(q);
    TextBox c = textBox(other);
    h.setRoot(column()(b, c));
    h.frame();
    h.setFocus(b);
    b.anchor = b.caret = 1;
    h.frame();
    float before = b.caretRect.x;
    b.caret = 3;
    h.injectCompose("^");
    h.frame();
    assert(q.peek == "fort" && b.line.composing == "^" && b.line.composeTo == 1);
    assert(b.caretRect.x > before && p.inputArea == b.caretRect, "the caret follows the accent");
    h.injectKey(Key.backspace);
    assert(q.peek == "fort", "keys go to the input method");
    h.injectCompose("");
    assert(b.line.composing is null);
    h.injectCompose("ê");
    h.injectText("ê");
    assert(q.peek == "fêt" && b.caret == 3 && b.line.composing is null, "the commit replaces the selection");
    h.injectKey(Key.backspace);
    assert(q.peek == "ft", "keys work again");

    h.injectCompose("´");
    h.setFocus(c);
    assert(b.line.composing is null && p.textOn, "focus moves on and text input restarts");
    h.injectText("x");
    assert(other.peek == "x" && q.peek == "ft");
}

// An island text box takes the press, typing, editing keys, the clipboard and input method text, leaves Enter to
// the pass, and blinks by timer without a pass every frame.
unittest
{
    import dentrite.containers : column, expanded;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.island : Island, island;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    HeadlessPlatform p = cast(HeadlessPlatform) h.platform;
    string name = "fort";
    string other;
    int changes;
    int entered;
    Island isl = island((Ui ui) {
        if (ui.textBox(name, "Name"))
        {
            ++changes;
        }
        if (ui.takeKey(Key.enter))
        {
            ++entered;
        }
        ui.textBox(other);
    });
    h.setRoot(column()(expanded(isl)));
    h.frame();
    h.setFocus(isl);
    isl.enterFocus(false);
    h.frame();
    Rect box = isl.focusRect;
    Point end = Point(box.x + box.w - 4, box.y + box.h / 2);
    h.inject(PointerKind.move, end);
    h.inject(PointerKind.down, end);
    h.inject(PointerKind.up, end);
    h.frame();
    /// Sends key `k` with `mods` and runs a frame.
    void key(uint k, ubyte mods = 0)
    {
        h.injectKey(k, mods);
        h.frame();
    }

    h.injectText("s");
    h.frame();
    assert(name == "forts" && changes == 1, "the press put the caret at the end");
    key(Key.home);
    key(Key.end, Mod.shift);
    key(Key.c, Mod.ctrl);
    assert(p.clip == "forts");
    key(Key.end);
    key(Key.v, Mod.ctrl);
    key(Key.backspace);
    assert(name == "fortsfort" && changes == 3);
    key(Key.enter);
    assert(entered == 1 && name == "fortsfort", "Enter is left to the pass");

    float before = isl.caretRect.x;
    h.injectCompose("^");
    h.frame();
    assert(name == "fortsfort" && isl.caretRect.x > before && p.inputArea == isl.caretRect,
        "the accent shows at the caret, which reaches the platform");
    h.injectCompose("");
    h.injectCompose("ê");
    h.injectText("ê");
    h.frame();
    assert(name == "fortsfortê" && isl.caretRect.x > before);

    assert(isl.ui.wakeAt != MonoTime.max, "the caret blink asks for a pass later");
    int passes = isl.passes;
    h.frame();
    h.frame();
    assert(isl.passes == passes, "and not every frame");
    key(Key.tab);
    h.injectText("x");
    h.frame();
    assert(other == "x" && name == "fortsfortê");
}

// Keys and text in one frame reach an island text box in the order they came, more of them than a frame's
// passes included.
unittest
{
    import dentrite.containers : column, expanded;
    import dentrite.host : Host;
    import dentrite.island : Island, island;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    string name;
    Island isl = island((Ui ui) { ui.textBox(name); });
    h.setRoot(column()(expanded(isl)));
    h.frame();
    h.setFocus(isl);
    isl.enterFocus(false);
    h.frame();
    h.injectText("a");
    h.injectKey(Key.backspace, 0);
    h.injectText("b");
    h.frame();
    assert(name == "b", "Backspace took the a before the b came");

    h.injectText("xy");
    h.injectKey(Key.left, 0);
    h.injectText("1");
    h.injectKey(Key.left, 0);
    h.injectText("2");
    h.injectKey(Key.end, 0);
    h.injectText("3");
    h.injectKey(Key.home, 0);
    h.injectText("4");
    h.injectKey(Key.end, 0);
    h.injectText("5");
    h.frame();
    assert(name.length < 11, "more than a frame's passes hold");
    h.frame();
    h.frame();
    assert(name == "4bx21y35");
}

// A double click selects the word holding the character under it, even at the word's first character, and
// between words the run of other characters.
unittest
{
    LineEdit e;
    e.setText("std.algorithm : filter");
    e.press(16, 2, 0);
    assert(e.anchor == 16 && e.caret == 22, "filter");
    e.press(22, 2, 0);
    assert(e.anchor == 16 && e.caret == 22, "just after it");
    e.press(14, 2, 0);
    assert(e.anchor == 13 && e.caret == 16, "the spaces and colon");
}
