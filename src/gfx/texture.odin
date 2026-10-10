package gfx

import sdl "vendor:sdl3"

Texture :: struct {
	handle:        ^sdl.GPUTexture,
	format:        sdl.GPUTextureFormat,
	usage:         sdl.GPUTextureUsageFlags,
	width, height: u32,
	_staging_data: []byte,
}

gfx_texture_create :: proc(
	gfx: ^Gfx,
	width, height: u32,
	format: sdl.GPUTextureFormat,
	usage: sdl.GPUTextureUsageFlag,
) -> Texture_Handle {
	return gfx_texture_create_with_usage(gfx, width, height, format, {usage})
}

gfx_texture_create_with_usage :: proc(
	gfx: ^Gfx,
	width, height: u32,
	format: sdl.GPUTextureFormat,
	usage: sdl.GPUTextureUsageFlags,
) -> Texture_Handle {
	resource := Texture {
		handle = sdl.CreateGPUTexture(
			gfx.gpu,
			{
				format = format,
				usage = usage,
				width = width,
				height = height,
				layer_count_or_depth = 1,
				num_levels = 1,
			},
		),
		format = format,
		usage  = usage,
		width  = width,
		height = height,
	}
	assert(resource.handle != nil)
	handle := Texture_Handle(handle_pool_acquire(&gfx.texture_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.textures) {
		append(&gfx.textures, resource)
	} else {
		gfx.textures[index] = resource
	}
	return handle
}

gfx_texture_get :: proc(gfx: ^Gfx, handle: Texture_Handle) -> ^Texture {
	raw_handle := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.texture_handles, raw_handle), "stale texture handle")
	return &gfx.textures[raw_handle.index]
}

// Reallocates a texture at a new size, preserving format and usage. Waits
// for GPU idle so the old texture can be released safely mid-session; call
// between frames, not inside a pass. Returns true when it recreated.
gfx_texture_resize :: proc(gfx: ^Gfx, handle: ^Texture_Handle, width, height: u32) -> bool {
	if width == 0 || height == 0 do return false
	texture := gfx_texture_get(gfx, handle^)
	if texture.width == width && texture.height == height do return false
	kept_format := texture.format
	kept_usage := texture.usage
	_ = sdl.WaitForGPUIdle(gfx.gpu)
	gfx_texture_destroy(gfx, handle^)
	handle^ = gfx_texture_create_with_usage(gfx, width, height, kept_format, kept_usage)
	return true
}

gfx_texture_destroy :: proc(gfx: ^Gfx, handle: Texture_Handle) {
	raw_handle := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.texture_handles, raw_handle) do return
	resource := &gfx.textures[raw_handle.index]
	if resource.handle != nil do sdl.ReleaseGPUTexture(gfx.gpu, resource.handle)
	delete(resource._staging_data)
	resource^ = {}
	assert(handle_pool_release(&gfx.texture_handles, raw_handle))
}
