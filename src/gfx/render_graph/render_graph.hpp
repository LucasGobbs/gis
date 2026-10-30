// render_graph: graph.json is both the node-editor document and the runtime
// pipeline manifest. Direct port of src/render_graph/render_graph.odin.
// Reflection remains authoritative for pass interfaces; links are semantic;
// node positions are presentation state only.
#pragma once

#include <string>
#include <vector>

namespace render_graph {

constexpr int GRAPH_SCHEMA_VERSION = 1;
// Upper bound the adapter passes to plan_path; the caller decides the real
// value (DEBUG_WATCH_MAX_PASSES in the app).
constexpr int PLAN_PATH_MAX_PASSES = 8;

struct Node_Json {
    std::string key;
    std::string kind;
    float x = 0, y = 0;
    // User-authored resource nodes ("uimg:"/"uobj:" keys).
    std::string file;
    std::string source;   // "file" (default) | "target"
    std::string model;    // mesh nodes: assets/models basename to render
    std::string filter;   // "point"|"linear"
    std::string address;  // "clamp"|"repeat"|"mirror"
    int width = 0, height = 0;  // targets only
    float value = 0;            // persisted widget value for "ui:" nodes
};

struct Link_Json {
    std::string from;
    std::string to;
};

struct Graph_Json {
    int version = 0;
    std::string scene;
    std::vector<Node_Json> nodes;
    std::vector<Link_Json> links;
};

// Reflection snapshot of one pass, owned by the caller (adapter). The plan
// borrows key/name/input_textures; it never deletes them.
struct Pass_Descriptor {
    std::string key;
    std::string name;
    std::vector<std::string> input_textures;
    std::string output_pin;
    // True when the pass's vertex entry takes a stage_in ModelVertex: a MODEL
    // resource route may target it.
    bool uses_model = false;
    // Uniform (cbuffer) bindings the pass consumes: wireless inputs. The
    // params node broadcasts one output per unique block name across all
    // passes ("Uniforms (SceneUniforms)" style labels live in the editor).
    std::vector<std::string> uniform_blocks;
};

struct Route {
    int producer = -1;
    int consumer = -1;
    std::string input_name;
};

enum class Resource_Kind { TEXTURE, MODEL, SAMPLER };
enum class Resource_Source { FILE, TARGET_WRITE, TARGET_READ };

// One app-fed asset routed into a pass input ("uimg:assets/x.jpg:texture" ->
// "pass:b_tex"). input_name is the texture binding name, or "ModelVertex" for
// a model route. TARGET_READ is the delayed edge (reads last frame's result),
// TARGET_WRITE the write side.
struct Resource_Route {
    int consumer = -1;
    std::string input_name;
    Resource_Kind kind = Resource_Kind::TEXTURE;
    Resource_Source source = Resource_Source::FILE;
    std::string path;
};

struct Plan {
    std::vector<int> order;
    std::vector<Route> routes;
    int output_pass = -1;
    std::vector<Resource_Route> resources;
};

std::string graph_path(const std::string& scene, const std::string& scene_root);
void plan_destroy(Plan& plan);
std::string endpoint(const std::string& node_key, const std::string& pin_name);
// Finds the pass endpoint "<key>:<pin>": returns pass index + pin name.
bool find_pass_endpoint(const std::vector<Pass_Descriptor>& passes, const std::string& endpoint,
                        int& pass_index, std::string& pin_name);
Plan plan_default(const std::vector<Pass_Descriptor>& passes);
// Builds a validated plan from the doc. On failure returns ok=false with the
// same error strings as the Odin original (tests match them verbatim).
Plan plan_build(const std::vector<Pass_Descriptor>& passes, const Graph_Json& doc,
                std::string& error_message, bool& ok);
// Reachability path to output_pass, bounded by max_passes.
std::vector<bool> plan_path(const Plan& plan, int pass_count, int max_passes);
bool plan_equal(const Plan& a, const Plan& b);

} // namespace render_graph
