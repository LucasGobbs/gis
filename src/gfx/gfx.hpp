// gfx: SDL3 GPU wrapper with generation-checked handles, a fence-gated
// transfer queue, and a foreign-window variant (Qt NSView) for the Qt shell.
// Direct port of src/gfx/*.odin; same semantics, C++17 without Odin closures.
#pragma once

#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

namespace gfx {

// ---- Generation-checked handles (resource_handle.odin) ----

struct Resource_Handle {
    uint32_t index = 0;
    uint32_t generation = 0;
};

struct Buffer_Handle : Resource_Handle {};
struct Texture_Handle : Resource_Handle {};

struct Handle_Slot {
    uint32_t generation = 0;
    bool alive = false;
};

struct Handle_Pool {
    std::vector<Handle_Slot> pool;
    std::vector<uint32_t> free;

    Resource_Handle acquire() {
        if (!free.empty()) {
            uint32_t index = free.back();
            free.pop_back();
            Handle_Slot& slot = pool[index];
            assert(!slot.alive);
            slot.alive = true;
            return {index, slot.generation};
        }
        uint32_t index = uint32_t(pool.size());
        pool.push_back(Handle_Slot{1, true});
        return {index, 1};
    }
    bool contains(Resource_Handle h) const {
        if (h.generation == 0 || h.index >= pool.size()) return false;
        const Handle_Slot& slot = pool[h.index];
        return slot.alive && slot.generation == h.generation;
    }
    bool release(Resource_Handle h) {
        if (!contains(h)) return false;
        Handle_Slot& slot = pool[h.index];
        slot.alive = false;
        if (++slot.generation == 0) slot.generation = 1;
        free.push_back(h.index);
        return true;
    }
};

// ---- Resources (buffer/texture/sampler.odin) ----

struct Buffer {
    SDL_GPUBuffer* handle = nullptr;
    uint32_t size = 0;
    SDL_GPUBufferUsageFlags usage = 0;
    std::vector<uint8_t> staging_data;   // owned CPU copy, uploaded via Uploader
};

struct Texture {
    SDL_GPUTexture* handle = nullptr;
    SDL_GPUTextureFormat format = SDL_GPU_TEXTUREFORMAT_INVALID;
    SDL_GPUTextureUsageFlags usage = 0;
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> staging_data;
};


// ---- Uploader (uploader.odin): fence-gated staging recycle ----

struct Uploader;

struct Staging {
    SDL_GPUTransferBuffer* buffer = nullptr;
    uint32_t size = 0;
    SDL_GPUDevice* device = nullptr;
    SDL_GPUTransferBufferUsage usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    SDL_GPUFence* fence = nullptr;  // nil until the consuming submit
};

struct Gfx;

struct Uploader {
    Gfx* gfx = nullptr;
    std::vector<Staging> free_stagings;
    std::vector<Staging> pending;     // uploads in flight
    std::vector<Staging> downloads;   // readbacks owned by the caller until staging_release
    SDL_GPUCommandBuffer* command_buffer = nullptr;
    SDL_GPUCopyPass* pass = nullptr;
};

// ---- Gfx (gfx.odin) ----

struct Gfx {
    SDL_GPUDevice* gpu = nullptr;
    SDL_GPUTextureFormat swapchain_format = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;

    SDL_GPUCommandBuffer* command_buffer = nullptr;
    SDL_GPUTexture* swapchain = nullptr;
    bool frame_open = false;

    Handle_Pool buffer_handles, texture_handles;
    std::vector<Buffer> buffers;
    std::vector<Texture> textures;

    Uploader uploader;
};

// Lifecycle. Foreign window variant: Qt owns the NSWindow/NSView.
bool gfx_create(Gfx& gfx, SDL_Window* window, int width, int height);
void gfx_destroy(Gfx& gfx);

bool gfx_begin_frame(Gfx& gfx, SDL_Window* window); // false: no swapchain texture this frame
void gfx_end_frame(Gfx& gfx);

// Buffers.
Buffer_Handle gfx_buffer_create(Gfx& gfx, uint32_t size, SDL_GPUBufferUsageFlags usage);
Buffer_Handle gfx_buffer_create_from_bytes(Gfx& gfx, const void* data, size_t bytes,
                                           SDL_GPUBufferUsageFlags usage);
Buffer* gfx_buffer_get(Gfx& gfx, Buffer_Handle handle);
void gfx_buffer_destroy(Gfx& gfx, Buffer_Handle handle);

// Textures.
Texture_Handle gfx_texture_create(Gfx& gfx, uint32_t width, uint32_t height,
                                  SDL_GPUTextureFormat format,
                                  SDL_GPUTextureUsageFlags usage);
Texture* gfx_texture_get(Gfx& gfx, Texture_Handle handle);

void gfx_texture_destroy(Gfx& gfx, Texture_Handle handle);

// Uploader: begin -> record -> flush_blocking. Downloads are tracked separately
// and live until staging_release.
void uploader_begin(Uploader& up);
bool uploader_upload_buffer(Uploader& up, Buffer_Handle handle);   // false: staging alloc/map failed
bool uploader_upload_texture(Uploader& up, Texture_Handle handle);
void uploader_flush_blocking(Uploader& up);
Staging uploader_download_texture_region_begin(Uploader& up, SDL_GPUTexture* source,
                                               int x, int y, uint32_t width, uint32_t height);
Staging uploader_download_buffer_begin(Uploader& up, SDL_GPUBuffer* source, uint32_t byte_size);
bool staging_ready(Uploader& up, const Staging& s);
const uint8_t* staging_read(const Staging& s);
void staging_release(Uploader& up, Staging s);

} // namespace gfx
