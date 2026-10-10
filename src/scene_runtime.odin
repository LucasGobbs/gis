package main

import gfx "./gfx"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

// Compiler diagnostics for the editor: parsed from slangc stderr on scene
// build failure. The ImGui editor turns them into squiggles/markers;
// cleared on the next successful build. build_errors_version bumps on every
// change so UI layers can cache.
BuildError :: struct {
	file: string, // shader name relative to src/shaders, no extension ("scenes/apple")
	line: int,    // 1-based, as reported
	col:  int,    // 1-based, as reported
	msg:  string, // the "error[...]" line
}

build_errors: [dynamic]BuildError
build_errors_version: int
build_success_version: int

build_errors_clear :: proc() {
	for build_error in build_errors {
		delete(build_error.file)
		delete(build_error.msg)
	}
	clear(&build_errors)
}

// slangc error shape:
//   error[E20001]: unexpected token
//     --> src/shaders/scenes/apple.slang:27:1
//
// Binding gotcha (debugged 2026-10-03, apple scene black screen): slang
// assigns Metal texture indices by declaration order and THEN dead-code
// eliminates unused resources. A debug write like
// `out_tex[uv] = float4(float3(1,0,0), 1.0);` doesn't use the sampled
// paper texture, so the sampler is eliminated but out_tex stays at
// [[texture(1)]], while SDL binds the pass storage texture at Metal
// index 0. Writes land on an unbound texture and are silently discarded
// (black screen, white GPU download, valid-looking MSL). Rule: debug
// writes must still consume the sampled values; samplers first, storage
// after, matching SDL's expectation.
build_errors_parse :: proc(stderr: string) {
	// Runs on the scene build worker: the editor reads build_errors on the
	// main thread under the same mutex.
	sync.mutex_lock(&scene_build_mu)
	defer sync.mutex_unlock(&scene_build_mu)
	build_errors_clear()
	lines := strings.split_lines(stderr, context.temp_allocator)
	for i := 0; i < len(lines); i += 1 {
		error_line := strings.trim_space(lines[i])
		if !strings.has_prefix(error_line, "error") do continue
		error_msg := error_line
		for j := i + 1; j < min(i + 4, len(lines)); j += 1 {
			location_line := strings.trim_space(lines[j])
			if !strings.has_prefix(location_line, "-->") do continue
			location_ref := strings.trim_space(strings.trim_prefix(location_line, "-->"))
			last := strings.last_index(location_ref, ":")
			if last < 0 do break
			prev := strings.last_index(location_ref[:last], ":")
			if prev < 0 do break
			col_num, _ := strconv.parse_int(location_ref[last + 1:])
			line_num, _ := strconv.parse_int(location_ref[prev + 1:])
			path := location_ref[:prev]
			// Keep the path relative to src/shaders ("scenes/apple").
			rel_path := path
			if prefix_at := strings.index(rel_path, "src/shaders/"); prefix_at >= 0 {
				rel_path = rel_path[prefix_at + len("src/shaders/"):]
			}
			rel_path = strings.trim_suffix(rel_path, ".slang")
			// Canonicalize "scenes/../common" -> "common": slang follows
			// imports and can report the error inside an imported file.
			for {
				dotdot_at := strings.index(rel_path, "/../")
				if dotdot_at < 0 do break
				prev := strings.last_index(rel_path[:dotdot_at], "/")
				if prev < 0 {
					rel_path = rel_path[dotdot_at + 4:]
					break
				}
				rel_path = strings.concatenate({rel_path[:prev], rel_path[dotdot_at + 3:]}, context.temp_allocator)
			}
			append(
				&build_errors,
				BuildError {
					file = strings.clone(rel_path),
					line = line_num,
					col  = col_num,
					msg  = strings.clone(error_msg),
				},
			)
			break
		}
	}
	build_errors_version += 1
}

// Runtime scene system: a scene is a directory in SCENES_DIR: a small
// unit owning its files: <name>/<name>.slang is the entry shader,
// graph.json the node structure (see imgui_nodes.odin), and any further
// .slang files are scene-owned modules. Adding a directory needs no code
// change: the watcher (scene_poll) generates a goose manifest for the
// found scenes, runs goose-build, and (re)builds pipelines, uniform
// blocks, and UI widgets from slang's reflection JSON. Scenes are data:
// only infra shaders (blit, blit3d, ui) stay compiled into the app.
//
// Conventions for scene shaders:
// - import "../../common" for SceneUniforms, helpers, and the Ui* widget
//   attributes ([UiSlider]/[UiToggle]/[UiColor] on params fields).
// - Compute: [shader("compute")] entry, writes a RWTexture2D<float4>.
// - Graphics: vertMain = common.fullscreen_vertex, pixelMain writes
//   SV_Target0; the pass renders into the same scene texture.
// - If the scene declares samplers, slot 0 gets the selected paper
//   texture.
// - Uniform fields named iResolution/iTime/iFbm/iColorMode/iManual are
//   filled by the app; everything else comes from widgets.

SCENES_DIR :: "src/shaders/scenes"
// User scenes live OUTSIDE the source tree: they survive repo updates
// and are clearly separated from the built-in learning trail in the
// scene selector. Created on demand by scene_user_dir.
USER_SCENES_DIR :: "gis_scenes"
// Scene artifacts live in their own directory, outside the compiled
// `generated` package: the glue .odin goose emits for scenes is unused
// (pipelines are built from reflection JSON) and two manifests sharing
// one outputDir would clobber each other's common.odin.
GENERATED_DIR :: "src/generated/scenes"
SCENES_MANIFEST :: "src/generated/scenes/manifest.json"

// Scene title -> owning root directory. Filled by scene_names_on_disk;
// every path helper (entry path, modules, mtimes, graph.json) resolves
// through it so a user scene renders identically to a built-in one.
scene_roots: map[string]string

SceneKind :: enum {
	COMPUTE,
	GRAPHICS,
}

// Stage discriminator for reflection parsing (sdl.GPUShaderStage has no
// compute value).
StageKind :: enum {
	COMPUTE,
	VERTEX,
	FRAGMENT,
}

UiWidgetKind :: enum {
	SLIDER,
	TOGGLE,
	COLOR,
}

UiWidget :: struct {
	label:    string,
	kind:     UiWidgetKind,
	min:      f32,
	max:      f32,
	step:     f32,
	value:    [3]f32, // SLIDER uses [0], COLOR uses all three
	on:       bool,   // TOGGLE
}

UniformField :: struct {
	name:   string,
	offset: int,
	size:   int,
}

CBuffer :: struct {
	name:         string,
	compute_slot: u32,
	vert_slot:    u32,
	frag_slot:    u32,
	block:        []u8,
	fields:       [dynamic]UniformField,
	in_vert:      bool, // graphics: stage presence (push only where declared)
	in_frag:      bool,
}

// One render pass of a scene: the entry shader plus every scene-owned
// module (pass_1.slang, pass_2.slang, ...), executed in order. A pass
// after the first samples the previous pass's frame through a texture
// named "input_tex".
ScenePass :: struct {
	name:     string, // artifact base in GENERATED_DIR (scene title or "title__mod")
	graph_key: string, // stable graph.json node key
	kind:     SceneKind,
	compute:  ^sdl.GPUComputePipeline,
	graphics: ^sdl.GPUGraphicsPipeline,
	thread:   [3]u32,
	entry:    string, // compute entry; graphics entries below
	entry_vert, entry_frag: string,
	cbuffers: [dynamic]CBuffer,
	// Sampled texture names in sampler-slot order. Bound by name:
	// "input_tex" gets the previous pass's frame, "skybox_tex" the
	// selected skybox; anything else falls back to paper.
	sampler_textures: [dynamic]string,
	debug_compute_buffer: bool,
	debug_fragment_buffer: bool,
	debug_compute_slot: u32,
	debug_fragment_slot: u32,
	debug_watch_labels: [DEBUG_WATCH_COUNT]string,
	// Model-viewer passes: the vertex entry takes a [[stage_in]] struct,
	// so the default model (model.odin) is drawn indexed with depth
	// instead of the fullscreen triangle.
	uses_model:   bool,
	vertex_attrs: [dynamic]sdl.GPUVertexAttribute,
}

RuntimeScene :: struct {
	title:    string,
	source:   string,
	mtime:    time.Time,
	loaded:   bool,
	user_owned: bool, // lives in USER_SCENES_DIR, not the repo tree
	passes:   [dynamic]ScenePass,
	// Widgets merged from every pass's reflection (deduped by label);
	// values live here, writes fan out to the pass cbuffers by field name.
	widgets:  [dynamic]UiWidget,
	kind:     SceneKind, // first pass's kind
	// Any pass draws the model (camera interaction + backdrop clear).
	uses_model: bool,
	pipeline:       PipelinePlan,
	pipeline_mtime: time.Time,
	pipeline_error: string,
}

SceneManager :: struct {
	scenes:  [dynamic]RuntimeScene,
	current: int,
}

// --------------------------------------------------------------------
// JSON navigation helpers (slang reflection schema, defensive lookups)

jget :: proc(value: json.Value, json_key: string) -> json.Value {
	obj, is_object := value.(json.Object)
	if !is_object do return nil
	return obj[json_key]
}

jarr :: proc(value: json.Value) -> []json.Value {
	items, is_array := value.(json.Array)
	if !is_array do return nil
	return items[:]
}

jstr :: proc(value: json.Value) -> string {
	text, is_string := value.(json.String)
	if !is_string do return ""
	return text
}

jfloat :: proc(value: json.Value) -> f32 {
	#partial switch variant in value {
	case json.Float:
		return f32(variant)
	case json.Integer:
		return f32(variant)
	}
	return 0
}

jint :: proc(value: json.Value) -> int {
	return int(jfloat(value))
}

jkind :: proc(value: json.Value) -> string {
	return jstr(jget(value, "kind"))
}

// --------------------------------------------------------------------
// Reflection parsing

// Counts resources of one parameter list (global scope or one entry
// point) into SDL pipeline counts.
ResourceCounts :: struct {
	samplers:  u32,
	ro_tex:    u32,
	rw_tex:    u32,
	ro_buf:    u32,
	rw_buf:    u32,
	ubuf:      u32,
}

// Returns the stage's "used" flag for a named resource (0 when absent).
entry_binding_used :: proc(entry: json.Value, name: string) -> int {
	for binding_entry in jarr(jget(entry, "bindings")) {
		if jstr(jget(binding_entry, "name")) == name {
			return jint(jget(jget(binding_entry, "binding"), "used"))
		}
	}
	return 0
}

// Resource usage of ONE stage: entryPoints[].bindings carries a per-
// stage "used" flag (global parameters list every module resource).
count_resources :: proc(params: []json.Value, entry: json.Value) -> ResourceCounts {
	counts: ResourceCounts
	for binding_entry in jarr(jget(entry, "bindings")) {
		binding := jget(binding_entry, "binding")
		if jint(jget(binding, "used")) == 0 do continue
		name := jstr(jget(binding_entry, "name"))
		access := ""
		type_kind := ""
		base_shape := ""
		for param in params {
			if jstr(jget(param, "name")) != name do continue
			access = jstr(jget(param, "access"))
			if access == "" do access = jstr(jget(jget(param, "type"), "access"))
			type_kind = jkind(jget(param, "type"))
			base_shape = jstr(jget(jget(param, "type"), "baseShape"))
			break
		}
		is_buffer := strings.contains(type_kind, "tructuredBuffer") || strings.contains(base_shape, "tructuredBuffer")
		read_write := access == "readWrite"
		if is_buffer {
			if read_write {
				counts.rw_buf += 1
			} else {
				counts.ro_buf += 1
			}
			continue
		}

		switch jkind(binding) {
		case "samplerState":
			counts.samplers += 1
		case "constantBuffer":
			// Raw MSL keeps original buffer indices. Gaps count: a sole
			// buffer(1) requires num_uniform_buffers=2 and push slot 1.
			counts.ubuf = max(counts.ubuf, u32(jint(jget(binding, "index")) + 1))
		case "shaderResource":
			if read_write {
				counts.rw_tex += 1
			} else {
				counts.ro_tex += 1
			}
		}
	}
	// A Texture2D read through a SamplerState is a SAMPLED texture in SDL
	// terms, not a readonly storage texture: slang pairs texture index i
	// with sampler index i, so the first `samplers` readonly textures are
	// sampled and must not be counted as storage.
	counts.ro_tex -= min(counts.ro_tex, counts.samplers)
	return counts
}

debug_buffer_slot :: proc(params: []json.Value, entry: json.Value, target: string) -> (u32, bool) {
	rw_slot: u32
	for binding_entry in jarr(jget(entry, "bindings")) {
		if jint(jget(jget(binding_entry, "binding"), "used")) == 0 do continue
		name := jstr(jget(binding_entry, "name"))
		is_buffer := false
		read_write := false
		for param in params {
			if jstr(jget(param, "name")) != name do continue
			type_ := jget(param, "type")
			is_buffer = strings.contains(jkind(type_), "tructuredBuffer") ||
			            strings.contains(jstr(jget(type_, "baseShape")), "tructuredBuffer")
			access := jstr(jget(param, "access"))
			if access == "" do access = jstr(jget(type_, "access"))
			read_write = access == "readWrite"
			break
		}
		if !is_buffer || !read_write do continue
		if name == target do return rw_slot, true
		rw_slot += 1
	}
	return 0, false
}

// Merges the constant buffers of one stage's reflection into the pass:
// same-name cbuffers from the other stage unify, with stage presence
// taken from the entry point's used bindings so graphics pushes only
// where the block is used. Widgets go to the scene-level list, deduped
// by label across passes.
parse_cbuffers :: proc(
	pass: ^ScenePass,
	scene: ^RuntimeScene,
	params: []json.Value,
	entry: json.Value,
	stage: StageKind,
) {
	for param in params {
		binding := jget(param, "binding")
		if jkind(binding) != "constantBuffer" || jkind(jget(param, "type")) != "constantBuffer" do continue
		name := jstr(jget(param, "name"))
		if entry_binding_used(entry, name) == 0 do continue
		cbuffer: ^CBuffer
		for &existing in pass.cbuffers {
			if existing.name == name {
				cbuffer = &existing
				break
			}
		}
		if cbuffer == nil {
			append(&pass.cbuffers, CBuffer {
				name = strings.clone(name),
			})
			cbuffer = &pass.cbuffers[len(pass.cbuffers) - 1]

			fields := jarr(jget(jget(jget(jget(param, "type"), "elementVarLayout"), "type"), "fields"))
			size := 0
			for field_def in fields {
				fbinding := jget(field_def, "binding")
				field := UniformField {
					name   = strings.clone(jstr(jget(field_def, "name"))),
					offset = jint(jget(fbinding, "offset")),
					size   = jint(jget(fbinding, "size")),
				}
				append(&cbuffer.fields, field)
				size = max(size, field.offset + field.size)

				// Widget attributes ([UiSlider]/[UiToggle]/[UiColor]).
				for attr in jarr(jget(field_def, "userAttribs")) {
					args := jarr(jget(attr, "arguments"))
					widget := UiWidget {
						label = field.name,
					}
					switch jstr(jget(attr, "name")) {
					case "UiSlider":
						widget.kind = .SLIDER
						if len(args) >= 4 {
							widget.min = jfloat(args[0])
							widget.max = jfloat(args[1])
							widget.step = jfloat(args[2])
							widget.value[0] = jfloat(args[3])
						}
					case "UiToggle":
						widget.kind = .TOGGLE
						if len(args) >= 1 do widget.on = jfloat(args[0]) != 0
					case "UiColor":
						widget.kind = .COLOR
						widget.value = {1, 1, 1}
						if len(args) >= 3 {
							widget.value = {jfloat(args[0]), jfloat(args[1]), jfloat(args[2])}
						}
					case:
						continue
					}
					seen := false
					for existing in scene.widgets {
						if existing.label == widget.label {
							seen = true
							break
						}
					}
					if !seen do append(&scene.widgets, widget)
				}
			}
			// std140 rounds the block to a multiple of 16.
			cbuffer.block = make([]u8, (size + 15) &~ 15)
		}
		slot := u32(jint(jget(binding, "index")))
		#partial switch stage {
		case .COMPUTE:
			cbuffer.compute_slot = slot
		case .VERTEX:
			cbuffer.in_vert = true
			cbuffer.vert_slot = slot
		case .FRAGMENT:
			cbuffer.in_frag = true
			cbuffer.frag_slot = slot
		}
	}
}

// Parses one per-stage reflection file (<name>.<stage>.msl.refl.json):
// resource counts (used-marked), entry point name, thread count, and
// cbuffers merged into the pass (widgets go to the scene).
scene_parse_stage_refl :: proc(
	pass: ^ScenePass,
	scene: ^RuntimeScene,
	path: string,
	stage: StageKind,
) -> (counts: ResourceCounts, succeeded: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		log.errorf("scene %s: failed to read %s", scene.title, path)
		return {}, false
	}
	root, parse_err := json.parse(data)
	if parse_err != nil {
		log.errorf("scene %s: failed to parse %s: %v", scene.title, path, parse_err)
		return {}, false
	}
	// The reflection JSON tree is heap-allocated (50KB+ per pass file);
	// without destroying it, every hot reload leaks the whole tree.
	defer json.destroy_value(root)

	entry: json.Value
	for entry_point in jarr(jget(root, "entryPoints")) {
		if entry == nil do entry = entry_point
		#partial switch stage {
		case .COMPUTE:
			pass.entry = strings.clone(jstr(jget(entry_point, "name")))
			thread_group := jarr(jget(entry_point, "threadGroupSize"))
			if len(thread_group) == 3 {
				pass.thread = {u32(jint(thread_group[0])), u32(jint(thread_group[1])), u32(jint(thread_group[2]))}
			}
		case .VERTEX:
			pass.entry_vert = strings.clone(jstr(jget(entry_point, "name")))
			// A [[stage_in]] struct means the pass wants the default
			// model drawn indexed (attribute offsets come from the fixed
			// model layout, keyed by attribute location).
			for param in jarr(jget(entry_point, "parameters")) {
				if jkind(jget(param, "binding")) != "varyingInput" do continue
				for field in jarr(jget(jget(param, "type"), "fields")) {
					location := jint(jget(jget(field, "binding"), "index"))
					offset, offset_ok := model_attr_offset(location)
					if !offset_ok {
						log.errorf(
							"scene %s: model vertex attribute %s has unsupported location %d",
							scene.title, jstr(jget(field, "name")), location,
						)
						continue
					}
					format: sdl.GPUVertexElementFormat
					switch jint(jget(jget(field, "type"), "elementCount")) {
					case 1:
						format = .FLOAT
					case 2:
						format = .FLOAT2
					case 3:
						format = .FLOAT3
					case 4:
						format = .FLOAT4
					case:
						continue
					}
					append(&pass.vertex_attrs, sdl.GPUVertexAttribute {
						location    = u32(location),
						buffer_slot = 0,
						format      = format,
						offset      = offset,
					})
				}
				if len(pass.vertex_attrs) > 0 do pass.uses_model = true
			}
		case .FRAGMENT:
			pass.entry_frag = strings.clone(jstr(jget(entry_point, "name")))
		}
	}
	if pass.thread == {} do pass.thread = {8, 8, 1}

	params := jarr(jget(root, "parameters"))
	counts = count_resources(params, entry)
	parse_cbuffers(pass, scene, params, entry, stage)
	if slot, found := debug_buffer_slot(params, entry, "debug_records"); found {
		if stage == .COMPUTE {
			pass.debug_compute_buffer = true
			pass.debug_compute_slot = slot
		} else if stage == .FRAGMENT {
			pass.debug_fragment_buffer = true
			pass.debug_fragment_slot = slot
		}
	}

	// Sampled textures in sampler-slot order (compute and fragment
	// stages): slang pairs the i-th sampled texture with the i-th
	// sampler by binding index.
	if stage != .VERTEX {
		for binding_entry in jarr(jget(entry, "bindings")) {
			binding := jget(binding_entry, "binding")
			if jkind(binding) != "samplerState" || jint(jget(binding, "used")) == 0 do continue
			slot := jint(jget(binding, "index"))
			for texture_entry in jarr(jget(entry, "bindings")) {
				texture_binding := jget(texture_entry, "binding")
				if jkind(texture_binding) != "shaderResource" do continue
				if jint(jget(texture_binding, "index")) != slot || jint(jget(texture_binding, "used")) == 0 do continue
				for len(pass.sampler_textures) <= slot {
					append(&pass.sampler_textures, "")
				}
				pass.sampler_textures[slot] = strings.clone(jstr(jget(texture_entry, "name")))
			}
		}
	}
	return counts, true
}

// Shader format per host platform: MSL on macOS (Metal), SPIR-V elsewhere
// (Vulkan). The baked build (goose.json) emits both; hot-reload requests
// only the host's format. D3D12 (DXIL) is not emitted yet; honest scope.
SCENE_FMT      :: "msl" when ODIN_OS == .Darwin else "spv"
SCENE_FMT_FLAG :: sdl.GPUShaderFormat{.MSL} when ODIN_OS == .Darwin else sdl.GPUShaderFormat{.SPIRV}
SCENE_TARGET   :: "metal" when ODIN_OS == .Darwin else "spirv"

// Builds the pipeline of one pass from its artifacts in GENERATED_DIR
// (<name>.<stage>.<fmt> + .refl.json), where name is the scene title for
// the entry shader or "title__mod" for a scene-owned module.
scene_parse_pass :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene, name: string) -> (ScenePass, bool) {
	pass := ScenePass {
		name = strings.clone(name),
	}
	compute_refl := fmt.tprintf("%s/%s.compute.%s.refl.json", GENERATED_DIR, name, SCENE_FMT)
	vert_refl := fmt.tprintf("%s/%s.vert.%s.refl.json", GENERATED_DIR, name, SCENE_FMT)
	frag_refl := fmt.tprintf("%s/%s.frag.%s.refl.json", GENERATED_DIR, name, SCENE_FMT)

	if os.exists(compute_refl) {
		pass.kind = .COMPUTE
		counts, succeeded := scene_parse_stage_refl(&pass, scene, compute_refl, .COMPUTE)
		if !succeeded do return pass, false
		pass.compute = create_compute_pipeline_raw(
			gpu,
			fmt.tprintf("%s/%s.compute.%s", GENERATED_DIR, name, SCENE_FMT),
			pass.entry,
			counts,
			pass.thread,
		)
		return pass, pass.compute != nil
	}

	if os.exists(vert_refl) && os.exists(frag_refl) {
		pass.kind = .GRAPHICS
		vert_counts, vert_ok := scene_parse_stage_refl(&pass, scene, vert_refl, .VERTEX)
		frag_counts, frag_ok := scene_parse_stage_refl(&pass, scene, frag_refl, .FRAGMENT)
		if !vert_ok || !frag_ok do return pass, false
		pass.graphics = create_graphics_pipeline_raw(
			gpu,
			fmt.tprintf("%s/%s.vert.%s", GENERATED_DIR, name, SCENE_FMT),
			fmt.tprintf("%s/%s.frag.%s", GENERATED_DIR, name, SCENE_FMT),
			pass.entry_vert,
			pass.entry_frag,
			vert_counts,
			frag_counts,
			&pass,
		)
		return pass, pass.graphics != nil
	}

	log.errorf("scene %s: no reflection artifacts for %s", scene.title, name)
	return pass, false
}

debug_watch_arg_comma :: proc(source: string, start: int) -> int {
	depth := 0
	for i := start; i < len(source); i += 1 {
		switch source[i] {
		case '(', '[', '{':
			depth += 1
		case ')':
			if depth == 0 do return -1
			depth -= 1
		case ']', '}':
			depth = max(depth - 1, 0)
		case ',':
			if depth == 0 do return i
		}
	}
	return -1
}

scene_parse_debug_watch_labels :: proc(pass: ^ScenePass, path: string) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return
	source := string(data)
	markers := []string{"debug_watch_fragment(", "debug_watch_compute("}
	for marker in markers {
		cursor := 0
		for cursor < len(source) {
			marker_at := strings.index(source[cursor:], marker)
			if marker_at < 0 do break
			call_start := cursor + marker_at
			args_start := call_start + len(marker)
			cursor = args_start
			line_start := strings.last_index(source[:call_start], "\n") + 1
			if strings.index(source[line_start:call_start], "//") >= 0 do continue
			first := debug_watch_arg_comma(source, args_start)
			if first < 0 do continue
			second := debug_watch_arg_comma(source, first + 1)
			if second < 0 do continue
			cursor = second + 1
			slot, slot_ok := strconv.parse_int(strings.trim_space(source[args_start:first]))
			if !slot_ok || slot < 0 || slot >= DEBUG_WATCH_COUNT do continue
			label := strings.trim_space(source[first + 1:second])
			if label == "" || pass.debug_watch_labels[slot] != "" do continue
			if len(label) > 48 do label = label[:48]
			pass.debug_watch_labels[slot] = strings.clone(label)
		}
	}
}

// Parses the entry shader plus every scene-owned module (pass_1.slang,
scene_parse_reflection :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene) -> bool {
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	sources := make([dynamic]string, 0, 4, context.temp_allocator)
	append(&names, scene.title)
	append(&sources, scene.source)
	for module_name in scene_module_names(scene.title) {
		append(&names, fmt.tprintf("%s__%s", scene.title, module_name))
		append(&sources, fmt.tprintf("%s/%s/%s.slang", SCENES_DIR, scene.title, module_name))
	}
	for name, i in names {
		pass, succeeded := scene_parse_pass(gpu, scene, name)
		if !succeeded {
			scene_release_pass(gpu, &pass)
			return false
		}
		scene_parse_debug_watch_labels(&pass, sources[i])
		source_key := strings.trim_suffix(strings.trim_prefix(sources[i], "src/shaders/"), ".slang")
		if pass.kind == .COMPUTE {
			pass.graph_key = strings.clone(fmt.tprintf("comp:%s:%s", source_key, pass.entry))
		} else {
			pass.graph_key = strings.clone(fmt.tprintf("gfx:%s", source_key))
		}
		scene.uses_model |= pass.uses_model
		append(&scene.passes, pass)
	}
	if len(scene.passes) == 0 do return false
	scene.kind = scene.passes[0].kind
	return true
}

// pass_2.slang, ...) into the scene's ordered pass chain.

// --------------------------------------------------------------------
// Pipeline creation from reflection counts (no compiled glue)

create_shader_raw :: proc(
	gpu: ^sdl.GPUDevice,
	path: string,
	entrypoint: string,
	stage: sdl.GPUShaderStage,
	counts: ResourceCounts,
) -> ^sdl.GPUShader {
	blob, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		log.errorf("scene: failed to read %s", path)
		return nil
	}
	shader := sdl.CreateGPUShader(
		gpu,
		{
			stage = stage,
			format = SCENE_FMT_FLAG,
			code_size = len(blob),
			code = raw_data(blob),
			entrypoint = strings.clone_to_cstring(entrypoint, context.temp_allocator),
			num_samplers = counts.samplers,
			num_uniform_buffers = counts.ubuf,
			num_storage_buffers = counts.rw_buf,
			num_storage_textures = counts.rw_tex,
		},
	)
	if shader == nil {
		log.errorf("scene: failed to create shader from %s: %s", path, sdl.GetError())
	}
	return shader
}

create_compute_pipeline_raw :: proc(
	gpu: ^sdl.GPUDevice,
	msl_path: string,
	entrypoint: string,
	counts: ResourceCounts,
	thread: [3]u32,
) -> ^sdl.GPUComputePipeline {
	blob, read_err := os.read_entire_file(msl_path, context.temp_allocator)
	if read_err != nil {
		log.errorf("scene: failed to read %s", msl_path)
		return nil
	}
	pipeline := sdl.CreateGPUComputePipeline(
		gpu,
		{
			code = raw_data(blob),
			code_size = len(blob),
			entrypoint = strings.clone_to_cstring(entrypoint, context.temp_allocator),
			format = SCENE_FMT_FLAG,
			num_samplers = counts.samplers,
			num_readonly_storage_textures = counts.ro_tex,
			num_readonly_storage_buffers = counts.ro_buf,
			num_readwrite_storage_textures = counts.rw_tex,
			num_readwrite_storage_buffers = counts.rw_buf,
			num_uniform_buffers = counts.ubuf,
			threadcount_x = thread.x,
			threadcount_y = thread.y,
			threadcount_z = thread.z,
		},
	)
	if pipeline == nil {
		log.errorf("scene: failed to create compute pipeline %s: %s", msl_path, sdl.GetError())
	}
	return pipeline
}

create_graphics_pipeline_raw :: proc(
	gpu: ^sdl.GPUDevice,
	vert_path, frag_path: string,
	entry_vert, entry_frag: string,
	vert_counts, frag_counts: ResourceCounts,
	pass: ^ScenePass,
) -> ^sdl.GPUGraphicsPipeline {
	vert_shader := create_shader_raw(gpu, vert_path, entry_vert, .VERTEX, vert_counts)
	if vert_shader == nil do return nil
	defer sdl.ReleaseGPUShader(gpu, vert_shader)
	frag_shader := create_shader_raw(gpu, frag_path, entry_frag, .FRAGMENT, frag_counts)
	if frag_shader == nil do return nil
	defer sdl.ReleaseGPUShader(gpu, frag_shader)

	create_info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vert_shader,
		fragment_shader = frag_shader,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {
			fill_mode  = .FILL,
			cull_mode  = .BACK,
			front_face = .COUNTER_CLOCKWISE,
		},
		target_info = {
			num_color_targets = 1,
			color_target_descriptions = &(sdl.GPUColorTargetDescription {
					format = .R8G8B8A8_UNORM, // the scene texture
				}),
		},
	}
	if pass.uses_model {
		// Model draw: interleaved vertex buffer at slot 0, depth-tested.
		create_info.vertex_input_state = {
			num_vertex_buffers = 1,
			vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
				slot = 0,
				pitch = MODEL_PITCH,
				input_rate = .VERTEX,
			}),
			num_vertex_attributes = u32(len(pass.vertex_attrs)),
			vertex_attributes = raw_data(pass.vertex_attrs),
		}
		create_info.target_info.depth_stencil_format = .D32_FLOAT
		create_info.depth_stencil_state = {
			compare_op = .LESS,
			enable_depth_test = true,
			enable_depth_write = true,
		}
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(gpu, create_info)
	if pipeline == nil {
		log.errorf("scene: failed to link graphics pipeline: %s", sdl.GetError())
	}
	return pipeline
}
// Root directory owning a scene: the user dir when registered there,
// the built-in tree otherwise. Unknown names fall back to built-in so
// callers before the first scan still build valid paths.
scene_root_dir :: proc(name: string) -> string {
	if root, found := scene_roots[name]; found do return root
	return SCENES_DIR
}

// A scene is a directory under its root: <name>/<name>.slang is the
// entry shader, graph.json its node structure, and any extra .slang
// files are scene-owned modules. This is the entry path for a scene name.
scene_entry_path :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s/%s.slang", scene_root_dir(name), name, name)
}

// Scene-owned module files (every .slang in the scene dir except the
// entry), sorted by name: this is the pass chain order, so chained
// passes name themselves pass_1, pass_2, ... Returned names carry no
// extension.
scene_module_names :: proc(name: string) -> [dynamic]string {
	// Temp-allocated: the caller consumes the list while parsing the
	// scene (same frame), and the per-frame free_all reclaims it.
	mods := make([dynamic]string, context.temp_allocator)
	scene_dir := fmt.tprintf("%s/%s", scene_root_dir(name), name)
	entries, scan_err := os.read_directory_by_path(scene_dir, 0, context.temp_allocator)
	if scan_err != nil do return mods
	entry_file := fmt.tprintf("%s.slang", name)
	for entry in entries {
		if entry.type != .Regular do continue
		if !strings.has_suffix(entry.name, ".slang") do continue
		if entry.name == entry_file do continue
		append(&mods, strings.clone(entry.name[:len(entry.name) - len(".slang")], context.temp_allocator))
	}
	slice.sort(mods[:])
	return mods
}
scene_names_on_disk :: proc() -> [dynamic]string {
	// Temp-allocated: callers (scene_poll/rescan) use the list within the
	// frame, and the main loop's per-frame free_all reclaims it: the
	// heap would otherwise grow by ~24 strings every frame forever.
	names := make([dynamic]string, context.temp_allocator)
	// Built-in first, then user scenes: a user scene with the same name
	// as a built-in one shadows it (registered last wins in scene_roots).
	roots := [2]string{SCENES_DIR, scene_user_dir()}
	for root in roots {
		entries, scan_err := os.read_directory_by_path(root, 0, context.temp_allocator)
		if scan_err != nil do continue
		for entry in entries {
			if entry.type != .Directory do continue
			if !os.exists(fmt.tprintf("%s/%s/%s.slang", root, entry.name, entry.name)) do continue
			// Keys must outlive the frame: the poll path frees the temp
			// allocator every frame, and a map key pointing into it
			// dangles (lookup misses, user scenes fall back to builtin).
			if _, found := scene_roots[entry.name]; !found {
				scene_roots[strings.clone(entry.name)] = root
			} else {
				scene_roots[entry.name] = root
			}
			// Dedup across roots: the shadowed duplicate is dropped.
			duplicate := false
			for existing in names do if existing == entry.name {
				duplicate = true
				break
			}
			if !duplicate do append(&names, strings.clone(entry.name, context.temp_allocator))
		}
	}
	slice.sort(names[:])
	return names
}

// The user scene root, created on first call: sibling to the repo (not
// inside it), so user work survives clean checkouts and updates.
scene_user_dir :: proc() -> string {
	user_dir := USER_SCENES_DIR
	if !os.exists(user_dir) {
		if os.make_directory(user_dir) == nil do log.infof("scenes: created user scene dir %s", user_dir)
	}
	return user_dir
}

// Writes a goose manifest for the given scenes and runs goose-build so
// their artifacts (msl + refl.json) exist and are fresh.
scenes_build :: proc(names: []string) -> bool {
	os.make_directory(GENERATED_DIR) // fine if it already exists
	manifest := strings.builder_make(context.temp_allocator)
	strings.write_string(&manifest, `{"outputDir":"`)
	strings.write_string(&manifest, GENERATED_DIR)
	strings.write_string(&manifest, `","parameterOutputDir":"`)
	strings.write_string(&manifest, GENERATED_DIR)
	strings.write_string(&manifest, `",`)
	strings.write_string(&manifest, `"package":"generated","gooseImport":"../../../goose/src",`)
	// Hot-reload emits only the host's shader format (SCENE_TARGET);
	// the baked goose.json build still emits both msl and spv.
	strings.write_string(&manifest, `"commonUniforms":true,"targets":["`)
	strings.write_string(&manifest, SCENE_TARGET)
	strings.write_string(&manifest, `"],"shaders":[`)
	// No fmt here: Odin's fmt treats '{' as a directive.
	write_shader :: proc(manifest: ^strings.Builder, name, source: string, first: ^bool) {
		if !first^ do strings.write_byte(manifest, ',')
		first^ = false
		strings.write_string(manifest, `{"name":"`)
		strings.write_string(manifest, name)
		strings.write_string(manifest, `","source":"`)
		strings.write_string(manifest, source)
		strings.write_string(manifest, `"}`)
	}
	first := true
	for name in names {
		entry := scene_entry_path(name)
		write_shader(&manifest, name, entry, &first)
		// Scene-owned modules (the pass chain): artifact names are
		// namespaced "scene__mod" so two scenes can both have pass_1.
		for module_name in scene_module_names(name) {
			source := fmt.tprintf("%s/%s/%s.slang", scene_root_dir(name), name, module_name)
			write_shader(&manifest, fmt.tprintf("%s__%s", name, module_name), source, &first)
		}
	}
	strings.write_string(&manifest, `]}`)
	if os.write_entire_file(SCENES_MANIFEST, transmute([]u8)strings.to_string(manifest)) != nil {
		log.errorf("scenes: failed to write %s", SCENES_MANIFEST)
		return false
	}

	// Cross-process exclusion: more than one app instance may watch the
	// same src/shaders tree (two dev builds at once), and concurrent
	// goose-build runs corrupt each other's artifacts: reflection files
	// left truncated at 0 bytes, scenes stuck "goose-build failed"
	// forever (seen live with graphics2d). Serialize through an O_EXCL
	// lockfile; if another process holds it, skip this round: the next
	// rescan picks up its artifacts.
	lock, lock_err := os.open(
		"src/generated/scenes/.build.lock",
		{.Write, .Create, .Excl},
	)
	if lock_err == nil {
		defer {
			os.close(lock)
			os.remove("src/generated/scenes/.build.lock")
		}
	} else {
		// Stale lock guard: a crashed builder never releases. Treat a
		// lock older than a minute as stale and take it over.
		if info, stat_err := os.stat("src/generated/scenes/.build.lock", context.temp_allocator);
		   stat_err == nil && time.since(info.modification_time) > time.Minute {
			os.remove("src/generated/scenes/.build.lock")
		}
		log.info("scenes: build lock held by another instance; skipping")
		return true
	}

	goose_bin := os.get_env("GOOSE", context.temp_allocator)
	if goose_bin == "" do goose_bin = "../goose/goose-build"
	slang := os.get_env("SLANG", context.temp_allocator)
	if slang == "" do slang = "vendor/slang/bin/slangc"
	command := []string{goose_bin, "--manifest", SCENES_MANIFEST, "--slang", slang}
	state, stdout, stderr, process_error := os.process_exec({command = command}, context.temp_allocator)
	if process_error != nil {
		log.errorf("scenes: failed to run goose-build: %v", process_error)
		return false
	}
	if !state.success {
		if len(stderr) > 0 {
			fmt.eprint(string(stderr))
			build_errors_parse(string(stderr))
		}
		log.warn("scenes: goose-build failed; keeping previous scene pipelines")
		return false
	}
	sync.mutex_lock(&scene_build_mu)
	if len(build_errors) > 0 {
		build_errors_clear()
		build_errors_version += 1
	}
	sync.mutex_unlock(&scene_build_mu)
	return true
}

scene_release_pass :: proc(gpu: ^sdl.GPUDevice, pass: ^ScenePass) {
	if pass.compute != nil do sdl.ReleaseGPUComputePipeline(gpu, pass.compute)
	if pass.graphics != nil do sdl.ReleaseGPUGraphicsPipeline(gpu, pass.graphics)
	delete(pass.name)
	delete(pass.graph_key)
	for cbuffer in pass.cbuffers do delete(cbuffer.block)
	delete(pass.cbuffers)
	delete(pass.sampler_textures)
	delete(pass.vertex_attrs)
	for label in pass.debug_watch_labels do if label != "" do delete(label)
}

scene_release :: proc(gpu: ^sdl.GPUDevice, scene: ^RuntimeScene) {
	for &pass in scene.passes do scene_release_pass(gpu, &pass)
	delete(scene.passes)
	delete(scene.widgets)
	pipeline_plan_destroy(&scene.pipeline)
	delete(scene.pipeline_error)
}

// Newest mtime across the scene's entry and module files: the reload key
// (a chained pass edit must rebuild the scene like an entry edit).
scene_latest_mtime :: proc(name: string) -> time.Time {
	latest: time.Time
	if info, stat_err := os.stat(scene_entry_path(name), context.temp_allocator); stat_err == nil {
		latest = info.modification_time
	}
	for module_name in scene_module_names(name) {
		path := fmt.tprintf("%s/%s/%s.slang", scene_root_dir(name), name, module_name)
		if info, stat_err := os.stat(path, context.temp_allocator); stat_err == nil {
			if time.diff(info.modification_time, latest) > 0 {
				latest = info.modification_time
			}
		}
	}
	return latest
}

// Loads a scene into `out`; on failure `out` is cleaned up and false is
// returned, so callers can keep a previous working version in place
// (e.g. artifacts corrupted by a concurrent instance or a slang error).
scene_load_into :: proc(gpu: ^sdl.GPUDevice, name: string, dest: ^RuntimeScene) -> bool {
	dest^ = RuntimeScene {
		title  = strings.clone(name),
		source = scene_entry_path(name),
	}
	dest.user_owned = scene_root_dir(name) == USER_SCENES_DIR
	if !os.exists(dest.source) do return false
	dest.mtime = scene_latest_mtime(name)

	if !scene_parse_reflection(gpu, dest) || !pipeline_scene_init(dest) {
		scene_release(gpu, dest)
		return false
	}
	dest.loaded = true
	return true
}

scene_load :: proc(manager: ^SceneManager, gpu: ^sdl.GPUDevice, name: string) -> bool {
	scene: RuntimeScene
	if !scene_load_into(gpu, name, &scene) do return false
	append(&manager.scenes, scene)
	return true
}

// --------------------------------------------------------------------
// Async scene builds: saving a shader must not freeze the UI thread.
// scene_poll only REQUESTS a build; the worker thread runs goose-build
// (process exec, file IO), and scene_build_pump applies the result on the
// main thread (pipeline creation needs the GPU). Requests during a build
// coalesce into one follow-up build. The startup scan stays synchronous;
// the first frame needs pipelines.

scene_build_mu:      sync.Mutex

// Reload/build serialization: scene_build_pump sets scene_applying while
// scene_reload reads generated artifacts; the worker waits for it before
// running goose-build, which rewrites the same files. Without this a fast
// edit sequence makes the pump parse half-written reflection JSON.
scene_applying:      bool
scene_build_apply_cond: sync.Cond

// Scenes whose load failed at a given mtime (name -> mtime, names owned).
// A failed scene is retried only when its source changes again: a broken
// shader otherwise re-runs the failing build every frame, flooding the
// log with the same errors.
scene_failed: map[string]time.Time
scene_build_cond:    sync.Cond
scene_build_req:     bool
scene_build_running: bool
scene_build_done:    bool
scene_build_ok:      bool
scene_build_again:   bool
scene_build_names:   [dynamic]string
scene_build_thread:  ^thread.Thread

scene_build_worker :: proc() {
	for {
		sync.mutex_lock(&scene_build_mu)
		for !scene_build_req {
			sync.cond_wait(&scene_build_cond, &scene_build_mu)
		}
		scene_build_req = false
		scene_build_running = true
		// Snapshot the names under the lock: scene_request_build frees and
		// rebuilds scene_build_names concurrently, and the build itself
		// must wait for any in-flight reload to finish reading artifacts.
		names := make([dynamic]string, 0, len(scene_build_names))
		for scene_name in scene_build_names do append(&names, strings.clone(scene_name))
		for scene_applying {
			sync.cond_wait(&scene_build_apply_cond, &scene_build_mu)
		}
		sync.mutex_unlock(&scene_build_mu)

		succeeded := scenes_build(names[:])
		for scene_name in names do delete(scene_name)
		delete(names)
		// The worker's temp_allocator is separate from the main thread's:
		// without this, every build's manifest/file/JSON temp allocations
		// accumulate for the process's lifetime (long sessions balloon).
		free_all(context.temp_allocator)

		sync.mutex_lock(&scene_build_mu)
		scene_build_ok = succeeded
		scene_build_running = false
		scene_build_done = true
		sync.mutex_unlock(&scene_build_mu)
	}
}

// Requests a build on the worker thread (starts it lazily). A request
// while one is in flight coalesces into a single follow-up.
// Edit→pixel latency probe: armed when a build is
// requested, marked when a scene pipeline actually swaps in scene_reload,
// read by main after the next presented frame. Failed/no-op reloads disarm.
latency_pending: bool
latency_tick:    time.Tick
latency_swapped: bool

scene_request_build :: proc(names: []string) {
	if !latency_pending {
		latency_pending = true
		latency_tick = time.tick_now()
	}
	sync.mutex_lock(&scene_build_mu)
	if scene_build_thread == nil {
		scene_build_thread = thread.create_and_start(
			scene_build_worker,
			runtime.default_context(),
		)
	}
	if scene_build_req || scene_build_running {
		scene_build_again = true
		sync.mutex_unlock(&scene_build_mu)
		return
	}
	for scene_name in scene_build_names do delete(scene_name)
	clear(&scene_build_names)
	for scene_name in names do append(&scene_build_names, strings.clone(scene_name))
	scene_build_req = true
	sync.cond_signal(&scene_build_cond)
	sync.mutex_unlock(&scene_build_mu)
	log.infof("[scenes] async build queued (%d scenes)", len(names))
}

// Reports the edit→pixel latency once, after the frame that first renders
// a swapped pipeline. Called by main at the end of each frame.
latency_report :: proc() {
	if latency_pending && latency_swapped {
		elapsed_ms := f64(time.tick_since(latency_tick)) / f64(time.Millisecond)
		log.infof("[latency] edit->pixel: %.1f ms", elapsed_ms)
		latency_pending = false
		latency_swapped = false
	}
}

// Applies a finished build: reloads changed scenes on the main thread and
// queues the coalesced follow-up build, if any. Called every frame.
// Monotonic version consumed by the editor to snapshot source text only
// after a build produced a loadable pipeline.
scene_build_pump :: proc(manager: ^SceneManager, gpu: ^sdl.GPUDevice) {
	sync.mutex_lock(&scene_build_mu)
	if !scene_build_done {
		sync.mutex_unlock(&scene_build_mu)
		return
	}
	scene_build_done = false
	again := scene_build_again
	scene_build_again = false
	sync.mutex_unlock(&scene_build_mu)

	if !scene_build_ok {
		latency_pending = false
		latency_swapped = false
	}
	sync.mutex_lock(&scene_build_mu)
	scene_applying = true
	sync.mutex_unlock(&scene_build_mu)
	scene_reload(manager, gpu, scene_build_names[:])
	sync.mutex_lock(&scene_build_mu)
	scene_applying = false
	sync.cond_broadcast(&scene_build_apply_cond)
	sync.mutex_unlock(&scene_build_mu)
	log.infof("[scenes] async build applied (ok=%v)", scene_build_ok)
	if !scene_build_ok {
		notify(.ERROR, "%s", tr("build failed"))
	}
	if again && len(manager.scenes) > 0 {
		active := [1]string{manager.scenes[manager.current].title}
		scene_request_build(active[:])
	}
}

// Discovers the complete catalog but builds only the selected scene.
scene_rescan :: proc(manager: ^SceneManager, gpu: ^sdl.GPUDevice, start_scene: int) -> bool {
	names := scene_names_on_disk()
	if len(names) == 0 {
		log.errorf("no scene directories found in %s", SCENES_DIR)
		return false
	}
	for name in names {
		append(&manager.scenes, RuntimeScene {
			title = strings.clone(name),
			source = scene_entry_path(name),
		})
	}
	selected := start_scene
	if selected < 0 || selected >= len(manager.scenes) do selected = 0
	manager.current = selected
	if info, stat_err := os.stat("src/shaders/common.slang", context.temp_allocator); stat_err == nil {
		common_mtime = info.modification_time
	}
	return scene_ensure_loaded(manager, gpu, selected)
}

// Builds and loads one catalog entry. Scene-owned pass modules are included
// by scenes_build; Slang resolves imported utils through the module search path.
scene_ensure_loaded :: proc(manager: ^SceneManager, gpu: ^sdl.GPUDevice, index: int) -> bool {
	if index < 0 || index >= len(manager.scenes) {
		log.errorf("scene index out of range: %d", index)
		return false
	}
	if manager.scenes[index].loaded do return true
	name := manager.scenes[index].title
	requested := [1]string{name}
	if !scenes_build(requested[:]) {
		log.errorf("failed to build scene %s", name)
		return false
	}
	current_before := manager.current
	manager.current = index
	scene_reload(manager, gpu, requested[:])
	loaded := index < len(manager.scenes) && manager.scenes[index].loaded
	if !loaded {
		log.errorf("failed to load scene %s after build", name)
		manager.current = current_before
	}
	return loaded
}

// Synchronizes removals against the complete on-disk catalog. Reloads may
// receive only a subset of changed scenes, so removal cannot live there.
scene_drop_removed :: proc(manager: ^SceneManager, gpu: ^sdl.GPUDevice, names: []string) {
	current_title := strings.clone(manager.scenes[manager.current].title) if len(manager.scenes) > 0 else ""
	defer if current_title != "" do delete(current_title)
	for i := len(manager.scenes) - 1; i >= 0; i -= 1 {
		found := false
		for name in names do if manager.scenes[i].title == name { found = true; break }
		if !found {
			scene_release(gpu, &manager.scenes[i])
			ordered_remove(&manager.scenes, i)
		}
	}
	stale := make([dynamic]string, context.temp_allocator)
	for failed_key in scene_failed {
		found := false
		for name in names do if failed_key == name { found = true; break }
		if !found do append(&stale, failed_key)
	}
	for failed_key in stale {
		delete_key(&scene_failed, failed_key)
		delete(failed_key)
	}
	if len(manager.scenes) == 0 {
		manager.current = 0
		return
	}
	manager.current = 0
	if current_title != "" {
		for &scene_entry, i in manager.scenes do if scene_entry.title == current_title { manager.current = i; break }
	}
}

// Adds newly discovered scenes as unloaded catalog entries. Their shader
// artifacts are built only when the user selects them.
scene_add_new_catalog_entries :: proc(manager: ^SceneManager, names: []string) {
	for name in names {
		found := false
		for &scene_entry in manager.scenes do if scene_entry.title == name { found = true; break }
		if !found {
			append(&manager.scenes, RuntimeScene {
				title = strings.clone(name),
				source = scene_entry_path(name),
			})
		}
	}
}

// Reloads what changed after a build. Preserves the current scene by
// title; a scene that fails to reload keeps its previous working version.
scene_reload :: proc(manager: ^SceneManager, gpu: ^sdl.GPUDevice, names: []string) {
	current_title := strings.clone(manager.scenes[manager.current].title) if len(manager.scenes) > 0 else ""
	defer if current_title != "" do delete(current_title)


	// Add new, reload changed. A scene that fails to reload keeps its
	// previous working version in place, and a scene whose source didn't
	// change since the failure is NOT retried (otherwise a broken shader
	// re-runs the failing build every frame, spamming the same errors).
	for name in names {
		if !os.exists(scene_entry_path(name)) do continue
		mtime := scene_latest_mtime(name)
		if failed_at, was_failed := scene_failed[name]; was_failed && failed_at == mtime {
			continue
		}
		existing_index := -1
		for &scene_entry, i in manager.scenes do if scene_entry.title == name { existing_index = i; break }
		if existing_index >= 0 && manager.scenes[existing_index].mtime == mtime do continue
		succeeded: bool
		if existing_index >= 0 {
			candidate: RuntimeScene
			if scene_load_into(gpu, name, &candidate) {
				scene_release(gpu, &manager.scenes[existing_index])
				ordered_remove(&manager.scenes, existing_index)
				inject_at(&manager.scenes, existing_index, candidate)
				succeeded = true
			}
		} else {
			succeeded = scene_load(manager, gpu, name)
		}
		if succeeded {
			latency_swapped = true
			// Map indexing yields the value, so find the owned key to
			// free it (no delete_key during iteration).
			stored: string
			have_stored := false
			for key_name in scene_failed {
				if key_name == name { stored = key_name; have_stored = true; break }
			}
			if have_stored {
				// delete_key BEFORE delete: hashing the key after freeing
				// it is a use-after-free.
				delete_key(&scene_failed, stored)
				delete(stored)
			}
		} else if !(name in scene_failed) {
			scene_failed[strings.clone(name)] = mtime
			notify(.ERROR, tr("scene '%s' failed to load"), name)
		}
	}


	// A reload that swapped nothing leaves no latency to report (broken
	// scenes keep the previous pipeline by design).
	if latency_pending && !latency_swapped do latency_pending = false

	// Restore selection.
	manager.current = 0
	if current_title != "" {
		for &scene_entry, i in manager.scenes do if scene_entry.title == current_title { manager.current = i; break }
	}
}

SCENE_POLL_INTERVAL_MS :: u64(100)
scene_poll_started: bool
scene_poll_next_ms: u64

scene_poll :: proc(manager: ^SceneManager, gpu: ^sdl.GPUDevice) {
	// Apply finished async builds first (reloads change manager.scenes).
	if !scene_poll_started {
		scene_poll_started = true
		log.infof("[scenes] watcher active for %s", manager.scenes[manager.current].title)
	}
	scene_build_pump(manager, gpu)
	// Disk scans and stat calls do not need to run at the render rate.
	now_ms := sdl.GetTicks()
	if now_ms < scene_poll_next_ms do return
	scene_poll_next_ms = now_ms + SCENE_POLL_INTERVAL_MS
	names := scene_names_on_disk()
	scene_drop_removed(manager, gpu, names[:])
	scene_add_new_catalog_entries(manager, names[:])
	changed_names := make([dynamic]string, context.temp_allocator)
	if len(manager.scenes) == 0 do return
	active_name := manager.scenes[manager.current].title
	active_mtime := scene_latest_mtime(active_name)
	if failed_at, was_failed := scene_failed[active_name]; !was_failed || failed_at != active_mtime {
		if !manager.scenes[manager.current].loaded || manager.scenes[manager.current].mtime != active_mtime {
			log.infof("[scenes] source change detected: %s", active_name)
			append(&changed_names, active_name)
		}
	}
	// common.slang is imported by every scene. Rebuild only the active
	// scene now; unloaded scenes consume the new common when selected.
	info, stat_err := os.stat("src/shaders/common.slang", context.temp_allocator)
	if stat_err == nil && info.modification_time != common_mtime {
		common_mtime = info.modification_time
		clear(&changed_names)
		append(&changed_names, active_name)
		failed_keys := make([dynamic]string, context.temp_allocator)
		for failed_key in scene_failed do append(&failed_keys, failed_key)
		for failed_key in failed_keys {
			delete_key(&scene_failed, failed_key)
			delete(failed_key)
		}
	}
	if len(changed_names) > 0 do scene_request_build(changed_names[:])
}

common_mtime: time.Time

// --------------------------------------------------------------------
// Per-frame uniform filling

poke_f32 :: proc(block: []u8, offset: int, value: f32) {
	if offset < 0 || offset + 4 > len(block) do return
	(^f32)(rawptr(&block[offset]))^ = value
}

poke_u32 :: proc(block: []u8, offset: int, value: u32) {
	if offset < 0 || offset + 4 > len(block) do return
	(^u32)(rawptr(&block[offset]))^ = value
}

scene_set_manual :: proc(pass: ^ScenePass, value: f32) {
	for cbuffer in pass.cbuffers {
		for field in cbuffer.fields {
			if field.name == "iManual" do poke_f32(cbuffer.block, field.offset, value)
		}
	}
}

scene_set_debug_pass :: proc(pass: ^ScenePass, pass_index: u32) {
	for cbuffer in pass.cbuffers {
		for field in cbuffer.fields {
			if field.name == "iDebugPass" do poke_u32(cbuffer.block, field.offset, pass_index)
		}
	}
}

scene_has_debug_watches :: proc(scene: ^RuntimeScene) -> bool {
	for pass in scene.passes {
		if pass.debug_compute_buffer || pass.debug_fragment_buffer do return true
	}
	return false
}

// --------------------------------------------------------------------
// Frame submission


SceneResources :: struct {
	depth_tex:         ^sdl.GPUTexture,
	sampler:           ^sdl.GPUSampler,
	// Asset textures live in the gfx pool; targets stay raw.
	paper_textures:    []gfx.Texture_Handle,
	paper_index:       int,
	skybox_textures:   []gfx.Texture_Handle,
	skybox_index:      int,
	model:             ^Model,
	pass_tex:          []^sdl.GPUTexture,
	black_texture:     gfx.Texture_Handle,
	debug_watch_buffer: ^sdl.GPUBuffer,
}

push_scene_uniforms :: proc(cmd_buffer: ^sdl.GPUCommandBuffer, pass: ^ScenePass, compute: bool) {
	for cbuffer in pass.cbuffers {
		if compute {
			sdl.PushGPUComputeUniformData(cmd_buffer, cbuffer.compute_slot, raw_data(cbuffer.block), u32(len(cbuffer.block)))
			continue
		}
		if cbuffer.in_vert {
			sdl.PushGPUVertexUniformData(cmd_buffer, cbuffer.vert_slot, raw_data(cbuffer.block), u32(len(cbuffer.block)))
		}
		if cbuffer.in_frag {
			sdl.PushGPUFragmentUniformData(cmd_buffer, cbuffer.frag_slot, raw_data(cbuffer.block), u32(len(cbuffer.block)))
		}
	}
}

scene_pass_texture :: proc(
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	resources: ^SceneResources,
	pass_index: int,
) -> ^sdl.GPUTexture {
	if pass_index == scene.pipeline.output_pass do return scene_tex
	if pass_index >= 0 && pass_index < len(resources.pass_tex) do return resources.pass_tex[pass_index]
	return nil
}

submit_scene_frame :: proc(
	gfx_state: ^gfx.Gfx,
	gpu: ^sdl.GPUDevice,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	resources: ^SceneResources,
	width, height: i32,
	// Node-graph thumbnails: after the passes, each full-res output is
	// downsampled (linear blit) into its fixed-size preview target.
	// preview_tex[i] mirrors pass_tex[i]; the entry AFTER the last pass
	// mirrors scene_tex (the pipeline's viewport output).
	preview_pipeline: ^sdl.GPUGraphicsPipeline,
	preview_sampler: ^sdl.GPUSampler,
	preview_tex: []^sdl.GPUTexture,
) -> ^sdl.GPUFence {
	cmd_buffer := sdl.AcquireGPUCommandBuffer(gpu)
	if cmd_buffer == nil {
		log.errorf("scene: failed to acquire command buffer: %s", sdl.GetError())
		return nil
	}

	for pass_index in scene.pipeline.order {
		pass := &scene.passes[pass_index]
		out_tex := scene_pass_texture(scene, scene_tex, resources, pass_index)
		if out_tex == nil {
			log.errorf("scene: no output texture for pass %s", pass.name)
			return nil
		}
		scene_set_debug_pass(pass, u32(pass_index))
		sampler_count := len(pass.sampler_textures)
		bindings := make([]sdl.GPUTextureSamplerBinding, max(sampler_count, 1), context.temp_allocator)
		for name, slot in pass.sampler_textures {
			texture := gfx.gfx_texture_get(gfx_state, resources.paper_textures[resources.paper_index]).handle
			if producer := pipeline_plan_source(&scene.pipeline, pass_index, name); producer >= 0 {
				texture = scene_pass_texture(scene, scene_tex, resources, producer)
			} else if path, ok := pipeline_plan_resource(&scene.pipeline, pass_index, name, .TEXTURE); ok {
				if user_tex, cached := user_assets_textures[path]; cached {
					texture = gfx.gfx_texture_get(gfx_state, user_tex).handle
				}
			} else {
				switch name {
				case "skybox_tex":
					if resources.skybox_index >= 0 && resources.skybox_index < len(resources.skybox_textures) {
						texture = gfx.gfx_texture_get(gfx_state, resources.skybox_textures[resources.skybox_index]).handle
					}
				case "input_tex":
					texture = gfx.gfx_texture_get(gfx_state, resources.black_texture).handle
				}
			}
			bindings[slot] = {texture = texture, sampler = resources.sampler}
		}

		switch pass.kind {
		case .COMPUTE:
			tex_binding := sdl.GPUStorageTextureReadWriteBinding {texture = out_tex, cycle = false}
			compute_pass: ^sdl.GPUComputePass
			if pass.debug_compute_buffer && resources.debug_watch_buffer != nil {
				buffer_binding := sdl.GPUStorageBufferReadWriteBinding {buffer = resources.debug_watch_buffer, cycle = false}
				compute_pass = sdl.BeginGPUComputePass(cmd_buffer, &tex_binding, 1, &buffer_binding, 1)
			} else {
				compute_pass = sdl.BeginGPUComputePass(cmd_buffer, &tex_binding, 1, nil, 0)
			}
			sdl.BindGPUComputePipeline(compute_pass, pass.compute)
			if sampler_count > 0 do sdl.BindGPUComputeSamplers(compute_pass, 0, raw_data(bindings), u32(sampler_count))
			push_scene_uniforms(cmd_buffer, pass, true)
			threads_x, threads_y := i32(pass.thread.x), i32(pass.thread.y)
			sdl.DispatchGPUCompute(compute_pass, u32((width + threads_x - 1) / threads_x), u32((height + threads_y - 1) / threads_y), 1)
			sdl.EndGPUComputePass(compute_pass)
		case .GRAPHICS:
			color_target := sdl.GPUColorTargetInfo {
				texture = out_tex, load_op = .CLEAR, clear_color = {0, 0, 0, 1}, store_op = .STORE,
			}
			if pass.uses_model do color_target.clear_color = {0.93, 0.91, 0.86, 1}
			depth_target := sdl.GPUDepthStencilTargetInfo {
				texture = resources.depth_tex, load_op = .CLEAR, clear_depth = 1.0, store_op = .DONT_CARE,
			}
			render_pass := sdl.BeginGPURenderPass(cmd_buffer, &color_target, 1, pass.uses_model ? &depth_target : nil)
			sdl.BindGPUGraphicsPipeline(render_pass, pass.graphics)
			if sampler_count > 0 do sdl.BindGPUFragmentSamplers(render_pass, 0, raw_data(bindings), u32(sampler_count))
			if pass.debug_fragment_buffer && resources.debug_watch_buffer != nil {
				sdl.BindGPUFragmentStorageBuffers(render_pass, pass.debug_fragment_slot, &resources.debug_watch_buffer, 1)
			}
			if pass.uses_model {
				// A user model route replaces the app-selected model;
				// fall back to resources.model when none/cached fail.
				model := resources.model
				if path, ok := pipeline_plan_resource(&scene.pipeline, pass_index, "ModelVertex", .MODEL); ok {
					if user_model, cached := user_assets_models[path]; cached && user_model.vb != nil {
						model = user_model
					}
				}
				vb_binding := sdl.GPUBufferBinding{buffer = model.vb, offset = 0}
				sdl.BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1)
				sdl.BindGPUIndexBuffer(render_pass, {buffer = model.ib, offset = 0}, ._32BIT)
				scene_set_manual(pass, 1)
				push_scene_uniforms(cmd_buffer, pass, false)
				sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
				scene_set_manual(pass, 0)
				push_scene_uniforms(cmd_buffer, pass, false)
				sdl.DrawGPUIndexedPrimitives(render_pass, model.index_count, 1, 0, 0, 0)
			} else {
				sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
			}
			sdl.EndGPURenderPass(render_pass)
		}
	}

	// Node-graph thumbnails: linear-blit every pass's output (and the
	// final viewport image) into its fixed-size preview target. Same
	// command buffer/fence as the passes: the previews are coherent with
	// the frame they mirror at no extra submission cost.
	if len(preview_tex) == len(scene.passes) + 1 {
		for pass_index in scene.pipeline.order {
			source := scene_pass_texture(scene, scene_tex, resources, pass_index)
			if source == nil do continue
			target := preview_tex[pass_index]
			preview_target := sdl.GPUColorTargetInfo {
				texture = target, load_op = .DONT_CARE, store_op = .STORE,
			}
			preview_pass := sdl.BeginGPURenderPass(cmd_buffer, &preview_target, 1, nil)
			sdl.BindGPUGraphicsPipeline(preview_pass, preview_pipeline)
			sdl.BindGPUFragmentSamplers(
				preview_pass,
				0,
				&(sdl.GPUTextureSamplerBinding{texture = source, sampler = preview_sampler}),
				1,
			)
			sdl.DrawGPUPrimitives(preview_pass, 3, 1, 0, 0)
			sdl.EndGPURenderPass(preview_pass)
		}
		final_target := preview_tex[len(preview_tex) - 1]
		preview_target := sdl.GPUColorTargetInfo {
			texture = final_target, load_op = .DONT_CARE, store_op = .STORE,
		}
		preview_pass := sdl.BeginGPURenderPass(cmd_buffer, &preview_target, 1, nil)
		sdl.BindGPUGraphicsPipeline(preview_pass, preview_pipeline)
		sdl.BindGPUFragmentSamplers(
			preview_pass,
			0,
			&(sdl.GPUTextureSamplerBinding{texture = scene_tex, sampler = preview_sampler}),
			1,
		)
		sdl.DrawGPUPrimitives(preview_pass, 3, 1, 0, 0)
		sdl.EndGPURenderPass(preview_pass)
	}
	return sdl.SubmitGPUCommandBufferAndAcquireFence(cmd_buffer)
}


scene_write_uniforms :: proc(
	scene: ^RuntimeScene,
	resources: [2]f32,
	time_s: f32,
	color: bool,
	mouse_pos: [2]f32,
	mouse_click: bool,
	camera: ^CameraUniforms,
	debug_enabled: bool,
	debug_pixel_top: [2]i32,
	debug_frame: u32,
) {
	for &pass in scene.passes {
		for cbuffer in pass.cbuffers {
			for field in cbuffer.fields {
				switch field.name {
				case "iResolution":
					poke_f32(cbuffer.block, field.offset, resources.x)
					poke_f32(cbuffer.block, field.offset + 4, resources.y)
					poke_f32(cbuffer.block, field.offset + 8, 1)
				case "iTime":
					poke_f32(cbuffer.block, field.offset, time_s)
				case "iFbm":
					poke_f32(cbuffer.block, field.offset, 6)
					poke_f32(cbuffer.block, field.offset + 4, 2.03)
					poke_f32(cbuffer.block, field.offset + 8, 0.5)
				case "iColorMode":
					poke_f32(cbuffer.block, field.offset, color ? 1 : 0)
				case "iMousePos":
					poke_f32(cbuffer.block, field.offset, mouse_pos.x)
					poke_f32(cbuffer.block, field.offset + 4, mouse_pos.y)
				case "iMouseClick":
					poke_f32(cbuffer.block, field.offset, mouse_click ? 1 : 0)
				case "iViewProjection":
					for i in 0 ..< 16 do poke_f32(cbuffer.block, field.offset + i*4, camera.view_projection[i])
				case "iCameraPosition":
					for i in 0 ..< 3 do poke_f32(cbuffer.block, field.offset + i*4, camera.position[i])
				case "iCameraRight":
					for i in 0 ..< 3 do poke_f32(cbuffer.block, field.offset + i*4, camera.right[i])
				case "iCameraUp":
					for i in 0 ..< 3 do poke_f32(cbuffer.block, field.offset + i*4, camera.up[i])
				case "iCameraForward":
					for i in 0 ..< 3 do poke_f32(cbuffer.block, field.offset + i*4, camera.forward[i])
				case "iManual":
					poke_f32(cbuffer.block, field.offset, 1)
				case "iDebugPixel":
					poke_u32(cbuffer.block, field.offset, u32(max(debug_pixel_top[0], 0)))
					debug_y := debug_pixel_top[1]
					if pass.kind == .GRAPHICS do debug_y = i32(resources.y) - 1 - debug_y
					poke_u32(cbuffer.block, field.offset + 4, u32(max(debug_y, 0)))
				case "iDebugEnabled":
					poke_u32(cbuffer.block, field.offset, debug_enabled ? 1 : 0)
				case "iDebugFrame":
					poke_u32(cbuffer.block, field.offset, debug_frame)
				}
			}
		}
	}
	for &widget in scene.widgets {
		for &pass in scene.passes {
			for cbuffer in pass.cbuffers {
				for field in cbuffer.fields {
					if field.name != widget.label do continue
					switch widget.kind {
					case .SLIDER: poke_f32(cbuffer.block, field.offset, widget.value[0])
					case .TOGGLE: poke_f32(cbuffer.block, field.offset, widget.on ? 1 : 0)
					case .COLOR:
						poke_f32(cbuffer.block, field.offset, widget.value[0])
						poke_f32(cbuffer.block, field.offset + 4, widget.value[1])
						poke_f32(cbuffer.block, field.offset + 8, widget.value[2])
					}
				}
			}
		}
	}
}
