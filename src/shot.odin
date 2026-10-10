package main

import gfx "./gfx"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import stbiw "vendor:stb/image"

GIF_FPS :: 17
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

// GIF export (EXPORT panel's "export gif" button): re-renders the active
// scene at GIF_FPS from t=start_s to t=end_s, writes each frame as
// /tmp/inktober_gif/frame_NNN.png, then runs ffmpeg.
export_gif :: proc(
	gfx_state: ^gfx.Gfx,
	gpu: ^sdl.GPUDevice,
	scene: ^RuntimeScene,
	scene_tex: ^sdl.GPUTexture,
	resources: ^SceneResources,
	width, height: i32,
	color: bool,
	start_s, end_s: f32,
) {
	frames := max(1, int((end_s - start_s) * GIF_FPS))
	os.make_directory(GIF_DIR)
	for i in 0 ..< 100000 {
		if remove_err := os.remove(fmt.tprintf("%s/frame_%03d.png", GIF_DIR, i)); remove_err != nil do break
	}
	for i in 0 ..< frames {
		time_s := start_s + f32(i)/GIF_FPS
		camera := camera_orbit(time_s * 0.4, 0.55, f32(width) / f32(height))
		scene_write_uniforms(
			scene,
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
		fence := submit_scene_frame(gfx_state, gpu, scene, scene_tex, resources, width, height, nil, nil, nil)
		if fence == nil {
			log.errorf("gif export: failed to submit frame %d", i)
			break
		}
		sdl.ReleaseGPUFence(gpu, fence)
		path := fmt.tprintf("%s/frame_%03d.png", GIF_DIR, i)
		if !save_texture_png(&gfx_state.uploader, scene_tex, width, height, path) do break
	}

	out_path := export_path(scene.title, "gif")
	palette := fmt.tprintf("%s/palette.png", GIF_DIR)
	filters :: "fps=17,scale=480:-1:flags=lanczos"
	cmdline := fmt.tprintf(
		`ffmpeg -v warning -framerate 17 -i %s/frame_%%03d.png -vf "%s,palettegen" -y %s` +
		` && ffmpeg -v warning -framerate 17 -i %s/frame_%%03d.png -i %s` +
		` -lavfi "%s [x]; [x][1:v] paletteuse" -y %s`,
		GIF_DIR, filters, palette, GIF_DIR, palette, filters, out_path,
	)
	status := libc.system(strings.clone_to_cstring(cmdline, context.temp_allocator))
	if status == 0 {
		log.infof("saved %s", out_path)
	} else {
		log.errorf("gif export: ffmpeg exited with status %d", status)
	}
}

// Frame export: download the just-submitted scene texture and write it as
// a PNG named after the scene (UI EXPORT button).
export_frame_png :: proc(
	uploader: ^gfx.Uploader,
	scene_tex: ^sdl.GPUTexture,
	width, height: i32,
	title: string,
) -> bool {
	path := export_path(title, "png")
	if save_texture_png(uploader, scene_tex, width, height, path) {
		log.infof("saved %s", path)
		return true
	}
	return false
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
