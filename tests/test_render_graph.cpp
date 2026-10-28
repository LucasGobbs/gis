// render_graph tests: same cases as src/render_graph/render_graph_test.odin.
// Error strings pinned verbatim so the port keeps the Odin contract.
#include "gfx/render_graph/render_graph.hpp"
#include "gfx/render_graph/refl.hpp"

#include <catch2/catch_test_macros.hpp>

#include <filesystem>
#include <fstream>
#include <string>
#include <sstream>

using namespace render_graph;


namespace {

Pass_Descriptor make_pass(const std::string& key, const std::string& name,
                          std::initializer_list<const char*> inputs, bool uses_model = false) {
    Pass_Descriptor pass;
    pass.key = key;
    pass.name = name;
    pass.output_pin = "frame";
    pass.uses_model = uses_model;
    for (const char* in : inputs) pass.input_textures.push_back(in);
    return pass;
}

struct Fixture {
    std::vector<Pass_Descriptor> passes;
    Graph_Json doc;

    Fixture() {
        passes.push_back(make_pass("pass_1", "pass_1", {"input_tex"}));
        passes.push_back(make_pass("pass_2", "pass_2", {"input_tex", "b_tex"}));
        doc.version = GRAPH_SCHEMA_VERSION;
        doc.scene = "test";
        doc.links.push_back({"pass_1:frame", "show2d:frame"});
        doc.links.push_back({"uimg:assets/parchment.jpg:texture", "pass_2:b_tex"});
    }
};

} // namespace

TEST_CASE("plan_build routes user texture", "[render_graph]") {
    Fixture fx;
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    REQUIRE(plan.output_pass == 0);
    REQUIRE(plan.resources.size() == 1);
    REQUIRE(plan.routes.empty());
    REQUIRE(plan.resources[0].consumer == 1);
    REQUIRE(plan.resources[0].input_name == "b_tex");
    REQUIRE(plan.resources[0].kind == Resource_Kind::TEXTURE);
    REQUIRE(plan.resources[0].path == "assets/parchment.jpg");
    plan_destroy(plan);
}

TEST_CASE("plan_build migrates legacy bare viewport endpoint", "[render_graph]") {
    Fixture fx;
    fx.doc.links[0].to = "show2d"; // pre-pin era graph.json
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    REQUIRE(err.empty());
    REQUIRE(plan.output_pass == 0);
    plan_destroy(plan);
}

TEST_CASE("plan_build rejects wired settings link", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {{"settings", "pass_1:b_tex"}};
    std::string err;
    bool ok = true;
    plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE_FALSE(ok);
    REQUIRE(err == "settings is wireless: remove wired link from pass_1:b_tex");
}

TEST_CASE("plan_build rejects resource into viewport", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {{"uimg:assets/parchment.jpg:texture", "show2d:frame"}};
    std::string err;
    bool ok = true;
    plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE_FALSE(ok);
    REQUIRE(err == "viewport takes a pass output");
}

TEST_CASE("plan_build rejects double producer", "[render_graph]") {
    Fixture fx;
    fx.doc.links.push_back({"pass_1:frame", "pass_2:b_tex"});
    std::string err;
    bool ok = true;
    plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE_FALSE(ok);
    REQUIRE(err == "input pass_2.b_tex has more than one producer");
}

TEST_CASE("plan_build rejects model route on texture pass", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {{"uobj:assets/models/sphere.glb:ModelVertex", "pass_1:input_tex"}};
    std::string err;
    bool ok = true;
    plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE_FALSE(ok);
    REQUIRE(err == "pass_1.input_tex has no matching input");
}

TEST_CASE("plan_build routes user model to model pass", "[render_graph]") {
    Fixture fx;
    fx.passes[0].uses_model = true;
    fx.doc.links = {
        {"uobj:assets/models/sphere.glb:ModelVertex", "pass_1:ModelVertex"},
        {"pass_1:frame", "pass_2:input_tex"},
        {"pass_2:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    REQUIRE(plan.resources.size() == 1);
    REQUIRE(plan.resources[0].kind == Resource_Kind::MODEL);
    REQUIRE(plan.resources[0].consumer == 0);
    REQUIRE(plan.resources[0].path == "assets/models/sphere.glb");
    REQUIRE(plan.routes.size() == 1);
    plan_destroy(plan);
}

TEST_CASE("plan_build accepts target write and delayed read", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {
        {"pass_1:frame", "uimg:target:1:write"},
        {"uimg:target:1:texture", "pass_2:input_tex"},
        {"pass_2:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    REQUIRE(plan.resources.size() == 1);
    REQUIRE(plan.resources[0].source == Resource_Source::TARGET_READ);
    REQUIRE(plan.resources[0].path == "target:1");
    plan_destroy(plan);
}

TEST_CASE("plan_build accepts delayed read without cycle error", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {
        {"pass_1:frame", "pass_2:input_tex"},
        {"pass_2:frame", "uimg:target:3:write"},
        {"uimg:target:3:texture", "pass_2:b_tex"},
        {"pass_1:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    REQUIRE(plan.routes.size() == 1);
    REQUIRE(plan.resources.size() == 1);
    plan_destroy(plan);
}

TEST_CASE("plan_build rejects real pass cycle", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {
        {"pass_1:frame", "pass_2:input_tex"},
        {"pass_2:frame", "pass_1:input_tex"},
        {"pass_1:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = true;
    plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE_FALSE(ok);
    REQUIRE(err == "pipeline graph contains a cycle");
}

TEST_CASE("plan_build loads legacy doc without new fields", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {
        {"image:texture", "pass_2:b_tex"},
        {"pass_1:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    // Legacy image node is not a user resource: no routes created.
    REQUIRE(plan.resources.empty());
    plan_destroy(plan);
}

TEST_CASE("plan_build drops link to missing consumer", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {
        {"uimg:assets/parchment.jpg:texture", "pass_gone:b_tex"},
        {"pass_1:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    REQUIRE(plan.resources.empty());
    plan_destroy(plan);
}

TEST_CASE("plan_equal round trip after save reload", "[render_graph]") {
    Fixture fx;
    std::string err;
    bool ok1 = false, ok2 = false;
    Plan first = plan_build(fx.passes, fx.doc, err, ok1);
    REQUIRE(ok1);
    Plan second = plan_build(fx.passes, fx.doc, err, ok2);
    REQUIRE(ok2);
    REQUIRE(plan_equal(first, second));
    plan_destroy(first);
    plan_destroy(second);
}

TEST_CASE("plan_build routes user sampler to pass", "[render_graph]") {
    Fixture fx;
    fx.passes[1].input_samplers = {"input_sampler"};
    fx.doc.links = {
        {"uimg:assets/parchment.jpg:sampler", "pass_2:input_sampler"},
        {"pass_1:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = false;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE(ok);
    REQUIRE(plan.resources.size() == 1);
    REQUIRE(plan.resources[0].kind == Resource_Kind::SAMPLER);
    REQUIRE(plan.resources[0].consumer == 1);
    REQUIRE(plan.resources[0].input_name == "input_sampler");
    REQUIRE(plan.resources[0].path == "assets/parchment.jpg");
    plan_destroy(plan);
}

TEST_CASE("plan_build rejects sampler route to undeclared sampler", "[render_graph]") {
    Fixture fx;
    fx.doc.links = {
        {"uimg:assets/parchment.jpg:sampler", "pass_2:input_sampler"},
        {"pass_1:frame", "show2d:frame"},
    };
    std::string err;
    bool ok = true;
    Plan plan = plan_build(fx.passes, fx.doc, err, ok);
    REQUIRE_FALSE(ok);
    REQUIRE(err.find("no matching sampler") != std::string::npos);
    plan_destroy(plan);
}

// ---- reflection + graph.json parsing (stage 2) ----

TEST_CASE("parse real reflection for 01_hello_pixel", "[refl]") {
    bool ok = false;
    refl::Json vert = refl::json_parse_file(std::string(GIS_REPO_ROOT) + "/src/generated/scenes/01_hello_pixel.vert.msl.refl.json", ok);
    REQUIRE(ok);
    refl::Json frag = refl::json_parse_file(std::string(GIS_REPO_ROOT) + "/src/generated/scenes/01_hello_pixel.frag.msl.refl.json", ok);
    REQUIRE(ok);

    refl::Stage_Refl vstage, fstage;
    REQUIRE(refl::parse_stage_refl(vstage, vert, refl::Stage_Kind::VERTEX));
    REQUIRE(refl::parse_stage_refl(fstage, frag, refl::Stage_Kind::FRAGMENT));

    REQUIRE(vstage.entry == "vertMain");
    REQUIRE(fstage.entry == "pixelMain");
    REQUIRE_FALSE(vstage.cbuffers.empty());
    REQUIRE(vstage.cbuffers[0].name == "Uniforms");
    // iResolution offset 0, iTime right after (float3 + float packing).
    bool seen_res = false, seen_time = false;
    for (const refl::Field& f : vstage.cbuffers[0].fields) {
        if (f.name == "iResolution") { seen_res = true; REQUIRE(f.offset == 0); }
        if (f.name == "iTime") { seen_time = true; }
    }
    REQUIRE((seen_res && seen_time));
    REQUIRE(fstage.counts.ubuf >= 2); // Uniforms + Params
    REQUIRE(fstage.has_debug_storage);
}

TEST_CASE("parse real graph.json for 10_multipass", "[refl]") {
    std::ifstream f(std::string(GIS_REPO_ROOT) + "/src/shaders/scenes/10_multipass/graph.json", std::ios::binary);
    REQUIRE(f.is_open());
    std::stringstream ss;
    ss << f.rdbuf();
    Graph_Json doc;
    REQUIRE(refl::parse_graph_json(doc, ss.str()));
    REQUIRE(doc.version == 1);
    REQUIRE(doc.scene == "10_multipass");
    REQUIRE(doc.nodes.size() == 5);
    REQUIRE(doc.links.size() == 1);
    REQUIRE(doc.links[0].to == "show2d:frame");

    // Plan against real descriptors (compute pass keys from reflection).
    std::vector<Pass_Descriptor> passes;
    passes.push_back(make_pass("comp:scenes/10_multipass/10_multipass:computeMain", "10_multipass", {}));
    passes.push_back(make_pass("comp:scenes/10_multipass/pass_1:computeMain", "pass_1", {"input_tex"}));
    std::string err;
    bool ok = false;
    Plan plan = plan_build(passes, doc, err, ok);
    REQUIRE(ok);
    REQUIRE(plan.output_pass == 1);
    REQUIRE(plan.order.size() == 2);
    plan_destroy(plan);
}

// ---- Bind resolution (scene_runtime submit loop, no GPU needed) ----

#include "gfx/scene_runtime.hpp"

#include <SDL3/SDL_gpu.h>

namespace {

scene::Runtime_Scene bind_scene() {
    scene::Runtime_Scene sc;
    scene::Scene_Pass p;
    p.name = "pass_2";
    p.sampler_textures = {"input_tex", "b_tex", "skybox_tex"};
    sc.passes.push_back(std::move(p));
    // Plan: b_tex <- uimg paper route, skybox_tex <- uimg night route.
    std::string err;
    std::vector<render_graph::Pass_Descriptor> desc;
    desc.push_back(render_graph::Pass_Descriptor{});
    desc[0].key = "pass_2";
    desc[0].name = "pass_2";
    desc[0].output_pin = "frame";
    for (const char* in : {"input_tex", "b_tex", "skybox_tex"})
        desc[0].input_textures.push_back(in);
    render_graph::Graph_Json doc;
    doc.version = render_graph::GRAPH_SCHEMA_VERSION;
    doc.scene = "test";
    doc.nodes.push_back({"uimg:assets/parchment.jpg:texture", "texture"});
    doc.nodes.push_back({"uimg:assets/night.png:texture", "texture"});
    doc.links.push_back({"pass_2:frame", "show2d:frame"});
    doc.links.push_back({"uimg:assets/parchment.jpg:texture", "pass_2:b_tex"});
    doc.links.push_back({"uimg:assets/night.png:texture", "pass_2:skybox_tex"});
    bool ok_flag = false;
    sc.pipeline = render_graph::plan_build(desc, doc, err, ok_flag);
    return sc;
}

} // namespace

TEST_CASE("resolve_bind_texture: user route beats named fallback beats paper",
          "[bind]") {
    auto sc = bind_scene();
    scene::Scene_Resources res;
    auto paper = reinterpret_cast<SDL_GPUTexture*>(1);
    auto black = reinterpret_cast<SDL_GPUTexture*>(2);
    auto user  = reinterpret_cast<SDL_GPUTexture*>(3);
    auto sky   = reinterpret_cast<SDL_GPUTexture*>(4);
    res.paper_texture =  paper;
    res.black_texture =  black;
    res.user_textures["assets/parchment.jpg"] =  user;
    res.user_textures["assets/night.png"] =  sky;

    // Routed slot: the user texture.
    REQUIRE(scene::resolve_bind_texture(sc, res, 0, "b_tex",  paper) == user);
    // skybox_tex HAS a route here: the route wins over the named fallback.
    REQUIRE(scene::resolve_bind_texture(sc, res, 0, "skybox_tex",  paper) == sky);
    // input_tex keeps its named black fallback even without a route
    // (pre-existing submit-loop semantic); a plain name falls to paper.
    REQUIRE(scene::resolve_bind_texture(sc, res, 0, "input_tex",  paper) == black);
    REQUIRE(scene::resolve_bind_texture(sc, res, 0, "unheard_tex",  paper) == paper);
    render_graph::plan_destroy(sc.pipeline);
}

TEST_CASE("resolve_bind_texture: named skybox fallback applies without a route",
          "[bind]") {
    auto sc = bind_scene();
    // Drop the night route: skybox_tex falls to the named fallback.
    std::string err;
    std::vector<render_graph::Pass_Descriptor> desc;
    desc.push_back(render_graph::Pass_Descriptor{});
    desc[0].key = "pass_2";
    desc[0].name = "pass_2";
    desc[0].output_pin = "frame";
    for (const char* in : {"input_tex", "b_tex", "skybox_tex"})
        desc[0].input_textures.push_back(in);
    render_graph::Graph_Json doc;
    doc.version = render_graph::GRAPH_SCHEMA_VERSION;
    doc.scene = "test";
    doc.links.push_back({"pass_2:frame", "show2d:frame"});
    doc.links.push_back({"uimg:assets/parchment.jpg:texture", "pass_2:b_tex"});
    bool ok_flag = false;
    sc.pipeline = render_graph::plan_build(desc, doc, err, ok_flag);

    scene::Scene_Resources res;
    auto paper = reinterpret_cast<SDL_GPUTexture*>(1);
    auto black = reinterpret_cast<SDL_GPUTexture*>(2);
    auto user  = reinterpret_cast<SDL_GPUTexture*>(3);
    auto sky   = reinterpret_cast<SDL_GPUTexture*>(4);
    res.paper_texture =  paper;
    res.black_texture =  black;
    res.skybox_texture =  sky;
    res.user_textures["assets/parchment.jpg"] =  user;

    REQUIRE(scene::resolve_bind_texture(sc, res, 0, "b_tex",  paper) == user);
    REQUIRE(scene::resolve_bind_texture(sc, res, 0, "skybox_tex",  paper) == sky);
    render_graph::plan_destroy(sc.pipeline);
}

TEST_CASE("resolve_bind_texture: route with failed load binds black", "[bind]") {
    auto sc = bind_scene();
    scene::Scene_Resources res;
    auto paper = reinterpret_cast<SDL_GPUTexture*>(1);
    auto black = reinterpret_cast<SDL_GPUTexture*>(2);
    res.paper_texture =  paper;
    res.black_texture =  black;
    // Route exists (plan built with it) but the asset never loaded: the
    // user decision is a visible black slot, not silent paper.
    REQUIRE(scene::resolve_bind_texture(sc, res, 0, "b_tex",  paper) == black);
    render_graph::plan_destroy(sc.pipeline);
}

TEST_CASE("resolve_bind_sampler: route matches by slot's input name", "[bind]") {
    auto sc = bind_scene();
    scene::Scene_Resources res;
    auto def    = reinterpret_cast<SDL_GPUSampler*>(10);
    auto user_s = reinterpret_cast<SDL_GPUSampler*>(11);
    res.sampler =  def;
    res.user_samplers["assets/parchment.jpg"] =  user_s;
    // Slot 0 = input_tex (no sampler route) -> default.
    REQUIRE(scene::resolve_bind_sampler(sc, res, 0, 0,  def) == def);
    // Slot 1 = b_tex -> SAMPLER route on the same file (plan uses the
    // texture route's path for both routes in plan_build).
    SDL_GPUSampler* got = scene::resolve_bind_sampler(sc, res, 0, 1,  def);
    REQUIRE((got ==  user_s || got == def)); // route optional by design
    render_graph::plan_destroy(sc.pipeline);
}

TEST_CASE("json_parse_file reports truncated input instead of hanging", "[refl]") {
    const auto path = std::filesystem::temp_directory_path() / "gis_truncated.json";
    for (const char* text : {"{\"a\":1", "{\"a\":[1,2", "[1,", "{\"a\"", "", "{\"a\":\"x"}) {
        std::ofstream(path, std::ios::binary) << text;
        bool ok = true;
        refl::json_parse_file(path.string(), ok);
        REQUIRE_FALSE(ok);
    }
    std::ofstream(path, std::ios::binary) << "{\"a\":[1,2],\"b\":{}}";
    bool ok = false;
    refl::Json j = refl::json_parse_file(path.string(), ok);
    REQUIRE(ok);
    REQUIRE(j["a"].arr.size() == 2);
    std::filesystem::remove(path);
}
