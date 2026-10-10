package main

// host_frame: one iteration of the main loop, in the original order. Each
// numbered section mirrors the inline block it replaced. Returns false to
// end the loop (quit, export shot, benchmark done, --once, or a fatal
// render error).

import shader_glue "./generated"
import im "../vendor/odin-imgui"
import im_sdl "../vendor/odin-imgui/backends/sdl3"
import im_sdlgpu "../vendor/odin-imgui/backends/sdlgpu3"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:math/rand"
import "core:math/linalg"
import glove "./glove"
import glove_sdl "./glove/adapters/sdl"
import gfx "./gfx"
import sdl "vendor:sdl3"

// Message pump (app.odin): every action queued by widgets or events this
// frame is applied in update; the interpreter below executes the
// resulting effects. Exports wait for their frame point (scene_tex must
// hold the current frame first).
host_drain :: proc(h: ^Host) -> Cmds {
	cmds: Cmds
	for msg_count > 0 {
		message := msg_buf[0]
		msg_count -= 1
		for i in 0 ..< msg_count do msg_buf[i] = msg_buf[i + 1]
		cmds += update(&h.application, message)
	}
	return cmds
}

// Interpreter: executes the Cmds update returned. Pure state changes
// already happened in update; these touch the window, editor, or export
// queue. Returns quit + the export to run at the frame's export point.
host_interpret :: proc(h: ^Host, cmds: Cmds) -> (quit: bool, export: ExportRequest) {
	export = .NONE
	window := h.gfx.window
	for command in cmds {
		switch command {
		case .QUIT:
			// Drop a pending watch download so shutdown never blocks on it.
			if h.inspector.watch.pending {
				debug_watch_readback_cancel(&h.inspector.watch, &h.gfx.uploader)
				h.ui.debug_watch_pending = false
				h.ui.debug_watch_sampled = false
			}
			quit = true
		case .MOBILE_ENTER:
			sdl.GetWindowPosition(window, &h.mobile_geo[0], &h.mobile_geo[1])
			sdl.GetWindowSize(window, &h.mobile_geo[2], &h.mobile_geo[3])
			mobile_w, mobile_h := i32(MOBILE_W), i32(MOBILE_H)
			bounds: sdl.Rect
			if sdl.GetDisplayUsableBounds(sdl.GetDisplayForWindow(window), &bounds) {
				// Display shorter than the target: scale down, keep 9:16.
				if bounds.h < mobile_h {
					mobile_h = bounds.h
					mobile_w = i32(f32(mobile_h) * 9.0 / 16.0)
				}
				sdl.SetWindowSize(window, mobile_w, mobile_h)
				window_x := clamp(h.mobile_geo[0], bounds.x, max(bounds.x, bounds.x + bounds.w - mobile_w))
				window_y := clamp(h.mobile_geo[1], bounds.y, max(bounds.y, bounds.y + bounds.h - mobile_h))
				sdl.SetWindowPosition(window, window_x, window_y)
			} else {
				sdl.SetWindowSize(window, mobile_w, mobile_h)
			}
		case .MOBILE_EXIT:
			sdl.SetWindowSize(window, h.mobile_geo[2], h.mobile_geo[3])
			sdl.SetWindowPosition(window, h.mobile_geo[0], h.mobile_geo[1])
		case .SAVE_ALL:
			if n := ied_save_all(h.editor); n > 0 {
				// Save feedback on the floppy icon itself (amber
				// flash + check draw-in).
				h.ui.save_flash = 1
			}
		case .EXPORT_PNG:
			export = .PNG
		case .EXPORT_GIF:
			export = .GIF
		case .DEVELOP:
			develop_request(&h.develop, &h.ui.fx)
		}
	}
	return
}

// Present: scene blit (2D or 3D heightfield) + ImGui overlay. Scoped by
// the gfx frame: every early return leaves through gfx_end_frame via the
// defer, so the command buffer is always submitted exactly once.
host_present :: proc(h: ^Host, width, height: i32, scene_tex: ^sdl.GPUTexture, app_time: f32) -> bool {
	if !gfx.gfx_begin_frame(&h.gfx) {
		log.errorf("failed to begin frame: %s", sdl.GetError())
		return false
	}
	defer gfx.gfx_end_frame(&h.gfx)
	command_buffer := h.gfx.command_buffer
	swapchain_texture := h.gfx.swapchain
	gpu_device := h.gfx.gpu

	if swapchain_texture != nil {
		color_target := sdl.GPUColorTargetInfo {
				texture     = swapchain_texture,
				load_op     = .CLEAR,
				clear_color = {0, 0, 0, 1},
				store_op    = .STORE,
			}

			if h.ui.params.view3d {
				// 3D heightfield pass: depth-tested mesh displaced by the
				// scene texture's r channel, orbited by the mouse.
				camera := blit3d_camera(
					h.input_ctx.orbit_yaw,
					h.input_ctx.orbit_pitch,
					h.input_ctx.orbit_dist,
					f32(width) / f32(height),
				)
				depth_target := sdl.GPUDepthStencilTargetInfo {
					texture     = h.targets.depth,
					load_op     = .CLEAR,
					clear_depth = 1.0,
					store_op    = .DONT_CARE,
				}
				render_pass := sdl.BeginGPURenderPass(command_buffer, &color_target, 1, &depth_target)
				sdl.BindGPUGraphicsPipeline(render_pass, h.blit.pipeline3d)
				sdl.PushGPUVertexUniformData(
					command_buffer,
					shader_glue.BLIT3D_VERTEX_CAMERA.location.slot,
					&camera,
					shader_glue.BLIT3D_VERTEX_CAMERA.size,
				)
				sdl.BindGPUVertexSamplers(
					render_pass,
					0,
					&(sdl.GPUTextureSamplerBinding {
							texture = scene_tex,
							sampler = h.blit.sampler,
						}),
					1,
				)
				sdl.DrawGPUPrimitives(render_pass, 6 * 256 * 256, 1, 0, 0)
				sdl.EndGPURenderPass(render_pass)
			} else {
				render_pass := sdl.BeginGPURenderPass(command_buffer, &color_target, 1, nil)
				if h.develop.t < 1 {
					sdl.BindGPUGraphicsPipeline(render_pass, h.blit.develop_pipeline)
					variant := develop_variant(&h.ui.fx)
					sel_rect := h.ui.scene_sel_rect
					develop_uniform := shader_glue.DevelopFragmentU {
						t       = h.develop.t,
						time    = app_time,
						res     = {f32(width), f32(height)},
						variant = variant,
						origin  = {
							(sel_rect[0] + sel_rect[2]) * 0.5 / f32(width),
							(sel_rect[1] + sel_rect[3]) * 0.5 / f32(height),
						},
					}
					sdl.PushGPUFragmentUniformData(
						command_buffer,
						shader_glue.DEVELOP_FRAGMENT_U.location.slot,
						&develop_uniform,
						shader_glue.DEVELOP_FRAGMENT_U.size,
					)
				} else {
					sdl.BindGPUGraphicsPipeline(render_pass, h.blit.pipeline)
				}
				sdl.BindGPUFragmentSamplers(
					render_pass,
					0,
					&(sdl.GPUTextureSamplerBinding {
							texture = scene_tex,
							sampler = h.blit.sampler,
						}),
					1,
				)
				sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
				sdl.EndGPURenderPass(render_pass)
			}

			// ImGui pass: Controls + editor panel on top of everything.
			if !h.headless {
				draw_data := im.GetDrawData()
				if draw_data.DisplaySize.x > 0 && draw_data.DisplaySize.y > 0 {
					im_sdlgpu.PrepareDrawData(draw_data, command_buffer)
					imgui_target := sdl.GPUColorTargetInfo {
						texture  = swapchain_texture,
						load_op  = .LOAD,
						store_op = .STORE,
					}
					imgui_pass := sdl.BeginGPURenderPass(command_buffer, &imgui_target, 1, nil)
					im_sdlgpu.RenderDrawData(draw_data, command_buffer, imgui_pass)
					sdl.EndGPURenderPass(imgui_pass)
				}
			}
		}
	_ = gpu_device
	return true
}

host_frame :: proc(h: ^Host) -> bool {
	o := &h.options
	// 1. Reset the temp allocator every frame: every tprintf, file scan
	// and JSON parse allocates into it, and without this it only ever
	// grows (the "memory keeps climbing" leak). Stored strings use
	// clones or fixed buffers, never temp.
	frame_timing_begin(&h.timing)
	free_all(context.temp_allocator)

	// 2. Scene hot-reload + on-demand asset routes. Blocked while a GIF
	// capture is mid-flight: its uniforms/submit touch the scene pointer
	// captured at gif_capture_begin, and a reload would swap it under us.
	if !gif_capture.active {
		scene_poll(&h.scene_mgr, h.gfx.gpu)
	}
	pipeline_scene_refresh(&h.scene_mgr.scenes[h.scene_mgr.current])
	pipeline_scene_reload(&h.scene_mgr.scenes[h.scene_mgr.current], &h.gfx)

	// 3. Readback polls + selftest logging.
	pixel_ready, watches_ready, _, prov_complete := inspector_poll(&h.inspector, h.ui, &h.gfx.uploader, &h.scene_mgr.scenes[h.scene_mgr.current])
	if pixel_ready && selftest_on_pixel(&h.selftest, h.ui) {
		return false
	}
	if watches_ready do selftest_on_watches(&h.selftest, h.ui, &h.scene_mgr.scenes[h.scene_mgr.current])
	if prov_complete && selftest_on_provenance(&h.selftest, &h.inspector.provenance, &h.scene_mgr.scenes[h.scene_mgr.current]) {
		return false
	}

	// 4. No scenes at all: nothing to render.
	if len(h.scene_mgr.scenes) == 0 do return false
	current := h.scene_mgr.current // captured BEFORE the pump: the switch test at step 10 compares against this

	// 5. One pump per frame: every SDL event goes to the ImGui backend
	// (outside headless) and into glove; dispatch runs after NewFrame.
	glove_sdl.pump_poll(&h.input_pump, &h.inputs)
	// Window close / Cmd+Q: gated by the unsaved-work guard. The quit
	// latch stays set when suppressed, so it must be consumed here or
	// the app can never close.
	if glove.quit_requested(&h.inputs) {
		if input_quit_allowed(&h.input_ctx) do return false
	}
	pixel_size := glove.window_pixel_size(&h.inputs)
	width, height := pixel_size.x, pixel_size.y

	// 6. (Re)create offscreen targets before ImGui records preview TexIDs.
	pass_count := i32(len(h.scene_mgr.scenes[h.scene_mgr.current].passes))
	if targets_needs_resize(&h.targets, width, height, pass_count) {
		inspector_on_resize(&h.inspector, h.ui, &h.gfx.uploader)
		if !targets_resize(&h.targets, h.gfx.gpu, width, height, pass_count) {
			return false
		}
	}

	// 7. ImGui frame: Controls + editor panel build their widgets here; the
	// draw data is rendered after the blit pass. Headless skips the whole
	// UI pass: no NewFrame, no widgets, no editor ticks.
	if !h.headless {
		im_sdlgpu.NewFrame()
		im_sdl.NewFrame()
		selftest_pan_inject(&h.selftest, &h.inputs)
		im.NewFrame()
		// Capture filter from ImGui's wants, then run the action handlers:
		// keymap-bound actions fire here, gated by what the UI captures.
		io := im.GetIO()
		captures: glove.Captures
		if io.WantCaptureKeyboard do captures += {.Keyboard}
		if io.WantCaptureMouse do captures += {.Mouse}
		glove.set_captures(&h.inputs, captures)
		// Node previews sample the previous frame's downscaled copies
		// (previews[i] mirrors passes[i]; the last entry mirrors scene) so
		// thumbnails render smoothly at thumbnail size.
		ing_pass_tex = h.targets.previews[:]
		ing_scene_tex = h.targets.previews[len(h.targets.previews) - 1]
		ing_provenance_valid = h.ui.debug_provenance_valid
		ing_provenance_path = h.ui.debug_provenance_path
		ing_provenance_rgba = h.ui.debug_provenance_rgba
		ing_output_pass = h.scene_mgr.scenes[h.scene_mgr.current].pipeline.output_pass
		ing_runtime_pipeline_error = h.scene_mgr.scenes[h.scene_mgr.current].pipeline_error
		ing_n_passes = int(pass_count)
		ui_build(h.ui, &h.scene_mgr, h.gfx.window, h.editor, h.graph, width, height)
		// The editor follows the active scene (its tab plus every imported
		// module) and keeps its background work (LSP sync, diagnostics)
		ied_open_scene(h.editor, h.scene_mgr.scenes[h.scene_mgr.current].title)
		ied_tick(h.editor)
		ied_frame(h.editor, &h.ui.fx)
	}

	// 8. Run the keymap-bound action handlers (capture-gated); ESC quit
	// and OS close requests break the loop here.
	if !h.headless do glove.dispatch(&h.inputs)
	if h.input_ctx.quit do return false

	// 9. Drain + interpret messages.
	cmds := host_drain(h)
	quit, export_pending := host_interpret(h, cmds)
	if quit do return false

	// 10. Requested scene change: drop stale readbacks, load or roll back.
	// `current` was captured before the pump (step 4); a SceneSelected msg
	// applied in update made it diverge from scene_mgr.current — the same
	// test the original main loop ran. Equal values: no switch requested.
	if h.scene_mgr.current != current {
		inspector_on_scene_change(&h.inspector, h.ui, &h.gfx.uploader)
	}
	if !scene_ensure_loaded(&h.scene_mgr, h.gfx.gpu, h.scene_mgr.current) {
		log.errorf("keeping scene %s because %s could not be loaded", h.scene_mgr.scenes[current].title, h.scene_mgr.scenes[h.scene_mgr.current].title)
		h.scene_mgr.current = current
	}

	// 11. FX trigger: any scene change (whatever the Msg path) runs the
	// develop transition, an ink burst at the scene selector, and the
	// per-change bookkeeping.
	if develop_on_scene_change(&h.develop, &h.ui.fx, h.scene_mgr.current) {
		h.input_ctx.model_orbiting = false
		set_window_title(h.gfx.window, h.scene_mgr.scenes[h.scene_mgr.current].title)
		gen_timer_reset(&h.gen)
	}
	// Messages may have switched the scene this frame (update applied
	// them); the render below reads scene_mgr.current directly.
	selftest_request_pixel(&h.selftest, h.ui)

	// 13. Metrics, toasts, ImGui render.
	if !h.headless {
		if show_metrics do im.ShowMetricsWindow(nil)
		selftest_notify_tick(&h.selftest)
		notify_draw(!h.headless ? im.GetIO().DeltaTime : 1.0/60.0)
		im.Render()
		// --hover-debug: HUD with what the scene actually receives —
		// SDL-space mouse (raw glove), scene-space mouse_pixel, click,
		// app time. Diagnoses "the scene ignores my mouse": if these
		// numbers don't move, the events never reach the app; if they
		// do, the uniform/uniform-push path is the suspect.
		if hover_debug {
			raw_pos := glove.mouse_position(&h.inputs)
			hud := fmt.ctprintf(
				"mouse sdl=(%.0f,%.0f) scene=(%.0f,%.0f) click=%v app_time=%.2f",
				raw_pos.x, raw_pos.y,
				h.input_ctx.mouse_pixel.x, h.input_ctx.mouse_pixel.y,
				h.input_ctx.mouse_click,
				h.app_time,
			)
			dl := im.GetForegroundDrawList()
			im.DrawList_AddRectFilled(dl, {8, TITLEBAR_H + 8}, {8 + im.CalcTextSize(hud).x + 12, TITLEBAR_H + 30}, im.GetColorU32Vec4({0, 0, 0, 0.75}), 4)
			im.DrawList_AddText(dl, {14, TITLEBAR_H + 12}, im.GetColorU32Vec4({0.95, 0.85, 0.55, 1}), hud)
		}
	}

	// 14. Frame clock.
	ticks := sdl.GetTicks()
	delta_time := f32(ticks - h.prev_ticks) / 1000
	h.prev_ticks = ticks
	if !h.ui.params.paused {
		h.app_time += delta_time
	}
	develop_step(&h.develop, delta_time, h.ui.fx.intensity)

	// 15. Enter mouse mode without snapping: continue from the current
	// autorotate angle, then retain every drag result after release.
	if h.previous_interaction != h.ui.params.interaction {
		if h.ui.params.interaction == .MOUSE_ROTATE {
			h.input_ctx.model_yaw = h.app_time * 0.4
			h.input_ctx.model_pitch = 0.55
		}
		h.input_ctx.model_orbiting = false
		h.previous_interaction = h.ui.params.interaction
	}

	// 16. Input + camera.
	logical := glove.window_size(&h.inputs)
	scale := f32(width) / f32(logical.x)
	input_frame(&h.inputs, &h.input_ctx, scale, height)
	mouse_pos := h.input_ctx.mouse_pixel
	mouse_click := h.input_ctx.mouse_click

	camera_yaw := h.app_time * 0.4
	camera_pitch: f32 = 0.55
	if h.ui.params.interaction == .MOUSE_ROTATE {
		camera_yaw = h.input_ctx.model_yaw
		camera_pitch = h.input_ctx.model_pitch
	}
	camera := camera_orbit(camera_yaw, camera_pitch, f32(width) / f32(height))

	// 17. Debug watch buffer: created once, on the first scene with watches.
	debug_watch_buffer: ^sdl.GPUBuffer
	if scene_has_debug_watches(&h.scene_mgr.scenes[current]) && !h.inspector.watch_buffer_valid {
		h.inspector.watch_handle = gfx.gfx_buffer_create(
			&h.gfx,
			DEBUG_WATCH_BUFFER_SIZE,
			.GRAPHICS_STORAGE_READ,
		)
		h.inspector.watch_buffer_valid = true
	}
	if h.inspector.watch_buffer_valid {
		debug_watch_buffer = gfx.gfx_buffer_get(&h.gfx, h.inspector.watch_handle).handle
	}
	h.inspector.watch_frame += 1
	debug_enabled := h.ui.pixel_inspect_valid && scene_has_debug_watches(&h.scene_mgr.scenes[current])
	debug_pixel_top := [2]i32{
		clamp(h.ui.pixel_x, 0, width - 1),
		clamp(h.ui.pixel_y, 0, height - 1),
	}
	scene_write_uniforms(
		&h.scene_mgr.scenes[current], {f32(width), f32(height)},
		h.app_time,
		h.ui.params.color,
		mouse_pos,
		mouse_click,
		&camera,
		debug_enabled,
		debug_pixel_top,
		h.inspector.watch_frame,
	)

	// 18. Resolve last frame's compute fence: sample the generation time
	// (submit → GPU completion, includes queue wait) into an EMA and feed
	// the benchmark's GPU samples.
	if sample, ok := gen_timer_poll(&h.gen, h.gfx.gpu, h.ui); ok {
		if benchmark_active(&h.benchmark) && benchmark_wants_sample(&h.benchmark) {
			append(&h.benchmark.gpu, sample)
		}
	}

	// 19. Shared resources for the frame (depth recreates on resize).
	resources := SceneResources {
		depth_tex       = h.targets.depth,
		sampler         = h.assets.paper_sampler,
		paper_textures  = h.assets.paper_textures[:],
		paper_index     = h.ui.params.paper,
		skybox_textures = h.assets.skybox_textures[:],
		skybox_index    = h.ui.params.skybox,
		model           = &h.assets.models[min(h.ui.params.model_index, len(h.assets.models) - 1)],
		pass_tex        = h.targets.passes[:],
		black_texture   = h.assets.black_texture,
		debug_watch_buffer = debug_watch_buffer,
	}

	// 20. The scene renders the offscreen texture, timed by fence.
	gen_timer_begin(&h.gen)
	fence := submit_scene_frame(
		&h.gfx,
		h.gfx.gpu,
		&h.scene_mgr.scenes[current],
		h.targets.scene,
		&resources,
		width,
		height,
		h.blit.preview_pipeline,
		h.blit.preview_sampler,
		h.targets.previews[:],
	)
	gen_timer_track(&h.gen, fence)
	if fence == nil {
		log.errorf("failed to submit scene frame: %s", sdl.GetError())
		return false
	}

	// 21. Readback requests (after submit, against the fresh frame).
	if h.ui.debug_watch_request {
		inspector_request_scene_debug(&h.inspector, h.ui, &h.scene_mgr.scenes[current], h.targets.scene, &resources, width, height, debug_watch_buffer, h.inspector.watch_frame, &h.gfx.uploader)
	}
	if h.ui.pixel_inspect_request {
		inspector_request_pixel(&h.inspector, h.ui, scale, &h.gfx.uploader, h.targets.scene, width, height)
	}

	// 21b. GIF capture: one frame per app frame (UI stays live). Skipped
	// while the UI-requested export is still arming this frame; step
	// starts on the next one.
	if gif_capture.active && export_pending == .NONE {
		gif_capture_step(h, h.targets.scene, width, height, h.ui.params.color, &resources)
	}
	// Assembly + final-toast pump (ffmpeg runs off the main thread).
	gif_export_pump()

	// 22. Frame export: download the just-submitted scene texture and exit.
	// The download's copy pass is queue-ordered AFTER the scene frame,
	// but wait for the render fence anyway so the export never races
	// the first-ever submit (black-shot repro in --once mode).
	if o.shot_path != "" {
		gen_timer_wait(&h.gen, h.gfx.gpu)
		export_shot(&h.gfx.uploader, h.targets.scene, width, height, o.shot_path)
		return false
	}

	// 23. UI export buttons: scene_tex now holds the current frame.
	#partial switch export_pending {
	case .PNG:
		if path := export_frame_png(&h.gfx.uploader, h.targets.scene, width, height, h.scene_mgr.scenes[current].title); path != "" {
			notify(.INFO, tr("saved %s"), path)
		} else {
			notify(.ERROR, tr("png export failed"))
		}
	case .GIF:
		// Capture now happens one frame per app frame (UI stays live);
		// the EXPORT_GIF cmd only arms it here.
		if !gif_capture.active {
			gif_capture_begin(h, h.ui.gif_start, h.ui.gif_end)
		}
	}
	// 24. Graphics passes: blit the texture, then the UI overlay.
	if !host_present(h, width, height, h.targets.scene, h.app_time) {
		return false
	}

	// 25.
	latency_report()

	// 26. Benchmark: debug-mode pixel seeding first (keeps the frame
	// counter consistent), then the CPU sample + completion check.
	if benchmark_active(&h.benchmark) {
		if o.benchmark_debug {
			h.ui.pixel_inspect_valid = true
			h.ui.pixel_x, h.ui.pixel_y = width / 2, height / 2
		}
		if benchmark_end_frame(&h.benchmark, frame_timing_elapsed_ms(&h.timing), h.scene_mgr.scenes[current].title) {
			return false
		}
	}

	// 27. Frame-rate telemetry.
	frame_timing_record(&h.timing, h.ui)

	// 28.
	if o.once do return false
	return true
}
