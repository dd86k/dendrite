/// AccessKit adapter for an SDL window: sends the access tree to screen readers and brings their actions back as
/// events.
///
/// On Linux the AccessKit handlers run on a thread of their own. Activation only flags that the next update must
/// hold the whole tree and wakes the UI loop, and actions travel as SDL user events, so no dentrite state is
/// touched there. Windows and macOS call the handlers on the UI thread and take the same path.
/// NOTE: only the Linux adapter has been run. The Windows and macOS calls follow accesskit-c's SDL example.
module dentrite.accesskit;

import core.atomic : atomicLoad, atomicStore, cas;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : strdup;
import dentrite.access;
import dentrite.geom : Rect;
import dentrite.c.accesskit;
import dentrite.c.sdl;
import dentrite.platform : wakeUi;
import std.math : isNaN;
import std.string : fromStringz, indexOf;
import std.utf : stride;

/// Action request copied out of AccessKit on its thread, without the GC.
private struct Pending
{
    ulong target;        /// node id
    AccessAction action; /// what to do
    double number;       /// `setValue` number, NaN for none
    char* text;          /// `setValue` text from strdup, or null
    accesskit_text_selection selection; /// `setSelection` ends as text run positions
}

/// Text run of a field, to turn run positions back into byte offsets.
private struct Spot
{
    ulong field; /// id of the field
    size_t from; /// first byte in the field's value
    string text; /// the run's text
}

/// AccessKit adapter on one SDL window.
final class AccessKitAdapter : AccessAdapter
{
    private shared bool active;   /// an assistive technology listens
    private shared bool wantFull; /// the next update must hold every node
    private uint actionEvent;     /// SDL user event type carrying a `Pending`
    private const(AccessUpdate)* pending; /// update the factory builds, set during `update`
    private float pendingScale;   /// scale for `pending`
    private Spot[ulong] spots;    /// text runs sent, by id

    version (linux)
    {
        private accesskit_unix_adapter* adapter; /// platform adapter
    }
    else version (Windows)
    {
        private accesskit_windows_subclassing_adapter* adapter; /// platform adapter
    }
    else version (OSX)
    {
        private accesskit_macos_subclassing_adapter* adapter; /// platform adapter
    }

    /// Adapter on `win`, or null when the library is missing or the system has none. `path` overrides the
    /// library file. Actions come back as SDL events of type `actionEvent`, see `request`.
    static AccessKitAdapter open(SDL_Window* win, uint actionEvent, const(char)* path)
    {
        if (loadAccessKit(path) == false)
        {
            return null;
        }
        AccessKitAdapter a = new AccessKitAdapter;
        a.actionEvent = actionEvent;
        void* self = cast(void*) a;
        version (linux)
        {
            a.adapter = accesskit_unix_adapter_new(&activated, self, &asked, self, &deactivated, self);
        }
        else version (Windows)
        {
            void* hwnd = SDL_GetPointerProperty(SDL_GetWindowProperties(win), "SDL.window.win32.hwnd", null);
            a.adapter = accesskit_windows_subclassing_adapter_new(hwnd, &activated, self, &asked, self);
        }
        else version (OSX)
        {
            accesskit_macos_add_focus_forwarder_to_window_class("SDL3Window");
            void* nsWindow = SDL_GetPointerProperty(SDL_GetWindowProperties(win), "SDL.window.cocoa.window", null);
            a.adapter = accesskit_macos_subclassing_adapter_for_window(nsWindow, &activated, self, &asked, self);
        }
        else
        {
            return null;
        }
        if (a.adapter is null)
        {
            return null;
        }
        // NOTE: the adapter holds `self` as raw userdata, out of the GC's sight.
        import core.memory : GC;

        GC.addRoot(self);
        return a;
    }

    /// Frees the platform adapter. Before the window closes.
    void close()
    {
        if (adapter is null)
        {
            return;
        }
        version (linux)
        {
            accesskit_unix_adapter_free(adapter);
        }
        else version (Windows)
        {
            accesskit_windows_subclassing_adapter_free(adapter);
        }
        else version (OSX)
        {
            accesskit_macos_subclassing_adapter_free(adapter);
        }
        adapter = null;
        import core.memory : GC;

        GC.removeRoot(cast(void*) this);
    }

    /// `AccessDemand.full` once after a screen reader asks for the tree, then `AccessDemand.changes` until it
    /// stops listening.
    AccessDemand demand()
    {
        if (atomicLoad(active) == false)
        {
            return AccessDemand.none;
        }
        return cas(&wantFull, true, false) ? AccessDemand.full : AccessDemand.changes;
    }

    /// Sends `u` through the platform adapter, if still active.
    void update(ref const AccessUpdate u, float scale)
    {
        pending = &u;
        pendingScale = scale;
        scope (exit)
        {
            pending = null;
        }
        void* self = cast(void*) this;
        version (linux)
        {
            accesskit_unix_adapter_update_if_active(adapter, &build, self);
        }
        else version (Windows)
        {
            raise(accesskit_windows_subclassing_adapter_update_if_active(adapter, &build, self));
        }
        else version (OSX)
        {
            raise(accesskit_macos_subclassing_adapter_update_if_active(adapter, &build, self));
        }
    }

    /// Tells the adapter whether the window has keyboard focus.
    void windowFocus(bool on)
    {
        version (linux)
        {
            accesskit_unix_adapter_update_window_focus_state(adapter, on);
        }
        else version (OSX)
        {
            raise(accesskit_macos_subclassing_adapter_update_view_focus_state(adapter, on));
        }
    }

    /// Tells the adapter where `win` is on screen, which only X11 knows.
    void windowMoved(SDL_Window* win)
    {
        version (linux)
        {
            int x, y, w, h, top, left, bottom, right;
            SDL_GetWindowPosition(win, &x, &y);
            SDL_GetWindowSize(win, &w, &h);
            SDL_GetWindowBordersSize(win, &top, &left, &bottom, &right);
            accesskit_unix_adapter_set_root_window_bounds(adapter,
                accesskit_rect(x - left, y - top, x + w + right, y + h + bottom), accesskit_rect(x, y, x + w, y + h));
        }
    }

    /// Request carried by SDL user event `s` of the action event type, freeing what the handler allocated.
    AccessRequest request(ref SDL_Event s)
    {
        Pending* p = cast(Pending*) s.user.data1;
        AccessRequest r = AccessRequest(p.target, p.action, null, p.number);
        if (p.text !is null)
        {
            r.text = fromStringz(p.text).idup;
            free(p.text);
        }
        if (p.action == AccessAction.setSelection)
        {
            r.anchor = offsetOf(p.selection.anchor, r.target);
            r.caret = offsetOf(p.selection.focus, r.target);
        }
        free(p);
        return r;
    }

    /// Byte offset in its field's value of text run position `t`, with `field` set to the field. `size_t.max` for
    /// a run not sent.
    private size_t offsetOf(accesskit_text_position t, ref ulong field)
    {
        Spot* sp = t.node in spots;
        if (sp is null)
        {
            return size_t.max;
        }
        field = sp.field;
        size_t b;
        foreach (size_t k; 0 .. t.index)
        {
            if (b >= sp.text.length)
            {
                break;
            }
            b += stride(sp.text, b);
        }
        return sp.from + b;
    }

    /// AccessKit tree update for `u`. Bounds stay logical, the window node scales them to pixels.
    private accesskit_tree_update* treeOf(ref const AccessUpdate u, float scale)
    {
        accesskit_tree_update* t = accesskit_tree_update_with_capacity_and_focus(u.nodes.length, u.focus);
        if (u.full)
        {
            accesskit_tree_info* info = accesskit_tree_info_new(u.root);
            accesskit_tree_info_set_toolkit_name(info, "dentrite");
            accesskit_tree_update_set_tree_info(t, info);
            spots = null;
        }
        foreach (ref const AccessNode n; u.nodes)
        {
            accesskit_node* k = nodeOf(n);
            if (n.id == u.root)
            {
                accesskit_node_set_transform(k, accesskit_affine([scale, 0, 0, scale, 0, 0]));
            }
            if (isText(n.info.role))
            {
                addRuns(t, k, n, spots);
            }
            accesskit_tree_update_push_node(t, n.id, k);
        }
        return t;
    }
}

/// AccessKit node for `n`.
private accesskit_node* nodeOf(ref const AccessNode n)
{
    const(AccessInfo)* a = &n.info;
    accesskit_node* k = accesskit_node_new(roleOf(a.role));
    // NOTE: screen readers read a label's text from its value, as egui sends it.
    if (a.role == Role.label)
    {
        setText(k, accesskit_node_set_value_with_length, a.label);
    }
    else
    {
        setText(k, accesskit_node_set_label_with_length, a.label);
        setText(k, accesskit_node_set_value_with_length, a.value);
    }
    setText(k, accesskit_node_set_description_with_length, a.description);
    setText(k, accesskit_node_set_placeholder_with_length, a.placeholder);
    setText(k, accesskit_node_set_keyboard_shortcut_with_length, a.shortcut);
    setText(k, accesskit_node_set_url_with_length, a.url);
    accesskit_node_set_bounds(k, accesskit_rect(n.bounds.x, n.bounds.y, n.bounds.x + n.bounds.w,
        n.bounds.y + n.bounds.h));
    if (n.children.length > 0 && isText(a.role) == false)
    {
        accesskit_node_set_children(k, n.children.length, n.children.ptr);
    }
    static immutable ubyte[AccessAction.max + 1] actions = [ACCESSKIT_ACTION_CLICK, ACCESSKIT_ACTION_FOCUS,
        ACCESSKIT_ACTION_INCREMENT, ACCESSKIT_ACTION_DECREMENT, ACCESSKIT_ACTION_SET_VALUE, ACCESSKIT_ACTION_EXPAND,
        ACCESSKIT_ACTION_COLLAPSE, ACCESSKIT_ACTION_SCROLL_INTO_VIEW, ACCESSKIT_ACTION_SHOW_CONTEXT_MENU,
        ACCESSKIT_ACTION_SET_TEXT_SELECTION];
    foreach (AccessAction act; AccessAction.min .. cast(AccessAction)(AccessAction.max + 1))
    {
        if (a.allows(act))
        {
            accesskit_node_add_action(k, actions[act]);
        }
    }
    if (a.role != Role.window)
    {
        accesskit_node_add_action(k, ACCESSKIT_ACTION_SCROLL_INTO_VIEW);
    }
    if (n.labelledBy != 0)
    {
        accesskit_node_push_labelled_by(k, n.labelledBy);
    }
    if (a.live != Live.off)
    {
        accesskit_node_set_live(k, a.live == Live.assertive ? ACCESSKIT_LIVE_ASSERTIVE : ACCESSKIT_LIVE_POLITE);
    }
    if (a.toggled != Toggle.none)
    {
        accesskit_node_set_toggled(k, a.toggled == Toggle.on ? ACCESSKIT_TOGGLED_TRUE
            : a.toggled == Toggle.mixed ? ACCESSKIT_TOGGLED_MIXED : ACCESSKIT_TOGGLED_FALSE);
    }
    if (a.selected != Tri.unset)
    {
        accesskit_node_set_selected(k, a.selected == Tri.yes);
    }
    if (a.expanded != Tri.unset)
    {
        accesskit_node_set_expanded(k, a.expanded == Tri.yes);
    }
    if (a.disabled)
    {
        accesskit_node_set_disabled(k);
    }
    if (a.readOnly)
    {
        accesskit_node_set_read_only(k);
    }
    if (a.modal)
    {
        accesskit_node_set_modal(k);
    }
    if (a.multiselectable)
    {
        accesskit_node_set_multiselectable(k);
    }
    setNumber(k, accesskit_node_set_numeric_value, a.number);
    setNumber(k, accesskit_node_set_min_numeric_value, a.min);
    setNumber(k, accesskit_node_set_max_numeric_value, a.max);
    setNumber(k, accesskit_node_set_numeric_value_step, a.step);
    if (a.level > 0)
    {
        accesskit_node_set_level(k, a.level);
    }
    if (a.position > 0)
    {
        accesskit_node_set_position_in_set(k, a.position);
    }
    if (a.setSize > 0)
    {
        accesskit_node_set_size_of_set(k, a.setSize);
    }
    if (a.rowIndex > 0)
    {
        accesskit_node_set_row_index(k, a.rowIndex - 1);
    }
    if (a.columnIndex > 0)
    {
        accesskit_node_set_column_index(k, a.columnIndex - 1);
    }
    if (a.rowCount > 0)
    {
        accesskit_node_set_row_count(k, a.rowCount);
    }
    if (a.columnCount > 0)
    {
        accesskit_node_set_column_count(k, a.columnCount);
    }
    return k;
}

/// True for the roles whose text AccessKit reads from text runs.
private bool isText(Role r)
{
    return r == Role.textInput || r == Role.passwordInput || r == Role.multilineTextInput;
}

/// Part of a field's text in one text run: a line, or 255 characters of it, with the newline that ends it.
private struct Run
{
    size_t from;   /// first byte in the text
    size_t to;     /// byte after the last
    ulong id;      /// node id
    Rect rect;     /// bounds in window coordinates
    float[] edges; /// left edge of each character from `rect.x`, then the right end, empty when unknown
}

/// Lines of field `n`: as laid out, else one per line of its value over its bounds.
private const(AccessLine)[] linesOf(ref const AccessNode n)
{
    if (n.info.lines.length > 0)
    {
        return n.info.lines;
    }
    string s = n.info.value;
    AccessLine[] lines;
    size_t start;
    while (true)
    {
        ptrdiff_t nl = s.indexOf('\n', start);
        size_t end = nl < 0 ? s.length : nl + 1;
        lines ~= AccessLine(start, end, n.bounds);
        if (nl < 0)
        {
            return lines;
        }
        start = end;
    }
}

/// Runs of field `n`. An empty line still has one, for the caret.
private Run[] runsOf(ref const AccessNode n)
{
    string s = n.info.value;
    Run[] runs;
    foreach (size_t line, ref const AccessLine l; linesOf(n))
    {
        size_t chunk;
        size_t p = l.from;
        size_t c; // characters of the line before `p`
        do
        {
            size_t q = p;
            size_t c0 = c;
            for (size_t chars; q < l.to && chars < 255; ++chars)
            {
                q += stride(s, q);
                ++c;
            }
            // Bit 61 keeps run ids apart from the ids of nodes and parts.
            Run r = Run(p, q, (mixId(chunk, mixId(line, n.id)) | 1UL << 61) & ~(3UL << 62), l.rect);
            if (c < l.edges.length)
            {
                float x0 = l.edges[c0];
                r.rect = Rect(l.rect.x + x0, l.rect.y, l.edges[c] - x0, l.rect.h);
                foreach (float e; l.edges[c0 .. c + 1])
                {
                    r.edges ~= e - x0;
                }
            }
            runs ~= r;
            ++chunk;
            p = q;
        }
        while (p < l.to);
    }
    return runs;
}

/// Run and character of byte offset `b` in `s`, cut into `runs`.
private accesskit_text_position positionOf(const Run[] runs, string s, size_t b)
{
    foreach (ref const Run r; runs)
    {
        if (b < r.to || &r is &runs[$ - 1])
        {
            size_t chars;
            for (size_t p = r.from; p < b && p < r.to; p += stride(s, p))
            {
                ++chars;
            }
            return accesskit_text_position(r.id, chars);
        }
    }
    return accesskit_text_position(0, 0);
}

/// Adds the text runs of field `n` to `t` as the children of `k`, with where each character is when known, and
/// its caret and selection. Notes each run in `spots`.
private void addRuns(accesskit_tree_update* t, accesskit_node* k, ref const AccessNode n, ref Spot[ulong] spots)
{
    string s = n.info.value;
    Run[] runs = runsOf(n);
    ulong[] ids;
    foreach (ref Run r; runs)
    {
        ids ~= r.id;
        spots[r.id] = Spot(n.id, r.from, s[r.from .. r.to]);
        accesskit_node* run = accesskit_node_new(ACCESSKIT_ROLE_TEXT_RUN);
        ubyte[] lengths;
        for (size_t p = r.from; p < r.to; p += stride(s, p))
        {
            lengths ~= cast(ubyte) stride(s, p);
        }
        // NOTE: AccessKit panics on a run without a value or lengths, so an empty one gets empty ones at a valid
        // address.
        static immutable char[1] blank;
        accesskit_node_set_value_with_length(run, r.to > r.from ? s.ptr + r.from : blank.ptr, r.to - r.from);
        accesskit_node_set_character_lengths(run, lengths.length,
            lengths.length > 0 ? lengths.ptr : cast(const(ubyte)*) blank.ptr);
        if (lengths.length > 0 && r.edges.length == lengths.length + 1)
        {
            float[] widths = new float[lengths.length];
            foreach (size_t i, ref float w; widths)
            {
                w = r.edges[i + 1] - r.edges[i];
            }
            accesskit_node_set_character_positions(run, lengths.length, r.edges.ptr);
            accesskit_node_set_character_widths(run, widths.length, widths.ptr);
        }
        accesskit_node_set_text_direction(run, ACCESSKIT_TEXT_DIRECTION_LEFT_TO_RIGHT);
        accesskit_node_set_bounds(run, accesskit_rect(r.rect.x, r.rect.y, r.rect.right, r.rect.bottom));
        accesskit_tree_update_push_node(t, r.id, run);
    }
    accesskit_node_set_children(k, ids.length, ids.ptr);
    if (n.info.caret <= s.length)
    {
        size_t anchor = n.info.anchor <= s.length ? n.info.anchor : n.info.caret;
        accesskit_node_set_text_selection(k, accesskit_text_selection(positionOf(runs, s, anchor),
            positionOf(runs, s, n.info.caret)));
    }
}

/// Sets string property `s` of `k` with `setter`, unless empty.
private void setText(accesskit_node* k, typeof(accesskit_node_set_label_with_length) setter, string s)
{
    if (s.length > 0)
    {
        setter(k, s.ptr, s.length);
    }
}

/// Sets number `v` of `k` with `setter`, unless NaN.
private void setNumber(accesskit_node* k, typeof(accesskit_node_set_numeric_value) setter, double v)
{
    if (isNaN(v) == false)
    {
        setter(k, v);
    }
}

/// AccessKit role of `r`.
private ubyte roleOf(Role r)
{
    final switch (r)
    {
    case Role.none:
        return ACCESSKIT_ROLE_UNKNOWN;
    case Role.window:
        return ACCESSKIT_ROLE_WINDOW;
    case Role.group:
        return ACCESSKIT_ROLE_GROUP;
    case Role.pane:
        return ACCESSKIT_ROLE_PANE;
    case Role.label:
        return ACCESSKIT_ROLE_LABEL;
    case Role.button:
        return ACCESSKIT_ROLE_BUTTON;
    case Role.link:
        return ACCESSKIT_ROLE_LINK;
    case Role.checkBox:
        return ACCESSKIT_ROLE_CHECK_BOX;
    case Role.radioButton:
        return ACCESSKIT_ROLE_RADIO_BUTTON;
    case Role.slider:
        return ACCESSKIT_ROLE_SLIDER;
    case Role.progressIndicator:
        return ACCESSKIT_ROLE_PROGRESS_INDICATOR;
    case Role.textInput:
        return ACCESSKIT_ROLE_TEXT_INPUT;
    case Role.passwordInput:
        return ACCESSKIT_ROLE_PASSWORD_INPUT;
    case Role.multilineTextInput:
        return ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT;
    case Role.spinButton:
        return ACCESSKIT_ROLE_SPIN_BUTTON;
    case Role.comboBox:
        return ACCESSKIT_ROLE_COMBO_BOX;
    case Role.listBox:
        return ACCESSKIT_ROLE_LIST_BOX;
    case Role.listBoxOption:
        return ACCESSKIT_ROLE_LIST_BOX_OPTION;
    case Role.tree:
        return ACCESSKIT_ROLE_TREE;
    case Role.treeItem:
        return ACCESSKIT_ROLE_TREE_ITEM;
    case Role.table:
        return ACCESSKIT_ROLE_TABLE;
    case Role.row:
        return ACCESSKIT_ROLE_ROW;
    case Role.cell:
        return ACCESSKIT_ROLE_CELL;
    case Role.columnHeader:
        return ACCESSKIT_ROLE_COLUMN_HEADER;
    case Role.tabList:
        return ACCESSKIT_ROLE_TAB_LIST;
    case Role.tab:
        return ACCESSKIT_ROLE_TAB;
    case Role.tabPanel:
        return ACCESSKIT_ROLE_TAB_PANEL;
    case Role.menu:
        return ACCESSKIT_ROLE_MENU;
    case Role.menuBar:
        return ACCESSKIT_ROLE_MENU_BAR;
    case Role.menuItem:
        return ACCESSKIT_ROLE_MENU_ITEM;
    case Role.menuItemCheckBox:
        return ACCESSKIT_ROLE_MENU_ITEM_CHECK_BOX;
    case Role.dialog:
        return ACCESSKIT_ROLE_DIALOG;
    case Role.tooltip:
        return ACCESSKIT_ROLE_TOOLTIP;
    case Role.scrollView:
        return ACCESSKIT_ROLE_SCROLL_VIEW;
    case Role.separator:
        return ACCESSKIT_ROLE_SPLITTER;
    case Role.image:
        return ACCESSKIT_ROLE_IMAGE;
    }
}

version (Windows)
{
    /// Raises and frees `events` if any.
    private void raise(accesskit_queued_events* events)
    {
        if (events !is null)
        {
            accesskit_windows_queued_events_raise(events);
        }
    }
}
else version (OSX)
{
    /// Raises and frees `events` if any.
    private void raise(accesskit_queued_events* events)
    {
        if (events !is null)
        {
            accesskit_macos_queued_events_raise(events);
        }
    }
}

extern (C) nothrow:

/// Builds the pending update, called by the platform adapter inside `update`.
private accesskit_tree_update* build(void* userdata)
{
    AccessKitAdapter a = cast(AccessKitAdapter) userdata;
    try
    {
        return a.treeOf(*a.pending, a.pendingScale);
    }
    catch (Exception e)
    {
        return accesskit_tree_update_with_capacity_and_focus(0, accessRootId);
    }
}

/// An assistive technology asked for the tree: flags a full update and wakes the loop, which sends it.
private accesskit_tree_update* activated(void* userdata)
{
    AccessKitAdapter a = cast(AccessKitAdapter) userdata;
    atomicStore(a.wantFull, true);
    atomicStore(a.active, true);
    wakeUi();
    return null;
}

/// The assistive technology left.
private void deactivated(void* userdata)
{
    AccessKitAdapter a = cast(AccessKitAdapter) userdata;
    atomicStore(a.active, false);
}

/// Copies an action request into an SDL user event for the UI thread. Requests dentrite has no action for are
/// dropped.
private void asked(accesskit_action_request* r, void* userdata)
{
    AccessKitAdapter a = cast(AccessKitAdapter) userdata;
    scope (exit)
    {
        accesskit_action_request_free(r);
    }
    AccessAction act;
    switch (r.action)
    {
    case ACCESSKIT_ACTION_CLICK:
        act = AccessAction.click;
        break;
    case ACCESSKIT_ACTION_FOCUS:
        act = AccessAction.focus;
        break;
    case ACCESSKIT_ACTION_INCREMENT:
        act = AccessAction.increment;
        break;
    case ACCESSKIT_ACTION_DECREMENT:
        act = AccessAction.decrement;
        break;
    case ACCESSKIT_ACTION_SET_VALUE:
        act = AccessAction.setValue;
        break;
    case ACCESSKIT_ACTION_EXPAND:
        act = AccessAction.expand;
        break;
    case ACCESSKIT_ACTION_COLLAPSE:
        act = AccessAction.collapse;
        break;
    case ACCESSKIT_ACTION_SCROLL_INTO_VIEW:
        act = AccessAction.scrollIntoView;
        break;
    case ACCESSKIT_ACTION_SHOW_CONTEXT_MENU:
        act = AccessAction.showContextMenu;
        break;
    case ACCESSKIT_ACTION_SET_TEXT_SELECTION:
        if (r.data.has_value == false || r.data.value.tag != ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION)
        {
            return;
        }
        act = AccessAction.setSelection;
        break;
    default:
        return;
    }
    Pending* p = cast(Pending*) malloc(Pending.sizeof);
    if (p is null)
    {
        return;
    }
    *p = Pending(r.target_node, act, double.nan, null);
    if (r.data.has_value && r.data.value.tag == ACCESSKIT_ACTION_DATA_VALUE && r.data.value.value !is null)
    {
        p.text = strdup(r.data.value.value);
    }
    else if (r.data.has_value && r.data.value.tag == ACCESSKIT_ACTION_DATA_NUMERIC_VALUE)
    {
        p.number = r.data.value.numericValue;
    }
    else if (act == AccessAction.setSelection)
    {
        p.selection = accesskit_text_selection(r.data.value.selection[0], r.data.value.selection[1]);
    }
    SDL_Event e;
    e.type = a.actionEvent;
    e.user.data1 = p;
    SDL_PushEvent(&e);
}
