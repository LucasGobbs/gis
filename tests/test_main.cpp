// gis_tests own main: chdir to the repo root before Catch2 runs. The scene
// runtime resolves GENERATED_DIR/SCENES_DIR as relative paths; run from
// a build dir the shell test could not find the artifacts. Mirrors
// chdir_repo_root() in host_main.mm.
#include <catch2/catch_session.hpp>
#include <filesystem>

int main(int argc, char* argv[]) {
    namespace fs = std::filesystem;
#if defined(GIS_REPO_ROOT)
    // Compile-time anchor first (configure knows the source tree), then the
    // walk-up for a relocated build.
    fs::path anchored = fs::path(GIS_REPO_ROOT);
    if (fs::exists(anchored / "src/shaders/scenes")) {
        std::error_code ec;
        fs::current_path(anchored, ec);
    } else
#endif
    {
        for (fs::path p = fs::current_path(); !p.empty(); p = p.parent_path()) {
            if (fs::exists(p / "src/shaders/scenes")) {
                std::error_code ec;
                fs::current_path(p, ec);
                break;
            }
        }
    }
    return Catch::Session().run(argc, argv);
}
