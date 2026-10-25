// gfx: SDL3 GPU wrapper implementation. Direct port of src/gfx/*.odin.
#include "gfx.hpp"

namespace gfx {

bool gfx_create(Gfx& gfx, SDL_Window* window, int width, int height) {
    gfx.gpu = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, true, nullptr); // debug: validation on
    if (!gfx.gpu) return false;
    if (!SDL_ClaimWindowForGPUDevice(gfx.gpu, window)) {
        SDL_DestroyGPUDevice(gfx.gpu);
        gfx.gpu = nullptr;
        return false;
    }
    gfx.window_width = width;
    gfx.window_height = height;
    gfx.shader_format = SDL_GPU_SHADERFORMAT_MSL;
    gfx.swapchain_format = SDL_GetGPUSwapchainTextureFormat(gfx.gpu, window);
    gfx.uploader.gfx = &gfx;
    return true;
}

void gfx_destroy(Gfx& gfx) {
    assert(gfx.command_buffer == nullptr && !gfx.frame_open);
    for (uint32_t i = 0; i < gfx.sampler_handles.pool.size(); ++i)
        if (gfx.sampler_handles.pool[i].alive)
            gfx_sampler_destroy(gfx, Sampler_Handle{{i, gfx.sampler_handles.pool[i].generation}});
    for (uint32_t i = 0; i < gfx.texture_handles.pool.size(); ++i)
        if (gfx.texture_handles.pool[i].alive)
            gfx_texture_destroy(gfx, Texture_Handle{{i, gfx.texture_handles.pool[i].generation}});
    for (uint32_t i = 0; i < gfx.buffer_handles.pool.size(); ++i)
        if (gfx.buffer_handles.pool[i].alive)
            gfx_buffer_destroy(gfx, Buffer_Handle{{i, gfx.buffer_handles.pool[i].generation}});
    // Pending stagings: the device is about to die; release instead of
    // waiting on their fence.
    for (const Staging& s : gfx.uploader.pending) {
        if (s.fence) SDL_ReleaseGPUFence(gfx.gpu, s.fence);
        if (s.buffer) SDL_ReleaseGPUTransferBuffer(gfx.gpu, s.buffer);
    }
    gfx.uploader.free_stagings.clear();
    gfx.uploader.pending.clear();
    if (gfx.depth_texture) SDL_ReleaseGPUTexture(gfx.gpu, gfx.depth_texture);
    SDL_DestroyGPUDevice(gfx.gpu);
    gfx.gpu = nullptr;
}

bool gfx_begin_frame(Gfx& gfx, SDL_Window* window) {
    gfx.command_buffer = SDL_AcquireGPUCommandBuffer(gfx.gpu);
    assert(gfx.command_buffer);
    gfx.frame_open = true;
    // Non-blocking acquire: a nil swap (occluded window) skips the blit but
    // the frame's other work still runs; blocking variant can wait forever
    // when a foreign CAMetalLayer never presents.
    Uint32 sw = 0, sh = 0;
    SDL_AcquireGPUSwapchainTexture(gfx.command_buffer, window, &gfx.swapchain, &sw, &sh);
    return gfx.swapchain != nullptr;
}

void gfx_end_frame(Gfx& gfx) {
    assert(gfx.frame_open && gfx.command_buffer);
    SDL_SubmitGPUCommandBuffer(gfx.command_buffer);
    gfx.command_buffer = nullptr;
    gfx.swapchain = nullptr;
    gfx.frame_open = false;
}

float gfx_aspect_ratio(const Gfx& gfx) {
    return float(gfx.window_width) / float(gfx.window_height);
}

// ---- Buffers ----

Buffer_Handle gfx_buffer_create(Gfx& gfx, uint32_t size, SDL_GPUBufferUsageFlags usage) {
    SDL_GPUBufferCreateInfo ci{};
    ci.usage = usage;
    ci.size = size;
    Buffer resource;
    resource.handle = SDL_CreateGPUBuffer(gfx.gpu, &ci);
    assert(resource.handle);
    resource.size = size;
    resource.usage = usage;
    Buffer_Handle handle{{}};
    {
        Resource_Handle raw = gfx.buffer_handles.acquire();
        handle.index = raw.index;
        handle.generation = raw.generation;
    }
    if (handle.index == gfx.buffers.size()) gfx.buffers.push_back(resource);
    else gfx.buffers[handle.index] = resource;
    return handle;
}

Buffer_Handle gfx_buffer_create_from_bytes(Gfx& gfx, const void* data, size_t bytes,
                                           SDL_GPUBufferUsageFlags usage) {
    Buffer_Handle handle = gfx_buffer_create(gfx, uint32_t(bytes), usage);
    Buffer* resource = gfx_buffer_get(gfx, handle);
    resource->length = uint32_t(bytes);
    resource->staging_data.assign((const uint8_t*)data, (const uint8_t*)data + bytes);
    return handle;
}

Buffer_Handle gfx_buffer_stage(Gfx& gfx, Buffer_Handle handle, const void* data, size_t bytes,
                               SDL_GPUBufferUsageFlags usage) {
    Buffer* resource = gfx_buffer_get(gfx, handle);
    if (resource->size >= bytes && resource->usage == usage) {
        resource->length = uint32_t(bytes);
        resource->staging_data.assign((const uint8_t*)data, (const uint8_t*)data + bytes);
        resource->data_submitted = false;
        return handle;
    }
    SDL_WaitForGPUIdle(gfx.gpu);
    gfx_buffer_destroy(gfx, handle);
    return gfx_buffer_create_from_bytes(gfx, data, bytes, usage);
}

Buffer* gfx_buffer_get(Gfx& gfx, Buffer_Handle handle) {
    assert(gfx.buffer_handles.contains(handle) && "stale buffer handle");
    return &gfx.buffers[handle.index];
}

void gfx_buffer_destroy(Gfx& gfx, Buffer_Handle handle) {
    if (!gfx.buffer_handles.contains(handle)) return;
    Buffer& resource = gfx.buffers[handle.index];
    if (resource.handle) SDL_ReleaseGPUBuffer(gfx.gpu, resource.handle);
    resource = {};
    bool ok = gfx.buffer_handles.release(handle);
    assert(ok); (void)ok;
}

// ---- Textures ----

Texture_Handle gfx_texture_create(Gfx& gfx, uint32_t width, uint32_t height,
                                  SDL_GPUTextureFormat format,
                                  SDL_GPUTextureUsageFlags usage) {
    SDL_GPUTextureCreateInfo ci{};
    ci.type = SDL_GPU_TEXTURETYPE_2D;
    ci.format = format;
    ci.usage = usage;
    ci.width = width;
    ci.height = height;
    ci.layer_count_or_depth = 1;
    ci.num_levels = 1;
    Texture resource;
    resource.handle = SDL_CreateGPUTexture(gfx.gpu, &ci);
    assert(resource.handle);
    resource.format = format;
    resource.usage = usage;
    resource.width = width;
    resource.height = height;
    Texture_Handle handle{{}};
    {
        Resource_Handle raw = gfx.texture_handles.acquire();
        handle.index = raw.index;
        handle.generation = raw.generation;
    }
    if (handle.index == gfx.textures.size()) gfx.textures.push_back(resource);
    else gfx.textures[handle.index] = resource;
    return handle;
}

Texture* gfx_texture_get(Gfx& gfx, Texture_Handle handle) {
    assert(gfx.texture_handles.contains(handle) && "stale texture handle");
    return &gfx.textures[handle.index];
}

bool gfx_texture_resize(Gfx& gfx, Texture_Handle& handle, uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return false;
    Texture* texture = gfx_texture_get(gfx, handle);
    if (texture->width == width && texture->height == height) return false;
    SDL_GPUTextureFormat format = texture->format;
    SDL_GPUTextureUsageFlags usage = texture->usage;
    SDL_WaitForGPUIdle(gfx.gpu);
    gfx_texture_destroy(gfx, handle);
    handle = gfx_texture_create(gfx, width, height, format, usage);
    return true;
}

void gfx_texture_destroy(Gfx& gfx, Texture_Handle handle) {
    if (!gfx.texture_handles.contains(handle)) return;
    Texture& resource = gfx.textures[handle.index];
    if (resource.handle) SDL_ReleaseGPUTexture(gfx.gpu, resource.handle);
    resource = {};
    bool ok = gfx.texture_handles.release(handle);
    assert(ok); (void)ok;
}

// ---- Samplers ----

Sampler_Handle gfx_sampler_create(Gfx& gfx, const SDL_GPUSamplerCreateInfo& ci) {
    Sampler resource;
    resource.handle = SDL_CreateGPUSampler(gfx.gpu, &ci);
    assert(resource.handle);
    Sampler_Handle handle{{}};
    {
        Resource_Handle raw = gfx.sampler_handles.acquire();
        handle.index = raw.index;
        handle.generation = raw.generation;
    }
    if (handle.index == gfx.samplers.size()) gfx.samplers.push_back(resource);
    else gfx.samplers[handle.index] = resource;
    return handle;
}

Sampler* gfx_sampler_get(Gfx& gfx, Sampler_Handle handle) {
    assert(gfx.sampler_handles.contains(handle) && "stale sampler handle");
    return &gfx.samplers[handle.index];
}

void gfx_sampler_destroy(Gfx& gfx, Sampler_Handle handle) {
    if (!gfx.sampler_handles.contains(handle)) return;
    Sampler& resource = gfx.samplers[handle.index];
    if (resource.handle) SDL_ReleaseGPUSampler(gfx.gpu, resource.handle);
    resource = {};
    bool ok = gfx.sampler_handles.release(handle);
    assert(ok); (void)ok;
}

// ---- Uploader ----

void uploader_begin(Uploader& up) {
    assert(up.pass == nullptr);
    up.command_buffer = SDL_AcquireGPUCommandBuffer(up.gfx->gpu);
    up.pass = SDL_BeginGPUCopyPass(up.command_buffer);
}

static Staging uploader_acquire_staging(Uploader& up, uint32_t size,
                                        SDL_GPUTransferBufferUsage usage) {
    for (size_t i = 0; i < up.free_stagings.size(); ++i) {
        Staging& s = up.free_stagings[i];
        if (s.usage != usage || s.size < size) continue;
        Staging out = s;
        up.free_stagings.erase(up.free_stagings.begin() + long(i));
        return out;
    }
    SDL_GPUTransferBufferCreateInfo ci{};
    ci.usage = usage;
    ci.size = size;
    Staging out;
    out.buffer = SDL_CreateGPUTransferBuffer(up.gfx->gpu, &ci);
    out.size = size;
    out.device = up.gfx->gpu;
    out.usage = usage;
    return out;
}

void uploader_upload_buffer(Uploader& up, Buffer_Handle handle) {
    Buffer* destination = gfx_buffer_get(*up.gfx, handle);
    const std::vector<uint8_t>& bytes = destination->staging_data;
    Staging staging = uploader_acquire_staging(up, uint32_t(bytes.size()),
                                               SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD);
    void* mapped = SDL_MapGPUTransferBuffer(up.gfx->gpu, staging.buffer, false);
    std::memcpy(mapped, bytes.data(), bytes.size());
    SDL_UnmapGPUTransferBuffer(up.gfx->gpu, staging.buffer);
    SDL_GPUTransferBufferLocation src{staging.buffer, 0};
    SDL_GPUBufferRegion dst{destination->handle, 0, uint32_t(bytes.size())};
    SDL_UploadToGPUBuffer(up.pass, &src, &dst, false);
    destination->data_submitted = true;
    up.pending.push_back(staging);
}

void uploader_upload_texture(Uploader& up, Texture_Handle handle) {
    Texture* destination = gfx_texture_get(*up.gfx, handle);
    const std::vector<uint8_t>& bytes = destination->staging_data;
    Staging staging = uploader_acquire_staging(up, uint32_t(bytes.size()),
                                               SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD);
    void* mapped = SDL_MapGPUTransferBuffer(up.gfx->gpu, staging.buffer, false);
    std::memcpy(mapped, bytes.data(), bytes.size());
    SDL_UnmapGPUTransferBuffer(up.gfx->gpu, staging.buffer);
    SDL_GPUTextureTransferInfo src{staging.buffer, 0, destination->width, destination->height};
    SDL_GPUTextureRegion dst{destination->handle, 0, 0, 0, 0, 0, destination->width,
                             destination->height, 1};
    SDL_UploadToGPUTexture(up.pass, &src, &dst, false);
    up.pending.push_back(staging);
}

void uploader_flush(Uploader& up) {
    SDL_EndGPUCopyPass(up.pass);
    SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(up.command_buffer);
    for (Staging& s : up.pending) s.fence = fence;
    up.pass = nullptr;
    up.command_buffer = nullptr;
}

void uploader_flush_blocking(Uploader& up) {
    SDL_EndGPUCopyPass(up.pass);
    SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(up.command_buffer);
    SDL_GPUFence* fences[1] = {fence};
    SDL_WaitForGPUFences(up.gfx->gpu, true, fences, 1);
    SDL_ReleaseGPUFence(up.gfx->gpu, fence);
    for (Staging& s : up.pending) {
        s.fence = nullptr;
        up.free_stagings.push_back(s);
    }
    up.pending.clear();
    up.pass = nullptr;
    up.command_buffer = nullptr;
}

void uploader_collect(Uploader& up) {
    // uploader_flush shares one fence across every pending staging of a
    // submit: release it once and free all its stagings together.
    for (;;) {
        SDL_GPUFence* ready = nullptr;
        for (const Staging& s : up.pending)
            if (s.fence && SDL_QueryGPUFence(up.gfx->gpu, s.fence)) { ready = s.fence; break; }
        if (!ready) return;
        SDL_ReleaseGPUFence(up.gfx->gpu, ready);
        for (size_t j = 0; j < up.pending.size();) {
            if (up.pending[j].fence != ready) { ++j; continue; }
            up.pending[j].fence = nullptr;
            up.free_stagings.push_back(up.pending[j]);
            up.pending.erase(up.pending.begin() + long(j));
        }
    }
}

static Staging uploader_download_begin(Uploader& up, uint32_t byte_size, bool& owns_pass) {
    Staging staging = uploader_acquire_staging(up, byte_size, SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD);
    staging.device = up.gfx->gpu;
    owns_pass = up.pass == nullptr; // decide before opening: a shared pass belongs to its opener
    if (owns_pass) {
        up.command_buffer = SDL_AcquireGPUCommandBuffer(up.gfx->gpu);
        up.pass = SDL_BeginGPUCopyPass(up.command_buffer);
    }
    return staging;
}

static void uploader_download_end(Uploader& up, Staging& staging, bool owns_pass) {
    // staging is mutated (fence) and the CALLER's copy must see it: the
    // download_*_begin wrappers return the same Staging they passed here.
    if (owns_pass) {
        SDL_EndGPUCopyPass(up.pass);
        SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(up.command_buffer);
        assert(fence);
        staging.fence = fence;
        up.pending.push_back(staging);
        up.pass = nullptr;
        up.command_buffer = nullptr;
    } else {
        staging.fence = nullptr; // shared pass: the opener's submit covers it
        up.pending.push_back(staging);
    }
}

Staging uploader_download_texture_region_begin(Uploader& up, SDL_GPUTexture* source,
                                               int x, int y, uint32_t width, uint32_t height) {
    uint32_t byte_size = 4 * width * height;
    bool owns_pass = false;
    Staging staging = uploader_download_begin(up, byte_size, owns_pass);
    SDL_GPUTextureRegion src{source, 0, 0, uint32_t(x), uint32_t(y), 0, width, height, 1};
    SDL_GPUTextureTransferInfo dst{staging.buffer, 0, width, height};
    SDL_DownloadFromGPUTexture(up.pass, &src, &dst);
    uploader_download_end(up, staging, owns_pass);
    return staging;
}

Staging uploader_download_buffer_begin(Uploader& up, SDL_GPUBuffer* source, uint32_t byte_size) {
    bool owns_pass = false;
    Staging staging = uploader_download_begin(up, byte_size, owns_pass);
    SDL_GPUBufferRegion src{source, 0, byte_size};
    SDL_GPUTransferBufferLocation dst{staging.buffer, 0};
    SDL_DownloadFromGPUBuffer(up.pass, &src, &dst);
    uploader_download_end(up, staging, owns_pass);
    return staging;
}

bool staging_ready(Uploader& up, const Staging& s) {
    assert(s.fence && "staging has no pending fence");
    return SDL_QueryGPUFence(up.gfx->gpu, s.fence);
}

const uint8_t* staging_read(const Staging& s) {
    assert(s.fence && "staging has no pending fence");
    return (const uint8_t*)SDL_MapGPUTransferBuffer(s.device, s.buffer, false);
}

void staging_release(Uploader& up, Staging s) {
    assert(s.fence && "staging has no pending fence");
    for (size_t i = 0; i < up.pending.size(); ++i) {
        if (up.pending[i].buffer == s.buffer) {
            up.pending.erase(up.pending.begin() + long(i));
            break;
        }
    }
    SDL_UnmapGPUTransferBuffer(up.gfx->gpu, s.buffer);
    SDL_ReleaseGPUFence(up.gfx->gpu, s.fence);
    s.fence = nullptr;
    up.free_stagings.push_back(s);
}

} // namespace gfx
