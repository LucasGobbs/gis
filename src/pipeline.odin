package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import gfx "./gfx"
import render_graph "./render_graph"

// User asset caches for graph resource routes: images and models loaded
// on demand (pipeline_scene_reload), keyed by asset-relative path.
// main sets the gfx state at startup (user_assets_set_gfx); small by
// design (loaded assets are never freed on swap).
user_assets_textures: map[string]gfx.Texture_Handle
user_assets_models:   map[string]^Model
user_assets_gfx:      ^gfx.Gfx

user_assets_set_gfx :: proc(gfx_state: ^gfx.Gfx) {
	user_assets_gfx = gfx_state
}

PIPELINE_SCHEMA_VERSION :: render_graph.GRAPH_SCHEMA_VERSION

// Thin adapter over src/render_graph: the plan/route JSON types and every
// graph algorithm (validation, output election, stable sort) live there;
// this file only converts scene passes into descriptors and keeps the
// legacy call-site signatures (main/scene_runtime/imgui_nodes untouched).

PipelinePlan :: render_graph.Plan
PipelineRoute :: render_graph.Route
SgGraphJson :: render_graph.Graph_Json
SgGraphNodeJson :: render_graph.Node_Json
SgGraphLinkJson :: render_graph.Link_Json
DEBUG_WATCH_MAX_PASSES :: render_graph.PLAN_PATH_MAX_PASSES

// Output pin name of a pass in graph.json endpoints: compute passes write
// out_tex (RWTexture2D), graphics passes produce their frame. The pass
// reflection does not record the output name, only its kind.
scene_pass_output_pin :: proc(pass: ^ScenePass) -> string {
	return "out_tex" if pass.kind == .COMPUTE else "frame"
}

// Reflection snapshot borrows scene strings; consumed by the plan calls
// below within the same frame.
scene_pass_descriptors :: proc(scene: ^RuntimeScene) -> [dynamic]render_graph.Pass_Descriptor {
	descriptors := make([dynamic]render_graph.Pass_Descriptor, 0, len(scene.passes), context.temp_allocator)
	for &pass in scene.passes {
		append(
			&descriptors,
			render_graph.Pass_Descriptor {
				key            = pass.graph_key,
				name           = pass.name,
				input_textures = pass.sampler_textures,
				output_pin     = scene_pass_output_pin(&pass),
				uses_model     = pass.uses_model,
			},
		)
	}
	return descriptors
}

pipeline_graph_path :: proc(scene: string) -> string {
	return render_graph.graph_path(scene, scene_root_dir(scene))
}

pipeline_plan_destroy :: proc(plan: ^PipelinePlan) {
	render_graph.plan_destroy(plan)
}

pipeline_endpoint :: proc(node_key, pin_name: string) -> string {
	return render_graph.endpoint(node_key, pin_name)
}

pipeline_find_pass_endpoint :: proc(
	scene: ^RuntimeScene,
	endpoint: string,
) -> (pass_index: int, pin_name: string, found: bool) {
	descriptors := scene_pass_descriptors(scene)
	defer delete(descriptors)
	return render_graph.find_pass_endpoint(descriptors[:], endpoint)
}

pipeline_plan_default :: proc(scene: ^RuntimeScene) -> PipelinePlan {
	descriptors := scene_pass_descriptors(scene)
	defer delete(descriptors)
	return render_graph.plan_default(descriptors[:])
}

pipeline_plan_build :: proc(
	scene: ^RuntimeScene,
	graph_json: ^SgGraphJson,
) -> (plan: PipelinePlan, error_message: string, succeeded: bool) {
	if graph_json.scene != "" && graph_json.scene != scene.title {
		return {}, fmt.tprintf("graph scene '%s' does not match '%s'", graph_json.scene, scene.title), false
	}
	if graph_json.version != 0 && graph_json.version != PIPELINE_SCHEMA_VERSION {
		return {}, fmt.tprintf("unsupported graph schema version %d", graph_json.version), false
	}
	descriptors := scene_pass_descriptors(scene)
	defer delete(descriptors)
	return render_graph.plan_build(descriptors[:], graph_json)
}

pipeline_plan_load :: proc(scene: ^RuntimeScene) -> (PipelinePlan, string, bool) {
	path := pipeline_graph_path(scene.title)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		return pipeline_plan_default(scene), "", true
	}
	graph_json: SgGraphJson
	if parse_error := json.unmarshal(data, &graph_json, allocator = context.temp_allocator); parse_error != nil {
		return {}, fmt.tprintf("could not parse %s", path), false
	}
	return pipeline_plan_build(scene, &graph_json)
}

pipeline_plan_source :: proc(plan: ^PipelinePlan, consumer: int, input_name: string) -> int {
	for route in plan.routes {
		if route.consumer == consumer && route.input_name == input_name do return route.producer
	}
	return -1
}

// Looks up the resource route feeding a pass input: the asset path and
// kind (TEXTURE = user image, MODEL = user model). ok=false when no
// resource route targets that input (a pass producer feeds it, or it
// falls back to the app default).
pipeline_plan_resource :: proc(
	plan: ^PipelinePlan,
	consumer: int,
	input_name: string,
	kind: render_graph.Resource_Kind,
) -> (path: string, ok: bool) {
	for resource in plan.resources {
		if resource.consumer == consumer && resource.input_name == input_name && resource.kind == kind {
			return resource.path, true
		}
	}
	return "", false
}

pipeline_plan_path :: proc(plan: ^PipelinePlan, pass_count: int) -> [DEBUG_WATCH_MAX_PASSES]bool {
	path: [DEBUG_WATCH_MAX_PASSES]bool
	temp_path := render_graph.plan_path(plan, pass_count, DEBUG_WATCH_MAX_PASSES)
	copy(path[:], temp_path)
	return path
}

pipeline_plan_equal :: proc(a, b: ^PipelinePlan) -> bool {
	return render_graph.plan_equal(a, b)
}

pipeline_scene_init :: proc(scene: ^RuntimeScene) -> bool {
	candidate, _, succeeded := pipeline_plan_load(scene)
	if !succeeded do return false
	scene.pipeline = candidate
	path := pipeline_graph_path(scene.title)
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err == nil {
		scene.pipeline_mtime = info.modification_time
	}
	return true
}

// Loads the app-fed assets a new plan's resource routes reference
// (thread main, between frames). Any failed load keeps the old plan and
// records one error; the plan with loaded assets becomes the scene's.
pipeline_scene_reload :: proc(scene: ^RuntimeScene, gfx_state: ^gfx.Gfx) {
	for &resource in scene.pipeline.resources {
		if _, ok := user_assets_textures[resource.path]; ok do continue
		if _, ok := user_assets_models[resource.path]; ok do continue
		if resource.kind == .TEXTURE {
			texture, loaded := load_texture(gfx_state, resource.path)
			if !loaded {
				delete(scene.pipeline_error)
				scene.pipeline_error = strings.clone(fmt.tprintf("asset not found: %s", resource.path))
				notify(.ERROR, "pipeline: %s", scene.pipeline_error)
				return
			}
			user_assets_textures[resource.path] = texture
			log.infof("pipeline: loaded user texture %s", resource.path)
		} else {
			model, loaded := model_load_gltf(gfx_state, resource.path)
			if !loaded {
				delete(scene.pipeline_error)
				scene.pipeline_error = strings.clone(fmt.tprintf("asset not found: %s", resource.path))
				notify(.ERROR, "pipeline: %s", scene.pipeline_error)
				return
			}
			user_assets_models[resource.path] = new_clone(model)
			log.infof("pipeline: loaded user model %s", resource.path)
		}
	}
}

// JSON-only edits do not require recompiling shaders. Invalid candidates keep
// the last known-good plan and surface one error per file modification.
pipeline_scene_refresh :: proc(scene: ^RuntimeScene) {
	path := pipeline_graph_path(scene.title)
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil do return
	if time.diff(info.modification_time, scene.pipeline_mtime) == 0 do return
	scene.pipeline_mtime = info.modification_time

	candidate, error_message, succeeded := pipeline_plan_load(scene)
	if !succeeded {
		delete(scene.pipeline_error)
		scene.pipeline_error = strings.clone(error_message)
		log.warnf("pipeline rejected for %s: %s; keeping last valid plan", scene.title, error_message)
		notify(.ERROR, "pipeline: %s", error_message)
		return
	}
	if pipeline_plan_equal(&scene.pipeline, &candidate) {
		pipeline_plan_destroy(&candidate)
		delete(scene.pipeline_error)
		scene.pipeline_error = ""
		return
	}
	pipeline_plan_destroy(&scene.pipeline)
	scene.pipeline = candidate
	delete(scene.pipeline_error)
	scene.pipeline_error = ""
	pipeline_scene_reload(scene, user_assets_gfx)
	notify(.INFO, "pipeline updated: %s", scene.title)
	log.infof("pipeline updated for %s: %d passes, %d routes, %d resources", scene.title, len(scene.pipeline.order), len(scene.pipeline.routes), len(scene.pipeline.resources))
}
