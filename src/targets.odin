package main

// Offscreen render targets: the scene texture presented by the viewport,
// one stable target per reflected pass, fixed-size preview thumbnails
// (one per pass + the final image), and the 3D view's depth buffer. The
// JSON pipeline chooses which pass target is the output.

import "core:log"
import sdl "vendor:sdl3"

PREVIEW_SIZE :: 128

create_scene_target :: proc(gpu_device: ^sdl.GPUDevice, width, height: i32) -> ^sdl.GPUTexture {
	return sdl.CreateGPUTexture(
		gpu_device,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER, .COMPUTE_STORAGE_WRITE, .COLOR_TARGET},
			width = u32(width),
			height = u32(height),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
}

Render_Targets :: struct {
	scene:    ^sdl.GPUTexture,
	depth:    ^sdl.GPUTexture,
	passes:   [dynamic]^sdl.GPUTexture,
	previews: [dynamic]^sdl.GPUTexture,
	w, h:     i32,
}

targets_needs_resize :: proc(t: ^Render_Targets, width, height, pass_count: i32) -> bool {
	return t.scene == nil || t.w != width || t.h != height || i32(len(t.passes)) != pass_count
}

// (Re)create all offscreen targets; same order and error messages as the
// original inline block. Returns false on the first failure.
targets_resize :: proc(t: ^Render_Targets, gpu_device: ^sdl.GPUDevice, width, height, pass_count: i32) -> bool {
	if t.scene != nil do sdl.ReleaseGPUTexture(gpu_device, t.scene)
	t.scene = create_scene_target(gpu_device, width, height)
	if t.scene == nil {
		log.errorf("failed to create scene texture %dx%d: %s", width, height, sdl.GetError())
		return false
	}
	for pass_target in t.passes do if pass_target != nil do sdl.ReleaseGPUTexture(gpu_device, pass_target)
	clear(&t.passes)
	for _ in 0 ..< pass_count {
		pass_target := create_scene_target(gpu_device, width, height)
		if pass_target == nil {
			log.errorf("failed to create pass texture %dx%d: %s", width, height, sdl.GetError())
			return false
		}
		append(&t.passes, pass_target)
	}
	for preview_target in t.previews do if preview_target != nil do sdl.ReleaseGPUTexture(gpu_device, preview_target)
	clear(&t.previews)
	for _ in 0 ..< pass_count + 1 {
		preview_target := sdl.CreateGPUTexture(
			gpu_device,
			{
				type = .D2,
				format = .R8G8B8A8_UNORM,
				usage = {.SAMPLER, .COLOR_TARGET},
				width = PREVIEW_SIZE,
				height = PREVIEW_SIZE,
				layer_count_or_depth = 1,
				num_levels = 1,
			},
		)
		if preview_target == nil {
			log.errorf("failed to create preview texture %dx%d: %s", PREVIEW_SIZE, PREVIEW_SIZE, sdl.GetError())
			return false
		}
		append(&t.previews, preview_target)
	}
	if t.depth != nil do sdl.ReleaseGPUTexture(gpu_device, t.depth)
	t.depth = sdl.CreateGPUTexture(
		gpu_device,
		{
			type = .D2,
			format = .D32_FLOAT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = u32(width),
			height = u32(height),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	if t.depth == nil {
		log.errorf("failed to create depth texture %dx%d: %s", width, height, sdl.GetError())
		return false
	}
	t.w, t.h = width, height
	return true
}

// Explicit teardown; DestroyGPUDevice covers anything left.
targets_destroy :: proc(gpu_device: ^sdl.GPUDevice, t: ^Render_Targets) {
	if t.scene != nil do sdl.ReleaseGPUTexture(gpu_device, t.scene)
	if t.depth != nil do sdl.ReleaseGPUTexture(gpu_device, t.depth)
	for pass_target in t.passes do if pass_target != nil do sdl.ReleaseGPUTexture(gpu_device, pass_target)
	for preview_target in t.previews do if preview_target != nil do sdl.ReleaseGPUTexture(gpu_device, preview_target)
}
