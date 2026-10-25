// Scene architecture graph, docked in the sidebar's GRAPH mode (F2 jumps
// to it). The graph reflects how the active scene unit is built, it is not
// a material editor: a params node per uniform block the app feeds, an
// image node (the app's textures + samplers) when any pass samples one, a
// 3d object node (the selected model's vertex stream, entering passes
// through the stage_in ModelVertex parameter) when any pass draws the
// model, one graphics node per vertex+fragment entry pair
// found in the scene's files, one compute node per compute entry, and a
// terminal "show 2d" node (the frame the viewport presents). Passes chain
// in declaration order: a graphics node's frame output feeds the next
// pass's first texture input (e.g. phong 3D → blur compute: params →
// graphics → compute). Uniforms are wireless: the params node's output
// pins carry a broadcast mark and every cbuffer input a receiver mark;
// no uniform links are drawn and they play no part in the layout. The
// remaining links are derived from the source on a 120-frame rescan;
// they are not user-editable. The node layout persists in the scene's
// graph.json. All state lives here in Odin; the C++ side only renders.
//
// Pan with two fingers on the trackpad (wheel deltas adjust the editor
// panning); middle-drag also pans (imnodes built-in).
package main

import im "../vendor/odin-imgui"
import imnodes "../vendor/imnodes-odin"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"


// The owning ImNodes context: ine_create makes it current and records it;
// ine_destroy frees the editor context then the context itself. Called from
// main's teardown so the pool/selection state is not reported as leaks.
ine_owning_ctx: ^imnodes.Context

ine_create :: proc() -> ^imnodes.Editor_Context {
	// Dedicated context + editor context, dark style (same shape the ine
	// wrapper used to mirror).
	node_context := imnodes.create_context()
	ine_owning_ctx = node_context
	imnodes.set_current_context(node_context)
	editor := imnodes.editor_context_create()
	imnodes.editor_context_set(editor)
	imnodes.style_colors_dark()
	return editor
}

ine_destroy :: proc(editor: ^imnodes.Editor_Context) {
	if ine_owning_ctx == nil do return
	if editor != nil {
		if current := imnodes.get_current_context(); current == ine_owning_ctx {
			imnodes.editor_context_free(editor)
		}
	}
	imnodes.destroy_context(ine_owning_ctx)
	ine_owning_ctx = nil
}

ine_editor_begin :: proc() {
	ine_editor_scope = true
	imnodes.begin_node_editor()
}

ine_editor_end :: proc() {
	imnodes.end_node_editor()
	ine_editor_scope = false
}

// True between ine_editor_begin and ine_editor_end. imnodes' position
// queries panic on nodes absent from the current frame's pool (e.g. right
// after a scene switch), so sg_save/sg_compute_layout fall back to the
// cached node.cur whenever this is false.
ine_editor_scope: bool

ine_scope_active :: proc() -> bool {
	return ine_editor_scope
}

ine_minimap :: proc(size_fraction: f32, location: imnodes.Mini_Map_Location) {
	imnodes.mini_map(size_fraction, location)
}

ine_begin_node :: proc(node_id: int) {
	imnodes.begin_node(i32(node_id))
}

ine_end_node :: proc() {
	imnodes.end_node()
}

ine_title_bar_begin :: proc() {
	imnodes.begin_node_title_bar()
}

ine_title_bar_end :: proc() {
	imnodes.end_node_title_bar()
}

ine_input_attr_begin :: proc(attr_id: int, shape: imnodes.Pin_Shape) {
	imnodes.begin_input_attribute(i32(attr_id), shape)
}

ine_input_attr_end :: proc() {
	imnodes.end_input_attribute()
}

ine_output_attr_begin :: proc(attr_id: int, shape: imnodes.Pin_Shape) {
	imnodes.begin_output_attribute(i32(attr_id), shape)
}

ine_output_attr_end :: proc() {
	imnodes.end_output_attribute()
}

ine_static_attr_begin :: proc(attr_id: int) {
	imnodes.begin_static_attribute(i32(attr_id))
}

ine_static_attr_end :: proc() {
	imnodes.end_static_attribute()
}

ine_link :: proc(link_id, start_attr, end_attr: int) {
	imnodes.link(i32(link_id), i32(start_attr), i32(end_attr))
}

ine_is_link_created :: proc(start_attr, end_attr: ^int) -> bool {
	created, start_id, end_id, _ := imnodes.is_link_created()
	start_attr^, end_attr^ = int(start_id), int(end_id)
	return created
}

ine_is_link_destroyed :: proc(link_id: ^int) -> bool {
	destroyed, removed_id := imnodes.is_link_destroyed()
	link_id^ = int(removed_id)
	return destroyed
}

ine_push_attribute_flag :: proc(flags: imnodes.Attribute_Flags) {
	imnodes.push_attribute_flag(flags)
}

ine_pop_attribute_flag :: proc() {
	imnodes.pop_attribute_flag()
}

ine_set_node_grid_pos :: proc(node_id: int, position: im.Vec2) {
	imnodes.set_node_grid_space_pos(i32(node_id), position)
}

ine_get_node_grid_pos :: proc(node_id: int) -> im.Vec2 {
	return imnodes.get_node_grid_space_pos(i32(node_id))
}

ine_get_panning :: proc() -> im.Vec2 {
	return imnodes.editor_context_get_panning()
}

ine_reset_panning :: proc(position: im.Vec2) {
	imnodes.editor_context_reset_panning(position)
}

ine_is_editor_hovered :: proc() -> bool {
	return imnodes.is_editor_hovered()
}

ine_is_node_hovered :: proc() -> (hovered: bool, node_id: int) {
	is_hovered, hovered_id := imnodes.is_node_hovered()
	return is_hovered, int(hovered_id)
}

ine_push_color_style :: proc(color_slot: imnodes.Col, packed_color: u32) {
	imnodes.push_color_style(color_slot, packed_color)
}

ine_pop_color_style :: proc() {
	imnodes.pop_color_style()
}

ine_screen_to_grid :: proc(screen_pos: im.Vec2) -> im.Vec2 {
	origin := imnodes.get_canvas_origin_screen_space()
	panning := imnodes.editor_context_get_panning()
	zoom := imnodes.editor_context_get_zoom()
	return im.Vec2{
		(screen_pos.x - origin.x - panning.x) / zoom,
		(screen_pos.y - origin.y - panning.y) / zoom,
	}
}

ine_get_zoom :: proc() -> f32 {
	return imnodes.editor_context_get_zoom()
}

ine_set_zoom :: proc(zoom: f32, pivot: Maybe(im.Vec2) = nil) {
	imnodes.editor_context_set_zoom(zoom, pivot)
}

// imnodes color slots (imnodes.Col enum values) used below.
INE_COL_NODE_BG        :: imnodes.Col.NodeBackground
INE_COL_NODE_BG_HOVER  :: imnodes.Col.NodeBackgroundHovered
INE_COL_NODE_BG_SELECT :: imnodes.Col.NodeBackgroundSelected
INE_COL_NODE_OUTLINE   :: imnodes.Col.NodeOutline
INE_COL_TITLE_BAR      :: imnodes.Col.TitleBar
INE_COL_TITLE_BAR_HOVERED  :: imnodes.Col.TitleBarHovered
INE_COL_TITLE_BAR_SELECTED :: imnodes.Col.TitleBarSelected
INE_COL_LINK           :: imnodes.Col.Link
INE_COL_LINK_HOVER     :: imnodes.Col.LinkHovered
INE_COL_LINK_SELECT    :: imnodes.Col.LinkSelected
INE_COL_PIN            :: imnodes.Col.Pin
INE_COL_PIN_HOVERED    :: imnodes.Col.PinHovered

// The node types. Pins distinguish them too: params = circle, graphics =
// triangle, compute = quad (all filled); show = circle outline,
// 3d object = triangle outline, image = quad outline. SHOW is the terminal
// "show 2d" node (the frame the viewport presents); OBJECT3D feeds the
// selected model's vertex stream (the stage_in ModelVertex parameter) to
// model passes; IMAGE feeds the app's textures (paper/skybox) and
SgPassKind :: enum { PARAMS, GRAPHICS, COMPUTE, SHOW, OBJECT3D, IMAGE, COMBINE, WIDGET }

SG_KIND_TAGS := [SgPassKind]string {
	.PARAMS   = "params",
	.GRAPHICS = "graphics",
	.COMPUTE  = "compute",
	.SHOW     = "output",
	.OBJECT3D = "mesh",
	.IMAGE    = "texture",
	.COMBINE  = "combine",
	.WIDGET   = "widget",
}

// Colors are ABGR-packed (a<<24|b<<16|g<<8|r) like col32() produces, written
// as constant expressions because global initializers can't call procs.
SG_KIND_COLORS := [SgPassKind]u32 {
	.PARAMS   = 0xFF << 24 | 0xC4 << 16 | 0x71 << 8 | 0x6C, // violet
	.GRAPHICS = 0xFF << 24 | 0x16 << 16 | 0x4B << 8 | 0xCB, // orange
	.COMPUTE  = 0xFF << 24 | 0xD2 << 16 | 0x8B << 8 | 0x26, // blue
	.SHOW     = 0xFF << 24 | 0x57 << 16 | 0xA8 << 8 | 0xE8, // safelight amber
	.OBJECT3D = 0xFF << 24 | 0x5C << 16 | 0xA0 << 8 | 0x58, // green
	.IMAGE    = 0xFF << 24 | 0xA5 << 16 | 0xA3 << 8 | 0x4F, // teal
	.COMBINE  = 0xFF << 24 | 0xE8 << 16 | 0x6A << 8 | 0xB0, // pink
	.WIDGET   = 0xFF << 24 | 0x2A << 16 | 0xB0 << 8 | 0xE0, // amber-gold
}

// imnodes pin shapes per node kind.
SG_KIND_PIN_SHAPES := [SgPassKind]imnodes.Pin_Shape {
	.PARAMS   = .CircleFilled,
	.GRAPHICS = .TriangleFilled,
	.COMPUTE  = .QuadFilled,
	.SHOW     = .Circle,
	.OBJECT3D = .Triangle,
	.IMAGE    = .Quad,
	.COMBINE  = .Circle,
	.WIDGET   = .CircleFilled,
}

SG_PIN_IN_COLOR  :: 0xFF << 24 | 0xE0 << 16 | 0xE0 << 8 | 0xE0 // white
SG_PIN_OUT_COLOR :: 0xFF << 24 | 0x2E << 16 | 0xE2 << 8 | 0xA6 // green


// Body tint for a kind: the kind's hue darkened and fully OPAQUE, no
// canvas bleeding through nodes. `bright` scales the kind color.
sg_kind_body :: proc(kind: SgPassKind, bright: f32) -> u32 {
	packed := SG_KIND_COLORS[kind]
	red := u32(f32(packed & 0xFF) * bright)
	green := u32(f32(packed >> 8 & 0xFF) * bright)
	blue := u32(f32(packed >> 16 & 0xFF) * bright)
	return 0xFF << 24 | blue << 16 | green << 8 | red
}

// Type icon in the title bar: a 16px glyph drawn in the 20px slot at the
// title's left, in dark-on-color (like the traffic-light glyphs). Each
// kind gets a distinct mark so node types read by shape as well as color.
// Kind icon drawn directly into the node's draw list. `zoom` scales every
// coordinate/length so the icon grows and stays centered in its 20x~16 slot
// alongside the (zoom-scaled) title text.
sg_draw_kind_icon :: proc(draw_list: ^im.DrawList, kind: SgPassKind, position: im.Vec2, color: u32, zoom: f32) {
	scale := max(zoom, 0.01)
	center_x := position.x + 10 * scale
	center_y := position.y + 8 * scale
	switch kind {
	case .PARAMS:
		// Sliders: three rails with knobs.
		knobs := [3]f32{-1.5, 2, -3}
		for knob, index in knobs {
			rail_y := center_y - 4 * scale + f32(index) * 4 * scale
			im.DrawList_AddLine(draw_list, {center_x - 5 * scale, rail_y}, {center_x + 5 * scale, rail_y}, color, 1.1 * scale)
			im.DrawList_AddCircleFilled(draw_list, {center_x + knob * scale, rail_y}, 1.6 * scale, color)
		}
	case .GRAPHICS:
		// Triangle.
		im.DrawList_AddTriangle(draw_list, {center_x, center_y - 5 * scale}, {center_x - 5 * scale, center_y + 4 * scale}, {center_x + 5 * scale, center_y + 4 * scale}, color, 1.2 * scale)
	case .COMPUTE:
		// 3x3 thread grid.
		for row in 0 ..< 3 {
			for column in 0 ..< 3 {
				cell_x := center_x - 5 * scale + f32(column) * 5 * scale
				cell_y := center_y - 5 * scale + f32(row) * 5 * scale
				im.DrawList_AddRectFilled(draw_list, {cell_x, cell_y}, {cell_x + 3 * scale, cell_y + 3 * scale}, color)
			}
		}
	case .SHOW:
		// Monitor: screen outline with a stand.
		im.DrawList_AddRect(draw_list, {center_x - 5 * scale, center_y - 5 * scale}, {center_x + 5 * scale, center_y + 2 * scale}, color, 1 * scale, 1.2 * scale)
		im.DrawList_AddLine(draw_list, {center_x, center_y + 2 * scale}, {center_x, center_y + 5 * scale}, color, 1.2 * scale)
	case .OBJECT3D:
		// Cube: back square offset from the front one, joined corners.
		im.DrawList_AddRect(draw_list, {center_x - 5 * scale, center_y - 1 * scale}, {center_x + 1 * scale, center_y + 5 * scale}, color, 0, 1.1 * scale)
		im.DrawList_AddRect(draw_list, {center_x - 1 * scale, center_y - 5 * scale}, {center_x + 5 * scale, center_y + 1 * scale}, color, 0, 1.1 * scale)
		im.DrawList_AddLine(draw_list, {center_x - 5 * scale, center_y - 1 * scale}, {center_x - 1 * scale, center_y - 5 * scale}, color, 1.1 * scale)
		im.DrawList_AddLine(draw_list, {center_x + 1 * scale, center_y + 5 * scale}, {center_x + 5 * scale, center_y + 1 * scale}, color, 1.1 * scale)
	case .IMAGE:
		// Picture: frame with a mountain and a sun dot.
		im.DrawList_AddRect(draw_list, {center_x - 5 * scale, center_y - 4 * scale}, {center_x + 5 * scale, center_y + 5 * scale}, color, 1 * scale, 1.1 * scale)
		im.DrawList_AddTriangleFilled(draw_list, {center_x - 4 * scale, center_y + 4 * scale}, {center_x, center_y - 1 * scale}, {center_x + 4 * scale, center_y + 4 * scale}, color)
		im.DrawList_AddCircleFilled(draw_list, {center_x + 2.5 * scale, center_y - 2 * scale}, 1 * scale, color)
	case .COMBINE:
		// Diamond.
		im.DrawList_AddQuadFilled(
			draw_list,
			{center_x, center_y - 5 * scale},
			{center_x + 5 * scale, center_y},
			{center_x, center_y + 5 * scale},
			{center_x - 5 * scale, center_y},
			color,
		)
	case .WIDGET:
		// Checkbox: square outline with a check inside.
		im.DrawList_AddRect(draw_list, {center_x - 4 * scale, center_y - 4 * scale}, {center_x + 4 * scale, center_y + 4 * scale}, color, 1 * scale, 1.1 * scale)
		im.DrawList_AddLine(draw_list, {center_x - 2.5 * scale, center_y + 0.5 * scale}, {center_x - 0.5 * scale, center_y + 2.5 * scale}, color, 1.3 * scale)
		im.DrawList_AddLine(draw_list, {center_x - 0.5 * scale, center_y + 2.5 * scale}, {center_x + 3 * scale, center_y - 2.5 * scale}, color, 1.3 * scale)
	}
}

SgPin :: struct {
	id:    int,
	name:  string, // owned; identity (links, save keys)
	// Display text when set (params node shows "name (type)"); identity
	// stays `name`. Owned.
	label: string,
	input: bool,
	kind:  SgBindKind,
}

SgNode :: struct {
	id:     int,
	key:    string, // "params", "gfx:scenes/apple/apple", "comp:...:computeMain"; owned
	title:  string, // display name; owned
	kind:   SgPassKind,
	file:   string, // owning slang file ("" for params); owned
	pins:   [dynamic]SgPin,
	pos:    [2]f32, // spawn/layout-loaded position (initial placement)
	cur:    [2]f32, // last known grid position (barycenter ordering input)
	pref:   [2]f32, // layered position from sg_compute_layout (initial placement)
	// True when pos came from the cascade spawn (no saved layout, no
	// right-click point): sg_compute_layout replaces it with the layered
	// pref until the node is placed. User positions are never touched.
	auto_pos: bool,
	layer:  int, // depth: right of every node linking into it
	placed: bool,
	// Index in the scene's pass chain (-1: no preview): the node's preview
	// shows this pass's output texture (params/resource nodes stay -1;
	// "show" uses the final index, i.e. scene_tex).
	pass_idx: int,
}

// Wire flavor, set from the link's semantics at creation (sg_sync):
// decides the decoration style drawn over the imnodes base link: the
// frame chain flows, texture/mesh feeds are dashed. UNIFORM is unused
// today: uniforms are wireless (broadcast/receive marks on the pins, no
// links); the value stays reserved for future use.
SgLinkFlavor :: enum { FRAME, UNIFORM, TEXTURE, MESH }

SgLink :: struct {
	id, from, to: int,
	flavor:       SgLinkFlavor,
	col:          u32, // source node's kind color, for the wire decoration
	editable:      bool,
}

// A user-authored resource node (created via right-click): an image
// (file source or empty render target) or a model file. Persisted in
// graph.json (the "file" + optional resource fields), unlike the derived
// nodes which regenerate from source.
SgPendingLinkAction :: enum { NONE, CONNECT, DISCONNECT }

SgNodeSource :: enum { FILE, TARGET }

// Sampler settings carried by an image node; mapped to
// sdl.GPUSamplerCreateInfo at binding time (cached per pair).
SgSamplerFilter :: enum { POINT, LINEAR }
SgSamplerAddress :: enum { CLAMP, REPEAT, MIRROR }

SgUserNode :: struct {
	path: string, // asset-relative ("assets/parchment.jpg"), absolute, or "" for targets; owned
	kind: SgPassKind, // .IMAGE or .OBJECT3D
	source: SgNodeSource, // file vs empty render target
	target_id: int, // unique render-target id (source == .TARGET); 0 for file nodes
	title: string, // user-set title override ("" = derived); owned
	filter: SgSamplerFilter,
	address: SgSamplerAddress,
	width, height: int, // render target size (source == .TARGET)
	value: f32, // widget nodes (.WIDGET): persisted control value
}
sg_user_key :: proc(kind: SgPassKind, path: string) -> string {
	prefix := kind == .OBJECT3D ? "uobj:" : "uimg:"
	return fmt.tprintf("%s%s", prefix, path)
}

// Stable graph key for a user node: file nodes key off the path,
// render targets off their unique id ("uimg:target:3").
sg_user_node_key :: proc(user_node: ^SgUserNode) -> string {
	if user_node.source == .TARGET {
		return fmt.tprintf("uimg:target:%d", user_node.target_id)
	}
	return sg_user_key(user_node.kind, user_node.path)
}

// File name without directory or extension, for the node title.
sg_base_title :: proc(path: string) -> string {
	base := path
	if slash := strings.last_index(base, "/"); slash >= 0 do base = base[slash + 1:]
	if dot := strings.last_index(base, "."); dot > 0 do base = base[:dot]
	return base
}

// File name with extension ("parchment.jpg"), shown in the node body.
sg_file_name :: proc(path: string) -> string {
	if slash := strings.last_index(path, "/"); slash >= 0 do return path[slash + 1:]
	return path
}

// Small lightning bolt marking an app-injected pin, drawn centered
// INSIDE the pin socket's shape where a link would attach.
sg_draw_injected :: proc(draw_list: ^im.DrawList, center_x, center_y: f32) {
	col := im.GetColorU32Vec4(ACCENT) // safelight amber
	im.DrawList_AddLine(draw_list, {center_x + 1.6, center_y - 3}, {center_x - 1.2, center_y + 0.4}, col, 1.1)
	im.DrawList_AddLine(draw_list, {center_x - 1.2, center_y + 0.4}, {center_x + 1.6, center_y + 0.4}, col, 1.1)
	im.DrawList_AddLine(draw_list, {center_x + 1.6, center_y + 0.4}, {center_x - 1.2, center_y + 3.6}, col, 1.1)
}

// Replace the alpha channel of an ABGR-packed color.
sg_alpha :: proc(color: u32, alpha: u32) -> u32 {
	return alpha << 24 | (color & 0x00FF_FFFF)
}

// Wireless-uniform marks, drawn over the pin shapes (same style as the
// injected bolt above; `zoom` scales every length so the marks track the
// editor zoom like the kind icons do). Both marks share the wireless
// accent (a light blue), and both are animated: rings radiate outward on
// the emitter, converge inward on the receiver.

// The wireless accent: a light blue, distinct from every node kind hue
// so the uniform feed reads as its own signal, not a node's wire.
SG_WIRELESS_COLOR :: 0xFF << 24 | 0xFF << 16 | 0xC8 << 8 | 0x7A // light blue (ABGR)

// Rings shared by both wireless marks: `grow` true expands outward
// (emitter), false converges inward (receiver). Two staggered rings on a
// ~1.6s loop; alpha fades as the ring travels.
sg_draw_wireless_rings :: proc(
	draw_list: ^im.DrawList,
	center: im.Vec2,
	base_radius, span: f32,
	color: u32,
	zoom: f32,
	now: f64,
	grow: bool,
) {
	scale := max(zoom, 0.01)
	phase := f32(math.mod(now * 0.625, 1.0))
	for k in 0 ..< 2 {
		t := math.mod(phase + f32(k) * 0.5, 1.0)
		radius :=
			(base_radius + span * t) * scale if grow else
			(base_radius + span - span * t) * scale
		alpha :=
			u32(f32(0x90) * (1.0 - t)) if grow else
			u32(f32(0x30) + f32(0x60) * t)
		im.DrawList_AddCircle(draw_list, center, radius, sg_alpha(color, alpha), 0, 1.2 * scale)
	}
}

// Broadcast mark on a params node's cbuffer output: draws the ball (a
// filled light-blue disc covering the imnodes pin socket) plus two
// concentric rings pulsing outward (expanding radius, fading alpha, on a
// ~1.6s loop). Drawn after EndNodeEditor so it sits over the socket.
sg_draw_broadcast_mark :: proc(draw_list: ^im.DrawList, center_x, center_y: f32, zoom: f32, now: f64) {
	center := im.Vec2{center_x, center_y}
	im.DrawList_AddCircleFilled(draw_list, center, 4.2 * max(zoom, 0.01), SG_WIRELESS_COLOR)
	sg_draw_wireless_rings(draw_list, center, 4.2, 9.0, SG_WIRELESS_COLOR, zoom, now, true)
}

// Receive mark on a pass's cbuffer input: two concentric rings converging
// inward toward the pin (shrinking radius, brightening alpha), in the
// same light blue as the broadcast: the signal arriving.
sg_draw_receive_mark :: proc(draw_list: ^im.DrawList, center_x, center_y: f32, zoom: f32, now: f64) {
	center := im.Vec2{center_x, center_y}
	sg_draw_wireless_rings(draw_list, center, 4.2, 8.8, SG_WIRELESS_COLOR, zoom, now, false)
}


NodeGraph :: struct {
	handle:      ^imnodes.Editor_Context,
	nodes:       [dynamic]SgNode,
	links:       [dynamic]SgLink,
	next_id:     int,
	// Stable imnodes ids per string key ("node:gfx:...", "pin:...:Uniforms",
	// "link:3:7") so rescanning keeps node positions.
	ids:         map[string]int,
	spawn_count: int,
	user_nodes:   [dynamic]SgUserNode,
	file_pick:    SgPassKind, // kind being file-picked this popup
	pick_open:    bool, // open the native file dialog this frame (outside popups)
	swap_key:     string, // user node key pending a file swap via context menu (owned)
	delete_key:   string, // user node key pending delete via context menu (owned)
	rename_key:   string, // user node key pending rename (owned)
	rename_buf:   [64]u8, // rename InputText scratch buffer
	sync_frame:  int,
	// The scene unit this graph belongs to ("" before the first frame) and
	// the layout loaded from its graph.json (node key -> grid pos).
	scene:       string,
	layout:      map[string][2]f32,

	// A node's "+" button was clicked this frame: open the create popup.
	create_open: bool,
	// Node previews (the pass output thumbnail inside each pass node);
	// toggled in the GRAPH panel header.
	show_previews: bool,
	// Right-click creation: the new node spawns at the clicked grid point
	// (consumed by sg_upsert_node when the created pass's node appears).
	create_pos:     im.Vec2,
	create_pos_set: bool,
	save_pending: bool, // persist graph.json after the next sync
	saved_links: [dynamic]SgGraphLinkJson,
	graph_mtime: time.Time,
	graph_authoritative: bool,
	pipeline_error: string,
	pending_action: SgPendingLinkAction,
	pending_from, pending_to, pending_link_id: int,
	// Trackpad pan momentum: while the fingers scroll, deltas move the
	// panning 1:1 and the gesture velocity is sampled here; on release
	// the velocity glides on with exponential friction (the "ice").
	pan_vel: [2]f32,
	// Layered layout: node index pairs per link (rebuilt each sync by
	// sg_compute_layout for depth + barycenter ordering).
	link_pairs: [dynamic][2]int,
	// Node id whose context menu is open (##node_user_menu): user nodes
	// offer swap/delete, combine nodes offer delete only.
	menu_node_id: int,
}

// Default size for a new render-target image node (fixed at creation;
// editable later in the node body).
SG_TARGET_DEFAULT_WIDTH  :: 1280
SG_TARGET_DEFAULT_HEIGHT :: 720

// Stable id for a namespaced key.
sg_id :: proc(ng: ^NodeGraph, key: string) -> int {
	if v, ok := ng.ids[key]; ok do return v
	v := ng.next_id
	ng.next_id += 1
	ng.ids[strings.clone(key)] = v
	return v
}

// --- Lightweight .slang interface parsing ---------------------------------
// All parsed strings are slices into the file text, which the caller owns
// for the duration of a sync pass.

SgBindKind :: enum { CBUFFER, TEXTURE, SAMPLER, RWTEXTURE, BUFFER }

SgBinding :: struct {
	name: string,
	kind: SgBindKind,
	// CBUFFER only: the generic argument (`ConstantBuffer<HelloParams>`
	// -> "HelloParams"), for display. Slice into the file text.
	type_name: string,
}

SgEntryKind :: enum { COMPUTE, VERTEX, FRAGMENT }

SgEntry :: struct {
	kind: SgEntryKind,
	name: string,
	line: int,
}

SgFileInfo :: struct {
	text:       string, // owned by the sync pass
	bind_in:    [dynamic]SgBinding,
	bind_out:   [dynamic]SgBinding, // RWTexture outputs
	entries:    [dynamic]SgEntry,
	uses_model: bool, // a vertex entry takes the ModelVertex stage_in struct
	// Non-empty for combinator files: the op from the first-line marker
	// "// graph-node: combine <OP>" (ADD/MUL/AND/OR/NOT). A slice into
	// text (not owned).
	combine_op: string,
}

sg_is_ident :: proc(b: u8) -> bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

sg_last_word :: proc(text: string) -> string {
	trimmed := strings.trim_space(text)
	for i := len(trimmed) - 1; i >= 0; i -= 1 {
		if !sg_is_ident(trimmed[i]) {
			return trimmed[i + 1:]
		}
	}
	return trimmed
}

// Extracts the variable name from a binding declaration line: the
// identifier right before the trailing ';'.
sg_binding_name :: proc(line: string) -> (string, bool) {
	semi := strings.index(line, ";")
	if semi < 0 do return "", false
	name := sg_last_word(line[:semi])
	if name == "" || name == "SamplerState" do return "", false
	return name, true
}

sg_parse_file :: proc(text: string) -> SgFileInfo {
	info: SgFileInfo
	info.text = text
	pending := -1 // SgEntryKind of the last [shader("...")] attribute, -1 none
	for line, lineno in strings.split_lines(text, context.temp_allocator) {
		if line == "" do continue
		trimmed := strings.trim_space(line)
		// Combinator marker: first comment line of the file carrying it
		// (the generated template puts it on line 1).
		if info.combine_op == "" && strings.has_prefix(trimmed, "// graph-node: combine ") {
			info.combine_op = trimmed[len("// graph-node: combine "):]
			continue
		}
		if trimmed == "" || strings.has_prefix(trimmed, "//") do continue
		if strings.has_prefix(trimmed, `[shader("`) {
			rest := trimmed[len(`[shader("`):]
			if end := strings.index(rest, `"`); end > 0 {
				switch rest[:end] {
				case "compute":  pending = int(SgEntryKind.COMPUTE)
				case "vertex":   pending = int(SgEntryKind.VERTEX)
				case "fragment": pending = int(SgEntryKind.FRAGMENT)
				}
			}
			continue
		}
		if line[0] == ' ' || line[0] == '\t' || line[0] == '/' || line[0] == '[' do continue
		rest := line
		if strings.has_prefix(rest, "public ") do rest = rest[len("public "):]
		switch {
		case strings.contains(rest, "RWTexture"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_out, SgBinding{name, .RWTEXTURE, ""})
			}
		case strings.contains(rest, "ConstantBuffer<"):
			if name, ok := sg_binding_name(rest); ok {
				type_name := ""
				if lt := strings.index(rest, "<"); lt >= 0 {
					if gt := strings.index(rest[lt + 1:], ">"); gt > 0 {
						type_name = rest[lt + 1:][:gt]
					}
				}
				append(&info.bind_in, SgBinding{name, .CBUFFER, type_name})
			}
		case strings.contains(rest, "Texture2D<"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_in, SgBinding{name, .TEXTURE, ""})
			}
		case strings.has_prefix(rest, "SamplerState"):
			if name, ok := sg_binding_name(rest); ok {
				append(&info.bind_in, SgBinding{name, .SAMPLER, ""})
			}
		case strings.contains(rest, "(") && !strings.has_suffix(trimmed, ";"):
			// Top-level function definition: name is the word before '('. A
			// pending [shader("...")] attribute makes it an entry point.
			name := sg_last_word(rest[:strings.index(rest, "(")])
			if pending >= 0 && name != "" {
				// A vertex entry taking ModelVertex: the runtime feeds the
				// selected model's vertex stream (modelview-style).
				if SgEntryKind(pending) == .VERTEX && strings.contains(rest, "ModelVertex") {
					info.uses_model = true
				}
				append(&info.entries, SgEntry{SgEntryKind(pending), name, lineno})
				pending = -1
			}
		}
	}
	return info
}

sg_free_info :: proc(info: ^SgFileInfo) {
	delete(info.text)
	delete(info.bind_in)
	delete(info.bind_out)
	delete(info.entries)
}

sg_node_pin :: proc(ng: ^NodeGraph, pin_id: int) -> (^SgNode, ^SgPin, bool) {
	for &node in ng.nodes {
		for &pin in node.pins {
			if pin.id == pin_id do return &node, &pin, true
		}
	}
	return nil, nil, false
}

sg_pin_endpoint :: proc(ng: ^NodeGraph, pin_id: int) -> string {
	node, pin, ok := sg_node_pin(ng, pin_id)
	if !ok do return "?"
	return pipeline_endpoint(node.key, pin.name)
}

sg_resolve_endpoint :: proc(ng: ^NodeGraph, endpoint: string) -> int {
	for &node in ng.nodes {
		for &pin in node.pins {
			if endpoint == pipeline_endpoint(node.key, pin.name) do return pin.id
		}
	}
	return -1
}
sg_is_pass_kind :: proc(kind: SgPassKind) -> bool {
	return kind == .GRAPHICS || kind == .COMPUTE || kind == .COMBINE
}

sg_node_id_for_pin :: proc(ng: ^NodeGraph, pin_id: int) -> int {
	for &node in ng.nodes {
		for pin in node.pins do if pin.id == pin_id do return node.id
	}
	return -1
}

// Looks up the user-node record backing a graph node; nil for derived
// nodes (params/show/passes/combine/legacy structural image/object3d).
sg_user_source_for_node :: proc(ng: ^NodeGraph, node: ^SgNode) -> ^SgUserNode {
	for i in 0 ..< len(ng.user_nodes) {
		if sg_user_node_key(&ng.user_nodes[i]) == node.key {
			return &ng.user_nodes[i]
		}
	}
	return nil
}

// Breadth-first pass-node reachability for the cycle check. Edges whose
// SOURCE is a target-mode image node's `texture` output are DELAYED (the
// reader consumes last frame's completed texture, not this frame's
// write), so they never create a frame-order cycle and are skipped here.
sg_path_exists :: proc(ng: ^NodeGraph, from_node, to_node: int) -> bool {
	queue := make([dynamic]int, 0, len(ng.nodes), context.temp_allocator)
	seen := make(map[int]bool, len(ng.nodes), context.temp_allocator)
	append(&queue, from_node)
	seen[from_node] = true
	for cursor := 0; cursor < len(queue); cursor += 1 {
		current := queue[cursor]
		if current == to_node do return true
		for link in ng.links {
			if !link.editable do continue
			if sg_link_is_delayed_target_read(ng, link) do continue
			link_source := sg_node_id_for_pin(ng, link.from)
			link_target := sg_node_id_for_pin(ng, link.to)
			if link_source != current || link_target < 0 || seen[link_target] do continue
			seen[link_target] = true
			append(&queue, link_target)
		}
	}
	return false
}

// True when the link leaves a target-mode image node's `texture` output:
// the reader sees the PREVIOUS frame's content (ping-pong read side).
sg_link_is_delayed_target_read :: proc(ng: ^NodeGraph, link: SgLink) -> bool {
	source_node, source_pin, ok := sg_node_pin(ng, link.from)
	if !ok || source_pin.input do return false
	if source_node.kind != .IMAGE || source_pin.name != "texture" do return false
	user_source := sg_user_source_for_node(ng, source_node)
	return user_source != nil && user_source.source == .TARGET
}

// Validates a pipeline edge between pins (either order; normalized so
// `from` is the output). Rules by endpoint kind:
//   - outputs: a pass's TEXTURE/RWTEXTURE, or a user resource node's
//     texture/BUFFER output (identified by node kind + user-node source,
//     NOT by key prefix — legacy "image"/"object3d" structural nodes
//     never save as a source).
//   - inputs: a pass's TEXTURE/BUFFER (ModelVertex), the viewport's
//     frame (pass outputs only), or a target-mode image node's `write`
//     pin (pass outputs only: ping-pong feedback).
// An input already holding an editable link is allowed: sg_connect
// replaces it. Resource sources never create cycles EXCEPT the
// image(target).texture -> pass edge, which is delayed (reads last
// frame's result): sg_path_exists skips delayed edges, so the cycle
// check still runs only for pass sources.
sg_validate_connection :: proc(ng: ^NodeGraph, pin_a, pin_b: int) -> (from, to: int, error_message: string, ok: bool) {
	from_id, to_id := pin_a, pin_b
	an, ap, aok := sg_node_pin(ng, from_id)
	bn, bp, bok := sg_node_pin(ng, to_id)
	if !aok || !bok do return -1, -1, "unknown pin", false
	if ap.input == bp.input do return -1, -1, "connect one output to one input", false
	if ap.input {
		an, bn = bn, an
		ap, bp = bp, ap
		from_id, to_id = to_id, from_id
	}
	user_source := sg_user_source_for_node(ng, an)
	source_is_pass := sg_is_pass_kind(an.kind)
	source_is_resource: bool
	source_is_resource =
		(an.kind == .IMAGE && ap.kind == .TEXTURE && user_source != nil) ||
		(an.kind == .IMAGE && ap.kind == .SAMPLER && user_source != nil) ||
		(an.kind == .OBJECT3D && ap.kind == .BUFFER && user_source != nil)
	target_is_pass := sg_is_pass_kind(bn.kind)
	target_user_source := sg_user_source_for_node(ng, bn)
	if !target_is_pass && bn.kind != .SHOW && !(bn.kind == .IMAGE && bp.input && target_user_source != nil && target_user_source.source == .TARGET) {
		return -1, -1, "pipeline edges must end at a pass, viewport, or target write", false
	}
	if bn.kind == .SHOW {
		if !source_is_pass {
			return -1, -1, "viewport takes a pass output", false
		}
		if bp.kind != .TEXTURE || (ap.kind != .TEXTURE && ap.kind != .RWTEXTURE) {
			return -1, -1, "type mismatch", false
		}
	} else if bn.kind == .IMAGE {
		// Target write: only pass outputs feed it (delayed read side
		// renders the previous frame; file images have no input).
		if !source_is_pass {
			return -1, -1, "target write takes a pass output", false
		}
		if bp.kind != .TEXTURE || (ap.kind != .TEXTURE && ap.kind != .RWTEXTURE) {
			return -1, -1, "type mismatch", false
		}
	} else {
		// Pass targets: type must match exactly (TEXTURE<->TEXTURE,
		// SAMPLER<->SAMPLER, BUFFER<->BUFFER).
		if bp.kind != ap.kind {
			return -1, -1, "type mismatch", false
		}
		if ap.kind != .TEXTURE && ap.kind != .RWTEXTURE && ap.kind != .BUFFER && ap.kind != .SAMPLER {
			return -1, -1, "type mismatch", false
		}
	}
	if an.id == bn.id do return -1, -1, "a pass cannot feed itself", false
	for link in ng.links {
		if link.from == from_id && link.to == to_id do return -1, -1, "link already exists", false
	}
	if source_is_pass && bn.kind != .SHOW && sg_path_exists(ng, bn.id, an.id) {
		return -1, -1, "connection would create a cycle", false
	}
	return from_id, to_id, "", true
}

// Replaces-and-appends a UI connection: the input's previous editable
// link is removed first (one producer per input), then the new edge is
// appended. Load-time code goes through sg_validate_connection instead.
sg_connect :: proc(ng: ^NodeGraph, from, to: int) {
	for link, i in ng.links {
		if link.editable && link.to == to {
			ordered_remove(&ng.links, i)
			break
		}
	}
	sg_append_pipeline_link(ng, from, to)
}

// Appends an editable link; the wire flavor follows the semantics (the
// frame chain flows, texture/mesh feeds dashed) and col carries the
// source node's kind color for the per-link tint.
sg_append_pipeline_link :: proc(ng: ^NodeGraph, from, to: int) {
	node, pin, ok := sg_node_pin(ng, from)
	if !ok do return
	flavor := SgLinkFlavor.FRAME
	if pin != nil {
		if pin.kind == .BUFFER do flavor = .MESH
		if pin.kind == .TEXTURE || pin.kind == .RWTEXTURE do flavor = .TEXTURE
	}
	append(
		&ng.links,
		SgLink {
			id = sg_id(ng, fmt.tprintf("link:%d:%d", from, to)),
			from = from,
			to = to,
			flavor = flavor,
			col = SG_KIND_COLORS[node.kind],
			editable = true,
		},
	)
}

sg_remove_pipeline_link :: proc(ng: ^NodeGraph, link_id: int) -> bool {
	for link, i in ng.links {
		if link.id != link_id || !link.editable do continue
		ordered_remove(&ng.links, i)
		return true
	}
	return false
}

// --- graph.json persistence ------------------------------------------------
// Nodes carry presentation/layout state; links are the authoritative runtime
// topology. Shader reflection still owns the available typed ports.

sg_graph_path :: proc(scene: string) -> string {
	return pipeline_graph_path(scene)
}

sg_clear_saved_links :: proc(ng: ^NodeGraph) {
	for &link in ng.saved_links {
		delete(link.from)
		delete(link.to)
	}
	clear(&ng.saved_links)
}

// Frees every user node's owned strings and clears the slice.
sg_clear_user_nodes :: proc(ng: ^NodeGraph) {
	for i in 0 ..< len(ng.user_nodes) {
		delete(ng.user_nodes[i].path)
		delete(ng.user_nodes[i].title)
	}
	clear(&ng.user_nodes)
}

// Maps a saved Node_Json onto a SgUserNode, applying the schema defaults
// for absent fields (file source, linear filter, clamp address, 1280x720
// target size). Legacy rows (no "source") with a file stay file nodes.
sg_user_node_from_json :: proc(saved: SgGraphNodeJson) -> SgUserNode {
	user_node := SgUserNode{path = strings.clone(saved.file), kind = .IMAGE}
	if strings.has_prefix(saved.key, "uobj:") do user_node.kind = .OBJECT3D
	switch saved.source {
	case "target":
		user_node.source = .TARGET
		user_node.path = ""
		user_node.width = saved.width == 0 ? SG_TARGET_DEFAULT_WIDTH : saved.width
		user_node.height = saved.height == 0 ? SG_TARGET_DEFAULT_HEIGHT : saved.height
		if id := sg_target_id_from_key(saved.key); id > 0 do user_node.target_id = id
	case:
		user_node.source = .FILE
	}
	switch saved.filter {
	case "point":
		user_node.filter = .POINT
	case:
		user_node.filter = .LINEAR
	}
	switch saved.address {
	case "repeat":
		user_node.address = .REPEAT
	case "mirror":
		user_node.address = .MIRROR
	case:
		user_node.address = .CLAMP
	}
	if saved.title != "" do user_node.title = strings.clone(saved.title)
	user_node.value = saved.value
	return user_node
}

// Parses the trailing integer of a "uimg:target:<id>" key; 0 when absent.
sg_target_id_from_key :: proc(key: string) -> int {
	prefix := "uimg:target:"
	if !strings.has_prefix(key, prefix) do return 0
	id, _ := strconv.parse_int(key[len(prefix):])
	return id
}

sg_load_layout :: proc(ng: ^NodeGraph, scene: string) -> bool {
	path := sg_graph_path(scene)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	doc: SgGraphJson
	if json.unmarshal(data, &doc, allocator = context.temp_allocator) != nil {
		delete(ng.pipeline_error)
		ng.pipeline_error = strings.clone("invalid graph.json")
		return false
	}
	if doc.version != 0 && doc.version != PIPELINE_SCHEMA_VERSION {
		delete(ng.pipeline_error)
		ng.pipeline_error = strings.clone(fmt.tprintf("unsupported graph schema version %d", doc.version))
		return false
	}
	ng.graph_authoritative = doc.version == PIPELINE_SCHEMA_VERSION

	for layout_key, _ in ng.layout do delete(layout_key)
	clear(&ng.layout)
	sg_clear_user_nodes(ng)
	sg_clear_saved_links(ng)
	for saved_node in doc.nodes {
		ng.layout[strings.clone(saved_node.key)] = {saved_node.x, saved_node.y}
		if saved_node.file != "" || strings.has_prefix(saved_node.key, "uimg:target:") {
			user_node := sg_user_node_from_json(saved_node)
			append(&ng.user_nodes, user_node)
		}
		// Persisted widget value overrides the reflection default.
		if strings.has_prefix(saved_node.key, "ui:") {
			field := saved_node.key[len("ui:"):]
			for &widget in sg_node_widgets {
				if widget.label != field do continue
				if widget.kind == .TOGGLE {
					widget.on = saved_node.value != 0
				} else if widget.kind == .SLIDER {
					widget.value[0] = saved_node.value
				}
				break
			}
		}
	}
	for link in doc.links {
		append(
			&ng.saved_links,
			SgGraphLinkJson{from = strings.clone(link.from), to = strings.clone(link.to)},
		)
	}
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err == nil {
		ng.graph_mtime = info.modification_time
	}
	delete(ng.pipeline_error)
	ng.pipeline_error = ""
	return true
}

sg_reload_if_changed :: proc(ng: ^NodeGraph) {
	if ng.scene == "" do return
	info, err := os.stat(sg_graph_path(ng.scene), context.temp_allocator)
	if err != nil || time.diff(info.modification_time, ng.graph_mtime) == 0 do return
	if !sg_load_layout(ng, ng.scene) do return
	for &node in ng.nodes {
		if pos, ok := ng.layout[node.key]; ok {
			node.pos = pos
			node.cur = pos
			node.placed = false
			node.auto_pos = false
		}
	}
	ng.sync_frame = 0
}

sg_save :: proc(ng: ^NodeGraph) {
	if ng.scene == "" || len(ng.nodes) == 0 do return
	pin_names := make(map[int]string, 64, context.temp_allocator)
	for &node in ng.nodes {
		for &pin in node.pins do pin_names[pin.id] = fmt.tprintf("%s:%s", node.key, pin.name)
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"version":`)
	fmt.sbprintf(&sb, "%d", PIPELINE_SCHEMA_VERSION)
	strings.write_string(&sb, `,"scene":"`)
	strings.write_string(&sb, ng.scene)
	strings.write_string(&sb, `","nodes":[`)
	for &node, node_i in ng.nodes {
		if node_i > 0 do strings.write_byte(&sb, ',')
		// Outside the editor scope imnodes' pool may not hold this node
		// (scene switch), so fall back to the last known grid position.
		position := ine_scope_active() ? ine_get_node_grid_pos(node.id) : im.Vec2{node.cur.x, node.cur.y}
		pos_x, pos_y := position.x, position.y
		strings.write_string(&sb, `{"key":"`)
		strings.write_string(&sb, node.key)
		strings.write_string(&sb, `","kind":"`)
		strings.write_string(&sb, SG_KIND_TAGS[node.kind])
		fmt.sbprintf(&sb, `","x":%.1f,"y":%.1f`, pos_x, pos_y)
		if user_source := sg_user_source_for_node(ng, &node); user_source != nil {
			if user_source.source == .TARGET {
				fmt.sbprintf(&sb, `,"source":"target","width":%d,"height":%d`, user_source.width, user_source.height)
			} else {
				strings.write_string(&sb, `,"file":"`)
				strings.write_string(&sb, user_source.path)
				strings.write_byte(&sb, '"')
				if user_source.filter == .POINT {
					strings.write_string(&sb, `,"filter":"point"`)
				}
				#partial switch user_source.address {
				case .REPEAT:
					strings.write_string(&sb, `,"address":"repeat"`)
				case .MIRROR:
					strings.write_string(&sb, `,"address":"mirror"`)
				}
			}
			if user_source.title != "" {
				strings.write_string(&sb, `,"title":"`)
				strings.write_string(&sb, user_source.title)
				strings.write_byte(&sb, '"')
			}
			if strings.has_prefix(node.key, "ui:") {
				if widget := sg_widget_by_label(node.key[len("ui:"):]); widget != nil {
					if widget.kind == .TOGGLE {
						fmt.sbprintf(&sb, `,"value":%g`, widget.on ? 1.0 : 0.0)
					} else {
						fmt.sbprintf(&sb, `,"value":%g`, widget.value[0])
					}
				}
			} else if user_source.value != 0 {
				fmt.sbprintf(&sb, `,"value":%g`, user_source.value)
			}
		}
		strings.write_byte(&sb, '}')
	}
	strings.write_string(&sb, `],"links":[`)
	for link, link_i in ng.links {
		from_name, from_ok := pin_names[link.from]
		to_name, to_ok := pin_names[link.to]
		if !from_ok || !to_ok do continue
		if link_i > 0 do strings.write_byte(&sb, ',')
		strings.write_string(&sb, `{"from":"`)
		strings.write_string(&sb, from_name)
		strings.write_string(&sb, `","to":"`)
		strings.write_string(&sb, to_name)
		strings.write_string(&sb, `"}`)
	}
	strings.write_string(&sb, `]}`)
	path := sg_graph_path(ng.scene)
	// Atomic write: a second app instance (or a crash mid-write) can
	// truncate a direct overwrite, leaving invalid JSON that rejects the
	// scene's pipeline forever. Write to a sibling temp file, then swap.
	tmp_path := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp_path, transmute([]u8)strings.to_string(sb)) != nil {
		log.errorf("[node-graph] failed to write %s", tmp_path)
		return
	}
	if os.rename(tmp_path, path) != nil {
		log.errorf("[node-graph] failed to swap %s into place", path)
		os.remove(tmp_path)
		return
	}
	ng.graph_authoritative = true
	sg_clear_saved_links(ng)
	for link in ng.links {
		from_name, from_ok := pin_names[link.from]
		to_name, to_ok := pin_names[link.to]
		if !from_ok || !to_ok do continue
		append(&ng.saved_links, SgGraphLinkJson{from = strings.clone(from_name), to = strings.clone(to_name)})
	}
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err == nil {
		ng.graph_mtime = info.modification_time
	}
}

sg_clear_graph :: proc(ng: ^NodeGraph) {
	for &node in ng.nodes {
		for &pin in node.pins { delete(pin.name); delete(pin.label) }
		delete(node.pins)
		delete(node.key)
		delete(node.title)
		delete(node.file)
	}
	clear(&ng.nodes)
	clear(&ng.links)
	ng.spawn_count = 0
	for layout_key, _ in ng.layout do delete(layout_key)
	clear(&ng.layout)
	for user_node in ng.user_nodes do delete(user_node.path)
	clear(&ng.user_nodes)
	sg_clear_saved_links(ng)
	delete(ng.pipeline_error)
	ng.pipeline_error = ""
	ng.graph_mtime = {}
	ng.graph_authoritative = false
	ng.pending_action = .NONE
	if ng.delete_key != "" {
		delete(ng.delete_key)
		ng.delete_key = ""
	}
	if ng.swap_key != "" {
		delete(ng.swap_key)
		ng.swap_key = ""
	}
	delete(ng.scene)
	ng.scene = ""
}

// --- Graph construction ----------------------------------------------------

// One render pass found in the scene's files.
SgPassDesc :: struct {
	key:   string,
	title: string,
	file:  string,
	kind:  SgPassKind,
	order: int, // file list index * 10000 + entry line
}

// Templates for passes created from a node's "+" button: a chained pass
// samples the previous pass's frame via input_tex and produces its own
// output. The file lands in the scene unit's directory; the graph picks it
// up on the next sync and chains it (passes order by file name, so
// pass_1 < pass_2 < ...).
SG_TEMPLATE_COMPUTE :: `// Compute pass created from the node graph. Reads the previous pass's
// frame (input_tex) and writes out_tex; replace the passthrough with
// your effect.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 uv = (float2(id.xy) + 0.5) / Uniforms.iResolution.xy;
    out_tex[id.xy] = input_tex.Sample(input_sampler, uv);
}
`

SG_TEMPLATE_GRAPHICS :: `// Graphics pass created from the node graph. Fullscreen triangle sampling
// the previous pass's frame (input_tex); replace the passthrough with
// your shading.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    return input_tex.Sample(input_sampler, uv);
}
`

// Creates a pass file (pass_N.slang) in the current scene's directory from
// the kind's template and forces a graph resync. Returns the new file's
// rel name ("" on failure).
sg_create_pass :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor, kind: SgPassKind) -> string {
	dir := fmt.tprintf("%s/%s", scene_root_dir(ng.scene), ng.scene)
	source := kind == .GRAPHICS ? SG_TEMPLATE_GRAPHICS : SG_TEMPLATE_COMPUTE
	for n := 1; n < 100; n += 1 {
		name := fmt.tprintf("pass_%d", n)
		path := fmt.tprintf("%s/%s.slang", dir, name)
		if os.exists(path) do continue
		if os.write_entire_file(path, transmute([]u8)source) != nil {
			log.errorf("[node-graph] failed to write %s", path)
			return ""
		}
		log.infof("[node-graph] created %s", path)
		ied_rescan(ed)
		ng.sync_frame = 0 // force resync on the next panel frame
		return fmt.tprintf("%s%s", ied_unit_prefix(ng.scene), name)
	}
	return ""
}

sg_add_pin :: proc(ng: ^NodeGraph, node: ^SgNode, name: string, kind: SgBindKind, input: bool) {
	key := fmt.tprintf("pin:%s:%s", node.key, name)
	append(&node.pins, SgPin{id = sg_id(ng, key), name = strings.clone(name), input = input, kind = kind})
}

SG_COMBINE_OPS := [?]string{"ADD", "MUL", "AND", "OR", "NOT"}

// Fragment body per combine op (see the plan's table; ADD is the
// alpha-over composite, the rest are per-channel in all 4 channels).
sg_combine_body :: proc(op: string) -> string {
	switch op {
	case "ADD":
		return `float oa = a.a + b.a * (1.0 - a.a); float3 rgb = oa > 1e-6 ? (a.rgb * a.a + b.rgb * b.a * (1.0 - a.a)) / oa : float3(0.0, 0.0, 0.0); return float4(rgb, oa);`
	case "MUL": return `return a * b;`
	case "AND": return `return min(a, b);`
	case "OR":  return `return max(a, b);`
	case "NOT": return `return float4(1.0 - a.rgb, a.a);`
	}
	return ""
}

SG_TEMPLATE_COMBINE :: `// graph-node: combine @OP@
// Combinator created from the node graph: a @OP@ of its two inputs.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> a_tex;

[[vk::binding(2, 0)]]
SamplerState a_sampler;

[[vk::binding(3, 0)]]
Texture2D<float4> b_tex;

[[vk::binding(4, 0)]]
SamplerState b_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    float4 a = a_tex.Sample(a_sampler, uv);
    float4 b = b_tex.Sample(b_sampler, uv);
    @BODY@
}
`

// Creates a combinator file (combine_<op>[_N].slang) in the current
// scene's directory and forces a graph resync. The file's first line
// marks it; sg_sync turns it into a COMBINE node next frame.
sg_create_combine :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor, op: string) {
	valid := false
	for candidate in SG_COMBINE_OPS do if candidate == op do valid = true
	if !valid do return
	dir := fmt.tprintf("%s/%s", scene_root_dir(ng.scene), ng.scene)
	name := fmt.tprintf("combine_%s", strings.to_lower(op, context.temp_allocator))
	suffix := 0
	for {
		candidate := suffix == 0 ? name : fmt.tprintf("%s_%d", name, suffix)
		if !os.exists(fmt.tprintf("%s/%s.slang", dir, candidate)) {
			name = candidate
			break
		}
		suffix += 1
	}
	body := sg_combine_body(op)
	// Marker replacement, NOT fmt.tprintf: the Odin formatter consumes
	// { } braces as nested-format syntax and mangled every function body
	// in the template (%!(MISSING CLOSE BRACE)).
	source, _ := strings.replace(SG_TEMPLATE_COMBINE, "@OP@", op, -1)
	source, _ = strings.replace(source, "@BODY@", body, -1)
	path := fmt.tprintf("%s/%s.slang", dir, name)
	if os.write_entire_file(path, transmute([]u8)source) != nil {
		log.errorf("[node-graph] failed to write %s", path)
		return
	}
	log.infof("[node-graph] created %s", path)
	ied_rescan(ed)
	ng.sync_frame = 0 // force resync on the next panel frame
}

// Deletes the combinator file behind a COMBINE node, but only while it
// still carries the marker line (never a user-edited pass). The links
// that mention the node vanish on the next sync (the node is gone) and
// sg_save rewrites graph.json without them.
sg_delete_combine :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor, key: string) {
	file_name := ""
	if strings.has_prefix(key, "gfx:") {
		file_name = key[len("gfx:"):]
	} else if strings.has_prefix(key, "comp:") {
		// comp:<file>:<entry>: strip the trailing ":<entry>".
		body := key[len("comp:"):]
		if colon := strings.last_index(body, ":"); colon >= 0 do file_name = body[:colon]
	}
	if file_name == "" do return
	path := fmt.tprintf("%s/%s.slang", SHADER_DIR, file_name)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return
	text := string(data)
	if trimmed := strings.trim_space(text); !strings.has_prefix(trimmed, "// graph-node: combine") {
		log.warnf("[node-graph] refusing to delete %s: not a combinator file", path)
		return
	}
	if os.remove(path) != nil {
		log.errorf("[node-graph] failed to delete %s", path)
		return
	}
	log.infof("[node-graph] deleted %s", path)
	ied_rescan(ed)
	ng.sync_frame = 0
}



// Registers a user-authored resource node (file or render target); the
// next sync upserts it (at the right-clicked grid point) and graph.json
// persists it. Render targets key off a unique integer id — their "path"
// is empty and their identity never collides with file nodes.
sg_create_user_node :: proc(ng: ^NodeGraph, kind: SgPassKind, path: string) -> ^SgUserNode {
	key := sg_user_key(kind, path)
	for i in 0 ..< len(ng.user_nodes) {
		if sg_user_key(ng.user_nodes[i].kind, ng.user_nodes[i].path) == key {
			return &ng.user_nodes[i] // already on the canvas
		}
	}
	node := SgUserNode{path = strings.clone(path), kind = kind}
	append(&ng.user_nodes, node)
	log.infof("[node-graph] created %s node for %s", SG_KIND_TAGS[kind], path)
	ng.sync_frame = 0 // force resync on the next panel frame
	ng.save_pending = true
	return &ng.user_nodes[len(ng.user_nodes) - 1]
}

// Registers an empty render-target image node with fixed RGBA8 size.
// The unique target id persists via graph.json so reloads keep identity;
// nodes keyed "uimg:target:<id>" never collide with file-path keys.
sg_create_target_node :: proc(ng: ^NodeGraph, kind: SgPassKind, width, height: int) -> ^SgUserNode {
	next_id := 1
	for &user_node in ng.user_nodes {
		if user_node.source == .TARGET && user_node.width == width && user_node.height == height {
			return &user_node // already on the canvas
		}
		if user_node.source == .TARGET && user_node.target_id >= next_id {
			next_id = user_node.target_id + 1
		}
	}
	node := SgUserNode{path = "", kind = kind, source = .TARGET, target_id = next_id, width = width, height = height}
	append(&ng.user_nodes, node)
	target := &ng.user_nodes[len(ng.user_nodes) - 1]
	log.infof("[node-graph] created %s render target %dx%d (target id %d)", SG_KIND_TAGS[kind], width, height, next_id)
	ng.sync_frame = 0
	ng.save_pending = true
	return target
}

// Opens the native file dialog (blocking, called outside any ImGui popup
// so the modal is not swallowed by the popup's begin/end scope), then
// creates or swaps the user node with the chosen path. Paths inside the
// working directory are stored relative to it; anything else absolute.
sg_pick_file :: proc(ng: ^NodeGraph) {
	kind := ng.file_pick
	title := "choose image" if kind == .IMAGE else "choose model"
	filters: []string
	if kind == .IMAGE {
		fixed := NATIVE_FILTER_IMAGE
		filters = fixed[:]
	} else {
		fixed := NATIVE_FILTER_MODEL
		filters = fixed[:]
	}
	path, ok := native_open_file(title, filters)
	if !ok do return
	wd, wd_err := os.get_working_directory(context.temp_allocator)
	if wd_err == nil && strings.has_prefix(path, wd) && len(path) > len(wd) && path[len(wd)] == '/' {
		path = path[len(wd) + 1:]
	}
	if ng.swap_key != "" {
		sg_swap_user_node(ng, path)
	} else {
		sg_create_user_node(ng, kind, path)
	}
}

// Re-points the user node pending swap (swap_key) at a new file: the
// node keeps its canvas position (the key changes, so the imnodes id
// does too; imnodes re-seats it at the grid origin, the position reload
// from graph.json restores the spot after the save).
sg_swap_user_node :: proc(ng: ^NodeGraph, path: string) {
	if ng.swap_key == "" do return
	for i in 0 ..< len(ng.user_nodes) {
		if sg_user_node_key(&ng.user_nodes[i]) != ng.swap_key do continue
		delete(ng.user_nodes[i].path)
		ng.user_nodes[i].path = strings.clone(path)
		ng.user_nodes[i].source = .FILE
		break
	}
	delete(ng.swap_key)
	ng.swap_key = ""
	ng.sync_frame = 0 // the sweep + upsert rebuild the node's pins
	ng.save_pending = true
}

// Removes the user node pending deletion (delete_key), by key.
sg_delete_user_node :: proc(ng: ^NodeGraph) {
	if ng.delete_key == "" do return
	for i in 0 ..< len(ng.user_nodes) {
		if sg_user_node_key(&ng.user_nodes[i]) != ng.delete_key do continue
		delete(ng.user_nodes[i].path)
		delete(ng.user_nodes[i].title)
		ordered_remove(&ng.user_nodes, i)
		break
	}
	deleted := ng.delete_key
	delete(ng.delete_key)
	ng.delete_key = ""
	if ng.rename_key != "" && ng.rename_key == deleted {
		delete(ng.rename_key)
		ng.rename_key = ""
	}
	ng.sync_frame = 0 // the sweep drops the node
	ng.save_pending = true
}

sg_upsert_node :: proc(ng: ^NodeGraph, pass_desc: SgPassDesc) -> ^SgNode {
	for &node in ng.nodes {
		if node.key == pass_desc.key do return &node
	}
	position, has_layout := ng.layout[pass_desc.key]
	auto_pos := false
	if !has_layout {
		if ng.create_pos_set {
			// Right-click creation: spawn at the clicked grid point.
			position = [2]f32{ng.create_pos.x, ng.create_pos.y}
			ng.create_pos_set = false
		} else {
			// Cascade placeholder; sg_compute_layout replaces it with
			// the layered position before the node is first placed.
			column := ng.spawn_count % 3
			row := ng.spawn_count / 3
			position = {40 + f32(column) * 240, 40 + f32(row) * 220}
			ng.spawn_count += 1
			auto_pos = true
		}
	}
	append(
		&ng.nodes,
		SgNode {
			id    = sg_id(ng, fmt.tprintf("node:%s", pass_desc.key)),
			key   = strings.clone(pass_desc.key),
			title = strings.clone(pass_desc.title),
			kind  = pass_desc.kind,
			file  = strings.clone(pass_desc.file),
			pos   = position,
			cur   = position,
			auto_pos = auto_pos,
			// Only pass nodes get a preview (the pass loop assigns pi);
			// params/resource nodes keep the no-preview sentinel.
			pass_idx = -1,
		},
	)
	return &ng.nodes[len(ng.nodes) - 1]
}

// Rebuilds the architecture graph for the current scene unit: one params
// node plus one node per render pass (graphics = vertex/fragment entries,
// compute = compute entry) found in the scene's files, linked params ->
// pass inputs and pass output -> next pass's first texture input. Runs on
// the first frame of a scene and then every 120 frames; node ids are
// stable across passes so imnodes keeps the user's layout.
sg_sync :: proc(ng: ^NodeGraph, ed: ^ImGuiEditor) {
	ng.sync_frame += 1
	if ng.sync_frame > 1 && ng.sync_frame % 120 != 1 do return

	entry := fmt.tprintf("%s%s", ied_unit_prefix(ng.scene), ng.scene)
	// The architecture is the scene unit's own files: the entry first,
	// then scene-owned modules sorted by name (pass_1 < pass_2 < ...) so
	// the chain order matches creation order.
	files := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&files, entry)
	prefix := ied_unit_prefix(ng.scene)
	for file_name in ed.files {
		if file_name == entry do continue
		if strings.has_prefix(file_name, prefix) do append(&files, file_name)
	}
	slice.sort(files[1:])

	// Parse every file in the closure once.
	infos: map[string]SgFileInfo
	defer {
		for _, &info in infos do sg_free_info(&info)
		delete(infos)
	}
	for file_name in files {
		path := ied_file_path_for_rel(file_name)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil do continue
		infos[file_name] = sg_parse_file(string(data))
	}

	// Collect the passes in declaration order (closure order, then entry
	// line inside each file).
	passes := make([dynamic]SgPassDesc, 0, 8, context.temp_allocator)
	for file_name, file_idx in files {
		info, ok := infos[file_name]
		if !ok do continue
		base := file_name
		if slash := strings.last_index(base, "/"); slash >= 0 {
			base = base[slash + 1:]
		}
		gfx_line := -1
		compute_entries := 0
		for entry_desc in info.entries {
			if entry_desc.kind == .COMPUTE do compute_entries += 1
		}
		pass_count := 0
		for entry_desc in info.entries {
			if entry_desc.kind == .COMPUTE {
				title := base
				if compute_entries > 1 do title = entry_desc.name
				append(
					&passes,
					SgPassDesc {
						key   = fmt.tprintf("comp:%s:%s", file_name, entry_desc.name),
						title = title,
						file  = file_name,
						kind  = .COMPUTE,
						order = file_idx * 10000 + entry_desc.line,
					},
				)
				pass_count += 1
			} else if gfx_line < 0 {
				gfx_line = entry_desc.line
			}
		}
		if gfx_line >= 0 {
			kind := SgPassKind.GRAPHICS
			title := base
			if info.combine_op != "" {
				kind = .COMBINE
				title = info.combine_op
			}
			append(
				&passes,
				SgPassDesc {
					key   = fmt.tprintf("gfx:%s", file_name),
					title = title,
					file  = file_name,
					kind  = kind,
					order = file_idx * 10000 + gfx_line,
				},
			)
		}
		// Passes inside one file keep declaration order.
		// (closure order is already the outer loop's)
		for i := len(passes) - pass_count; i < len(passes); i += 1 {
			for j := i + 1; j < len(passes); j += 1 {
				if passes[j].order < passes[i].order {
					passes[i], passes[j] = passes[j], passes[i]
				}
			}
		}
	}

	// When the saved graph is authoritative (graph.json version 1), the
	// links are the source of truth: nothing is derived. Legacy/new
	// documents (no version) keep the declaration-order chain below.
	has_saved_pipeline := ng.graph_authoritative

	// User-authored resource nodes (created via right-click, persisted in
	// graph.json): rebuilt like the structural nodes so their pins exist
	// for linking. Target-mode image nodes add a `write` input so a pass
	// can feed them (ping-pong feedback).
	for i in 0 ..< len(ng.user_nodes) {
		user_node := &ng.user_nodes[i]
		key := sg_user_node_key(user_node)
		title := sg_base_title(user_node.path)
		if user_node.source == .TARGET {
			title = fmt.tprintf("target %dx%d", user_node.width, user_node.height)
		}
		if user_node.title != "" {
			title = user_node.title
		}
		node := sg_upsert_node(ng, SgPassDesc{key = key, title = title, kind = user_node.kind})
		for &pin in node.pins { delete(pin.name); delete(pin.label) }
		clear(&node.pins)
		#partial switch user_node.kind {
		case .IMAGE:
			// Output pins: the texture and the node's sampler. Target
			// mode also takes a pass output on `write` (feedback edge).
			sg_add_pin(ng, node, "texture", .TEXTURE, false)
			sg_add_pin(ng, node, "sampler", .SAMPLER, false)
			if user_node.source == .TARGET {
				sg_add_pin(ng, node, "write", .TEXTURE, true)
			}
		case .OBJECT3D:
			sg_add_pin(ng, node, "ModelVertex", .BUFFER, false)
		}
	}
	for i in 0 ..< len(ng.user_nodes) {
		user_node := &ng.user_nodes[i]
		sg_user_samplers[sg_user_node_key(user_node)] = [2]int{int(user_node.filter), int(user_node.address)}
	}
	sg_user_alive :: proc(ng: ^NodeGraph, key: string) -> bool {
		for i in 0 ..< len(ng.user_nodes) {
			if sg_user_node_key(&ng.user_nodes[i]) == key do return true
		}
		return false
	}

	// Which resource nodes this scene needs: the 3d object node when any
	// pass draws the model, the image node when any pass samples an
	// app-fed texture or sampler.
	need_object3d := false
	need_image := false
	for pass_desc in passes {
		info := infos[pass_desc.file]
		if info.uses_model do need_object3d = true
		for binding in info.bind_in {
			if binding.kind == .TEXTURE || binding.kind == .SAMPLER do need_image = true
		}
	}

	// Drop nodes for passes that vanished (file edited, import removed),
	// and resource nodes the scene no longer needs. Params and the show
	// node are structural: they outlive pass edits.
	for i := len(ng.nodes) - 1; i >= 0; i -= 1 {
		node := &ng.nodes[i]
		alive := false
		switch node.kind {
		case .PARAMS, .SHOW:
			alive = true
		case .OBJECT3D:
			alive = strings.has_prefix(node.key, "uobj:") ? sg_user_alive(ng, node.key) : need_object3d
		case .IMAGE:
			alive = strings.has_prefix(node.key, "uimg:") ? sg_user_alive(ng, node.key) : need_image
		case .GRAPHICS, .COMPUTE:
			for pass in passes {
				if pass.key == node.key {
					alive = true
					break
				}
			}
		case .COMBINE:
			for pass in passes {
				if pass.key == node.key && pass.kind == .COMBINE {
					alive = true
					break
				}
			}
		case .WIDGET:
			// A widget node lives while the shader declares the
			// [NodeUICheck]/[NodeUISlider] attribute (key "ui:<field>").
			for &widget in sg_node_widgets {
				if fmt.tprintf("ui:%s", widget.label) == node.key {
					alive = true
					break
				}
			}
		}
		if !alive {
			for &pin in node.pins { delete(pin.name); delete(pin.label) }
			delete(node.pins)
			delete(node.key)
			delete(node.title)
			delete(node.file)
			ordered_remove(&ng.nodes, i)
		}
	}
	clear(&ng.links)

	// Uniforms node: SceneUniforms ("Uniforms") plus one output per
	// uniform block the passes consume from the app, labeled with the
	// block's struct type ("Uniforms (SceneUniforms)"). SceneUniforms is
	// app-injected into every pass: it carries the injected mark (and no
	// link) on both ends.
	params := sg_upsert_node(ng, SgPassDesc{key = "params", title = "Uniforms", kind = .PARAMS})
	for &p in params.pins { delete(p.name); delete(p.label) }
	clear(&params.pins)
	seen := make(map[string]bool, 16, context.temp_allocator)
	for pass_desc in passes {
		info := infos[pass_desc.file]
		for binding in info.bind_in {
			if binding.kind != .CBUFFER do continue
			if seen[binding.name] do continue
			seen[binding.name] = true
			sg_add_pin(ng, params, binding.name, binding.kind, false)
			if binding.type_name != "" {
				pin := &params.pins[len(params.pins) - 1]
				pin.label = strings.clone(fmt.tprintf("%s (%s)", binding.name, binding.type_name))
			}
		}
	}

	// Resource nodes: the selected model's geometry and the app's
	// textures/samplers. Pins are fixed; links fan out by kind below.
	object3d: ^SgNode
	if need_object3d {
		object3d = sg_upsert_node(ng, SgPassDesc{key = "object3d", title = "3d object", kind = .OBJECT3D})
		for &pin in object3d.pins do delete(pin.name)
		clear(&object3d.pins)
		// The mesh leaves as the vertex stream the pass's stage_in
		// parameter consumes (ModelVertex).
		sg_add_pin(ng, object3d, "ModelVertex", .BUFFER, false)
	}
	image: ^SgNode
	if need_image {
		image = sg_upsert_node(ng, SgPassDesc{key = "image", title = "image", kind = .IMAGE})
		for &pin in image.pins { delete(pin.name); delete(pin.label) }
		clear(&image.pins)
		// Texture output only; samplers are implicit (resources.sampler).
		sg_add_pin(ng, image, "texture", .TEXTURE, false)
	}


	// NodeUI widget nodes: one per [NodeUICheck]/[NodeUISlider] attribute
	// declared in any pass. No pins; the control lives in the node body.
	for &widget in sg_node_widgets {
		key := fmt.tprintf("ui:%s", widget.label)
		node := sg_upsert_node(ng, SgPassDesc{key = key, title = widget.label, kind = .WIDGET})
		for &pin in node.pins { delete(pin.name); delete(pin.label) }
		clear(&node.pins)
	}

	// Pass nodes: inputs are their bindings (plus vertex/index buffer for
	// model passes), output is the frame they produce (graphics) or their
	// RWTexture(s) (compute).
	for pass_desc, pass_i in passes {
		node := sg_upsert_node(ng, pass_desc)
		node.pass_idx = pass_i
		for &pin in node.pins { delete(pin.name); delete(pin.label) }
		clear(&node.pins)
		info := infos[pass_desc.file]
		for binding in info.bind_in do sg_add_pin(ng, node, binding.name, binding.kind, true)
		if info.uses_model {
			// The mesh input is not a vk::binding: it enters the vertex
			// entry through the stage_in ModelVertex parameter, so it is
			// a pin of the node like the bindings are.
			sg_add_pin(ng, node, "ModelVertex", .BUFFER, true)
		}
		switch pass_desc.kind {
		case .GRAPHICS, .COMBINE:
			sg_add_pin(ng, node, "frame", .TEXTURE, false)
		case .COMPUTE:
			for out_binding in info.bind_out do sg_add_pin(ng, node, out_binding.name, out_binding.kind, false)
		case .PARAMS, .SHOW, .OBJECT3D, .IMAGE, .WIDGET:
			// Pins are assigned outside this loop (widget nodes: none).
		}
		// Legacy/new graphs only: resource nodes -> pass, textures/
		// samplers from image, geometry from 3d object. When the saved
		// graph is authoritative, links come solely from graph.json.
		// Uniform cbuffer inputs are wireless in both cases.
		if ng.graph_authoritative do continue
		for &pin in node.pins {
			if !pin.input do continue
			// Uniforms are wireless (the params node broadcasts; see the
			// pin marks in ing_panel): every cbuffer input skips its link.
			// Samplers are implicit too (resources.sampler): the image node
			// has no sampler pin, and a link to a pin no node renders
			// creates an imnodes pool pin with type None — draw_link then
			// panics on the bezier. Skip them like the saved-link path does.
			if pin.kind == .CBUFFER || pin.kind == .SAMPLER do continue
			from := -1
			flavor := SgLinkFlavor.TEXTURE
			src_kind := SgPassKind.IMAGE
			#partial switch pin.kind {
			case .TEXTURE:
				from = sg_id(ng, "pin:image:texture")
			case .BUFFER:
				from = sg_id(ng, fmt.tprintf("pin:object3d:%s", pin.name))
				flavor = .MESH
				src_kind = .OBJECT3D
			case .RWTEXTURE:
			}
			if from < 0 do continue
			append(
				&ng.links,
				SgLink {
					id     = sg_id(ng, fmt.tprintf("link:%d:%d", from, pin.id)),
					from   = from,
					to     = pin.id,
					flavor = flavor,
					col    = SG_KIND_COLORS[src_kind],
				},
			)
		}
	}

	// The viewport is a real pipeline sink. Its incoming edge and all
	// pass-to-pass texture edges come from graph.json when present.
	show := sg_upsert_node(ng, SgPassDesc{key = "show2d", title = "show 2d", kind = .SHOW})
	show.pass_idx = len(passes) - 1
	for &pin in show.pins { delete(pin.name); delete(pin.label) }
	clear(&show.pins)
	sg_add_pin(ng, show, "frame", .TEXTURE, true)

	if has_saved_pipeline {
		// Authoritative graph.json: the saved links are the entire
		// topology. Every endpoint kind participates (resource -> pass,
		// pass -> pass, pass -> viewport, image sampler -> pass sampler);
		// only the LEGACY fixed image node's sampler endpoints are
		// skipped (samplers were implicit there). Rejected links record
		// their first message and drop.
		for saved in ng.saved_links {
			if saved.from == "image:sampler" || saved.to == "image:sampler" {
				continue
			}
			from := sg_resolve_endpoint(ng, saved.from)
			to := sg_resolve_endpoint(ng, saved.to)
			if from < 0 || to < 0 do continue
			normalized_from, normalized_to, error_message, ok := sg_validate_connection(ng, from, to)
			if !ok {
				if ng.pipeline_error == "" {
					ng.pipeline_error = strings.clone(error_message)
				}
				continue
			}
			sg_append_pipeline_link(ng, normalized_from, normalized_to)
			if target_node, _, target_ok := sg_node_pin(ng, normalized_to); target_ok && target_node.kind == .SHOW {
				if source_node, _, source_ok := sg_node_pin(ng, normalized_from); source_ok {
					show.pass_idx = source_node.pass_idx
				}
			}
		}
	} else if !ng.graph_authoritative {
		// Migration/default: the previous declaration-order chain.
		for i := 1; i < len(passes); i += 1 {
			previous := sg_upsert_node(ng, passes[i - 1])
			current := sg_upsert_node(ng, passes[i])
			previous_output := -1
			for pin in previous.pins do if !pin.input { previous_output = pin.id; break }
			current_input := -1
			for pin in current.pins {
				if pin.input && pin.kind == .TEXTURE { current_input = pin.id; break }
			}
			if previous_output >= 0 && current_input >= 0 do sg_append_pipeline_link(ng, previous_output, current_input)
		}
		if len(passes) > 0 {
			last := sg_upsert_node(ng, passes[len(passes) - 1])
			for pin in last.pins {
				if !pin.input { sg_append_pipeline_link(ng, pin.id, show.pins[0].id); break }
			}
		}
		ng.save_pending = true
	}

	sg_compute_layout(ng)

	if ng.sync_frame == 1 {
		log.infof("[node-graph] %s: %d nodes, %d links", ng.scene, len(ng.nodes), len(ng.links))
		for &node in ng.nodes {
			log.infof("[node-graph]   %s (%s): %d pins", node.title, SG_KIND_TAGS[node.kind], len(node.pins))
		}
	}
}

// --- Layered layout --------------------------------------------------------
// Nodes hold a preferred position: sources on the left, every node to the
// right of the nodes linking into it (topological depth), and within a
// depth layer ordered top-to-bottom by the barycenter of its inputs.
// There is NO simulation: pref only seeds the initial placement of nodes
// that have no user-chosen position; after that imnodes owns positions
// and sg_save persists them.

SG_LAYOUT_X0    :: 40.0
SG_LAYOUT_Y0    :: 40.0
SG_LAYOUT_X_GAP :: 300.0
SG_LAYOUT_Y_GAP :: 260.0 // fits nodes with previews (~220px tall)

// Rebuilds link endpoint pairs and the preferred positions from the
// current graph. Runs at the end of every sync. Positions are owned by
// the user: pref only seeds nodes that have no saved/right-click
// position yet (auto_pos) and have never been placed.
sg_compute_layout :: proc(ng: ^NodeGraph) {
	// Refresh the cached positions of placed nodes so the barycenter
	// ordering below sees where the user actually left things. Outside
	// the editor scope imnodes' pool may not hold the node (scene
	// switch): keep the cached value instead of querying.
	for &node in ng.nodes {
		if node.placed && ine_scope_active() {
			grid_pos := ine_get_node_grid_pos(node.id)
			node.cur = [2]f32{grid_pos.x, grid_pos.y}
		}
	}

	clear(&ng.link_pairs)
	for link in ng.links {
		source_idx, target_idx := -1, -1
		for &node, node_i in ng.nodes {
			for &pin in node.pins {
				if pin.id == link.from do source_idx = node_i
				if pin.id == link.to do target_idx = node_i
			}
		}
		if source_idx >= 0 && target_idx >= 0 do append(&ng.link_pairs, [2]int{source_idx, target_idx})
	}

	// Depth: 0 for sources, 1 + max(source depths) otherwise. The links
	// form a DAG, so relaxation converges.
	for &node in ng.nodes do node.layer = 0
	for _ in 0 ..< len(ng.nodes) {
		changed := false
		for pair in ng.link_pairs {
			target := &ng.nodes[pair[1]]
			if target.layer < ng.nodes[pair[0]].layer + 1 {
				target.layer = ng.nodes[pair[0]].layer + 1
				changed = true
			}
		}
		if !changed do break
	}

	// Within each layer: order by the barycenter of the inputs' current
	// y (fewer crossings), then slot top-to-bottom.
	max_layer := 0
	for &node in ng.nodes do max_layer = max(max_layer, node.layer)
	for layer in 0 ..= max_layer {
		Entry :: struct {
			i: int,
			b: f32,
		}
		entries := make([dynamic]Entry, 0, 8, context.temp_allocator)
		for &node, node_i in ng.nodes {
			if node.layer != layer do continue
			sum := 0.0
			cnt := 0
			for pair in ng.link_pairs {
				if pair[1] != node_i do continue
				sum += f64(ng.nodes[pair[0]].cur.y)
				cnt += 1
			}
			append(&entries, Entry{i = node_i, b = cnt > 0 ? f32(sum / f64(cnt)) : 0})
		}
		slice.sort_by(entries[:], proc(a, b: Entry) -> bool { return a.b < b.b })
		for entry, slot in entries {
			ng.nodes[entry.i].pref = {
				SG_LAYOUT_X0 + f32(layer) * SG_LAYOUT_X_GAP,
				SG_LAYOUT_Y0 + f32(slot) * SG_LAYOUT_Y_GAP,
			}
		}
	}

	// Nodes without a user-chosen position adopt the layered layout:
	// once, before their first placement. After that the position belongs
	// to the user (imnodes owns it; sg_save persists it).
	for &node in ng.nodes {
		if node.auto_pos && !node.placed {
			node.pos = node.pref
			node.cur = node.pref
		}
	}
}

// Self-test knob (--graph-test): creates one compute and one graphics pass
// on the starting scene at startup; the panel then shows a 5-node chain.
ing_selftest: bool

// Click-test harness (--graph-click-test): drives the right-click →
// "image" → "assets/parchment.jpg" flow with synthetic mouse events,
// reproducing the user's broken create-node path end to end.
ing_click_test: bool
ing_click_test_frame: int
// Set when the user image node actually appears (verified each frame).
ing_click_test_ok := false
ing_click_test_logged := false

// Node previews: one stable texture per reflected pass plus the selected
// viewport output. Set from main before the graph panel renders.
ing_pass_tex:   []^sdl.GPUTexture
ing_scene_tex:  ^sdl.GPUTexture
ing_output_pass: int
ing_n_passes:   int
ing_provenance_valid: [DEBUG_WATCH_MAX_PASSES]bool
ing_provenance_path: [DEBUG_WATCH_MAX_PASSES]bool
ing_provenance_rgba: [DEBUG_WATCH_MAX_PASSES][4]f32

// Sampler settings per user node key ("uimg:<path>", "uobj:<path>",
// "uimg:target:<id>"), rebuilt by sg_sync each rescan. scene_runtime's
// frame submit consults it to bind the image node's sampler on texture
// routes instead of the app default. Values are ints: 0/1 filter,
// 0/1/2 address.
sg_user_samplers: map[string][2]int

// Snapshot of the active scene's node-widgets ([NodeUICheck]/
// [NodeUISlider]) refreshed by sg_sync from the scene manager global;
// .WIDGET node liveness keys off "ui:<field>".
sg_node_widgets: [dynamic]UiWidget

// Replaces the widget snapshot (called by ui_build before ing_panel):
// labels are copied; the caller keeps ownership of its slice.
sg_set_node_widgets :: proc(widgets: []UiWidget) {
	clear(&sg_node_widgets)
	for &widget in widgets {
		if widget.node {
			append(&sg_node_widgets, widget)
		}
	}
}

// Finds the node-widget snapshot entry for a field label; nil when the
// shader no longer declares it.
sg_widget_by_label :: proc(label: string) -> ^UiWidget {
	for &widget in sg_node_widgets {
		if widget.label == label do return &widget
	}
	return nil
}

sg_preview_tex :: proc(i: int) -> ^sdl.GPUTexture {
	if i < 0 || ing_scene_tex == nil do return nil
	if i == ing_output_pass do return ing_scene_tex
	if i < len(ing_pass_tex) do return ing_pass_tex[i]
	return nil
}

ing_runtime_pipeline_error: string

ing_init :: proc() -> ^NodeGraph {
	graph := new(NodeGraph)
	graph.handle = ine_create()
	graph.next_id = 1
	graph.show_previews = true
	return graph
}

// Panel content; renders into the caller's window (the sidebar's GRAPH
// mode panel). The graph follows the active scene unit: switching scenes
// saves the outgoing graph.json and loads the incoming one. `maximized`
ing_panel :: proc(graph: ^NodeGraph, editor: ^ImGuiEditor, scene_title: string, maximized: ^bool) {
	if scene_title != graph.scene {
		sg_save(graph)
		sg_clear_graph(graph)
		graph.scene = strings.clone(scene_title)
		sg_load_layout(graph, scene_title)
		// Force a full resync on the next frame: sg_sync's modulo gate
		// would otherwise leave the panel node-less for up to 119 frames
		// while saves/layout queries hit imnodes' emptied node pool.
		graph.sync_frame = 0
	} else {
		sg_reload_if_changed(graph)
	}
	sg_sync(graph, editor)
	if graph.sync_frame > 0 && graph.sync_frame % 600 == 2 do sg_save(graph)
	if graph.save_pending {
		sg_save(graph)
		graph.save_pending = false
	}
	// Zoom: scroll on the canvas zooms around the cursor; clicking the
	// label resets to 100%.
	imgui_io := im.GetIO()
	im.Checkbox(trc("previews"), &graph.show_previews)
	im.SameLine()
	zoom := ine_get_zoom()
	zoom_label := fmt.tprintf("zoom: %.0f%%", zoom * 100)
	if im.SmallButton(strings_to_c(zoom_label)) {
		ine_set_zoom(1.0)
	}
	if graph.pipeline_error != "" || ing_runtime_pipeline_error != "" {
		message := graph.pipeline_error if graph.pipeline_error != "" else ing_runtime_pipeline_error
		im.TextColored(ERROR_RED, "pipeline: %s", strings_to_c(message))
		im.TextDisabled(trc("last valid pipeline remains active"))
	}
	ine_editor_begin()
	// Marks drawn after ine_editor_end, collected while rendering the
	// nodes: imnodes paints pin shapes at EndNodeEditor, so anything that
	// must sit over a socket (inject bolts, the wireless broadcast ball)
	// queues its screen position here.
	inject_marks := make([dynamic][2]f32, 0, 16, context.temp_allocator)
	broadcast_marks := make([dynamic][2]f32, 0, 8, context.temp_allocator)
	receive_marks := make([dynamic][2]f32, 0, 16, context.temp_allocator)
	// Pin id -> screen-space socket center for wire decorations.
	pin_pos := make(map[int][2]f32, 64, context.temp_allocator)
	for &node in graph.nodes {
		if !node.placed {
			ine_set_node_grid_pos(node.id, im.Vec2{node.pos.x, node.pos.y})
			node.placed = true
		}
		title_color := SG_KIND_COLORS[node.kind]
		ine_push_color_style(INE_COL_TITLE_BAR, title_color)
		ine_push_color_style(INE_COL_TITLE_BAR_HOVERED, title_color)
		ine_push_color_style(INE_COL_TITLE_BAR_SELECTED, title_color)
		// Body tinted with the kind's color at low alpha; the output node
		// also gets the bright safelight outline so it reads as the sink.
		ine_push_color_style(INE_COL_NODE_BG, sg_kind_body(node.kind, 0.30))
		ine_push_color_style(INE_COL_NODE_BG_HOVER, sg_kind_body(node.kind, 0.40))
		ine_push_color_style(INE_COL_NODE_BG_SELECT, sg_kind_body(node.kind, 0.50))
		if node.kind == .SHOW {
			ine_push_color_style(INE_COL_NODE_OUTLINE, title_color)
		}
		ine_begin_node(node.id)
		ine_title_bar_begin()
		icon_col := im.GetColorU32Vec4({0, 0, 0, 0.55})
		icon_pos := im.GetCursorScreenPos()
		node_zoom := ine_get_zoom()
		sg_draw_kind_icon(im.GetWindowDrawList(), node.kind, icon_pos, icon_col, node_zoom)
		im.SetCursorScreenPos({icon_pos.x + 20 * node_zoom, icon_pos.y})
		// tr() falls back to the key, so user-file titles pass through
		// unchanged; only the fixed node names translate. The raw tag
		// (untranslated) is what graph.json persists.
		title := fmt.ctprintf("%s · %s", tr(node.title), tr(SG_KIND_TAGS[node.kind]))
		im.TextUnformatted(title)
		ine_title_bar_end()
		// The title bar takes the node's width (not vice versa), so long
		// titles clip: reserve the widest text in the node body: title
		// (plus its icon) OR longest pin name, since pins longer than the
		// title clip too (inputs on the right edge, outputs on the left).
		node_width := im.CalcTextSize(title).x + 20 * node_zoom
		for &pin in node.pins {
			text := pin.label if pin.label != "" else pin.name
			pin_width := im.CalcTextSize(strings_to_c(text)).x
			if pin_width > node_width do node_width = pin_width
		}
		im.Dummy({node_width, 1})
		// imnodes paints pin sockets at the NODE body's left/right edges
		// (helpers.get_screen_space_pin_coordinates: x = node.rect.min/max
		// + pin_offset, y = attribute rect center), so capture the body
		// rect here instead of deriving positions from the pin text.
		body_min := im.GetItemRectMin()
		body_max := im.GetItemRectMax()
		// User-authored resource nodes show the asset they feed (file
		// mode) or their fixed size (target mode).
		if user_source := sg_user_source_for_node(graph, &node); user_source != nil {
			if user_source.source == .TARGET {
				im.TextDisabled(strings_to_c(fmt.tprintf("render target %dx%d · RGBA8", user_source.width, user_source.height)))
			} else {
				im.TextDisabled(strings_to_c(sg_file_name(user_source.path)))
			}
		}
		// Sampler controls on image nodes (file or target): filter and
		// address mode, bound to the user node record (persisted). Static
		// attribute so dragging the widgets never drags the node.
		if user_source := sg_user_source_for_node(graph, &node); user_source != nil && user_source.kind == .IMAGE {
			ine_static_attr_begin(sg_id(graph, fmt.tprintf("pin:%s:sampler", node.key)))
			im.SetNextItemWidth(-1)
			filter_names := [2]cstring{"point", "linear"}
			filter_idx := i32(user_source.filter)
			if im.ComboChar("filter", &filter_idx, raw_data(&filter_names), i32(len(filter_names))) {
				user_source.filter = SgSamplerFilter(filter_idx)
				graph.save_pending = true
			}
			im.SetNextItemWidth(-1)
			address_names := [3]cstring{"clamp", "repeat", "mirror"}
			address_idx := i32(user_source.address)
			if im.ComboChar("address", &address_idx, raw_data(&address_names), i32(len(address_names))) {
				user_source.address = SgSamplerAddress(address_idx)
				graph.save_pending = true
			}
			ine_static_attr_end()
		}
		// NodeUI widget controls ([NodeUICheck]/[NodeUISlider]): the node
		// IS the control. Writes go straight into the widget snapshot,
		// which scene_write_uniforms pokes into the pass cbuffer.
		if node.kind == .WIDGET {
			field := node.key[len("ui:"):]
			if widget := sg_widget_by_label(field); widget != nil {
				ine_static_attr_begin(sg_id(graph, fmt.tprintf("pin:%s:control", node.key)))
				widget_id := strings_to_c(field)
				switch widget.kind {
				case .TOGGLE:
					if im.Checkbox(widget_id, &widget.on) {
						graph.save_pending = true
					}
				case .SLIDER:
					im.SetNextItemWidth(-1)
					if im.SliderFloat(widget_id, &widget.value[0], widget.min, widget.max, "%.2f") {
						graph.save_pending = true
					}
				case .COLOR:
					// NodeUICheck/NodeUISlider never produce .COLOR; kept
					// for exhaustiveness.
					im.TextDisabled("(color widgets stay in settings)")
				}
				ine_static_attr_end()
			}
		}
		shape := SG_KIND_PIN_SHAPES[node.kind]
		// Inputs first, then outputs: links flow left to right.
		for want_input in ([?]bool{true, false}) {
			for &pin in node.pins {
				if pin.input != want_input do continue
				pin_color: u32 = pin.input ? SG_PIN_IN_COLOR : SG_PIN_OUT_COLOR
				// Wireless-uniform pins carry the wireless accent instead of
				// the default in/out color so the ball/ring marks (drawn
				// after EndNodeEditor over the socket) sit on a matching
				// base instead of green/white remnants.
				broadcast := node.kind == .PARAMS && !pin.input && pin.kind == .CBUFFER
				receive := pin.input && pin.kind == .CBUFFER
				if broadcast || receive do pin_color = SG_WIRELESS_COLOR
				ine_push_color_style(INE_COL_PIN, pin_color)
				ine_push_color_style(INE_COL_PIN_HOVERED, pin_color)
				injected := pin.kind == .CBUFFER && pin.name == "Uniforms"
				// Wireless uniforms: the params node's cbuffer outputs
				// broadcast (ball + rings), every cbuffer input receives
				// (converging rings). Both draw after EndNodeEditor so
				// they sit over the imnodes pin sockets.
				text := pin.label if pin.label != "" else pin.name
				if pin.input {
					ine_input_attr_begin(pin.id, shape)
					ine_push_attribute_flag({.EnableLinkDetachWithDragClick})
					im.TextUnformatted(strings_to_c(text))
					ine_pop_attribute_flag()
					ine_input_attr_end()
					rect_min := im.GetItemRectMin()
					rect_max := im.GetItemRectMax()
					pin_pos[pin.id] = {body_min.x - 8 * node_zoom, (rect_min.y + rect_max.y) / 2}
					if injected do append(&inject_marks, pin_pos[pin.id])
					if receive do append(&receive_marks, pin_pos[pin.id])
				} else {
					ine_output_attr_begin(pin.id, shape)
					im.TextUnformatted(strings_to_c(text))
					ine_output_attr_end()
					rect_min := im.GetItemRectMin()
					rect_max := im.GetItemRectMax()
					pin_pos[pin.id] = {body_max.x + 8 * node_zoom, (rect_min.y + rect_max.y) / 2}
					if broadcast do append(&broadcast_marks, pin_pos[pin.id])
				}
				ine_pop_color_style()
				ine_pop_color_style()
			}
		}
		// Pass preview: the frame this pass produced (previous frame's
		// content: the graph renders before this frame's submit). The
		// source is a 128px square preview target (a low-res copy the
		// submit blits every frame) holding the window-aspect image
		// squeezed anisotropically; displaying at window aspect applies
		// the inverse vertical factor and restores the geometry.
		if graph.show_previews && node.pass_idx >= 0 {
			if tex := sg_preview_tex(node.pass_idx); tex != nil {
				ine_static_attr_begin(sg_id(graph, fmt.tprintf("pin:%s:prev", node.key)))
				preview_w := f32(128) * ine_get_zoom()
				preview_h := preview_w * imgui_io.DisplaySize.y / imgui_io.DisplaySize.x
				im.Image(im.TextureRef{_TexID = u64(uintptr(tex))}, {preview_w, preview_h})
				ine_static_attr_end()
			}
		}
		if node.pass_idx >= 0 && node.pass_idx < DEBUG_WATCH_MAX_PASSES &&
		   ing_provenance_valid[node.pass_idx] && ing_provenance_path[node.pass_idx] {
			ine_static_attr_begin(sg_id(graph, fmt.tprintf("pin:%s:provenance", node.key)))
			value := ing_provenance_rgba[node.pass_idx]
			im.TextColored(
				{value[0], value[1], value[2], 1},
				"pixel  %.3f  %.3f  %.3f  %.3f",
				value[0], value[1], value[2], value[3],
			)
			ine_static_attr_end()
		}
		// "+" appends a pass to the chain (the popup below asks the kind).
		ine_static_attr_begin(sg_id(graph, fmt.tprintf("pin:%s:+", node.key)))
		if im.SmallButton("+") {
			graph.create_open = true
		}
		ine_static_attr_end()
		ine_end_node()
		// Pop title trio + body trio (+ the SHOW outline when pushed).
		for _ in 0 ..< (node.kind == .SHOW ? 7 : 6) {
			ine_pop_color_style()
		}
	}

	// Every link takes the source node's kind color, tinted: ~45% alpha
	// base, brighter on hover/select, so links are distinguishable from
	// each other (image teal, mesh green, pass/combinator own hue).
	// UNIFORM keeps the reserved transparent base (uniforms are wireless).
	for link in graph.links {
		if link.flavor == .UNIFORM {
			ine_push_color_style(INE_COL_LINK, 0x00)
			ine_push_color_style(INE_COL_LINK_HOVER, 0x00)
			ine_push_color_style(INE_COL_LINK_SELECT, 0x00)
		} else {
			rgb := link.col & 0x00FFFFFF
			ine_push_color_style(INE_COL_LINK, 0x73 << 24 | rgb)
			ine_push_color_style(INE_COL_LINK_HOVER, 0xC0 << 24 | rgb)
			ine_push_color_style(INE_COL_LINK_SELECT, 0xE0 << 24 | rgb)
		}
		ine_link(link.id, link.from, link.to)
		ine_pop_color_style()
		ine_pop_color_style()
		ine_pop_color_style()
	}
	// Refresh cached positions every frame while the imnodes pool holds
	// the nodes (inside the editor scope). sg_save always runs outside
	// the scope and falls back to node.cur; without this the last ~2s
	// of drags are lost to the 120-frame sg_compute_layout refresh.
	for &node in graph.nodes {
		if node.placed {
			grid_pos := ine_get_node_grid_pos(node.id)
			node.cur = [2]f32{grid_pos.x, grid_pos.y}
		}
	}

	ine_editor_end()

	// Post-editor marks over the pin sockets imnodes painted at
	// EndNodeEditor: inject bolts, plus the animated wireless marks.
	// Only plain links remain between nodes: a link is exactly "this
	// output becomes that input", with no decoration on top of it.
	{
		mark_dl := im.GetWindowDrawList()
		now := im.GetTime()
		for mark in inject_marks {
			sg_draw_injected(mark_dl, mark.x, mark.y)
		}
		for mark in broadcast_marks {
			sg_draw_broadcast_mark(mark_dl, mark.x, mark.y, ine_get_zoom(), now)
		}
		for mark in receive_marks {
			sg_draw_receive_mark(mark_dl, mark.x, mark.y, ine_get_zoom(), now)
		}
	}

	// Link gestures are staged. The JSON changes only after confirmation.
	created_a, created_b: int
	if ine_is_link_created(&created_a, &created_b) {
		from, to, error_message, ok := sg_validate_connection(graph, created_a, created_b)
		if ok {
			graph.pending_action = .CONNECT
			graph.pending_from, graph.pending_to = from, to
			graph.pending_link_id = -1
		} else {
			delete(graph.pipeline_error)
			graph.pipeline_error = strings.clone(error_message)
			notify(.ERROR, "pipeline: %s", error_message)
		}
	}
	destroyed_id: int
	if graph.pending_action == .NONE && ine_is_link_destroyed(&destroyed_id) {
		for link in graph.links {
			if link.id != destroyed_id || !link.editable do continue
			graph.pending_action = .DISCONNECT
			graph.pending_from, graph.pending_to = link.from, link.to
			graph.pending_link_id = link.id
			break
		}
	}
	if graph.pending_action != .NONE do im.OpenPopup("##pipeline_change")
	if im.BeginPopup("##pipeline_change", {}) {
		action := tr("connect pipeline edge") if graph.pending_action == .CONNECT else tr("disconnect pipeline edge")
		im.TextUnformatted(strings_to_c(action))
		im.TextDisabled(strings_to_c(sg_pin_endpoint(graph, graph.pending_from)))
		im.TextUnformatted("→")
		im.TextDisabled(strings_to_c(sg_pin_endpoint(graph, graph.pending_to)))
		// CONNECT over an input that already has an editable producer:
		// the apply below replaces it (one producer per input).
		if graph.pending_action == .CONNECT {
			for link in graph.links {
				if link.editable && link.to == graph.pending_to && link.from != graph.pending_from {
					im.TextDisabled(fmt.ctprintf(tr("replaces %s"), sg_pin_endpoint(graph, link.from)))
					break
				}
			}
		}
		im.Spacing()
		im.TextDisabled(trc("invalid changes keep the last valid pipeline"))
		if im.Button(trc("apply")) {
			if graph.pending_action == .CONNECT {
				sg_connect(graph, graph.pending_from, graph.pending_to)
			} else {
				sg_remove_pipeline_link(graph, graph.pending_link_id)
			}
			delete(graph.pipeline_error)
			graph.pipeline_error = ""
			graph.save_pending = true
			sg_compute_layout(graph)
			graph.pending_action = .NONE
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button(trc("cancel")) {
			graph.pending_action = .NONE
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
	// Click on a node opens its file's tab in the code editor (params
	// jumps to the scene's entry shader; resource nodes have no file).
	// Gated on release-without-drag so moving a node doesn't switch tabs.
	if im.IsMouseReleased(.Left) && !im.IsMouseDragging(.Left) {
		if hovered, hovered_node_id := ine_is_node_hovered(); hovered {
			for &node in graph.nodes {
				if node.id != hovered_node_id do continue
				target := node.file
				if target == "" && node.kind == .PARAMS {
					target = fmt.tprintf("%s%s", ied_unit_prefix(graph.scene), graph.scene)
				}
				if target != "" {
					msg: OpenFile
					msg_set(&msg.rel, target)
					emit(msg)
				}
			}
		}
	}

	// Maximize toggle, top-right over the canvas. FlattenChildren (bit 11,
	// not in the binding's ButtonFlag enum) lets the button receive clicks
	// although the imnodes child covers the area.
	{
		window_pos := im.GetWindowPos()
		window_size := im.GetWindowSize()
		button_x := window_pos.x + window_size.x - 30
		button_y := window_pos.y + 8
		im.SetCursorScreenPos({button_x, button_y})
		flatten := transmute(im.ButtonFlags)(i32(1) << 11)
		if im.InvisibleButton("##graph_max", {22, 22}, flatten) {
			maximized^ = !maximized^
		}
		hovered := im.IsItemHovered()
		draw_list := im.GetWindowDrawList()
		glyph_color := im.GetColorU32Vec4(hovered ? ICON_HOVER : ICON_IDLE)
		if hovered {
			im.DrawList_AddRectFilled(draw_list, {button_x, button_y}, {button_x + 22, button_y + 22}, im.GetColorU32Vec4({1, 1, 1, 0.07}), 5)
		}
	}
	// Right-click on empty canvas: open the create popup and spawn the new
	// node at the clicked grid point (consumed by sg_upsert_node).
	if im.IsWindowHovered({.ChildWindows}) && im.IsMouseReleased(.Right) && !im.IsMouseDragging(.Right) {
		hovered, hovered_node_id := ine_is_node_hovered()
		log.infof("[graph-click] right-release: hovered=%v node=%d window_hovered=%v", hovered, hovered_node_id, im.IsWindowHovered({.ChildWindows}))
		if hovered {
			// Right-click on a node: context menu. User nodes offer
			// rename/swap/delete; combine nodes delete only (removes the
			// node's .slang file). Both actions key off the node.
			graph.menu_node_id = hovered_node_id
			for &node in graph.nodes {
				if node.id != hovered_node_id do continue
				if sg_user_source_for_node(graph, &node) != nil {
					if graph.delete_key != "" do delete(graph.delete_key)
					graph.delete_key = strings.clone(node.key)
					if graph.swap_key != "" do delete(graph.swap_key)
					graph.swap_key = strings.clone(node.key)
					im.OpenPopup("##node_user_menu")
				} else if node.kind == .COMBINE {
					im.OpenPopup("##node_user_menu")
				}
				break
			}
		} else {
			graph.create_pos = ine_screen_to_grid(imgui_io.MousePos)
			graph.create_pos_set = true
			graph.create_open = true
			log.infof("[graph-click] canvas hit: opening ##node_create at grid (%.0f, %.0f)", graph.create_pos.x, graph.create_pos.y)
		}
	}

	// Create-node popup (opened by a node's "+" or canvas right-click):
	// passes write a file into the scene's directory and append to the
	// chain on the next sync; image/3d object open the file picker.
	if graph.create_open {
		im.OpenPopup("##node_create")
		graph.create_open = false
	}
	if im.BeginPopup("##node_create") {
		pmin := im.GetWindowPos()
		psize := im.GetWindowSize()
		log.infof("[graph-click] node_create popup rect (%.0f, %.0f) size (%.0f, %.0f)", pmin.x, pmin.y, psize.x, psize.y)
		im.TextDisabled(trc("create pass"))
		if im.Selectable(trc("graphics pass"), false, {}) {
			sg_create_pass(graph, editor, .GRAPHICS)
		}
		if im.Selectable(trc("compute pass"), false, {}) {
			sg_create_pass(graph, editor, .COMPUTE)
		}
		im.TextDisabled(trc("create combine"))
		if im.Selectable(trc("ADD"), false, {}) {
			sg_create_combine(graph, editor, "ADD")
		}
		if im.Selectable(trc("MUL"), false, {}) {
			sg_create_combine(graph, editor, "MUL")
		}
		if im.Selectable(trc("AND"), false, {}) {
			sg_create_combine(graph, editor, "AND")
		}
		if im.Selectable(trc("OR"), false, {}) {
			sg_create_combine(graph, editor, "OR")
		}
		if im.Selectable(trc("NOT"), false, {}) {
			sg_create_combine(graph, editor, "NOT")
		}
		im.TextDisabled(trc("create resource"))
		if im.Selectable(trc("image"), false, {}) {
			graph.file_pick = .IMAGE
			graph.pick_open = true
		}
		if im.Selectable(trc("3d object"), false, {}) {
			graph.file_pick = .OBJECT3D
			graph.pick_open = true
		}
		if im.Selectable(trc("render target"), false, {}) {
			sg_create_target_node(graph, .IMAGE, SG_TARGET_DEFAULT_WIDTH, SG_TARGET_DEFAULT_HEIGHT)
		}
		im.EndPopup()
	} else {
		// Popup not shown this frame: a closed/cancelled create clears
		// the pending right-click spawn point.
		graph.create_pos_set = false
	}

	// User-node context menu: rename, swap the asset file (file mode), or
	// delete the node. Combine nodes get only delete (they own their
	// .slang file, removed by sg_delete_combine).
	if im.BeginPopup("##node_user_menu") {
		menu_node: ^SgNode
		for &node in graph.nodes {
			if node.id == graph.menu_node_id {
				menu_node = &node
				break
			}
		}
		if menu_node != nil && menu_node.kind == .COMBINE {
			if im.Selectable(trc("delete node"), false, {}) {
				sg_delete_combine(graph, editor, menu_node.key)
			}
		} else if menu_node != nil {
			if im.Selectable(trc("rename"), false, {}) {
				menu_user_source := sg_user_source_for_node(graph, menu_node)
				if menu_user_source != nil {
					delete(graph.rename_key)
					graph.rename_key = strings.clone(menu_node.key)
					for i in 0 ..< len(graph.rename_buf) do graph.rename_buf[i] = 0
					copy(graph.rename_buf[:], menu_node.title)
					im.OpenPopup("##node_rename")
				}
			}
			menu_user_source := sg_user_source_for_node(graph, menu_node)
			if menu_user_source != nil && menu_user_source.source == .FILE {
				if im.Selectable(trc("swap file"), false, {}) {
					// The swap target's kind drives the dialog filters.
					graph.file_pick = menu_node.kind
					graph.pick_open = true
				}
			}
			if im.Selectable(trc("delete node"), false, {}) {
				sg_delete_user_node(graph)
			}
		}
		im.EndPopup()
	}

	// Rename popup: InputText bound to a fixed buffer; Enter/apply writes
	// the title override to the user node (persisted as "title" in
	// graph.json).
	if im.BeginPopup("##node_rename") {
		im.TextDisabled(trc("node title"))
		im.SetNextItemWidth(-1)
		if im.InputText(
			"##rename_input",
			cstring(&graph.rename_buf[0]),
			len(graph.rename_buf),
			{.EnterReturnsTrue},
		) || im.Button(trc("apply")) {
			for i in 0 ..< len(graph.user_nodes) {
				if sg_user_node_key(&graph.user_nodes[i]) == graph.rename_key {
					delete(graph.user_nodes[i].title)
					graph.user_nodes[i].title = strings.clone(string(cstring(&graph.rename_buf[0])))
					break
				}
			}
			delete(graph.rename_key)
			graph.rename_key = ""
			graph.sync_frame = 0 // re-upsert applies the title override
			graph.save_pending = true
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button(trc("cancel")) {
			delete(graph.rename_key)
			graph.rename_key = ""
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// Native file dialog: opened at window level (outside every popup
	// scope — a modal launched inside BeginPopup/EndPopup is swallowed
	// by that scope's bounds), one-shot per pick_open flag.
	if graph.pick_open {
		graph.pick_open = false
		sg_pick_file(graph)
	}


	// SPACE-hold grab: the cursor reads as the grab hand for the whole
	// hold (set every frame: ImGui resets io.MouseCursor to Arrow on
	// NewFrame, so a branch-local set flickers between frames that pan
	// and frames that don't).
	if graph_grab_held do im.SetMouseCursor(.ResizeAll)
	// Scroll always zooms the node canvas around the cursor (was
	// two-finger pan with Ctrl+scroll zoom; pan now lives on the SPACE
	// grab). Ctrl state comes from ImGui's IO (kept in sync by the event
	// forwarder; the SDL mod state is glove-owned).
	if im.IsWindowHovered({.ChildWindows}) && imgui_io.MouseWheel != 0 {
		ZOOM_STEP :: 1.125
		current_zoom := ine_get_zoom()
		ine_set_zoom(
			current_zoom * math.pow(f32(ZOOM_STEP), imgui_io.MouseWheel),
			im.Vec2{imgui_io.MousePos.x, imgui_io.MousePos.y},
		)
	} else if im.IsWindowHovered({.ChildWindows}) && graph_grab_held &&
	          (imgui_io.MouseDelta.x != 0 || imgui_io.MouseDelta.y != 0) {
		// SPACE-hold grab: drag moves the panning 1:1 with the cursor
		// ("viewport moves with the mouse", same sign convention as the
		// old two-finger pan) and the velocity is sampled so release
		// glides on with the same exponential friction.
		im.SetMouseCursor(.ResizeAll)
		delta_time := max(imgui_io.DeltaTime, 1e-4)
		velocity := [2]f32{-imgui_io.MouseDelta.x / delta_time, -imgui_io.MouseDelta.y / delta_time}
		speed := math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
		if speed > sg_pan_max_speed {
			velocity *= sg_pan_max_speed / speed
		}
		graph.pan_vel = graph.pan_vel * 0.4 + velocity * 0.6
		panning := ine_get_panning()
		ine_reset_panning(im.Vec2{panning.x - imgui_io.MouseDelta.x, panning.y - imgui_io.MouseDelta.y})
		if pan_test_debug {
			log.infof(
				"[pan-debug] GRABBED by (%.0f, %.0f) vel (%.0f, %.0f)",
				-imgui_io.MouseDelta.x, -imgui_io.MouseDelta.y, graph.pan_vel.x, graph.pan_vel.y,
			)
		}
	} else if graph.pan_vel != {} {
		// Inertia: friction eases the velocity to zero.
		delta_time := imgui_io.DeltaTime
		panning := ine_get_panning()
		ine_reset_panning(im.Vec2{panning.x + graph.pan_vel.x * delta_time, panning.y + graph.pan_vel.y * delta_time})
		graph.pan_vel *= math.exp(-sg_pan_friction * delta_time)
		if abs(graph.pan_vel.x) < 1 && abs(graph.pan_vel.y) < 1 do graph.pan_vel = {}
	}
}

// Glide tuning, adjustable in the settings popup: the velocity decays
// exp(-sg_pan_friction * dt) after release (lower = icier, higher =
// tighter) and the momentum sample is capped at sg_pan_max_speed px/s.
sg_pan_friction:  f32 = 10
sg_pan_max_speed: f32 = 1000

// SPACE-hold grab on the node canvas (graph_grab action): while held,
// dragging moves the panning and the cursor reads as a grab hand.
// Set by input_bindings' handlers; read here.
graph_grab_held: bool


// Set by --pan-test (main.odin): logs the pan vector as wheel deltas move it.
pan_test_debug: bool
