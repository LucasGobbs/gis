// render_graph implementation: direct port of render_graph.odin. Error
// strings match the Odin originals verbatim (tests pin them).
#include "render_graph.hpp"

namespace render_graph {

std::string graph_path(const std::string& scene, const std::string& scene_root) {
    return scene_root + "/" + scene + "/graph.json";
}

void plan_destroy(Plan& plan) {
    plan.order.clear();
    plan.routes.clear();
    plan.resources.clear();
    plan.output_pass = -1;
}

bool find_pass_endpoint(const std::vector<Pass_Descriptor>& passes, const std::string& ep,
                        int& pass_index, std::string& pin_name) {
    for (size_t i = 0; i < passes.size(); ++i) {
        const std::string& prefix = passes[i].key + ":";
        if (ep.rfind(prefix, 0) == 0 && ep.size() > prefix.size()) {
            pass_index = int(i);
            pin_name = ep.substr(prefix.size());
            return true;
        }
    }
    return false;
}

static bool pass_has_input(const Pass_Descriptor& pass, const std::string& name) {
    for (const std::string& input : pass.input_textures)
        if (input == name) return true;
    return false;
}

static bool pass_has_sampler(const Pass_Descriptor& pass, const std::string& name) {
    for (const std::string& sampler : pass.input_samplers)
        if (sampler == name) return true;
    return false;
}

static std::string default_input(const Pass_Descriptor& pass) {
    for (const std::string& name : pass.input_textures)
        if (name == "input_tex") return name;
    for (const std::string& name : pass.input_textures)
        if (!name.empty()) return name;
    return "";
}

Plan plan_default(const std::vector<Pass_Descriptor>& passes) {
    Plan plan;
    plan.output_pass = int(passes.size()) - 1;
    for (size_t i = 0; i < passes.size(); ++i) plan.order.push_back(int(i));
    for (size_t i = 1; i < passes.size(); ++i) {
        std::string input = default_input(passes[i]);
        if (input.empty()) continue;
        Route route;
        route.producer = int(i) - 1;
        route.consumer = int(i);
        route.input_name = input;
        plan.routes.push_back(route);
    }
    return plan;
}

static bool has_prefix(const std::string& s, const std::string& p) {
    return s.rfind(p, 0) == 0;
}
static bool has_suffix(const std::string& s, const std::string& suf) {
    return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
}

Plan plan_build(const std::vector<Pass_Descriptor>& passes, const Graph_Json& doc,
                std::string& error_message, bool& ok) {
    ok = false;
    const int n = int(passes.size());
    Plan plan;
    auto fail = [&](const std::string& msg) -> Plan {
        plan_destroy(plan);
        error_message = msg;
        return Plan{};
    };

    if (n == 0) return fail("pipeline has no reflected passes");

    const bool authoritative = doc.version == GRAPH_SCHEMA_VERSION;
    std::vector<int> indegree(n, 0);
    std::vector<std::vector<int>> adj(n);
    // "consumer:input" -> seen
    std::vector<std::string> incoming_keys;
    auto incoming_has = [&](const std::string& k) {
        for (const std::string& s : incoming_keys)
            if (s == k) return true;
        return false;
    };
    int output_seen = 0;
    plan.output_pass = -1;
    int pass_edges = 0;

    // Legacy documents link the viewport node without the pin
    // ("show2d"); the editor migrates on read, the runtime normalizes
    // here so old graph.json files keep their viewport output. doc is
    // const: normalize into a local copy.
    std::vector<Link_Json> links = doc.links;
    for (Link_Json& link : links)
        if (link.to == "show2d") link.to = "show2d:frame";
    for (const Link_Json& link : links) {
        int producer = -1;
        std::string output_pin;
        bool producer_ok = find_pass_endpoint(passes, link.from, producer, output_pin);
        if (!producer_ok) {
            // Not a pass output: user resource or legacy fixed node. settings is
            // wireless (broadcast uniforms), never a wired producer.
            if (link.from == "params" || link.from == "settings") return fail("settings is wireless: remove wired link from " + link.to);
            Resource_Kind kind = Resource_Kind::TEXTURE;
            Resource_Source source = Resource_Source::FILE;
            size_t prefix_len = 0;
            std::string suffix = ":texture";
            if (has_prefix(link.from, "uimg:target:") && has_suffix(link.from, ":texture")) {
                kind = Resource_Kind::TEXTURE;
                source = Resource_Source::TARGET_READ;
                prefix_len = 5; // "uimg:"
            } else if (has_prefix(link.from, "uimg:") && has_suffix(link.from, ":sampler")) {
                kind = Resource_Kind::SAMPLER;
                suffix = ":sampler";
                prefix_len = 5;
            } else if (has_prefix(link.from, "uimg:") && has_suffix(link.from, ":texture")) {
                kind = Resource_Kind::TEXTURE;
                prefix_len = 5;
            } else if (has_prefix(link.from, "uobj:") && has_suffix(link.from, ":ModelVertex")) {
                kind = Resource_Kind::MODEL;
                suffix = ":ModelVertex";
                prefix_len = 5;
            } else {
                continue;
            }
            // Path is everything between the prefix and the LAST colon
            // (paths never contain ':', pin names do). Target nodes keep
            // their identity ("target:<id>").
            std::string body = link.from.substr(prefix_len, link.from.size() - prefix_len - suffix.size());
            std::string path = body;
            if (source != Resource_Source::TARGET_READ) {
                size_t colon = body.rfind(':');
                if (colon != std::string::npos) path = body.substr(0, colon);
            }
            if (path.empty()) continue;

            if (link.to == "show2d:frame") return fail("viewport takes a pass output");
            int consumer = -1;
            std::string input_name;
            bool consumer_ok = find_pass_endpoint(passes, link.to, consumer, input_name);
            if (!consumer_ok) continue;
            if (kind == Resource_Kind::SAMPLER) {
                if (!pass_has_sampler(passes[consumer], input_name))
                    return fail(passes[consumer].name + "." + input_name + " has no matching sampler");
            } else if (kind == Resource_Kind::TEXTURE) {
                if (!pass_has_input(passes[consumer], input_name))
                    return fail(passes[consumer].name + "." + input_name + " has no matching input");
            } else if (!passes[consumer].uses_model || input_name != "ModelVertex") {
                return fail(passes[consumer].name + "." + input_name + " has no matching input");
            }
            std::string input_key = std::to_string(consumer) + ":" + input_name;
            if (incoming_has(input_key))
                return fail("input " + passes[consumer].name + "." + input_name +
                            " has more than one producer");
            incoming_keys.push_back(input_key);
            Resource_Route r;
            r.consumer = consumer;
            r.input_name = input_name;
            r.kind = kind;
            r.source = source;
            r.path = path;
            plan.resources.push_back(r);
            continue;
        }

        // Pass output feeding a target-mode image node's write pin:
        // participates in ordering but binds no sampled input.
        if (has_prefix(link.to, "uimg:target:") && has_suffix(link.to, ":write")) {
            if (link.from == "show2d:frame")
                return fail("viewport frame cannot feed a target write");
            continue;
        }

        if (link.to == "show2d:frame") {
            if (output_seen) return fail("pipeline has more than one viewport output");
            if (output_pin.empty()) return fail("invalid output endpoint '" + link.from + "'");
            plan.output_pass = producer;
            output_seen = 1;
            continue;
        }

        int consumer = -1;
        std::string input_name;
        bool consumer_ok = find_pass_endpoint(passes, link.to, consumer, input_name);
        if (!consumer_ok) continue;
        if (producer == consumer) return fail("self-cycle at " + passes[producer].name);
        if (!pass_has_input(passes[consumer], input_name))
            return fail(passes[consumer].name + " has no sampled texture input '" + input_name + "'");
        std::string input_key = std::to_string(consumer) + ":" + input_name;
        if (incoming_has(input_key))
            return fail("input " + passes[consumer].name + "." + input_name +
                        " has more than one producer");
        incoming_keys.push_back(input_key);
        Route route;
        route.producer = producer;
        route.consumer = consumer;
        route.input_name = input_name;
        plan.routes.push_back(route);
        adj[producer].push_back(consumer);
        indegree[consumer] += 1;
        pass_edges += 1;
    }

    // Legacy documents without semantic links migrate to declaration order.
    if (!authoritative && !output_seen && pass_edges == 0) {
        plan_destroy(plan);
        plan = plan_default(passes);
        error_message.clear();
        ok = true;
        return plan;
    }
    if (plan.output_pass < 0) return fail("pipeline has no viewport output");

    // Stable Kahn sort: original reflection order breaks ties.
    std::vector<bool> removed(n, false);
    while (int(plan.order.size()) < n) {
        int picked = -1;
        for (int i = 0; i < n; ++i) {
            if (!removed[i] && indegree[i] == 0) { picked = i; break; }
        }
        if (picked < 0) return fail("pipeline graph contains a cycle");
        removed[picked] = true;
        plan.order.push_back(picked);
        for (int consumer : adj[picked]) indegree[consumer] -= 1;
    }
    error_message.clear();
    ok = true;
    return plan;
}

bool plan_equal(const Plan& a, const Plan& b) {
    if (a.output_pass != b.output_pass || a.order.size() != b.order.size() ||
        a.routes.size() != b.routes.size() || a.resources.size() != b.resources.size())
        return false;
    for (size_t i = 0; i < a.order.size(); ++i)
        if (a.order[i] != b.order[i]) return false;
    for (const Route& route : a.routes) {
        bool found = false;
        for (const Route& other : b.routes) {
            if (route.producer == other.producer && route.consumer == other.consumer &&
                route.input_name == other.input_name) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    // Resource routes compare ordered: both sides come from the same
    // doc.links order, so pairwise is exact.
    for (size_t i = 0; i < a.resources.size(); ++i) {
        const Resource_Route& r = a.resources[i];
        const Resource_Route& o = b.resources[i];
        if (r.consumer != o.consumer || r.input_name != o.input_name || r.kind != o.kind ||
            r.path != o.path)
            return false;
    }
    return true;
}

} // namespace render_graph
