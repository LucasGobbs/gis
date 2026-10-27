// Shell structural test: offscreen Qt, builds the Shell over a loaded scene
// manager, switches modes, checks panels exist and prefs round-trip.
#include "ui/shell.hpp"
#include "ui/editor.hpp"
#include "ui/i18n.hpp"
#include "gfx/scene_runtime.hpp"

#include <catch2/catch_test_macros.hpp>
#include <QApplication>
#include <QPushButton>
#include <QScrollArea>
#include <QStackedWidget>
#include <QTreeWidget>
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

    SECTION("persistent panel survives mode switches") {
        // P0-N1: the panel is a QStackedWidget with persistent pages; the
        // FILES tree must keep its item count across mode switches.
        shell.show_mode(shell::Sidebar_Mode::FILES);
        auto* stack = shell.findChild<QStackedWidget*>();
        REQUIRE(stack != nullptr);
        auto* tree = shell.findChild<QTreeWidget*>();
        REQUIRE(tree != nullptr);
        int items_after_files = tree->topLevelItemCount();
        REQUIRE(items_after_files >= 3); // unit + shared + assets

        shell.show_mode(shell::Sidebar_Mode::CONTROLS);
        shell.show_mode(shell::Sidebar_Mode::FILES);
        REQUIRE(tree->topLevelItemCount() == items_after_files);
    }

    SECTION("layout presets are mutually exclusive (P3-N4)") {
        // Entering Theater saves and hides chrome; entering Zen afterwards
        // must LEAVE Theater (restore fonts) instead of interleaving state.
        float normal_font = shell.ui.editor_font; // Normal-state value
        shell.set_layout(shell::Ui_State::Layout_Preset::Theater);
        REQUIRE(shell.ui.layout == shell::Ui_State::Layout_Preset::Theater);
        REQUIRE(shell.ui.editor_font == 21);
        REQUIRE(shell.ui.panel_open == false);

        shell.set_layout(shell::Ui_State::Layout_Preset::Zen);
        // Theater left cleanly: fonts restored to the Normal-state values,
        // then Zen applied on top.
        REQUIRE(shell.ui.editor_font == shell.ui.saved_ed_font);
        REQUIRE(shell.ui.layout == shell::Ui_State::Layout_Preset::Zen);

        shell.set_layout(shell::Ui_State::Layout_Preset::Normal);
        REQUIRE(shell.ui.editor_font == normal_font);
        REQUIRE(shell.ui.panel_open == true);
    }

    SDL_DestroyGPUDevice(gpu);
}
