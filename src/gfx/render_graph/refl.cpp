// refl implementation: JSON reader + reflection/graph parsers.
#include "refl.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>

namespace refl {

// ---- JSON ----

struct Json_Parser {
    const char* p;
    const char* end;
    const char* start;

    void skip_ws() {
        while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) ++p;
    }
    bool eat(char c) {
        skip_ws();
        if (p < end && *p == c) { ++p; return true; }
        return false;
    }
    // Parse failure is RECOVERABLE: slangc may still be writing the file
    // (hot-reload race: the pump read a truncated/empty reflection
    // mid-write; EOF at byte 0 aborted the whole app = "Abort trap: 6").
    // Set failed_ and stop; json_parse_file reports ok=false and the
    // caller keeps the last-good pipeline.
    bool failed_ = false;
    void fail(const char* what) {
        std::fprintf(stderr, "json parse error: %s at byte %td\n", what, p - start);
        failed_ = true;
        p = end; // stop consuming
    }
    Json parse() {
        if (failed_) return Json{};
        skip_ws();
        if (p >= end) fail("eof");
        char c = *p;
        if (c == '{') return parse_obj();
        if (c == '[') return parse_arr();
        if (c == '"') { Json j; j.kind = Json::Kind::STR; j.str = parse_str(); return j; }
        if (c == 't' || c == 'f') {
            Json j; j.kind = Json::Kind::BOOL;
            if (p + 4 <= end && std::memcmp(p, "true", 4) == 0) { j.b = true; p += 4; }
            else if (p + 5 <= end && std::memcmp(p, "false", 5) == 0) { j.b = false; p += 5; }
            else fail("bool");
            return j;
        }
        if (c == 'n' && p + 4 <= end && std::memcmp(p, "null", 4) == 0) { p += 4; return Json{}; }
        Json j;
        j.kind = Json::Kind::NUM;
        // Locale-independent: Qt sets LC_ALL="" and strtod misparses "1.1"
        // under comma-decimal locales.
        const char* s = p;
        bool any = false, neg = false, dot = false, neg_exp = false;
        double v = 0, frac = 0, scale = 1, exp10 = 0;
        if (s < end && (*s == '-' || *s == '+')) { neg = *s == '-'; ++s; }
        while (s < end) {
            char ch = *s;
            if (ch >= '0' && ch <= '9') {
                any = true;
                if (!dot) v = v * 10 + (ch - '0');
                else { frac = frac * 10 + (ch - '0'); scale *= 10; }
                ++s;
            } else if (ch == '.' && !dot) {
                dot = true; ++s;
            } else if ((ch == 'e' || ch == 'E') && any) {
                ++s;
                if (s < end && (*s == '+' || *s == '-')) { neg_exp = *s == '-'; ++s; }
                long ev = 0;
                while (s < end && *s >= '0' && *s <= '9') { ev = ev * 10 + (*s - '0'); ++s; }
                exp10 = neg_exp ? -(double)ev : (double)ev;
                break;
            } else break;
        }
        if (!any) fail("num");
        j.num = (neg ? -1.0 : 1.0) * (v + frac / scale);
        if (exp10 != 0) j.num *= std::pow(10.0, exp10);
        p = s;
        return j;
    }
    std::string parse_str() {
        if (!eat('"')) fail("str");
        std::string out;
        while (p < end && *p != '"') {
            if (*p == '\\' && p + 1 < end) {
                ++p;
                switch (*p) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                case 'r': out += '\r'; break;
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'u': {
                    if (p + 4 < end) {
                        unsigned cp = 0;
                        for (int i = 1; i <= 4; ++i) {
                            char h = p[i];
                            cp <<= 4;
                            if (h >= '0' && h <= '9') cp |= unsigned(h - '0');
                            else if (h >= 'a' && h <= 'f') cp |= unsigned(h - 'a' + 10);
                            else if (h >= 'A' && h <= 'F') cp |= unsigned(h - 'A' + 10);
                        }
                        p += 4;
                        if (cp < 0x80) out += char(cp);
                        else if (cp < 0x800) {
                            out += char(0xC0 | (cp >> 6));
                            out += char(0x80 | (cp & 0x3F));
                        } else {
                            out += char(0xE0 | (cp >> 12));
                            out += char(0x80 | ((cp >> 6) & 0x3F));
                            out += char(0x80 | (cp & 0x3F));
                        }
                    }
                    break;
                }
                default: out += *p; break;
                }
                ++p;
            } else {
                out += *p++;
            }
        }
        if (!eat('"')) fail("str end");
        return out;
    }
    Json parse_obj() {
        Json j; j.kind = Json::Kind::OBJ;
        eat('{');
        if (eat('}')) return j;
        while (true) {
            std::string key = parse_str();
            if (!eat(':')) fail("colon");
            j.obj.emplace_back(std::move(key), parse());
            if (eat(',')) continue;
            if (eat('}')) break;
            fail("obj");
        }
        return j;
    }
    Json parse_arr() {
        Json j; j.kind = Json::Kind::ARR;
        eat('[');
        if (eat(']')) return j;
        while (true) {
            j.arr.push_back(parse());
            if (eat(',')) continue;
            if (eat(']')) break;
            fail("arr");
        }
        return j;
    }
};

Json json_parse_file(const std::string& path, bool& ok) {
    ok = false;
    std::ifstream f(path, std::ios::binary);
    if (!f) return Json{};
    std::stringstream ss;
    ss << f.rdbuf();
    std::string text = ss.str();
    Json_Parser pr{text.data(), text.data() + text.size(), text.data()};
    Json j = pr.parse();
    if (pr.failed_) return Json{}; // truncated/mid-write: caller keeps last-good
    ok = true;
    return j;
}

static bool jcontains(const std::string& s, const char* needle) {
    return s.find(needle) != std::string::npos;
}

void poke_f32(CBuffer& cb, uint32_t off, float v) {
    if (off + 4 <= cb.block.size()) std::memcpy(cb.block.data() + off, &v, 4);
}
void poke_u32(CBuffer& cb, uint32_t off, uint32_t v) {
    if (off + 4 <= cb.block.size()) std::memcpy(cb.block.data() + off, &v, 4);
}

// ---- Reflection (scene_runtime.odin helpers) ----

namespace {

int entry_binding_used(const Json& entry, const std::string& name) {
    for (const Json& b : entry["bindings"].arr) {
        if (b["name"].str == name) return int(b["binding"]["used"].num);
    }
    return 0;
}

// RW structured buffers get consecutive storage slots in usage order
// (debug_buffer_slot in scene_runtime.odin).
uint32_t debug_buffer_slot(const Json& params, const Json& entry, const std::string& target,
                           bool& found) {
    found = false;
    uint32_t rw_slot = 0;
    for (const Json& b : entry["bindings"].arr) {
        if (b["binding"]["used"].num < 1) continue;
        const std::string& name = b["name"].str;
        bool is_buffer = false, read_write = false;
        for (const Json& p : params.arr) {
            if (p["name"].str != name) continue;
            const Json& type = p["type"];
            is_buffer = jcontains(type["kind"].str, "tructuredBuffer") ||
                        jcontains(type["baseShape"].str, "tructuredBuffer");
            std::string access = p["access"].str;
            if (access.empty()) access = type["access"].str;
            read_write = access == "readWrite";
            break;
        }
        if (!is_buffer || !read_write) continue;
        if (name == target) {
            found = true;
            return rw_slot;
        }
        rw_slot += 1;
    }
    return rw_slot;
}

void count_resources(ResourceCounts& counts, const Json& params, const Json& entry) {
    for (const Json& b : entry["bindings"].arr) {
        const Json& binding = b["binding"];
        if (binding["used"].num < 1) continue;
        const std::string& name = b["name"].str;
        std::string access, type_kind, base_shape;
        for (const Json& p : params.arr) {
            if (p["name"].str != name) continue;
            access = p["access"].str;
            if (access.empty()) access = p["type"]["access"].str;
            type_kind = p["type"]["kind"].str;
            base_shape = p["type"]["baseShape"].str;
            break;
        }
        bool is_buffer = type_kind.find("tructuredBuffer") != std::string::npos ||
                         base_shape.find("tructuredBuffer") != std::string::npos;
        bool read_write = access == "readWrite";
        if (is_buffer) {
            if (read_write) ++counts.rw_buf;
            else ++counts.ro_buf;
            continue;
        }
        const std::string& bk = binding["kind"].str;
        if (bk == "samplerState") ++counts.samplers;
        else if (bk == "constantBuffer")
            counts.ubuf = counts.ubuf > uint32_t(binding["index"].num) + 1
                              ? counts.ubuf
                              : uint32_t(binding["index"].num) + 1;
        else if (bk == "shaderResource") {
            if (read_write) ++counts.rw_tex;
            else ++counts.ro_tex;
        }
    }
    // A Texture2D read through a SamplerState is a SAMPLED texture in SDL
    // terms, not a readonly storage texture: slang pairs texture index i
    // with sampler index i, so the first `samplers` readonly textures are
    // sampled and must not be counted as storage.
    uint32_t sampled = counts.ro_tex < counts.samplers ? counts.ro_tex : counts.samplers;
    counts.ro_tex -= sampled;
}

} // namespace

bool parse_stage_refl(Stage_Refl& out, const Json& root, Stage_Kind stage) {
    const Json& eps = root["entryPoints"];
    const Json nil{};
    const Json& eb = eps.arr.empty() ? nil : eps.arr[0]["bindings"];
    const Json& params = root["parameters"];

    if (!eps.arr.empty()) out.entry = eps.arr[0]["name"].str;
    if (stage == Stage_Kind::COMPUTE && !eps.arr.empty()) {
        const Json& tg = eps.arr[0]["threadGroupSize"];
        if (tg.arr.size() == 3) {
            out.thread[0] = uint32_t(tg.arr[0].num);
            out.thread[1] = uint32_t(tg.arr[1].num);
            out.thread[2] = uint32_t(tg.arr[2].num);
        }
    }
    // Model pass: vertex entry takes a [[stage_in]] (varyingInput param).
    if (stage == Stage_Kind::VERTEX && !eps.arr.empty()) {
        for (const Json& param : eps.arr[0]["parameters"].arr) {
            if (param["binding"]["kind"].str != "varyingInput") continue;
            if (!param["type"]["fields"].arr.empty()) out.uses_model = true;
        }
    }

    count_resources(out.counts, params, eps.arr.empty() ? nil : eps.arr[0]);

    // Cbuffers: same-name unify per stage; slot from binding index.
    for (const Json& b : eb.arr) {
        const Json& binding = b["binding"];
        if (binding.kind != Json::Kind::OBJ) continue;
        if (binding["used"].num < 1) continue;
        if (binding["kind"].str != "constantBuffer") continue;
        const std::string& name = b["name"].str;

        const Json* param = nullptr;
        for (const Json& p : params.arr)
            if (p["name"].str == name) { param = &p; break; }
        if (!param) continue;
        if ((*param)["type"]["kind"].str != "constantBuffer") continue;
        if (entry_binding_used(eps.arr.empty() ? nil : eps.arr[0], name) == 0) continue;

        CBuffer* cb = nullptr;
        for (CBuffer& existing : out.cbuffers) {
            if (existing.name == name) { cb = &existing; break; }
        }
        if (!cb) {
            CBuffer fresh;
            fresh.name = name;
            const Json& fields = (*param)["type"]["elementVarLayout"]["type"]["fields"];
            uint32_t size = 0;
            for (const Json& f : fields.arr) {
                Field fld;
                fld.name = f["name"].str;
                fld.offset = uint32_t(f["binding"]["offset"].num);
                fld.size = uint32_t(f["binding"]["size"].num);
                size = size > fld.offset + fld.size ? size : fld.offset + fld.size;
                fresh.fields.push_back(fld);
            }
            fresh.block.assign((size + 15u) & ~15u, 0); // std140 rounds to 16
            out.cbuffers.push_back(std::move(fresh));
            cb = &out.cbuffers.back();
        }
        uint32_t slot = uint32_t(binding["index"].num);
        if (stage == Stage_Kind::COMPUTE) cb->compute_slot = slot;
        else if (stage == Stage_Kind::VERTEX) { cb->in_vert = true; cb->vert_slot = slot; }
        else if (stage == Stage_Kind::FRAGMENT) { cb->in_frag = true; cb->frag_slot = slot; }
    }

    bool found = false;
    uint32_t slot = debug_buffer_slot(params, eps.arr.empty() ? nil : eps.arr[0], "debug_records", found);
    if (found) {
        out.has_debug_storage = true;
        out.debug_storage_slot = slot;
    }

    // Sampled textures in sampler-slot order (stage != VERTEX): the i-th
    // sampled texture pairs with the i-th sampler by binding index.
    if (stage != Stage_Kind::VERTEX) {
        for (const Json& sb : eb.arr) {
            const Json& binding = sb["binding"];
            if (binding["kind"].str != "samplerState" || binding["used"].num < 1) continue;
            uint32_t s_slot = uint32_t(binding["index"].num);
            for (const Json& tb : eb.arr) {
                const Json& tbinding = tb["binding"];
                if (tbinding["kind"].str != "shaderResource") continue;
                if (tbinding["index"].num != double(s_slot) || tbinding["used"].num < 1) continue;
                if (out.sampler_textures.size() <= s_slot)
                    out.sampler_textures.resize(s_slot + 1);
                if (out.sampler_names.size() <= s_slot) out.sampler_names.resize(s_slot + 1);
                out.sampler_textures[s_slot] = tb["name"].str;
                out.sampler_names[s_slot] = sb["name"].str;
            }
        }
    }
    return true;
}

// ---- graph.json ----

bool parse_graph_json(render_graph::Graph_Json& out, const std::string& text) {
    Json_Parser pr{text.data(), text.data() + text.size(), text.data()};
    Json root = pr.parse();
    if (pr.failed_) return false;
    out.version = int(root["version"].num);
    out.scene = root["scene"].str;
    for (const Json& n : root["nodes"].arr) {
        render_graph::Node_Json node;
        node.key = n["key"].str;
        node.kind = n["kind"].str;
        node.x = float(n["x"].num);
        node.y = float(n["y"].num);
        node.file = n["file"].str;
        node.source = n["source"].str;
        node.title = n["title"].str;
        node.filter = n["filter"].str;
        node.address = n["address"].str;
        node.width = int(n["width"].num);
        node.height = int(n["height"].num);
        node.value = float(n["value"].num);
        out.nodes.push_back(std::move(node));
    }
    for (const Json& l : root["links"].arr) {
        render_graph::Link_Json link;
        link.from = l["from"].str;
        link.to = l["to"].str;
        out.links.push_back(std::move(link));
    }
    return true;
}

} // namespace refl
