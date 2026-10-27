// Scene runtime implementation. Direct port of scene_runtime.odin +
// targets.odin + pipeline.odin adapter. Threads mirror the Odin design:
// scene_request_build → worker (goose-build subprocess) → scene_build_pump
// applies on the calling (main) thread.
#include "scene_runtime.hpp"

#include <SDL3/SDL.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <sstream>
#include <sys/stat.h>

namespace scene {

// ---- targets.odin ----

static SDL_GPUTexture* create_scene_target(SDL_GPUDevice* gpu, int width, int height) {
    SDL_GPUTextureCreateInfo ci{};
    ci.type = SDL_GPU_TEXTURETYPE_2D;
    ci.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    ci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER | SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE |
               SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    ci.width = uint32_t(width);
    ci.height = uint32_t(height);
    ci.layer_count_or_depth = 1;
    ci.num_levels = 1;
    return SDL_CreateGPUTexture(gpu, &ci);
}

bool targets_needs_resize(const Render_Targets& t, int width, int height, int pass_count) {
    return t.scene == nullptr || t.w != width || t.h != height ||
           int(t.passes.size()) != pass_count;
}

bool targets_resize(Render_Targets& t, SDL_GPUDevice* gpu, int width, int height,
                    int pass_count) {
    if (t.scene) SDL_ReleaseGPUTexture(gpu, t.scene);
    t.scene = create_scene_target(gpu, width, height);
    if (!t.scene) return false;
    for (SDL_GPUTexture* p : t.passes)
        if (p) SDL_ReleaseGPUTexture(gpu, p);
    t.passes.clear();
    for (int i = 0; i < pass_count; ++i) {
        SDL_GPUTexture* p = create_scene_target(gpu, width, height);
        if (!p) return false;
        t.passes.push_back(p);
    }
    for (SDL_GPUTexture* p : t.previews)
        if (p) SDL_ReleaseGPUTexture(gpu, p);
    t.previews.clear();
    for (int i = 0; i < pass_count + 1; ++i) {
        SDL_GPUTextureCreateInfo ci{};
        ci.type = SDL_GPU_TEXTURETYPE_2D;
        ci.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        ci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER | SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
        ci.width = PREVIEW_SIZE;
        ci.height = PREVIEW_SIZE;
        ci.layer_count_or_depth = 1;
        ci.num_levels = 1;
        SDL_GPUTexture* p = SDL_CreateGPUTexture(gpu, &ci);
        if (!p) return false;
        t.previews.push_back(p);
    }
    if (t.depth) SDL_ReleaseGPUTexture(gpu, t.depth);
    SDL_GPUTextureCreateInfo dci{};
    dci.type = SDL_GPU_TEXTURETYPE_2D;
    dci.format = SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
    dci.usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
    dci.width = uint32_t(width);
    dci.height = uint32_t(height);
    dci.layer_count_or_depth = 1;
    dci.num_levels = 1;
    t.depth = SDL_CreateGPUTexture(gpu, &dci);
    if (!t.depth) return false;
    t.w = width;
    t.h = height;
    return true;
}

void targets_destroy(SDL_GPUDevice* gpu, Render_Targets& t) {
    if (t.scene) SDL_ReleaseGPUTexture(gpu, t.scene);
    for (SDL_GPUTexture* p : t.passes)
        if (p) SDL_ReleaseGPUTexture(gpu, p);
    for (SDL_GPUTexture* p : t.previews)
        if (p) SDL_ReleaseGPUTexture(gpu, p);
    if (t.depth) SDL_ReleaseGPUTexture(gpu, t.depth);
    t = {};
}

// ---- Discovery ----

static uint64_t file_mtime(const std::string& path) {
    struct stat st;
    if (::stat(path.c_str(), &st) != 0) return 0;
    return uint64_t(st.st_mtime) * 1000000000ull + uint64_t(st.st_mtimespec.tv_nsec);
}

std::vector<std::string> scene_names_on_disk(std::map<std::string, std::string>& scene_roots) {
    // Built-in first, then user scenes: user shadows builtin (registered last).
    const char* roots[2] = {SCENES_DIR, USER_SCENES_DIR};
    std::vector<std::string> names;
    for (const char* root : roots) {
        DIR* dir = opendir(root);
        if (!dir) continue;
        while (dirent* entry = readdir(dir)) {
            if (entry->d_type != DT_DIR) continue;
            std::string name = entry->d_name;
            if (name == "." || name == "..") continue;
            std::string entry_path = std::string(root) + "/" + name + "/" + name + ".slang";
            std::ifstream f(entry_path);
            if (!f.good()) continue;
            scene_roots[name] = root; // last registration wins (shadowing)
            bool duplicate = false;
            for (const std::string& existing : names)
                if (existing == name) { duplicate = true; break; }
            if (!duplicate) names.push_back(name);
        }
        closedir(dir);
    }
    std::sort(names.begin(), names.end());
    return names;
}

std::string scene_root_dir(const std::map<std::string, std::string>& scene_roots,
                           const std::string& name) {
    auto it = scene_roots.find(name);
    return it != scene_roots.end() ? it->second : std::string(SCENES_DIR);
}

std::string scene_entry_path(const std::map<std::string, std::string>& scene_roots,
                             const std::string& name) {
    return scene_root_dir(scene_roots, name) + "/" + name + "/" + name + ".slang";
}

std::vector<std::string> scene_module_names(const std::map<std::string, std::string>& scene_roots,
                                            const std::string& name) {
    // Extra .slang files in the scene dir, alphabetical, entry excluded.
    std::vector<std::string> mods;
    std::string dir = scene_root_dir(scene_roots, name) + "/" + name;
    DIR* d = opendir(dir.c_str());
    if (!d) return mods;
    std::string entry_file = name + ".slang";
    while (dirent* entry = readdir(d)) {
        if (entry->d_type != DT_REG) continue;
        std::string n = entry->d_name;
        if (n.size() <= 6 || n.substr(n.size() - 6) != ".slang") continue;
        if (n == entry_file) continue;
        mods.push_back(n.substr(0, n.size() - 6));
    }
    closedir(d);
    std::sort(mods.begin(), mods.end());
    return mods;
}

uint64_t scene_latest_mtime(const std::map<std::string, std::string>& scene_roots,
                            const std::string& name) {
    uint64_t latest = file_mtime(scene_entry_path(scene_roots, name));
    for (const std::string& mod : scene_module_names(scene_roots, name)) {
        std::string path = scene_root_dir(scene_roots, name) + "/" + name + "/" + mod + ".slang";
        uint64_t m = file_mtime(path);
        if (m > latest) latest = m;
    }
    return latest;
}

// ---- Build manifest + subprocess (scenes_build) ----

static void write_manifest(const std::vector<std::string>& names,
                           const std::map<std::string, std::string>& scene_roots) {
    std::ostringstream m;
    m << "{\"outputDir\":\"" << GENERATED_DIR << "\",\"parameterOutputDir\":\"" << GENERATED_DIR
      << "\",";
    m << "\"package\":\"generated\",\"gooseImport\":\"vendor/goose/src\",";
    m << "\"commonUniforms\":true,\"targets\":[\"" << SCENE_TARGET << "\"],\"shaders\":[";
    bool first = true;
    auto write_shader = [&](const std::string& name, const std::string& source) {
        if (!first) m << ",";
        first = false;
        m << "{\"name\":\"" << name << "\",\"source\":\"" << source << "\"}";
    };
    for (const std::string& name : names) {
        write_shader(name, scene_entry_path(scene_roots, name));
        for (const std::string& mod : scene_module_names(scene_roots, name)) {
            write_shader(name + "__" + mod,
                         scene_root_dir(scene_roots, name) + "/" + name + "/" + mod + ".slang");
        }
    }
    m << "]}";
    std::ofstream f(SCENES_MANIFEST, std::ios::binary | std::ios::trunc);
    f << m.str();
}

bool scenes_build(const std::vector<std::string>& names,
                  const std::map<std::string, std::string>& scene_roots) {
    // Cross-process exclusion via O_EXCL lockfile (crash-stale after 60s).
    const std::string lock_path = std::string(GENERATED_DIR) + "/.build.lock";
    {
        FILE* f = std::fopen(lock_path.c_str(), "wx"); // exclusive create
        if (f) {
            // Delete the lock when the scope closes: otherwise every save
            // within 60 s of THIS build silently skipped the rebuild (the
            // stale-takeover path read the untouched timestamp).
            struct Close { FILE* f; const std::string& path;
                           ~Close() { std::fclose(f); ::remove(path.c_str()); } }
                closer{f, lock_path};
            write_manifest(names, scene_roots);
            std::string goose =
                std::getenv("GOOSE") ? std::getenv("GOOSE") : "vendor/goose/goose-build";
            std::string slang =
                std::getenv("SLANG") ? std::getenv("SLANG") : "vendor/slang/bin/slangc";
            std::string cmd = goose + " --manifest " + SCENES_MANIFEST + " --slang " + slang;
            int rc = std::system(cmd.c_str());
            return rc == 0;
        }
        // Stale lock: older than 60s → take over.
        struct stat st;
        if (::stat(lock_path.c_str(), &st) == 0) {
            uint64_t age = file_mtime(lock_path);
            uint64_t now = uint64_t(::time(nullptr)) * 1000000000ull;
            if (now - age > 60000000000ull) {
                ::remove(lock_path.c_str());
            } else {
                return true; // held by another instance; next rescan picks up
            }
        }
        return scenes_build(names, scene_roots); // retry once after stale removal
    }
}

// ---- Worker thread (scene_build_worker / scene_request_build / pump) ----

static void build_worker(Build_State* build) {
    std::map<std::string, std::string> roots; // filled by pump-provided names? no:
    // The worker needs the roots snapshot; the request copies it via the
    // pending names' roots captured at request time. To keep the worker
    // self-contained it re-scans disk (cheap, few dirs).
    std::map<std::string, uint64_t> unused_failed;
    for (;;) {
        std::vector<std::string> names;
        {
            std::unique_lock<std::mutex> lock(build->mu);
            build->cond.wait(lock, [&] { return build->req || build->stop; });
            if (build->stop) return;
            build->req = false;
            build->running = true;
            names = build->names;
            // Wait for any in-flight apply to finish reading artifacts.
            build->apply_cond.wait(lock, [&] { return !build->applying || build->stop; });
            if (build->stop) return;
        }
        std::map<std::string, std::string> roots_snapshot;
        // Roots snapshot: scan (same result as the poller's).
        scene_names_on_disk(roots_snapshot);
        bool ok = scenes_build(names, roots_snapshot);
        {
            std::lock_guard<std::mutex> lock(build->mu);
            build->ok = ok;
            build->running = false;
            build->done = true;
        }
    }
}

void scene_request_build(Build_State& build, const std::vector<std::string>& names) {
    std::lock_guard<std::mutex> lock(build.mu);
    if (!build.thread_started) {
        build.thread = std::thread(build_worker, &build);
        build.thread_started = true;
    }
    if (build.req || build.running) {
        build.again = true;
        return;
    }
    build.names = names;
    build.req = true;
    build.cond.notify_one();
}

bool scene_build_pump(Build_State& build, Scene_Manager& manager, SDL_GPUDevice* gpu,
                      const std::map<std::string, std::string>& scene_roots,
                      std::map<std::string, uint64_t>& scene_failed) {
    {
        std::lock_guard<std::mutex> lock(build.mu);
        if (!build.done) return false;
        build.done = false;
        // Arm the apply guard: the worker must not rewrite artifacts while
        // this pump is reading them on the main thread.
        build.applying = true;
    }
    if (manager.scenes.empty()) {
        {
            std::lock_guard<std::mutex> lock(build.mu);
            build.applying = false;
        }
        build.apply_cond.notify_all();
        return true;
    }

    // Reload active scene on the main thread (pipeline creation needs GPU).
    Runtime_Scene& current = manager.scenes[size_t(manager.current)];
    std::string name = current.title;
    Runtime_Scene candidate;
    if (scene_load_into(gpu, candidate, name, scene_roots)) {
        scene_release(gpu, current);
        current = std::move(candidate);
    } else {
        // Failed reload keeps the last-good pipeline running.
        scene_failed[name] = scene_latest_mtime(scene_roots, name);
    }
    // Coalesced follow-up.
    bool again = false;
    {
        std::lock_guard<std::mutex> lock(build.mu);
        again = build.again;
        build.again = false;
        build.applying = false;
    }
    build.apply_cond.notify_all();
    if (again) scene_request_build(build, {name});
    return true;
}

// ---- Pipeline creation from reflection (create_*_pipeline_raw) ----


static SDL_GPUShader* load_shader_raw(SDL_GPUDevice* gpu, const std::string& path,
                                      const std::string& entrypoint, SDL_GPUShaderStage stage,
                                      const refl::ResourceCounts& counts) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return nullptr;
    std::stringstream ss;
    ss << f.rdbuf();
    std::string code = ss.str();
    SDL_GPUShaderCreateInfo ci{};
    ci.stage = stage;
    ci.format = SDL_GPU_SHADERFORMAT_MSL;
    ci.entrypoint = entrypoint.c_str();  // slang names MSL fns (vertMain/pixelMain); SDL default is main0
    ci.code = reinterpret_cast<const Uint8*>(code.data());
    ci.code_size = code.size();
    ci.num_samplers = counts.samplers;
    ci.num_uniform_buffers = counts.ubuf;
    ci.num_storage_buffers = counts.rw_buf;
    ci.num_storage_textures = counts.rw_tex;
    // Slang emits gl_FragCoord as a TEXCOORD_1 varying filled by the vertex
    // stage from a vertex-stage uniform; on this SDL+Metal path that uniform
    // never reaches the vertex stage, so the varying arrives flat and scenes
    // draw a single color. Workaround: rewrite the fragment MSL to derive
    // pixel coordinates from the interpolated [[position]] instead. Y is
    // flipped: slang's fragCoord is GL-style (bottom-up), Metal's position
    // is top-down. The stage_in variable name varies per scene (_S14, _1...):
    // extract it from the pixelMain signature; rewrite only when the field
    // and the uses share it.
    // The TEXCOORD_1 rewrite is DISABLED: the varying path works now that
    // vertex uniforms are pushed correctly ([ub] dump proved iResolution
    // arrives as (575,562,1)); the rewritten [[position]]-based coords
    // produced a squeezed/mirrored gradient on this SDL+Metal path.
    // (TEXCOORD_1 rewrite block deleted: it produced a squeezed/mirrored
    // gradient; see git history.)
    SDL_GPUShader* out = SDL_CreateGPUShader(gpu, &ci);
    if (!out)
        std::fprintf(stderr, "[shader-fail] %s (%s): %s\n", path.c_str(),
                     entrypoint.c_str(), SDL_GetError());
    return out;
}


static SDL_GPUComputePipeline* create_compute_pipeline_raw(SDL_GPUDevice* gpu,
                                                           const std::string& msl_path,
                                                           const std::string& entrypoint,
                                                           const refl::ResourceCounts& counts,
                                                           const uint32_t thread[3]) {
    std::ifstream f(msl_path, std::ios::binary);
    if (!f) return nullptr;
    std::stringstream ss;
    ss << f.rdbuf();
    std::string code = ss.str();
    SDL_GPUComputePipelineCreateInfo ci{};
    ci.code = reinterpret_cast<const Uint8*>(code.data());
    ci.code_size = code.size();
    ci.entrypoint = entrypoint.c_str();
    ci.format = SDL_GPU_SHADERFORMAT_MSL;
    ci.num_samplers = counts.samplers;
    ci.num_readonly_storage_textures = counts.ro_tex;
    ci.num_readwrite_storage_textures = counts.rw_tex;
    std::fprintf(stderr, "[create-compute] %s sam=%u ro_tex=%u rw_tex=%u ro_buf=%u rw_buf=%u ubuf=%u\n",
                 msl_path.c_str(), counts.samplers, counts.ro_tex, counts.rw_tex,
                 counts.ro_buf, counts.rw_buf, counts.ubuf);
    ci.num_readwrite_storage_buffers = counts.rw_buf;
    ci.num_uniform_buffers = counts.ubuf;
    ci.threadcount_x = thread[0];
    ci.threadcount_y = thread[1];
    ci.threadcount_z = thread[2];
    return SDL_CreateGPUComputePipeline(gpu, &ci);
}

static SDL_GPUGraphicsPipeline* create_graphics_pipeline_raw(
    SDL_GPUDevice* gpu, const std::string& vert_path, const std::string& frag_path,
    const std::string& entry_vert, const std::string& entry_frag,
    const refl::ResourceCounts& vert_counts, const refl::ResourceCounts& frag_counts,
    Scene_Pass& pass) {
    SDL_GPUShader* vs = load_shader_raw(gpu, vert_path, entry_vert,
                                        SDL_GPU_SHADERSTAGE_VERTEX, vert_counts);
    if (!vs) return nullptr;
    SDL_GPUShader* fs = load_shader_raw(gpu, frag_path, entry_frag,
                                        SDL_GPU_SHADERSTAGE_FRAGMENT, frag_counts);
    if (!fs) {
        SDL_ReleaseGPUShader(gpu, vs);
        return nullptr;
    }
    SDL_GPUGraphicsPipelineCreateInfo ci{};
    ci.vertex_shader = vs;
    ci.fragment_shader = fs;
    ci.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    ci.rasterizer_state.fill_mode = SDL_GPU_FILLMODE_FILL;
    ci.rasterizer_state.cull_mode = SDL_GPU_CULLMODE_NONE;
    ci.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
    ci.target_info.num_color_targets = 1;
    static SDL_GPUColorTargetDescription target{};
    target.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM; // the scene texture
    ci.target_info.color_target_descriptions = &target;
    if (pass.uses_model) {
        static SDL_GPUVertexBufferDescription vb_desc{0, MODEL_PITCH,
                                                      SDL_GPU_VERTEXINPUTRATE_VERTEX, 0};
        ci.vertex_input_state.num_vertex_buffers = 1;
        ci.vertex_input_state.vertex_buffer_descriptions = &vb_desc;
        ci.vertex_input_state.num_vertex_attributes = uint32_t(pass.vertex_attrs.size());
        ci.vertex_input_state.vertex_attributes = pass.vertex_attrs.data();
        ci.target_info.depth_stencil_format = SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
        ci.depth_stencil_state.compare_op = SDL_GPU_COMPAREOP_LESS;
        ci.depth_stencil_state.enable_depth_test = true;
        ci.depth_stencil_state.enable_depth_write = true;
    }
    SDL_GPUGraphicsPipeline* pipeline = SDL_CreateGPUGraphicsPipeline(gpu, &ci);
    SDL_ReleaseGPUShader(gpu, vs);
    SDL_ReleaseGPUShader(gpu, fs);
    return pipeline;
}

// ---- Reflection parse into Scene_Pass (scene_parse_stage_refl + widgets) ----

static bool parse_pass_stage(Scene_Pass& pass, Runtime_Scene& scene, const std::string& refl_path,
                             refl::Stage_Kind stage) {
    (void)scene;   // widgets already extracted by the caller's parse_widgets
    bool ok = false;
    refl::Json root = refl::json_parse_file(refl_path, ok);
    if (!ok) return false;
    refl::Stage_Refl st;
    if (!refl::parse_stage_refl(st, root, stage)) return false;

    if (stage == refl::Stage_Kind::COMPUTE) {
        pass.entry = st.entry;
        pass.thread[0] = st.thread[0];
        pass.thread[1] = st.thread[1];
        pass.thread[2] = st.thread[2];
        pass.compute_counts = st.counts;
        pass.debug_compute_buffer = st.has_debug_storage;
        pass.debug_compute_slot = st.debug_storage_slot;
        pass.sampler_textures = st.sampler_textures;
        pass.sampler_names = st.sampler_names;
    } else if (stage == refl::Stage_Kind::VERTEX) {
        pass.entry_vert = st.entry;
        pass.vert_counts = st.counts;
        pass.uses_model = st.uses_model;
        // Model vertex attributes: fixed layout by location (model.odin).
        if (st.uses_model) {
            for (size_t i = 0; i < 3; ++i) {
                SDL_GPUVertexAttribute attr{};
                attr.location = uint32_t(i);
                attr.buffer_slot = 0;
                attr.format = i == 2 ? SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2
                                     : SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3;
                attr.offset = i == 0 ? MODEL_OFF_POS : (i == 1 ? MODEL_OFF_NRM : MODEL_OFF_UV);
                pass.vertex_attrs.push_back(attr);
            }
        }
    } else {
        pass.entry_frag = st.entry;
        pass.frag_counts = st.counts;
        pass.debug_fragment_buffer = st.has_debug_storage;
        pass.debug_fragment_slot = st.debug_storage_slot;
        pass.sampler_textures = st.sampler_textures;
        pass.sampler_names = st.sampler_names;
    }

    // Merge cbuffers into the pass; widgets go to the scene (dedup by label).
    for (const refl::CBuffer& src : st.cbuffers) {
        CBuffer* cb = nullptr;
        for (CBuffer& existing : pass.cbuffers) {
            if (existing.name == src.name) { cb = &existing; break; }
        }
        if (!cb) {
            CBuffer fresh;
            fresh.name = src.name;
            for (const refl::Field& f : src.fields) { (void)f;
                Uniform_Field uf;
                uf.name = f.name;
                uf.offset = f.offset;
                uf.size = f.size;
                fresh.fields.push_back(uf);
            }
            fresh.block = src.block;
            pass.cbuffers.push_back(std::move(fresh));
            cb = &pass.cbuffers.back();
        }
        // Each stage carries its own [[buffer(n)]] index; keep both when shared.
        if (stage == refl::Stage_Kind::COMPUTE) cb->compute_slot = src.compute_slot;
        else if (stage == refl::Stage_Kind::VERTEX) { cb->in_vert = true; cb->vert_slot = src.vert_slot; }
        else { cb->in_frag = true; cb->frag_slot = src.frag_slot; }

        // Widget attributes ([UiSlider]/[UiToggle]/[UiColor]).
        for (const refl::Field& f : src.fields) { (void)f;
            const refl::Json* fp = nullptr;
            // Re-find the field's userAttribs from the JSON (fields parsed
            // without attributes in refl.hpp).
            (void)fp;
        }
    }
    return true;
}

// Extracts widget attributes; separate pass over the raw JSON. module = the
// reflection unit (scene entry or <scene>__<module> pass) the buffer came
// from, so the UI can group params per file.
static void parse_widgets(Runtime_Scene& scene, const refl::Json& root,
                          const std::string& module) {
    const refl::Json& params = root["parameters"];
    for (const refl::Json& param : params.arr) {
        if (param["type"]["kind"].str != "constantBuffer") continue;
        const refl::Json& fields = param["type"]["elementVarLayout"]["type"]["fields"];
        for (const refl::Json& f : fields.arr) {
            const std::string& field_name = f["name"].str;
            for (const refl::Json& attr : f["userAttribs"].arr) {
                const std::string& aname = attr["name"].str;
                const refl::Json& args = attr["arguments"];
                Uniform_Widget widget;
                widget.label = field_name;
                widget.module = module;
                widget.param = param["name"].str;
                bool known = true;
                if (aname == "UiSlider" || aname == "NodeUISlider") {
                    widget.kind = Uniform_Widget::Kind::SLIDER;
                    widget.node = aname == "NodeUISlider";
                    if (args.arr.size() >= 4) {
                        widget.min = float(args.arr[0].num);
                        widget.max = float(args.arr[1].num);
                        widget.step = float(args.arr[2].num);
                        widget.value[0] = float(args.arr[3].num);
                    }
                } else if (aname == "UiToggle" || aname == "NodeUICheck") {
                    widget.kind = Uniform_Widget::Kind::TOGGLE;
                    widget.node = aname == "NodeUICheck";
                    if (!args.arr.empty()) widget.on = args.arr[0].num != 0;
                } else if (aname == "UiColor") {
                    widget.kind = Uniform_Widget::Kind::COLOR;
                    widget.value[0] = widget.value[1] = widget.value[2] = 1;
                    if (args.arr.size() >= 3) {
                        widget.value[0] = float(args.arr[0].num);
                        widget.value[1] = float(args.arr[1].num);
                        widget.value[2] = float(args.arr[2].num);
                    }
                } else {
                    known = false;
                }
                if (!known) continue;
                bool seen = false;
                for (const Uniform_Widget& existing : scene.widgets)
                    if (existing.label == widget.label) { seen = true; break; }
                if (!seen) scene.widgets.push_back(widget);
            }
        }
    }
}

// ---- scene_parse_pass + scene_parse_reflection ----

static bool scene_parse_pass(SDL_GPUDevice* gpu, Runtime_Scene& scene, const std::string& name,
                             const std::string& source, Scene_Pass& pass) {
    (void)source;  // reflection comes from the generated artifacts, not the source
    pass.name = name;
    const std::string base = std::string(GENERATED_DIR) + "/" + name;
    const std::string compute_refl = base + ".compute." + SCENE_FMT + ".refl.json";
    const std::string vert_refl = base + ".vert." + SCENE_FMT + ".refl.json";
    const std::string frag_refl = base + ".frag." + SCENE_FMT + ".refl.json";

    bool ok = false;
    if (std::ifstream(compute_refl).good()) {
        pass.kind = Scene_Kind::COMPUTE;
        bool parse_ok = false;
        refl::Json root = refl::json_parse_file(compute_refl, parse_ok);
        if (!parse_ok) return false;
        parse_widgets(scene, root, name);
        if (!parse_pass_stage(pass, scene, compute_refl, refl::Stage_Kind::COMPUTE)) return false;
        pass.compute = create_compute_pipeline_raw(
            gpu, base + ".compute." + SCENE_FMT, pass.entry, pass.compute_counts, pass.thread);
        return pass.compute != nullptr;
    }
    if (std::ifstream(vert_refl).good() && std::ifstream(frag_refl).good()) {
        pass.kind = Scene_Kind::GRAPHICS;
        bool parse_ok = false;
        refl::Json vroot = refl::json_parse_file(vert_refl, parse_ok);
        if (!parse_ok) return false;
        refl::Json froot = refl::json_parse_file(frag_refl, ok);
        if (!ok) return false;
        parse_widgets(scene, vroot, name);
        parse_widgets(scene, froot, name);
        if (!parse_pass_stage(pass, scene, vert_refl, refl::Stage_Kind::VERTEX)) return false;
        if (!parse_pass_stage(pass, scene, frag_refl, refl::Stage_Kind::FRAGMENT)) return false;
        pass.graphics = create_graphics_pipeline_raw(
            gpu, base + ".vert." + SCENE_FMT, base + ".frag." + SCENE_FMT, pass.entry_vert,
            pass.entry_frag, pass.vert_counts, pass.frag_counts, pass);
        if (!pass.graphics)
            std::fprintf(stderr, "scene: failed to create graphics pipeline %s: %s\n",
                         (base + ".frag." + SCENE_FMT).c_str(), SDL_GetError());
        return pass.graphics != nullptr;
    }
    return false;
}

static bool scene_parse_reflection(SDL_GPUDevice* gpu, Runtime_Scene& scene,
                                   const std::map<std::string, std::string>& scene_roots) {
    std::vector<std::string> names;
    std::vector<std::string> sources;
    names.push_back(scene.title);
    sources.push_back(scene.source);
    for (const std::string& mod : scene_module_names(scene_roots, scene.title)) {
        names.push_back(scene.title + "__" + mod);
        sources.push_back(scene_root_dir(scene_roots, scene.title) + "/" + scene.title + "/" +
                          mod + ".slang");
    }
    for (size_t i = 0; i < names.size(); ++i) {
        Scene_Pass pass;
        if (!scene_parse_pass(gpu, scene, names[i], sources[i], pass)) {
            scene_release_pass(gpu, pass);
            return false;
        }
        // graph key: comp:<source>:<entry> / gfx:<source> (source minus
        // src/shaders/ prefix and .slang suffix).
        std::string source_key = sources[i];
        const std::string prefix = "src/shaders/";
        if (source_key.rfind(prefix, 0) == 0) source_key = source_key.substr(prefix.size());
        if (source_key.size() > 6 && source_key.substr(source_key.size() - 6) == ".slang")
            source_key = source_key.substr(0, source_key.size() - 6);
        if (pass.kind == Scene_Kind::COMPUTE)
            pass.graph_key = "comp:" + source_key + ":" + pass.entry;
        else
            pass.graph_key = "gfx:" + source_key;
        scene.uses_model = scene.uses_model || pass.uses_model;
        scene.passes.push_back(std::move(pass));
    }
    if (scene.passes.empty()) return false;
    scene.kind = scene.passes[0].kind;
    return true;
}

// ---- Pipeline adapter (pipeline.odin) ----

std::vector<render_graph::Pass_Descriptor> scene_pass_descriptors(const Runtime_Scene& scene) {
    std::vector<render_graph::Pass_Descriptor> out;
    out.reserve(scene.passes.size());
    for (const Scene_Pass& pass : scene.passes) {
        render_graph::Pass_Descriptor d;
        d.key = pass.graph_key;
        d.name = pass.name;
        d.input_textures = pass.sampler_textures;
        d.output_pin = pass.kind == Scene_Kind::COMPUTE ? "out_tex" : "frame";
        d.uses_model = pass.uses_model;
        for (const CBuffer& cb : pass.cbuffers) d.uniform_blocks.push_back(cb.name);
        out.push_back(std::move(d));
    }
    return out;
}

bool pipeline_scene_init(Runtime_Scene& scene,
                         const std::map<std::string, std::string>& scene_roots,
                         std::string& error) {
    // Load graph.json (missing file → default plan).
    std::string path =
        render_graph::graph_path(scene.title, scene_root_dir(scene_roots, scene.title));
    std::ifstream f(path, std::ios::binary);
    render_graph::Plan candidate;
    if (!f.good()) {
        candidate = render_graph::plan_default(scene_pass_descriptors(scene));
        scene.pipeline = std::move(candidate);
        scene.pipeline_error.clear();
        scene.pipeline_mtime = file_mtime(path);
        return true;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    render_graph::Graph_Json doc;
    if (!refl::parse_graph_json(doc, ss.str())) {
        error = "could not parse " + path;
    } else if (!doc.scene.empty() && doc.scene != scene.title) {
        error = "graph scene '" + doc.scene + "' does not match '" + scene.title + "'";
    } else if (doc.version != 0 && doc.version != render_graph::GRAPH_SCHEMA_VERSION) {
        error = "unsupported graph schema version " + std::to_string(doc.version);
    } else {
        std::string build_err;
        bool ok = false;
        candidate = render_graph::plan_build(scene_pass_descriptors(scene), doc, build_err, ok);
        if (!ok) error = build_err;
    }
    if (!error.empty()) {
        // Last-good contract (Odin parity): a broken graph.json must not take
        // the scene down. Run the declaration-order default plan and surface
        // the error; the next valid save rebuilds the authored pipeline.
        candidate = render_graph::plan_default(scene_pass_descriptors(scene));
        scene.pipeline = std::move(candidate);
        scene.pipeline_error = error;
        scene.pipeline_mtime = file_mtime(path);
        return true;
    }
    scene.pipeline = std::move(candidate);
    scene.pipeline_error.clear();
    scene.pipeline_mtime = file_mtime(path);
    return true;
}

int pipeline_plan_source(const render_graph::Plan& plan, int consumer,
                         const std::string& input_name) {
    for (const render_graph::Route& route : plan.routes) {
        if (route.consumer == consumer && route.input_name == input_name) return route.producer;
    }
    return -1;
}

bool pipeline_plan_resource(const render_graph::Plan& plan, int consumer,
                            const std::string& input_name, render_graph::Resource_Kind kind,
                            std::string& path) {
    for (const render_graph::Resource_Route& r : plan.resources) {
        if (r.consumer == consumer && r.input_name == input_name && r.kind == kind) {
            path = r.path;
            return true;
        }
    }
    return false;
}

bool pipeline_plan_equal(const render_graph::Plan& a, const render_graph::Plan& b) {
    return render_graph::plan_equal(a, b);
}

// ---- Load / release / reload ----

void scene_release_pass(SDL_GPUDevice* gpu, Scene_Pass& pass) {
    if (pass.compute) SDL_ReleaseGPUComputePipeline(gpu, pass.compute);
    if (pass.graphics) SDL_ReleaseGPUGraphicsPipeline(gpu, pass.graphics);
    pass = {};
}

void scene_release(SDL_GPUDevice* gpu, Runtime_Scene& scene) {
    for (Scene_Pass& pass : scene.passes) scene_release_pass(gpu, pass);
    scene.passes.clear();
    scene.widgets.clear();
    render_graph::plan_destroy(scene.pipeline);
}

bool scene_load_into(SDL_GPUDevice* gpu, Runtime_Scene& dest, const std::string& name_in,
                     const std::map<std::string, std::string>& scene_roots) {
    // name by value: the common caller passes dest.title as the argument,
    // and `dest = Runtime_Scene{}` below would wipe the referenced string
    // mid-load (name == dest.title aliases the same buffer).
    std::string name = name_in;
    dest = Runtime_Scene{};
    dest.title = name;
    dest.source = scene_entry_path(scene_roots, name);
    dest.user_owned = scene_root_dir(scene_roots, name) == USER_SCENES_DIR;
    {
        std::ifstream f(dest.source);
        if (!f.good()) return false;
    }
    dest.mtime = scene_latest_mtime(scene_roots, name);
    std::string error;
    if (!scene_parse_reflection(gpu, dest, scene_roots) ||
        !pipeline_scene_init(dest, scene_roots, error)) {
        dest.pipeline_error = error;
        scene_release(gpu, dest);
        return false;
    }
    dest.loaded = true;
    return true;
}

bool scene_load(Scene_Manager& manager, SDL_GPUDevice* gpu, const std::string& name,
                const std::map<std::string, std::string>& scene_roots) {
    Runtime_Scene scene;
    if (!scene_load_into(gpu, scene, name, scene_roots)) return false;
    manager.scenes.push_back(std::move(scene));
    return true;
}

void scene_reload(Scene_Manager& manager, SDL_GPUDevice* gpu,
                  const std::map<std::string, std::string>& scene_roots,
                  const std::vector<std::string>& names,
                  std::map<std::string, uint64_t>& scene_failed) {
    std::string current_title =
        manager.scenes.empty() ? std::string() : manager.scenes[size_t(manager.current)].title;

    for (const std::string& name : names) {
        {
            std::ifstream f(scene_entry_path(scene_roots, name));
            if (!f.good()) continue;
        }
        // Graph.json participates in the gate: an external editor changing
        // routing must re-plan even when no .slang changed.
        uint64_t mtime = scene_latest_mtime(scene_roots, name);
        {
            std::string gp = render_graph::graph_path(
                name, scene_root_dir(scene_roots, name));
            uint64_t gm = file_mtime(gp);
            if (gm > mtime) mtime = gm;
        }
        auto failed_it = scene_failed.find(name);
        if (failed_it != scene_failed.end() && failed_it->second == mtime) continue;

        long existing_index = -1;
        for (size_t i = 0; i < manager.scenes.size(); ++i)
            if (manager.scenes[i].title == name) { existing_index = long(i); break; }
        if (existing_index >= 0 &&
            manager.scenes[size_t(existing_index)].mtime == mtime)
            continue;

        bool succeeded = false;
        if (existing_index >= 0) {
            Runtime_Scene candidate;
            if (scene_load_into(gpu, candidate, name, scene_roots)) {
                scene_release(gpu, manager.scenes[size_t(existing_index)]);
                manager.scenes[size_t(existing_index)] = std::move(candidate);
                succeeded = true;
            }
        } else {
            succeeded = scene_load(manager, gpu, name, scene_roots);
        }
        if (succeeded) {
            scene_failed.erase(name);
        } else if (scene_failed.find(name) == scene_failed.end()) {
            scene_failed[name] = mtime;
        }
    }
}

// ---- Uniform fill + submission ----

static void poke_f32(std::vector<uint8_t>& block, uint32_t offset, float value) {
    if (offset + 4 <= block.size()) std::memcpy(block.data() + offset, &value, 4);
}
static void poke_u32(std::vector<uint8_t>& block, uint32_t offset, uint32_t value) {
    if (offset + 4 <= block.size()) std::memcpy(block.data() + offset, &value, 4);
}

void scene_write_uniforms(Runtime_Scene& scene, float res_x, float res_y, float time_s,
                          bool color, float mouse_x, float mouse_y, bool mouse_click) {
    for (Scene_Pass& pass : scene.passes) {
        for (CBuffer& cb : pass.cbuffers) {
            for (const Uniform_Field& field : cb.fields) {
                if (field.name == "iResolution") {
                    poke_f32(cb.block, field.offset + 0, res_x);
                    poke_f32(cb.block, field.offset + 4, res_y);
                    poke_f32(cb.block, field.offset + 8, 1.0f);
                } else if (field.name == "iTime") {
                    poke_f32(cb.block, field.offset, time_s);
                } else if (field.name == "iFbm") {
                    poke_f32(cb.block, field.offset + 0, 6.0f);
                    poke_f32(cb.block, field.offset + 4, 2.03f);
                    poke_f32(cb.block, field.offset + 8, 0.5f);
                } else if (field.name == "iColorMode") {
                    poke_f32(cb.block, field.offset, color ? 1.0f : 0.0f);
                } else if (field.name == "iMousePos") {
                    poke_f32(cb.block, field.offset + 0, mouse_x);
                    poke_f32(cb.block, field.offset + 4, mouse_y);
                } else if (field.name == "iMouseClick") {
                    poke_f32(cb.block, field.offset, mouse_click ? 1.0f : 0.0f);
                } else if (field.name == "iViewProjection") {
                    // identity (2D scenes ignore it)
                    for (int i = 0; i < 16; ++i)
                        poke_f32(cb.block, field.offset + uint32_t(i) * 4,
                                 (i % 5 == 0) ? 1.0f : 0.0f);
                } else if (field.name == "iCameraPosition" || field.name == "iCameraRight" ||
                           field.name == "iCameraUp" || field.name == "iCameraForward") {
                    for (int i = 0; i < 3; ++i)
                        poke_f32(cb.block, field.offset + uint32_t(i) * 4, 0.0f);
                } else if (field.name == "iManual") {
                    poke_f32(cb.block, field.offset, 1.0f);
                } else if (field.name == "iDebugPixel" || field.name == "iDebugEnabled" ||
                           field.name == "iDebugFrame") {
                    poke_u32(cb.block, field.offset, 0);
                }
            }
        }
    }
    // Widgets fan out to every pass cbuffer matching by field name.
    for (const Uniform_Widget& widget : scene.widgets) {
        for (Scene_Pass& pass : scene.passes) {
            for (CBuffer& cb : pass.cbuffers) {
                for (const Uniform_Field& field : cb.fields) {
                    if (field.name != widget.label) continue;
                    switch (widget.kind) {
                    case Uniform_Widget::Kind::SLIDER:
                        poke_f32(cb.block, field.offset, widget.value[0]);
                        break;
                    case Uniform_Widget::Kind::TOGGLE:
                        poke_f32(cb.block, field.offset, widget.on ? 1.0f : 0.0f);
                        break;
                    case Uniform_Widget::Kind::COLOR:
                        poke_f32(cb.block, field.offset + 0, widget.value[0]);
                        poke_f32(cb.block, field.offset + 4, widget.value[1]);
                        poke_f32(cb.block, field.offset + 8, widget.value[2]);
                        break;
                    }
                }
            }
        }
    }
}

SDL_GPUTexture* scene_pass_texture(const Runtime_Scene& scene, SDL_GPUTexture* scene_tex,
                                   const Scene_Resources& res, int pass_index) {
    if (pass_index == scene.pipeline.output_pass) return scene_tex;
    if (pass_index >= 0 && pass_index < int(res.pass_tex.size())) return res.pass_tex[size_t(pass_index)];
    return nullptr;
}

void push_scene_uniforms(SDL_GPUCommandBuffer* cmd, Scene_Pass& pass, bool compute) {
    for (CBuffer& cb : pass.cbuffers) {
        if (compute) {
            SDL_PushGPUComputeUniformData(cmd, cb.compute_slot, cb.block.data(),
                                          uint32_t(cb.block.size()));
            continue;
        }
        if (cb.in_vert)
            SDL_PushGPUVertexUniformData(cmd, cb.vert_slot, cb.block.data(),
                                         uint32_t(cb.block.size()));
        if (cb.in_frag)
            SDL_PushGPUFragmentUniformData(cmd, cb.frag_slot, cb.block.data(),
                                           uint32_t(cb.block.size()));
    }
}
// Model-draw branch selector (common.slang model_scene_vertex): 1 = the
// fullscreen background, 0 = the indexed model.
static void scene_set_manual(Scene_Pass& pass, float value) {
    for (CBuffer& cb : pass.cbuffers)
        for (const Uniform_Field& field : cb.fields)
            if (field.name == "iManual") poke_f32(cb.block, field.offset, value);
}

SDL_GPUFence* submit_scene_frame(SDL_GPUDevice* gpu, Runtime_Scene& scene,
                                 SDL_GPUTexture* scene_tex, Scene_Resources& resources,
                                 int width, int height, SDL_GPUGraphicsPipeline* preview_pipeline,
                                 SDL_GPUGraphicsPipeline* blit_pipeline, SDL_GPUSampler* blit_sampler,
                                 SDL_GPUSampler* preview_sampler,
                                 std::vector<SDL_GPUTexture*>& preview_tex) {
    (void)blit_pipeline; (void)blit_sampler; // host blits the swapchain itself
    SDL_GPUCommandBuffer* cmd = SDL_AcquireGPUCommandBuffer(gpu);
    if (!cmd) return nullptr;


    for (int pass_index : scene.pipeline.order) {
        Scene_Pass& pass = scene.passes[size_t(pass_index)];
        SDL_GPUTexture* out_tex = scene_pass_texture(scene, scene_tex, resources, pass_index);
        if (!out_tex) {
            // Never leak the acquired command buffer: submit empty and bail.
            SDL_SubmitGPUCommandBuffer(cmd);
            return nullptr;
        }
        // iDebugPass = pass index.
        for (CBuffer& cb : pass.cbuffers)
            for (const Uniform_Field& field : cb.fields)
                if (field.name == "iDebugPass") poke_u32(cb.block, field.offset, uint32_t(pass_index));

        size_t sampler_count = pass.sampler_textures.size();
        std::vector<SDL_GPUTextureSamplerBinding> bindings(
            sampler_count > 0 ? sampler_count : 1);
        for (size_t slot = 0; slot < sampler_count; ++slot) {
            const std::string& name = pass.sampler_textures[slot];
            // Default = the app's paper texture (Odin resources.paper_index);
            // a producer pass wins, then a user-resource route, then the
            // skybox/input_tex named fallbacks.
            SDL_GPUTexture* texture = resources.paper_texture
                                          ? resources.paper_texture
                                          : resources.black_texture;
            int producer = pipeline_plan_source(scene.pipeline, pass_index, name);
            if (producer >= 0) {
                texture = scene_pass_texture(scene, scene_tex, resources, producer);
            } else if (name == "skybox_tex" && resources.skybox_texture) {
                texture = resources.skybox_texture;
            } else if (name == "input_tex") {
                texture = resources.black_texture;
            }
            bindings[slot].texture = texture;
            bindings[slot].sampler = resources.sampler;
        }

        if (pass.kind == Scene_Kind::COMPUTE) {
            SDL_GPUStorageTextureReadWriteBinding tex_binding{};
            tex_binding.texture = out_tex;
            SDL_GPUStorageBufferReadWriteBinding buf_binding{};
            buf_binding.buffer = resources.debug_watch_buffer;
            SDL_GPUComputePass* compute_pass =
                pass.debug_compute_buffer && resources.debug_watch_buffer
                    ? SDL_BeginGPUComputePass(cmd, &tex_binding, 1, &buf_binding, 1)
                    : SDL_BeginGPUComputePass(cmd, &tex_binding, 1, nullptr, 0);
            SDL_BindGPUComputePipeline(compute_pass, pass.compute);
            if (sampler_count > 0)
                SDL_BindGPUComputeSamplers(compute_pass, 0, bindings.data(),
                                           uint32_t(sampler_count));
            push_scene_uniforms(cmd, pass, true);
            uint32_t tx = pass.thread[0], ty = pass.thread[1];
            SDL_DispatchGPUCompute(compute_pass, uint32_t((width + tx - 1) / tx),
                                   uint32_t((height + ty - 1) / ty), 1);
            SDL_EndGPUComputePass(compute_pass);
        } else {
            SDL_GPUColorTargetInfo color_target{};
            color_target.texture = out_tex;
            color_target.load_op = SDL_GPU_LOADOP_CLEAR;
            color_target.store_op = SDL_GPU_STOREOP_STORE;
            color_target.clear_color = pass.uses_model ? SDL_FColor{0.93f, 0.91f, 0.86f, 1}
                                                       : SDL_FColor{0, 0, 0, 1};
            SDL_GPUDepthStencilTargetInfo depth_target{};
            depth_target.texture = resources.depth_tex;
            depth_target.load_op = SDL_GPU_LOADOP_CLEAR;
            depth_target.clear_depth = 1.0f;
            depth_target.store_op = SDL_GPU_STOREOP_DONT_CARE;
            SDL_GPURenderPass* render_pass =
                SDL_BeginGPURenderPass(cmd, &color_target, 1,
                                       pass.uses_model ? &depth_target : nullptr);
            SDL_BindGPUGraphicsPipeline(render_pass, pass.graphics);
            if (sampler_count > 0) {
                // Only contiguous bound slots; gaps (nullptr texture) stop the run.
                uint32_t bound = 0;
                for (SDL_GPUTextureSamplerBinding& b : bindings) {
                    if (!b.texture) break;
                    ++bound;
                }
                if (bound > 0) SDL_BindGPUFragmentSamplers(render_pass, 0, bindings.data(), bound);
            }
            if (pass.debug_fragment_buffer && resources.debug_watch_buffer) {
                SDL_BindGPUFragmentStorageBuffers(render_pass, 0, &resources.debug_watch_buffer, 1); // SDL array slot; Metal maps storage buffers after uniform buffers
            }
            SDL_GPUViewport vp{0, 0, float(width), float(height), 0.0f, 1.0f};
            SDL_SetGPUViewport(render_pass, &vp);
            if (pass.uses_model && resources.model_vb && resources.model_ib) {
                // Model draw: fullscreen background first (iManual=1), then
                // the indexed model depth-tested on top (iManual=0), matching
                // the common.slang model_scene_vertex branch.
                SDL_GPUBufferBinding vb_binding{resources.model_vb, 0};
                SDL_BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1);
                SDL_GPUBufferBinding ib_binding{resources.model_ib, 0};
                SDL_BindGPUIndexBuffer(render_pass, &ib_binding,
                                       SDL_GPU_INDEXELEMENTSIZE_32BIT);
                scene_set_manual(pass, 1);
                push_scene_uniforms(cmd, pass, false);
                SDL_DrawGPUPrimitives(render_pass, 3, 1, 0, 0);
                scene_set_manual(pass, 0);
                push_scene_uniforms(cmd, pass, false);
                SDL_DrawGPUIndexedPrimitives(render_pass, resources.model_index_count, 1, 0, 0, 0);
            } else {
                push_scene_uniforms(cmd, pass, false);
                SDL_DrawGPUPrimitives(render_pass, 3, 1, 0, 0);
            }
            SDL_EndGPURenderPass(render_pass);
        }
    }

    // Previews: linear-blit each pass output (+ final) into fixed targets.
    if (preview_pipeline && preview_sampler &&
        preview_tex.size() == scene.passes.size() + 1) {
        for (int pass_index : scene.pipeline.order) {
            SDL_GPUTexture* source = scene_pass_texture(scene, scene_tex, resources, pass_index);
            SDL_GPUTexture* target = preview_tex[size_t(pass_index)];
            if (!source || !target) continue;

            SDL_GPUColorTargetInfo pt{};
            pt.texture = target;
            pt.load_op = SDL_GPU_LOADOP_DONT_CARE;
            pt.store_op = SDL_GPU_STOREOP_STORE;
            SDL_GPURenderPass* pp = SDL_BeginGPURenderPass(cmd, &pt, 1, nullptr);
            SDL_BindGPUGraphicsPipeline(pp, preview_pipeline);
            SDL_GPUTextureSamplerBinding bind{source, preview_sampler};
            SDL_BindGPUFragmentSamplers(pp, 0, &bind, 1);
            SDL_DrawGPUPrimitives(pp, 3, 1, 0, 0);
            SDL_EndGPURenderPass(pp);
        }
        SDL_GPUTexture* final_target = preview_tex.back();
        SDL_GPUColorTargetInfo pt{};
        pt.texture = final_target;
        pt.load_op = SDL_GPU_LOADOP_DONT_CARE;
        pt.store_op = SDL_GPU_STOREOP_STORE;
        SDL_GPURenderPass* pp = SDL_BeginGPURenderPass(cmd, &pt, 1, nullptr);
        SDL_BindGPUGraphicsPipeline(pp, preview_pipeline);
        SDL_GPUTextureSamplerBinding bind{scene_tex, preview_sampler};
        SDL_BindGPUFragmentSamplers(pp, 0, &bind, 1);
        SDL_DrawGPUPrimitives(pp, 3, 1, 0, 0);
        SDL_EndGPURenderPass(pp);
    }

    // NOTE: the scene->swapchain blit happens in the HOST's frame command
    // buffer (gfx_begin_frame) AFTER this submission, matching the Odin
    // host: same-buffer sample-after-write presented black on Metal.
    return SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
}

bool scene_has_debug_watches(const Runtime_Scene& scene) {
    for (const Scene_Pass& pass : scene.passes)
        if (pass.debug_compute_buffer || pass.debug_fragment_buffer) return true;
    return false;
}

} // namespace scene
