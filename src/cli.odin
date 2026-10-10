package main

// CLI options: parsing (once, per flag) and the globals other modules read
// (flags that predate the Options struct). Everything else is carried in
// Options and consumed by main/host_init.

import "core:os"
import "core:strconv"
import "core:strings"
import glove_sdl "./glove/adapters/sdl"

Options :: struct {
	once:             bool,
	headless:         bool,
	force3d:          bool,
	force_color:      bool,
	start_mobile:     bool,
	start_graph:      bool,
	metrics:          bool,
	notify_test:      bool,
	pixel_test:       bool,
	ied_debug_clicks: bool,
	watch_test:       bool,
	hover_debug:      bool,
	input_log:        bool,
	pan_test:         bool,
	ied_test:         bool,
	benchmark_frames: int, // 0 = off
	benchmark_warmup: int,
	benchmark_debug:  bool,
	start_scene:      int,
	start_scene_name: string,
	shot_path:        string,
	pixel_test_pos:   [2]f32,
}

options_parse :: proc(args: []string) -> Options {
	o := Options{
		benchmark_warmup = 60,
		pixel_test_pos   = {400, 300},
	}
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--once":
			o.once = true
		case "--3d":
			o.force3d = true
		case "--ied-debug":
			o.ied_debug_clicks = true
		case "--ied-test":
			o.ied_test = true
		case "--hover-debug":
			// Logs the live hover pipeline (capture, dwell, lookup).
			o.hover_debug = true
		case "--input-log":
			// Logs every raw key press and mouse click (glove SDL
			// adapter) — the exact user input stream.
			o.input_log = true
		case "--notify-test":
			// Fires one toast of each kind at startup (visual check of
			// the notification overlay).
			o.notify_test = true
		case "--benchmark", "--benchmark-debug":
			o.benchmark_frames = 300
			o.benchmark_debug = args[i] == "--benchmark-debug"
			if i + 1 < len(args) {
				if count, ok := strconv.parse_int(args[i + 1]); ok && count > 0 {
					o.benchmark_frames = int(count)
					i += 1
				}
			}
		case "--metrics":
			o.metrics = true
		case "--mobile":
			// Start in mobile theater (F5): 9:16 portrait for vertical
			// recordings.
			o.start_mobile = true
		case "--color":
			o.force_color = true
		case "--shot":
			// Render one frame, export it as PNG (src/shot.odin), exit.
			if i + 1 < len(args) {
				i += 1
				o.shot_path = args[i]
			}
		case "--scene":
			if i + 1 < len(args) {
				i += 1
				// Accepts a 1-based index (--scene 10) or a scene name
				// (--scene 10_multipass); the name wins when both parse.
				if n, parsed := strconv.parse_int(args[i]); parsed && n > 0 {
					o.start_scene = int(n - 1)
				} else {
					o.start_scene_name = strings.clone(args[i])
				}
			}
		case "--headless":
			// Code-only mode: scene fullscreen, no UI chrome. Edit the
			// .slang in an external editor (VS Code); saving hot-reloads.
			o.headless = true
		case "--pixel-test":
			o.pixel_test = true
			if i + 2 < len(args) {
				x, x_ok := strconv.parse_int(args[i + 1])
				y, y_ok := strconv.parse_int(args[i + 2])
				if x_ok && y_ok {
					o.pixel_test_pos = {f32(x), f32(y)}
					i += 2
				}
			}
		case "--watch-test":
			o.pixel_test = true
			o.watch_test = true
			if i + 2 < len(args) {
				x, x_ok := strconv.parse_int(args[i + 1])
				y, y_ok := strconv.parse_int(args[i + 2])
				if x_ok && y_ok {
					o.pixel_test_pos = {f32(x), f32(y)}
					i += 2
				}
			}
		case "--graph":
			// Start with the sidebar on the node graph panel (CLI parity
			// with F2).
			o.start_graph = true
		case "--graph-test":
			// --graph plus two created passes on the starting scene.
			o.start_graph = true
			o.ied_test = false // keep separate from ied_test
			ing_selftest = true
		case "--graph-click-test":
			// Alias of --graph: the synthetic right-click flow lives in
			// imgui_nodes (ing_click_test); no separate main local today.
			o.start_graph = true
		case "--pan-test":
			// Drive the node-editor trackpad pan without a trackpad: fake
			// the cursor over the canvas and inject wheel deltas.
			o.pan_test = true
			pan_test_debug = true
			o.start_graph = true
		}
	}
	return o
}

// Flags other modules read as globals (pre-Options interface).
options_apply_globals :: proc(o: Options) {
	ied_debug_clicks = o.ied_debug_clicks
	ied_selftest = o.ied_test
	hover_debug = o.hover_debug

	show_metrics = o.metrics
}
