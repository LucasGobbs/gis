package render_graph

import "core:fmt"
import "core:strings"

// graph.json is both the node-editor document and the runtime pipeline
// manifest. Node positions are presentation state; links are semantic.
// Shader reflection remains authoritative for pass interfaces and pin types.

GRAPH_SCHEMA_VERSION :: 1

// Upper bound the wave-2 adapter passes to plan_path; the caller decides the
// real value (DEBUG_WATCH_MAX_PASSES in the main package).
PLAN_PATH_MAX_PASSES :: 8

Node_Json :: struct {
	key:  string,
	kind: string,
	x:    f32,
	y:    f32,
	// Set only on user-authored resource nodes ("uimg:"/"uobj:" keys).
	file: string,
	// Optional resource-node fields (absent in JSON = zero value; the
	// loaders apply the defaults). source: "file" (default) | "target";
	// title overrides the derived title; filter "point"|"linear";
	// address "clamp"|"repeat"|"mirror"; width/height only for targets;
	// value holds the persisted widget value for "ui:" nodes.
	source:  string,
	title:   string,
	filter:  string,
	address: string,
	width:   int,
	height:  int,
	value:   f32,
}

Link_Json :: struct {
	from: string,
	to:   string,
}

Graph_Json :: struct {
	version: int,
	scene:   string,
	nodes:   []Node_Json,
	links:   []Link_Json,
}

// Reflection snapshot of one pass, owned by the caller (adapter). The plan
// borrows key/name/input_textures; it never deletes them.
Pass_Descriptor :: struct {
	key:            string,
	name:           string,
	input_textures: [dynamic]string,
	output_pin:     string,
	// True when the pass's vertex entry takes a stage_in ModelVertex
	// (model passes): a MODEL resource route may target it.
	uses_model:     bool,
}

Route :: struct {
	producer:   int,
	consumer:   int,
	input_name: string, // owned
}
Resource_Kind :: enum { TEXTURE, MODEL, SAMPLER }

Resource_Source :: enum {
	FILE,
	TARGET_WRITE,
	TARGET_READ,
}

// One app-fed asset routed into a pass input (from a user resource node
// link, "uimg:assets/x.jpg:texture" -> "pass:b_tex"). input_name is the
// texture binding name, or "ModelVertex" for a model route. path is
// owned. source marks a ping-pong render-target route: TARGET_READ is
// the delayed edge (reads last frame's result), TARGET_WRITE the write
// side (pass -> image node's `write` pin).
Resource_Route :: struct {
	consumer:   int,
	input_name: string, // owned
	kind:       Resource_Kind,
	source:     Resource_Source,
	path:       string, // owned
}

Plan :: struct {
	order:       [dynamic]int,
	routes:      [dynamic]Route,
	output_pass: int,
	resources:   [dynamic]Resource_Route,
}

graph_path :: proc(scene: string, scene_root: string) -> string {
	return fmt.tprintf("%s/%s/graph.json", scene_root, scene)
}
plan_destroy :: proc(plan: ^Plan) {
	for &route in plan.routes do delete(route.input_name)
	for &resource in plan.resources {
		delete(resource.input_name)
		delete(resource.path)
	}
	delete(plan.routes)
	delete(plan.resources)
	delete(plan.order)
	plan^ = {}
}

endpoint :: proc(node_key, pin_name: string) -> string {
	return fmt.tprintf("%s:%s", node_key, pin_name)
}

find_pass_endpoint :: proc(
	passes: []Pass_Descriptor,
	endpoint: string,
) -> (
	pass_index: int,
	pin_name: string,
	found: bool,
) {
	for &pass, i in passes {
		prefix := fmt.tprintf("%s:", pass.key)
		if strings.has_prefix(endpoint, prefix) {
			return i, endpoint[len(prefix):], true
		}
	}
	return -1, "", false
}

pass_has_input :: proc(pass: ^Pass_Descriptor, name: string) -> bool {
	for input_name in pass.input_textures {
		if input_name == name do return true
	}
	return false
}

default_input :: proc(pass: ^Pass_Descriptor) -> string {
	for name in pass.input_textures {
		if name == "input_tex" do return name
	}
	for name in pass.input_textures {
		if name != "" do return name
	}
	return ""
}

plan_default :: proc(passes: []Pass_Descriptor) -> Plan {
	plan: Plan
	plan.output_pass = len(passes) - 1
	for i in 0 ..< len(passes) do append(&plan.order, i)
	for i := 1; i < len(passes); i += 1 {
		input_name := default_input(&passes[i])
		if input_name == "" do continue
		append(
			&plan.routes,
			Route{producer = i - 1, consumer = i, input_name = strings.clone(input_name)},
		)
	}
	return plan
}

plan_build :: proc(
	passes: []Pass_Descriptor,
	doc: ^Graph_Json,
) -> (
	plan: Plan,
	error_message: string,
	ok: bool,
) {
	n := len(passes)
	if n == 0 do return {}, "pipeline has no reflected passes", false

	indegree := make([]int, n, context.temp_allocator)
	authoritative := doc.version == GRAPH_SCHEMA_VERSION
	outdegree := make([]int, n, context.temp_allocator)
	adj := make([][dynamic]int, n, context.temp_allocator)
	incoming := make(map[string]bool, n * 2, context.temp_allocator)
	output_seen := false
	plan.output_pass = -1
	pass_edges := 0

	for link in doc.links {
		producer, output_pin, producer_ok := find_pass_endpoint(passes, link.from)
		if !producer_ok {
			// Not a pass output: either a user resource node's output
			// ("uimg:<path>:texture" / "uobj:<path>:ModelVertex"), a
			// legacy fixed-resource node ("image:...", "object3d:...",
			// runtime falls back to defaults), or a params endpoint.
			// Only user resources route into the plan.
			kind := Resource_Kind.TEXTURE
			source := Resource_Source.FILE
			prefix_len := 0
			suffix := ":texture"
			if strings.has_prefix(link.from, "uimg:target:") && strings.has_suffix(link.from, ":texture") {
				// Ping-pong read side: the reader consumes the texture
				// completed in the PREVIOUS frame, so this edge is
				// delayed (excluded from cycle/ordering constraints).
				kind = .TEXTURE
				source = .TARGET_READ
				prefix_len = len("uimg:")
			} else if strings.has_prefix(link.from, "uimg:") && strings.has_suffix(link.from, ":sampler") {
				// The image node's explicit sampler routed into a pass's
				// SamplerState binding by name.
				kind = .SAMPLER
				suffix = ":sampler"
				prefix_len = len("uimg:")
			} else if strings.has_prefix(link.from, "uimg:") && strings.has_suffix(link.from, ":texture") {
				kind = .TEXTURE
				prefix_len = len("uimg:")
			} else if strings.has_prefix(link.from, "uobj:") && strings.has_suffix(link.from, ":ModelVertex") {
				kind = .MODEL
				suffix = ":ModelVertex"
				prefix_len = len("uobj:")
			} else {
				continue
			}
			// The path is everything between the prefix and the LAST
			// colon (paths never contain ':', but the pin name does).
			// Target nodes keep their identity in the key ("target:<id>").
			body := link.from[prefix_len:len(link.from) - len(suffix)]
			path := body
			if colon := strings.last_index(body, ":"); colon >= 0 && source != .TARGET_READ do path = body[:colon]
			if path == "" do continue

			if link.to == "show2d:frame" {
				plan_destroy(&plan)
				return {}, "viewport takes a pass output", false
			}
			consumer, input_name, consumer_ok := find_pass_endpoint(passes, link.to)
			if !consumer_ok do continue
			if kind == .SAMPLER {
				// The route targets a named SamplerState binding; the
				// reflection only records sampled textures, so existence
				// can't be checked here — the bind site matches by name.
			} else if kind == .TEXTURE {
				if !pass_has_input(&passes[consumer], input_name) {
					plan_destroy(&plan)
					return {},
						fmt.tprintf(
							"%s.%s has no matching input",
							passes[consumer].name,
							input_name,
						),
						false
				}
			} else if !passes[consumer].uses_model || input_name != "ModelVertex" {
				plan_destroy(&plan)
				return {},
					fmt.tprintf(
						"%s.%s has no matching input",
						passes[consumer].name,
						input_name,
					),
					false
			}
			input_key := fmt.tprintf("%d:%s", consumer, input_name)
			if incoming[input_key] {
				plan_destroy(&plan)
				return {},
					fmt.tprintf(
						"input %s.%s has more than one producer",
						passes[consumer].name,
						input_name,
					),
					false
			}
			incoming[input_key] = true
			append(
				&plan.resources,
				Resource_Route {
					consumer   = consumer,
					input_name = strings.clone(input_name),
					kind       = kind,
					source     = source,
					path       = strings.clone(path),
				},
			)
			continue
		}

		// Pass output feeding a target-mode image node's `write` pin
		// ("uimg:target:<id>:write"): the write side of the ping-pong.
		// It participates in ordering (the pass must run) but binds no
		// sampled input, so it contributes no route edge.
		if strings.has_prefix(link.to, "uimg:target:") && strings.has_suffix(link.to, ":write") {
			if link.from == "show2d:frame" {
				plan_destroy(&plan)
				return {}, "viewport frame cannot feed a target write", false
			}
			continue
		}

		if link.to == "show2d:frame" {
			if output_seen {
				plan_destroy(&plan)
				return {}, "pipeline has more than one viewport output", false
			}
			if output_pin == "" {
				plan_destroy(&plan)
				return {}, fmt.tprintf("invalid output endpoint '%s'", link.from), false
			}
			plan.output_pass = producer
			output_seen = true
			continue
		}

		consumer, input_name, consumer_ok := find_pass_endpoint(passes, link.to)
		if !consumer_ok do continue
		if producer == consumer {
			plan_destroy(&plan)
			return {}, fmt.tprintf("self-cycle at %s", passes[producer].name), false
		}
		if !pass_has_input(&passes[consumer], input_name) {
			plan_destroy(&plan)
			return {},
				fmt.tprintf(
					"%s has no sampled texture input '%s'",
					passes[consumer].name,
					input_name,
				),
				false
		}
		input_key := fmt.tprintf("%d:%s", consumer, input_name)
		if incoming[input_key] {
			plan_destroy(&plan)
			return {},
				fmt.tprintf(
					"input %s.%s has more than one producer",
					passes[consumer].name,
					input_name,
				),
				false
		}
		incoming[input_key] = true
		append(
			&plan.routes,
			Route {
				producer = producer,
				consumer = consumer,
				input_name = strings.clone(input_name),
			},
		)
		append(&adj[producer], consumer)
		indegree[consumer] += 1
		outdegree[producer] += 1
		pass_edges += 1
	}

	// Legacy documents without semantic links migrate to declaration order.
	if !authoritative && !output_seen && pass_edges == 0 {
		plan_destroy(&plan)
		return plan_default(passes), "", true
	}
	if plan.output_pass < 0 {
		plan_destroy(&plan)
		return {}, "pipeline has no viewport output", false
	}

	// Stable Kahn sort: original reflection order breaks ties.
	removed := make([]bool, n, context.temp_allocator)
	for len(plan.order) < n {
		picked := -1
		for i in 0 ..< n {
			if !removed[i] && indegree[i] == 0 {
				picked = i
				break
			}
		}
		if picked < 0 {
			plan_destroy(&plan)
			return {}, "pipeline graph contains a cycle", false
		}
		removed[picked] = true
		append(&plan.order, picked)
		for consumer in adj[picked] do indegree[consumer] -= 1
	}
	return plan, "", true
}

plan_path :: proc(plan: ^Plan, pass_count: int, max_passes: int) -> []bool {
	path := make([]bool, max_passes, context.temp_allocator)
	if plan.output_pass < 0 || plan.output_pass >= min(pass_count, max_passes) do return path
	path[plan.output_pass] = true
	changed := true
	for changed {
		changed = false
		for route in plan.routes {
			if route.consumer >= max_passes || route.producer >= max_passes do continue
			if path[route.consumer] && !path[route.producer] {
				path[route.producer] = true
				changed = true
			}
		}
	}
	return path
}

plan_equal :: proc(a, b: ^Plan) -> bool {
	if a.output_pass != b.output_pass || len(a.order) != len(b.order) || len(a.routes) != len(b.routes) ||
	   len(a.resources) != len(b.resources) {
		return false
	}
	for value, i in a.order do if b.order[i] != value do return false
	for route in a.routes {
		found := false
		for other in b.routes {
			if route.producer == other.producer &&
			   route.consumer == other.consumer &&
			   route.input_name == other.input_name {
				found = true
				break
			}
		}
		if !found do return false
	}
	// Resource routes compare ordered: both sides come from the same
	// doc.links order, so pairwise is exact.
	for &resource, i in a.resources {
		other := &b.resources[i]
		if resource.consumer != other.consumer ||
		   resource.input_name != other.input_name ||
		   resource.kind != other.kind ||
		   resource.path != other.path {
			return false
		}
	}
	return true
}
