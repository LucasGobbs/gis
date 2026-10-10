package gfx

import "core:c"
import "core:strings"
import sdl "vendor:sdl3"

Gfx :: struct {
	window:          ^sdl.Window,
	gpu:             ^sdl.GPUDevice,
	window_size:     [2]i32,
	shader_format:   sdl.GPUShaderFormat,
	swapchain_format: sdl.GPUTextureFormat,
	depth_texture:   ^sdl.GPUTexture,

	// Received via sdl.AcquireGPUCommandBuffer and released after
	// sdl.SubmitGPUCommandBuffer (short lived).
	command_buffer:  ^sdl.GPUCommandBuffer,
	swapchain:       ^sdl.GPUTexture,
	frame_open:      bool,

	// Native GPU resources are owned here. Public code carries
	// generation-checked handles.
	buffers:         [dynamic]Buffer,
	buffer_handles:  Handle_Pool,
	textures:        [dynamic]Texture,
	texture_handles: Handle_Pool,
	samplers:        [dynamic]Sampler,
	sampler_handles: Handle_Pool,

	// Asset transfer queue, owned and destroyed by Gfx: uploads from
	// staged CPU data and GPU->CPU downloads (readbacks). App code
	// records transfers through it; one per device.
	uploader:        Uploader,
}

create :: proc(
	gfx:        ^Gfx,
	window_title: string      = "Shader Explorer",
	window_width:  int        = 1280,
	window_height: int        = 780,
) -> bool {
	succeeded := sdl.Init(sdl.INIT_VIDEO); assert(succeeded)
	// Native window frame: the OS owns the title bar and its window
	// controls (traffic lights on macOS, min/max/close on Windows). The
	// app draws its toolbar below the frame (ui_chrome.ui_toolbar).
	main_window := sdl.CreateWindow(
		strings.clone_to_cstring(window_title, context.temp_allocator),
		c.int(window_width),
		c.int(window_height),
		{.RESIZABLE},
	); assert(main_window != nil)
	gpu_device := sdl.CreateGPUDevice({.MSL, .SPIRV}, true, nil); assert(gpu_device != nil)
	succeeded = sdl.ClaimWindowForGPUDevice(gpu_device, main_window); assert(succeeded)
	window_size: [2]i32
	succeeded = sdl.GetWindowSize(main_window, &window_size.x, &window_size.y); assert(succeeded)

	// Metal shaders on Darwin drivers, SPIR-V everywhere else.
	shader_format := sdl.GPUShaderFormat{.MSL}
	if !strings.starts_with(string(sdl.GetGPUDeviceDriver(gpu_device)), "metal") {
		shader_format = {.SPIRV}
	}
	assert(sdl.GetGPUShaderFormats(gpu_device) & shader_format == shader_format)

	depth_stencil := sdl.CreateGPUTexture(
		gpu_device,
		{
			format = .D32_FLOAT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = u32(window_size.x),
			height = u32(window_size.y),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	assert(depth_stencil != nil)

	gfx.window = main_window
	gfx.gpu = gpu_device
	gfx.window_size = window_size
	gfx.uploader.gfx = gfx
	return true
}

gfx_begin_frame :: proc(gfx: ^Gfx) -> bool {
	gfx.command_buffer = sdl.AcquireGPUCommandBuffer(gfx.gpu)
	assert(gfx.command_buffer != nil)
	gfx.frame_open = true
	succeeded := sdl.WaitAndAcquireGPUSwapchainTexture(
		gfx.command_buffer,
		gfx.window,
		&gfx.swapchain,
		nil,
		nil,
	); assert(succeeded)
	return gfx.swapchain != nil
}

gfx_end_frame :: proc(gfx: ^Gfx) {
	assert(gfx.frame_open && gfx.command_buffer != nil)
	succeeded := sdl.SubmitGPUCommandBuffer(gfx.command_buffer); assert(succeeded)
	gfx.command_buffer, gfx.swapchain, gfx.frame_open = nil, nil, false
}

// Present mode: .VSYNC (SDL default, caps FPS at display refresh),
// .IMMEDIATE (uncapped, may tear), .MAILBOX (uncapped without tearing where
// supported). Falls back to vsync when the driver rejects the mode.
gfx_set_present_mode :: proc(gfx: ^Gfx, mode: sdl.GPUPresentMode) {
	if sdl.WindowSupportsGPUPresentMode(gfx.gpu, gfx.window, mode) {
		_ = sdl.SetGPUSwapchainParameters(gfx.gpu, gfx.window, .SDR, mode)
	}
}

gfx_aspect_ratio :: proc(gfx: ^Gfx) -> f32 {
	return f32(gfx.window_size.x) / f32(gfx.window_size.y)
}


destroy :: proc(gfx: ^Gfx) {
	assert(gfx.command_buffer == nil)
	assert(!gfx.frame_open)
	for slot, index in gfx.sampler_handles.slots {
		if slot.alive do gfx_sampler_destroy(gfx, Sampler_Handle(Resource_Handle{index = u32(index), generation = slot.generation}))
	}
	for slot, index in gfx.texture_handles.slots {
		if slot.alive do gfx_texture_destroy(gfx, Texture_Handle(Resource_Handle{index = u32(index), generation = slot.generation}))
	}
	for slot, index in gfx.buffer_handles.slots {
		if slot.alive do gfx_buffer_destroy(gfx, Buffer_Handle(Resource_Handle{index = u32(index), generation = slot.generation}))
	}
	delete(gfx.samplers)
	delete(gfx.textures)
	delete(gfx.buffers)
	handle_pool_destroy(&gfx.sampler_handles)
	handle_pool_destroy(&gfx.texture_handles)
	handle_pool_destroy(&gfx.buffer_handles)
	uploader_destroy(&gfx.uploader)

	if gfx.depth_texture != nil {
		sdl.ReleaseGPUTexture(gfx.gpu, gfx.depth_texture)
	}
	if gfx.gpu != nil && gfx.window != nil {
		sdl.ReleaseWindowFromGPUDevice(gfx.gpu, gfx.window)
	}
	if gfx.gpu != nil {
		sdl.DestroyGPUDevice(gfx.gpu)
	}
	if gfx.window != nil {
		sdl.DestroyWindow(gfx.window)
	}

	sdl.Quit()
	gfx^ = {}
}
