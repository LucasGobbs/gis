// Scene runtime: discovery (builtin + gis_scenes with shadowing), manifest
// generation, goose-build subprocess on a worker thread, reflection-driven
// pipeline creation, per-frame uniform fill, pass submission, hot reload
// with last-good retention. Direct port of src/scene_runtime.odin +
// src/targets.odin + src/pipeline.odin (adapter layer).
#pragma once

#include "gfx.hpp"
#include "camera.hpp"
#include "render_graph/refl.hpp"
#include "render_graph/render_graph.hpp"

#include <SDL3/SDL_gpu.h>

#include <cstdint>
#include <map>
#include <mutex>
#include <condition_variable>
#include <string>
#include <thread>
#include <vector>

namespace scene {

constexpr const char* SCENES_DIR = "src/shaders/scenes";
constexpr const char* USER_SCENES_DIR = "gis_scenes";
constexpr const char* GENERATED_DIR = "src/generated/scenes";
constexpr const char* SCENES_MANIFEST = "src/generated/scenes/manifest.json";
constexpr const char* SCENE_FMT = "msl";       // metal on darwin
constexpr const char* SCENE_TARGET = "metal";  // hot-reload goose target
constexpr int PREVIEW_SIZE = 128;
constexpr int DEBUG_WATCH_COUNT = 8;
constexpr uint32_t MODEL_PITCH = 32;
constexpr uint32_t MODEL_OFF_POS = 0, MODEL_OFF_NRM = 12, MODEL_OFF_UV = 24;
constexpr const char* SHARED_SHADER_MODULES[] = {"common", "space", "camera", "noise", "sdf"};

enum class Scene_Kind { GRAPHICS, COMPUTE };

// ---- Reflection-derived per-pass data (ScenePass in Odin) ----

struct Uniform_Field {
    std::string name;
    uint32_t offset = 0;
    uint32_t size = 0;
};

struct Uniform_Widget {
    enum class Kind { SLIDER, TOGGLE, COLOR } kind = Uniform_Widget::Kind::SLIDER;
    float min = 0, max = 0, step = 0;
    float value[3] = {0, 0, 0};
    bool on = false;
    bool node = false; // [NodeUICheck]/[NodeUISlider]
    std::string label;
    std::string module; // source module that declared the field (entry or pass_N)
    std::string param;  // cbuffer name (display label)
};

struct CBuffer {
    std::string name;
    uint32_t compute_slot = 0;
    uint32_t vert_slot = 0;
    uint32_t frag_slot = 0;
    bool in_vert = false;
    bool in_frag = false;
    std::vector<Uniform_Field> fields;
    std::vector<uint8_t> block;
};

struct Scene_Pass {
    std::string name;
    std::string graph_key;
    Scene_Kind kind = Scene_Kind::GRAPHICS;
    SDL_GPUComputePipeline* compute = nullptr;
    SDL_GPUGraphicsPipeline* graphics = nullptr;
    uint32_t thread[3] = {8, 8, 1};
    std::vector<std::string> sampler_textures;
    std::vector<std::string> sampler_names;
    std::vector<CBuffer> cbuffers;
    std::string entry;        // compute entry
    std::string entry_vert;
    std::string entry_frag;
    bool debug_compute_buffer = false;
    uint32_t debug_compute_slot = 0;
    bool debug_fragment_buffer = false;
    uint32_t debug_fragment_slot = 0;
    std::string debug_watch_labels[DEBUG_WATCH_COUNT];
    bool uses_model = false;
    std::vector<SDL_GPUVertexAttribute> vertex_attrs;
    // reflection counts kept for rebuild
    refl::ResourceCounts vert_counts;
    refl::ResourceCounts frag_counts;
    refl::ResourceCounts compute_counts;
};

struct Runtime_Scene {
    std::string title;
    std::string source;
    uint64_t mtime = 0; // latest modification across entry + modules
    bool loaded = false;
    bool user_owned = false;
    std::vector<Scene_Pass> passes;
    std::vector<Uniform_Widget> widgets;
    Scene_Kind kind = Scene_Kind::GRAPHICS;
    bool uses_model = false;
    std::string model; // mesh node's assets/models basename ("" = default)
    // Per-pass uobj routes: pass index → model path (graph.json "object"
    // nodes). The host uploads each and fills Scene_Resources maps.
    std::map<int, std::string> pass_model_paths;
    // Texture node sampler settings: node key ("uimg:<path>:texture") →
    // {filter, address} from the graph editor node fields; "" = unset
    // (defaults linear/clamp).
    std::map<std::string, std::pair<std::string, std::string>> node_sampler_settings;
    render_graph::Plan pipeline;
    uint64_t pipeline_mtime = 0;
    std::string pipeline_error;
};

struct Scene_Manager {
    std::vector<Runtime_Scene> scenes;
    int current = 0;
};

// Offscreen targets (targets.odin).
struct Render_Targets {
    SDL_GPUTexture* scene = nullptr;
    SDL_GPUTexture* depth = nullptr;
    std::vector<SDL_GPUTexture*> passes;
    std::vector<SDL_GPUTexture*> previews;
    int w = 0, h = 0;
};

bool targets_needs_resize(const Render_Targets& t, int width, int height, int pass_count);
bool targets_resize(Render_Targets& t, SDL_GPUDevice* gpu, int width, int height, int pass_count);
void targets_destroy(SDL_GPUDevice* gpu, Render_Targets& t);

// Scene resources for submission. Assets mirror the Odin SceneResources:
// paper is the default binding for unmet texture inputs, skybox feeds
// skybox_tex, model is the drawn vertex stream (assets module owns them).
struct Scene_Resources {
    SDL_GPUTexture* depth_tex = nullptr;
    SDL_GPUSampler* sampler = nullptr;
    SDL_GPUTexture* paper_texture = nullptr;
    SDL_GPUTexture* skybox_texture = nullptr; // null = none (-1 in Odin)
    SDL_GPUBuffer* model_vb = nullptr;        // default (no uobj route)
    SDL_GPUBuffer* model_ib = nullptr;
    uint32_t model_index_count = 0;
    SDL_GPUTexture* model_base_color_texture = nullptr;  // current model's base color
    SDL_GPUSampler* model_base_color_sampler = nullptr;
    // Per-pass model from uobj routes: pass index → uploaded buffers. Filled
    // at scene load; passes without a mesh route use the default above.
    std::map<int, SDL_GPUBuffer*> pass_model_vb;
    std::map<int, SDL_GPUBuffer*> pass_model_ib;
    // Graph-routed user textures/samplers (path → resolved GPU object).
    // Host-owned, app lifetime; loaded once per path, failures reported
    // once and left absent (bind falls through to the default).
    std::map<std::string, SDL_GPUTexture*> user_textures;
    std::map<std::string, SDL_GPUSampler*> user_samplers;
    std::map<int, uint32_t> pass_model_index_count;
    std::vector<SDL_GPUTexture*> pass_tex;
    SDL_GPUTexture* black_texture = nullptr;
    SDL_GPUSampler* black_sampler = nullptr;
    SDL_GPUBuffer* debug_watch_buffer = nullptr;
};

// ---- Discovery ----
std::vector<std::string> scene_names_on_disk(std::map<std::string, std::string>& scene_roots);
std::string scene_root_dir(const std::map<std::string, std::string>& scene_roots,
                           const std::string& name);
std::string scene_entry_path(const std::map<std::string, std::string>& scene_roots,
                             const std::string& name);
std::vector<std::string> scene_module_names(const std::map<std::string, std::string>& scene_roots,
                                            const std::string& name);
uint64_t scene_latest_mtime(const std::map<std::string, std::string>& scene_roots,
                            const std::string& name);

// ---- Build (worker thread) ----
bool scenes_build(const std::vector<std::string>& names,
                  const std::map<std::string, std::string>& scene_roots);

struct Build_State {
    std::mutex mu;
    std::condition_variable cond;
    std::condition_variable apply_cond;
    bool req = false;
    bool running = false;
    bool done = false;
    bool ok = false;
    bool again = false;
    bool applying = false;
    bool stop = false;
    std::vector<std::string> names;
    std::thread thread;
    bool thread_started = false;
    ~Build_State() {
        {
            std::lock_guard<std::mutex> lock(mu);
            stop = true;
        }
        cond.notify_all();
        apply_cond.notify_all();
        if (thread_started && thread.joinable()) thread.join();
    }
};

void scene_request_build(Build_State& build, const std::vector<std::string>& names);
// Applies a finished build on the caller (main) thread; returns true when a
// build was consumed.
bool scene_build_pump(Build_State& build, Scene_Manager& manager, SDL_GPUDevice* gpu,
                      const std::map<std::string, std::string>& scene_roots,
                      std::map<std::string, uint64_t>& scene_failed);

// ---- Load / reload ----
bool scene_load_into(SDL_GPUDevice* gpu, Runtime_Scene& dest, const std::string& name,
                     const std::map<std::string, std::string>& scene_roots);
bool scene_load(Scene_Manager& manager, SDL_GPUDevice* gpu, const std::string& name,
                const std::map<std::string, std::string>& scene_roots);
void scene_release(SDL_GPUDevice* gpu, Runtime_Scene& scene);
void scene_release_pass(SDL_GPUDevice* gpu, Scene_Pass& pass);
void scene_reload(Scene_Manager& manager, SDL_GPUDevice* gpu,
                  const std::map<std::string, std::string>& scene_roots,
                  const std::vector<std::string>& names,
                  std::map<std::string, uint64_t>& scene_failed);

// ---- Pipeline adapter (pipeline.odin) ----
bool pipeline_scene_init(Runtime_Scene& scene,
                         const std::map<std::string, std::string>& scene_roots,
                         std::string& error);
std::vector<render_graph::Pass_Descriptor> scene_pass_descriptors(const Runtime_Scene& scene);
int pipeline_plan_source(const render_graph::Plan& plan, int consumer,
                         const std::string& input_name);
bool pipeline_plan_resource(const render_graph::Plan& plan, int consumer,
                            const std::string& input_name, render_graph::Resource_Kind kind,
                            std::string& path);
bool pipeline_plan_equal(const render_graph::Plan& a, const render_graph::Plan& b);

// ---- Submission ----
SDL_GPUTexture* scene_pass_texture(const Runtime_Scene& scene, SDL_GPUTexture* scene_tex,
                                   const Scene_Resources& res, int pass_index);
void push_scene_uniforms(SDL_GPUCommandBuffer* cmd, Scene_Pass& pass, bool compute);
SDL_GPUFence* submit_scene_frame(SDL_GPUDevice* gpu,
                                 Runtime_Scene& scene, SDL_GPUTexture* scene_tex,
                                 Scene_Resources& resources, int width, int height,
                                 SDL_GPUGraphicsPipeline* preview_pipeline,
                                 SDL_GPUGraphicsPipeline* blit_pipeline,
                                 SDL_GPUSampler* blit_sampler,
                                 SDL_GPUSampler* preview_sampler,
                                 std::vector<SDL_GPUTexture*>& preview_tex);

// Bind resolution (submit loop), exposed for unit tests. resolve_bind_
// texture: producer (caller-side) > user texture route > named fallbacks
// (skybox_tex/input_tex) > fallback. resolve_bind_sampler: the SAMPLER
// route's image file → host sampler object for that slot.
SDL_GPUTexture* resolve_bind_texture(const Runtime_Scene& scene,
                                     const Scene_Resources& resources, int pass_index,
                                     const std::string& input_name,
                                     SDL_GPUTexture* fallback);
SDL_GPUSampler* resolve_bind_sampler(const Runtime_Scene& scene,
                                     const Scene_Resources& resources, int pass_index,
                                     int slot, SDL_GPUSampler* fallback);

// Uniform fill (scene_write_uniforms): values the app pokes per frame.
// The camera uniforms (iViewProjection + iCamera*) come from the host's
// camera::Uniforms (src/gfx/camera.hpp) — the host owns the camera state.
void scene_write_uniforms(Runtime_Scene& scene, float res_x, float res_y, float time_s,
                          bool color, float mouse_x, float mouse_y, bool mouse_click,
                          const camera::Uniforms& cam);

// Watches.
bool scene_has_debug_watches(const Runtime_Scene& scene);

} // namespace scene
