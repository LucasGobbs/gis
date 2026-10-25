// Watch label parser tests (stage 8): slots, comments, dedupe, truncation.
#include "gfx/inspect.hpp"
#include <catch2/catch_test_macros.hpp>

TEST_CASE("parse_watch_labels extracts slots and labels", "[inspect]") {
    std::string src = R"(
        debug_watch_fragment(0, uv, uint2(input.gl_FragCoord.xy), Uniforms);
        // debug_watch_fragment(1, commented, uint2(0), Uniforms);
        debug_watch_fragment(2, color, uint2(input.gl_FragCoord.xy), Uniforms);
        debug_watch_compute(5, id.xy, uint2(id.xy), Uniforms);
    )";
    auto labels = inspect::parse_watch_labels(src);
    REQUIRE(labels[0] == "uv");
    REQUIRE(labels[1].empty());      // commented out
    REQUIRE(labels[2] == "color");
    REQUIRE(labels[5] == "id.xy");
    REQUIRE(labels[3].empty());
}

TEST_CASE("parse_watch_labels truncates and dedupes", "[inspect]") {
    std::string long_expr(60, 'x');
    std::string src = "debug_watch_fragment(1, " + long_expr + ", uint2(0), Uniforms);";
    auto labels = inspect::parse_watch_labels(src);
    REQUIRE(labels[1].size() == 48);
    std::string src2 = "debug_watch_fragment(3, first, uint2(0), Uniforms);\n"
                       "debug_watch_fragment(3, second, uint2(0), Uniforms);";
    auto labels2 = inspect::parse_watch_labels(src2);
    REQUIRE(labels2[3] == "first");
}
