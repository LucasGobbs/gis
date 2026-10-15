package main

// Funnel tests (plan L1): drive the disk and catalog side of the funnel
// through the real procs. Editor-dependent paths (ied_save_all,
// ied_rescan) need a live ImGui editor and are covered by the runtime
// flag run, not here. Run with `odin test src` from the repo root: the
// user scene tree (gis_scenes/) is relative to it.
//
// Isolation: the test runner executes tests on several threads, and
// scene_roots plus gis_scenes/ are process-global. Every test owns its
// own zz_test_<tag>_* names so no two tests ever touch the same
// directory or catalog key.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Removes the given scenes from disk and from the catalog registry.
funnel_cleanup :: proc(names: ..string) {
	for name in names {
		os.remove_all(fmt.tprintf("%s/%s", USER_SCENES_DIR, name))
		if _, found := scene_roots[name]; found do delete_key(&scene_roots, name)
	}
}

@(test)
funnel_rename_scene_disk_moves_dir_and_rewrites_graph :: proc(t: ^testing.T) {
	old, new := "zz_test_rn_a", "zz_test_rn_b"
	defer funnel_cleanup(old, new)

	title, ok := scene_create_named(.COMPUTE, old)
	testing.expect(t, ok, "create source scene")
	testing.expect_value(t, title, old)

	graph := fmt.tprintf(`{"nodes":["gfx:gis_scenes/%s/%s"]}`, old, old)
	graph_path := fmt.tprintf("%s/%s/graph.json", USER_SCENES_DIR, old)
	testing.expect(t, os.write_entire_file(graph_path, transmute([]u8)graph) == nil, "write graph.json")

	testing.expect(t, scene_rename_disk(old, new), "disk rename succeeds")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", USER_SCENES_DIR, old)), "old dir gone")
	testing.expect(t, os.exists(fmt.tprintf("%s/%s/%s.slang", USER_SCENES_DIR, new, new)), "entry renamed")

	data, read_err := os.read_entire_file_from_path(fmt.tprintf("%s/%s/graph.json", USER_SCENES_DIR, new), context.temp_allocator)
	testing.expect(t, read_err == nil, "read graph.json")
	text := string(data)
	testing.expectf(t, strings.contains(text, fmt.tprintf("gis_scenes/%s/%s\"", new, new)), "graph key rewritten: %s", text)
	testing.expectf(t, !strings.contains(text, old), "old key gone: %s", text)

	testing.expect_value(t, scene_roots[new], USER_SCENES_DIR)
	_, has_old := scene_roots[old]
	testing.expect(t, !has_old, "old title leaves scene_roots")
}

@(test)
funnel_create_duplicate_name_leaves_disk_untouched :: proc(t: ^testing.T) {
	name := "zz_test_dup_a"
	defer funnel_cleanup(name)

	_, ok := scene_create_named(.COMPUTE, name)
	testing.expect(t, ok, "first create")

	entry := fmt.tprintf("%s/%s/%s.slang", USER_SCENES_DIR, name, name)
	sentinel := "// sentinel, must survive a refused create\n"
	testing.expect(t, os.write_entire_file(entry, transmute([]u8)sentinel) == nil, "write sentinel")

	_, dup_ok := scene_create_named(.COMPUTE, name)
	testing.expect(t, !dup_ok, "duplicate create refused")

	data, read_err := os.read_entire_file_from_path(entry, context.temp_allocator)
	testing.expect(t, read_err == nil, "read entry back")
	testing.expect_value(t, string(data), sentinel)
}

@(test)
funnel_rename_to_taken_name_refuses :: proc(t: ^testing.T) {
	a, b := "zz_test_tk_a", "zz_test_tk_b"
	defer funnel_cleanup(a, b)

	_, a_ok := scene_create_named(.COMPUTE, a)
	_, b_ok := scene_create_named(.COMPUTE, b)
	testing.expect(t, a_ok && b_ok, "create both scenes")

	// scene_rename refuses on scene_name_taken before any disk move; the
	// disk proc trusts its caller, so the guard is what this asserts.
	testing.expect(t, scene_name_taken(b), "target name reads as taken")
	testing.expect(t, os.exists(fmt.tprintf("%s/%s/%s.slang", USER_SCENES_DIR, a, a)), "source untouched")
	testing.expect(t, os.exists(fmt.tprintf("%s/%s/%s.slang", USER_SCENES_DIR, b, b)), "target untouched")
}

// State-only funnel cases: no editor, no disk. They drive update() with a
// zeroed App whose ed is nil, so any accidental editor access panics here.

@(test)
funnel_toggle_pause_twice_restores_state :: proc(t: ^testing.T) {
	ui := Ui{}
	app := App{ui = &ui}
	initial := ui.params.paused
	update(&app, TogglePause{})
	testing.expect(t, ui.params.paused != initial, "first toggle flips paused")
	update(&app, TogglePause{})
	testing.expect_value(t, ui.params.paused, initial)
}

@(test)
funnel_begin_rename_then_cancel_clears_key :: proc(t: ^testing.T) {
	ui := Ui{}
	app := App{ui = &ui}
	defer delete(ui.rename_key)

	msg: BeginRenameScene
	msg_set(&msg.title, "zz_test_state_a")
	update(&app, msg)
	testing.expect_value(t, ui.rename_key, "zz_test_state_a")

	update(&app, CancelRename{})
	testing.expect_value(t, ui.rename_key, "")
}

@(test)
funnel_create_scene_writes_entry_and_selects :: proc(t: ^testing.T) {
	name := "zz_test_upd_a"
	defer funnel_cleanup(name)

	ui := Ui{}
	app := App{ui = &ui}
	defer delete(ui.pending_scene)

	msg: CreateScene
	msg.kind = .COMPUTE
	msg_set(&msg.name, name)
	update(&app, msg)

	testing.expect(t, os.exists(fmt.tprintf("%s/%s/%s.slang", USER_SCENES_DIR, name, name)), "update writes the entry shader")
	testing.expect_value(t, ui.pending_scene, name)
}
