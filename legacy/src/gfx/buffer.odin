package gfx

import "core:slice"
import sdl "vendor:sdl3"

Buffer :: struct {
	handle:          ^sdl.GPUBuffer,
	length:          u32,
	size:            u32,
	usage:           sdl.GPUBufferUsageFlags,
	_staging_data:   []byte,
	_data_submitted: bool,
}

gfx_buffer_create_from_bytes :: proc(
	gfx: ^Gfx,
	data: []$T,
	usage: sdl.GPUBufferUsageFlag,
) -> Buffer_Handle {
	allocated_size := u32(len(data) * size_of(T))
	handle := gfx_buffer_create(gfx, allocated_size, usage)
	resource := gfx_buffer_get(gfx, handle)
	resource.length = u32(len(data))
	// The gfx owns the staged bytes: copy, never alias the caller's slice
	// (callers may free their buffers before the upload runs).
	resource._staging_data = make([]u8, len(data) * size_of(T))
	copy(resource._staging_data, slice.to_bytes(data))
	return handle
}

// Stages new contents for an existing buffer, reusing the GPU allocation
// when it is large enough. On growth the old buffer is released after a GPU
// idle wait, so it is safe to call between frames without a retire queue.
// The data is not on the GPU until the buffer goes through the Uploader.
gfx_buffer_stage :: proc(
	gfx: ^Gfx,
	handle: Buffer_Handle,
	data: []$T,
	usage: sdl.GPUBufferUsageFlag,
) -> Buffer_Handle {
	staged_size := u32(len(data) * size_of(T))
	resource := gfx_buffer_get(gfx, handle)
	if resource.size >= staged_size && resource.usage == {usage} {
		resource.length = u32(len(data))
		resource._staging_data = make([]u8, len(data) * size_of(T))
		copy(resource._staging_data, slice.to_bytes(data))
		resource._data_submitted = false
		return handle
	}
	succeeded := sdl.WaitForGPUIdle(gfx.gpu)
	assert(succeeded)
	gfx_buffer_destroy(gfx, handle)
	return gfx_buffer_create_from_bytes(gfx, data, usage)
}

gfx_buffer_create :: proc(gfx: ^Gfx, size: u32, usage: sdl.GPUBufferUsageFlag) -> Buffer_Handle {
	resource := Buffer {
		handle = sdl.CreateGPUBuffer(gfx.gpu, {usage = {usage}, size = size}),
		size   = size,
		usage  = {usage},
	}
	assert(resource.handle != nil)
	handle := Buffer_Handle(handle_pool_acquire(&gfx.buffer_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.buffers) {
		append(&gfx.buffers, resource)
	} else {
		gfx.buffers[index] = resource
	}
	return handle
}

gfx_buffer_get :: proc(gfx: ^Gfx, handle: Buffer_Handle) -> ^Buffer {
	raw_handle := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.buffer_handles, raw_handle), "stale buffer handle")
	return &gfx.buffers[raw_handle.index]
}

gfx_buffer_destroy :: proc(gfx: ^Gfx, handle: Buffer_Handle) {
	raw_handle := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.buffer_handles, raw_handle) do return
	resource := &gfx.buffers[raw_handle.index]
	if resource.handle != nil do sdl.ReleaseGPUBuffer(gfx.gpu, resource.handle)
	delete(resource._staging_data)
	resource^ = {}
	assert(handle_pool_release(&gfx.buffer_handles, raw_handle))
}
