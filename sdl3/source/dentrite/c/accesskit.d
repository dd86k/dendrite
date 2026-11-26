/// accesskit-c subset, loaded at run time so the library stays optional. Checked against the accesskit.h of
/// accesskit-c 0.23.2, struct layouts with ImportC.
module dentrite.c.accesskit;

import dentrite.c.sdl : SDL_LoadFunction, SDL_LoadObject, SDL_SharedObject;
import std.traits : FunctionAttribute, SetFunctionAttributes, functionAttributes;

/// Builds a tree update when the adapter is active, on the calling thread.
alias accesskit_tree_update_factory = extern (C) accesskit_tree_update* function(void* userdata) nothrow;
/// First request for the tree, any thread. Null means the app sends it later through `update_if_active`.
alias accesskit_activation_handler_callback = extern (C) accesskit_tree_update* function(void* userdata) nothrow;
/// Action request, any thread on Unix. Owns `request`.
alias accesskit_action_handler_callback = extern (C) void function(accesskit_action_request* request,
    void* userdata) nothrow;
/// The assistive technology left, any thread.
alias accesskit_deactivation_handler_callback = extern (C) void function(void* userdata) nothrow;

extern (C) nothrow @nogc:

/// Opaque node under construction.
struct accesskit_node;
/// Opaque tree update.
struct accesskit_tree_update;
/// Opaque tree description.
struct accesskit_tree_info;
/// Opaque Unix adapter.
struct accesskit_unix_adapter;
/// Opaque Windows adapter.
struct accesskit_windows_subclassing_adapter;
/// Opaque macOS adapter.
struct accesskit_macos_subclassing_adapter;
/// Opaque events that Windows and macOS adapters raise after an update.
struct accesskit_queued_events;

/// Node id.
alias accesskit_node_id = ulong;

/// Rectangle by its edges.
struct accesskit_rect
{
    double x0; /// left
    double y0; /// top
    double x1; /// right
    double y1; /// bottom
}

/// 2D affine transform, column major as kurbo's.
struct accesskit_affine
{
    double[6] m; /// scale x, shear y, shear x, scale y, translate x, translate y
}

/// Point.
struct accesskit_point
{
    double x; /// x
    double y; /// y
}

/// Text position.
struct accesskit_text_position
{
    accesskit_node_id node; /// text run
    size_t index;           /// character index
}

/// Text selection by run positions.
struct accesskit_text_selection
{
    accesskit_text_position anchor; /// fixed end
    accesskit_text_position focus;  /// moving end, the caret
}

/// Payload of an action request. `tag` says which member is set.
struct accesskit_action_data
{
    int tag; /// `ACCESSKIT_ACTION_DATA_*`
    union
    {
        int customAction;      /// custom action id
        char* value;           /// `setValue` text
        double numericValue;   /// `setValue` number
        ubyte scrollUnit;      /// scroll unit
        accesskit_point point; /// scroll target
        accesskit_text_position[2] selection; /// text selection
    }
}

/// Optional `accesskit_action_data`.
struct accesskit_opt_action_data
{
    bool has_value;              /// `value` is set
    accesskit_action_data value; /// payload
}

/// What an assistive technology asks for, freed with `accesskit_action_request_free`.
struct accesskit_action_request
{
    ubyte action;                   /// `ACCESSKIT_ACTION_*`
    ubyte[16] target_tree;          /// tree id, unused with one tree
    accesskit_node_id target_node;  /// node
    accesskit_opt_action_data data; /// payload
}

version (D_LP64)
{
    static assert(accesskit_action_request.sizeof == 80 && accesskit_action_request.target_node.offsetof == 24
        && accesskit_action_request.data.offsetof == 32 && accesskit_action_data.sizeof == 40);
}
else version (X86) version (linux)
{
    // i386 aligns 64-bit fields to 4.
    static assert(accesskit_action_request.sizeof == 60 && accesskit_action_request.target_node.offsetof == 20
        && accesskit_action_request.data.offsetof == 28 && accesskit_action_data.sizeof == 28);
}

enum : int
{
    ACCESSKIT_ACTION_DATA_VALUE = 1,         /// `value` is set
    ACCESSKIT_ACTION_DATA_NUMERIC_VALUE = 2, /// `numericValue` is set
    ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION = 7, /// `selection` is set
}

enum : ubyte
{
    ACCESSKIT_ACTION_CLICK = 0,              /// default action
    ACCESSKIT_ACTION_FOCUS = 1,              /// take focus
    ACCESSKIT_ACTION_COLLAPSE = 3,           /// close children
    ACCESSKIT_ACTION_EXPAND = 4,             /// open children
    ACCESSKIT_ACTION_DECREMENT = 6,          /// step down
    ACCESSKIT_ACTION_INCREMENT = 7,          /// step up
    ACCESSKIT_ACTION_SCROLL_INTO_VIEW = 15,  /// bring into view
    ACCESSKIT_ACTION_SET_TEXT_SELECTION = 18, /// move the caret or selection
    ACCESSKIT_ACTION_SET_VALUE = 20,         /// replace the value
    ACCESSKIT_ACTION_SHOW_CONTEXT_MENU = 21, /// open the context menu
}

enum : ubyte
{
    ACCESSKIT_TOGGLED_FALSE = 0, /// unchecked
    ACCESSKIT_TOGGLED_TRUE = 1,  /// checked
    ACCESSKIT_TOGGLED_MIXED = 2, /// partly checked
}

enum : ubyte
{
    ACCESSKIT_TEXT_DIRECTION_LEFT_TO_RIGHT = 0, /// text runs left to right
}

enum : ubyte
{
    ACCESSKIT_LIVE_OFF = 0,       /// changes not announced
    ACCESSKIT_LIVE_POLITE = 1,    /// announced when idle
    ACCESSKIT_LIVE_ASSERTIVE = 2, /// announced at once
}

enum : ubyte
{
    ACCESSKIT_ROLE_UNKNOWN = 0,                /// role
    ACCESSKIT_ROLE_TEXT_RUN = 1,               /// ditto
    ACCESSKIT_ROLE_CELL = 2,                   /// ditto
    ACCESSKIT_ROLE_LABEL = 3,                  /// ditto
    ACCESSKIT_ROLE_IMAGE = 4,                  /// ditto
    ACCESSKIT_ROLE_ROW = 6,                    /// ditto
    ACCESSKIT_ROLE_TREE_ITEM = 9,              /// ditto
    ACCESSKIT_ROLE_LIST_BOX_OPTION = 10,       /// ditto
    ACCESSKIT_ROLE_MENU_ITEM = 11,             /// ditto
    ACCESSKIT_ROLE_CHECK_BOX = 15,             /// ditto
    ACCESSKIT_ROLE_RADIO_BUTTON = 16,          /// ditto
    ACCESSKIT_ROLE_TEXT_INPUT = 17,            /// ditto
    ACCESSKIT_ROLE_BUTTON = 18,                /// ditto
    ACCESSKIT_ROLE_PANE = 20,                  /// ditto
    ACCESSKIT_ROLE_COLUMN_HEADER = 22,         /// ditto
    ACCESSKIT_ROLE_TABLE = 25,                 /// ditto
    ACCESSKIT_ROLE_MENU = 30,                  /// ditto
    ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT = 31,  /// ditto
    ACCESSKIT_ROLE_PASSWORD_INPUT = 40,        /// ditto
    ACCESSKIT_ROLE_COMBO_BOX = 56,             /// ditto
    ACCESSKIT_ROLE_DIALOG = 66,                /// ditto
    ACCESSKIT_ROLE_GROUP = 78,                 /// ditto
    ACCESSKIT_ROLE_LIST_BOX = 87,              /// ditto
    ACCESSKIT_ROLE_MENU_BAR = 93,              /// ditto
    ACCESSKIT_ROLE_MENU_ITEM_CHECK_BOX = 94,   /// ditto
    ACCESSKIT_ROLE_PROGRESS_INDICATOR = 101,   /// ditto
    ACCESSKIT_ROLE_SCROLL_VIEW = 108,          /// ditto
    ACCESSKIT_ROLE_SLIDER = 113,               /// ditto
    ACCESSKIT_ROLE_SPIN_BUTTON = 114,          /// ditto
    ACCESSKIT_ROLE_SPLITTER = 115,             /// ditto
    ACCESSKIT_ROLE_TAB = 120,                  /// ditto
    ACCESSKIT_ROLE_TAB_LIST = 121,             /// ditto
    ACCESSKIT_ROLE_TAB_PANEL = 122,            /// ditto
    ACCESSKIT_ROLE_TOOLTIP = 128,              /// ditto
    ACCESSKIT_ROLE_TREE = 129,                 /// ditto
    ACCESSKIT_ROLE_WINDOW = 133,               /// ditto
}

// NOTE: D linkage on purpose. C names here would interpose on the library's own symbols.
extern (D):

/// Function pointer type `F` with C linkage, as the variables below are D.
private alias C(F) = SetFunctionAttributes!(F, "C", functionAttributes!F | FunctionAttribute.nothrow_);

__gshared
{
    /// New node of `role`.
    C!(accesskit_node* function(ubyte role)) accesskit_node_new;
    /// Sets a string property, `s` need not end in zero.
    C!(void function(accesskit_node*, const(char)* s, size_t length)) accesskit_node_set_label_with_length,
        accesskit_node_set_value_with_length, accesskit_node_set_description_with_length,
        accesskit_node_set_placeholder_with_length, accesskit_node_set_keyboard_shortcut_with_length;
    /// Adds a node naming this one.
    C!(void function(accesskit_node*, accesskit_node_id)) accesskit_node_push_labelled_by;
    /// Sets the children.
    C!(void function(accesskit_node*, size_t length, const(accesskit_node_id)* ids)) accesskit_node_set_children;
    /// Adds a supported action.
    C!(void function(accesskit_node*, ubyte action)) accesskit_node_add_action;
    /// Sets the bounds, in the parent's transformed space.
    C!(void function(accesskit_node*, accesskit_rect)) accesskit_node_set_bounds;
    /// Sets the transform of the node's children.
    C!(void function(accesskit_node*, accesskit_affine)) accesskit_node_set_transform;
    /// Sets a flag.
    C!(void function(accesskit_node*)) accesskit_node_set_disabled, accesskit_node_set_read_only,
        accesskit_node_set_modal, accesskit_node_set_multiselectable;
    /// Sets a boolean state.
    C!(void function(accesskit_node*, bool)) accesskit_node_set_selected, accesskit_node_set_expanded;
    /// Sets the check state.
    C!(void function(accesskit_node*, ubyte)) accesskit_node_set_toggled, accesskit_node_set_live;
    /// Sets a number.
    C!(void function(accesskit_node*, double)) accesskit_node_set_numeric_value, accesskit_node_set_min_numeric_value,
        accesskit_node_set_max_numeric_value, accesskit_node_set_numeric_value_step;
    /// Sets the UTF-8 length of each character of a text run.
    C!(void function(accesskit_node*, size_t length, const(ubyte)* values)) accesskit_node_set_character_lengths;
    /// Sets the left edge, or the width, of each character of a text run, from the run's left edge.
    C!(void function(accesskit_node*, size_t length, const(float)* values)) accesskit_node_set_character_positions,
        accesskit_node_set_character_widths;
    /// Sets the direction of a text run.
    C!(void function(accesskit_node*, ubyte)) accesskit_node_set_text_direction;
    /// Sets the caret and selection of a text field.
    C!(void function(accesskit_node*, accesskit_text_selection)) accesskit_node_set_text_selection;
    /// Sets an index or count.
    C!(void function(accesskit_node*, size_t)) accesskit_node_set_level, accesskit_node_set_position_in_set,
        accesskit_node_set_size_of_set, accesskit_node_set_row_count, accesskit_node_set_column_count,
        accesskit_node_set_row_index, accesskit_node_set_column_index;
    /// New update with room for `capacity` nodes and `focus`.
    C!(accesskit_tree_update* function(size_t capacity, accesskit_node_id focus))
        accesskit_tree_update_with_capacity_and_focus;
    /// Adds `node`, taking it over.
    C!(void function(accesskit_tree_update*, accesskit_node_id, accesskit_node*)) accesskit_tree_update_push_node;
    /// Sets the tree description, taking it over.
    C!(void function(accesskit_tree_update*, accesskit_tree_info*)) accesskit_tree_update_set_tree_info;
    /// New tree description with root `root`.
    C!(accesskit_tree_info* function(accesskit_node_id root)) accesskit_tree_info_new;
    /// Sets the toolkit name.
    C!(void function(accesskit_tree_info*, const(char)*)) accesskit_tree_info_set_toolkit_name;
    /// Frees a request handed to the action handler.
    C!(void function(accesskit_action_request*)) accesskit_action_request_free;
}

version (linux)
{
    __gshared
    {
        /// New adapter. The handlers run on another thread.
        C!(accesskit_unix_adapter* function(accesskit_activation_handler_callback, void*,
            accesskit_action_handler_callback, void*, accesskit_deactivation_handler_callback, void*))
            accesskit_unix_adapter_new;
        /// Frees the adapter.
        C!(void function(accesskit_unix_adapter*)) accesskit_unix_adapter_free;
        /// Calls `factory` and sends its update if an assistive technology listens.
        C!(void function(accesskit_unix_adapter*, accesskit_tree_update_factory, void*))
            accesskit_unix_adapter_update_if_active;
        /// Tells whether the window has focus.
        C!(void function(accesskit_unix_adapter*, bool)) accesskit_unix_adapter_update_window_focus_state;
        /// Window bounds with and without decorations, screen coordinates. X11 only.
        C!(void function(accesskit_unix_adapter*, accesskit_rect outer, accesskit_rect inner))
            accesskit_unix_adapter_set_root_window_bounds;
    }

    /// Names of the platform functions.
    private enum string[] platformNames = ["accesskit_unix_adapter_new", "accesskit_unix_adapter_free",
        "accesskit_unix_adapter_update_if_active", "accesskit_unix_adapter_update_window_focus_state",
        "accesskit_unix_adapter_set_root_window_bounds"];
    /// Library file.
    private enum string libraryName = "libaccesskit.so";
}
else version (Windows)
{
    __gshared
    {
        /// New adapter on window `hwnd`, which it subclasses. The handlers run on the UI thread.
        C!(accesskit_windows_subclassing_adapter* function(void* hwnd, accesskit_activation_handler_callback, void*,
            accesskit_action_handler_callback, void*)) accesskit_windows_subclassing_adapter_new;
        /// Frees the adapter.
        C!(void function(accesskit_windows_subclassing_adapter*)) accesskit_windows_subclassing_adapter_free;
        /// Calls `factory` if active, returning events to raise or null.
        C!(accesskit_queued_events* function(accesskit_windows_subclassing_adapter*, accesskit_tree_update_factory,
            void*)) accesskit_windows_subclassing_adapter_update_if_active;
        /// Raises and frees queued events.
        C!(void function(accesskit_queued_events*)) accesskit_windows_queued_events_raise;
    }

    /// Names of the platform functions.
    private enum string[] platformNames = ["accesskit_windows_subclassing_adapter_new",
        "accesskit_windows_subclassing_adapter_free", "accesskit_windows_subclassing_adapter_update_if_active",
        "accesskit_windows_queued_events_raise"];
    /// Library file.
    private enum string libraryName = "accesskit.dll";
}
else version (OSX)
{
    __gshared
    {
        /// Forwards focus of windows of class `name` to the adapter. Before the adapter.
        C!(void function(const(char)* name)) accesskit_macos_add_focus_forwarder_to_window_class;
        /// New adapter on NSWindow `window`, whose view it subclasses. The handlers run on the UI thread.
        C!(accesskit_macos_subclassing_adapter* function(void* window, accesskit_activation_handler_callback, void*,
            accesskit_action_handler_callback, void*)) accesskit_macos_subclassing_adapter_for_window;
        /// Frees the adapter.
        C!(void function(accesskit_macos_subclassing_adapter*)) accesskit_macos_subclassing_adapter_free;
        /// Calls `factory` if active, returning events to raise or null.
        C!(accesskit_queued_events* function(accesskit_macos_subclassing_adapter*, accesskit_tree_update_factory,
            void*)) accesskit_macos_subclassing_adapter_update_if_active;
        /// Tells whether the view has focus, returning events to raise or null.
        C!(accesskit_queued_events* function(accesskit_macos_subclassing_adapter*, bool))
            accesskit_macos_subclassing_adapter_update_view_focus_state;
        /// Raises and frees queued events.
        C!(void function(accesskit_queued_events*)) accesskit_macos_queued_events_raise;
    }

    /// Names of the platform functions.
    private enum string[] platformNames = ["accesskit_macos_add_focus_forwarder_to_window_class",
        "accesskit_macos_subclassing_adapter_for_window", "accesskit_macos_subclassing_adapter_free",
        "accesskit_macos_subclassing_adapter_update_if_active",
        "accesskit_macos_subclassing_adapter_update_view_focus_state", "accesskit_macos_queued_events_raise"];
    /// Library file.
    private enum string libraryName = "libaccesskit.dylib";
}
else
{
    /// No adapter on other systems.
    private enum string[] platformNames = null;
    /// No library on other systems.
    private enum string libraryName = null;
}

/// Names of the functions every system needs.
private enum string[] commonNames = ["accesskit_node_new", "accesskit_node_set_label_with_length",
    "accesskit_node_set_value_with_length", "accesskit_node_set_description_with_length",
    "accesskit_node_set_placeholder_with_length", "accesskit_node_set_keyboard_shortcut_with_length",
    "accesskit_node_set_children", "accesskit_node_add_action", "accesskit_node_set_bounds",
    "accesskit_node_set_transform", "accesskit_node_set_disabled", "accesskit_node_set_read_only",
    "accesskit_node_set_modal", "accesskit_node_set_multiselectable", "accesskit_node_set_selected",
    "accesskit_node_set_expanded", "accesskit_node_set_toggled", "accesskit_node_set_live",
    "accesskit_node_push_labelled_by", "accesskit_node_set_numeric_value",
    "accesskit_node_set_min_numeric_value", "accesskit_node_set_max_numeric_value",
    "accesskit_node_set_numeric_value_step", "accesskit_node_set_level", "accesskit_node_set_position_in_set",
    "accesskit_node_set_size_of_set", "accesskit_node_set_character_lengths",
    "accesskit_node_set_character_positions", "accesskit_node_set_character_widths",
    "accesskit_node_set_text_direction", "accesskit_node_set_row_count", "accesskit_node_set_column_count",
    "accesskit_node_set_row_index", "accesskit_node_set_column_index", "accesskit_node_set_text_selection",
    "accesskit_tree_update_with_capacity_and_focus",
    "accesskit_tree_update_push_node", "accesskit_tree_update_set_tree_info", "accesskit_tree_info_new",
    "accesskit_tree_info_set_toolkit_name", "accesskit_action_request_free"];

/// Loads the library from `path`, or the system's default name when null, once. False if it or a function is
/// missing, or the system has no adapter.
bool loadAccessKit(const(char)* path)
{
    static bool tried;
    static bool loaded;
    if (tried)
    {
        return loaded;
    }
    tried = true;
    if (libraryName is null)
    {
        return false;
    }
    SDL_SharedObject* lib = SDL_LoadObject(path !is null ? path : libraryName.ptr);
    if (lib is null)
    {
        return false;
    }
    static foreach (string name; commonNames ~ platformNames)
    {
        mixin(name) = cast(typeof(mixin(name))) SDL_LoadFunction(lib, name.ptr);
        if (mixin(name) is null)
        {
            return false;
        }
    }
    loaded = true;
    return true;
}
