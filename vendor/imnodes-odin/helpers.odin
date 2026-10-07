// imnodes-odin — port of Nelarius/imnodes (C++, MIT) to Odin.
//
// Internal helpers: bezier curve helpers, coordinate space conversion
// helpers, draw list helper and ui state logic.
//
// Original C++: vendor/imnodes/imnodes.cpp lines 36–1301.
//
// Adaptations vs. the C++ source:
//  * ImLineClosestPoint (imgui_internal.h) is not exposed by the imgui
//    binding, so it is ported here as im_line_closest_point.
//  * The C++ CubicBezier struct carries a NumSegments field; Cubic_Bezier in
//    types.odin does not. cubic_bezier_num_segments recomputes it from the
//    curve endpoints with the identical formula.
//  * ImVector growth (memcpy + ImGui::MemAlloc/MemFree) is mirrored with
//    im.MemAlloc/im.MemFree so allocations stay paired with the imgui
//    allocator (imgui later frees these buffers in ClearFreeMemory).
package imnodes

import "core:log"
import "core:math"

import im "../odin-imgui"

// ---------------------------------------------------------------------------
// [SECTION] bezier curve helpers
// ---------------------------------------------------------------------------

eval_cubic_bezier :: proc {
	eval_cubic_bezier_points,
	eval_cubic_bezier_bezier,
}

// B(t) = (1-t)**3 p0 + 3(1 - t)**2 t P1 + 3(1-t)t**2 P2 + t**3 P3
eval_cubic_bezier_points :: proc "contextless" (p0, p1, p2, p3: Vec2, t: f32) -> Vec2 {
	u := 1.0 - t
	b0 := u * u * u
	b1 := 3 * u * u * t
	b2 := 3 * u * t * t
	b3 := t * t * t
	return {
		b0 * p0.x + b1 * p1.x + b2 * p2.x + b3 * p3.x,
		b0 * p0.y + b1 * p1.y + b2 * p2.y + b3 * p3.y,
	}
}

eval_cubic_bezier_bezier :: proc "contextless" (cb: Cubic_Bezier, t: f32) -> Vec2 {
	return eval_cubic_bezier_points(cb.p0, cb.p1, cb.p2, cb.p3, t)
}

// Port of ImLineClosestPoint from imgui_internal.h (not exposed by the binding).
im_line_closest_point :: proc "contextless" (a, b, p: Vec2) -> Vec2 {
	ap := v2_sub(p, a)
	ab_dir := v2_sub(b, a)
	dot := ap.x * ab_dir.x + ap.y * ab_dir.y
	if dot < 0.0 {
		return a
	}
	ab_len_sqr := v2_length_sqr(ab_dir)
	if dot > ab_len_sqr {
		return b
	}
	return v2_add(a, v2_scale(ab_dir, dot / ab_len_sqr))
}

// The C++ CubicBezier struct stores NumSegments, computed in GetCubicBezier as
// max(int(link_length * line_segments_per_length), 1) with
// link_length = length(P3 - P0). Recompute it here with the identical formula.
cubic_bezier_num_segments :: proc(cb: Cubic_Bezier, line_segments_per_length: f32) -> int {
	link_length := math.sqrt(v2_length_sqr(v2_sub(cb.p3, cb.p0)))
	return max(int(link_length * line_segments_per_length), 1)
}

// Calculates the closest point along each bezier curve segment.
get_closest_point_on_cubic_bezier :: proc(num_segments: int, p: Vec2, cb: Cubic_Bezier) -> Vec2 {
	assert(num_segments > 0)
	p_last := cb.p0
	p_closest: Vec2
	p_closest_dist := max(f32)
	t_step := 1.0 / f32(num_segments)
	for i in 1 ..= num_segments {
		p_current := eval_cubic_bezier(cb, t_step * f32(i))
		p_line := im_line_closest_point(p_last, p_current, p)
		dist := v2_length_sqr(v2_sub(p, p_line))
		if dist < p_closest_dist {
			p_closest = p_line
			p_closest_dist = dist
		}
		p_last = p_current
	}
	return p_closest
}

get_distance_to_cubic_bezier :: proc(pos: Vec2, cubic_bezier: Cubic_Bezier, num_segments: int) -> f32 {
	point_on_curve := get_closest_point_on_cubic_bezier(num_segments, pos, cubic_bezier)

	to_curve := v2_sub(point_on_curve, pos)
	return math.sqrt(v2_length_sqr(to_curve))
}

get_containing_rect_for_cubic_bezier :: proc(cb: Cubic_Bezier) -> Rect {
	rmin := Vec2{min(cb.p0.x, cb.p3.x), min(cb.p0.y, cb.p3.y)}
	rmax := Vec2{max(cb.p0.x, cb.p3.x), max(cb.p0.y, cb.p3.y)}

	hover_distance := g_imnodes.style.link_hover_distance * editor_context_get().zoom

	r := Rect{rmin, rmax}
	r = rect_add_point(r, cb.p1)
	r = rect_add_point(r, cb.p2)
	r = rect_expand_vec(r, {hover_distance, hover_distance})

	return r
}

get_cubic_bezier :: proc {
	get_cubic_bezier_points,
	get_cubic_bezier_pins,
}

get_cubic_bezier_points :: proc(
	start, end: Vec2,
	start_type: Attribute_Type,
	line_segments_per_length: f32,
) -> Cubic_Bezier {
	if start_type != .Input && start_type != .Output {
		internal_error("get_cubic_bezier: invalid attribute type %d", int(start_type))
	}
	start, end := start, end
	if start_type == .Input {
		start, end = end, start
	}

	link_length := math.sqrt(v2_length_sqr(v2_sub(end, start)))
	offset := Vec2{0.25 * link_length, 0}
	cubic_bezier: Cubic_Bezier
	cubic_bezier.p0 = start
	cubic_bezier.p1 = v2_add(start, offset)
	cubic_bezier.p2 = v2_sub(end, offset)
	cubic_bezier.p3 = end
	return cubic_bezier
}

// Convenience overload: positions from the pins, segments-per-length from the
// current style (all C++ call sites pass GImNodes->Style.LinkLineSegmentsPerLength).
get_cubic_bezier_pins :: proc(pin_start, pin_end: Pin_Data, start_type: Attribute_Type) -> Cubic_Bezier {
	return get_cubic_bezier_points(
		pin_start.pos,
		pin_end.pos,
		start_type,
		g_imnodes.style.link_line_segments_per_length,
	)
}

eval_implicit_line_eq :: proc "contextless" (p1, p2, p: Vec2) -> f32 {
	return (p2.y - p1.y) * p.x + (p1.x - p2.x) * p.y + (p2.x * p1.y - p1.x * p2.y)
}

sign_f32 :: proc "contextless" (val: f32) -> i32 {
	return i32(val > 0.0) - i32(val < 0.0)
}

rectangle_overlaps_line_segment :: proc "contextless" (rect: Rect, p1, p2: Vec2) -> bool {
	// Trivial case: rectangle contains an endpoint
	if rect_contains_point(rect, p1) || rect_contains_point(rect, p2) {
		return true
	}

	// Flip rectangle if necessary
	flip_rect := rect

	if flip_rect.min.x > flip_rect.max.x {
		flip_rect.min.x, flip_rect.max.x = flip_rect.max.x, flip_rect.min.x
	}

	if flip_rect.min.y > flip_rect.max.y {
		flip_rect.min.y, flip_rect.max.y = flip_rect.max.y, flip_rect.min.y
	}

	// Trivial case: line segment lies to one particular side of rectangle
	if (p1.x < flip_rect.min.x && p2.x < flip_rect.min.x) ||
	   (p1.x > flip_rect.max.x && p2.x > flip_rect.max.x) ||
	   (p1.y < flip_rect.min.y && p2.y < flip_rect.min.y) ||
	   (p1.y > flip_rect.max.y && p2.y > flip_rect.max.y) {
		return false
	}

	corner_signs := [4]i32 {
		sign_f32(eval_implicit_line_eq(p1, p2, flip_rect.min)),
		sign_f32(eval_implicit_line_eq(p1, p2, {flip_rect.max.x, flip_rect.min.y})),
		sign_f32(eval_implicit_line_eq(p1, p2, {flip_rect.min.x, flip_rect.max.y})),
		sign_f32(eval_implicit_line_eq(p1, p2, flip_rect.max)),
	}

	sum := i32(0)
	sum_abs := i32(0)

	for corner_sign in corner_signs {
		sum += corner_sign
		sum_abs += abs(corner_sign)
	}

	// At least one corner of rectangle lies on a different side of line segment
	return abs(sum) != sum_abs
}

rectangle_overlaps_bezier :: proc(rectangle: Rect, cubic_bezier: Cubic_Bezier) -> bool {
	// RectangleOverlapsBezier is only reached via rectangle_overlaps_link /
	// click handling, where the bezier was built with the current style's
	// LinkLineSegmentsPerLength — recompute the segment count identically.
	num_segments := cubic_bezier_num_segments(
		cubic_bezier,
		g_imnodes.style.link_line_segments_per_length,
	)
	current := eval_cubic_bezier(cubic_bezier, 0)
	dt := 1.0 / f32(num_segments)
	for s in 0 ..< num_segments {
		next := eval_cubic_bezier(cubic_bezier, f32(s + 1) * dt)
		if rectangle_overlaps_line_segment(rectangle, current, next) {
			return true
		}
		current = next
	}
	return false
}

rectangle_overlaps_link :: proc(rectangle: Rect, start, end: Vec2, start_type: Attribute_Type) -> bool {
	// First level: simple rejection test via rectangle overlap:

	lrect := Rect{start, end}
	if lrect.min.x > lrect.max.x {
		lrect.min.x, lrect.max.x = lrect.max.x, lrect.min.x
	}

	if lrect.min.y > lrect.max.y {
		lrect.min.y, lrect.max.y = lrect.max.y, lrect.min.y
	}

	if rect_overlaps(rectangle, lrect) {
		// First, check if either one or both endpoinds are trivially contained
		// in the rectangle

		if rect_contains_point(rectangle, start) || rect_contains_point(rectangle, end) {
			return true
		}

		// Second level of refinement: do a more expensive test against the
		// link

		cubic_bezier := get_cubic_bezier(
			start,
			end,
			start_type,
			g_imnodes.style.link_line_segments_per_length,
		)
		return rectangle_overlaps_bezier(rectangle, cubic_bezier)
	}

	return false
}

// ---------------------------------------------------------------------------
// [SECTION] coordinate space conversion helpers
// ---------------------------------------------------------------------------

screen_space_to_grid_space :: proc {
	screen_space_to_grid_space_vec,
	screen_space_to_grid_space_rect,
}

// Zoom model (imnodes-odin extension): grid space is the canonical unscaled
// content space; editor space = grid * zoom + panning; screen = editor +
// canvas origin. At zoom == 1 these reduce to the upstream C++ transforms.

screen_space_to_grid_space_vec :: proc "contextless" (editor: ^Editor_Context, v: Vec2) -> Vec2 {
	return v2_scale_div(
		v2_sub(v2_sub(v, g_imnodes.canvas_origin_screen_space), editor.panning),
		editor.zoom,
	)
}

screen_space_to_grid_space_rect :: proc "contextless" (editor: ^Editor_Context, r: Rect) -> Rect {
	return {
		screen_space_to_grid_space(editor, r.min),
		screen_space_to_grid_space(editor, r.max),
	}
}

grid_space_to_screen_space :: proc "contextless" (editor: ^Editor_Context, v: Vec2) -> Vec2 {
	return v2_add(
		v2_add(v2_scale(v, editor.zoom), g_imnodes.canvas_origin_screen_space),
		editor.panning,
	)
}

grid_space_to_editor_space :: proc "contextless" (editor: ^Editor_Context, v: Vec2) -> Vec2 {
	return v2_add(v2_scale(v, editor.zoom), editor.panning)
}

editor_space_to_grid_space :: proc "contextless" (editor: ^Editor_Context, v: Vec2) -> Vec2 {
	return v2_scale_div(v2_sub(v, editor.panning), editor.zoom)
}

editor_space_to_screen_space :: proc "contextless" (v: Vec2) -> Vec2 {
	return v2_add(g_imnodes.canvas_origin_screen_space, v)
}

mini_map_space_to_grid_space :: proc "contextless" (editor: ^Editor_Context, v: Vec2) -> Vec2 {
	return v2_add(
		v2_scale_div(
			v2_sub(v, editor.mini_map_content_screen_space.min),
			editor.mini_map_scaling,
		),
		editor.grid_content_bounds.min,
	)
}

screen_space_to_mini_map_space :: proc {
	screen_space_to_mini_map_space_vec,
	screen_space_to_mini_map_space_rect,
}

screen_space_to_mini_map_space_vec :: proc "contextless" (editor: ^Editor_Context, v: Vec2) -> Vec2 {
	return v2_add(
		v2_scale(
			v2_sub(screen_space_to_grid_space(editor, v), editor.grid_content_bounds.min),
			editor.mini_map_scaling,
		),
		editor.mini_map_content_screen_space.min,
	)
}

screen_space_to_mini_map_space_rect :: proc "contextless" (editor: ^Editor_Context, r: Rect) -> Rect {
	return {
		screen_space_to_mini_map_space(editor, r.min),
		screen_space_to_mini_map_space(editor, r.max),
	}
}

// ---------------------------------------------------------------------------
// [SECTION] draw list helper
// ---------------------------------------------------------------------------

// Mirrors ImVector::reserve with the imgui allocator: the channel buffers are
// later freed by imgui itself (ImDrawListSplitter_ClearFreeMemory), so the
// allocation must come from im.MemAlloc to stay paired.
im_grow_draw_channel_buffer :: proc(channels: ^im.Vector_DrawChannel, new_capacity: i32) {
	new_data := cast([^]im.DrawChannel)im.MemAlloc(uint(new_capacity) * size_of(im.DrawChannel))
	if channels.Data != nil {
		copy(new_data[:channels.Size], channels.Data[:channels.Size])
		im.MemFree(channels.Data)
	}
	channels.Data = new_data
	channels.Capacity = new_capacity
}

// Mirrors ImVector::push_back for ImDrawCmd (reserve(Size + 1) growth).
im_draw_cmd_push_back :: proc(buf: ^im.Vector_DrawCmd, cmd: im.DrawCmd) {
	if buf.Size == buf.Capacity {
		new_capacity := buf.Size + 1
		new_data := cast([^]im.DrawCmd)im.MemAlloc(uint(new_capacity) * size_of(im.DrawCmd))
		if buf.Data != nil {
			copy(new_data[:buf.Size], buf.Data[:buf.Size])
			im.MemFree(buf.Data)
		}
		buf.Data = new_data
		buf.Capacity = new_capacity
	}
	buf.Data[buf.Size] = cmd
	buf.Size += 1
}

im_draw_list_grow_channels :: proc(draw_list: ^im.DrawList, num_channels: i32) {
	splitter := &draw_list._Splitter

	if splitter._Count == 1 {
		im.DrawListSplitter_Split(splitter, draw_list, num_channels + 1)
		return
	}

	// NOTE: this logic has been lifted from ImDrawListSplitter::Split with slight modifications
	// to allow nested splits. The main modification is that we only create new ImDrawChannel
	// instances after splitter._Count, instead of over the whole splitter._Channels array like
	// the regular ImDrawListSplitter::Split method does.

	old_channel_capacity := splitter._Channels.Size
	// NOTE: _Channels is not resized down, and therefore _Count <= _Channels.size()!
	old_channel_count := splitter._Count
	requested_channel_count := old_channel_count + num_channels
	if old_channel_capacity < requested_channel_count {
		// Mirrors ImVector::resize(requested_channel_count).
		if requested_channel_count > splitter._Channels.Capacity {
			im_grow_draw_channel_buffer(&splitter._Channels, requested_channel_count)
		}
		splitter._Channels.Size = requested_channel_count
	}

	splitter._Count = requested_channel_count

	for i in old_channel_count ..< requested_channel_count {
		channel := &splitter._Channels.Data[i]

		// If we're inside the old capacity region of the array, we need to reuse the existing
		// memory of the command and index buffers.
		if i < old_channel_capacity {
			channel._CmdBuffer.Size = 0
			channel._IdxBuffer.Size = 0
		} else {
			// Else, we need to construct new draw channels.
			channel^ = {}
		}

		{
			draw_cmd := im.DrawCmd {
				ClipRect = draw_list._ClipRectStack.Data[draw_list._ClipRectStack.Size - 1],
				TexRef   = draw_list._TextureStack.Data[draw_list._TextureStack.Size - 1],
			}
			im_draw_cmd_push_back(&channel._CmdBuffer, draw_cmd)
		}
	}
}

im_draw_list_splitter_swap_channels :: proc(splitter: ^im.DrawListSplitter, lhs_idx, rhs_idx: i32) {
	if lhs_idx == rhs_idx {
		return
	}

	assert(lhs_idx >= 0 && lhs_idx < splitter._Count)
	assert(rhs_idx >= 0 && rhs_idx < splitter._Count)

	lhs_channel := &splitter._Channels.Data[lhs_idx]
	rhs_channel := &splitter._Channels.Data[rhs_idx]
	lhs_channel._CmdBuffer, rhs_channel._CmdBuffer = rhs_channel._CmdBuffer, lhs_channel._CmdBuffer
	lhs_channel._IdxBuffer, rhs_channel._IdxBuffer = rhs_channel._IdxBuffer, lhs_channel._IdxBuffer

	current_channel := splitter._Current

	if current_channel == lhs_idx {
		splitter._Current = rhs_idx
	} else if current_channel == rhs_idx {
		splitter._Current = lhs_idx
	}
}

draw_list_set :: proc(window_draw_list: ^im.DrawList) {
	g_imnodes.canvas_draw_list = window_draw_list
	clear(&g_imnodes.node_idx_to_submission_idx)
	clear(&g_imnodes.node_idx_submission_order)
}

// The draw list channels are structured as follows. First we have our base channel, the canvas grid
// on which we render the grid lines in BeginNodeEditor(). The base channel is the reason
// draw_list_submission_idx_to_background_channel_idx offsets the index by one. Each BeginNode()
// call appends two new draw channels, for the node background and foreground. The node foreground
// is the channel into which the node's ImGui content is rendered. Finally, in EndNodeEditor() we
// append one last draw channel for rendering the selection box and the incomplete link on top of
// everything else.
//
// +----------+----------+----------+----------+----------+----------+
// |          |          |          |          |          |          |
// |canvas    |node      |node      |...       |...       |click     |
// |grid      |background|foreground|          |          |interaction
// |          |          |          |          |          |          |
// +----------+----------+----------+----------+----------+----------+
//            |                     |
//            |   submission idx    |
//            |                     |
//            -----------------------

draw_list_add_node :: proc(node_idx: int) {
	g_imnodes.node_idx_to_submission_idx[i32(node_idx)] = i32(len(g_imnodes.node_idx_submission_order))
	append(&g_imnodes.node_idx_submission_order, node_idx)
	im_draw_list_grow_channels(g_imnodes.canvas_draw_list, 2)
}

draw_list_append_click_interaction_channel :: proc() {
	// NOTE: don't use this function outside of EndNodeEditor. Using this before all nodes have been
	// added will screw up the node draw order.
	im_draw_list_grow_channels(g_imnodes.canvas_draw_list, 1)
}

draw_list_submission_idx_to_background_channel_idx :: proc "contextless" (submission_idx: int) -> int {
	// NOTE: the first channel is the canvas background, i.e. the grid
	return 1 + 2 * submission_idx
}

draw_list_submission_idx_to_foreground_channel_idx :: proc "contextless" (submission_idx: int) -> int {
	return draw_list_submission_idx_to_background_channel_idx(submission_idx) + 1
}

draw_list_activate_click_interaction_channel :: proc() {
	im.DrawListSplitter_SetCurrentChannel(
		&g_imnodes.canvas_draw_list._Splitter,
		g_imnodes.canvas_draw_list,
		g_imnodes.canvas_draw_list._Splitter._Count - 1,
	)
}

draw_list_activate_current_node_foreground :: proc() {
	foreground_channel_idx := draw_list_submission_idx_to_foreground_channel_idx(
		len(g_imnodes.node_idx_submission_order) - 1,
	)
	im.DrawListSplitter_SetCurrentChannel(
		&g_imnodes.canvas_draw_list._Splitter,
		g_imnodes.canvas_draw_list,
		i32(foreground_channel_idx),
	)
}

draw_list_activate_node_background :: proc(node_idx: int) {
	submission_idx := -1
	if v, ok := g_imnodes.node_idx_to_submission_idx[i32(node_idx)]; ok {
		submission_idx = int(v)
	}
	// There is a discrepancy in the submitted node count and the rendered node count! Did you call
	// one of the following functions
	// * EditorContextMoveToNode
	// * SetNodeScreenSpacePos
	// * SetNodeGridSpacePos
	// * SetNodeDraggable
	// after the BeginNode/EndNode function calls?
	if submission_idx == -1 {
		internal_error("draw_list_activate_node_background: node %d was not submitted via begin_node this frame", node_idx)
	}
	background_channel_idx := draw_list_submission_idx_to_background_channel_idx(submission_idx)
	im.DrawListSplitter_SetCurrentChannel(
		&g_imnodes.canvas_draw_list._Splitter,
		g_imnodes.canvas_draw_list,
		i32(background_channel_idx),
	)
}

draw_list_swap_submission_indices :: proc(lhs_idx, rhs_idx: int) {
	assert(lhs_idx != rhs_idx)

	lhs_foreground_channel_idx := draw_list_submission_idx_to_foreground_channel_idx(lhs_idx)
	lhs_background_channel_idx := draw_list_submission_idx_to_background_channel_idx(lhs_idx)
	rhs_foreground_channel_idx := draw_list_submission_idx_to_foreground_channel_idx(rhs_idx)
	rhs_background_channel_idx := draw_list_submission_idx_to_background_channel_idx(rhs_idx)

	im_draw_list_splitter_swap_channels(
		&g_imnodes.canvas_draw_list._Splitter,
		i32(lhs_background_channel_idx),
		i32(rhs_background_channel_idx),
	)
	im_draw_list_splitter_swap_channels(
		&g_imnodes.canvas_draw_list._Splitter,
		i32(lhs_foreground_channel_idx),
		i32(rhs_foreground_channel_idx),
	)
}

draw_list_sort_channels_by_depth :: proc(node_idx_depth_order: []int) {
	if len(g_imnodes.node_idx_to_submission_idx) < 2 {
		return
	}

	assert(len(node_idx_depth_order) == len(g_imnodes.node_idx_submission_order))

	start_idx := len(node_idx_depth_order) - 1

	for node_idx_depth_order[start_idx] == g_imnodes.node_idx_submission_order[start_idx] {
		start_idx -= 1
		if start_idx == 0 {
			// early out if submission order and depth order are the same
			return
		}
	}

	// TODO: this is an O(N^2) algorithm. It might be worthwhile revisiting this to see if the time
	// complexity can be reduced.

	for depth_idx := start_idx; depth_idx > 0; depth_idx -= 1 {
		node_idx := node_idx_depth_order[depth_idx]

		// Find the current index of the node_idx in the submission order array
		submission_idx := -1
		for i in 0 ..< len(g_imnodes.node_idx_submission_order) {
			if g_imnodes.node_idx_submission_order[i] == node_idx {
				submission_idx = i
				break
			}
		}
		assert(submission_idx >= 0)

		if submission_idx == depth_idx {
			continue
		}

		for j in submission_idx ..< depth_idx {
			draw_list_swap_submission_indices(j, j + 1)
			g_imnodes.node_idx_submission_order[j], g_imnodes.node_idx_submission_order[j + 1] =
				g_imnodes.node_idx_submission_order[j + 1], g_imnodes.node_idx_submission_order[j]
		}
	}
}

// ---------------------------------------------------------------------------
// [SECTION] ui state logic
// ---------------------------------------------------------------------------

get_screen_space_pin_coordinates :: proc {
	get_screen_space_pin_coordinates_rects,
	get_screen_space_pin_coordinates_pin,
}

get_screen_space_pin_coordinates_rects :: proc(
	node_rect, attribute_rect: Rect,
	type: Attribute_Type,
) -> Vec2 {
	if type != .Input && type != .Output {
		internal_error("get_screen_space_pin_coordinates: invalid attribute type %d", int(type))
	}
	x: f32
	pin_offset := g_imnodes.style.pin_offset * editor_context_get().zoom
	if type == .Input {
		x = node_rect.min.x - pin_offset
	} else {
		x = node_rect.max.x + pin_offset
	}
	return {x, 0.5 * (attribute_rect.min.y + attribute_rect.max.y)}
}

get_screen_space_pin_coordinates_pin :: proc(editor: ^Editor_Context, pin: Pin_Data) -> Vec2 {
	parent_node_rect := editor.nodes.pool[pin.parent_node_idx].rect
	return get_screen_space_pin_coordinates(parent_node_rect, pin.attribute_rect, pin.type)
}

mouse_in_canvas :: proc() -> bool {
	// This flag should be true either when hovering or clicking something in the canvas.
	is_window_hovered_or_focused := im.IsWindowHovered() || im.IsWindowFocused()

	return is_window_hovered_or_focused &&
	       rect_contains_point(g_imnodes.canvas_rect_screen_space, im.GetIO().MousePos)
}

// Sentinel-value equality of ImOptionalIndex: equal iff both are invalid or
// both hold the same value.
maybe_int_equal :: proc "contextless" (a, b: Maybe(int)) -> bool {
	av, aok := a.?
	bv, bok := b.?
	return aok == bok && (!aok || av == bv)
}

int_slice_contains :: proc "contextless" (s: []int, v: int) -> bool {
	for x in s {
		if x == v {
			return true
		}
	}
	return false
}

begin_node_selection :: proc(editor: ^Editor_Context, node_idx: int) {
	// Don't start selecting a node if we are e.g. already creating and dragging
	// a new link! New link creation can happen when the mouse is clicked over
	// a node, but within the hover radius of a pin.
	if editor.click_interaction.type != .None {
		return
	}

	editor.click_interaction.type = .Node
	// If the node is not already contained in the selection, then we want only
	// the interaction node to be selected, effective immediately.
	//
	// If the multiple selection modifier is active, we want to add this node
	// to the current list of selected nodes.
	//
	// Otherwise, we want to allow for the possibility of multiple nodes to be
	// moved at once.
	if !int_slice_contains(editor.selected_node_indices[:], node_idx) {
		clear(&editor.selected_link_indices)
		if !g_imnodes.multiple_select_modifier {
			clear(&editor.selected_node_indices)
		}
		append(&editor.selected_node_indices, node_idx)

		// Ensure that individually selected nodes get rendered on top
		depth_idx := -1
		for elem, i in editor.node_depth_order {
			if elem == node_idx {
				depth_idx = i
				break
			}
		}
		assert(depth_idx != -1)
		ordered_remove(&editor.node_depth_order, depth_idx)
		append(&editor.node_depth_order, node_idx)
	} else if g_imnodes.multiple_select_modifier {
		// Deselect a previously-selected node
		for elem, i in editor.selected_node_indices {
			if elem == node_idx {
				ordered_remove(&editor.selected_node_indices, i)
				break
			}
		}

		// Don't allow dragging after deselecting
		editor.click_interaction.type = .None
	}

	// To support snapping of multiple nodes, we need to store the offset of
	// each node in the selection to the origin of the dragged node.
	//
	// primary_node_offset is kept in screen space: grid_space_to_screen_space
	// applies the zoom, so the drag delta measured in pixels is unscaled back
	// to grid units in translate_selected_nodes.
	ref_origin := editor.nodes.pool[node_idx].origin
	editor.primary_node_offset = v2_sub(
		grid_space_to_screen_space(editor, ref_origin),
		g_imnodes.mouse_pos,
	)

	clear(&editor.selected_node_offsets)
	for idx in 0 ..< len(editor.selected_node_indices) {
		node := editor.selected_node_indices[idx]
		node_origin := v2_sub(editor.nodes.pool[node].origin, ref_origin)
		append(&editor.selected_node_offsets, node_origin)
	}
}

begin_link_selection :: proc(editor: ^Editor_Context, link_idx: int) {
	editor.click_interaction.type = .Link
	// When a link is selected, clear all other selections, and insert the link
	// as the sole selection.
	clear(&editor.selected_node_indices)
	clear(&editor.selected_link_indices)
	append(&editor.selected_link_indices, link_idx)
}

begin_link_detach :: proc(editor: ^Editor_Context, link_idx, detach_pin_idx: int) {
	link := editor.links.pool[link_idx]
	state := &editor.click_interaction
	state.type = .LinkCreation
	state.link_creation.end_pin_idx = nil
	state.link_creation.start_pin_idx =
		link.end_pin_idx if detach_pin_idx == link.start_pin_idx else link.start_pin_idx
	g_imnodes.deleted_link_idx = link_idx
}

begin_link_creation :: proc(editor: ^Editor_Context, hovered_pin_idx: int) {
	editor.click_interaction.type = .LinkCreation
	editor.click_interaction.link_creation.start_pin_idx = hovered_pin_idx
	editor.click_interaction.link_creation.end_pin_idx = nil
	editor.click_interaction.link_creation.type = .Standard
	g_imnodes.ui_state += {.LinkStarted}
}

begin_link_interaction :: proc(editor: ^Editor_Context, link_idx: int, pin_idx: Maybe(int) = nil) {
	// Check if we are clicking the link with the modifier pressed.
	// This will in a link detach via clicking.

	modifier := g_imnodes.io.link_detach_with_modifier_click.modifier
	modifier_pressed := modifier != nil && modifier^

	if modifier_pressed {
		link := editor.links.pool[link_idx]
		start_pin := editor.pins.pool[link.start_pin_idx]
		end_pin := editor.pins.pool[link.end_pin_idx]
		mouse_pos := g_imnodes.mouse_pos
		dist_to_start := v2_length_sqr(v2_sub(start_pin.pos, mouse_pos))
		dist_to_end := v2_length_sqr(v2_sub(end_pin.pos, mouse_pos))
		closest_pin_idx := link.end_pin_idx
		if dist_to_start < dist_to_end {
			closest_pin_idx = link.start_pin_idx
		}

		editor.click_interaction.type = .LinkCreation
		begin_link_detach(editor, link_idx, closest_pin_idx)
		editor.click_interaction.link_creation.type = .FromDetach
	} else {
		if idx, ok := pin_idx.?; ok {
			hovered_pin_flags := editor.pins.pool[idx].flags

			// Check the 'click and drag to detach' case.
			if .EnableLinkDetachWithDragClick in hovered_pin_flags {
				begin_link_detach(editor, link_idx, idx)
				editor.click_interaction.link_creation.type = .FromDetach
			} else {
				begin_link_creation(editor, idx)
			}
		} else {
			begin_link_selection(editor, link_idx)
		}
	}
}

begin_canvas_interaction :: proc(editor: ^Editor_Context) {
	any_ui_element_hovered :=
		g_imnodes.hovered_node_idx != nil ||
		g_imnodes.hovered_link_idx != nil ||
		g_imnodes.hovered_pin_idx != nil ||
		im.IsAnyItemHovered()

	mouse_not_in_canvas := !mouse_in_canvas()

	if editor.click_interaction.type != .None ||
	   any_ui_element_hovered ||
	   mouse_not_in_canvas ||
	   !im.IsWindowHovered() {
		return
	}

	started_panning := g_imnodes.alt_mouse_clicked

	if started_panning {
		editor.click_interaction.type = .Panning
	} else if g_imnodes.left_mouse_clicked {
		editor.click_interaction.type = .BoxSelection
		editor.click_interaction.box_selector.rect.min = screen_space_to_grid_space(
			editor,
			g_imnodes.mouse_pos,
		)
	}
}

box_selector_update_selection :: proc(editor: ^Editor_Context, box_rect: Rect) {
	box_rect := box_rect

	// Invert box selector coordinates as needed

	if box_rect.min.x > box_rect.max.x {
		box_rect.min.x, box_rect.max.x = box_rect.max.x, box_rect.min.x
	}

	if box_rect.min.y > box_rect.max.y {
		box_rect.min.y, box_rect.max.y = box_rect.max.y, box_rect.min.y
	}

	// Update node selection

	clear(&editor.selected_node_indices)

	// Test for overlap against node rectangles

	for node_idx in 0 ..< len(editor.nodes.pool) {
		if editor.nodes.in_use[node_idx] {
			node := editor.nodes.pool[node_idx]
			if rect_overlaps(box_rect, node.rect) {
				append(&editor.selected_node_indices, node_idx)
			}
		}
	}

	// Update link selection

	clear(&editor.selected_link_indices)

	// Test for overlap against links

	for link_idx in 0 ..< len(editor.links.pool) {
		if editor.links.in_use[link_idx] {
			link := editor.links.pool[link_idx]

			pin_start := editor.pins.pool[link.start_pin_idx]
			pin_end := editor.pins.pool[link.end_pin_idx]
			node_start_rect := editor.nodes.pool[pin_start.parent_node_idx].rect
			node_end_rect := editor.nodes.pool[pin_end.parent_node_idx].rect

			start := get_screen_space_pin_coordinates(
				node_start_rect,
				pin_start.attribute_rect,
				pin_start.type,
			)
			end := get_screen_space_pin_coordinates(
				node_end_rect,
				pin_end.attribute_rect,
				pin_end.type,
			)

			// Test
			if rectangle_overlaps_link(box_rect, start, end, pin_start.type) {
				append(&editor.selected_link_indices, link_idx)
			}
		}
	}
}

snap_origin_to_grid :: proc(origin: Vec2) -> Vec2 {
	origin := origin
	if .GridSnapping in g_imnodes.style.flags {
		spacing := g_imnodes.style.grid_spacing
		spacing2 := spacing * 0.5

		// Snap the origin to the nearest grid point in any direction
		modx := math.mod_f32(abs(origin.x) + spacing2, spacing) - spacing2
		mody := math.mod_f32(abs(origin.y) + spacing2, spacing) - spacing2
		origin.x += modx if origin.x < 0 else -modx
		origin.y += mody if origin.y < 0 else -mody
	}

	return origin
}

translate_selected_nodes :: proc(editor: ^Editor_Context) {
	if g_imnodes.left_mouse_dragging {
		// If we have grid snap enabled, don't start moving nodes until we've moved the mouse
		// slightly
		should_translate := true
		if .GridSnapping in g_imnodes.style.flags {
			should_translate = im.GetIO().MouseDragMaxDistanceSqr[0] > 5.0
		}

		// mouse/primary_node_offset are screen-space pixels; the node origin is
		// grid space, so unscale by zoom (identity at zoom == 1).
		origin := snap_origin_to_grid(
			v2_scale_div(
				v2_add(
					v2_sub(
						v2_sub(g_imnodes.mouse_pos, g_imnodes.canvas_origin_screen_space),
						editor.panning,
					),
					editor.primary_node_offset,
				),
				editor.zoom,
			),
		)
		for i in 0 ..< len(editor.selected_node_indices) {
			node_rel := editor.selected_node_offsets[i]
			node_idx := editor.selected_node_indices[i]
			node := &editor.nodes.pool[node_idx]
			if node.draggable && should_translate {
				node.origin = v2_add(
					v2_add(origin, node_rel),
					v2_scale_div(editor.auto_panning_delta, editor.zoom),
				)
			}
		}
	}
}

// Do a unique compare by sorting the pins' addresses.
// This catches duplicate links, whether they are in the
// same direction or not.
// Sorting by pin index should have the uniqueness guarantees as sorting
// by id -- each unique id will get one slot in the link pool array.
link_predicate :: proc "contextless" (lhs, rhs: Link_Data) -> bool {
	lhs_start := lhs.start_pin_idx
	lhs_end := lhs.end_pin_idx
	rhs_start := rhs.start_pin_idx
	rhs_end := rhs.end_pin_idx

	if lhs_start > lhs_end {
		lhs_start, lhs_end = lhs_end, lhs_start
	}

	if rhs_start > rhs_end {
		rhs_start, rhs_end = rhs_end, rhs_start
	}

	return lhs_start == rhs_start && lhs_end == rhs_end
}

find_duplicate_link :: proc(editor: ^Editor_Context, start_pin_idx, end_pin_idx: int) -> Maybe(int) {
	test_link := Link_Data {
		start_pin_idx = start_pin_idx,
		end_pin_idx   = end_pin_idx,
	}
	for link_idx in 0 ..< len(editor.links.pool) {
		link := editor.links.pool[link_idx]
		if link_predicate(test_link, link) && editor.links.in_use[link_idx] {
			return link_idx
		}
	}

	return nil
}

should_link_snap_to_pin :: proc(
	editor: ^Editor_Context,
	start_pin: Pin_Data,
	hovered_pin_idx: int,
	duplicate_link: Maybe(int),
) -> bool {
	end_pin := editor.pins.pool[hovered_pin_idx]

	// The end pin must be in a different node
	if start_pin.parent_node_idx == end_pin.parent_node_idx {
		return false
	}

	// The end pin must be of a different type
	if start_pin.type == end_pin.type {
		return false
	}

	// The link to be created must not be a duplicate, unless it is the link which was created on
	// snap. In that case we want to snap, since we want it to appear visually as if the created
	// link remains snapped to the pin.
	if duplicate_link != nil && !maybe_int_equal(duplicate_link, g_imnodes.snap_link_idx) {
		return false
	}

	return true
}

click_interaction_update :: proc(editor: ^Editor_Context) {
	switch editor.click_interaction.type {
	case .BoxSelection:
		editor.click_interaction.box_selector.rect.max = screen_space_to_grid_space(
			editor,
			g_imnodes.mouse_pos,
		)

		box_rect := editor.click_interaction.box_selector.rect
		box_rect.min = grid_space_to_screen_space(editor, box_rect.min)
		box_rect.max = grid_space_to_screen_space(editor, box_rect.max)

		box_selector_update_selection(editor, box_rect)

		box_selector_color := g_imnodes.style.colors[.BoxSelector]
		box_selector_outline := g_imnodes.style.colors[.BoxSelectorOutline]
		im.DrawList_AddRectFilled(
			g_imnodes.canvas_draw_list,
			box_rect.min,
			box_rect.max,
			box_selector_color,
		)
		im.DrawList_AddRect(
			g_imnodes.canvas_draw_list,
			box_rect.min,
			box_rect.max,
			box_selector_outline,
		)

		if g_imnodes.left_mouse_released {
			// Bump the selected node indices, in order, to the top of the depth stack.
			// NOTE: this algorithm has worst case time complexity of O(N^2), if the node selection
			// is ~ N (due to selected_idxs.contains()).

			depth_stack := &editor.node_depth_order
			selected_idxs := editor.selected_node_indices

			if len(selected_idxs) > 0 && len(selected_idxs) < len(depth_stack) {
				num_moved := 0 // The number of indices moved. Stop after selected_idxs.Size
				bound := len(depth_stack) - len(selected_idxs)
				for i := 0; i < bound; i += 1 {
					for {
						node_idx := depth_stack[i]
						if !int_slice_contains(selected_idxs[:], node_idx) {
							break
						}
						ordered_remove(depth_stack, i)
						append(depth_stack, node_idx)
						num_moved += 1
					}

					if num_moved == len(selected_idxs) {
						break
					}
				}
			}

			editor.click_interaction.type = .None
		}
	case .Node:
		translate_selected_nodes(editor)

		if g_imnodes.left_mouse_released {
			editor.click_interaction.type = .None
		}
	case .Link:
		if g_imnodes.left_mouse_released {
			editor.click_interaction.type = .None
		}
	case .LinkCreation:
		start_pin := editor.pins.pool[editor.click_interaction.link_creation.start_pin_idx]

		maybe_duplicate_link_idx: Maybe(int)
		hovered_pin_idx, hovered_pin_ok := g_imnodes.hovered_pin_idx.?
		if hovered_pin_ok {
			maybe_duplicate_link_idx = find_duplicate_link(
				editor,
				editor.click_interaction.link_creation.start_pin_idx,
				hovered_pin_idx,
			)
		}

		should_snap :=
			hovered_pin_ok &&
			should_link_snap_to_pin(editor, start_pin, hovered_pin_idx, maybe_duplicate_link_idx)

		// If we created on snap and the hovered pin is empty or changed, then we need signal that
		// the link's state has changed.
		snapping_pin_changed :=
			editor.click_interaction.link_creation.end_pin_idx != nil &&
			!maybe_int_equal(
				g_imnodes.hovered_pin_idx,
				editor.click_interaction.link_creation.end_pin_idx,
			)

		// Detach the link that was created by this link event if it's no longer in snap range
		if snapping_pin_changed {
			if snap_link_idx, ok := g_imnodes.snap_link_idx.?; ok {
				begin_link_detach(
					editor,
					snap_link_idx,
					editor.click_interaction.link_creation.end_pin_idx.?,
				)
			}
		}

		start_pos := get_screen_space_pin_coordinates(editor, start_pin)
		// If we are within the hover radius of a receiving pin, snap the link
		// endpoint to it
		end_pos := g_imnodes.mouse_pos
		if should_snap {
			end_pos = get_screen_space_pin_coordinates(editor, editor.pins.pool[hovered_pin_idx])
		}

		cubic_bezier := get_cubic_bezier(
			start_pos,
			end_pos,
			start_pin.type,
			g_imnodes.style.link_line_segments_per_length,
		)
		im.DrawList_AddBezierCubic(
			g_imnodes.canvas_draw_list,
			cubic_bezier.p0,
			cubic_bezier.p1,
			cubic_bezier.p2,
			cubic_bezier.p3,
			g_imnodes.style.colors[.Link],
			g_imnodes.style.link_thickness * editor.zoom, // imnodes-odin zoom
			i32(
				cubic_bezier_num_segments(
					cubic_bezier,
					g_imnodes.style.link_line_segments_per_length,
				),
			),
		)

		link_creation_on_snap :=
			hovered_pin_ok &&
			(.EnableLinkCreationOnSnap in editor.pins.pool[hovered_pin_idx].flags)

		if !should_snap {
			editor.click_interaction.link_creation.end_pin_idx = nil
		}

		create_link := should_snap && (g_imnodes.left_mouse_released || link_creation_on_snap)

		if create_link && maybe_duplicate_link_idx == nil {
			// Avoid send OnLinkCreated() events every frame if the snap link is not saved
			// (only applies for EnableLinkCreationOnSnap)
			if !g_imnodes.left_mouse_released &&
			   maybe_int_equal(
				   editor.click_interaction.link_creation.end_pin_idx,
				   g_imnodes.hovered_pin_idx,
			   ) {
				break
			}

			g_imnodes.ui_state += {.LinkCreated}
			editor.click_interaction.link_creation.end_pin_idx = hovered_pin_idx
		}

		if g_imnodes.left_mouse_released {
			editor.click_interaction.type = .None
			if !create_link {
				g_imnodes.ui_state += {.LinkDropped}
			}
		}
	case .Panning:
		dragging := g_imnodes.alt_mouse_dragging

		if dragging {
			editor.panning = v2_add(editor.panning, im.GetIO().MouseDelta)
		} else {
			editor.click_interaction.type = .None
		}
	case .ImGuiItem:
		if g_imnodes.left_mouse_released {
			editor.click_interaction.type = .None
		}
	case .None:
	case:
		assert(false, "Unreachable code!")
	}
}

resolve_occluded_pins :: proc(editor: ^Editor_Context, occluded_pin_indices: ^[dynamic]int) {
	depth_stack := editor.node_depth_order

	clear(occluded_pin_indices)

	if len(depth_stack) < 2 {
		return
	}

	// For each node in the depth stack
	for depth_idx in 0 ..< len(depth_stack) - 1 {
		node_below := editor.nodes.pool[depth_stack[depth_idx]]

		// Iterate over the rest of the depth stack to find nodes overlapping the pins
		for next_depth_idx in depth_idx + 1 ..< len(depth_stack) {
			rect_above := editor.nodes.pool[depth_stack[next_depth_idx]].rect

			// Iterate over each pin
			for idx in 0 ..< len(node_below.pin_indices) {
				pin_idx := node_below.pin_indices[idx]
				pin_pos := editor.pins.pool[pin_idx].pos

				if rect_contains_point(rect_above, pin_pos) {
					append(occluded_pin_indices, pin_idx)
				}
			}
		}
	}
}

resolve_hovered_pin :: proc(pins: Object_Pool(Pin_Data), occluded_pin_indices: []int) -> Maybe(int) {
	smallest_distance := max(f32)
	pin_idx_with_smallest_distance: Maybe(int)

	hover_radius := g_imnodes.style.pin_hover_radius * editor_context_get().zoom
	hover_radius_sqr := hover_radius * hover_radius

	for idx in 0 ..< len(pins.pool) {
		if !pins.in_use[idx] {
			continue
		}

		if int_slice_contains(occluded_pin_indices, idx) {
			continue
		}

		pin_pos := pins.pool[idx].pos
		distance_sqr := v2_length_sqr(v2_sub(pin_pos, g_imnodes.mouse_pos))

		// TODO: GImNodes->Style.PinHoverRadius needs to be copied into pin data and the pin-local
		// value used here. This is no longer called in BeginAttribute/EndAttribute scope and the
		// detected pin might have a different hover radius than what the user had when calling
		// BeginAttribute/EndAttribute.
		if distance_sqr < hover_radius_sqr && distance_sqr < smallest_distance {
			smallest_distance = distance_sqr
			pin_idx_with_smallest_distance = idx
		}
	}

	return pin_idx_with_smallest_distance
}

resolve_hovered_node :: proc(depth_stack: []int) -> Maybe(int) {
	if len(g_imnodes.node_indices_overlapping_with_mouse) == 0 {
		return nil
	}

	if len(g_imnodes.node_indices_overlapping_with_mouse) == 1 {
		return g_imnodes.node_indices_overlapping_with_mouse[0]
	}

	largest_depth_idx := -1
	node_idx_on_top := -1

	for i in 0 ..< len(g_imnodes.node_indices_overlapping_with_mouse) {
		node_idx := g_imnodes.node_indices_overlapping_with_mouse[i]
		for depth_idx in 0 ..< len(depth_stack) {
			if depth_stack[depth_idx] == node_idx && depth_idx > largest_depth_idx {
				largest_depth_idx = depth_idx
				node_idx_on_top = node_idx
			}
		}
	}

	if node_idx_on_top == -1 {
		// The overlapping set should always intersect the depth stack; if it
		// does not, the state is inconsistent — degrade gracefully instead of
		// tripping an assert that the release build compiles out.
		log.error("imnodes: resolve_hovered_node found no overlapping node in the depth stack")
		return nil
	}
	return node_idx_on_top
}

resolve_hovered_link :: proc(
	links: Object_Pool(Link_Data),
	pins: Object_Pool(Pin_Data),
) -> Maybe(int) {
	smallest_distance := max(f32)
	link_idx_with_smallest_distance: Maybe(int)
	link_hover_distance := g_imnodes.style.link_hover_distance * editor_context_get().zoom

	// There are two ways a link can be detected as "hovered".
	// 1. The link is within hover distance to the mouse. The closest such link is selected as being
	// hovered over.
	// 2. If the link is connected to the currently hovered pin.
	//
	// The latter is a requirement for link detaching with drag click to work, as both a link and
	// pin are required to be hovered over for the feature to work.

	for idx in 0 ..< len(links.pool) {
		if !links.in_use[idx] {
			continue
		}

		link := links.pool[idx]
		start_pin := pins.pool[link.start_pin_idx]
		end_pin := pins.pool[link.end_pin_idx]

		// If there is a hovered pin links can only be considered hovered if they use that pin
		if hovered_pin_idx, ok := g_imnodes.hovered_pin_idx.?; ok {
			if hovered_pin_idx == link.start_pin_idx || hovered_pin_idx == link.end_pin_idx {
				return idx
			}
			continue
		}

		// TODO: the calculated CubicBeziers could be cached since we generate them again when
		// rendering the links

		cubic_bezier := get_cubic_bezier(
			start_pin.pos,
			end_pin.pos,
			start_pin.type,
			g_imnodes.style.link_line_segments_per_length,
		)

		// The distance test
		{
			link_rect := get_containing_rect_for_cubic_bezier(cubic_bezier)

			// First, do a simple bounding box test against the box containing the link
			// to see whether calculating the distance to the link is worth doing.
			if rect_contains_point(link_rect, g_imnodes.mouse_pos) {
				distance := get_distance_to_cubic_bezier(
					g_imnodes.mouse_pos,
					cubic_bezier,
					cubic_bezier_num_segments(
						cubic_bezier,
						g_imnodes.style.link_line_segments_per_length,
					),
				)

				// TODO: GImNodes->Style.LinkHoverDistance could be also copied into ImLinkData,
				// since we're not calling this function in the same scope as ImNodes::Link(). The
				// rendered/detected link might have a different hover distance than what the user
				// had specified when calling Link()
				if distance < link_hover_distance && distance < smallest_distance {
					smallest_distance = distance
					link_idx_with_smallest_distance = idx
				}
			}
		}
	}

	return link_idx_with_smallest_distance
}
