package render_graph

import "core:fmt"
import "core:testing"



// One pass descriptor with a stable key; input_textures owned per call.
make_pass :: proc(key, name: string, inputs: ..string, uses_model := false) -> Pass_Descriptor {
	pass := Pass_Descriptor{key = key, name = name, output_pin = "frame", uses_model = uses_model}
	for input in inputs do append(&pass.input_textures, input)
	return pass
}

fixture :: proc() -> (passes: [dynamic]Pass_Descriptor, doc: Graph_Json) {
	passes = make([dynamic]Pass_Descriptor, 0, 2)
	append(&passes, make_pass("pass_1", "pass_1", "input_tex"))
	append(&passes, make_pass("pass_2", "pass_2", "input_tex", "b_tex"))

	links := make([dynamic]Link_Json, 0, 4)
	append(&links, Link_Json{from = "pass_1:frame", to = "show2d:frame"})
	append(&links, Link_Json{from = "uimg:assets/parchment.jpg:texture", to = "pass_2:b_tex"})
	doc = Graph_Json{
		version = GRAPH_SCHEMA_VERSION,
		scene   = "test",
		links   = links[:],
	}
	return
}

@(test)
plan_build_routes_user_texture :: proc(t: ^testing.T) {
	passes, doc := fixture()
	// The descriptors borrow strings; the doc links own nothing here.
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
		delete(doc.links)
	}

	plan, error_message, ok := plan_build(passes[:], &doc)
	defer plan_destroy(&plan)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	testing.expect_value(t, plan.output_pass, 0)
	testing.expect_value(t, len(plan.resources), 1)
	testing.expect_value(t, len(plan.routes), 0)
	if len(plan.resources) == 1 {
		resource := plan.resources[0]
		testing.expect_value(t, resource.consumer, 1)
		testing.expect_value(t, resource.input_name, "b_tex")
		testing.expect_value(t, int(resource.kind), int(Resource_Kind.TEXTURE))
		testing.expect_value(t, resource.path, "assets/parchment.jpg")
	}
}

add_links :: proc(doc: ^Graph_Json, new_links: ..Link_Json) {
	links := make([dynamic]Link_Json, len(new_links))
	for link, i in new_links do links[i] = link
	doc.links = links[:]
}

@(test)
plan_build_rejects_resource_into_viewport :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
	}
	add_links(&doc, Link_Json{from = "uimg:assets/parchment.jpg:texture", to = "show2d:frame"})

	_, error_message, ok := plan_build(passes[:], &doc)
	testing.expect(t, !ok, "resource -> viewport must be rejected")
	testing.expect_value(t, error_message, "viewport takes a pass output")
}

@(test)
plan_build_rejects_double_producer :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
	}
	// The fixture already has uimg -> pass_2:b_tex and pass_1 -> show2d;
	// adding a pass producer for the same input must be rejected.
	links := make([dynamic]Link_Json, len(doc.links) + 1)
	copy(links[:], doc.links[:])
	links[len(doc.links)] = Link_Json{from = "pass_1:frame", to = "pass_2:b_tex"}
	doc.links = links[:]

	_, error_message, ok := plan_build(passes[:], &doc)
	testing.expect(t, !ok, "two producers on one input must be rejected")
	testing.expect_value(t, error_message, "input pass_2.b_tex has more than one producer")
}

@(test)
plan_build_rejects_model_route_on_texture_pass :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
	}
	add_links(&doc, Link_Json{from = "uobj:assets/models/sphere.glb:ModelVertex", to = "pass_1:input_tex"})

	_, error_message, ok := plan_build(passes[:], &doc)
	testing.expect(t, !ok, "model route onto a non-model pass must be rejected")
	testing.expect_value(t, error_message, "pass_1.input_tex has no matching input")
}

@(test)
plan_build_routes_user_model_to_model_pass :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
	}
	// pass_1 becomes a model pass (uses_model) and takes the user mesh;
	// pass_2 chains pass_1's frame.
	passes[0].uses_model = true
	add_links(
		&doc,
		Link_Json{from = "uobj:assets/models/sphere.glb:ModelVertex", to = "pass_1:ModelVertex"},
		Link_Json{from = "pass_1:frame", to = "pass_2:input_tex"},
		Link_Json{from = "pass_2:frame", to = "show2d:frame"},
	)

	plan, error_message, ok := plan_build(passes[:], &doc)
	defer plan_destroy(&plan)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	testing.expect_value(t, len(plan.resources), 1)
	if len(plan.resources) == 1 {
		resource := plan.resources[0]
		testing.expect_value(t, int(resource.kind), int(Resource_Kind.MODEL))
		testing.expect_value(t, resource.consumer, 0)
		testing.expect_value(t, resource.path, "assets/models/sphere.glb")
	}
	testing.expect_value(t, len(plan.routes), 1)
}

@(test)
plan_build_accepts_target_write_and_delayed_read :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
		delete(doc.links)
	}
	// Feedback loop: pass_1 writes the target, the target's delayed
	// texture read feeds pass_2. Neither edge may trip the cycle check.
	add_links(
		&doc,
		Link_Json{from = "pass_1:frame", to = "uimg:target:1:write"},
		Link_Json{from = "uimg:target:1:texture", to = "pass_2:input_tex"},
		Link_Json{from = "pass_2:frame", to = "show2d:frame"},
	)

	plan, error_message, ok := plan_build(passes[:], &doc)
	defer plan_destroy(&plan)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	testing.expect_value(t, len(plan.resources), 1)
	if len(plan.resources) == 1 {
		resource := plan.resources[0]
		testing.expect_value(t, int(resource.source), int(Resource_Source.TARGET_READ))
		testing.expect_value(t, resource.path, "target:1")
	}
}

@(test)
plan_build_accepts_delayed_read_without_cycle_error :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
		delete(doc.links)
	}
	// The harshest topology: pass_2 feeds the target write, the target's
	// delayed read feeds pass_2 itself (true ping-pong feedback). A
	// non-delayed edge here would be rejected as a cycle.
	add_links(
		&doc,
		Link_Json{from = "pass_1:frame", to = "pass_2:input_tex"},
		Link_Json{from = "pass_2:frame", to = "uimg:target:3:write"},
		Link_Json{from = "uimg:target:3:texture", to = "pass_2:b_tex"},
		Link_Json{from = "pass_1:frame", to = "show2d:frame"},
	)

	plan, error_message, ok := plan_build(passes[:], &doc)
	defer plan_destroy(&plan)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	testing.expect_value(t, len(plan.routes), 1)
	testing.expect_value(t, len(plan.resources), 1)
}

@(test)
plan_build_rejects_real_pass_cycle :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
		delete(doc.links)
	}
	// pass_1 -> pass_2 -> pass_1 (no delayed edge involved): a real cycle.
	add_links(
		&doc,
		Link_Json{from = "pass_1:frame", to = "pass_2:input_tex"},
		Link_Json{from = "pass_2:frame", to = "pass_1:input_tex"},
		Link_Json{from = "pass_1:frame", to = "show2d:frame"},
	)

	_, error_message, ok := plan_build(passes[:], &doc)
	testing.expect(t, !ok, "pass-to-pass cycle must be rejected")
	testing.expect_value(t, error_message, "pipeline graph contains a cycle")
}

@(test)
plan_build_loads_legacy_doc_without_new_fields :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
		delete(doc.links)
	}
	// Legacy row: legacy fixed "image" node key, no resource fields at
	// all. plan_build must not fail; the runtime falls back to defaults.
	add_links(
		&doc,
		Link_Json{from = "image:texture", to = "pass_2:b_tex"},
		Link_Json{from = "pass_1:frame", to = "show2d:frame"},
	)

	plan, error_message, ok := plan_build(passes[:], &doc)
	defer plan_destroy(&plan)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	// Legacy image node is not a user resource: no routes created.
	testing.expect_value(t, len(plan.resources), 0)
}

@(test)
plan_build_drops_link_to_missing_consumer :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
		delete(doc.links)
	}
	// A link whose consumer endpoint no longer exists (node deleted /
	// mode switched) is dropped; the rest of the doc still loads.
	add_links(
		&doc,
		Link_Json{from = "uimg:assets/parchment.jpg:texture", to = "pass_gone:b_tex"},
		Link_Json{from = "pass_1:frame", to = "show2d:frame"},
	)

	plan, error_message, ok := plan_build(passes[:], &doc)
	defer plan_destroy(&plan)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	testing.expect_value(t, len(plan.resources), 0)
}

@(test)
plan_equal_round_trip_after_save_reload :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
	}

	first, error_message, ok := plan_build(passes[:], &doc)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	defer plan_destroy(&first)

	// Simulate save+reload: re-run plan_build on the same doc (the JSON
	// round trip preserves the fields the plan reads) and compare.
	second, second_error, ok2 := plan_build(passes[:], &doc)
	defer plan_destroy(&second)
	testing.expect(t, ok2, fmt.tprintf("second plan rejected: %s", second_error))
	testing.expect(t, plan_equal(&first, &second), "save/reload round trip must produce an equal plan")
}

@(test)
plan_build_routes_user_sampler_to_pass :: proc(t: ^testing.T) {
	passes, doc := fixture()
	defer {
		for &pass in passes do delete(pass.input_textures)
		delete(passes)
		delete(doc.links)
	}
	// The image node's explicit sampler output wired into a pass's
	// SamplerState binding by name.
	add_links(
		&doc,
		Link_Json{from = "uimg:assets/parchment.jpg:sampler", to = "pass_2:input_sampler"},
		Link_Json{from = "pass_1:frame", to = "show2d:frame"},
	)

	plan, error_message, ok := plan_build(passes[:], &doc)
	defer plan_destroy(&plan)
	testing.expect(t, ok, fmt.tprintf("plan rejected: %s", error_message))
	testing.expect_value(t, len(plan.resources), 1)
	if len(plan.resources) == 1 {
		resource := plan.resources[0]
		testing.expect_value(t, int(resource.kind), int(Resource_Kind.SAMPLER))
		testing.expect_value(t, resource.consumer, 1)
		testing.expect_value(t, resource.input_name, "input_sampler")
		testing.expect_value(t, resource.path, "assets/parchment.jpg")
	}
}
