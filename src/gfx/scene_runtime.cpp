// Scene runtime implementation. Direct port of scene_runtime.odin +
// targets.odin + pipeline.odin adapter. Threads mirror the Odin design:
// scene_request_build → worker (goose-build subprocess) → scene_build_pump
// applies on the calling (main) thread.
#include "scene_runtime.hpp"
#include "camera.hpp"
#include <SDL3/SDL.h>

#include <algorithm>
#include <filesystem>
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
    std::error_code ec;
    std::filesystem::create_directories(GENERATED_DIR, ec); // fresh clone: dir may not exist yet
    for (int attempt = 0; attempt < 2; ++attempt) {
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
        // Lock exists: stale (older than 60 s) means take over and retry once.
        struct stat st;
        if (::stat(lock_path.c_str(), &st) != 0) return false; // cannot create it and it is not there
        uint64_t age = file_mtime(lock_path);
        uint64_t now = uint64_t(::time(nullptr)) * 1000000000ull;
        if (now - age <= 60000000000ull) return true; // held by another instance; next rescan picks up
        ::remove(lock_path.c_str());
    }
    return false;
}

// ---- Worker thread (scene_build_worker / scene_request_build / pump) ----

static void build_worker(Build_State* build) {
    for (;;) {
        std::vector<std::string> names;
        {
            std::unique_lock<std::mutex> lock(build->mu);
            build->cond.wait(lock, [&] { return build->req || build->stop; });
            if (build->stop) return;
            build->req = false;
            build->running = true;
            names = build->names;
            // Wait for an unconsumed result and any in-flight apply: the pump
            // reads artifacts from the moment `done` is set until it finishes.
            build->apply_cond.wait(lock, [&] {
                return (!build->applying && !build->done) || build->stop;
            });
            if (build->stop) return;
        }
        // The worker re-scans disk for the roots snapshot (cheap, few dirs).
        std::map<std::string, std::string> roots_snapshot;
        scene_names_on_disk(roots_snapshot);
        scenes_build(names, roots_snapshot);
        {
            std::lock_guard<std::mutex> lock(build->mu);
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
                      const std::map<std::string, std::string>& scene_roots) {
    {
        std::lock_guard<std::mutex> lock(build.mu);
        if (!build.done) return false;
        build.done = false;
        // Arm the apply guard: the worker must not rewrite artifacts while
        // this pump is reading them on the main thread.
        build.applying = true;
    }
    // Reload active scene on the main thread (pipeline creation needs GPU).
    // A failed reload keeps the last-good pipeline running.
    bool swapped = false;
    std::string name;
    if (!manager.scenes.empty()) {
        Runtime_Scene& current = manager.scenes[size_t(manager.current)];
        name = current.title;
        Runtime_Scene candidate;
        if (scene_load_into(gpu, candidate, name, scene_roots)) {
            scene_release(gpu, current);
            current = std::move(candidate);
            swapped = true;
        }
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
    if (again && !name.empty()) scene_request_build(build, {name});
    return swapped;
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
    // Slang's TEXCOORD_1 fragCoord varying works on this SDL+Metal path; no MSL rewrite needed.
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
    ci.num_readwrite_storage_buffers = counts.rw_buf;
    ci.num_uniform_buffers = counts.ubuf;
    ci.threadcount_x = thread[0];
    ci.threadcount_y = thread[1];
    ci.threadcount_z = thread[2];
    return SDL_CreateGPUComputePipeline(gpu, &ci);
}

// Builds a pipeline from an already-created shader pair. `cull` selects the
// per-draw variant: doubleSided materials use NONE (second pipeline), others BACK.
static SDL_GPUGraphicsPipeline* build_graphics_pipeline(SDL_GPUDevice* gpu, SDL_GPUShader* vs,
                                                        SDL_GPUShader* fs, const Scene_Pass& pass,
                                                        SDL_GPUCullMode cull) {
    SDL_GPUGraphicsPipelineCreateInfo ci{};
    ci.vertex_shader = vs;
    ci.fragment_shader = fs;
    ci.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    ci.rasterizer_state.fill_mode = SDL_GPU_FILLMODE_FILL;
    ci.rasterizer_state.cull_mode = cull;
    ci.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
    ci.target_info.num_color_targets = 1;
    SDL_GPUColorTargetDescription target{};
    target.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM; // the scene texture
    ci.target_info.color_target_descriptions = &target;
    SDL_GPUVertexBufferDescription vb_desc{0, MODEL_PITCH, SDL_GPU_VERTEXINPUTRATE_VERTEX, 0};
    if (pass.uses_model) {
        ci.vertex_input_state.num_vertex_buffers = 1;
        ci.vertex_input_state.vertex_buffer_descriptions = &vb_desc;
        ci.vertex_input_state.num_vertex_attributes = uint32_t(pass.vertex_attrs.size());
        ci.vertex_input_state.vertex_attributes = pass.vertex_attrs.data();
        ci.target_info.has_depth_stencil_target = true;
        ci.target_info.depth_stencil_format = SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
        ci.depth_stencil_state.compare_op = SDL_GPU_COMPAREOP_LESS;
        ci.depth_stencil_state.enable_depth_test = true;
        ci.depth_stencil_state.enable_depth_write = true;
    }
    return SDL_CreateGPUGraphicsPipeline(gpu, &ci);
}

// Creates pass.graphics (and graphics_double_sided for model passes) from one
// compiled shader pair.
static bool create_graphics_pipelines(SDL_GPUDevice* gpu, const std::string& vert_path,
                                      const std::string& frag_path, Scene_Pass& pass) {
    SDL_GPUShader* vs = load_shader_raw(gpu, vert_path, pass.entry_vert,
                                        SDL_GPU_SHADERSTAGE_VERTEX, pass.vert_counts);
    if (!vs) return false;
    SDL_GPUShader* fs = load_shader_raw(gpu, frag_path, pass.entry_frag,
                                        SDL_GPU_SHADERSTAGE_FRAGMENT, pass.frag_counts);
    if (!fs) {
        SDL_ReleaseGPUShader(gpu, vs);
        return false;
    }
    pass.graphics = build_graphics_pipeline(gpu, vs, fs, pass, SDL_GPU_CULLMODE_BACK);
    if (pass.graphics && pass.uses_model)
        pass.graphics_double_sided =
            build_graphics_pipeline(gpu, vs, fs, pass, SDL_GPU_CULLMODE_NONE);
    SDL_ReleaseGPUShader(gpu, vs);
    SDL_ReleaseGPUShader(gpu, fs);
    return pass.graphics != nullptr;
}

// ---- Reflection parse into Scene_Pass (scene_parse_stage_refl + widgets) ----

// Stage-specific entry, counts, thread size, samplers and model vertex layout.
static void apply_stage_info(Scene_Pass& pass, const refl::Stage_Refl& st, refl::Stage_Kind stage) {
    if (stage == refl::Stage_Kind::COMPUTE) {
        pass.entry = st.entry;
        pass.thread[0] = st.thread[0];
        pass.thread[1] = st.thread[1];
        pass.thread[2] = st.thread[2];
        pass.compute_counts = st.counts;
        pass.debug_compute_buffer = st.has_debug_storage;
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
        pass.sampler_textures = st.sampler_textures;
        pass.sampler_names = st.sampler_names;
    }
}

// Merges the stage's cbuffers into the pass (shared by name across stages).
static void merge_cbuffers(Scene_Pass& pass, const refl::Stage_Refl& st, refl::Stage_Kind stage) {
    for (const refl::CBuffer& src : st.cbuffers) {
        CBuffer* cb = nullptr;
        for (CBuffer& existing : pass.cbuffers) {
            if (existing.name == src.name) { cb = &existing; break; }
        }
        if (!cb) {
            CBuffer fresh;
            fresh.name = src.name;
            for (const refl::Field& f : src.fields) {
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
    }
}

static bool parse_pass_stage(Scene_Pass& pass, const refl::Json& root, refl::Stage_Kind stage) {
    refl::Stage_Refl st;
    if (!refl::parse_stage_refl(st, root, stage)) return false;
    apply_stage_info(pass, st, stage);
    merge_cbuffers(pass, st, stage);
    return true;
}

// Fills `widget` from one userAttrib ([UiSlider]/[UiToggle]/[UiColor] and the
// Node* variants); false for any other attribute.
static bool widget_from_attrib(const refl::Json& attr, Uniform_Widget& widget) {
    const std::string& aname = attr["name"].str;
    const refl::Json& args = attr["arguments"];
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
        return false;
    }
    return true;
}

// Extracts widget attributes; separate pass over the raw JSON. module = the
// reflection unit (scene entry or <scene>__<module> pass) the buffer came
// from, so the UI can group params per file. Widgets dedupe by label.
static void parse_widgets(Runtime_Scene& scene, const refl::Json& root,
                          const std::string& module) {
    for (const refl::Json& param : root["parameters"].arr) {
        if (param["type"]["kind"].str != "constantBuffer") continue;
        for (const refl::Json& f : param["type"]["elementVarLayout"]["type"]["fields"].arr) {
            for (const refl::Json& attr : f["userAttribs"].arr) {
                Uniform_Widget widget;
                widget.label = f["name"].str;
                widget.module = module;
                widget.param = param["name"].str;
                if (!widget_from_attrib(attr, widget)) continue;
                bool seen = false;
                for (const Uniform_Widget& existing : scene.widgets)
                    if (existing.label == widget.label) { seen = true; break; }
                if (!seen) scene.widgets.push_back(widget);
            }
        }
    }
}

// ---- scene_parse_pass + scene_parse_reflection ----

static bool parse_stage_file(Runtime_Scene& scene, Scene_Pass& pass, const std::string& name,
                             const std::string& refl_path, refl::Stage_Kind stage) {
    bool ok = false;
    refl::Json root = refl::json_parse_file(refl_path, ok);
    if (!ok) return false;
    parse_widgets(scene, root, name);
    return parse_pass_stage(pass, root, stage);
}

static bool scene_parse_pass(SDL_GPUDevice* gpu, Runtime_Scene& scene, const std::string& name,
                             Scene_Pass& pass) {
    pass.name = name;
    const std::string base = std::string(GENERATED_DIR) + "/" + name;
    const std::string compute_refl = base + ".compute." + SCENE_FMT + ".refl.json";
    const std::string vert_refl = base + ".vert." + SCENE_FMT + ".refl.json";
    const std::string frag_refl = base + ".frag." + SCENE_FMT + ".refl.json";

    if (std::ifstream(compute_refl).good()) {
        pass.kind = Scene_Kind::COMPUTE;
        if (!parse_stage_file(scene, pass, name, compute_refl, refl::Stage_Kind::COMPUTE))
            return false;
        pass.compute = create_compute_pipeline_raw(
            gpu, base + ".compute." + SCENE_FMT, pass.entry, pass.compute_counts, pass.thread);
        return pass.compute != nullptr;
    }
    if (std::ifstream(vert_refl).good() && std::ifstream(frag_refl).good()) {
        pass.kind = Scene_Kind::GRAPHICS;
        if (!parse_stage_file(scene, pass, name, vert_refl, refl::Stage_Kind::VERTEX) ||
            !parse_stage_file(scene, pass, name, frag_refl, refl::Stage_Kind::FRAGMENT))
            return false;
        if (!create_graphics_pipelines(gpu, base + ".vert." + SCENE_FMT,
                                       base + ".frag." + SCENE_FMT, pass)) {
            std::fprintf(stderr, "scene: failed to create graphics pipeline %s: %s\n",
                         (base + ".frag." + SCENE_FMT).c_str(), SDL_GetError());
            return false;
        }
        return true;
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
        if (!scene_parse_pass(gpu, scene, names[i], pass)) {
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
        d.input_samplers = pass.sampler_names;
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
        // Mesh node's model pick (Plan: dragon showcase). First mesh node
        // with a "model" field wins; empty = host default (models[0]).
        for (const auto& n : doc.nodes) {
            if (n.kind == "mesh" && !n.model.empty()) {
                scene.model = n.model;
                break;
            }
        }
        // Texture node sampler settings for the host's sampler-route
        // override (per-node filter/address; "" = host defaults).
        for (const auto& n : doc.nodes) {
            if (n.kind == "texture" && !n.file.empty())
                scene.node_sampler_settings[n.key] = {
                    n.filter.empty() ? "linear" : n.filter,
                    n.address.empty() ? "clamp" : n.address};
        }
        // Per-pass uobj routes: each MODEL route names a glb; the pass draws
        // THAT model (graph inputs drive geometry).
        for (const auto& r : candidate.resources) {
            if (r.kind == render_graph::Resource_Kind::MODEL &&
                r.consumer >= 0 && !r.path.empty())
                scene.pass_model_paths[size_t(r.consumer)] = r.path;
        }
    }
    if (!error.empty()) {
        // Last-good contract (Odin parity): a broken graph.json must not take
        // the scene down. Run the declaration-order default plan and surface
        // the error; the next valid save rebuilds the authored pipeline.
        candidate = render_graph::plan_default(scene_pass_descriptors(scene));
        scene.pipeline = std::move(candidate);
        scene.pipeline_error = error;
        return true;
    }
    scene.pipeline = std::move(candidate);
    scene.pipeline_error.clear();
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

// ---- Load / release / reload ----

void scene_release_pass(SDL_GPUDevice* gpu, Scene_Pass& pass) {
    if (pass.compute) SDL_ReleaseGPUComputePipeline(gpu, pass.compute);
    if (pass.graphics) SDL_ReleaseGPUGraphicsPipeline(gpu, pass.graphics);
    if (pass.graphics_double_sided) SDL_ReleaseGPUGraphicsPipeline(gpu, pass.graphics_double_sided);
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

// ---- Uniform fill + submission ----

static void poke_f32(std::vector<uint8_t>& block, uint32_t offset, float value) {
    if (offset + 4 <= block.size()) std::memcpy(block.data() + offset, &value, 4);
}
static void poke_u32(std::vector<uint8_t>& block, uint32_t offset, uint32_t value) {
    if (offset + 4 <= block.size()) std::memcpy(block.data() + offset, &value, 4);
}

struct Frame_Values {
    float res_x, res_y, time_s;
    bool color;
    float mouse_x, mouse_y;
    bool mouse_click;
    const camera::Uniforms& cam;
};

static void poke_floats(std::vector<uint8_t>& block, uint32_t offset, const float* v, int n) {
    for (int i = 0; i < n; ++i) poke_f32(block, offset + uint32_t(i) * 4, v[i]);
}

// Per-frame values the app owns, matched by reflected field name.
static void write_builtin_uniform(CBuffer& cb, const Uniform_Field& field,
                                  const Frame_Values& fv) {
    const std::string& name = field.name;
    const uint32_t off = field.offset;
    if (name == "iResolution") {
        const float v[3] = {fv.res_x, fv.res_y, 1.0f};
        poke_floats(cb.block, off, v, 3);
    } else if (name == "iTime") {
        poke_f32(cb.block, off, fv.time_s);
    } else if (name == "iFbm") {
        const float v[3] = {6.0f, 2.03f, 0.5f};
        poke_floats(cb.block, off, v, 3);
    } else if (name == "iColorMode") {
        poke_f32(cb.block, off, fv.color ? 1.0f : 0.0f);
    } else if (name == "iMousePos") {
        const float v[2] = {fv.mouse_x, fv.mouse_y};
        poke_floats(cb.block, off, v, 2);
    } else if (name == "iMouseClick") {
        poke_f32(cb.block, off, fv.mouse_click ? 1.0f : 0.0f);
    } else if (name == "iViewProjection") {
        poke_floats(cb.block, off, fv.cam.view_projection, 16);
    } else if (name == "iCameraPosition") {
        poke_floats(cb.block, off, fv.cam.position, 3);
    } else if (name == "iCameraRight") {
        poke_floats(cb.block, off, fv.cam.right, 3);
    } else if (name == "iCameraUp") {
        poke_floats(cb.block, off, fv.cam.up, 3);
    } else if (name == "iCameraForward") {
        poke_floats(cb.block, off, fv.cam.forward, 3);
    } else if (name == "iManual") {
        poke_f32(cb.block, off, 1.0f);
    } else if (name == "iDebugPixel" || name == "iDebugEnabled" || name == "iDebugFrame") {
        poke_u32(cb.block, off, 0);
    }
}

// Widgets fan out to every pass cbuffer matching by field name.
static void write_widget_uniforms(Runtime_Scene& scene) {
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
                        poke_floats(cb.block, field.offset, widget.value, 3);
                        break;
                    }
                }
            }
        }
    }
}

void scene_write_uniforms(Runtime_Scene& scene, float res_x, float res_y, float time_s,
                          bool color, float mouse_x, float mouse_y, bool mouse_click,
                          const camera::Uniforms& cam) {
    const Frame_Values fv{res_x, res_y, time_s, color, mouse_x, mouse_y, mouse_click, cam};
    for (Scene_Pass& pass : scene.passes)
        for (CBuffer& cb : pass.cbuffers)
            for (const Uniform_Field& field : cb.fields) write_builtin_uniform(cb, field, fv);
    write_widget_uniforms(scene);
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

// Bind resolution for the submit loop, split out for testability (no GPU
// needed: the maps hold plain pointers). Returns the texture to bind, or
// `fallback` when no graph route applies (caller keeps paper/skybox).
// Order: producer pass (handled by the caller) > user texture route >
// named skybox/input_tex fallbacks > `fallback`.
SDL_GPUTexture* resolve_bind_texture(const Runtime_Scene& scene,
                                     const Scene_Resources& resources, int pass_index,
                                     const std::string& input_name,
                                     SDL_GPUTexture* fallback) {
    std::string tex_path;
    if (pipeline_plan_resource(scene.pipeline, pass_index, input_name,
                               render_graph::Resource_Kind::TEXTURE, tex_path)) {
        auto it = resources.user_textures.find(tex_path);
        if (it != resources.user_textures.end()) return it->second;
        // Route present but asset failed to load: bind black (the user
        // decision — a visible hole beats silently showing paper).
        return resources.black_texture ? resources.black_texture : fallback;
    }
    if (input_name == "skybox_tex" && resources.skybox_texture)
        return resources.skybox_texture;
    if (input_name == "base_color_tex") {
        // Untextured model samples white: material color stays unscaled.
        auto pm = resources.pass_model_base_color.find(pass_index);
        if (pm != resources.pass_model_base_color.end())
            return pm->second ? pm->second : resources.white_texture;
        if (resources.model_base_color_texture) return resources.model_base_color_texture;
        return resources.white_texture ? resources.white_texture : fallback;
    }
    if (input_name == "input_tex") return resources.black_texture;
    return fallback;
}

// Sampler override for a bound slot: the plan's SAMPLER route names the
// image file; the owning texture node's filter/address selects the host
// sampler. No route / no object = the app default sampler.
SDL_GPUSampler* resolve_bind_sampler(const Runtime_Scene& scene,
                                     const Scene_Resources& resources, int pass_index,
                                     int slot, SDL_GPUSampler* fallback) {
    if (pass_index < 0 || pass_index >= int(scene.passes.size())) return fallback;
    if (slot >= int(scene.passes[size_t(pass_index)].sampler_textures.size()))
        return fallback;
    const std::string& name = scene.passes[size_t(pass_index)].sampler_textures[size_t(slot)];

    // Named sampler fallbacks for model textures
    if (name == "base_color_tex") {
        auto pm = resources.pass_model_base_sampler.find(pass_index);
        if (pm != resources.pass_model_base_sampler.end() && pm->second)
            return pm->second;
        if (resources.model_base_color_sampler) return resources.model_base_color_sampler;
    }

    std::string s_path;
    if (!pipeline_plan_resource(scene.pipeline, pass_index, name,
                                render_graph::Resource_Kind::SAMPLER, s_path))
        return fallback;
    auto it = resources.user_samplers.find(s_path);
    return it != resources.user_samplers.end() ? it->second : fallback;
}

// Texture/sampler bindings for one pass, in sampler_textures slot order.
// Resolution order (legacy parity): producer pass wins, then a graph-routed
// user texture, then the skybox/input_tex named fallbacks, then the app's
// paper texture.
static std::vector<SDL_GPUTextureSamplerBinding> bind_pass_samplers(
    const Runtime_Scene& scene, SDL_GPUTexture* scene_tex, const Scene_Resources& resources,
    int pass_index, const Scene_Pass& pass) {
    const size_t sampler_count = pass.sampler_textures.size();
    std::vector<SDL_GPUTextureSamplerBinding> bindings(sampler_count > 0 ? sampler_count : 1);
    for (size_t slot = 0; slot < sampler_count; ++slot) {
        const std::string& name = pass.sampler_textures[slot];
        SDL_GPUTexture* texture = resources.paper_texture ? resources.paper_texture
                                                          : resources.black_texture;
        int producer = pipeline_plan_source(scene.pipeline, pass_index, name);
        if (producer >= 0)
            texture = scene_pass_texture(scene, scene_tex, resources, producer);
        else
            texture = resolve_bind_texture(scene, resources, pass_index, name, texture);
        bindings[slot].texture = texture;
        bindings[slot].sampler =
            resolve_bind_sampler(scene, resources, pass_index, int(slot), resources.sampler);
    }
    return bindings;
}

static void encode_compute_pass(SDL_GPUCommandBuffer* cmd, Scene_Pass& pass,
                                SDL_GPUTexture* out_tex,
                                std::vector<SDL_GPUTextureSamplerBinding>& bindings,
                                const Scene_Resources& resources, int width, int height) {
    SDL_GPUStorageTextureReadWriteBinding tex_binding{};
    tex_binding.texture = out_tex;
    SDL_GPUStorageBufferReadWriteBinding buf_binding{};
    buf_binding.buffer = resources.debug_watch_buffer;
    SDL_GPUComputePass* compute_pass =
        pass.debug_compute_buffer && resources.debug_watch_buffer
            ? SDL_BeginGPUComputePass(cmd, &tex_binding, 1, &buf_binding, 1)
            : SDL_BeginGPUComputePass(cmd, &tex_binding, 1, nullptr, 0);
    SDL_BindGPUComputePipeline(compute_pass, pass.compute);
    const size_t sampler_count = pass.sampler_textures.size();
    if (sampler_count > 0)
        SDL_BindGPUComputeSamplers(compute_pass, 0, bindings.data(), uint32_t(sampler_count));
    push_scene_uniforms(cmd, pass, true);
    uint32_t tx = pass.thread[0], ty = pass.thread[1];
    SDL_DispatchGPUCompute(compute_pass, uint32_t((width + tx - 1) / tx),
                           uint32_t((height + ty - 1) / ty), 1);
    SDL_EndGPUComputePass(compute_pass);
}

struct Model_Draw {
    SDL_GPUBuffer* vb;
    SDL_GPUBuffer* ib;
    uint32_t index_count;
    bool double_sided;
};

// Per-pass uobj model when routed, else the default model.
static Model_Draw resolve_pass_model(const Scene_Resources& resources, int pass_index,
                                     const Scene_Pass& pass) {
    Model_Draw d{resources.model_vb, resources.model_ib, resources.model_index_count,
                 resources.model_double_sided};
    if (!pass.uses_model) return d;
    auto vb = resources.pass_model_vb.find(pass_index);
    if (vb != resources.pass_model_vb.end()) {
        auto ib = resources.pass_model_ib.find(pass_index);
        auto count = resources.pass_model_index_count.find(pass_index);
        d.vb = vb->second;
        d.ib = ib != resources.pass_model_ib.end() ? ib->second : nullptr;
        d.index_count = count != resources.pass_model_index_count.end() ? count->second : 0;
    }
    auto dbl = resources.pass_model_double_sided.find(pass_index);
    if (dbl != resources.pass_model_double_sided.end()) d.double_sided = dbl->second;
    return d;
}

// Model draw: fullscreen background first (iManual=1), then the indexed model
// depth-tested on top (iManual=0), matching the common.slang
// model_scene_vertex branch.
static void draw_model(SDL_GPUCommandBuffer* cmd, SDL_GPURenderPass* render_pass,
                       Scene_Pass& pass, const Model_Draw& d) {
    SDL_BindGPUGraphicsPipeline(render_pass, d.double_sided && pass.graphics_double_sided
                                                 ? pass.graphics_double_sided
                                                 : pass.graphics);
    SDL_GPUBufferBinding vb_binding{d.vb, 0};
    SDL_BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1);
    SDL_GPUBufferBinding ib_binding{d.ib, 0};
    SDL_BindGPUIndexBuffer(render_pass, &ib_binding, SDL_GPU_INDEXELEMENTSIZE_32BIT);
    scene_set_manual(pass, 1);
    push_scene_uniforms(cmd, pass, false);
    SDL_DrawGPUPrimitives(render_pass, 3, 1, 0, 0);
    scene_set_manual(pass, 0);
    push_scene_uniforms(cmd, pass, false);
    SDL_DrawGPUIndexedPrimitives(render_pass, d.index_count, 1, 0, 0, 0);
}

static void encode_graphics_pass(SDL_GPUCommandBuffer* cmd, Scene_Pass& pass, int pass_index,
                                 SDL_GPUTexture* out_tex,
                                 std::vector<SDL_GPUTextureSamplerBinding>& bindings,
                                 const Scene_Resources& resources, int width, int height) {
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
        SDL_BeginGPURenderPass(cmd, &color_target, 1, pass.uses_model ? &depth_target : nullptr);
    SDL_BindGPUGraphicsPipeline(render_pass, pass.graphics);
    if (!pass.sampler_textures.empty()) {
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
    const Model_Draw model = resolve_pass_model(resources, pass_index, pass);
    if (pass.uses_model && model.vb && model.ib) {
        draw_model(cmd, render_pass, pass, model);
    } else {
        push_scene_uniforms(cmd, pass, false);
        SDL_DrawGPUPrimitives(render_pass, 3, 1, 0, 0);
    }
    SDL_EndGPURenderPass(render_pass);
}

static void blit_to_preview(SDL_GPUCommandBuffer* cmd, SDL_GPUGraphicsPipeline* pipeline,
                            SDL_GPUSampler* sampler, SDL_GPUTexture* source,
                            SDL_GPUTexture* target) {
    SDL_GPUColorTargetInfo pt{};
    pt.texture = target;
    pt.load_op = SDL_GPU_LOADOP_DONT_CARE;
    pt.store_op = SDL_GPU_STOREOP_STORE;
    SDL_GPURenderPass* pp = SDL_BeginGPURenderPass(cmd, &pt, 1, nullptr);
    SDL_BindGPUGraphicsPipeline(pp, pipeline);
    SDL_GPUTextureSamplerBinding bind{source, sampler};
    SDL_BindGPUFragmentSamplers(pp, 0, &bind, 1);
    SDL_DrawGPUPrimitives(pp, 3, 1, 0, 0);
    SDL_EndGPURenderPass(pp);
}

SDL_GPUFence* submit_scene_frame(SDL_GPUDevice* gpu, Runtime_Scene& scene,
                                 SDL_GPUTexture* scene_tex, Scene_Resources& resources,
                                 int width, int height, SDL_GPUGraphicsPipeline* preview_pipeline,
                                 SDL_GPUSampler* preview_sampler,
                                 std::vector<SDL_GPUTexture*>& preview_tex) {
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

        std::vector<SDL_GPUTextureSamplerBinding> bindings =
            bind_pass_samplers(scene, scene_tex, resources, pass_index, pass);
        if (pass.kind == Scene_Kind::COMPUTE)
            encode_compute_pass(cmd, pass, out_tex, bindings, resources, width, height);
        else
            encode_graphics_pass(cmd, pass, pass_index, out_tex, bindings, resources, width, height);
    }

    // Previews: linear-blit each pass output (+ final) into fixed targets.
    if (preview_pipeline && preview_sampler && preview_tex.size() == scene.passes.size() + 1) {
        for (int pass_index : scene.pipeline.order) {
            SDL_GPUTexture* source = scene_pass_texture(scene, scene_tex, resources, pass_index);
            SDL_GPUTexture* target = preview_tex[size_t(pass_index)];
            if (!source || !target) continue;
            blit_to_preview(cmd, preview_pipeline, preview_sampler, source, target);
        }
        blit_to_preview(cmd, preview_pipeline, preview_sampler, scene_tex, preview_tex.back());
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
