package main

// Self-test harnesses (--pan-test, --pixel-test, --watch-test,
// --notify-test, --ied-test, --graph-test, --mobile). Each drives one dev
// path end to end and logs its observations; they are the app's only
// automated checks, so every flag stays.

import im "../vendor/odin-imgui"
import glove "./glove"
import "core:log"
import "core:strings"

Selftest :: struct {
	pixel:         bool,
	watch:         bool,
	pan:           bool,
	notify:        bool,
	pixel_pos:     [2]f32,
	watches_ready: bool,
	pan_frame:     int,
	notify_frame:  int,
}

selftest_init :: proc(o: Options) -> Selftest {
	return Selftest{
		pixel     = o.pixel_test,
		watch     = o.watch_test,
		pan       = o.pan_test,
		notify    = o.notify_test,
		pixel_pos = o.pixel_test_pos,
	}
}

// Startup, before the window exists: fire the three toasts once so the
// first captured frame already shows all kinds.
selftest_before_window :: proc(o: Options) {
	if o.notify_test {
		notify(.INFO, "notify test: info")
		notify(.WARN, "notify test: warning")
		notify(.ERROR, "notify test: error")
	}
}

// Startup, after ui_init/editor/graph exist: put every panel in the state
// its harness expects.
selftest_after_ui_init :: proc(st: ^Selftest, o: Options, ui: ^Ui, editor: ^ImGuiEditor, graph: ^NodeGraph, scene_mgr: ^SceneManager) {
	if st.pan do editor.open = false
	if o.start_graph {
		ui.mode = .GRAPH
		editor.open = false
		ui.graph_max = true
	}
	if o.ied_test do editor.open = true
	if o.start_mobile do emit(ToggleMobile{})
	if ing_selftest {
		graph.scene = strings.clone(scene_mgr.scenes[scene_mgr.current].title)
		sg_create_pass(graph, editor, .COMPUTE)
		sg_create_pass(graph, editor, .GRAPHICS)
	}
}

// --pixel-test / --watch-test: request one inspected pixel per frame until
// the readback lands.
selftest_request_pixel :: proc(st: ^Selftest, ui: ^Ui) {
	if st.pixel && !ui.pixel_inspect_pending && !ui.pixel_inspect_valid {
		ui.pixel_request_pos = st.pixel_pos
		ui.pixel_inspect_request = true
	}
}

// --pan-test: fake the cursor hovering the node canvas and, for a stretch
// of frames, wheel deltas as a trackpad sends them. Called after the
// backend's NewFrame so its (possibly stale) mouse-pos event doesn't
// override the fake one.
selftest_pan_inject :: proc(st: ^Selftest, inputs: ^glove.System) {
	if !st.pan {
		return
	}
	// Panel spans x 46..46+52% of the window, below the 38px title bar.
	pan_size := glove.window_size(inputs)
	pan_io := im.GetIO()
	im.IO_AddMousePosEvent(pan_io, f32(46) + f32(pan_size.x) * 0.26, f32(pan_size.y) * 0.55)
	if st.pan_frame >= 10 && st.pan_frame < 40 {
		im.IO_AddMouseWheelEvent(pan_io, 0.5, 0.8)
	}
	st.pan_frame += 1
}

// --notify-test: re-fire the toasts every second so captures at any
// moment show all three kinds.
selftest_notify_tick :: proc(st: ^Selftest, ) {
	if !st.notify {
		return
	}
	st.notify_frame += 1
	if st.notify_frame % 60 == 1 {
		notify(.INFO, "notify test: info")
		notify(.WARN, "notify test: warning")
		notify(.ERROR, "notify test: error")
	}
}

// Logs the pixel readback result; returns true when the harness wants to
// quit (pixel-test alone exits; watch-test keeps running for the watch
// and provenance phases).
selftest_on_pixel :: proc(st: ^Selftest, ui: ^Ui) -> bool {
	if !st.pixel {
		return false
	}
	log.infof(
		"[pixel-test] pixel=(%d,%d) uv=(%.4f,%.4f) rgba=(%.3f,%.3f,%.3f,%.3f)",
		ui.pixel_x, ui.pixel_y,
		ui.pixel_uv[0], ui.pixel_uv[1],
		ui.pixel_rgba[0], ui.pixel_rgba[1], ui.pixel_rgba[2], ui.pixel_rgba[3],
	)
	return !st.watch
}

// Logs every valid debug-watch sample with its pass label.
selftest_on_watches :: proc(st: ^Selftest, ui: ^Ui, scene: ^RuntimeScene) {
	if !st.watch {
		return
	}
	for watch, record_index in ui.debug_watches {
		if !watch.valid do continue
		slot := record_index % DEBUG_WATCH_COUNT
		label := "?"
		if int(watch.pass) < len(scene.passes) {
			watch_label := scene.passes[watch.pass].debug_watch_labels[slot]
			if watch_label != "" do label = watch_label
		}
		log.infof(
			"[watch-test] slot=%d label=%s pass=%d type=%d value=(%.4f,%.4f,%.4f,%.4f)",
			slot, label, watch.pass, watch.type,
			watch.value[0], watch.value[1], watch.value[2], watch.value[3],
		)
	}
	st.watches_ready = true
}

// Logs the per-pass provenance readback; returns true to quit (last phase
// of watch-test).
selftest_on_provenance :: proc(st: ^Selftest, readback: ^PassPixelReadback, scene: ^RuntimeScene) -> bool {
	if !st.watch || !st.watches_ready {
		return false
	}
	path := pipeline_plan_path(&scene.pipeline, len(scene.passes))
	for pass, i in scene.passes {
		if i >= DEBUG_WATCH_MAX_PASSES || !path[i] || !readback.valid[i] do continue
		value := readback.rgba[i]
		log.infof(
			"[provenance-test] pass=%d name=%s rgba=(%.4f,%.4f,%.4f,%.4f)",
			i, pass.name, value[0], value[1], value[2], value[3],
		)
	}
	return true
}
