package main

// Pixel / debug-watch / provenance readback primitives: GPU-to-CPU
// downloads built on gfx.Staging. The per-frame orchestration lives in
// frame.odin (Inspector); export lives in shot.odin.

import gfx "./gfx"
import "core:c/libc"
import sdl "vendor:sdl3"
import stbiw "vendor:stb/image"

PixelReadback :: struct {
	staging: gfx.Staging,
	pending: bool,
	x, y:    i32,
}

pixel_readback_begin :: proc(
	readback: ^PixelReadback,
	uploader: ^gfx.Uploader,
	texture: ^sdl.GPUTexture,
	x, y, width, height: i32,
) -> bool {
	if readback.pending || texture == nil || width <= 0 || height <= 0 do return false
	pixel_x := clamp(x, 0, width - 1)
	pixel_y := clamp(y, 0, height - 1)
	// 1x1 region of a tightly packed RGBA8 texture: 4 bytes.
	readback.staging = gfx.uploader_download_texture_region_begin(uploader, texture, pixel_x, pixel_y, 1, 1)
	readback.pending = true
	readback.x, readback.y = pixel_x, pixel_y
	return true
}

pixel_readback_poll :: proc(
	readback: ^PixelReadback,
	uploader: ^gfx.Uploader,
) -> (rgba: [4]f32, x, y: i32, ready: bool) {
	if !readback.pending || !gfx.staging_ready(uploader, readback.staging) do return
	staged_bytes := gfx.staging_read(readback.staging)
	for channel in 0 ..< 4 do rgba[channel] = f32(staged_bytes[channel]) / 255.0
	gfx.staging_release(uploader, readback.staging)
	readback^ = {}
	ready = true
	return
}

pixel_readback_cancel :: proc(readback: ^PixelReadback, uploader: ^gfx.Uploader) {
	if !readback.pending do return
	// Block until the download lands so the staging can go back to the pool.
	for !gfx.staging_ready(uploader, readback.staging) {}
	gfx.staging_release(uploader, readback.staging)
	readback^ = {}
}

PassPixelReadback :: struct {
	items: [DEBUG_WATCH_MAX_PASSES]PixelReadback,
	rgba:  [DEBUG_WATCH_MAX_PASSES][4]f32,
	valid: [DEBUG_WATCH_MAX_PASSES]bool,
	count: int,
	pending: bool,
}

pass_pixel_readback_cancel :: proc(readback: ^PassPixelReadback, uploader: ^gfx.Uploader) {
	for &item in readback.items do if item.pending do pixel_readback_cancel(&item, uploader)
	readback^ = {}
}

pass_pixel_readback_begin :: proc(
	readback: ^PassPixelReadback,
	uploader: ^gfx.Uploader,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	resources: ^SceneResources,
	x, y, width, height: i32,
) -> bool {
	if readback.pending do pass_pixel_readback_cancel(readback, uploader)
	readback.count = min(len(scene.passes), DEBUG_WATCH_MAX_PASSES)
	started := false
	for pass_index in 0 ..< readback.count {
		texture := scene_pass_texture(scene, scene_tex, resources, pass_index)
		if pixel_readback_begin(&readback.items[pass_index], uploader, texture, x, y, width, height) {
			started = true
		}
	}
	readback.pending = started
	return started
}

pass_pixel_readback_poll :: proc(readback: ^PassPixelReadback, uploader: ^gfx.Uploader) -> (changed, complete: bool) {
	if !readback.pending do return
	still_pending := false
	for pass_index in 0 ..< readback.count {
		if !readback.items[pass_index].pending do continue
		rgba, _, _, ready := pixel_readback_poll(&readback.items[pass_index], uploader)
		if ready {
			readback.rgba[pass_index] = rgba
			readback.valid[pass_index] = true
			changed = true
		}
		still_pending |= readback.items[pass_index].pending
	}
	readback.pending = still_pending
	complete = !still_pending
	return
}

DEBUG_WATCH_COUNT :: 8
DEBUG_WATCH_RECORD_COUNT :: DEBUG_WATCH_COUNT * DEBUG_WATCH_MAX_PASSES
DEBUG_WATCH_RECORD_SIZE :: 32
DEBUG_WATCH_BUFFER_SIZE :: DEBUG_WATCH_RECORD_COUNT * DEBUG_WATCH_RECORD_SIZE

DebugWatchSample :: struct {
	valid: bool,
	type:  u32,
	count: u32,
	pass:  u32,
	value: [4]f32,
}

DebugWatchReadback :: struct {
	staging: gfx.Staging,
	frame_id: u32,
	pending: bool,
}

debug_watch_readback_begin :: proc(
	readback: ^DebugWatchReadback,
	uploader: ^gfx.Uploader,
	buffer: ^sdl.GPUBuffer,
	frame_id: u32,
) -> bool {
	if readback.pending || buffer == nil do return false
	readback.staging = gfx.uploader_download_buffer_begin(uploader, buffer, DEBUG_WATCH_BUFFER_SIZE)
	readback.frame_id = frame_id
	readback.pending = true
	return true
}

debug_watch_readback_poll :: proc(
	readback: ^DebugWatchReadback,
	uploader: ^gfx.Uploader,
) -> (samples: [DEBUG_WATCH_RECORD_COUNT]DebugWatchSample, ready: bool) {
	if !readback.pending || !gfx.staging_ready(uploader, readback.staging) do return
	staged_bytes := gfx.staging_read(readback.staging)
	buffer_base := uintptr(raw_data(staged_bytes))
	for record_index in 0 ..< DEBUG_WATCH_RECORD_COUNT {
		record_offset := uintptr(record_index * DEBUG_WATCH_RECORD_SIZE)
		record_frame := (^u32)(rawptr(buffer_base + record_offset + 0))^
		if record_frame != readback.frame_id do continue
		samples[record_index].valid = true
		samples[record_index].type = (^u32)(rawptr(buffer_base + record_offset + 4))^
		samples[record_index].count = (^u32)(rawptr(buffer_base + record_offset + 8))^
		samples[record_index].pass = (^u32)(rawptr(buffer_base + record_offset + 12))^
		for channel in 0 ..< 4 {
			samples[record_index].value[channel] = (^f32)(rawptr(buffer_base + record_offset + uintptr(16 + channel*4)))^
		}
	}
	gfx.staging_release(uploader, readback.staging)
	readback^ = {}
	ready = true
	return
}

debug_watch_readback_cancel :: proc(readback: ^DebugWatchReadback, uploader: ^gfx.Uploader) {
	if !readback.pending do return
	for !gfx.staging_ready(uploader, readback.staging) {}
	gfx.staging_release(uploader, readback.staging)
	readback^ = {}
}

// Per-frame orchestration of the three readbacks (pixel inspect, debug
// watches, provenance). Polls pending downloads and updates ui state;
// selftest hooks live in selftest.odin.
Inspector :: struct {
	pixel:      PixelReadback,
	watch:      DebugWatchReadback,
	provenance: PassPixelReadback,
	// Debug watch GPU buffer (created once per app run, on first scene
	// with watches) and the frame counter its records are stamped with.
	watch_handle:       gfx.Buffer_Handle,
	watch_buffer_valid: bool,
	watch_frame:        u32,
}

inspector_cancel_pending :: proc(ins: ^Inspector, uploader: ^gfx.Uploader) {
	if ins.pixel.pending do pixel_readback_cancel(&ins.pixel, uploader)
	if ins.watch.pending do debug_watch_readback_cancel(&ins.watch, uploader)
	if ins.provenance.pending do pass_pixel_readback_cancel(&ins.provenance, uploader)
}

// Window resize: drop pending downloads (their sizes changed); the valid
// sampled data stays until the next request.
inspector_on_resize :: proc(ins: ^Inspector, ui: ^Ui, uploader: ^gfx.Uploader) {
	inspector_cancel_pending(ins, uploader)
	ui.pixel_inspect_pending = false
	ui.debug_watch_pending = false
}

// Scene change: everything stale — cancel downloads and clear state.
inspector_on_scene_change :: proc(ins: ^Inspector, ui: ^Ui, uploader: ^gfx.Uploader) {
	inspector_cancel_pending(ins, uploader)
	ui.pixel_inspect_pending = false
	ui.pixel_inspect_valid = false
	ui.pixel_inspect_request = false
	ui.debug_watch_pending = false
	ui.debug_watch_sampled = false
	ui.debug_watch_request = false
	ui.debug_provenance_pending = false
	ui.debug_provenance_valid = {}
	ui.debug_provenance_path = {}
}

// Polls all three readbacks; updates ui and reports what landed so the
// frame layer can trigger selftest logs. prov_complete clears the
// provenance pending flag.
inspector_poll :: proc(
	ins: ^Inspector,
	ui: ^Ui,
	uploader: ^gfx.Uploader,
	scene: ^RuntimeScene,
) -> (pixel_ready, watches_ready, prov_changed, prov_complete: bool) {
	pixel_rgba, pixel_x, pixel_y, ready := pixel_readback_poll(&ins.pixel, uploader)
	if ready {
		ui.pixel_inspect_pending = false
		ui.pixel_inspect_valid = true
		ui.pixel_x, ui.pixel_y = pixel_x, pixel_y
		ui.pixel_rgba = pixel_rgba
		ui.debug_watch_request = true
		ui.debug_watch_sampled = false
		ui.debug_provenance_valid = {}
		ui.debug_provenance_rgba = {}
		ui.debug_provenance_path = pipeline_plan_path(&scene.pipeline, len(scene.passes))
		pixel_ready = true
	}
	watch_samples, got := debug_watch_readback_poll(&ins.watch, uploader)
	if got {
		ui.debug_watch_pending = false
		ui.debug_watch_sampled = true
		ui.debug_watches = watch_samples
		watches_ready = true
	}
	prov_changed, prov_complete = pass_pixel_readback_poll(&ins.provenance, uploader)
	if prov_changed {
		ui.debug_provenance_valid = ins.provenance.valid
		ui.debug_provenance_rgba = ins.provenance.rgba
	}
	if prov_complete {
		ui.debug_provenance_pending = false
	}
	return
}

// ui.debug_watch_request handling: begin the watch + provenance downloads
// for the just-submitted frame.
inspector_request_scene_debug :: proc(
	ins: ^Inspector,
	ui: ^Ui,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	resources: ^SceneResources,
	width, height: i32,
	watch_buffer: ^sdl.GPUBuffer,
	watch_frame: u32,
	uploader: ^gfx.Uploader,
) {
	ui.debug_watch_request = false
	ui.debug_watch_sampled = false
	if scene_has_debug_watches(scene) && watch_buffer != nil {
		if debug_watch_readback_begin(&ins.watch, uploader, watch_buffer, watch_frame) {
			ui.debug_watch_pending = true
		}
	} else {
		ui.debug_watch_pending = false
		ui.debug_watch_sampled = true
		ui.debug_watches = {}
	}
	if pass_pixel_readback_begin(
		&ins.provenance,
		uploader,
		scene,
		scene_tex,
		resources,
		ui.pixel_x,
		ui.pixel_y,
		width,
		height,
	) {
		ui.debug_provenance_pending = true
	}
}

// ui.pixel_inspect_request handling: begin the 1x1 pixel download at the
// request position (scaled to pixels).
inspector_request_pixel :: proc(
	ins: ^Inspector,
	ui: ^Ui,
	scale: f32,
	uploader: ^gfx.Uploader,
	scene_tex: ^sdl.GPUTexture,
	width, height: i32,
) {
	pixel_x := clamp(i32(ui.pixel_request_pos[0] * scale), i32(0), width - 1)
	pixel_y := clamp(i32(ui.pixel_request_pos[1] * scale), i32(0), height - 1)
	ui.pixel_inspect_request = false
	if pixel_readback_begin(&ins.pixel, uploader, scene_tex, pixel_x, pixel_y, width, height) {
		ui.pixel_inspect_pending = true
		ui.pixel_x, ui.pixel_y = pixel_x, pixel_y
		frag_x := f32(pixel_x) + 0.5
		frag_y := f32(height) - (f32(pixel_y) + 0.5)
		ui.pixel_uv = {frag_x / f32(width), frag_y / f32(height)}
		ui.pixel_scene_uv = {
			(frag_x - 0.5 * f32(width)) / f32(height),
			(frag_y - 0.5 * f32(height)) / f32(height),
		}
	}
}

// Shutdown: release pending staging. (Targets are targets_destroy's job.)
inspector_destroy :: proc(ins: ^Inspector, uploader: ^gfx.Uploader) {
	inspector_cancel_pending(ins, uploader)
}
