// Shared runtime assets: paper textures (scene default binding + fx grain),
// equirectangular skyboxes, the model library (cgltf + generated icosphere
// fallback) and the black fallback. Direct port of src/assets.odin +
// src/model.odin. Textures/buffers live in the gfx pool; this module owns
// only the arrays + sampler.
#pragma once

#include "gfx.hpp"

#include <string>
#include <vector>

namespace assets {

constexpr uint32_t MODEL_PITCH = 32;   // float3 pos + float3 nrm + float2 uv
constexpr uint32_t MODEL_OFF_POS = 0;
constexpr uint32_t MODEL_OFF_NRM = 12;
constexpr uint32_t MODEL_OFF_UV = 24;

struct Model {
    SDL_GPUBuffer* vb = nullptr;
    SDL_GPUBuffer* ib = nullptr;
    gfx::Buffer_Handle vb_handle;
    gfx::Buffer_Handle ib_handle;
    uint32_t index_count = 0;
    std::string name;   // UI label (filename or "icosphere")
    std::string source; // file path or generator note
    gfx::Texture_Handle base_color_texture_handle;  // RGBA basecolor from GLB; fallback to black
    SDL_GPUTexture* base_color_texture = nullptr;   // GPU texture pointer (for shader binding)
    SDL_GPUSampler* texture_sampler = nullptr;
};

struct Assets {
    gfx::Texture_Handle paper_textures[2];
    SDL_GPUSampler* paper_sampler = nullptr;
    std::vector<std::string> skybox_names;
    std::vector<gfx::Texture_Handle> skybox_textures;
    gfx::Texture_Handle black_texture;
    std::vector<Model> models;
};

// Loads everything the app shares across scenes. Returns false only on hard
// failures (paper textures and the model set are required; a bad skybox is
// skipped with a warn).
bool load(Assets& out, gfx::Gfx& gfx);

void destroy(gfx::Gfx& gfx, Assets& a);

// Loads one image file (stb_image) into an R8G8B8A8 SAMPLER texture.
gfx::Texture_Handle load_texture(gfx::Gfx& gfx, const std::string& path, bool& ok);

// Loads one .glb/.gltf (POSITION/NORMAL/TEXCOORD_0 interleaved, normalized
// to the unit sphere) plus its buffers. Model.name is NOT set here.
bool load_gltf(gfx::Gfx& gfx, const std::string& path, Model& out);

} // namespace assets
