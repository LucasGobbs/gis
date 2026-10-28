// graph.json + slang reflection parsers (stage 2 half of the gate). The
// reflection side ports the json helpers scene_runtime.odin uses: per-stage
// resource counts, cbuffer merge with widget attributes, entry points,
// sampler/texture pairing. JSON via a small recursive-descent reader
// (locale-proof float parsing; Qt's QApplication sets LC_ALL="").
#pragma once

#include "render_graph.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace refl {

struct Field {
    std::string name;
    uint32_t offset = 0;
    uint32_t size = 0;
};

struct CBuffer {
    std::string name;
    bool in_vert = false;
    bool in_frag = false;
    uint32_t vert_slot = 0; // MSL [[buffer(n)]] per stage
    uint32_t frag_slot = 0;
    uint32_t compute_slot = 0;
    std::vector<Field> fields;
    std::vector<uint8_t> block; // std140-rounded to 16
};

struct ResourceCounts {
    uint32_t samplers = 0;
    uint32_t ubuf = 0;
    uint32_t ro_buf = 0;
    uint32_t rw_buf = 0;
    uint32_t ro_tex = 0;
    uint32_t rw_tex = 0;
};

enum class Stage_Kind { VERTEX, FRAGMENT, COMPUTE };

struct Stage_Refl {
    std::string entry;
    uint32_t thread[3] = {8, 8, 1};
    ResourceCounts counts;
    std::vector<CBuffer> cbuffers;
    // debug_records RW storage: present + its RW-storage slot.
    bool has_debug_storage = false;
    uint32_t debug_storage_slot = 0;
    // Sampled textures in sampler-slot order; empty string = unused slot.
    std::vector<std::string> sampler_textures;
    std::vector<std::string> sampler_names;
    // Model pass: vertex entry takes a stage_in struct.
    bool uses_model = false;
};

// Minimal locale-proof JSON value tree.
struct Json {
    enum class Kind { NIL, BOOL, NUM, STR, ARR, OBJ };
    Kind kind = Kind::NIL;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<Json> arr;
    std::vector<std::pair<std::string, Json>> obj;

    const Json* get(const char* key) const {
        for (auto& [k, v] : obj)
            if (k == key) return &v;
        return nullptr;
    }
    const Json& operator[](const char* key) const {
        static const Json missing{}; // not `nil`: an Objective-C macro in .mm includers
        const Json* v = get(key);
        return v ? *v : missing;
    }
};

Json json_parse_file(const std::string& path, bool& ok);

// Parses one per-stage reflection file (<name>.<stage>.msl.refl.json).
// Mirrors scene_parse_stage_refl + parse_cbuffers + count_resources +
// debug_buffer_slot + the sampler/texture pairing from scene_runtime.odin.
bool parse_stage_refl(Stage_Refl& out, const Json& root, Stage_Kind stage);


// graph.json text -> Graph_Json (version/scene/nodes/links).
bool parse_graph_json(render_graph::Graph_Json& out, const std::string& text);

} // namespace refl
