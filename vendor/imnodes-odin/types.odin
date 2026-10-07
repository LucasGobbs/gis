// imnodes-odin — port of Nelarius/imnodes (C++, MIT) to Odin.
//
// This file is the shared contract of the package: public types, internal
// data structures, object pools, vector/rect math (replacing
// IMGUI_DEFINE_MATH_OPERATORS) and the global context pointer.
//
// Original C++: vendor/imnodes/imnodes.h + imnodes_internal.h
package imnodes

import "core:fmt"
import "core:log"
import "core:math"

import im "../odin-imgui"

Vec2 :: im.Vec2

// ---------------------------------------------------------------------------
// [SECTION] public enums (imnodes.h)
// ---------------------------------------------------------------------------

Col :: enum i32 {
	NodeBackground = 0,
	NodeBackgroundHovered,
	NodeBackgroundSelected,
	NodeOutline,
	TitleBar,
	TitleBarHovered,
	TitleBarSelected,
	Link,
	LinkHovered,
	LinkSelected,
	Pin,
	PinHovered,
	BoxSelector,
	BoxSelectorOutline,
	GridBackground,
	GridLine,
	GridLinePrimary,
	MiniMapBackground,
	MiniMapBackgroundHovered,
	MiniMapOutline,
	MiniMapOutlineHovered,
	MiniMapNodeBackground,
	MiniMapNodeBackgroundHovered,
	MiniMapNodeBackgroundSelected,
	MiniMapNodeOutline,
	MiniMapLink,
	MiniMapLinkSelected,
	MiniMapCanvas,
	MiniMapCanvasOutline,
}

Style_Var :: enum i32 {
	GridSpacing = 0,
	NodeCornerRounding,
	NodePadding,
	NodeBorderThickness,
	LinkThickness,
	LinkLineSegmentsPerLength,
	LinkHoverDistance,
	PinCircleRadius,
	PinQuadSideLength,
	PinTriangleSideLength,
	PinLineThickness,
	PinHoverRadius,
	PinOffset,
	MiniMapPadding,
	MiniMapOffset,
}

Style_Flag :: enum i32 {
	NodeOutline       = 0,
	GridLines         = 2,
	GridLinesPrimary  = 3,
	GridSnapping      = 4,
}
Style_Flags :: bit_set[Style_Flag; i32]

Pin_Shape :: enum i32 {
	Circle,
	CircleFilled,
	Triangle,
	TriangleFilled,
	Quad,
	QuadFilled,
}

Attribute_Flag :: enum i32 {
	EnableLinkDetachWithDragClick = 0,
	EnableLinkCreationOnSnap      = 1,
}
Attribute_Flags :: bit_set[Attribute_Flag; i32]

Mini_Map_Location :: enum i32 {
	BottomLeft,
	BottomRight,
	TopLeft,
	TopRight,
}

// ---------------------------------------------------------------------------
// [SECTION] public structs (imnodes.h)
// ---------------------------------------------------------------------------

IO :: struct {
	// Keyboard modifier + left click pans the editor view (nil by default).
	emulate_three_button_mouse:      struct {
		modifier: ^bool,
	},
	// Left-clicking a link with the modifier pressed detaches it (nil by default).
	link_detach_with_modifier_click: struct {
		modifier: ^bool,
	},
	// Modifier for adding to the selection instead of replacing it.
	// nil = use Ctrl.
	multiple_select_modifier:        struct {
		modifier: ^bool,
	},
	// Mouse button used to pan (im.MouseButton value; Middle by default).
	alt_mouse_button:                i32,
	// Panning speed when dragging an element outside the editor view.
	auto_panning_speed:              f32,
}

io_init :: proc "contextless" () -> IO {
	return IO{alt_mouse_button = i32(im.MouseButton.Middle), auto_panning_speed = 1000.0}
}

Style :: struct {
	grid_spacing:                  f32,
	node_corner_rounding:          f32,
	node_padding:                  Vec2,
	node_border_thickness:         f32,
	link_thickness:                f32,
	link_line_segments_per_length: f32,
	link_hover_distance:           f32,
	pin_circle_radius:             f32,
	pin_quad_side_length:          f32,
	pin_triangle_side_length:      f32,
	pin_line_thickness:            f32,
	pin_hover_radius:              f32,
	pin_offset:                    f32,
	mini_map_padding:              Vec2,
	mini_map_offset:               Vec2,
	flags:                         Style_Flags,
	colors:                        [Col]u32,
}

// Default style values, matching the C++ ImNodesStyle constructor.
// Colors are installed by style_colors_dark (on by default, as upstream).
style_init :: proc "contextless" () -> Style {
	return Style{
		grid_spacing = 24.0,
		node_corner_rounding = 4.0,
		node_padding = {8.0, 8.0},
		node_border_thickness = 1.0,
		link_thickness = 3.0,
		link_line_segments_per_length = 0.1,
		link_hover_distance = 10.0,
		pin_circle_radius = 4.0,
		pin_quad_side_length = 7.0,
		pin_triangle_side_length = 9.5,
		pin_line_thickness = 1.0,
		pin_hover_radius = 10.0,
		pin_offset = 0.0,
		mini_map_padding = {8.0, 8.0},
		mini_map_offset = {4.0, 4.0},
		flags = {.NodeOutline, .GridLines},
	}
}

Mini_Map_Node_Hovering_Callback :: proc(node_id: i32, user_data: rawptr)
Mini_Map_Node_Hovering_Callback_User_Data :: rawptr

// ---------------------------------------------------------------------------
// [SECTION] internal enums (imnodes_internal.h)
// ---------------------------------------------------------------------------

Scope :: enum i32 {
	None      = 1,
	Editor    = 2,
	Node      = 4,
	Attribute = 8,
}

Attribute_Type :: enum i32 {
	None,
	Input,
	Output,
}

UI_State_Flag :: enum i32 {
	LinkStarted = 0,
	LinkDropped = 1,
	LinkCreated = 2,
}
UI_State :: bit_set[UI_State_Flag; i32]

Click_Interaction_Type :: enum i32 {
	Node,
	Link,
	LinkCreation,
	Panning,
	BoxSelection,
	ImGuiItem,
	None,
}

Link_Creation_Type :: enum i32 {
	Standard,
	FromDetach,
}

// ---------------------------------------------------------------------------
// [SECTION] rect (replaces ImRect from imgui_internal.h)
// ---------------------------------------------------------------------------

Rect :: struct {
	min, max: Vec2,
}

rect_size :: proc "contextless" (r: Rect) -> Vec2 {
	return {r.max.x - r.min.x, r.max.y - r.min.y}
}

rect_width :: proc "contextless" (r: Rect) -> f32 {
	return r.max.x - r.min.x
}

rect_height :: proc "contextless" (r: Rect) -> f32 {
	return r.max.y - r.min.y
}

rect_center :: proc "contextless" (r: Rect) -> Vec2 {
	return {(r.min.x + r.max.x) * 0.5, (r.min.y + r.max.y) * 0.5}
}

rect_contains_point :: proc "contextless" (r: Rect, p: Vec2) -> bool {
	return p.x >= r.min.x && p.y >= r.min.y && p.x < r.max.x && p.y < r.max.y
}

rect_contains_rect :: proc "contextless" (r, other: Rect) -> bool {
	return(
		other.min.x >= r.min.x &&
		other.min.y >= r.min.y &&
		other.max.x <= r.max.x &&
		other.max.y <= r.max.y \
	)
}

rect_overlaps :: proc "contextless" (r, other: Rect) -> bool {
	return(
		other.min.y < r.max.y &&
		other.max.y > r.min.y &&
		other.min.x < r.max.x &&
		other.max.x > r.min.x \
	)
}

rect_add_point :: proc "contextless" (r: Rect, p: Vec2) -> Rect {
	r := r
	if r.min.x > p.x { r.min.x = p.x }
	if r.min.y > p.y { r.min.y = p.y }
	if r.max.x < p.x { r.max.x = p.x }
	if r.max.y < p.y { r.max.y = p.y }
	return r
}

rect_add_rect :: proc "contextless" (r, other: Rect) -> Rect {
	r := r
	if r.min.x > other.min.x { r.min.x = other.min.x }
	if r.min.y > other.min.y { r.min.y = other.min.y }
	if r.max.x < other.max.x { r.max.x = other.max.x }
	if r.max.y < other.max.y { r.max.y = other.max.y }
	return r
}

rect_expand_scalar :: proc "contextless" (r: Rect, amount: f32) -> Rect {
	return {{r.min.x - amount, r.min.y - amount}, {r.max.x + amount, r.max.y + amount}}
}

rect_expand_vec :: proc "contextless" (r: Rect, amount: Vec2) -> Rect {
	return {{r.min.x - amount.x, r.min.y - amount.y}, {r.max.x + amount.x, r.max.y + amount.y}}
}

rect_translate :: proc "contextless" (r: Rect, d: Vec2) -> Rect {
	return {{r.min.x + d.x, r.min.y + d.y}, {r.max.x + d.x, r.max.y + d.y}}
}

rect_clip_with :: proc "contextless" (r, clip: Rect) -> Rect {
	return {
		{max(r.min.x, clip.min.x), max(r.min.y, clip.min.y)},
		{min(r.max.x, clip.max.x), min(r.max.y, clip.max.y)},
	}
}

// ---------------------------------------------------------------------------
// [SECTION] vec2 math (replaces IMGUI_DEFINE_MATH_OPERATORS + ImLerp/ImFloor)
// ---------------------------------------------------------------------------

v2_add :: proc "contextless" (a, b: Vec2) -> Vec2 { return {a.x + b.x, a.y + b.y} }
v2_sub :: proc "contextless" (a, b: Vec2) -> Vec2 { return {a.x - b.x, a.y - b.y} }
v2_mul :: proc "contextless" (a, b: Vec2) -> Vec2 { return {a.x * b.x, a.y * b.y} }
v2_scale :: proc "contextless" (a: Vec2, s: f32) -> Vec2 { return {a.x * s, a.y * s} }
v2_scale_div :: proc "contextless" (a: Vec2, s: f32) -> Vec2 { return {a.x / s, a.y / s} }
v2_neg :: proc "contextless" (a: Vec2) -> Vec2 { return {-a.x, -a.y} }
v2_length_sqr :: proc "contextless" (a: Vec2) -> f32 { return a.x * a.x + a.y * a.y }
v2_floor :: proc "contextless" (a: Vec2) -> Vec2 { return {math.floor(a.x), math.floor(a.y)} }
v2_lerp :: proc "contextless" (a, b: Vec2, t: f32) -> Vec2 {
	return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t}
}
v2_min :: proc "contextless" (a, b: Vec2) -> Vec2 { return {min(a.x, b.x), min(a.y, b.y)} }
v2_max :: proc "contextless" (a, b: Vec2) -> Vec2 { return {max(a.x, b.x), max(a.y, b.y)} }

// Replaces the IM_COL32 macro (little-endian RGBA packed into ImU32).
im_col32 :: proc "contextless" (r, g, b, a: u32) -> u32 {
	return (a << 24) | (b << 16) | (g << 8) | r
}

im_col32_white :: proc "contextless" () -> u32 {
	return 0xFFFFFFFF
}

// ---------------------------------------------------------------------------
// [SECTION] internal data structures (imnodes_internal.h)
// ---------------------------------------------------------------------------

Cubic_Bezier :: struct {
	p0, p1, p2, p3: Vec2,
}

Node_Data :: struct {
	id:                     i32,
	origin:                 Vec2, // node origin in editor space
	title_bar_content_rect: Rect,
	rect:                   Rect,
	color_style:            struct {
		background, background_hovered, background_selected: u32,
		outline:                                             u32,
		titlebar, titlebar_hovered, titlebar_selected:       u32,
	},
	layout_style:           struct {
		corner_rounding:  f32,
		padding:          Vec2,
		border_thickness: f32,
	},
	pin_indices:            [dynamic]int,
	draggable:              bool,
}

Pin_Data :: struct {
	id:              i32,
	parent_node_idx: int,
	attribute_rect:  Rect,
	type:            Attribute_Type,
	shape:           Pin_Shape,
	pos:             Vec2, // screen-space coordinates
	flags:           Attribute_Flags,
	color_style:     struct {
		background, hovered: u32,
	},
}

Link_Data :: struct {
	id:           i32,
	start_pin_idx: int,
	end_pin_idx:   int,
	color_style:  struct {
		base, hovered, selected: u32,
	},
}

Click_Interaction_State :: struct {
	type:          Click_Interaction_Type,
	link_creation: struct {
		start_pin_idx: int,
		end_pin_idx:   Maybe(int),
		type:          Link_Creation_Type,
	},
	box_selector:  struct {
		rect: Rect, // coordinates in grid space
	},
}

Col_Element :: struct {
	color: u32,
	item:  Col,
}

Style_Var_Element :: struct {
	item:        Style_Var,
	float_value: [2]f32,
}

// ---------------------------------------------------------------------------
// [SECTION] object pool (replaces the ImObjectPool<T> template)
//
// Objects live in a stable slot array; `id_map` maps user ids to slot
// indices, `in_use` is reset every frame (object_pool_reset) and objects not
// re-submitted in a frame are recycled by object_pool_update.
// ---------------------------------------------------------------------------

Object_Pool :: struct($T: typeid) {
	pool:      [dynamic]T,
	in_use:    [dynamic]bool,
	free_list: [dynamic]int,
	id_map:    map[i32]i32,
}

object_pool_find :: proc "contextless" (objects: Object_Pool($T), id: i32) -> int {
	index, ok := objects.id_map[id]
	if !ok {
		return -1
	}
	return int(index)
}

// Recycles slots whose objects were not submitted this frame.
// The `when T == Node_Data` branch is the C++ ObjectPoolUpdate<ImNodeData>
// specialization: clears pin indices of live nodes and removes dead nodes
// from the editor depth order stack.
object_pool_update :: proc(objects: ^Object_Pool($T)) {
	when T == Node_Data {
		editor := editor_context_get()
		for i in 0 ..< len(objects.in_use) {
			if objects.in_use[i] {
				clear(&objects.pool[i].pin_indices)
			} else {
				id := objects.pool[i].id
				mapped, ok := objects.id_map[id]
				if ok && int(mapped) == i {
					// Remove node idx from the depth stack the first time we
					// detect that this slot is unused.
					found := false
					for depth_pos := len(editor.node_depth_order) - 1; depth_pos >= 0; depth_pos -= 1 {
						if editor.node_depth_order[depth_pos] == i {
							ordered_remove(&editor.node_depth_order, depth_pos)
							found = true
							break
						}
					}
					if !found {
						internal_error("object_pool_update: depth order does not contain freed node slot %d (id %d)", i, id)
					}
					delete_key(&objects.id_map, id)
					append(&objects.free_list, i)
					delete(objects.pool[i].pin_indices)
					objects.pool[i].pin_indices = nil
					objects.pool[i].id = min(i32) // C++ ~ImNodeData() sets Id = INT_MIN
				}
			}
		}
	} else {
		for i in 0 ..< len(objects.in_use) {
			id := objects.pool[i].id
			mapped, ok := objects.id_map[id]
			if !objects.in_use[i] && ok && int(mapped) == i {
				delete_key(&objects.id_map, id)
				append(&objects.free_list, i)
				// C++ runs the destructor here; Odin has no destructors, but
				// Node_Data owns a dynamic array handled in the branch above.
			}
		}
	}
}

// Marks every slot as unused; objects re-submitted this frame flag
// themselves again in object_pool_find_or_create_index.
object_pool_reset :: proc(objects: ^Object_Pool($T)) {
	for &used in objects.in_use {
		used = false
	}
}

// The `when T == Node_Data` branch is the C++ ObjectPoolFindOrCreateIndex
// <ImNodeData> specialization: new nodes are appended to the editor depth
// order and default to draggable.
object_pool_find_or_create_index :: proc(objects: ^Object_Pool($T), id: i32) -> int {
	index: int
	mapped, ok := objects.id_map[id]
	if ok {
		index = int(mapped)
	} else {
		if len(objects.free_list) == 0 {
			index = len(objects.pool)
			assert(len(objects.pool) == len(objects.in_use))
			zero: T
			append(&objects.pool, zero)
			append(&objects.in_use, false)
		} else {
			index = pop(&objects.free_list)
			zero: T
			objects.pool[index] = zero
		}
		objects.pool[index].id = id
		when T == Node_Data {
			objects.pool[index].draggable = true
			editor := editor_context_get()
			append(&editor.node_depth_order, index)
		}
		objects.id_map[id] = i32(index)
	}
	objects.in_use[index] = true
	return index
}

object_pool_find_or_create_object :: proc(objects: ^Object_Pool($T), id: i32) -> ^T {
	index := object_pool_find_or_create_index(objects, id)
	return &objects.pool[index]
}

// ---------------------------------------------------------------------------
// [SECTION] global and editor context structs
// ---------------------------------------------------------------------------

Editor_Context :: struct {
	nodes:                  Object_Pool(Node_Data),
	pins:                   Object_Pool(Pin_Data),
	links:                  Object_Pool(Link_Data),
	node_depth_order:       [dynamic]int,
	// ui related fields
	panning:                Vec2,
	auto_panning_delta:     Vec2,
	// imnodes-odin extension (not in the C++ upstream): canvas zoom factor.
	// Grid space stays the canonical, unscaled content space; editor/screen
	// space = grid * zoom + panning. See editor_context_set_zoom.
	zoom:                   f32,
	// Extents of all content in grid space; valid after the final end_node() call.
	grid_content_bounds:    Rect,
	selected_node_indices:  [dynamic]int,
	selected_link_indices:  [dynamic]int,
	// Relative origins of selected nodes for snapping of dragged nodes.
	selected_node_offsets:  [dynamic]Vec2,
	// Offset of the primary node origin relative to the mouse cursor.
	primary_node_offset:    Vec2,
	click_interaction:      Click_Interaction_State,
	// Mini-map state set by mini_map()
	mini_map_enabled:       bool,
	mini_map_location:      Mini_Map_Location,
	mini_map_size_fraction: f32,
	mini_map_node_hovering_callback:          Mini_Map_Node_Hovering_Callback,
	mini_map_node_hovering_callback_user_data: Mini_Map_Node_Hovering_Callback_User_Data,
	// Mini-map state set during end_node_editor()
	mini_map_rect_screen_space:    Rect,
	mini_map_content_screen_space: Rect,
	mini_map_scaling:              f32,
}

Context :: struct {
	default_editor_ctx:   ^Editor_Context,
	editor_ctx:           ^Editor_Context,
	// Canvas draw list and helper state
	canvas_draw_list:     ^im.DrawList,
	node_idx_to_submission_idx: map[i32]i32,
	node_idx_submission_order:  [dynamic]int,
	node_indices_overlapping_with_mouse: [dynamic]int,
	occluded_pin_indices: [dynamic]int,
	// Canvas extents
	canvas_origin_screen_space: Vec2,
	canvas_rect_screen_space:   Rect,
	// Debug helpers
	current_scope: Scope,
	// Configuration state
	io:                   IO,
	style:                Style,
	color_modifier_stack: [dynamic]Col_Element,
	style_modifier_stack: [dynamic]Style_Var_Element,
	current_attribute_flags: Attribute_Flags,
	attribute_flag_stack:    [dynamic]Attribute_Flags,
	// UI element state
	current_node_idx:      int,
	current_pin_idx:       int,
	current_attribute_id:  i32,
	hovered_node_idx:      Maybe(int),
	hovered_link_idx:      Maybe(int),
	hovered_pin_idx:       Maybe(int),
	deleted_link_idx:      Maybe(int),
	snap_link_idx:         Maybe(int),
	// Event helper state
	ui_state: UI_State,
	active_attribute_id: i32,
	active_attribute:    bool,
	// imgui IO cache
	mouse_pos:                Vec2,
	left_mouse_clicked:       bool,
	left_mouse_released:      bool,
	alt_mouse_clicked:        bool,
	left_mouse_dragging:      bool,
	alt_mouse_dragging:       bool,
	alt_mouse_scroll_delta:   f32,
	multiple_select_modifier: bool,
}

// Global context pointer (replaces GImNodes).
g_imnodes: ^Context

// The release build (-disable-assert) compiles `assert` out, so a violated
// assumption here would turn into out-of-bounds reads / UB instead of a
// crash at the assert. internal_error logs the condition and panics in every
// build: the message points at the offending call, and the panic aborts the
// frame instead of silently corrupting state.
@(private)
internal_error :: proc(format: string, args: ..any) {
	log.errorf("imnodes: %s", fmt.aprintf(format, ..args))
	panic("imnodes: internal invariant violated, see the log line above")
}

editor_context_get :: proc() -> ^Editor_Context {
	// No editor context was set! Did you forget to call create_context()?
	if g_imnodes == nil || g_imnodes.editor_ctx == nil {
		internal_error("no editor context set: call create_context() (and editor_context_set() for a non-default context) before any other imnodes call")
	}
	return g_imnodes.editor_ctx
}
