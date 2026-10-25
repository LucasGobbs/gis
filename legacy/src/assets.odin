package main

// Shared assets: scanned paper backgrounds (fx grain + scene param),
// equirectangular skyboxes, the black fallback texture, and the model
// library for model-viewer scenes. Textures live in the gfx pool — the
// Gfx teardown frees them; this module owns only the sampler and arrays.

import gfx "./gfx"
import "core:c"
import "core:mem"
import "core:log"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

// Loads an image file (stb_image) into a GPU texture with .SAMPLER usage.
load_texture :: proc(gfx_state: ^gfx.Gfx, path: string) -> (gfx.Texture_Handle, bool) {
	file_data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		log.errorf("failed to read %s: %v", path, read_err)
		return {}, false
	}
	image_w, image_h, channels: c.int
	pixels := stbi.load_from_memory(
		raw_data(file_data),
		c.int(len(file_data)),
		&image_w,
		&image_h,
		&channels,
		4, // force RGBA8
	)
	if pixels == nil {
		log.errorf("failed to decode %s: %s", path, stbi.failure_reason())
		return {}, false
	}
	defer stbi.image_free(pixels)

	pixel_bytes := mem.byte_slice(pixels, int(image_w) * int(image_h) * 4)
	texture := gfx.gfx_texture_create(
		gfx_state,
		u32(image_w),
		u32(image_h),
		.R8G8B8A8_UNORM,
		.SAMPLER,
	)
	resource := gfx.gfx_texture_get(gfx_state, texture)
	resource._staging_data = make([]u8, len(pixel_bytes))
	copy(resource._staging_data, pixel_bytes)
	gfx.uploader_begin(&gfx_state.uploader)
	gfx.uploader_upload_texture(&gfx_state.uploader, texture)
	gfx.uploader_flush_blocking(&gfx_state.uploader)
	resource._staging_data = nil
	return texture, true
}

create_black_texture :: proc(gfx_state: ^gfx.Gfx) -> gfx.Texture_Handle {
	black := gfx.gfx_texture_create(gfx_state, 1, 1, .R8G8B8A8_UNORM, .SAMPLER)
	resource := gfx.gfx_texture_get(gfx_state, black)
	resource._staging_data = []u8{0, 0, 0, 0}
	gfx.uploader_begin(&gfx_state.uploader)
	gfx.uploader_upload_texture(&gfx_state.uploader, black)
	gfx.uploader_flush_blocking(&gfx_state.uploader)
	resource._staging_data = nil
	return black
}

PAPER_PATHS :: [2]string{"assets/watercolor_paper.jpg", "assets/parchment.jpg"}

Assets :: struct {
	paper_textures:  [2]gfx.Texture_Handle,
	paper_sampler:   ^sdl.GPUSampler,
	skybox_names:    [dynamic]string,
	skybox_textures: [dynamic]gfx.Texture_Handle,
	black_texture:   gfx.Texture_Handle,
	models:          [dynamic]Model,
}

// Loads everything the app shares across scenes. Order and messages match
// the original inline block. Returns false only on hard failures (paper
// textures and models are required; a bad skybox is skipped with a warn).
assets_load :: proc(a: ^Assets, gfx_state: ^gfx.Gfx, gpu_device: ^sdl.GPUDevice) -> bool {
	// Scanned paper backgrounds (assets/), picked in the UI and bound to
	// the scene's compute pass.
	for path, i in PAPER_PATHS {
		loaded_ok: bool
		a.paper_textures[i], loaded_ok = load_texture(gfx_state, path)
		if !loaded_ok {
			log.errorf("required paper texture could not be loaded: %s", path)
			return false
		}
	}

	// Equirectangular skyboxes (assets/skybox/skybox-*.png), a global
	// option like the paper: scenes sampling skybox_tex get the pick.
	if entries, read_err := os.read_directory_by_path("assets/skybox", 0, context.temp_allocator);
	   read_err == nil {
		for entry in entries {
			lower := strings.to_lower(entry.name, context.temp_allocator)
			if !strings.has_suffix(lower, ".png") && !strings.has_suffix(lower, ".jpg") do continue
			name := entry.name
			if strings.has_prefix(name, "skybox-") do name = name[len("skybox-"):]
			dot_index := strings.last_index(name, ".")
			if dot_index > 0 do name = name[:dot_index]
			skybox_ok: bool
			texture: gfx.Texture_Handle
			texture, skybox_ok = load_texture(gfx_state, entry.fullpath)
			if !skybox_ok {
				log.warnf("skipping skybox that could not be loaded: %s", entry.fullpath)
				continue
			}
			append(&a.skybox_names, strings.clone(name))
			append(&a.skybox_textures, texture)
		}
	}
	a.black_texture = create_black_texture(gfx_state)

	// All models in assets/models (+ generated icosphere fallback) for
	// model-viewer scenes; picked in the UI "model" group.
	a.models = model_load_all(gfx_state)
	if len(a.models) == 0 || a.models[0].vb == nil {
		log.error("no usable model could be loaded or generated")
		return false
	}

	a.paper_sampler = sdl.CreateGPUSampler(
		gpu_device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .LINEAR,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	)
	if a.paper_sampler == nil {
		log.errorf("failed to create paper sampler: %s", sdl.GetError())
		return false
	}
	return true
}

assets_destroy :: proc(gpu_device: ^sdl.GPUDevice, a: ^Assets) {
	if a.paper_sampler != nil do sdl.ReleaseGPUSampler(gpu_device, a.paper_sampler)
	// Texture handles and models are pooled in gfx/model; their teardown
	// happens in gfx.destroy / model teardown.
}
