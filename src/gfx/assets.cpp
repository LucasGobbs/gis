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
    if (!gfx.texture_handles.contains(handle)) { // create failed
        stbi_image_free(pixels);
        return handle;
    }
    gfx::Texture* resource = gfx::gfx_texture_get(gfx, handle);
    resource->staging_data.assign(pixels, pixels + bytes);
    stbi_image_free(pixels);
    gfx::uploader_begin(gfx.uploader);
    bool uploaded = gfx::uploader_upload_texture(gfx.uploader, handle);
    gfx::uploader_flush_blocking(gfx.uploader);
    if (!uploaded) {
        gfx::gfx_texture_destroy(gfx, handle);
        return gfx::Texture_Handle{};
    }
    resource->staging_data = {};
    ok = true;
    return handle;
}

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

// On failure (buffer create or staging upload) returns a Model with vb == nullptr.
static Model model_upload(gfx::Gfx& gfx, std::vector<uint8_t>& vertices,
                          std::vector<uint32_t>& indices, const char* source) {
    Model model;
    model.source = source;
    model.index_count = uint32_t(indices.size());
    model.vb_handle = gfx::gfx_buffer_create_from_bytes(
        gfx, vertices.data(), vertices.size(), SDL_GPU_BUFFERUSAGE_VERTEX);
    model.ib_handle = gfx::gfx_buffer_create_from_bytes(
        gfx, indices.data(), indices.size() * 4, SDL_GPU_BUFFERUSAGE_INDEX);
    if (!gfx.buffer_handles.contains(model.vb_handle) ||
        !gfx.buffer_handles.contains(model.ib_handle)) {
        model_release(gfx, model);
        return Model{};
    }
    // One copy pass carries both transfers.
    gfx::uploader_begin(gfx.uploader);
    bool ok = gfx::uploader_upload_buffer(gfx.uploader, model.vb_handle);
    ok = gfx::uploader_upload_buffer(gfx.uploader, model.ib_handle) && ok;
    gfx::uploader_flush_blocking(gfx.uploader);
    if (!ok) {
        model_release(gfx, model);
        return Model{};
    }
    model.vb = gfx::gfx_buffer_get(gfx, model.vb_handle)->handle;
    model.ib = gfx::gfx_buffer_get(gfx, model.ib_handle)->handle;
    return model;
}

// Area-weighted smooth normals over one primitive (index range [i0,i1),
// vertex range [v0,v1)) that lacks a NORMAL accessor (stanford_dragon.glb).
// Zero normals normalize to NaN in the shader and render black.
// shortcut: normals are per primitive-vertex, so seams split across
// primitives; weld by position when a multi-primitive model needs it.
static void model_compute_normals(const std::vector<uint32_t>& indices, size_t i0, size_t i1,
                                  std::vector<uint8_t>& vertices, size_t v0, size_t v1) {
    auto at = [&](uint32_t v) {
        return reinterpret_cast<float*>(&vertices[size_t(v) * MODEL_PITCH]);
    };
    for (size_t i = i0; i + 2 < i1; i += 3) {
        const float* a = at(indices[i]);
        const float* b = at(indices[i + 1]);
        const float* c = at(indices[i + 2]);
        const float e1[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
        const float e2[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
        const float n[3] = {e1[1] * e2[2] - e1[2] * e2[1],
                            e1[2] * e2[0] - e1[0] * e2[2],
                            e1[0] * e2[1] - e1[1] * e2[0]};
        for (size_t k = 0; k < 3; ++k) {
            float* p = at(indices[i + k]);
            p[3] += n[0];
            p[4] += n[1];
            p[5] += n[2];
        }
    }
    for (size_t v = v0; v < v1; ++v) {
        float* p = at(uint32_t(v));
        const float len = std::sqrt(p[3] * p[3] + p[4] * p[4] + p[5] * p[5]);
        if (len > 0.0f) {
            p[3] /= len;
            p[4] /= len;
            p[5] /= len;
        } else {
            p[3] = 0.0f;
            p[4] = 0.0f;
            p[5] = 1.0f;
        }
    }
}

// Uploads RGBA8 pixels as a sampler texture. gfx_texture_create allocates one
// mip level, so these textures are not mipmapped.
static gfx::Texture_Handle upload_rgba8(gfx::Gfx& gfx, const stbi_uc* pixels, int w, int h) {
    gfx::Texture_Handle handle = gfx::gfx_texture_create(
        gfx, uint32_t(w), uint32_t(h), SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        SDL_GPU_TEXTUREUSAGE_SAMPLER);
    if (!gfx.texture_handles.contains(handle)) return handle;
    gfx::Texture* resource = gfx::gfx_texture_get(gfx, handle);
    resource->staging_data.assign(pixels, pixels + size_t(w) * size_t(h) * 4);
    gfx::uploader_begin(gfx.uploader);
    bool uploaded = gfx::uploader_upload_texture(gfx.uploader, handle);
    gfx::uploader_flush_blocking(gfx.uploader);
    if (!uploaded) {
        gfx::gfx_texture_destroy(gfx, handle);
        return gfx::Texture_Handle{};
    }
    resource->staging_data = {};
    return handle;
}

// Decodes a glTF image to RGBA8 (free with stbi_image_free). Embedded images
// come from a bufferView; external ones resolve their uri against the glb's
// directory. data: URIs are unsupported. Returns nullptr on failure.
static stbi_uc* decode_image(const cgltf_image& img, const std::string& glb_path,
                             int& w, int& h) {
    int channels = 0;
    if (img.buffer_view && img.buffer_view->buffer) {
        const uint8_t* bytes =
            reinterpret_cast<const uint8_t*>(img.buffer_view->buffer->data) +
            img.buffer_view->offset;
        return stbi_load_from_memory(bytes, int(img.buffer_view->size), &w, &h, &channels, 4);
    }
    if (!img.uri || std::strncmp(img.uri, "data:", 5) == 0) return nullptr;
    std::vector<char> uri(img.uri, img.uri + std::strlen(img.uri) + 1);
    cgltf_decode_uri(uri.data()); // %20 and friends
    const std::string file =
        glb_path.substr(0, glb_path.find_last_of('/') + 1) + uri.data();
    return stbi_load(file.c_str(), &w, &h, &channels, 4);
}

// glTF sampler → SDL sampler. An absent sampler gets the spec defaults
// (repeat, linear). Single-mip textures, so the mipmap mode is NEAREST.
static SDL_GPUSampler* model_sampler_create(gfx::Gfx& gfx, const cgltf_sampler* s) {
    auto address = [](cgltf_int wrap) {
        if (wrap == 33071) return SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        if (wrap == 33648) return SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT;
        return SDL_GPU_SAMPLERADDRESSMODE_REPEAT; // 10497
    };
    const bool nearest = s && s->mag_filter == 9728; // GL_NEAREST
    SDL_GPUSamplerCreateInfo sci{};
    sci.min_filter = nearest ? SDL_GPU_FILTER_NEAREST : SDL_GPU_FILTER_LINEAR;
    sci.mag_filter = sci.min_filter;
    sci.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    sci.address_mode_u = address(s ? s->wrap_s : 10497);
    sci.address_mode_v = address(s ? s->wrap_t : 10497);
    sci.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    return SDL_CreateGPUSampler(gfx.gpu, &sci);
}

// Node world transform split for vertex transforms. Normals transform by
// (A^-1)^T = cofactor(A)/det(A); the sign of det is folded into the cofactors
// so mirrored nodes keep normals outward, and normalization drops the scale.
struct World {
    float m[16];   // column-major, cgltf layout
    float cof[9];  // row-major cofactor(A) * sign(det)
    bool mirrored; // det < 0: triangle winding must be reversed
};

static World make_world(const cgltf_float* m) {
    World w{};
    std::memcpy(w.m, m, sizeof w.m);
    auto a = [&](int r, int c) { return m[c * 4 + r]; };
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) {
            const int r1 = (r + 1) % 3, r2 = (r + 2) % 3;
            const int c1 = (c + 1) % 3, c2 = (c + 2) % 3;
            w.cof[r * 3 + c] = a(r1, c1) * a(r2, c2) - a(r1, c2) * a(r2, c1);
        }
    const float det = a(0, 0) * w.cof[0] + a(0, 1) * w.cof[1] + a(0, 2) * w.cof[2];
    w.mirrored = det < 0.0f;
    if (w.mirrored)
        for (float& v : w.cof) v = -v;
    return w;
}

static void world_point(const World& w, const float* p, float* o) {
    for (int r = 0; r < 3; ++r)
        o[r] = w.m[r] * p[0] + w.m[4 + r] * p[1] + w.m[8 + r] * p[2] + w.m[12 + r];
}

static void world_normal(const World& w, const float* n, float* o) {
    for (int r = 0; r < 3; ++r)
        o[r] = w.cof[r * 3] * n[0] + w.cof[r * 3 + 1] * n[1] + w.cof[r * 3 + 2] * n[2];
    const float len = std::sqrt(o[0] * o[0] + o[1] * o[1] + o[2] * o[2]);
    if (len > 0.0f) {
        for (int r = 0; r < 3; ++r) o[r] /= len;
    } else {
        o[0] = n[0];
        o[1] = n[1];
        o[2] = n[2];
    }
}

// Accumulates every triangle primitive of a glTF into one interleaved mesh.
struct Gltf_Mesh {
    std::vector<uint8_t> vertices;
    std::vector<uint32_t> indices;
    // Primitives without a NORMAL accessor: index and vertex ranges to smooth.
    struct Range { size_t i0, i1, v0, v1; };
    std::vector<Range> missing_normals;
    bool double_sided = false;
    // Model texture: the first base color image in the material list.
    // shortcut: one base color texture per model, split by material when a
    // model needs several.
    const cgltf_image* base_image = nullptr;
    const cgltf_sampler* base_sampler = nullptr;
};

static const cgltf_accessor* find_attribute(const cgltf_primitive& prim,
                                            cgltf_attribute_type type) {
    const cgltf_accessor* found = nullptr;
    for (size_t ai = 0; ai < prim.attributes_count; ++ai)
        if (prim.attributes[ai].type == type) found = prim.attributes[ai].data;
    return found;
}

// Unpacks `n` floats per element of `acc` (count elements).
static std::vector<float> unpack_floats(const cgltf_accessor* acc, size_t count, size_t n) {
    std::vector<float> out;
    if (!acc) return out;
    out.resize(count * n);
    cgltf_accessor_unpack_floats(acc, out.data(), count * n);
    return out;
}

// Returns false when the primitive is malformed (short attribute stream or
// an index past the vertex count).
static bool append_primitive(const cgltf_primitive& prim, const World& world, Gltf_Mesh& mesh) {
    const cgltf_accessor* pos_acc = find_attribute(prim, cgltf_attribute_type_position);
    const cgltf_accessor* nrm_acc = find_attribute(prim, cgltf_attribute_type_normal);
    const cgltf_accessor* uv_acc = find_attribute(prim, cgltf_attribute_type_texcoord);
    if (prim.material && prim.material->double_sided) mesh.double_sided = true;
    if (!pos_acc) return true;
    if (!mesh.base_image && prim.material) {
        const cgltf_texture_view& view = prim.material->pbr_metallic_roughness.base_color_texture;
        if (view.texture && view.texture->image) {
            mesh.base_image = view.texture->image;
            mesh.base_sampler = view.texture->sampler;
        }
    }

    const size_t count = pos_acc->count;
    if ((nrm_acc && nrm_acc->count < count) || (uv_acc && uv_acc->count < count)) return false;
    // Unpack each attribute stream once, then interleave.
    const std::vector<float> positions = unpack_floats(pos_acc, count, 3);
    const std::vector<float> normals = unpack_floats(nrm_acc, count, 3);
    const std::vector<float> uvs = unpack_floats(uv_acc, count, 2);

    const size_t first_index = mesh.indices.size();
    const size_t first_vertex = mesh.vertices.size() / MODEL_PITCH;
    const uint32_t base = uint32_t(first_vertex);
    for (size_t i = 0; i < count; ++i) {
        size_t row = mesh.vertices.size();
        mesh.vertices.resize(row + MODEL_PITCH);
        float* slot = reinterpret_cast<float*>(&mesh.vertices[row]);
        world_point(world, &positions[i * 3], slot);
        if (!normals.empty()) world_normal(world, &normals[i * 3], slot + 3);
        if (!uvs.empty()) {
            slot[6] = uvs[i * 2 + 0];
            slot[7] = uvs[i * 2 + 1];
        }
    }
    if (prim.indices) {
        for (size_t i = 0; i < prim.indices->count; ++i) {
            size_t idx = cgltf_accessor_read_index(prim.indices, i);
            if (idx >= count) return false;
            mesh.indices.push_back(base + uint32_t(idx));
        }
    } else {
        for (size_t i = 0; i < count; ++i) mesh.indices.push_back(base + uint32_t(i));
    }
    // Mirroring reverses front faces; glTF front faces are CCW in world space.
    if (world.mirrored)
        for (size_t t = first_index; t + 2 < mesh.indices.size(); t += 3)
            std::swap(mesh.indices[t + 1], mesh.indices[t + 2]);
    if (!nrm_acc)
        mesh.missing_normals.push_back({first_index, mesh.indices.size(), first_vertex,
                                        first_vertex + count});
    return true;
}

// Walk nodes, not meshes: a node transform places each instance, and a mesh
// no node references is not drawn.
static bool collect_triangles(const cgltf_data& data, Gltf_Mesh& mesh) {
    for (size_t ni = 0; ni < data.nodes_count; ++ni) {
        const cgltf_node& node = data.nodes[ni];
        if (!node.mesh) continue;
        cgltf_float world_m[16];
        cgltf_node_transform_world(&node, world_m);
        const World world = make_world(world_m);
        for (size_t pi = 0; pi < node.mesh->primitives_count; ++pi) {
            const cgltf_primitive& prim = node.mesh->primitives[pi];
            if (prim.type != cgltf_primitive_type_triangles) continue;
            if (!append_primitive(prim, world, mesh)) return false;
        }
    }
    return true;
}

// Parses, loads buffers and validates; nullptr (with a message) on failure.
static cgltf_data* open_gltf(const std::string& path) {
    cgltf_options options = {};
    cgltf_data* data = nullptr;
    if (cgltf_parse_file(&options, path.c_str(), &data) != cgltf_result_success || !data) {
        std::fprintf(stderr, "model: failed to parse %s\n", path.c_str());
        return nullptr;
    }
    if (cgltf_load_buffers(&options, data, path.c_str()) != cgltf_result_success) {
        std::fprintf(stderr, "model: failed to load buffers of %s\n", path.c_str());
        cgltf_free(data);
        return nullptr;
    }
    if (cgltf_validate(data) != cgltf_result_success) {
        std::fprintf(stderr, "model: %s failed glTF validation\n", path.c_str());
        cgltf_free(data);
        return nullptr;
    }
    return data;
}

bool load_gltf(gfx::Gfx& gfx, const std::string& path, Model& out) {
    cgltf_data* data = open_gltf(path);
    if (!data) return false;

    Gltf_Mesh mesh;
    if (!collect_triangles(*data, mesh)) {
        std::fprintf(stderr, "model: %s has malformed geometry\n", path.c_str());
        cgltf_free(data);
        return false;
    }
    if (mesh.indices.empty()) {
        std::fprintf(stderr, "model: %s has no triangles\n", path.c_str());
        cgltf_free(data);
        return false;
    }
    for (const Gltf_Mesh::Range& r : mesh.missing_normals)
        model_compute_normals(mesh.indices, r.i0, r.i1, mesh.vertices, r.v0, r.v1);
    std::fprintf(stderr, "model: %s loaded %zu vertices, %zu indices\n",
                 path.c_str(), mesh.vertices.size() / MODEL_PITCH, mesh.indices.size());

    gfx::Texture_Handle tex_handle;
    SDL_GPUTexture* tex = nullptr;
    if (mesh.base_image) {
        int w = 0, h = 0;
        stbi_uc* pixels = decode_image(*mesh.base_image, path, w, h);
        if (!pixels) {
            std::fprintf(stderr, "model: %s failed to decode base color image\n", path.c_str());
        } else {
            tex_handle = upload_rgba8(gfx, pixels, w, h);
            stbi_image_free(pixels);
            if (gfx.texture_handles.contains(tex_handle))
                tex = gfx::gfx_texture_get(gfx, tex_handle)->handle;
        }
    }
    SDL_GPUSampler* sampler = model_sampler_create(gfx, mesh.base_sampler);
    cgltf_free(data);
    if (!sampler) {
        std::fprintf(stderr, "model: %s failed to create texture sampler\n", path.c_str());
        if (gfx.texture_handles.contains(tex_handle)) gfx::gfx_texture_destroy(gfx, tex_handle);
        return false;
    }

    model_normalize_bounds(mesh.vertices);
    Model uploaded = model_upload(gfx, mesh.vertices, mesh.indices, path.c_str());
    if (!uploaded.vb) {
        std::fprintf(stderr, "model: %s failed to upload\n", path.c_str());
        SDL_ReleaseGPUSampler(gfx.gpu, sampler);
        if (gfx.texture_handles.contains(tex_handle)) gfx::gfx_texture_destroy(gfx, tex_handle);
        return false;
    }
    out = std::move(uploaded);
    out.base_color_texture_handle = tex_handle;
    out.base_color_texture = tex;
    out.texture_sampler = sampler;
    out.double_sided = mesh.double_sided;
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

// 1x1 sampler texture: black/white fallbacks. Staged, uploaded, staging freed.
static gfx::Texture_Handle create_1x1(gfx::Gfx& gfx, const uint8_t px[4]) {
    gfx::Texture_Handle handle = gfx::gfx_texture_create(
        gfx, 1, 1, SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    if (!gfx.texture_handles.contains(handle)) return handle;
    gfx::Texture* t = gfx::gfx_texture_get(gfx, handle);
    t->staging_data.assign(px, px + 4);
    gfx::uploader_begin(gfx.uploader);
    gfx::uploader_upload_texture(gfx.uploader, handle);
    gfx::uploader_flush_blocking(gfx.uploader);
    t->staging_data.clear();
    return handle;
}

// Scanned paper background (assets/), picked in the UI and bound to the
// scene's compute pass.
static bool load_papers(Assets& out, gfx::Gfx& gfx) {
    const char* path = "assets/watercolor_paper.jpg";
    bool ok = false;
    out.paper_textures[0] = load_texture(gfx, path, ok);
    if (!ok) std::fprintf(stderr, "required paper texture could not be loaded: %s\n", path);
    return ok;
}

// "skybox-foo.png" -> "foo".
static std::string display_name(const std::string& path, const char* strip_prefix) {
    std::string name = path.substr(path.find_last_of('/') + 1);
    if (strip_prefix && name.rfind(strip_prefix, 0) == 0) name = name.substr(std::strlen(strip_prefix));
    size_t dot = name.find_last_of('.');
    if (dot != std::string::npos && dot > 0) name = name.substr(0, dot);
    return name;
}

// Equirectangular skyboxes (assets/skybox/*.png|jpg), a global option like
// the paper: scenes sampling skybox_tex get the pick.
static void load_skyboxes(Assets& out, gfx::Gfx& gfx) {
    DIR* dir = opendir("assets/skybox");
    if (!dir) return;
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
            std::fprintf(stderr, "skipping skybox that could not be loaded: %s\n", path.c_str());
            continue;
        }
        out.skybox_names.push_back(display_name(path, "skybox-"));
        out.skybox_textures.push_back(handle);
    }
}

// All models in assets/models (+ generated icosphere fallback) for
// model-viewer scenes; picked in the UI "model" group.
static bool load_models(Assets& out, gfx::Gfx& gfx) {
    SDL_GPUTexture* white = gfx::gfx_texture_get(gfx, out.white_texture)->handle;
    if (DIR* dir = opendir("assets/models")) {
        std::vector<std::string> model_paths;
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
            model.name = display_name(path, nullptr);
            // Untextured model: white keeps base color; black would zero it.
            if (!model.base_color_texture) model.base_color_texture = white;
            out.models.push_back(std::move(model));
        }
    }
    if (out.models.empty())
        std::fprintf(stderr, "model: no .glb/.gltf in assets/models/, using generated icosphere\n");
    Model fallback = load_sphere(gfx);
    if (!fallback.vb) {
        std::fprintf(stderr, "no usable model could be loaded or generated\n");
        return false;
    }
    fallback.name = "icosphere";
    fallback.base_color_texture = white;
    out.models.push_back(std::move(fallback));
    return true;
}

bool load(Assets& out, gfx::Gfx& gfx) {
    if (!load_papers(out, gfx)) return false;
    load_skyboxes(out, gfx);
    // Generated (not files): unmet sampler inputs bind black, untextured model
    // base colors bind white.
    const uint8_t black[4] = {0, 0, 0, 255};
    const uint8_t white[4] = {255, 255, 255, 255};
    out.black_texture = create_1x1(gfx, black);
    out.white_texture = create_1x1(gfx, white);
    if (!gfx.texture_handles.contains(out.black_texture) ||
        !gfx.texture_handles.contains(out.white_texture)) {
        std::fprintf(stderr, "failed to create fallback textures\n");
        return false;
    }
    return load_models(out, gfx);
}

void model_release(gfx::Gfx& gfx, Model& m) {
    gfx::gfx_buffer_destroy(gfx, m.vb_handle);
    gfx::gfx_buffer_destroy(gfx, m.ib_handle);
    gfx::gfx_texture_destroy(gfx, m.base_color_texture_handle);
    if (m.texture_sampler) SDL_ReleaseGPUSampler(gfx.gpu, m.texture_sampler);
    m = {};
}

void destroy(gfx::Gfx& gfx, Assets& a) {
    for (gfx::Texture_Handle t : a.skybox_textures) gfx::gfx_texture_destroy(gfx, t);
    gfx::gfx_texture_destroy(gfx, a.black_texture);
    gfx::gfx_texture_destroy(gfx, a.white_texture);
    gfx::gfx_texture_destroy(gfx, a.paper_textures[0]);
    for (Model& m : a.models) model_release(gfx, m);
    a = {};
}

} // namespace assets
