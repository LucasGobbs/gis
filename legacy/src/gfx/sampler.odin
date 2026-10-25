package gfx

import sdl "vendor:sdl3"

Sampler :: struct {
	handle: ^sdl.GPUSampler,
}

gfx_sampler_create :: proc(
	gfx: ^Gfx,
	create_info := sdl.GPUSamplerCreateInfo{},
) -> Sampler_Handle {
	resource := Sampler {
		handle = sdl.CreateGPUSampler(gfx.gpu, create_info),
	}
	assert(resource.handle != nil)
	handle := Sampler_Handle(handle_pool_acquire(&gfx.sampler_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.samplers) {
		append(&gfx.samplers, resource)
	} else {
		gfx.samplers[index] = resource
	}
	return handle
}

gfx_sampler_get :: proc(gfx: ^Gfx, handle: Sampler_Handle) -> ^Sampler {
	raw_handle := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.sampler_handles, raw_handle), "stale sampler handle")
	return &gfx.samplers[raw_handle.index]
}

gfx_sampler_destroy :: proc(gfx: ^Gfx, handle: Sampler_Handle) {
	raw_handle := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.sampler_handles, raw_handle) do return
	resource := &gfx.samplers[raw_handle.index]
	if resource.handle != nil do sdl.ReleaseGPUSampler(gfx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx.sampler_handles, raw_handle))
}
