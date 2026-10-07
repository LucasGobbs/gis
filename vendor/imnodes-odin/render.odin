// imnodes-odin — port of imnodes.cpp [SECTION] render helpers (lines
// 1302-1692) and [SECTION] minimap (lines 1713-1954).
package imnodes

import "core:log"
import "core:math"
import "core:slice"

import im "../odin-imgui"

// ---------------------------------------------------------------------------
// [SECTION] render helpers
// ---------------------------------------------------------------------------

get_item_rect :: proc() -> Rect {
	return {im.GetItemRectMin(), im.GetItemRectMax()}
}

get_node_title_bar_origin :: proc "contextless" (node: ^Node_Data) -> Vec2 {
	return v2_add(node.origin, node.layout_style.padding)
}

get_node_content_origin :: proc(node: ^Node_Data) -> Vec2 {
	// title_bar_content_rect is measured in (scaled) screen pixels while the
	// result feeds grid-space layout, so the title height is unscaled back.
	zoom := editor_context_get().zoom
	title_bar_height := Vec2 {
		0.0,
		rect_height(node.title_bar_content_rect) / zoom + 2.0 * node.layout_style.padding.y,
	}
	return v2_add(v2_add(node.origin, title_bar_height), node.layout_style.padding)
}

get_node_title_rect :: proc(node: ^Node_Data) -> Rect {
	// Screen-space rect: padding (grid units) scales into pixels here.
	zoom := editor_context_get().zoom
	expanded_title_rect := rect_expand_vec(
		node.title_bar_content_rect,
		v2_scale(node.layout_style.padding, zoom),
	)

	return Rect {
		min = expanded_title_rect.min,
		max = v2_add(
			v2_add(expanded_title_rect.min, {rect_width(node.rect), 0.0}),
			{0.0, rect_height(expanded_title_rect)},
		),
	}
}

draw_grid :: proc(editor: ^Editor_Context, canvas_size: Vec2) {
	offset := editor.panning
	line_color := g_imnodes.style.colors[.GridLine]
	line_color_prim := g_imnodes.style.colors[.GridLinePrimary]
	draw_primary := .GridLinesPrimary in g_imnodes.style.flags
	// imnodes-odin zoom: the grid spacing lives in grid space, so the on-screen
	// spacing scales with the zoom factor.
	spacing := g_imnodes.style.grid_spacing * editor.zoom

	for x := math.mod(offset.x, spacing);
	    x < canvas_size.x;
	    x += spacing {
		im.DrawList_AddLine(
			g_imnodes.canvas_draw_list,
			editor_space_to_screen_space({x, 0.0}),
			editor_space_to_screen_space({x, canvas_size.y}),
			(offset.x - x == 0.0 && draw_primary) ? line_color_prim : line_color,
		)
	}

	for y := math.mod(offset.y, spacing);
	    y < canvas_size.y;
	    y += spacing {
		im.DrawList_AddLine(
			g_imnodes.canvas_draw_list,
			editor_space_to_screen_space({0.0, y}),
			editor_space_to_screen_space({canvas_size.x, y}),
			(offset.y - y == 0.0 && draw_primary) ? line_color_prim : line_color,
		)
	}
}

Quad_Offsets :: struct {
	top_left, bottom_left, bottom_right, top_right: Vec2,
}

calculate_quad_offsets :: proc "contextless" (side_length: f32) -> Quad_Offsets {
	half_side := 0.5 * side_length

	offset: Quad_Offsets

	offset.top_left = {-half_side, half_side}
	offset.bottom_left = {-half_side, -half_side}
	offset.bottom_right = {half_side, -half_side}
	offset.top_right = {half_side, half_side}

	return offset
}

Triangle_Offsets :: struct {
	top_left, bottom_left, right: Vec2,
}

calculate_triangle_offsets :: proc "contextless" (side_length: f32) -> Triangle_Offsets {
	// Calculates the Vec2 offsets from an equilateral triangle's midpoint to
	// its vertices. Here is how the left_offset and right_offset are
	// calculated.
	//
	// For an equilateral triangle of side length s, the
	// triangle's height, h, is h = s * sqrt(3) / 2.
	//
	// The length from the base to the midpoint is (1 / 3) * h. The length from
	// the midpoint to the triangle vertex is (2 / 3) * h.
	sqrt_3 := math.sqrt(f32(3.0))
	left_offset := -0.1666666666667 * sqrt_3 * side_length
	right_offset := 0.333333333333 * sqrt_3 * side_length
	vertical_offset := 0.5 * side_length

	offset: Triangle_Offsets
	offset.top_left = {left_offset, vertical_offset}
	offset.bottom_left = {left_offset, -vertical_offset}
	offset.right = {right_offset, 0.0}

	return offset
}

draw_pin_shape :: proc(pin_pos: Vec2, pin: ^Pin_Data, pin_color: u32) {
	CIRCLE_NUM_SEGMENTS :: 8

	// imnodes-odin zoom: pin geometry lives on screen, so it scales with zoom.
	zoom := editor_context_get().zoom
	circle_radius := g_imnodes.style.pin_circle_radius * zoom
	line_thickness := g_imnodes.style.pin_line_thickness * zoom
	quad_side := g_imnodes.style.pin_quad_side_length * zoom
	triangle_side := g_imnodes.style.pin_triangle_side_length * zoom

	switch pin.shape {
	case .Circle:
		im.DrawList_AddCircle(
			g_imnodes.canvas_draw_list,
			pin_pos,
			circle_radius,
			pin_color,
			CIRCLE_NUM_SEGMENTS,
			line_thickness,
		)
	case .CircleFilled:
		im.DrawList_AddCircleFilled(
			g_imnodes.canvas_draw_list,
			pin_pos,
			circle_radius,
			pin_color,
			CIRCLE_NUM_SEGMENTS,
		)
	case .Quad:
		offset := calculate_quad_offsets(quad_side)
		im.DrawList_AddQuad(
			g_imnodes.canvas_draw_list,
			v2_add(pin_pos, offset.top_left),
			v2_add(pin_pos, offset.bottom_left),
			v2_add(pin_pos, offset.bottom_right),
			v2_add(pin_pos, offset.top_right),
			pin_color,
			line_thickness,
		)
	case .QuadFilled:
		offset := calculate_quad_offsets(quad_side)
		im.DrawList_AddQuadFilled(
			g_imnodes.canvas_draw_list,
			v2_add(pin_pos, offset.top_left),
			v2_add(pin_pos, offset.bottom_left),
			v2_add(pin_pos, offset.bottom_right),
			v2_add(pin_pos, offset.top_right),
			pin_color,
		)
	case .Triangle:
		offset := calculate_triangle_offsets(triangle_side)
		im.DrawList_AddTriangle(
			g_imnodes.canvas_draw_list,
			v2_add(pin_pos, offset.top_left),
			v2_add(pin_pos, offset.bottom_left),
			v2_add(pin_pos, offset.right),
			pin_color,
			// NOTE: for some weird reason, the line drawn by AddTriangle is
			// much thinner than the lines drawn by AddCircle or AddQuad.
			// Multiplying the line thickness by two seemed to solve the
			// problem at a few different thickness values.
			2.0 * line_thickness,
		)
	case .TriangleFilled:
		offset := calculate_triangle_offsets(triangle_side)
		im.DrawList_AddTriangleFilled(
			g_imnodes.canvas_draw_list,
			v2_add(pin_pos, offset.top_left),
			v2_add(pin_pos, offset.bottom_left),
			v2_add(pin_pos, offset.right),
			pin_color,
		)
	case:
		internal_error("draw_pin_shape: invalid pin shape %d", int(pin.shape))
	}
}

draw_pin :: proc(editor: ^Editor_Context, pin_idx: int) {
	pin := &editor.pins.pool[pin_idx]

	pin.pos = get_screen_space_pin_coordinates_pin(editor, pin^)

	pin_color := pin.color_style.background

	if hovered, ok := g_imnodes.hovered_pin_idx.?; ok && hovered == pin_idx {
		pin_color = pin.color_style.hovered
	}

	draw_pin_shape(pin.pos, pin, pin_color)
}

draw_node :: proc(editor: ^Editor_Context, node_idx: int) {
	node := &editor.nodes.pool[node_idx]
	im.SetCursorPos(grid_space_to_editor_space(editor, node.origin))

	hovered, hovered_ok := g_imnodes.hovered_node_idx.?
	node_hovered :=
		hovered_ok && hovered == node_idx && editor.click_interaction.type != .BoxSelection

	node_background := node.color_style.background
	titlebar_background := node.color_style.titlebar

	if slice.contains(editor.selected_node_indices[:], node_idx) {
		node_background = node.color_style.background_selected
		titlebar_background = node.color_style.titlebar_selected
	} else if node_hovered {
		node_background = node.color_style.background_hovered
		titlebar_background = node.color_style.titlebar_hovered
	}

	{
		// imnodes-odin zoom: rect sizes are in screen pixels, so the style
		// lengths used for drawing scale with zoom.
		zoom := editor.zoom
		corner_rounding := node.layout_style.corner_rounding * zoom
		border_thickness := node.layout_style.border_thickness * zoom

		// node base
		im.DrawList_AddRectFilled(
			g_imnodes.canvas_draw_list,
			node.rect.min,
			node.rect.max,
			node_background,
			corner_rounding,
		)

		// title bar:
		if rect_height(node.title_bar_content_rect) > 0.0 {
			title_bar_rect := get_node_title_rect(node)

			im.DrawList_AddRectFilled(
				g_imnodes.canvas_draw_list,
				title_bar_rect.min,
				title_bar_rect.max,
				titlebar_background,
				corner_rounding,
				im.DRAW_FLAGS_ROUND_CORNERS_TOP,
			)
		}

		if .NodeOutline in g_imnodes.style.flags {
			im.DrawList_AddRect(
				g_imnodes.canvas_draw_list,
				node.rect.min,
				node.rect.max,
				node.color_style.outline,
				corner_rounding,
				border_thickness,
				im.DRAW_FLAGS_ROUND_CORNERS_ALL,
			)
		}
	}

	for i in 0 ..< len(node.pin_indices) {
		draw_pin(editor, node.pin_indices[i])
	}

	if node_hovered {
		g_imnodes.hovered_node_idx = node_idx
	}
}

draw_link :: proc(editor: ^Editor_Context, link_idx: int) {
	link := &editor.links.pool[link_idx]
	start_pin := &editor.pins.pool[link.start_pin_idx]
	end_pin := &editor.pins.pool[link.end_pin_idx]

	cubic_bezier := get_cubic_bezier(start_pin^, end_pin^, start_pin.type)
	num_segments := cubic_bezier_num_segments(
		cubic_bezier,
		g_imnodes.style.link_line_segments_per_length,
	)

	hovered, hovered_ok := g_imnodes.hovered_link_idx.?
	link_hovered :=
		hovered_ok && hovered == link_idx && editor.click_interaction.type != .BoxSelection

	if link_hovered {
		g_imnodes.hovered_link_idx = link_idx
	}

	// It's possible for a link to be deleted in begin_link_interaction. A user
	// may detach a link, resulting in the link wire snapping to the mouse
	// position.
	//
	// In other words, skip rendering the link if it was deleted.
	if deleted, ok := g_imnodes.deleted_link_idx.?; ok && deleted == link_idx {
		return
	}

	link_color := link.color_style.base
	if slice.contains(editor.selected_link_indices[:], link_idx) {
		link_color = link.color_style.selected
	} else if link_hovered {
		link_color = link.color_style.hovered
	}

	im.DrawList_AddBezierCubic(
		g_imnodes.canvas_draw_list,
		cubic_bezier.p0,
		cubic_bezier.p1,
		cubic_bezier.p2,
		cubic_bezier.p3,
		link_color,
		g_imnodes.style.link_thickness * editor.zoom, // imnodes-odin zoom
		i32(num_segments),
	)
}

begin_pin_attribute :: proc(id: i32, type: Attribute_Type, shape: Pin_Shape, node_idx: int) {
	// Make sure to call begin_node() before calling
	// begin_*_attribute()
	assert(g_imnodes.current_scope == .Node)
	g_imnodes.current_scope = .Attribute

	editor := editor_context_get()
	node := &editor.nodes.pool[node_idx]
	content_x := grid_space_to_editor_space(editor, get_node_content_origin(node)).x
	im.SetCursorPosX(content_x)

	im.BeginGroup()
	im.PushIDInt(id)

	g_imnodes.current_attribute_id = id
	pin_idx := object_pool_find_or_create_index(&editor.pins, id)
	g_imnodes.current_pin_idx = pin_idx
	pin := &editor.pins.pool[pin_idx]
	pin.id = id
	pin.parent_node_idx = node_idx
	pin.type = type
	pin.shape = shape
	pin.flags = g_imnodes.current_attribute_flags
	pin.color_style.background = g_imnodes.style.colors[.Pin]
	pin.color_style.hovered = g_imnodes.style.colors[.PinHovered]
}

end_pin_attribute :: proc() {
	assert(g_imnodes.current_scope == .Attribute)
	g_imnodes.current_scope = .Node

	im.PopID()
	im.EndGroup()

	if im.IsItemActive() {
		g_imnodes.active_attribute = true
		g_imnodes.active_attribute_id = g_imnodes.current_attribute_id
	}

	editor := editor_context_get()
	pin := &editor.pins.pool[g_imnodes.current_pin_idx]
	node := &editor.nodes.pool[g_imnodes.current_node_idx]
	pin.attribute_rect = get_item_rect()
	append(&node.pin_indices, g_imnodes.current_pin_idx)
}

// ---------------------------------------------------------------------------
// [SECTION] minimap
// ---------------------------------------------------------------------------

is_mini_map_active :: proc() -> bool {
	editor := editor_context_get()
	return editor.mini_map_enabled && editor.mini_map_size_fraction > 0.0
}

is_mini_map_hovered :: proc() -> bool {
	editor := editor_context_get()
	return(
		is_mini_map_active() &&
		im.IsMouseHoveringRect(
			editor.mini_map_rect_screen_space.min,
			editor.mini_map_rect_screen_space.max,
		) \
	)
}

// Replaces ImRect::IsInverted (not part of the Rect helpers in types.odin).
rect_is_inverted :: proc "contextless" (r: Rect) -> bool {
	return r.min.x > r.max.x || r.min.y > r.max.y
}

calc_mini_map_layout :: proc() {
	editor := editor_context_get()
	offset := g_imnodes.style.mini_map_offset
	border := g_imnodes.style.mini_map_padding
	editor_rect := g_imnodes.canvas_rect_screen_space

	// Compute the size of the mini-map area
	mini_map_size: Vec2
	mini_map_scaling: f32
	{
		max_size := v2_floor(
			v2_sub(
				v2_scale(rect_size(editor_rect), editor.mini_map_size_fraction),
				v2_scale(border, 2.0),
			),
		)
		max_size_aspect_ratio := max_size.x / max_size.y
		grid_content_size := rect_is_inverted(editor.grid_content_bounds) \
			? max_size \
			: v2_floor(rect_size(editor.grid_content_bounds))
		grid_content_aspect_ratio := grid_content_size.x / grid_content_size.y
		mini_map_size = v2_floor(
			grid_content_aspect_ratio > max_size_aspect_ratio \
			? Vec2{max_size.x, max_size.x / grid_content_aspect_ratio} \
			: Vec2{max_size.y * grid_content_aspect_ratio, max_size.y},
		)
		mini_map_scaling = mini_map_size.x / grid_content_size.x
	}

	// Compute location of the mini-map
	mini_map_pos: Vec2
	{
		align: Vec2

		switch editor.mini_map_location {
		case .BottomRight:
			align.x = 1.0
			align.y = 1.0
		case .BottomLeft:
			align.x = 0.0
			align.y = 1.0
		case .TopRight:
			align.x = 1.0
			align.y = 0.0
		case .TopLeft: // [[fallthrough]]
			align.x = 0.0
			align.y = 0.0
		case:
			align.x = 0.0
			align.y = 0.0
		}

		top_left_pos := v2_add(v2_add(editor_rect.min, offset), border)
		bottom_right_pos := v2_sub(v2_sub(v2_sub(editor_rect.max, offset), border), mini_map_size)
		// ImLerp with a Vec2 interpolant is component-wise.
		mini_map_pos = v2_floor(
			{
				math.lerp(top_left_pos.x, bottom_right_pos.x, align.x),
				math.lerp(top_left_pos.y, bottom_right_pos.y, align.y),
			},
		)
	}

	editor.mini_map_rect_screen_space = Rect {
		min = v2_sub(mini_map_pos, border),
		max = v2_add(v2_add(mini_map_pos, mini_map_size), border),
	}
	editor.mini_map_content_screen_space = Rect {
		min = mini_map_pos,
		max = v2_add(mini_map_pos, mini_map_size),
	}
	editor.mini_map_scaling = mini_map_scaling
}

mini_map_draw_node :: proc(editor: ^Editor_Context, node_idx: int) {
	node := &editor.nodes.pool[node_idx]

	node_rect := screen_space_to_mini_map_space(editor, node.rect)

	// Round to near whole pixel value for corner-rounding to prevent visual glitches
	mini_map_node_rounding := math.floor(node.layout_style.corner_rounding * editor.mini_map_scaling)

	mini_map_node_background: u32

	if editor.click_interaction.type == .None &&
	   im.IsMouseHoveringRect(node_rect.min, node_rect.max) {
		mini_map_node_background = g_imnodes.style.colors[.MiniMapNodeBackgroundHovered]

		// Run user callback when hovering a mini-map node
		if editor.mini_map_node_hovering_callback != nil {
			editor.mini_map_node_hovering_callback(
				node.id,
				editor.mini_map_node_hovering_callback_user_data,
			)
		}
	} else if slice.contains(editor.selected_node_indices[:], node_idx) {
		mini_map_node_background = g_imnodes.style.colors[.MiniMapNodeBackgroundSelected]
	} else {
		mini_map_node_background = g_imnodes.style.colors[.MiniMapNodeBackground]
	}

	mini_map_node_outline := g_imnodes.style.colors[.MiniMapNodeOutline]

	im.DrawList_AddRectFilled(
		g_imnodes.canvas_draw_list,
		node_rect.min,
		node_rect.max,
		mini_map_node_background,
		mini_map_node_rounding,
	)

	im.DrawList_AddRect(
		g_imnodes.canvas_draw_list,
		node_rect.min,
		node_rect.max,
		mini_map_node_outline,
		mini_map_node_rounding,
	)
}

mini_map_draw_link :: proc(editor: ^Editor_Context, link_idx: int) {
	link := &editor.links.pool[link_idx]
	start_pin := &editor.pins.pool[link.start_pin_idx]
	end_pin := &editor.pins.pool[link.end_pin_idx]

	cubic_bezier := get_cubic_bezier(
		screen_space_to_mini_map_space(editor, start_pin.pos),
		screen_space_to_mini_map_space(editor, end_pin.pos),
		start_pin.type,
		g_imnodes.style.link_line_segments_per_length / editor.mini_map_scaling,
	)
	num_segments := cubic_bezier_num_segments(
		cubic_bezier,
		g_imnodes.style.link_line_segments_per_length / editor.mini_map_scaling,
	)

	// It's possible for a link to be deleted in begin_link_interaction. A user
	// may detach a link, resulting in the link wire snapping to the mouse
	// position.
	//
	// In other words, skip rendering the link if it was deleted.
	if deleted, ok := g_imnodes.deleted_link_idx.?; ok && deleted == link_idx {
		return
	}

	link_color :=
		g_imnodes.style.colors[slice.contains(editor.selected_link_indices[:], link_idx) \
			? Col.MiniMapLinkSelected \
			: Col.MiniMapLink]

	im.DrawList_AddBezierCubic(
		g_imnodes.canvas_draw_list,
		cubic_bezier.p0,
		cubic_bezier.p1,
		cubic_bezier.p2,
		cubic_bezier.p3,
		link_color,
		g_imnodes.style.link_thickness * editor.mini_map_scaling,
		i32(num_segments),
	)
}

mini_map_update :: proc() {
	editor := editor_context_get()

	mini_map_background: u32

	if is_mini_map_hovered() {
		mini_map_background = g_imnodes.style.colors[.MiniMapBackgroundHovered]
	} else {
		mini_map_background = g_imnodes.style.colors[.MiniMapBackground]
	}

	// Create a child window below the mini-map, so it blocks all mouse interaction on canvas.
	im.SetCursorScreenPos(editor.mini_map_rect_screen_space.min)
	im.BeginChild("minimap", rect_size(editor.mini_map_rect_screen_space), {}, {.NoBackground})

	mini_map_rect := editor.mini_map_rect_screen_space

	// Draw minimap background and border
	im.DrawList_AddRectFilled(
		g_imnodes.canvas_draw_list,
		mini_map_rect.min,
		mini_map_rect.max,
		mini_map_background,
	)

	im.DrawList_AddRect(
		g_imnodes.canvas_draw_list,
		mini_map_rect.min,
		mini_map_rect.max,
		g_imnodes.style.colors[.MiniMapOutline],
	)

	// Clip draw list items to mini-map rect (after drawing background/outline)
	// intersect with editor clip-rect
	im.DrawList_PushClipRect(g_imnodes.canvas_draw_list, mini_map_rect.min, mini_map_rect.max, true)

	// Draw links first so they appear under nodes, and we can use the same draw channel
	for link_idx in 0 ..< len(editor.links.pool) {
		if editor.links.in_use[link_idx] {
			mini_map_draw_link(editor, link_idx)
		}
	}

	for node_idx in 0 ..< len(editor.nodes.pool) {
		if editor.nodes.in_use[node_idx] {
			mini_map_draw_node(editor, node_idx)
		}
	}

	// Draw editor canvas rect inside mini-map
	{
		canvas_color := g_imnodes.style.colors[.MiniMapCanvas]
		outline_color := g_imnodes.style.colors[.MiniMapCanvasOutline]
		rect := screen_space_to_mini_map_space(editor, g_imnodes.canvas_rect_screen_space)

		im.DrawList_AddRectFilled(g_imnodes.canvas_draw_list, rect.min, rect.max, canvas_color)
		im.DrawList_AddRect(g_imnodes.canvas_draw_list, rect.min, rect.max, outline_color)
	}

	// Have to pop mini-map clip rect
	im.DrawList_PopClipRect(g_imnodes.canvas_draw_list)

	mini_map_is_hovered := im.IsWindowHovered()

	im.EndChild()

	center_on_click :=
		mini_map_is_hovered &&
		im.IsMouseDown(.Left) &&
		editor.click_interaction.type == .None &&
		len(g_imnodes.node_idx_submission_order) > 0
	if center_on_click {
		target := mini_map_space_to_grid_space(editor, im.GetMousePos())
		center := v2_scale(rect_size(g_imnodes.canvas_rect_screen_space), 0.5)
		// editor space = grid * zoom + panning: keep target grid-invariant by
		// solving for panning (imnodes-odin zoom).
		editor.panning = v2_floor(v2_sub(center, v2_scale(target, editor.zoom)))
	}

	// Reset callback info after use
	editor.mini_map_node_hovering_callback = nil
	editor.mini_map_node_hovering_callback_user_data = nil
}
