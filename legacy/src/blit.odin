package main

// Blit: the only graphics pipelines besides the UI overlay. One pipeline
// presents the scene texture fullscreen (2D), a develop variant takes over
// during scene transitions, and a 3D variant draws the heightfield view
// with depth testing. Preview blit downsamples pass outputs for the node
// graph's thumbnails.

import goose "../../vendor/goose/src"
import shader_glue "./generated"
import "core:log"
import "core:math/linalg"
import sdl "vendor:sdl3"

create_shader :: proc(
	gpu_device: ^sdl.GPUDevice,
	glue: goose.GraphicsParameters,
	stage: sdl.GPUShaderStage,
) -> ^sdl.GPUShader {
	shader := sdl.CreateGPUShader(
		gpu_device,
		{
			stage = stage,
			format = glue.code.platform == .Metal ? {.MSL} : {.SPIRV},
			code_size = glue.code.blob.size,
			code = glue.code.blob.data,
			entrypoint = glue.code.entrypoint,
			num_samplers = glue.resources.samplers,
			num_uniform_buffers = glue.resources.uniform_buffers,
			num_storage_buffers = glue.resources.storage_buffers,
			num_storage_textures = glue.resources.storage_textures,
		},
	)
	if shader == nil {
		log.errorf("failed to create shader %s", glue.code.name)
	}
	return shader
}

link_pipeline :: proc(
	gpu_device: ^sdl.GPUDevice,
	window: ^sdl.Window,
	vertex_shader, fragment_shader: ^sdl.GPUShader,
) -> ^sdl.GPUGraphicsPipeline {
	return link_pipeline_format(gpu_device, vertex_shader, fragment_shader, sdl.GetGPUSwapchainTextureFormat(gpu_device, window))
}

// Same fullscreen-triangle link, but targeting an explicit pixel format:
// the preview pipeline renders into R8G8B8A8 offscreen targets, not the
// swapchain.
link_pipeline_format :: proc(
	gpu_device: ^sdl.GPUDevice,
	vertex_shader, fragment_shader: ^sdl.GPUShader,
	format: sdl.GPUTextureFormat,
) -> ^sdl.GPUGraphicsPipeline {
	pipeline := sdl.CreateGPUGraphicsPipeline(
	gpu_device,
	{
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
		primitive_type = .TRIANGLELIST,
		// No vertex_input_state: positions come from SV_VertexID.
		target_info = {
			num_color_targets = 1,
			color_target_descriptions = &(sdl.GPUColorTargetDescription {
					format = format,
				}),
		},
	},
	)
	if pipeline == nil {
		log.error("failed to link graphics pipeline")
	}
	return pipeline
}

create_pipeline :: proc(
	gpu_device: ^sdl.GPUDevice,
	window: ^sdl.Window,
	vertex_glue: goose.GraphicsParameters,
	fragment_glue: goose.GraphicsParameters,
) -> ^sdl.GPUGraphicsPipeline {
	defer free_blob_if_hot(vertex_glue)
	defer free_blob_if_hot(fragment_glue)

	vertex_shader := create_shader(gpu_device, vertex_glue, .VERTEX)
	if vertex_shader == nil do return nil
	fragment_shader := create_shader(gpu_device, fragment_glue, .FRAGMENT)
	if fragment_shader == nil {
		sdl.ReleaseGPUShader(gpu_device, vertex_shader)
		return nil
	}

	pipeline := link_pipeline(gpu_device, window, vertex_shader, fragment_shader)
	sdl.ReleaseGPUShader(gpu_device, vertex_shader)
	sdl.ReleaseGPUShader(gpu_device, fragment_shader)
	return pipeline
}

Blit :: struct {
	pipeline:          ^sdl.GPUGraphicsPipeline,
	develop_pipeline:  ^sdl.GPUGraphicsPipeline,
	pipeline3d:        ^sdl.GPUGraphicsPipeline,
	sampler:           ^sdl.GPUSampler,
	preview_pipeline:  ^sdl.GPUGraphicsPipeline,
	preview_sampler:   ^sdl.GPUSampler,
}

blit_init :: proc(gpu_device: ^sdl.GPUDevice, window: ^sdl.Window) -> (b: Blit, ok: bool) {
	// Blit: the only graphics pipeline besides the UI overlay.
	b.pipeline = create_pipeline(
		gpu_device,
		window,
		shader_glue.blit_vertex(),
		shader_glue.blit_fragment(),
	)
	if b.pipeline == nil {
		log.error("failed to create blit pipeline")
		return b, false
	}

	// Develop: the darkroom transition (fx), a blit variant with its own
	// fragment uniforms; takes over the 2D blit for ~1s on scene switch.
	b.develop_pipeline = create_pipeline(
		gpu_device,
		window,
		shader_glue.develop_vertex(),
		shader_glue.develop_fragment(),
	)
	if b.develop_pipeline == nil {
		log.error("failed to create develop transition pipeline")
		return b, false
	}

	// 3D heightfield view of the same offscreen texture (button in UI).
	blit3d_vertex_glue := shader_glue.blit3d_vertex()
	blit3d_fragment_glue := shader_glue.blit3d_fragment()
	blit3d_vs := create_shader(gpu_device, blit3d_vertex_glue, .VERTEX)
	blit3d_fs := create_shader(gpu_device, blit3d_fragment_glue, .FRAGMENT)
	free_blob_if_hot(blit3d_vertex_glue)
	free_blob_if_hot(blit3d_fragment_glue)
	if blit3d_vs == nil || blit3d_fs == nil {
		if blit3d_vs != nil do sdl.ReleaseGPUShader(gpu_device, blit3d_vs)
		if blit3d_fs != nil do sdl.ReleaseGPUShader(gpu_device, blit3d_fs)
		log.error("failed to create blit3d shaders")
		return b, false
	}
	b.pipeline3d = sdl.CreateGPUGraphicsPipeline(
		gpu_device,
		{
			vertex_shader = blit3d_vs,
			fragment_shader = blit3d_fs,
			primitive_type = .TRIANGLELIST,
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(gpu_device, window),
					}),
				depth_stencil_format = .D32_FLOAT,
			},
			depth_stencil_state = {
				compare_op = .LESS,
				enable_depth_test = true,
				enable_depth_write = true,
			},
		},
	)
	sdl.ReleaseGPUShader(gpu_device, blit3d_vs)
	sdl.ReleaseGPUShader(gpu_device, blit3d_fs)
	if b.pipeline3d == nil {
		log.errorf("failed to create blit3d pipeline: %s", sdl.GetError())
		return b, false
	}
	b.sampler = sdl.CreateGPUSampler(
		gpu_device,
		{
			min_filter = .NEAREST,
			mag_filter = .NEAREST,
			mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	)
	if b.sampler == nil {
		log.errorf("failed to create blit sampler: %s", sdl.GetError())
		return b, false
	}

	// Preview blit: downsample every pass's output into small fixed-size
	// targets the node graph displays. Linear filtering avoids the
	// scintillation of sampling a full-res target with NEAREST.
	preview_vs := create_shader(gpu_device, shader_glue.blit_vertex(), .VERTEX)
	preview_fs := create_shader(gpu_device, shader_glue.blit_fragment(), .FRAGMENT)
	free_blob_if_hot(shader_glue.blit_vertex())
	free_blob_if_hot(shader_glue.blit_fragment())
	b.preview_pipeline = link_pipeline_format(gpu_device, preview_vs, preview_fs, .R8G8B8A8_UNORM)
	sdl.ReleaseGPUShader(gpu_device, preview_vs)
	sdl.ReleaseGPUShader(gpu_device, preview_fs)
	if b.preview_pipeline == nil {
		log.errorf("failed to create preview blit pipeline: %s", sdl.GetError())
		return b, false
	}
	b.preview_sampler = sdl.CreateGPUSampler(
		gpu_device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	)
	if b.preview_sampler == nil {
		log.errorf("failed to create preview sampler: %s", sdl.GetError())
		return b, false
	}
	return b, true
}

blit_destroy :: proc(gpu_device: ^sdl.GPUDevice, b: ^Blit) {
	if b.pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu_device, b.pipeline)
	if b.develop_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu_device, b.develop_pipeline)
	if b.pipeline3d != nil do sdl.ReleaseGPUGraphicsPipeline(gpu_device, b.pipeline3d)
	if b.preview_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu_device, b.preview_pipeline)
	if b.sampler != nil do sdl.ReleaseGPUSampler(gpu_device, b.sampler)
	if b.preview_sampler != nil do sdl.ReleaseGPUSampler(gpu_device, b.preview_sampler)
}

// Camera for the 3D heightfield blit: orbits the origin at the interaction
// angles; fov/near/far match the blit3d shader's expectations.
blit3d_camera :: proc(yaw, pitch, dist, aspect: f32) -> shader_glue.Blit3dVertexCamera {
	origin := [3]f32{0, 0.15, 0}
	cos_pitch := linalg.cos(pitch)
	sin_pitch := linalg.sin(pitch)
	camPos := [3]f32 {
		origin.x + dist * cos_pitch * linalg.sin(yaw),
		origin.y + dist * sin_pitch,
		origin.z + dist * cos_pitch * linalg.cos(yaw),
	}
	to_origin := [3]f32 {
		origin.x - camPos.x,
		origin.y - camPos.y,
		origin.z - camPos.z,
	}
	forward := linalg.normalize(to_origin)
	right := linalg.normalize(linalg.cross(forward, [3]f32{0, 1, 0}))
	up_vector := linalg.cross(right, forward)
	return shader_glue.Blit3dVertexCamera {
		camPos = camPos,
		aspect = aspect,
		fwd    = forward,
		fovTan = 0.577,
		right  = right,
		nearZ  = 0.1,
		up     = up_vector,
		farZ   = 30.0,
	}
}
