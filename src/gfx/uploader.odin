package gfx

import "core:mem"
import sdl "vendor:sdl3"

// Per-frame upload/download queue. Each frame: uploader_begin, record
// transfers (upload_* / download_*_begin), then uploader_flush (async) or
// uploader_flush_blocking. Pending stagings retire through uploader_collect,
// which must be called once per frame.
Uploader :: struct {
	gfx: ^Gfx,

	// Stagings whose fence has completed, ready for reuse.
	free: [dynamic]Staging,

	// Stagings still owned by in-flight GPU submits.
	pending: [dynamic]Staging,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass:           ^sdl.GPUCopyPass,
}

// A transfer buffer tracked through the GPU fence lifecycle: acquired for a
// transfer, kept in `pending` until its submit completes, then recycled.
// Carries the owning device so staging_read can map without the uploader,
// and its usage so released stagings are only reused for the same direction.
Staging :: struct {
	buffer: ^sdl.GPUTransferBuffer,
	size:   u32,
	device: ^sdl.GPUDevice,
	usage:  sdl.GPUTransferBufferUsage,

	// Nil until the submit that consumed this buffer.
	fence: ^sdl.GPUFence,
}

uploader_begin :: proc(uploader: ^Uploader) {
	assert(uploader.pass == nil)
	uploader.command_buffer = sdl.AcquireGPUCommandBuffer(uploader.gfx.gpu)
	uploader.pass = sdl.BeginGPUCopyPass(uploader.command_buffer)
}

// Queues a copy of the buffer's staged CPU data to the GPU. The transfer
// lands when the frame's uploader_flush submits the command buffer.
uploader_upload_buffer :: proc(uploader: ^Uploader, handle: Buffer_Handle) {
	destination := gfx_buffer_get(uploader.gfx, handle)
	staged_bytes := destination._staging_data
	staging := uploader_acquire_staging(uploader, u32(len(staged_bytes)))

	mapped_bytes := sdl.MapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer, false)
	mem.copy(mapped_bytes, raw_data(staged_bytes), len(staged_bytes))
	sdl.UnmapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer)

	sdl.UploadToGPUBuffer(
		uploader.pass,
		{transfer_buffer = staging.buffer},
		{buffer = destination.handle, size = u32(len(staged_bytes))},
		false,
	)
	destination._data_submitted = true

	append(&uploader.pending, staging)
}

// Queues a copy of the texture's staged CPU data to the GPU. The transfer
// lands when the frame's uploader_flush submits the command buffer.
uploader_upload_texture :: proc(uploader: ^Uploader, handle: Texture_Handle) {
	destination := gfx_texture_get(uploader.gfx, handle)
	staged_bytes := destination._staging_data
	staging := uploader_acquire_staging(uploader, u32(len(staged_bytes)))

	mapped_bytes := sdl.MapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer, false)
	mem.copy(mapped_bytes, raw_data(staged_bytes), len(staged_bytes))
	sdl.UnmapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer)

	sdl.UploadToGPUTexture(
		uploader.pass,
		{transfer_buffer = staging.buffer},
		{texture = destination.handle, w = destination.width, h = destination.height, d = 1},
		false,
	)

	append(&uploader.pending, staging)
}

// Submits the frame's copy pass. Every staging recorded this frame is bound
// to the submitted fence at once; collect() retires them as the fence
// completes. Fixed from the cubes version, which appended into up.pending
// while iterating it (mutating the slice under the loop, doubling entries).
uploader_flush :: proc(up: ^Uploader) {
	sdl.EndGPUCopyPass(up.pass)
	frame_fence := sdl.SubmitGPUCommandBufferAndAcquireFence(up.command_buffer)
	flushed := make([dynamic]Staging, 0, len(up.pending))
	for &staging in up.pending {
		staging.fence = frame_fence
		append(&flushed, staging)
	}
	append(&up.pending, ..flushed[:])
	delete(flushed)
	up.pass, up.command_buffer = nil, nil
}

uploader_flush_blocking :: proc(up: ^Uploader) {
	sdl.EndGPUCopyPass(up.pass)
	frame_fence := sdl.SubmitGPUCommandBufferAndAcquireFence(up.command_buffer)
	frame_fences := [1]^sdl.GPUFence{frame_fence}
	succeeded := sdl.WaitForGPUFences(up.gfx.gpu, true, &frame_fences[0], 1); assert(succeeded)
	sdl.ReleaseGPUFence(up.gfx.gpu, frame_fence)
	for &staging in up.pending {
		staging.fence = nil
		append(&up.free, staging)
	}
	clear(&up.pending)
	up.pass, up.command_buffer = nil, nil
}

// Retires pending stagings whose fences have completed. Call once per frame.
uploader_collect :: proc(up: ^Uploader) {
	for index := len(up.pending) - 1; index >= 0; index -= 1 {
		staging := up.pending[index]
		if !sdl.QueryGPUFence(up.gfx.gpu, staging.fence) do continue
		sdl.ReleaseGPUFence(up.gfx.gpu, staging.fence)
		staging.fence = nil
		append(&up.free, staging)
		unordered_remove(&up.pending, index)
	}
}

// Begins an asynchronous GPU -> CPU download of `byte_size` bytes from
// `source`. The data is not readable until staging_ready returns true; read
// it with staging_read, then return the staging with staging_release.
// Starts its own command buffer/copy pass when the uploader is idle, so it
// can be called outside the uploader_begin/flush window.
uploader_download_buffer_begin :: proc(
	up: ^Uploader,
	source: ^sdl.GPUBuffer,
	byte_size: u32,
) -> Staging {
	staging := uploader_acquire_download_staging(up, byte_size)
	staging.device = up.gfx.gpu

	owns_pass := up.pass == nil
	if owns_pass {
		up.command_buffer = sdl.AcquireGPUCommandBuffer(up.gfx.gpu)
		up.pass = sdl.BeginGPUCopyPass(up.command_buffer)
	}

	sdl.DownloadFromGPUBuffer(
		up.pass,
		{buffer = source, offset = 0, size = byte_size},
		{transfer_buffer = staging.buffer, offset = 0},
	)

	if owns_pass {
		sdl.EndGPUCopyPass(up.pass)
		frame_fence := sdl.SubmitGPUCommandBufferAndAcquireFence(up.command_buffer)
		assert(frame_fence != nil)
		staging.fence = frame_fence
		append(&up.pending, staging)
		up.pass, up.command_buffer = nil, nil
	} else {
		append(&up.pending, staging)
	}
	return staging
}

// Begins an asynchronous GPU -> CPU download of a full texture. Reads back
// tightly packed RGBA rows; the transfer buffer is sized for the whole
// region. Same pass/fence lifecycle as uploader_download_buffer_begin.
uploader_download_texture_begin :: proc(
	up: ^Uploader,
	source: ^sdl.GPUTexture,
	width, height: u32,
) -> Staging {
	// Scene/pass targets are raw SDL textures outside the pool; their
	// scene format is always R8G8B8A8_UNORM, so size those downloads from
	// the texel block size directly. Pooled textures use their stored
	// format.
	byte_size := u32(4) * width * height
	if texture_resource := uploader_texture_format_or_nil(up, source); texture_resource != nil {
		byte_size = sdl.GPUTextureFormatTexelBlockSize(texture_resource.format) * width * height
	}
	staging := uploader_acquire_download_staging(up, byte_size)
	staging.device = up.gfx.gpu

	owns_pass := up.pass == nil
	if owns_pass {
		up.command_buffer = sdl.AcquireGPUCommandBuffer(up.gfx.gpu)
		up.pass = sdl.BeginGPUCopyPass(up.command_buffer)
	}

	sdl.DownloadFromGPUTexture(
		up.pass,
		{texture = source, w = width, h = height, d = 1},
		{transfer_buffer = staging.buffer},
	)

	if owns_pass {
		sdl.EndGPUCopyPass(up.pass)
		frame_fence := sdl.SubmitGPUCommandBufferAndAcquireFence(up.command_buffer)
		assert(frame_fence != nil)
		staging.fence = frame_fence
		append(&up.pending, staging)
		up.pass, up.command_buffer = nil, nil
	} else {
		append(&up.pending, staging)
	}
	return staging
}

// As uploader_download_texture_begin, for an (x, y)-offset sub-region — the
// pixel inspector reads a single 1x1 pixel this way. Sizes the transfer
// buffer for the region; rows are tightly packed.
uploader_download_texture_region_begin :: proc(
	up: ^Uploader,
	source: ^sdl.GPUTexture,
	x, y: i32,
	width, height: u32,
) -> Staging {
	texture_resource := uploader_texture_format_or_nil(up, source)
	texel_size := u32(4)
	if texture_resource != nil {
		texel_size = sdl.GPUTextureFormatTexelBlockSize(texture_resource.format)
	}
	byte_size := texel_size * width * height
	staging := uploader_acquire_download_staging(up, byte_size)
	staging.device = up.gfx.gpu

	owns_pass := up.pass == nil
	if owns_pass {
		up.command_buffer = sdl.AcquireGPUCommandBuffer(up.gfx.gpu)
		up.pass = sdl.BeginGPUCopyPass(up.command_buffer)
	}

	sdl.DownloadFromGPUTexture(
		up.pass,
		{texture = source, x = u32(x), y = u32(y), z = 0, w = width, h = height, d = 1},
		{transfer_buffer = staging.buffer, offset = 0, pixels_per_row = width, rows_per_layer = height},
	)

	if owns_pass {
		sdl.EndGPUCopyPass(up.pass)
		frame_fence := sdl.SubmitGPUCommandBufferAndAcquireFence(up.command_buffer)
		assert(frame_fence != nil)
		staging.fence = frame_fence
		append(&up.pending, staging)
		up.pass, up.command_buffer = nil, nil
	} else {
		append(&up.pending, staging)
	}
	return staging
}

// True once the GPU has finished the submit carrying this staging's copy.
staging_ready :: proc(up: ^Uploader, staging: Staging) -> bool {
	assert(staging.fence != nil, "staging has no pending fence")
	return sdl.QueryGPUFence(up.gfx.gpu, staging.fence)
}

// Maps the staging's transfer buffer for CPU reads. Valid only after
// staging_ready returned true. The slice stays valid until staging_release.
staging_read :: proc(staging: Staging) -> []byte {
	assert(staging.fence != nil, "staging has no pending fence")
	mapped_bytes := sdl.MapGPUTransferBuffer(staging.device, staging.buffer, false)
	return mem.byte_slice(mapped_bytes, int(staging.size))
}

// Unmaps the transfer buffer, releases the fence and returns the staging to
// the free list for reuse by later transfers. Also drops it from pending:
// a released staging is no longer owed a collect.
staging_release :: proc(up: ^Uploader, staging: Staging) {
	assert(staging.fence != nil, "staging has no pending fence")
	for pending_index in 0 ..< len(up.pending) {
		if up.pending[pending_index].buffer == staging.buffer {
			unordered_remove(&up.pending, pending_index)
			break
		}
	}
	sdl.UnmapGPUTransferBuffer(up.gfx.gpu, staging.buffer)
	sdl.ReleaseGPUFence(up.gfx.gpu, staging.fence)
	released := staging
	released.fence = nil
	append(&up.free, released)
}

uploader_acquire_staging :: proc(uploader: ^Uploader, size: u32) -> Staging {
	for staging, index in uploader.free {
		if staging.usage != .UPLOAD || staging.size < size do continue
		unordered_remove(&uploader.free, index)
		return staging
	}
	return Staging {
		buffer = sdl.CreateGPUTransferBuffer(uploader.gfx.gpu, {usage = .UPLOAD, size = size}),
		size = size,
		device = uploader.gfx.gpu,
		usage = .UPLOAD,
	}
}

// Downloads need DOWNLOAD usage transfer buffers, which cannot be reused for
// uploads; they return to the same free list but are only handed back to
// download requests of at least the same size.
uploader_acquire_download_staging :: proc(uploader: ^Uploader, size: u32) -> Staging {
	for staging, index in uploader.free {
		if staging.usage != .DOWNLOAD || staging.size < size do continue
		unordered_remove(&uploader.free, index)
		return staging
	}
	return Staging {
		buffer = sdl.CreateGPUTransferBuffer(uploader.gfx.gpu, {usage = .DOWNLOAD, size = size}),
		size = size,
		device = uploader.gfx.gpu,
		usage = .DOWNLOAD,
	}
}

uploader_destroy :: proc(up: ^Uploader) {
	assert(up.pass == nil)
	assert(up.command_buffer == nil)
	assert(len(up.pending) == 0)

	for staging in up.free {
		assert(staging.fence == nil)
		if staging.buffer != nil {
			sdl.ReleaseGPUTransferBuffer(up.gfx.gpu, staging.buffer)
		}
	}

	delete(up.free)
	delete(up.pending)
	up^ = {}
}

// Finds the pooled Texture whose GPU texture is `source`, so texture
// downloads can size the transfer buffer from the stored format.
uploader_texture_format :: proc(up: ^Uploader, source: ^sdl.GPUTexture) -> ^Texture {
	for index := 0; index < len(up.gfx.textures); index += 1 {
		if !up.gfx.texture_handles.slots[index].alive do continue
		if up.gfx.textures[index].handle != source do continue
		raw := Resource_Handle{index = u32(index), generation = up.gfx.texture_handles.slots[index].generation}
		return gfx_texture_get(up.gfx, Texture_Handle(raw))
	}
	panic("download texture not owned by gfx texture pool")
}

// As uploader_texture_format, but returns nil when `source` is not a
// pooled texture (raw scene/pass targets download as plain RGBA).
uploader_texture_format_or_nil :: proc(up: ^Uploader, source: ^sdl.GPUTexture) -> ^Texture {
	for index := 0; index < len(up.gfx.textures); index += 1 {
		if !up.gfx.texture_handles.slots[index].alive do continue
		if up.gfx.textures[index].handle != source do continue
		raw := Resource_Handle{index = u32(index), generation = up.gfx.texture_handles.slots[index].generation}
		return gfx_texture_get(up.gfx, Texture_Handle(raw))
	}
	return nil
}
