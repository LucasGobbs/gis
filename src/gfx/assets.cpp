// Assets implementation: stb_image textures, cgltf models, icosphere
// fallback. Same load order/messages as src/assets.odin + src/model.odin.
#include "assets.hpp"

#include <SDL3/SDL.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dirent.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-align"
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#pragma clang diagnostic pop

namespace assets {

static bool has_suffix_lower(const std::string& s, const char* suffix) {
    size_t n = std::strlen(suffix);
    if (s.size() < n) return false;
    for (size_t i = 0; i < n; ++i)
        if (std::tolower((unsigned char)s[s.size() - n + i]) != suffix[i]) return false;
    return true;
}

gfx::Texture_Handle load_texture(gfx::Gfx& gfx, const std::string& path, bool& ok) {
    ok = false;
    int w = 0, h = 0, channels = 0;
    stbi_uc* pixels = stbi_load(path.c_str(), &w, &h, &channels, 4);
    if (!pixels) {
        std::fprintf(stderr, "assets: failed to load %s\n", path.c_str());
        return gfx::Texture_Handle{};
    }
    size_t bytes = size_t(w) * size_t(h) * 4;
    gfx::Texture_Handle handle =
        gfx::gfx_texture_create(gfx, uint32_t(w), uint32_t(h),
                                SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                                SDL_GPU_TEXTUREUSAGE_SAMPLER);
    if (!gfx.texture_handles.contains(handle)) { // defensive; create asserts
        stbi_image_free(pixels);
        return handle;
    }
    gfx::Texture* resource = gfx::gfx_texture_get(gfx, handle);
    resource->staging_data.assign(pixels, pixels + bytes);
    stbi_image_free(pixels);
    gfx::uploader_begin(gfx.uploader);
    gfx::uploader_upload_texture(gfx.uploader, handle);
    gfx::uploader_flush_blocking(gfx.uploader);
    resource->staging_data.clear();
    resource->staging_data.shrink_to_fit();
    ok = true;
    return handle;
}

// Recenters/rescales interleaved vertices so the model fits the unit sphere.
static void model_normalize_bounds(std::vector<uint8_t>& vertices) {
    size_t n = vertices.size() / MODEL_PITCH;
    if (n == 0) return;
    float min_v[3] = {1e30f, 1e30f, 1e30f};
    float max_v[3] = {-1e30f, -1e30f, -1e30f};
    for (size_t i = 0; i < n; ++i) {
        const float* p = reinterpret_cast<const float*>(&vertices[i * MODEL_PITCH]);
        for (int c = 0; c < 3; ++c) {
            min_v[c] = std::min(min_v[c], p[c]);
            max_v[c] = std::max(max_v[c], p[c]);
        }
    }
    float center[3];
    for (int c = 0; c < 3; ++c) center[c] = (min_v[c] + max_v[c]) * 0.5f;
    float max_r = 1e-30f;
    for (size_t i = 0; i < n; ++i) {
        const float* p = reinterpret_cast<const float*>(&vertices[i * MODEL_PITCH]);
        float dx = p[0] - center[0], dy = p[1] - center[1], dz = p[2] - center[2];
        max_r = std::max(max_r, dx * dx + dy * dy + dz * dz);
    }
    float scale = 1.0f / std::sqrt(max_r);
    for (size_t i = 0; i < n; ++i) {
        float* p = reinterpret_cast<float*>(&vertices[i * MODEL_PITCH]);
        for (int c = 0; c < 3; ++c) p[c] = (p[c] - center[c]) * scale;
    }
}

static Model model_upload(gfx::Gfx& gfx, std::vector<uint8_t>& vertices,
                          std::vector<uint32_t>& indices, const char* source) {
    Model model;
    model.source = source;
    model.index_count = uint32_t(indices.size());
    model.vb_handle = gfx::gfx_buffer_create_from_bytes(
        gfx, vertices.data(), vertices.size(), SDL_GPU_BUFFERUSAGE_VERTEX);
    model.ib_handle = gfx::gfx_buffer_create_from_bytes(
        gfx, indices.data(), indices.size() * 4, SDL_GPU_BUFFERUSAGE_INDEX);
    // One copy pass carries both transfers.
    gfx::uploader_begin(gfx.uploader);
    gfx::uploader_upload_buffer(gfx.uploader, model.vb_handle);
    gfx::uploader_upload_buffer(gfx.uploader, model.ib_handle);
    gfx::uploader_flush_blocking(gfx.uploader);
    model.vb = gfx::gfx_buffer_get(gfx, model.vb_handle)->handle;
    model.ib = gfx::gfx_buffer_get(gfx, model.ib_handle)->handle;
    return model;
}

bool load_gltf(gfx::Gfx& gfx, const std::string& path, Model& out) {
    cgltf_options options = {};
    cgltf_data* data = nullptr;
    cgltf_result result = cgltf_parse_file(&options, path.c_str(), &data);
    if (result != cgltf_result_success || !data) {
        std::fprintf(stderr, "model: failed to parse %s\n", path.c_str());
        return false;
    }
    result = cgltf_load_buffers(&options, data, path.c_str());
    if (result != cgltf_result_success) {
        std::fprintf(stderr, "model: failed to load buffers of %s\n", path.c_str());
        cgltf_free(data);
        return false;
    }

    std::vector<uint8_t> vertices;
    std::vector<uint32_t> indices;
    for (size_t mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh& mesh = data->meshes[mi];
        for (size_t pi = 0; pi < mesh.primitives_count; ++pi) {
            const cgltf_primitive& prim = mesh.primitives[pi];
            if (prim.type != cgltf_primitive_type_triangles) continue;
            const cgltf_accessor* pos_acc = nullptr;
            const cgltf_accessor* nrm_acc = nullptr;
            const cgltf_accessor* uv_acc = nullptr;
            for (size_t ai = 0; ai < prim.attributes_count; ++ai) {
                const cgltf_attribute& attr = prim.attributes[ai];
                if (attr.type == cgltf_attribute_type_position) pos_acc = attr.data;
                else if (attr.type == cgltf_attribute_type_normal) nrm_acc = attr.data;
                else if (attr.type == cgltf_attribute_type_texcoord) uv_acc = attr.data;
            }
            if (!pos_acc) continue;

            // Unpack each attribute stream once, then interleave.
            size_t count = pos_acc->count;
            std::vector<float> positions(count * 3);
            cgltf_accessor_unpack_floats(pos_acc, positions.data(), count * 3);
            std::vector<float> normals;
            if (nrm_acc) {
                normals.resize(count * 3);
                cgltf_accessor_unpack_floats(nrm_acc, normals.data(), count * 3);
            }
            std::vector<float> uvs;
            if (uv_acc) {
                uvs.resize(count * 2);
                cgltf_accessor_unpack_floats(uv_acc, uvs.data(), count * 2);
            }

            uint32_t base = uint32_t(vertices.size() / MODEL_PITCH);
            for (size_t i = 0; i < count; ++i) {
                size_t row = vertices.size();
                vertices.resize(row + MODEL_PITCH);
                float* slot = reinterpret_cast<float*>(&vertices[row]);
                slot[0] = positions[i * 3 + 0];
                slot[1] = positions[i * 3 + 1];
                slot[2] = positions[i * 3 + 2];
                if (!normals.empty()) {
                    slot[3] = normals[i * 3 + 0];
                    slot[4] = normals[i * 3 + 1];
                    slot[5] = normals[i * 3 + 2];
                }
                if (!uvs.empty()) {
                    slot[6] = uvs[i * 2 + 0];
                    slot[7] = uvs[i * 2 + 1];
                }
            }
            if (prim.indices) {
                for (size_t i = 0; i < prim.indices->count; ++i)
                    indices.push_back(base + uint32_t(
                        cgltf_accessor_read_index(prim.indices, i)));
            } else {
                for (size_t i = 0; i < count; ++i) indices.push_back(base + uint32_t(i));
            }
        }
    }
    cgltf_free(data);
    if (indices.empty()) {
        std::fprintf(stderr, "model: %s has no triangles\n", path.c_str());
        return false;
    }
    model_normalize_bounds(vertices);
    out = model_upload(gfx, vertices, indices, path.c_str());
    return true;
}

// Icosphere fallback: subdivided icosahedron. Uniform triangles, no pole
// singularity and no UV seam (src/model.odin model_load_sphere).
static Model load_sphere(gfx::Gfx& gfx) {
    constexpr int SUBDIV = 4;
    const float PHI = 1.6180339887498948482f;
    const float base_verts[12][3] = {
        {-1, PHI, 0}, {1, PHI, 0}, {-1, -PHI, 0}, {1, -PHI, 0},
        {0, -1, PHI}, {0, 1, PHI}, {0, -1, -PHI}, {0, 1, -PHI},
        {PHI, 0, -1}, {PHI, 0, 1}, {-PHI, 0, -1}, {-PHI, 0, 1},
    };
    const uint32_t faces[20][3] = {
        {0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
        {1, 5, 9}, {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
        {3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8}, {3, 8, 9},
        {4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1},
    };
    auto normalize = [](const float v[3], float out[3]) {
        float len = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        out[0] = v[0] / len;
        out[1] = v[1] / len;
        out[2] = v[2] / len;
    };
    std::vector<std::array<float, 3>> verts;
    std::vector<uint32_t> indices;
    for (const auto& v : base_verts) {
        std::array<float, 3> n;
        normalize(v, n.data());
        verts.push_back(n);
    }
    for (const auto& f : faces)
        indices.insert(indices.end(), {f[0], f[1], f[2]});
    for (int level = 0; level < SUBDIV; ++level) {
        // Split every triangle at its edge midpoints (normalized back to
        // the unit sphere); winding follows the parent face.
        std::vector<std::array<float, 3>> next_verts;
        std::vector<uint32_t> next_indices;
        auto push_v = [&](const std::array<float, 3>& v) {
            next_verts.push_back(v);
            return uint32_t(next_verts.size() - 1);
        };
        for (size_t i = 0; i + 2 < indices.size(); i += 3) {
            const auto& a = verts[indices[i]];
            const auto& b = verts[indices[i + 1]];
            const auto& c = verts[indices[i + 2]];
            uint32_t ia = push_v(a), ib = push_v(b), ic = push_v(c);
            float ab[3] = {(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2};
            float bc[3] = {(b[0] + c[0]) / 2, (b[1] + c[1]) / 2, (b[2] + c[2]) / 2};
            float ca[3] = {(c[0] + a[0]) / 2, (c[1] + a[1]) / 2, (c[2] + a[2]) / 2};
            std::array<float, 3> nab, nbc, nca;
            normalize(ab, nab.data());
            normalize(bc, nbc.data());
            normalize(ca, nca.data());
            uint32_t iab = push_v(nab), ibc = push_v(nbc), ica = push_v(nca);
            const uint32_t quad[12] = {ia, iab, ica, ib, ibc, iab,
                                       ic, ica, ibc, iab, ibc, ica};
            next_indices.insert(next_indices.end(), quad, quad + 12);
        }
        verts = std::move(next_verts);
        indices = std::move(next_indices);
    }
    std::vector<uint8_t> vertices;
    for (const auto& sp : verts) {
        float u = std::atan2(sp[2], sp[0]) / (2 * float(M_PI)) + 0.5f;
        float v = std::acos(std::clamp(sp[1], -1.0f, 1.0f)) / float(M_PI);
        size_t row = vertices.size();
        vertices.resize(row + MODEL_PITCH);
        float* slot = reinterpret_cast<float*>(&vertices[row]);
        slot[0] = sp[0]; slot[1] = sp[1]; slot[2] = sp[2]; // position
        slot[3] = sp[0]; slot[4] = sp[1]; slot[5] = sp[2]; // normal
        slot[6] = u; slot[7] = v;                          // uv
    }
    return model_upload(gfx, vertices, indices, "generated icosphere");
}

bool load(Assets& out, gfx::Gfx& gfx) {
    // Scanned paper backgrounds (assets/), picked in the UI and bound to
    // the scene's compute pass.
    const char* paper_paths[2] = {"assets/watercolor_paper.jpg", "assets/parchment.jpg"};
    for (int i = 0; i < 2; ++i) {
        bool ok = false;
        out.paper_textures[i] = load_texture(gfx, paper_paths[i], ok);
        if (!ok) {
            std::fprintf(stderr, "required paper texture could not be loaded: %s\n",
                         paper_paths[i]);
            return false;
        }
    }

    // Equirectangular skyboxes (assets/skybox/*.png|jpg), a global option
    // like the paper: scenes sampling skybox_tex get the pick.
    if (DIR* dir = opendir("assets/skybox")) {
        std::vector<std::string> paths;
        while (dirent* entry = readdir(dir)) {
            std::string name = entry->d_name;
            if (name == "." || name == "..") continue;
            if (has_suffix_lower(name, ".png") || has_suffix_lower(name, ".jpg"))
                paths.push_back("assets/skybox/" + name);
        }
        closedir(dir);
        std::sort(paths.begin(), paths.end());
        for (const std::string& path : paths) {
            bool ok = false;
            gfx::Texture_Handle handle = load_texture(gfx, path, ok);
            if (!ok) {
                std::fprintf(stderr, "skipping skybox that could not be loaded: %s\n",
                             path.c_str());
                continue;
            }
            std::string name = path.substr(path.find_last_of('/') + 1);
            if (name.rfind("skybox-", 0) == 0) name = name.substr(7);
            size_t dot = name.find_last_of('.');
            if (dot != std::string::npos && dot > 0) name = name.substr(0, dot);
            out.skybox_names.push_back(name);
            out.skybox_textures.push_back(handle);
        }
    }
    // 1x1 black fallback for unmet sampler inputs (generated, not a file —
    // same as Odin create_black_texture).
    out.black_texture = gfx::gfx_texture_create(
        gfx, 1, 1, SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        SDL_GPU_TEXTUREUSAGE_SAMPLER);
    {
        gfx::Texture* t = gfx::gfx_texture_get(gfx, out.black_texture);
        const uint8_t black[4] = {0, 0, 0, 255};
        t->staging_data.assign(black, black + 4);
        gfx::uploader_begin(gfx.uploader);
        gfx::uploader_upload_texture(gfx.uploader, out.black_texture);
        gfx::uploader_flush_blocking(gfx.uploader);
        t->staging_data.clear();
    }

    // All models in assets/models (+ generated icosphere fallback) for
    // model-viewer scenes; picked in the UI "model" group.
    std::vector<std::string> model_paths;
    if (DIR* dir = opendir("assets/models")) {
        while (dirent* entry = readdir(dir)) {
            std::string name = entry->d_name;
            if (name == "." || name == "..") continue;
            if (has_suffix_lower(name, ".glb") || has_suffix_lower(name, ".gltf"))
                model_paths.push_back("assets/models/" + name);
        }
        closedir(dir);
        std::sort(model_paths.begin(), model_paths.end());
        for (const std::string& path : model_paths) {
            Model model;
            if (!load_gltf(gfx, path, model)) continue;
            std::string base = path.substr(path.find_last_of('/') + 1);
            size_t dot = base.find_last_of('.');
            if (dot != std::string::npos && dot > 0) base = base.substr(0, dot);
            model.name = base;
            std::fprintf(stderr, "model: loaded %s\n", path.c_str());
            out.models.push_back(std::move(model));
        }
    }
    if (out.models.empty())
        std::fprintf(stderr, "model: no .glb/.gltf in assets/models/, using generated icosphere\n");
    Model fallback = load_sphere(gfx);
    fallback.name = "icosphere";
    out.models.push_back(std::move(fallback));
    if (out.models.empty() || !out.models[0].vb) {
        std::fprintf(stderr, "no usable model could be loaded or generated\n");
        return false;
    }

    SDL_GPUSamplerCreateInfo sci{};
    sci.min_filter = SDL_GPU_FILTER_LINEAR;
    sci.mag_filter = SDL_GPU_FILTER_LINEAR;
    sci.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
    sci.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sci.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sci.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    out.paper_sampler = SDL_CreateGPUSampler(gfx.gpu, &sci);
    if (!out.paper_sampler) {
        std::fprintf(stderr, "failed to create paper sampler: %s\n", SDL_GetError());
        return false;
    }
    return true;
}

void destroy(gfx::Gfx& gfx, Assets& a) {
    if (a.paper_sampler) SDL_ReleaseGPUSampler(gfx.gpu, a.paper_sampler);
    for (gfx::Texture_Handle t : a.skybox_textures) gfx::gfx_texture_destroy(gfx, t);
    gfx::gfx_texture_destroy(gfx, a.black_texture);
    for (int i = 0; i < 2; ++i) gfx::gfx_texture_destroy(gfx, a.paper_textures[i]);
    for (Model& m : a.models) {
        gfx::gfx_buffer_destroy(gfx, m.vb_handle);
        gfx::gfx_buffer_destroy(gfx, m.ib_handle);
    }
    a = {};
}

} // namespace assets
