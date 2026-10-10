package main

import gfx "./gfx"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import stbiw "vendor:stb/image"
import "base:runtime"
import "core:thread"

GIF_FPS :: 17
GIF_OUT_W :: 480 // ffmpeg -vf scale width for GIF assembly
GIF_DIR :: "/tmp/inktober_gif"

// exports/<title>_YYYY-MM-DD_HH-MM-SS.<ext>: one file per export, so the
// exports/ folder keeps the full export history. Creates exports/ on demand.
// Timestamp is local time (libc localtime/strftime).
export_path :: proc(title, ext: string) -> string {
	os.make_directory("exports") // fine if it already exists
	unix_now := libc.time(nil)
	time_buf: [64]u8
	written := libc.strftime(raw_data(time_buf[:]), len(time_buf), "%Y-%m-%d_%H-%M-%S", libc.localtime(&unix_now))
	return fmt.tprintf("exports/%s_%s.%s", title, string(time_buf[:written]), ext)
}

// Downloads `tex` and saves it as RGBA8 PNG. The texture must have been
// submitted in an earlier command buffer (the scene compute pass).
save_texture_png :: proc(
	uploader: ^gfx.Uploader,
	texture: ^sdl.GPUTexture,
	width, height: i32,
	path: string,
) -> bool {
	staging := gfx.uploader_download_texture_begin(uploader, texture, u32(width), u32(height))
	defer gfx.staging_release(uploader, staging)
	for !gfx.staging_ready(uploader, staging) {}
	staged_bytes := gfx.staging_read(staging)
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	write_ok := stbiw.write_png(path_c, width, height, 4, raw_data(staged_bytes), width * 4) != 0
	if !write_ok {
		log.errorf("shot: failed to write %s", path)
		return false
	}
	log.infof("shot: wrote %s (%dx%d)", path, width, height)
	return true
}

// GIF capture state: frames are rendered and saved one per app frame
// (the UI stays live and shows progress), then ffmpeg assembles the PNGs
// on a worker thread. Started by frame.odin when the UI requests a GIF;
// gif_capture_step runs each app frame until done.
Gif_Capture :: struct {
	active:   bool,
	frame:    int,       // next frame index to render
	frames:   int,       // total (computed from [start, end])
	start_s:  f32,
	scene:    ^RuntimeScene, // valid while active: pump blocks scene reload
	out_path: string,    // owned; final GIF destination
	done:     bool,      // capture phase finished (worker may still run)
	ffmpeg:   bool,      // assembly running on the worker thread
	ffmpeg_ok: bool,
}

gif_capture: Gif_Capture
gif_capture_thread: ^thread.Thread

gif_capture_begin :: proc(h: ^Host, start_s, end_s: f32) {
	frames := max(1, int((end_s - start_s) * GIF_FPS))
	os.make_directory(GIF_DIR)
	// Clear stale frames from previous captures.
	for i in 0 ..< 100000 {
		if remove_err := os.remove(fmt.tprintf("%s/frame_%03d.png", GIF_DIR, i)); remove_err != nil do break
	}
	gif_capture = Gif_Capture{
		active   = true,
		frames   = frames,
		start_s  = start_s,
		scene    = &h.scene_mgr.scenes[h.scene_mgr.current],
		out_path = strings.clone(export_path(h.scene_mgr.scenes[h.scene_mgr.current].title, "gif")),
	}
	notify(.INFO, tr("gif: capturing %d frames"), frames)
}

// One capture step per app frame: write uniforms for frame N, submit,
// download to PNG. Returns false when the capture finished or failed.
gif_capture_step :: proc(h: ^Host, scene_tex: ^sdl.GPUTexture, width, height: i32, color: bool, resources: ^SceneResources) -> bool {
	c := &gif_capture
	if !c.active do return false
	// Safety net for the SceneSelected guard in app.update: if the active
	// scene changed mid-capture (scene reload reallocates sm.scenes),
	// abort instead of writing uniforms through a dangling scene pointer.
	if len(h.scene_mgr.scenes) == 0 || c.scene.title != h.scene_mgr.scenes[h.scene_mgr.current].title {
		log.errorf("gif export: active scene changed mid-capture, aborting at frame %d", c.frame)
		notify(.ERROR, tr("gif export aborted: scene changed mid-capture"))
		c.active = false
		c.done = false
		delete(c.out_path)
		c.out_path = ""
		return false
	}
	if c.frame >= c.frames {
		c.active = false
		c.done = true
		return false
	}
	time_s := c.start_s + f32(c.frame) / GIF_FPS
	camera := camera_orbit(time_s * 0.4, 0.55, f32(width) / f32(height))
	scene_write_uniforms(
		c.scene,
		{f32(width), f32(height)},
		time_s,
		color,
		{0, 0},
		false,
		&camera,
		false,
		{0, 0},
		0,
	)
	fence := submit_scene_frame(&h.gfx, h.gfx.gpu, c.scene, scene_tex, resources, width, height, nil, nil, nil)
	if fence == nil {
		log.errorf("gif export: failed to submit frame %d", c.frame)
		notify(.ERROR, tr("gif export failed at frame %d"), c.frame)
		c.active = false
		c.done = false
		delete(c.out_path)
		c.out_path = ""
		return false
	}
	sdl.ReleaseGPUFence(h.gfx.gpu, fence)
	path := fmt.tprintf("%s/frame_%03d.png", GIF_DIR, c.frame)
	if !save_texture_png(&h.gfx.uploader, scene_tex, width, height, path) {
		notify(.ERROR, tr("gif export failed at frame %d"), c.frame)
		c.active = false
		c.done = false
		delete(c.out_path)
		c.out_path = ""
		return false
	}
	c.frame += 1
	return true
}

// ffmpeg assembly on a worker thread: process exec + file IO only, no
// GPU or ImGui contact. Signals completion for the main thread's toast.
gif_ffmpeg_worker :: proc() {
	free_all(context.temp_allocator) // own the thread's temp allocator
	filters := fmt.tprintf("fps=%d,scale=%d:-1:flags=lanczos", GIF_FPS, GIF_OUT_W)
	palette := fmt.tprintf("%s/palette.png", GIF_DIR)
	cmdline := fmt.tprintf(
		`ffmpeg -v warning -framerate %d -i %s/frame_%%03d.png -vf "%%s,palettegen" -update 1 -y %s` +
		` && ffmpeg -v warning -framerate %d -i %s/frame_%%03d.png -i %s` +
		` -lavfi "%%s [x]; [x][1:v] paletteuse" -y %s`,
		GIF_FPS, GIF_DIR, filters, palette, GIF_FPS, GIF_DIR, palette, filters, gif_capture.out_path,
	)
	status := libc.system(strings.clone_to_cstring(cmdline, context.temp_allocator))
	gif_capture.ffmpeg_ok = status == 0
	gif_capture.ffmpeg = true
}

gif_ffmpeg_start :: proc() {
	gif_capture.ffmpeg = false
	gif_capture.ffmpeg_ok = false
	gif_capture_thread = thread.create_and_start(gif_ffmpeg_worker, runtime.default_context())
}

// Per-frame progress pump: reports capture progress, launches assembly,
// and delivers the final toast. Returns true while a GIF export is in
// flight (capture phase; callers must block scene reload during it).
gif_export_pump :: proc() -> bool {
	c := &gif_capture
	if c.active do return true
	if c.done && !c.ffmpeg && gif_capture_thread == nil {
		gif_ffmpeg_start()
		return true
	}
	if c.done && c.ffmpeg {
		if gif_capture_thread != nil && !thread.is_done(gif_capture_thread) do return true
		if c.ffmpeg_ok {
			notify(.INFO, tr("saved %s"), c.out_path)
		} else {
			log.error("gif export: ffmpeg exited with an error (is ffmpeg installed?)")
			notify(.ERROR, tr("gif assembly failed: is ffmpeg installed?"))
		}
		thread.destroy(gif_capture_thread)
		gif_capture_thread = nil
		delete(c.out_path)
		c.done = false
	}
	return false
}

// Frame export: download the just-submitted scene texture and write it as
// a PNG named after the scene (UI EXPORT button). Returns the written
// path ("" on failure) so frame.odin can toast it.
export_frame_png :: proc(
	uploader: ^gfx.Uploader,
	scene_tex: ^sdl.GPUTexture,
	width, height: i32,
	title: string,
) -> string {
	path := export_path(title, "png")
	if save_texture_png(uploader, scene_tex, width, height, path) {
		return path
	}
	return ""
}

// `--shot <path>`: same download, explicit path, single frame.
export_shot :: proc(
	uploader: ^gfx.Uploader,
	scene_tex: ^sdl.GPUTexture,
	width, height: i32,
	path: string,
) -> bool {
	return save_texture_png(uploader, scene_tex, width, height, path)
}
