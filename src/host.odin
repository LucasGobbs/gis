package main

// Host: app lifecycle and the frame loop. main.odin shrinks to options →
// host_init → for host_frame → host_destroy; every subsystem lives here.

import shader_glue "./generated"
import im "../vendor/odin-imgui"
import im_sdl "../vendor/odin-imgui/backends/sdl3"
import im_sdlgpu "../vendor/odin-imgui/backends/sdlgpu3"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:math/rand"
import glove "./glove"
import glove_sdl "./glove/adapters/sdl"
import gfx "./gfx"
import sdl "vendor:sdl3"

set_window_title :: proc(window: ^sdl.Window, title: string) {
	if !sdl.SetWindowTitle(window, fmt.ctprint("gis · ", title)) {
		log.warnf("failed to update window title: %s", sdl.GetError())
	}
}

Host :: struct {
	options:   Options,
	selftest:  Selftest,
	benchmark: Benchmark,
	gfx:       gfx.Gfx,
	inputs:    glove.System,
	input_pump: glove_sdl.Pump,
	input_ctx: Input_Context,
	scene_mgr: SceneManager,
	ui:        ^Ui,
	editor:    ^ImGuiEditor,
	graph:     ^NodeGraph,
	application: App,
	blit:      Blit,
	targets:   Render_Targets,
	inspector: Inspector,
	assets:    Assets,
	develop:   Develop,
	timing:    Frame_Timing,
	gen:       Gen_Timer,
	app_time:  f32,
	prev_ticks: u64,
	previous_interaction: InteractionMode,
	mobile_geo: [4]i32,
	imgui_ready: bool,
	headless:  bool,
}

host_init :: proc(h: ^Host, o: Options) -> bool {
	h.options = o
	h.headless = o.headless
	h.selftest = selftest_init(o)
	h.benchmark = benchmark_init(o)
	h.develop = develop_init()

	// SDL validation errors (bad bindings, invalid GPU state) become
	// error toasts (notify.odin) instead of the abort dialog: the app
	// keeps running, the user sees what happened. The callback runs on
	// whatever thread tripped the assert, so it needs a saved context.
	g_sdl_context = context
	sdl.SetAssertionHandler(sdl_assert_notify, nil)

	// Native window frame (gfx.create): the OS draws the title bar and
	// its window controls; the app toolbar renders inside the client
	// area below it.
	if !gfx.create(&h.gfx, "gis", 800, 600) {
		log.errorf("failed to create window/GPU device: %s", sdl.GetError())
		return false
	}
	window := h.gfx.window
	gpu_device := h.gfx.gpu
	// User asset loads (graph resource routes) share the main gfx state.
	user_assets_set_gfx(&h.gfx)
	// Glove owns every SDL input event from here on: one pump per frame,
	// seeded with the window's initial size (no resize event fires for it).
	h.inputs = glove.system_create(glove_sdl.create())
	glove_sdl.pump_seed_window(&h.inputs, window)
	if !h.headless {
		if !sdl.SetWindowMinimumSize(window, 480, 320) {
			log.errorf("failed to set minimum window size: %s", sdl.GetError())
			host_destroy(h)
			return false
		}
	}
	if benchmark_active(&h.benchmark) {
		gfx.gfx_set_present_mode(&h.gfx, .IMMEDIATE)
		log.info("[benchmark] present mode=immediate")
	}

	// Catalog every scene, but compile/load only the selected startup scene.
	if !scene_rescan(&h.scene_mgr, gpu_device, o.start_scene) {
		log.error("failed to initialize scene catalog")
		host_destroy(h)
		return false
	}

	// --scene <name>: resolve to the catalog index (alphabetical order,
	// same order the selector shows).
	if o.start_scene_name != "" {
		found := false
		for &scene, i in h.scene_mgr.scenes do if scene.title == o.start_scene_name {
			scene_ensure_loaded(&h.scene_mgr, gpu_device, i)
			h.scene_mgr.current = i
			found = true
			break
		}
		if !found do log.warnf("scene %q not found in catalog", o.start_scene_name)
	}

	set_window_title(window, h.scene_mgr.scenes[h.scene_mgr.current].title)

	blit, blit_ok := blit_init(gpu_device, window)
	h.blit = blit
	if !blit_ok {
		host_destroy(h)
		return false
	}

	h.ui = ui_init()
	if o.force3d do h.ui.params.view3d = true
	if o.pixel_test do h.ui.pixel_inspect_enabled = true
	if o.force_color do h.ui.params.color = true

	// Integrated ImGui shader editor (F1 toggles the panel). Headless
	// skips it entirely: no UI context, no editor, no node graph.
	if !h.headless {
		im.CHECKVERSION()
		im.CreateContext()
		// Coding font for everything (UI + editor): the atlas default is a tiny
		// bitmap font that hurts readability; JetBrains Mono is OFL-licensed and
		// vendored. FontDefault switches NewFrame to it.
		io_fonts := im.GetIO()
		if mono_font := im.FontAtlas_AddFontFromFileTTF(io_fonts.Fonts, "vendor/fonts/JetBrainsMono-Regular.ttf", 16, nil, nil); mono_font != nil {
			io_fonts.FontDefault = mono_font
			app_font = mono_font
		}
		ui_apply_style()
		im_sdl.InitForSDLGPU(window)
		imgui_init := im_sdlgpu.DEFAULT_INIT_INFO
		imgui_init.Device = gpu_device
		imgui_init.ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(gpu_device, window)
		imgui_gpu_ok := im_sdlgpu.Init(&imgui_init)
		if !imgui_gpu_ok {
			log.error("failed to initialize ImGui SDL_GPU backend")
			host_destroy(h)
			return false
		}
		h.editor = ied_init()
		h.graph = ing_init()
		ui_prefs_load(h.ui, h.editor)
		im.GetStyle().FontSizeBase = h.ui.font_size
		// Keyboard navigation for the ImGui chrome (sidebar, combos,
		// popups): the app is keyboard-first (Cmd+S, F1-F5), the chrome
		// should not be mouse-only.
		im.GetIO().ConfigFlags += {im.ConfigFlags.NavEnableKeyboard}
		h.imgui_ready = true
	}

	// The application (app.odin): everything that happens is a Msg,
	// applied in update; effects run through the interpreter below.
	h.application = App {
		ui  = h.ui,
		sm  = &h.scene_mgr,
		ed  = h.editor,
		ing = h.graph,
		win = window,
	}

	// App-side input bindings: named actions, handlers, and the keymap.
	// Handlers need the editor (nil in headless), so this waits for it.
	h.input_ctx = Input_Context{
		ui          = h.ui,
		editor      = h.editor,
		scene_mgr   = &h.scene_mgr,
		window      = window,
		orbit_yaw   = 0.6,
		orbit_pitch = 0.55,
		orbit_dist  = 2.6,
		model_pitch = 0.55,
	}
	h.inputs.action_log_enabled = o.input_log
	input_bindings_init(&h.inputs, &h.input_ctx)
	if !h.headless {
		// ImGui (and only ImGui) sees the raw event stream too, for its
		// own widgets; glove stays the only reader of app input.
		glove_sdl.pump_set_forwarder(&h.input_pump, imgui_forward_event, nil)
	}

	selftest_after_ui_init(&h.selftest, o, h.ui, h.editor, h.graph, &h.scene_mgr)

	if !assets_load(&h.assets, &h.gfx, gpu_device) {
		host_destroy(h)
		return false
	}
	// The panel grain background (fx): since ImGui 1.92.2 the sdlgpu3
	// backend expects a raw SDL_GPUTexture* as TextureID (it builds the
	// sampler binding itself), so we hand it the paper texture directly.
	fx_grain_binding = rawptr(gfx.gfx_texture_get(&h.gfx, h.assets.paper_textures[0]).handle)

	h.ui.time = &h.app_time
	h.previous_interaction = h.ui.params.interaction
	h.prev_ticks = sdl.GetTicks()
	return true
}

host_destroy :: proc(h: ^Host) {
	gpu_device := h.gfx.gpu
	inspector_cancel_pending(&h.inspector, &h.gfx.uploader)
	targets_destroy(gpu_device, &h.targets)
	blit_destroy(gpu_device, &h.blit)
	assets_destroy(gpu_device, &h.assets)
	if h.imgui_ready {
		ite_destroy(h.editor.handle)
		ine_destroy(h.graph.handle)
		im_sdlgpu.Shutdown()
		im_sdl.Shutdown()
		h.imgui_ready = false
	}
	// All pooled gfx assets (paper, skybox, black fallback) go through the
	// Gfx teardown.
	gfx.destroy(&h.gfx)
	glove.system_destroy(&h.inputs)
}
