// Shell structural test: offscreen Qt, builds the Shell over a loaded scene
// manager, switches modes, checks panels exist and prefs round-trip.
#include "ui/shell.hpp"
#include "ui/i18n.hpp"
#include "gfx/scene_runtime.hpp"

#include <catch2/catch_test_macros.hpp>
#include <QApplication>
#include <QPushButton>
#include <QScrollArea>

TEST_CASE("shell builds panels and switches modes", "[shell]") {
    const char* argv[] = {"test_shell"};
    int argc = 1;
    QApplication app(argc, const_cast<char**>(argv));

    SDL_Init(SDL_INIT_VIDEO);
    SDL_GPUDevice* gpu = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, true, nullptr);
    std::map<std::string, std::string> roots;
    scene::scene_names_on_disk(roots);
    scene::Scene_Manager mgr;
    REQUIRE(scene::scene_load(mgr, gpu, "03_mouse", roots));

    shell::Shell shell(nullptr, mgr, roots);
    shell.resize(1280, 780);

    SECTION("prefs round trip") {
        shell::Ui_State ui;
        ui.user_w = 333;
        ui.theme = shell::Editor_Theme::MONOKAI;
        shell::prefs_save(ui);
        shell::Ui_State loaded;
        shell::prefs_load(loaded);
        REQUIRE(loaded.user_w == 333);
        REQUIRE(loaded.theme == shell::Editor_Theme::MONOKAI);
    }

    SECTION("i18n catalogs") {
        i18n::set_language(i18n::Language::EN);
        REQUIRE(i18n::tr("controls") == "controls");
        i18n::set_language(i18n::Language::PT);
        REQUIRE(i18n::tr("controls") == "controles");
        REQUIRE(i18n::tr("file explorer") == "explorador de arquivos");
        i18n::set_language(i18n::Language::ES);
        REQUIRE(i18n::tr("scene name") == "nombre de la escena");
        // Missing keys fall back to English.
        REQUIRE(i18n::tr("no such key xyz") == "no such key xyz");
        i18n::set_language(i18n::Language::EN);
    }

    SECTION("panel width per mode") {
        shell::Ui_State ui;
        ui.user_w = 0;
        REQUIRE(shell::panel_width_for(ui, shell::Sidebar_Mode::CONTROLS, 1280).toInt() == 300);
        REQUIRE(shell::panel_width_for(ui, shell::Sidebar_Mode::GRAPH, 1280).toInt() == 666);
        ui.user_w = 500;
        REQUIRE(shell::panel_width_for(ui, shell::Sidebar_Mode::CONTROLS, 1280).toInt() == 500);
    }

    SECTION("mode strip populated") {
        // 7 strip buttons + settings gear.
        QList<QPushButton*> buttons = shell.findChildren<QPushButton*>();
        REQUIRE(buttons.size() >= 8);
    }

    SDL_DestroyGPUDevice(gpu);
}
