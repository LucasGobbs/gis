package main

// gis (Gobbi Interactive Shaders): a shader playground. Every .slang file in
// src/shaders/scenes is a scene (compute or fullscreen graphics pass,
// discovered and built at runtime: see scene_runtime.odin). Scenes
// render into an offscreen texture; a single blit pipeline samples it
// and the UI overlay draws on top. Generation time is measured per
// frame with a GPU fence and shown as an average in the UI.
//
// Built with -define:HOT_RELOAD:true (`make run` / `make debug`) the
// infra glue loads shader code from disk per call.

import im "../vendor/odin-imgui"
import "core:mem"
import "core:log"
import "core:os"

// The app font (JetBrains Mono), kept so the code editor can push its own
// size independently of the UI font size.
app_font: ^im.Font

show_metrics: bool

main :: proc() {
	o := options_parse(os.args[1:])
	options_apply_globals(o)

	// App-wide logging (core:log): info shows lifecycle + user actions,
	// debug hides self-test/LSP noise, warn for recoverable failures,
	// error for hard failures.
	context.logger = log.create_console_logger(log.Level.Info)

	// UI language (EN/ES/PT; core:text/i18n catalogs in i18n.odin),
	// restored from assets/i18n.lang.
	i18n_init()
	selftest_before_window(o)

	// Leak investigation: build with -define:MEM_TRACE=true to wrap the
	// heap in core:mem's tracking allocator; allocations still live at
	// exit are dumped with their allocation sites.
	when #config(MEM_TRACE, false) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			log.info("\n=== MEM TRACE: heap allocations still live at exit ===")
			for _, leak in track.allocation_map {
				log.errorf("LEAK: %v bytes allocated at %v", leak.size, leak.location)
			}
			for bad in track.bad_free_array {
				log.errorf("BAD FREE: %v at %v", bad.memory, bad.location)
			}
		}
	}

	h: Host
	if !host_init(&h, o) do return
	defer host_destroy(&h)

	for host_frame(&h) {}

	log.info("Exiting")
	if h.ui_test.enabled {
		os.exit(ui_test_exit_code(&h.ui_test))
	}
}
