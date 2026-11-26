/// Touch selection handles: a knob under each end of a text selection, dragged to move that end.
///
/// A text field shows them after a long press or a double tap selects a word. They live in popups so they can hang
/// below the field. The field reports where the ends are as it paints, and the popups follow after the next
/// layout, so they may lag a frame behind the text.
module dentrite.widgets.handles;

import dentrite.containers : CrossAlign;
import dentrite.node;
import dentrite.overlay : Popup, Side;

/// Look of the handles.
struct HandleStyle
{
    enum section = "handle"; /// section name in theme files

    Color fill = Color(0x4c, 0x8d, 0xf6, 0xff); /// knob and stem color
    float radius = 9; /// knob radius
    float stem = 4;   /// stem height between the text and the knob
}

/// Text field whose selection ends the handles move.
interface HandleTarget
{
    /// Moves the anchor end, or the caret end when `caretEnd`, to the text nearest window point `p`.
    void dragHandle(bool caretEnd, Point p);
}

/// Pair of handles for one field: the anchor end first, then the caret end.
final class SelectionHandles : Updatable
{
    private Node field;          /// field the handles belong to
    private Tree tree;           /// tree they show in, null while hidden
    private HandleTarget target; /// gets the drags
    private Popup[2] popups;     /// one per end
    private Knob[2] knobs;       /// their content
    private Rect[2] want;        /// caret boxes of the ends as last painted, window coordinates
    private bool[2] wanted;      /// each end is in view as last painted
    private bool[2] placed;      /// each popup shows
    private Rect[2] at;          /// caret box each popup was last placed under
    private bool active;         /// shown or about to be

    /// Handles for `field`, which `target` moves, usually the same node.
    this(Node field, HandleTarget target)
    {
        this.field = field;
        this.target = target;
        foreach (size_t i; 0 .. 2)
        {
            knobs[i] = new Knob(this, i == 1);
            Popup p = new Popup(knobs[i]);
            p.anchor = field;
            p.side = Side.below;
            p.dismiss = false;
            p.focus = false;
            popups[i] = p;
        }
    }

    /// True while shown or about to show at the next layout.
    bool shown() const
    {
        return active;
    }

    /// Shows the handles from the next layout on, where `place` puts them.
    void show()
    {
        if (active || field.tree is null)
        {
            return;
        }
        active = true;
        tree = field.tree;
        tree.addUpdater(this);
        tree.requestPaint();
    }

    /// Hides the handles.
    void hide()
    {
        if (active == false)
        {
            return;
        }
        active = false;
        wanted = [false, false];
        tree.removeUpdater(this);
        tree = null;
        foreach (size_t i; 0 .. 2)
        {
            popups[i].close();
            placed[i] = false;
        }
    }

    /// Puts the handles under caret boxes `anchor` and `caret`, in window coordinates, each only when its `in`
    /// flag says it is in view. Called while the field paints, so the popups move at the next layout.
    void place(Rect anchor, bool anchorIn, Rect caret, bool caretIn)
    {
        if (active == false)
        {
            return;
        }
        want = [anchor, caret];
        wanted = [anchorIn, caretIn];
        foreach (size_t i; 0 .. 2)
        {
            if (wanted[i] != placed[i] || (wanted[i] && want[i] != at[i]))
            {
                tree.requestPaint();
                return;
            }
        }
    }

    /// Opens, moves and closes the popups to match the last `place`. The knob of the end that comes first in the
    /// text hangs to the left, the other to the right.
    void update()
    {
        if (active == false)
        {
            return;
        }
        bool anchorFirst = want[0].y < want[1].y || (want[0].y == want[1].y && want[0].x <= want[1].x);
        foreach (size_t i; 0 .. 2)
        {
            bool left = (i == 0) == anchorFirst;
            if (knobs[i].left != left || popups[i].isOpen == false)
            {
                knobs[i].left = left;
                knobs[i].markNeedsPaint();
                popups[i].align_ = left ? CrossAlign.end : CrossAlign.start;
                popups[i].markNeedsLayout();
            }
            Rect r = Rect(want[i].x, want[i].bottom, 0, 0);
            if (wanted[i] == false)
            {
                popups[i].close();
            }
            else if (popups[i].isOpen == false)
            {
                popups[i].openAt(tree, r);
            }
            else
            {
                popups[i].moveTo(r);
            }
            placed[i] = wanted[i];
            at[i] = want[i];
        }
    }

    /// Nothing cached.
    void invalidate()
    {
    }

    /// Drag of the handle for the caret end, or the anchor end, aiming at window point `p` on the text.
    private void drag(bool caretEnd, Point p)
    {
        target.dragHandle(caretEnd, p);
    }

    /// Caret box of an end as last placed.
    private Rect end(bool caretEnd) const
    {
        return at[caretEnd ? 1 : 0];
    }
}

/// Knob of one handle: a stem up to the text and a teardrop hanging to one side. A drag moves its end, aiming at
/// the middle of the line as it was grabbed.
private final class Knob : Node
{
    private SelectionHandles owner; /// pair it belongs to
    private bool caretEnd;          /// moves the caret end, else the anchor end
    private bool left;              /// hangs left of the stem, which is then at its right edge
    private Point grab;             /// pointer minus the aim point at the press

    /// Knob of `owner` for the caret end when `caretEnd`.
    this(SelectionHandles owner, bool caretEnd)
    {
        this.owner = owner;
        this.caretEnd = caretEnd;
        interactive = true;
        keepFocus = true;
        drags = DragAxes.both;
    }

    /// A disc under a stem, both from the style.
    protected override Size performLayout(Constraints c)
    {
        HandleStyle s = tree.style!HandleStyle();
        return c.constrain(Size(s.radius * 2, s.stem + s.radius * 2));
    }

    /// Stem at the edge toward the text, then a disc with its corner on that side squared.
    override void paint(ref PaintContext ctx, Point origin)
    {
        HandleStyle s = ctx.style!HandleStyle();
        float stemX = left ? origin.x + s.radius * 2 - 2 : origin.x;
        float cornerX = left ? origin.x + s.radius : origin.x;
        ctx.list.rect(Rect(stemX, origin.y, 2, s.stem), s.fill);
        ctx.list.rect(Rect(cornerX, origin.y + s.stem, s.radius, s.radius), s.fill);
        ctx.list.rect(Rect(origin.x, origin.y + s.stem, s.radius * 2, s.radius * 2), s.fill, s.radius);
    }

    /// Press notes where the aim point is, moves drag the end.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            Rect r = owner.end(caretEnd);
            grab = Point(e.pos.x - r.x, e.pos.y - (r.y + r.h / 2));
            return true;
        case PointerKind.move:
            if (pressed)
            {
                owner.drag(caretEnd, Point(e.pos.x - grab.x, e.pos.y - grab.y));
            }
            return pressed;
        case PointerKind.up:
        case PointerKind.cancel:
            return true;
        default:
            return false;
        }
    }
}

// A touch press held on a text box selects the word under it and shows a handle under each end. Dragging a
// handle moves its end, and a tap hides them. The mouse shows none, a double tap does, and so does a text area.
unittest
{
    import core.time : MonoTime, msecs;
    import dentrite.containers : column, sized;
    import dentrite.host : Host;
    import dentrite.overlay : Stage;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;
    import dentrite.widgets.textarea : TextArea, TextPos, textArea;
    import dentrite.widgets.textbox : TextBox, textBox;

    Host h = menuHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    TextBox box = textBox(signal("hello world"));
    TextArea area = textArea(signal("one two\nthree"));
    h.setRoot(column()(sized(w: 200, h: 100)(area), sized(w: 200)(box)));
    h.frame();
    Stage stage = cast(Stage) h.tree.root;
    MonoTime t = MonoTime.currTime - 5000.msecs;

    /// Sends pointer event `k` at `at`, `ms` after `t`, from `from`.
    void touch(PointerKind k, Point at, int ms, ubyte clicks = 1, PointerSource from = PointerSource.touch)
    {
        h.inject(k, at, clicks, 1, 0, from, t + ms.msecs);
    }

    Point word = Point(box.bounds.right - 40, box.bounds.y + box.bounds.h / 2);
    touch(PointerKind.down, word, 0);
    h.frame();
    h.frame();
    assert(box.focused && box.line.anchor == 6 && box.line.caret == 11, "the word under the press");
    assert(box.handlesShown && stage.popups.length == 2);
    touch(PointerKind.up, word, 600);
    h.frame();
    assert(box.line.anchor == 6 && box.line.caret == 11, "the release leaves the selection");

    Rect knob = stage.popups[0].bounds;
    assert(knob.y >= box.bounds.y + box.bounds.h / 2 && knob.y < box.bounds.bottom, "under the line");
    Point grab = Point(knob.x + knob.w / 2, knob.y + knob.h / 2);
    touch(PointerKind.down, grab, 1000);
    touch(PointerKind.move, Point(box.bounds.x - 50, grab.y), 1010);
    touch(PointerKind.up, Point(box.bounds.x - 50, grab.y), 1020);
    h.frame();
    h.frame();
    assert(box.line.anchor == 0 && box.line.caret == 11 && box.focused, "the anchor handle moved to the start");
    assert(stage.popups[0].bounds.x < knob.x, "and its knob followed");

    touch(PointerKind.down, word, 2000);
    touch(PointerKind.up, word, 2010);
    h.frame();
    assert(box.handlesShown == false && stage.popups.length == 0, "a tap hides them");
    touch(PointerKind.down, word, 2100, 2, PointerSource.mouse);
    touch(PointerKind.up, word, 2110, 2, PointerSource.mouse);
    h.frame();
    assert(box.line.caret != box.line.anchor && box.handlesShown == false, "a mouse double click shows none");
    touch(PointerKind.down, word, 2200, 2);
    touch(PointerKind.up, word, 2210, 2);
    h.frame();
    h.frame();
    assert(box.handlesShown && stage.popups.length == 2, "a double tap shows them");

    Point two = Point(area.bounds.x + 40, area.bounds.y + 12);
    touch(PointerKind.down, two, 3000);
    h.frame();
    h.frame();
    assert(area.focused && box.handlesShown == false, "focus left the box");
    assert(area.anchor == TextPos(0, 4) && area.caret == TextPos(0, 7) && area.handlesShown);
    touch(PointerKind.up, two, 3600);
    h.frame();
    assert(stage.popups.length == 2);
}
