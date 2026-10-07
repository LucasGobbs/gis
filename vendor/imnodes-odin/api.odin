// imnodes-odin — port of Nelarius/imnodes (C++, MIT) to Odin.
//
// This file ports the public API implementation of imnodes.cpp:
// Initialize/Shutdown (1693-1711), the selection helpers (1955-1987) and the
// [SECTION] API implementation (1988-3273), including the INI serialization.
//
// Original C++: vendor/imnodes/imnodes.cpp
package imnodes

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import im "../odin-imgui"

// ---------------------------------------------------------------------------
// ImGui::ItemAdd binding
//
// ItemAdd is an internal Dear ImGui function and is not exported by the
// odin-imgui binding. It is used in end_node_title_bar to register the title
// bar as an ImGui item (so that e.g. im.IsItemHovered() works right after
// end_node_title_bar). On macOS/Linux we bind the Itanium-mangled symbol
// directly from the imgui static library; on Windows the MSVC-mangled name is
// not bound and the registration is skipped (see README).
// ---------------------------------------------------------------------------

when ODIN_OS == .Windows {
	@(private)
	item_add :: proc "contextless" (rect: Rect, id: im.ID) {}
} else {
	when ODIN_OS == .Linux {
		when ODIN_ARCH == .amd64 {
			foreign import imgui_internal "../odin-imgui/libimgui_linux_x86_64.a"
		} else {
			foreign import imgui_internal "../odin-imgui/libimgui_linux_arm64.a"
		}
	} else when ODIN_OS == .Darwin {
		when ODIN_ARCH == .amd64 {
			foreign import imgui_internal "../odin-imgui/libimgui_macosx_x86_64.a"
		} else {
			foreign import imgui_internal "../odin-imgui/libimgui_macosx_arm64.a"
		}
	}

	foreign imgui_internal {
		@(link_name = "_ZN5ImGui7ItemAddERK6ImRectjPS1_i")
		@(private)
		item_add_internal :: proc "c" (
			bb: ^Rect,
			id: im.ID,
			nav_bb_arg: ^Rect,
			extra_flags: i32,
		) -> bool ---
	}

	@(private)
	item_add :: proc(rect: Rect, id: im.ID) {
		r := rect
		item_add_internal(&r, id, nil, 0)
	}
}

// ---------------------------------------------------------------------------
// Initialize / Shutdown (imnodes.cpp:1693-1711)
// ---------------------------------------------------------------------------

initialize :: proc(ctx: ^Context) {
	// C++ relies on the ImNodesContext constructor for zero-init plus the
	// ImNodesIO/ImNodesStyle constructors for defaults.
	ctx^ = Context{}

	ctx.canvas_origin_screen_space = {0.0, 0.0}
	ctx.canvas_rect_screen_space = {}
	ctx.current_scope = .None

	ctx.current_pin_idx = max(int)
	ctx.current_node_idx = max(int)

	ctx.default_editor_ctx = editor_context_create()
	ctx.editor_ctx = ctx.default_editor_ctx

	ctx.current_attribute_flags = {}
	append(&ctx.attribute_flag_stack, ctx.current_attribute_flags)

	ctx.io = io_init()
	ctx.style = style_init()
	style_colors_dark(&ctx.style)
}

shutdown :: proc(ctx: ^Context) {
	editor_context_free(ctx.default_editor_ctx)
}

// ---------------------------------------------------------------------------
// [SECTION] selection helpers (imnodes.cpp:1955-1987)
// ---------------------------------------------------------------------------

select_object :: proc(objects: ^Object_Pool($T), selected_indices: ^[dynamic]int, id: i32) {
	idx := object_pool_find(objects^, id)
	assert(idx >= 0)
	assert(!slice.contains(selected_indices[:], idx))
	append(selected_indices, idx)
}

clear_object_selection :: proc {
	clear_object_selection_all,
	clear_object_selection_one,
}

clear_object_selection_all :: proc(selected_indices: ^[dynamic]int) {
	clear(selected_indices)
}

clear_object_selection_one :: proc(objects: ^Object_Pool($T), selected_indices: ^[dynamic]int, id: i32) {
	idx := object_pool_find(objects^, id)
	assert(idx >= 0)
	// selected_indices.find(idx) + find_erase_unsorted(idx)
	pos := -1
	for v, i in selected_indices^ {
		if v == idx {
			pos = i
			break
		}
	}
	assert(pos >= 0)
	selected_indices[pos] = selected_indices[len(selected_indices^) - 1]
	_ = pop(selected_indices)
}

is_object_selected :: proc(objects: ^Object_Pool($T), selected_indices: ^[dynamic]int, id: i32) -> bool {
	idx := object_pool_find(objects^, id)
	return slice.contains(selected_indices[:], idx)
}

// ---------------------------------------------------------------------------
// [SECTION] API implementation (imnodes.cpp:1988-3273)
// ---------------------------------------------------------------------------

create_context :: proc() -> ^Context {
	ctx := new(Context)
	if g_imnodes == nil {
		set_current_context(ctx)
	}
	initialize(ctx)
	return ctx
}

destroy_context :: proc(ctx: ^Context = nil) {
	ctx := ctx
	if ctx == nil {
		ctx = g_imnodes
	}
	shutdown(ctx)
	if g_imnodes == ctx {
		set_current_context(nil)
	}
	// C++ relies on the ImNodesContext destructor to release the ImVectors;
	// Odin needs explicit deletes for every owned dynamic array/map.
	delete(ctx.node_idx_to_submission_idx)
	delete(ctx.node_idx_submission_order)
	delete(ctx.node_indices_overlapping_with_mouse)
	delete(ctx.occluded_pin_indices)
	delete(ctx.color_modifier_stack)
	delete(ctx.style_modifier_stack)
	delete(ctx.attribute_flag_stack)
	free(ctx)
}

get_current_context :: proc() -> ^Context {
	return g_imnodes
}

set_current_context :: proc(ctx: ^Context) {
	g_imnodes = ctx
}

editor_context_create :: proc() -> ^Editor_Context {
	ctx := new(Editor_Context)
	ctx.zoom = 1.0
	// The C++ ctor sets ClickInteraction.Type = ImNodesClickInteractionType_None;
	// Odin's zero value here would be .Node (the enum mirrors the C++ order),
	// which starts every editor stuck in a node-drag interaction (auto-pan
	// pans forever while the mouse is outside the canvas).
	ctx.click_interaction.type = .None
	return ctx
}

editor_context_free :: proc(ctx: ^Editor_Context) {
	// C++ relies on the ImNodesEditorContext destructor; Odin needs explicit
	// deletes for every owned dynamic array/map, including the per-node pin
	// index arrays.
	for &node in ctx.nodes.pool {
		delete(node.pin_indices)
	}
	delete(ctx.nodes.pool)
	delete(ctx.nodes.in_use)
	delete(ctx.nodes.free_list)
	delete(ctx.nodes.id_map)
	delete(ctx.pins.pool)
	delete(ctx.pins.in_use)
	delete(ctx.pins.free_list)
	delete(ctx.pins.id_map)
	delete(ctx.links.pool)
	delete(ctx.links.in_use)
	delete(ctx.links.free_list)
	delete(ctx.links.id_map)
	delete(ctx.node_depth_order)
	delete(ctx.selected_node_indices)
	delete(ctx.selected_link_indices)
	delete(ctx.selected_node_offsets)
	free(ctx)
}

editor_context_set :: proc(ctx: ^Editor_Context) {
	g_imnodes.editor_ctx = ctx
}

editor_context_get_panning :: proc() -> Vec2 {
	editor := editor_context_get()
	return editor.panning
}

// The canvas origin in screen space. The C++ library keeps this in
// GImNodes->CanvasOriginScreenSpace (imnodes_internal.h); the ine wrapper
// used it for screen->grid conversion. Valid once the first
// begin_node_editor() of the frame ran.
get_canvas_origin_screen_space :: proc() -> Vec2 {
	return g_imnodes.canvas_origin_screen_space
}

editor_context_reset_panning :: proc(pos: Vec2) {
	editor := editor_context_get()
	editor.panning = pos
}

// --- Zoom (imnodes-odin extension, not in the C++ upstream) ---------------

ZOOM_MIN :: 0.25
ZOOM_MAX :: 3.0

editor_context_get_zoom :: proc() -> f32 {
	return editor_context_get().zoom
}

// Sets the canvas zoom, clamped to [ZOOM_MIN, ZOOM_MAX]. The grid point under
// pivot_screen_pos stays fixed on screen; with a nil pivot the canvas center
// is used. Node positions are stored in grid space, so only the panning needs
// to be recomputed.
editor_context_set_zoom :: proc(zoom: f32, pivot_screen_pos: Maybe(Vec2) = nil) {
	editor := editor_context_get()
	z := clamp(zoom, ZOOM_MIN, ZOOM_MAX)
	if z == editor.zoom {
		return
	}
	pivot_editor: Vec2
	if p, ok := pivot_screen_pos.?; ok {
		pivot_editor = v2_sub(p, g_imnodes.canvas_origin_screen_space)
	} else {
		pivot_editor = v2_scale(rect_size(g_imnodes.canvas_rect_screen_space), 0.5)
	}
	// editor_space = grid * zoom + panning; solve panning so the pivot's grid
	// point is invariant.
	grid_at_pivot := v2_scale_div(v2_sub(pivot_editor, editor.panning), editor.zoom)
	editor.panning = v2_sub(pivot_editor, v2_scale(grid_at_pivot, z))
	editor.zoom = z
}

editor_context_move_to_node :: proc(node_id: i32) {
	editor := editor_context_get()
	node := object_pool_find_or_create_object(&editor.nodes, node_id)

	// editor_space = origin * zoom + panning == 0 at the editor origin.
	editor.panning = v2_scale(v2_neg(node.origin), editor.zoom)
}

set_imgui_context :: proc(ctx: ^im.Context) {
	im.SetCurrentContext(ctx)
}

get_io :: proc() -> ^IO {
	return &g_imnodes.io
}

get_style :: proc() -> ^Style {
	return &g_imnodes.style
}

style_colors_dark :: proc(dest: ^Style = nil) {
	dest := dest
	if dest == nil {
		dest = &g_imnodes.style
	}

	dest.colors[.NodeBackground] = im_col32(50, 50, 50, 255)
	dest.colors[.NodeBackgroundHovered] = im_col32(75, 75, 75, 255)
	dest.colors[.NodeBackgroundSelected] = im_col32(75, 75, 75, 255)
	dest.colors[.NodeOutline] = im_col32(100, 100, 100, 255)
	// title bar colors match ImGui's titlebg colors
	dest.colors[.TitleBar] = im_col32(41, 74, 122, 255)
	dest.colors[.TitleBarHovered] = im_col32(66, 150, 250, 255)
	dest.colors[.TitleBarSelected] = im_col32(66, 150, 250, 255)
	// link colors match ImGui's slider grab colors
	dest.colors[.Link] = im_col32(61, 133, 224, 200)
	dest.colors[.LinkHovered] = im_col32(66, 150, 250, 255)
	dest.colors[.LinkSelected] = im_col32(66, 150, 250, 255)
	// pin colors match ImGui's button colors
	dest.colors[.Pin] = im_col32(53, 150, 250, 180)
	dest.colors[.PinHovered] = im_col32(53, 150, 250, 255)

	dest.colors[.BoxSelector] = im_col32(61, 133, 224, 30)
	dest.colors[.BoxSelectorOutline] = im_col32(61, 133, 224, 150)

	dest.colors[.GridBackground] = im_col32(40, 40, 50, 200)
	dest.colors[.GridLine] = im_col32(200, 200, 200, 40)
	dest.colors[.GridLinePrimary] = im_col32(240, 240, 240, 60)

	// minimap colors
	dest.colors[.MiniMapBackground] = im_col32(25, 25, 25, 150)
	dest.colors[.MiniMapBackgroundHovered] = im_col32(25, 25, 25, 200)
	dest.colors[.MiniMapOutline] = im_col32(150, 150, 150, 100)
	dest.colors[.MiniMapOutlineHovered] = im_col32(150, 150, 150, 200)
	dest.colors[.MiniMapNodeBackground] = im_col32(200, 200, 200, 100)
	dest.colors[.MiniMapNodeBackgroundHovered] = im_col32(200, 200, 200, 255)
	dest.colors[.MiniMapNodeBackgroundSelected] =
		dest.colors[.MiniMapNodeBackgroundHovered]
	dest.colors[.MiniMapNodeOutline] = im_col32(200, 200, 200, 100)
	dest.colors[.MiniMapLink] = dest.colors[.Link]
	dest.colors[.MiniMapLinkSelected] = dest.colors[.LinkSelected]
	dest.colors[.MiniMapCanvas] = im_col32(200, 200, 200, 25)
	dest.colors[.MiniMapCanvasOutline] = im_col32(200, 200, 200, 200)
}

style_colors_classic :: proc(dest: ^Style = nil) {
	dest := dest
	if dest == nil {
		dest = &g_imnodes.style
	}

	dest.colors[.NodeBackground] = im_col32(50, 50, 50, 255)
	dest.colors[.NodeBackgroundHovered] = im_col32(75, 75, 75, 255)
	dest.colors[.NodeBackgroundSelected] = im_col32(75, 75, 75, 255)
	dest.colors[.NodeOutline] = im_col32(100, 100, 100, 255)
	dest.colors[.TitleBar] = im_col32(69, 69, 138, 255)
	dest.colors[.TitleBarHovered] = im_col32(82, 82, 161, 255)
	dest.colors[.TitleBarSelected] = im_col32(82, 82, 161, 255)
	dest.colors[.Link] = im_col32(255, 255, 255, 100)
	dest.colors[.LinkHovered] = im_col32(105, 99, 204, 153)
	dest.colors[.LinkSelected] = im_col32(105, 99, 204, 153)
	dest.colors[.Pin] = im_col32(89, 102, 156, 170)
	dest.colors[.PinHovered] = im_col32(102, 122, 179, 200)
	dest.colors[.BoxSelector] = im_col32(82, 82, 161, 100)
	dest.colors[.BoxSelectorOutline] = im_col32(82, 82, 161, 255)
	dest.colors[.GridBackground] = im_col32(40, 40, 50, 200)
	dest.colors[.GridLine] = im_col32(200, 200, 200, 40)
	dest.colors[.GridLinePrimary] = im_col32(240, 240, 240, 60)

	// minimap colors
	dest.colors[.MiniMapBackground] = im_col32(25, 25, 25, 100)
	dest.colors[.MiniMapBackgroundHovered] = im_col32(25, 25, 25, 200)
	dest.colors[.MiniMapOutline] = im_col32(150, 150, 150, 100)
	dest.colors[.MiniMapOutlineHovered] = im_col32(150, 150, 150, 200)
	dest.colors[.MiniMapNodeBackground] = im_col32(200, 200, 200, 100)
	dest.colors[.MiniMapNodeBackgroundSelected] =
		dest.colors[.MiniMapNodeBackgroundHovered]
	dest.colors[.MiniMapNodeBackgroundSelected] = im_col32(200, 200, 240, 255)
	dest.colors[.MiniMapNodeOutline] = im_col32(200, 200, 200, 100)
	dest.colors[.MiniMapLink] = dest.colors[.Link]
	dest.colors[.MiniMapLinkSelected] = dest.colors[.LinkSelected]
	dest.colors[.MiniMapCanvas] = im_col32(200, 200, 200, 25)
	dest.colors[.MiniMapCanvasOutline] = im_col32(200, 200, 200, 200)
}

style_colors_light :: proc(dest: ^Style = nil) {
	dest := dest
	if dest == nil {
		dest = &g_imnodes.style
	}

	dest.colors[.NodeBackground] = im_col32(240, 240, 240, 255)
	dest.colors[.NodeBackgroundHovered] = im_col32(240, 240, 240, 255)
	dest.colors[.NodeBackgroundSelected] = im_col32(240, 240, 240, 255)
	dest.colors[.NodeOutline] = im_col32(100, 100, 100, 255)
	dest.colors[.TitleBar] = im_col32(248, 248, 248, 255)
	dest.colors[.TitleBarHovered] = im_col32(209, 209, 209, 255)
	dest.colors[.TitleBarSelected] = im_col32(209, 209, 209, 255)
	// original imgui values: 66, 150, 250
	dest.colors[.Link] = im_col32(66, 150, 250, 100)
	// original imgui values: 117, 138, 204
	dest.colors[.LinkHovered] = im_col32(66, 150, 250, 242)
	dest.colors[.LinkSelected] = im_col32(66, 150, 250, 242)
	// original imgui values: 66, 150, 250
	dest.colors[.Pin] = im_col32(66, 150, 250, 160)
	dest.colors[.PinHovered] = im_col32(66, 150, 250, 255)
	dest.colors[.BoxSelector] = im_col32(90, 170, 250, 30)
	dest.colors[.BoxSelectorOutline] = im_col32(90, 170, 250, 150)
	dest.colors[.GridBackground] = im_col32(225, 225, 225, 255)
	dest.colors[.GridLine] = im_col32(180, 180, 180, 100)
	dest.colors[.GridLinePrimary] = im_col32(120, 120, 120, 100)

	// minimap colors
	dest.colors[.MiniMapBackground] = im_col32(25, 25, 25, 100)
	dest.colors[.MiniMapBackgroundHovered] = im_col32(25, 25, 25, 200)
	dest.colors[.MiniMapOutline] = im_col32(150, 150, 150, 100)
	dest.colors[.MiniMapOutlineHovered] = im_col32(150, 150, 150, 200)
	dest.colors[.MiniMapNodeBackground] = im_col32(200, 200, 200, 100)
	dest.colors[.MiniMapNodeBackgroundSelected] =
		dest.colors[.MiniMapNodeBackgroundHovered]
	dest.colors[.MiniMapNodeBackgroundSelected] = im_col32(200, 200, 240, 255)
	dest.colors[.MiniMapNodeOutline] = im_col32(200, 200, 200, 100)
	dest.colors[.MiniMapLink] = dest.colors[.Link]
	dest.colors[.MiniMapLinkSelected] = dest.colors[.LinkSelected]
	dest.colors[.MiniMapCanvas] = im_col32(200, 200, 200, 25)
	dest.colors[.MiniMapCanvasOutline] = im_col32(200, 200, 200, 200)
}

begin_node_editor :: proc() {
	assert(g_imnodes.current_scope == .None)
	g_imnodes.current_scope = .Editor

	// Reset state from previous pass

	editor := editor_context_get()
	editor.auto_panning_delta = {0, 0}
	editor.grid_content_bounds = {{max(f32), max(f32)}, {-max(f32), -max(f32)}}
	editor.mini_map_enabled = false
	object_pool_reset(&editor.nodes)
	object_pool_reset(&editor.pins)
	object_pool_reset(&editor.links)

	g_imnodes.hovered_node_idx = nil
	g_imnodes.hovered_link_idx = nil
	g_imnodes.hovered_pin_idx = nil
	g_imnodes.deleted_link_idx = nil
	g_imnodes.snap_link_idx = nil

	clear(&g_imnodes.node_indices_overlapping_with_mouse)

	g_imnodes.ui_state = {}

	g_imnodes.mouse_pos = im.GetIO().MousePos
	g_imnodes.left_mouse_clicked = im.IsMouseClicked(.Left)
	g_imnodes.left_mouse_released = im.IsMouseReleased(.Left)
	g_imnodes.left_mouse_dragging = im.IsMouseDragging(.Left, 0.0)
	emulate_modifier := g_imnodes.io.emulate_three_button_mouse.modifier
	g_imnodes.alt_mouse_clicked =
		(emulate_modifier != nil && emulate_modifier^ && g_imnodes.left_mouse_clicked) ||
		im.IsMouseClicked(im.MouseButton(g_imnodes.io.alt_mouse_button))
	g_imnodes.alt_mouse_dragging =
		(emulate_modifier != nil && g_imnodes.left_mouse_dragging && emulate_modifier^) ||
		im.IsMouseDragging(im.MouseButton(g_imnodes.io.alt_mouse_button), 0.0)
	g_imnodes.alt_mouse_scroll_delta = im.GetIO().MouseWheel
	if ms_modifier := g_imnodes.io.multiple_select_modifier.modifier; ms_modifier != nil {
		g_imnodes.multiple_select_modifier = ms_modifier^
	} else {
		// io.KeyCtrl on the older imgui; the vendored binding exposes the
		// modifier as a key index instead.
		g_imnodes.multiple_select_modifier = im.IsKeyDown(im.Key(im.KEY_MOD_CTRL))
	}

	g_imnodes.active_attribute = false

	im.BeginGroup()
	{
		im.PushStyleVarVec2(.FramePadding, {1.0, 1.0})
		im.PushStyleVarVec2(.WindowPadding, {0.0, 0.0})
		im.PushStyleColor(.ChildBg, g_imnodes.style.colors[.GridBackground])
		im.BeginChild(
			"scrolling_region",
			{0.0, 0.0},
			im.ChildFlags{.Borders},
			{.NoScrollbar, .NoMove, .NoScrollWithMouse},
		)
		// imnodes-odin zoom: scale the node content text. PushFontFloat with a
		// nil font keeps the font and changes the size (FontSizeBase is the
		// unscaled size; global factors must not apply twice). Skipped at
		// zoom == 1 so the default path is bit-identical to upstream.
		if editor.zoom != 1.0 {
			im.PushFontFloat(nil, im.GetStyle().FontSizeBase * editor.zoom)
		}
		g_imnodes.canvas_origin_screen_space = im.GetCursorScreenPos()

		// NOTE: we have to fetch the canvas draw list *after* we call
		// BeginChild(), otherwise the ImGui UI elements are going to be
		// rendered into the parent window draw list.
		draw_list_set(im.GetWindowDrawList())

		{
			canvas_size := im.GetWindowSize()
			g_imnodes.canvas_rect_screen_space = Rect{
				editor_space_to_screen_space({0.0, 0.0}),
				editor_space_to_screen_space(canvas_size),
			}

			if .GridLines in g_imnodes.style.flags {
				draw_grid(editor, canvas_size)
			}
		}
	}
}

end_node_editor :: proc() {
	assert(g_imnodes.current_scope == .Editor)
	g_imnodes.current_scope = .None

	editor := editor_context_get()

	// GridContentBounds.IsInverted() inlined
	no_grid_content := editor.grid_content_bounds.min.x > editor.grid_content_bounds.max.x
	if no_grid_content {
		editor.grid_content_bounds = screen_space_to_grid_space(
			editor,
			g_imnodes.canvas_rect_screen_space,
		)
	}

	// Detect ImGui interaction first, because it blocks interaction with the rest of the UI

	if g_imnodes.left_mouse_clicked && im.IsAnyItemActive() {
		editor.click_interaction.type = .ImGuiItem
	}

	// Detect which UI element is being hovered over. Detection is done in a hierarchical fashion,
	// because a UI element being hovered excludes any other as being hovered over.

	// Don't do hovering detection for nodes/links/pins when interacting with the mini-map, since
	// its an *overlay* with its own interaction behavior and must have precedence during mouse
	// interaction.

	if (editor.click_interaction.type == .None ||
		   editor.click_interaction.type == .LinkCreation) &&
	   mouse_in_canvas() &&
	   !is_mini_map_hovered() {
		// Pins needs some special care. We need to check the depth stack to see which pins are
		// being occluded by other nodes.
		resolve_occluded_pins(editor, &g_imnodes.occluded_pin_indices)

		g_imnodes.hovered_pin_idx = resolve_hovered_pin(
			editor.pins,
			g_imnodes.occluded_pin_indices[:],
		)

		if g_imnodes.hovered_pin_idx == nil {
			// Resolve which node is actually on top and being hovered using the depth stack.
			g_imnodes.hovered_node_idx = resolve_hovered_node(editor.node_depth_order[:])
		}

		// We don't check for hovered pins here, because if we want to detach a link by clicking and
		// dragging, we need to have both a link and pin hovered.
		if g_imnodes.hovered_node_idx == nil {
			g_imnodes.hovered_link_idx = resolve_hovered_link(editor.links, editor.pins)
		}
	}

	for node_idx in 0 ..< len(editor.nodes.pool) {
		if editor.nodes.in_use[node_idx] {
			draw_list_activate_node_background(node_idx)
			draw_node(editor, node_idx)
		}
	}

	// In order to render the links underneath the nodes, we want to first select the bottom draw
	// channel.
	im.DrawList_ChannelsSetCurrent(g_imnodes.canvas_draw_list, 0)

	for link_idx in 0 ..< len(editor.links.pool) {
		if editor.links.in_use[link_idx] {
			draw_link(editor, link_idx)
		}
	}

	// Render the click interaction UI elements (partial links, box selector) on top of everything
	// else.

	draw_list_append_click_interaction_channel()
	draw_list_activate_click_interaction_channel()

	if is_mini_map_active() {
		calc_mini_map_layout()
		mini_map_update()
	}

	// Handle node graph interaction

	if !is_mini_map_hovered() {
		if g_imnodes.left_mouse_clicked && g_imnodes.hovered_link_idx != nil {
			begin_link_interaction(
				editor,
				g_imnodes.hovered_link_idx.?,
				g_imnodes.hovered_pin_idx,
			)
		} else if g_imnodes.left_mouse_clicked && g_imnodes.hovered_pin_idx != nil {
			begin_link_creation(editor, g_imnodes.hovered_pin_idx.?)
		} else if g_imnodes.left_mouse_clicked && g_imnodes.hovered_node_idx != nil {
			begin_node_selection(editor, g_imnodes.hovered_node_idx.?)
		} else if g_imnodes.left_mouse_clicked ||
		   g_imnodes.left_mouse_released ||
		   g_imnodes.alt_mouse_clicked ||
		   g_imnodes.alt_mouse_scroll_delta != 0.0 {
			begin_canvas_interaction(editor)
		}

		should_auto_pan :=
			editor.click_interaction.type == .BoxSelection ||
			editor.click_interaction.type == .LinkCreation ||
			editor.click_interaction.type == .Node
		if should_auto_pan && !mouse_in_canvas() {
			mouse := im.GetMousePos()
			center := rect_center(g_imnodes.canvas_rect_screen_space)
			direction := v2_sub(center, mouse)
			// direction = direction * ImInvLength(direction, 0.0)
			inv_length: f32 = 0.0
			if length_sqr := v2_length_sqr(direction); length_sqr > 0.0 {
				inv_length = 1.0 / math.sqrt(length_sqr)
			}
			direction = v2_scale(direction, inv_length)

			editor.auto_panning_delta = v2_scale(
				direction,
				im.GetIO().DeltaTime * g_imnodes.io.auto_panning_speed,
			)
			editor.panning = v2_add(editor.panning, editor.auto_panning_delta)
		}
	}
	click_interaction_update(editor)

	// At this point, draw commands have been issued for all nodes (and pins). Update the node pool
	// to detect unused node slots and remove those indices from the depth stack before sorting the
	// node draw commands by depth.
	object_pool_update(&editor.nodes)
	object_pool_update(&editor.pins)

	draw_list_sort_channels_by_depth(editor.node_depth_order[:])

	// After the links have been rendered, the link pool can be updated as well.
	object_pool_update(&editor.links)

	// Finally, merge the draw channels
	im.DrawList_ChannelsMerge(g_imnodes.canvas_draw_list)

	// pop style
	if editor.zoom != 1.0 {
		im.PopFont() // pushed in begin_node_editor (imnodes-odin zoom)
	}
	im.EndChild() // end scrolling region
	im.PopStyleColor() // pop child window background color
	im.PopStyleVar() // pop window padding
	im.PopStyleVar() // pop frame padding
	im.EndGroup()
}

mini_map :: proc(
	size_fraction: f32 = 0.2,
	location: Mini_Map_Location = .TopLeft,
	node_hovering_callback: Mini_Map_Node_Hovering_Callback = nil,
	node_hovering_callback_user_data: Mini_Map_Node_Hovering_Callback_User_Data = nil,
) {
	// Check that editor size fraction is sane; must be in the range (0, 1]
	assert(size_fraction > 0.0 && size_fraction <= 1.0)

	// Remember to call before EndNodeEditor
	assert(g_imnodes.current_scope == .Editor)

	editor := editor_context_get()

	editor.mini_map_enabled = true
	editor.mini_map_size_fraction = size_fraction
	editor.mini_map_location = location

	// Set node hovering callback information
	editor.mini_map_node_hovering_callback = node_hovering_callback
	editor.mini_map_node_hovering_callback_user_data = node_hovering_callback_user_data

	// Actual drawing/updating of the MiniMap is done in EndNodeEditor so that
	// mini map is draw over everything and all pin/link positions are updated
	// correctly relative to their respective nodes. Hence, we must store some of
	// of the state for the mini map in GImNodes for the actual drawing/updating
}

begin_node :: proc(node_id: i32) {
	// Remember to call BeginNodeEditor before calling BeginNode
	assert(g_imnodes.current_scope == .Editor)
	g_imnodes.current_scope = .Node

	editor := editor_context_get()

	node_idx := object_pool_find_or_create_index(&editor.nodes, node_id)
	g_imnodes.current_node_idx = node_idx

	node := &editor.nodes.pool[node_idx]
	node.color_style.background = g_imnodes.style.colors[.NodeBackground]
	node.color_style.background_hovered = g_imnodes.style.colors[.NodeBackgroundHovered]
	node.color_style.background_selected = g_imnodes.style.colors[.NodeBackgroundSelected]
	node.color_style.outline = g_imnodes.style.colors[.NodeOutline]
	node.color_style.titlebar = g_imnodes.style.colors[.TitleBar]
	node.color_style.titlebar_hovered = g_imnodes.style.colors[.TitleBarHovered]
	node.color_style.titlebar_selected = g_imnodes.style.colors[.TitleBarSelected]
	node.layout_style.corner_rounding = g_imnodes.style.node_corner_rounding
	node.layout_style.padding = g_imnodes.style.node_padding
	node.layout_style.border_thickness = g_imnodes.style.node_border_thickness

	// ImGui::SetCursorPos sets the cursor position, local to the current widget
	// (in this case, the child object started in BeginNodeEditor). Use
	// ImGui::SetCursorScreenPos to set the screen space coordinates directly.
	im.SetCursorPos(grid_space_to_editor_space(editor, get_node_title_bar_origin(node)))

	draw_list_add_node(node_idx)
	draw_list_activate_current_node_foreground()

	im.PushIDInt(node.id)
	im.BeginGroup()
}

end_node :: proc() {
	assert(g_imnodes.current_scope == .Node)
	g_imnodes.current_scope = .Editor

	editor := editor_context_get()

	// The node's rectangle depends on the ImGui UI group size.
	im.EndGroup()
	im.PopID()

	node := &editor.nodes.pool[g_imnodes.current_node_idx]
	node.rect = get_item_rect()
	// The group rect is measured in (scaled) screen pixels; the padding is in
	// unscaled grid units, so it scales into pixels for the screen-space rect.
	node.rect = rect_expand_vec(node.rect, v2_scale(node.layout_style.padding, editor.zoom))
	editor.grid_content_bounds = rect_add_point(editor.grid_content_bounds, node.origin)
	editor.grid_content_bounds = rect_add_point(
		editor.grid_content_bounds,
		v2_add(node.origin, v2_scale_div(rect_size(node.rect), editor.zoom)),
	)

	if rect_contains_point(node.rect, g_imnodes.mouse_pos) {
		append(
			&g_imnodes.node_indices_overlapping_with_mouse,
			g_imnodes.current_node_idx,
		)
	}
}

get_node_dimensions :: proc(node_id: i32) -> Vec2 {
	editor := editor_context_get()
	node_idx := object_pool_find(editor.nodes, node_id)
	if node_idx == -1 {
		internal_error("get_node_dimensions: invalid node id %d (no such node was submitted this frame)", node_id)
	}
	node := &editor.nodes.pool[node_idx]
	return rect_size(node.rect)
}

begin_node_title_bar :: proc() {
	assert(g_imnodes.current_scope == .Node)
	im.BeginGroup()
}

end_node_title_bar :: proc() {
	assert(g_imnodes.current_scope == .Node)
	im.EndGroup()

	editor := editor_context_get()
	node := &editor.nodes.pool[g_imnodes.current_node_idx]
	node.title_bar_content_rect = get_item_rect()

	item_add(get_node_title_rect(node), im.GetID("title_bar"))

	im.SetCursorPos(grid_space_to_editor_space(editor, get_node_content_origin(node)))
}

begin_input_attribute :: proc(id: i32, shape: Pin_Shape = .CircleFilled) {
	begin_pin_attribute(id, .Input, shape, g_imnodes.current_node_idx)
}

end_input_attribute :: proc() {
	end_pin_attribute()
}

begin_output_attribute :: proc(id: i32, shape: Pin_Shape = .CircleFilled) {
	begin_pin_attribute(id, .Output, shape, g_imnodes.current_node_idx)
}

end_output_attribute :: proc() {
	end_pin_attribute()
}

begin_static_attribute :: proc(id: i32) {
	// Make sure to call BeginNode() before calling BeginAttribute()
	assert(g_imnodes.current_scope == .Node)
	g_imnodes.current_scope = .Attribute

	g_imnodes.current_attribute_id = id

	editor := editor_context_get()
	node := &editor.nodes.pool[g_imnodes.current_node_idx]
	content_x := grid_space_to_editor_space(editor, get_node_content_origin(node)).x
	im.SetCursorPosX(content_x)

	im.BeginGroup()
	im.PushIDInt(id)
}
end_static_attribute :: proc() {
	// Make sure to call BeginNode() before calling BeginAttribute()
	assert(g_imnodes.current_scope == .Attribute)
	g_imnodes.current_scope = .Node

	im.PopID()
	im.EndGroup()

	if im.IsItemActive() {
		g_imnodes.active_attribute = true
		g_imnodes.active_attribute_id = g_imnodes.current_attribute_id
	}
}

push_attribute_flag :: proc(flag: Attribute_Flags) {
	g_imnodes.current_attribute_flags += flag
	append(&g_imnodes.attribute_flag_stack, g_imnodes.current_attribute_flags)
}

pop_attribute_flag :: proc() {
	// PopAttributeFlag called without a matching PushAttributeFlag!
	// The bottom value is always the default value, pushed in Initialize().
	if len(g_imnodes.attribute_flag_stack) <= 1 {
		internal_error("pop_attribute_flag: no matching push_attribute_flag")
	}

	_ = pop(&g_imnodes.attribute_flag_stack)
	g_imnodes.current_attribute_flags =
		g_imnodes.attribute_flag_stack[len(g_imnodes.attribute_flag_stack) - 1]
}

link :: proc(id, start_attr_id, end_attr_id: i32) {
	assert(g_imnodes.current_scope == .Editor)

	editor := editor_context_get()
	link := object_pool_find_or_create_object(&editor.links, id)
	link.id = id
	link.start_pin_idx = object_pool_find_or_create_index(&editor.pins, start_attr_id)
	link.end_pin_idx = object_pool_find_or_create_index(&editor.pins, end_attr_id)
	link.color_style.base = g_imnodes.style.colors[.Link]
	link.color_style.hovered = g_imnodes.style.colors[.LinkHovered]
	link.color_style.selected = g_imnodes.style.colors[.LinkSelected]

	// Check if this link was created by the current link event
	//
	// NOTE: the C++ ImOptionalIndex == int comparisons compare the raw index
	// value (-1 when empty); `or_else -1` mirrors that.
	if (editor.click_interaction.type == .LinkCreation &&
		   .EnableLinkCreationOnSnap in editor.pins.pool[link.end_pin_idx].flags &&
		   editor.click_interaction.link_creation.start_pin_idx == link.start_pin_idx &&
		   (editor.click_interaction.link_creation.end_pin_idx.? or_else -1) == link.end_pin_idx) ||
	   (editor.click_interaction.link_creation.start_pin_idx == link.end_pin_idx &&
		   (editor.click_interaction.link_creation.end_pin_idx.? or_else -1) == link.start_pin_idx) {
		g_imnodes.snap_link_idx = object_pool_find_or_create_index(&editor.links, id)
	}
}

push_color_style :: proc(item: Col, color: u32) {
	append(
		&g_imnodes.color_modifier_stack,
		Col_Element{color = g_imnodes.style.colors[item], item = item},
	)
	g_imnodes.style.colors[item] = color
}
pop_color_style :: proc() {
	if len(g_imnodes.color_modifier_stack) == 0 {
		internal_error("pop_color_style: color modifier stack is empty (mismatched push/pop)")
	}
	elem := pop(&g_imnodes.color_modifier_stack)
	g_imnodes.style.colors[elem.item] = elem.color
}

// Replaces the GStyleVarInfo offsetof table from the C++: explicit switches
// over Style_Var handing out a pointer to the corresponding Style field.
// Vec2 vars are .NodePadding, .MiniMapPadding, .MiniMapOffset; all others f32.

@(private)
style_var_float_ptr :: proc "contextless" (style: ^Style, item: Style_Var) -> ^f32 {
	switch item {
	case .GridSpacing:
		return &style.grid_spacing
	case .NodeCornerRounding:
		return &style.node_corner_rounding
	case .NodeBorderThickness:
		return &style.node_border_thickness
	case .LinkThickness:
		return &style.link_thickness
	case .LinkLineSegmentsPerLength:
		return &style.link_line_segments_per_length
	case .LinkHoverDistance:
		return &style.link_hover_distance
	case .PinCircleRadius:
		return &style.pin_circle_radius
	case .PinQuadSideLength:
		return &style.pin_quad_side_length
	case .PinTriangleSideLength:
		return &style.pin_triangle_side_length
	case .PinLineThickness:
		return &style.pin_line_thickness
	case .PinHoverRadius:
		return &style.pin_hover_radius
	case .PinOffset:
		return &style.pin_offset
	case .NodePadding, .MiniMapPadding, .MiniMapOffset:
		return nil
	}
	return nil
}

@(private)
style_var_vec2_ptr :: proc "contextless" (style: ^Style, item: Style_Var) -> ^Vec2 {
	switch item {
	case .NodePadding:
		return &style.node_padding
	case .MiniMapPadding:
		return &style.mini_map_padding
	case .MiniMapOffset:
		return &style.mini_map_offset
	case .GridSpacing,
	     .NodeCornerRounding,
	     .NodeBorderThickness,
	     .LinkThickness,
	     .LinkLineSegmentsPerLength,
	     .LinkHoverDistance,
	     .PinCircleRadius,
	     .PinQuadSideLength,
	     .PinTriangleSideLength,
	     .PinLineThickness,
	     .PinHoverRadius,
	     .PinOffset:
		return nil
	}
	return nil
}

push_style_var :: proc {
	push_style_var_float,
	push_style_var_vec2,
}

push_style_var_float :: proc(item: Style_Var, value: f32) {
	style_var := style_var_float_ptr(&g_imnodes.style, item)
	if style_var != nil {
		append(
			&g_imnodes.style_modifier_stack,
			Style_Var_Element{item = item, float_value = {style_var^, 0.0}},
		)
		style_var^ = value
		return
	}
	internal_error("push_style_var_float: style var %d is not a float", int(item))
}

push_style_var_vec2 :: proc(item: Style_Var, value: Vec2) {
	style_var := style_var_vec2_ptr(&g_imnodes.style, item)
	if style_var != nil {
		append(
			&g_imnodes.style_modifier_stack,
			Style_Var_Element{item = item, float_value = {style_var.x, style_var.y}},
		)
		style_var^ = value
		return
	}
	internal_error("push_style_var_vec2: style var %d is not a Vec2", int(item))
}

pop_style_var :: proc(count: int = 1) {
	count := count
	for count > 0 {
		if len(g_imnodes.style_modifier_stack) == 0 {
			internal_error("pop_style_var: style modifier stack is empty (mismatched push/pop)")
		}
		style_backup := pop(&g_imnodes.style_modifier_stack)
		if style_var := style_var_float_ptr(&g_imnodes.style, style_backup.item);
		   style_var != nil {
			style_var^ = style_backup.float_value[0]
		} else if style_var := style_var_vec2_ptr(&g_imnodes.style, style_backup.item);
		   style_var != nil {
			style_var^ = {style_backup.float_value[0], style_backup.float_value[1]}
		}
		count -= 1
	}
}

set_node_screen_space_pos :: proc(node_id: i32, screen_space_pos: Vec2) {
	editor := editor_context_get()
	node := object_pool_find_or_create_object(&editor.nodes, node_id)
	node.origin = screen_space_to_grid_space(editor, screen_space_pos)
}

set_node_editor_space_pos :: proc(node_id: i32, editor_space_pos: Vec2) {
	editor := editor_context_get()
	node := object_pool_find_or_create_object(&editor.nodes, node_id)
	node.origin = editor_space_to_grid_space(editor, editor_space_pos)
}

set_node_grid_space_pos :: proc(node_id: i32, grid_pos: Vec2) {
	editor := editor_context_get()
	node := object_pool_find_or_create_object(&editor.nodes, node_id)
	node.origin = grid_pos
}

set_node_draggable :: proc(node_id: i32, draggable: bool) {
	editor := editor_context_get()
	node := object_pool_find_or_create_object(&editor.nodes, node_id)
	node.draggable = draggable
}

get_node_screen_space_pos :: proc(node_id: i32) -> Vec2 {
	editor := editor_context_get()
	node_idx := object_pool_find(editor.nodes, node_id)
	if node_idx == -1 {
		internal_error("get_node_screen_space_pos: invalid node id %d (no such node was submitted this frame)", node_id)
	}
	node := &editor.nodes.pool[node_idx]
	return grid_space_to_screen_space(editor, node.origin)
}

get_node_editor_space_pos :: proc(node_id: i32) -> Vec2 {
	editor := editor_context_get()
	node_idx := object_pool_find(editor.nodes, node_id)
	if node_idx == -1 {
		internal_error("get_node_editor_space_pos: invalid node id %d (no such node was submitted this frame)", node_id)
	}
	node := &editor.nodes.pool[node_idx]
	return grid_space_to_editor_space(editor, node.origin)
}

get_node_grid_space_pos :: proc(node_id: i32) -> Vec2 {
	editor := editor_context_get()
	node_idx := object_pool_find(editor.nodes, node_id)
	if node_idx == -1 {
		internal_error("get_node_grid_space_pos: invalid node id %d (no such node was submitted this frame)", node_id)
	}
	node := &editor.nodes.pool[node_idx]
	return node.origin
}

snap_node_to_grid :: proc(node_id: i32) {
	editor := editor_context_get()
	node := object_pool_find_or_create_object(&editor.nodes, node_id)
	node.origin = snap_origin_to_grid(node.origin)
}

is_editor_hovered :: proc() -> bool {
	return mouse_in_canvas()
}

is_node_hovered :: proc() -> (hovered: bool, node_id: i32) {
	assert(g_imnodes.current_scope == .None)

	hovered = g_imnodes.hovered_node_idx != nil
	if hovered {
		editor := editor_context_get()
		node_id = editor.nodes.pool[g_imnodes.hovered_node_idx.?].id
	}
	return
}

is_link_hovered :: proc() -> (hovered: bool, link_id: i32) {
	assert(g_imnodes.current_scope == .None)

	hovered = g_imnodes.hovered_link_idx != nil
	if hovered {
		editor := editor_context_get()
		link_id = editor.links.pool[g_imnodes.hovered_link_idx.?].id
	}
	return
}

is_pin_hovered :: proc() -> (hovered: bool, attribute_id: i32) {
	assert(g_imnodes.current_scope == .None)

	hovered = g_imnodes.hovered_pin_idx != nil
	if hovered {
		editor := editor_context_get()
		attribute_id = editor.pins.pool[g_imnodes.hovered_pin_idx.?].id
	}
	return
}

num_selected_nodes :: proc() -> int {
	assert(g_imnodes.current_scope == .None)
	editor := editor_context_get()
	return len(editor.selected_node_indices)
}

num_selected_links :: proc() -> int {
	assert(g_imnodes.current_scope == .None)
	editor := editor_context_get()
	return len(editor.selected_link_indices)
}

// The caller provides a slice with enough capacity (num_selected_nodes()).
get_selected_nodes :: proc(node_ids: []i32) {
	editor := editor_context_get()
	for node_idx, i in editor.selected_node_indices {
		node_ids[i] = editor.nodes.pool[node_idx].id
	}
}

// The caller provides a slice with enough capacity (num_selected_links()).
get_selected_links :: proc(link_ids: []i32) {
	editor := editor_context_get()
	for link_idx, i in editor.selected_link_indices {
		link_ids[i] = editor.links.pool[link_idx].id
	}
}

clear_node_selection :: proc {
	clear_node_selection_all,
	clear_node_selection_one,
}

clear_node_selection_all :: proc() {
	editor := editor_context_get()
	clear_object_selection(&editor.selected_node_indices)
}

clear_node_selection_one :: proc(node_id: i32) {
	editor := editor_context_get()
	clear_object_selection(&editor.nodes, &editor.selected_node_indices, node_id)
}

clear_link_selection :: proc {
	clear_link_selection_all,
	clear_link_selection_one,
}

clear_link_selection_all :: proc() {
	editor := editor_context_get()
	clear_object_selection(&editor.selected_link_indices)
}

clear_link_selection_one :: proc(link_id: i32) {
	editor := editor_context_get()
	clear_object_selection(&editor.links, &editor.selected_link_indices, link_id)
}

select_node :: proc(node_id: i32) {
	editor := editor_context_get()
	select_object(&editor.nodes, &editor.selected_node_indices, node_id)
}

select_link :: proc(link_id: i32) {
	editor := editor_context_get()
	select_object(&editor.links, &editor.selected_link_indices, link_id)
}

is_node_selected :: proc(node_id: i32) -> bool {
	editor := editor_context_get()
	return is_object_selected(&editor.nodes, &editor.selected_node_indices, node_id)
}

is_link_selected :: proc(link_id: i32) -> bool {
	editor := editor_context_get()
	return is_object_selected(&editor.links, &editor.selected_link_indices, link_id)
}

is_attribute_active :: proc() -> bool {
	assert((i32(g_imnodes.current_scope) & i32(Scope.Node)) != 0)

	if !g_imnodes.active_attribute {
		return false
	}

	return g_imnodes.active_attribute_id == g_imnodes.current_attribute_id
}

is_any_attribute_active :: proc() -> (active: bool, attribute_id: i32) {
	assert(
		(i32(g_imnodes.current_scope) & (i32(Scope.Node) | i32(Scope.Attribute))) == 0,
	)

	if !g_imnodes.active_attribute {
		return false, 0
	}

	return true, g_imnodes.active_attribute_id
}

is_link_started :: proc() -> (started: bool, at_attr_id: i32) {
	// Call this function after EndNodeEditor()!
	assert(g_imnodes.current_scope == .None)

	started = .LinkStarted in g_imnodes.ui_state
	if started {
		editor := editor_context_get()
		pin_idx := editor.click_interaction.link_creation.start_pin_idx
		at_attr_id = editor.pins.pool[pin_idx].id
	}

	return
}

is_link_dropped :: proc(
	including_detached_links: bool = true,
) -> (
	dropped: bool,
	at_attr_id: i32,
) {
	// Call this function after EndNodeEditor()!
	assert(g_imnodes.current_scope == .None)

	editor := editor_context_get()

	dropped =
		(.LinkDropped in g_imnodes.ui_state) &&
		(including_detached_links ||
				editor.click_interaction.link_creation.type != .FromDetach)

	if dropped {
		pin_idx := editor.click_interaction.link_creation.start_pin_idx
		at_attr_id = editor.pins.pool[pin_idx].id
	}

	return
}

is_link_created :: proc() -> (
	created: bool,
	started_at_attr: i32,
	ended_at_attr: i32,
	created_from_snap: bool,
) {
	assert(g_imnodes.current_scope == .None)

	created = .LinkCreated in g_imnodes.ui_state

	if created {
		editor := editor_context_get()
		start_idx := editor.click_interaction.link_creation.start_pin_idx
		end_idx := editor.click_interaction.link_creation.end_pin_idx.?
		start_pin := &editor.pins.pool[start_idx]
		end_pin := &editor.pins.pool[end_idx]

		if start_pin.type == .Output {
			started_at_attr = start_pin.id
			ended_at_attr = end_pin.id
		} else {
			started_at_attr = end_pin.id
			ended_at_attr = start_pin.id
		}

		created_from_snap = editor.click_interaction.type == .LinkCreation
	}

	return
}

is_link_created_ex :: proc() -> (
	created: bool,
	started_at_node: i32,
	started_at_attr: i32,
	ended_at_node: i32,
	ended_at_attr: i32,
	created_from_snap: bool,
) {
	assert(g_imnodes.current_scope == .None)

	created = .LinkCreated in g_imnodes.ui_state

	if created {
		editor := editor_context_get()
		start_idx := editor.click_interaction.link_creation.start_pin_idx
		end_idx := editor.click_interaction.link_creation.end_pin_idx.?
		start_pin := &editor.pins.pool[start_idx]
		start_node := &editor.nodes.pool[start_pin.parent_node_idx]
		end_pin := &editor.pins.pool[end_idx]
		end_node := &editor.nodes.pool[end_pin.parent_node_idx]

		if start_pin.type == .Output {
			started_at_attr = start_pin.id
			started_at_node = start_node.id
			ended_at_attr = end_pin.id
			ended_at_node = end_node.id
		} else {
			started_at_attr = end_pin.id
			started_at_node = end_node.id
			ended_at_attr = start_pin.id
			ended_at_node = start_node.id
		}

		created_from_snap = editor.click_interaction.type == .LinkCreation
	}

	return
}

is_link_destroyed :: proc() -> (destroyed: bool, link_id: i32) {
	assert(g_imnodes.current_scope == .None)

	destroyed = g_imnodes.deleted_link_idx != nil
	if destroyed {
		editor := editor_context_get()
		link_idx := g_imnodes.deleted_link_idx.?
		link_id = editor.links.pool[link_idx].id
	}

	return
}

// ---------------------------------------------------------------------------
// [SECTION] INI serialization
//
// sscanf is replaced by small prefix scanners over string slices +
// core:strconv; the INI format itself is preserved exactly
// ([node.<id>] origin=x,y, [editor] panning=x,y).
// ---------------------------------------------------------------------------

// Parses a leading C sscanf("%i")-style integer: optional whitespace, sign and
// decimal digits; stops at the first non-digit.
@(private)
parse_sscanf_int :: proc(s: string) -> (value: int, consumed: int, ok: bool) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') {
		i += 1
	}
	start := i
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i += 1
	}
	digits_start := i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	if i == digits_start {
		return 0, 0, false
	}
	value, _ = strconv.parse_int(s[start:i])
	return value, i, true
}

// Parses a leading C sscanf("%f")-style float: optional whitespace, sign,
// digits with optional fraction and exponent; stops at the first char that is
// not part of the float.
@(private)
parse_sscanf_float :: proc(s: string) -> (value: f32, consumed: int, ok: bool) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') {
		i += 1
	}
	start := i
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i += 1
	}
	digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
		digits += 1
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
			digits += 1
		}
	}
	if digits == 0 {
		return 0, 0, false
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j += 1
		}
		exp_start := j
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j += 1
		}
		if j > exp_start {
			i = j
		}
	}
	v, _ := strconv.parse_f64(s[start:i])
	return f32(v), i, true
}

@(private)
node_line_handler :: proc(editor: ^Editor_Context, line: string) {
	if strings.has_prefix(line, "[node.") {
		id, _, ok := parse_sscanf_int(line[len("[node."):])
		if ok {
			node_idx := object_pool_find_or_create_index(&editor.nodes, i32(id))
			g_imnodes.current_node_idx = node_idx
			node := &editor.nodes.pool[node_idx]
			node.id = i32(id)
		}
	} else if strings.has_prefix(line, "origin=") {
		rest := line[len("origin="):]
		x, cx, okx := parse_sscanf_int(rest)
		if !okx || cx >= len(rest) || rest[cx] != ',' {
			return
		}
		y, _, oky := parse_sscanf_int(rest[cx + 1:])
		if !oky {
			return
		}
		node := &editor.nodes.pool[g_imnodes.current_node_idx]
		node.origin = snap_origin_to_grid(Vec2{f32(x), f32(y)})
	}
}

@(private)
editor_line_handler :: proc(editor: ^Editor_Context, line: string) {
	// C++ ignores the sscanf return value, so a partially matching line still
	// assigns whatever was parsed.
	if strings.has_prefix(line, "zoom=") {
		// imnodes-odin extension. Node origins live in grid space, so loading
		// the zoom needs no origin fixups — just the raw value.
		if z, _, ok := parse_sscanf_float(line[len("zoom="):]); ok {
			editor.zoom = clamp(z, ZOOM_MIN, ZOOM_MAX)
		}
		return
	}
	if !strings.has_prefix(line, "panning=") {
		return
	}
	rest := line[len("panning="):]
	x, cx, okx := parse_sscanf_float(rest)
	if !okx {
		return
	}
	editor.panning.x = x
	if cx >= len(rest) || rest[cx] != ',' {
		return
	}
	y, _, oky := parse_sscanf_float(rest[cx + 1:])
	if !oky {
		return
	}
	editor.panning.y = y
}

save_current_editor_state_to_ini_string :: proc() -> string {
	return save_editor_state_to_ini_string(editor_context_get())
}

// The returned string is built with context.temp_allocator: clone it if it
// must live past the current frame (see README).
save_editor_state_to_ini_string :: proc(editor_ptr: ^Editor_Context) -> string {
	assert(editor_ptr != nil)
	editor := editor_ptr

	// The C++ keeps an ImGuiTextBuffer on the context; here we use a local
	// strings.Builder on the temp allocator.
	buf: strings.Builder
	// TODO: check to make sure that the estimate is the upper bound of element
	strings.builder_init(&buf, 0, 64*len(editor.nodes.pool), context.temp_allocator)

	// C++ writes %f (6 decimals); the values are fractional (pan gestures,
	// zoom). zoom= is an imnodes-odin extension, ignored by the upstream
	// parser (it stops at unknown lines, like this one does).
	fmt.sbprintf(
		&buf,
		"[editor]\npanning=%.6f,%.6f\nzoom=%.6f\n",
		editor.panning.x,
		editor.panning.y,
		editor.zoom,
	)

	for i in 0 ..< len(editor.nodes.pool) {
		if editor.nodes.in_use[i] {
			node := &editor.nodes.pool[i]
			fmt.sbprintf(&buf, "\n[node.%d]\n", node.id)
			fmt.sbprintf(&buf, "origin=%.6f,%.6f\n", node.origin.x, node.origin.y)
		}
	}

	return strings.to_string(buf)
}

load_current_editor_state_from_ini_string :: proc(data: string) {
	load_editor_state_from_ini_string(editor_context_get(), data)
}

load_editor_state_from_ini_string :: proc(editor_ptr: ^Editor_Context, data: string) {
	if len(data) == 0 {
		return
	}

	editor := editor_ptr
	if editor == nil {
		editor = editor_context_get()
	}

	line_handler: proc(editor: ^Editor_Context, line: string)
	line_handler = nil

	i := 0
	for i < len(data) {
		for i < len(data) && (data[i] == '\n' || data[i] == '\r') {
			i += 1
		}
		if i >= len(data) {
			break
		}
		line_start := i
		for i < len(data) && data[i] != '\n' && data[i] != '\r' {
			i += 1
		}
		line := data[line_start:i]

		if len(line) == 0 || line[0] == ';' {
			continue
		}

		// The C++ nulls the trailing ']' of a section header before invoking
		// the line handler; handler_line mirrors that.
		handler_line := line
		if line[0] == '[' && line[len(line) - 1] == ']' {
			inner := line[1:len(line) - 1]
			if strings.has_prefix(inner, "node") {
				line_handler = node_line_handler
			} else if inner == "editor" {
				line_handler = editor_line_handler
			}
			handler_line = line[:len(line) - 1]
		}

		if line_handler != nil {
			line_handler(editor, handler_line)
		}
	}
}

save_current_editor_state_to_ini_file :: proc(file_name: string) {
	save_editor_state_to_ini_file(editor_context_get(), file_name)
}

save_editor_state_to_ini_file :: proc(editor: ^Editor_Context, file_name: string) {
	data := save_editor_state_to_ini_string(editor)
	// C++ silently returns when the file cannot be opened.
	_ = os.write_entire_file(file_name, transmute([]byte)data)
}

load_current_editor_state_from_ini_file :: proc(file_name: string) {
	load_editor_state_from_ini_file(editor_context_get(), file_name)
}

load_editor_state_from_ini_file :: proc(editor: ^Editor_Context, file_name: string) {
	// Read into the temp allocator; freeing is implicit at frame end.
	data, err := os.read_entire_file(file_name, context.temp_allocator)
	if err != nil {
		return
	}

	load_editor_state_from_ini_string(editor, string(data))
}
