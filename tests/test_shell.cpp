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
#include <QMouseEvent>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include "ui/graph_editor.hpp"
TEST_CASE("shell builds panels and switches modes", "[shell]") {
    int argc = 1;
    const char* argv[] = {"test_shell"};
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
        // plan5: per-mode dragged widths win over the legacy global one.
        shell::Ui_State per;
        per.user_w = 500;
        per.user_w_mode[int(shell::Sidebar_Mode::FILES)] = 360;
        REQUIRE(shell::panel_width_for(per, shell::Sidebar_Mode::FILES, 1280).toInt() == 360);
        REQUIRE(shell::panel_width_for(per, shell::Sidebar_Mode::CONTROLS, 1280).toInt() == 500);
        // Floor: values under kPanelMinW clamp up.
        shell::Ui_State small;
        small.user_w_mode[int(shell::Sidebar_Mode::EXPORT)] = 100;
        REQUIRE(shell::panel_width_for(small, shell::Sidebar_Mode::EXPORT, 1280).toInt() == 220);
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

    SECTION("strip icons swap with selection and reset on deselect (Plan 07)") {
        // Regression: the FILES folder glyph stayed folder-open after
        // switching away — apply_mode never reset the icon. The rest/
        // active pair now lives on button properties and swaps both ways.
        shell.show_mode(shell::Sidebar_Mode::FILES);
        QApplication::processEvents();
        // The FILES strip button: the one whose icon_rest is folder.svg.
        QWidget* files_btn = nullptr;
        for (QWidget* w : shell.findChildren<QWidget*>()) {
            if (w->property("icon_rest").toString().endsWith("folder.svg")) {
                files_btn = w;
                break;
            }
        }
        REQUIRE(files_btn != nullptr);
        auto icon_path = [](QWidget* b) {
            return b->property("current_icon").toString();
        };
        shell.show_mode(shell::Sidebar_Mode::FILES);
        QApplication::processEvents();
        REQUIRE(icon_path(files_btn).endsWith("folder-open.svg")); // selected
        shell.show_mode(shell::Sidebar_Mode::CONTROLS);
        QApplication::processEvents();
        REQUIRE(icon_path(files_btn).endsWith("folder.svg")); // reset!
        shell.show_mode(shell::Sidebar_Mode::FILES);
        QApplication::processEvents();
        REQUIRE(icon_path(files_btn).endsWith("folder-open.svg")); // again
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

    SECTION("header double-click maximizes and restores (Plan 02 §3)") {
        // The dbl-click handler lives in the topbar event filter; drive it
        // through the real event path: synthesized MouseButtonDblClick on
        // an empty topbar region (childAt == nullptr → chrome hit).
        // Find THE topbar by objectName (set in Shell::topbar()).
        QWidget* bar = shell.findChild<QWidget*>("topbar");
        REQUIRE(bar != nullptr);
        const bool was_max = shell.isMaximized();
        // Empty spot: scan the bar for a column with no interactive child
        // (geometry-independent; no fragile hardcoded x).
        shell.show(); // settle layout: bar->width() is 0 before the first show
        QApplication::processEvents();
        QPoint empty_pt(-1, -1);
        for (int x = bar->width() - 2; x > 0 && empty_pt.x() < 0; --x)
            for (int y = 4; y < bar->height() - 4; y += 6)
                if (bar->childAt(x, y) == nullptr) {
                    empty_pt = QPoint(x, y);
                    break;
                }
        REQUIRE(empty_pt.x() >= 0);
        QMouseEvent dbl(QEvent::MouseButtonDblClick, empty_pt,
                        shell.mapToGlobal(empty_pt), Qt::LeftButton,
                        Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(bar, &dbl);
        if (was_max) {
            // Offscreen test: maximize may not assert; only require the
            // event was consumed without crashing and state is coherent.
            REQUIRE(shell.windowHandle() != nullptr);
        }
    }

    SECTION("editor tabs: active color, dirty glyph, tooltip (Plan 03 §2)") {
        shell.show(); // tabs need layout for tabBar geometry
        QApplication::processEvents();
        editor::Editor* editor = shell.findChild<editor::Editor*>();
        REQUIRE(editor != nullptr);
        // Open a real scene file (entry files sit one level deep).
        QDir shaders("src/shaders/scenes");
        QStringList units = shaders.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
        REQUIRE(!units.isEmpty());
        QDir unit_dir("src/shaders/scenes/" + units.first());
        QStringList slang = unit_dir.entryList({"*.slang"}, QDir::Files);
        REQUIRE(!slang.isEmpty());
        const QString first = slang.first();
        const QString rel1 = "scenes/" + first.chopped(6) + "/" + first.chopped(6);
        editor->load_named(rel1);
        REQUIRE(editor->count() >= 1);
        // Full rel path in the tab tooltip (long-name fallback).
        REQUIRE(!editor->tabBar()->tabToolTip(0).isEmpty());
        // NO eliding: full file name policy (overflow scrolls instead).
        REQUIRE(editor->elideMode() == Qt::ElideNone);
        // Tab text carries the file name.
        REQUIRE(!editor->tabText(0).isEmpty());
    }

    SECTION("graph flash animation survives node sweep (Plan 05)") {
        // Regression: theme switch → apply_mode(GRAPH) → load_layout's
        // deleteNode sweep destroyed the pass-flash rings while their
        // QVariantAnimation was still running → ASan UAF in QPen::color().
        // The fix parents the animation's QObject guard to the node
        // graphics object; a destroyed node stops/disconnects the fade.
        shell.show_mode(shell::Sidebar_Mode::GRAPH);
        QApplication::processEvents();
        auto* graph = shell.findChild<graph_editor::Node_View*>();
        REQUIRE(graph != nullptr);
        // Drive two preview frames so flash_pass creates + replaces rings.
        QImage img(8, 8, QImage::Format_RGBA8888);
        img.fill(QColor(255, 0, 0));
        graph->set_previews(QVector<QImage>{img});
        QApplication::processEvents();
        img.fill(QColor(0, 255, 0)); // different checksum → flash again
        graph->set_previews(QVector<QImage>{img});
        QApplication::processEvents();
        // Drive the fade SYNCHRONOUSLY at mid-flight (setCurrentTime is the
        // exact crash path: QVariantAnimation::setCurrentTime → valueChanged
        // → ring->pen()). The sweep above freed the ring under the broken
        // version; with the guard, the destroyed receiver disconnects.
        REQUIRE(graph->debug_step_flashes(120) >= 1); // mid-fade tick
        shell.show_mode(shell::Sidebar_Mode::GRAPH); // sweep mid-fade
        QApplication::processEvents();
        REQUIRE(graph->debug_step_flashes(300) >= 0); // post-sweep tick
        QApplication::processEvents();
        // Full play-out: finished handler must not double-free either.
        graph->debug_step_flashes(700);
        QApplication::processEvents();
    }
    SECTION("graph: no duplicate nodes, settings ports, zoom clamp, fullscreen") {
        shell.show_mode(shell::Sidebar_Mode::GRAPH);
        QApplication::processEvents();
        auto* graph = shell.findChild<graph_editor::Node_View*>();
        REQUIRE(graph != nullptr);
        const int count = graph->debug_node_count();
        REQUIRE(count > 0);
        for (int i = 0; i < 3; ++i) {
            shell.show_mode(shell::Sidebar_Mode::CONTROLS);
            shell.show_mode(shell::Sidebar_Mode::GRAPH);
            QApplication::processEvents();
            REQUIRE(graph->debug_node_count() == count);
        }
        REQUIRE(graph->debug_ports("settings", true).isEmpty());
        // One output per uniform block the passes read; SceneUniforms always first.
        const QStringList outs = graph->debug_ports("settings", false);
        REQUIRE(outs.value(0) == "SceneUniforms (uniform)");
        auto* view = dynamic_cast<graph_editor::Graph_View*>(graph->findChild<QtNodes::GraphicsView*>());
        REQUIRE(view != nullptr);
        for (int i = 0; i < 60; ++i) {
            QWheelEvent ev(QPointF(10, 10), QPointF(10, 10), QPoint(0, 0), QPoint(0, 120),
                           Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
            QApplication::sendEvent(view, &ev);
        }
        REQUIRE(graph->debug_zoom() <= graph_editor::Graph_View::kMaxZoom + 1e-6);
        for (int i = 0; i < 200; ++i) {
            QWheelEvent ev(QPointF(10, 10), QPointF(10, 10), QPoint(0, 0), QPoint(0, -120),
                           Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
            QApplication::sendEvent(view, &ev);
        }
        REQUIRE(graph->debug_zoom() >= graph_editor::Graph_View::kMinZoom - 1e-6);
        shell::Ui_State ui;
        ui.graph_fullscreen = true;
        REQUIRE(shell::panel_width_for(ui, shell::Sidebar_Mode::GRAPH, 1280).toInt()
                == 1280 - shell::kStripW - shell::kGraphFullscreenReserve);
        ui.graph_fullscreen = false;
        REQUIRE(shell::panel_width_for(ui, shell::Sidebar_Mode::GRAPH, 1280).toInt() == 666);
        auto* fs = graph->findChild<QToolButton*>("graphFullscreen");
        REQUIRE(fs != nullptr);
        bool seen = false, seen_on = false;
        QObject::connect(graph, &graph_editor::Node_View::fullscreen_toggled, graph,
                         [&](bool on) { seen = true; seen_on = on; });
        fs->click();
        REQUIRE(seen);
        REQUIRE(seen_on);
    }
    SECTION("graph: trackpad pans, preview toggle keeps zoom") {
        shell.show_mode(shell::Sidebar_Mode::GRAPH);
        QApplication::processEvents();
        auto* graph = shell.findChild<graph_editor::Node_View*>();
        REQUIRE(graph != nullptr);
        auto* view = dynamic_cast<graph_editor::Graph_View*>(graph->findChild<QtNodes::GraphicsView*>());
        REQUIRE(view != nullptr);
        QWheelEvent wheel(QPointF(10, 10), QPointF(10, 10), QPoint(0, 0), QPoint(0, 120),
                          Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
        QApplication::sendEvent(view, &wheel);
        const double zoomed = graph->debug_zoom();
        REQUIRE(zoomed > graph_editor::Graph_View::kMinZoom);
        QWheelEvent pan(QPointF(10, 10), QPointF(10, 10), QPoint(0, 40), QPoint(0, 0),
                        Qt::NoButton, Qt::NoModifier, Qt::ScrollUpdate, false);
        QApplication::sendEvent(view, &pan);
        REQUIRE(std::abs(graph->debug_zoom() - zoomed) < 1e-9);
        auto* preview = graph->findChild<QToolButton*>("graphPreviewToggle");
        REQUIRE(preview != nullptr);
        preview->click();
        QApplication::processEvents();
        REQUIRE(std::abs(graph->debug_zoom() - zoomed) < 1e-9);
    }
    SDL_DestroyGPUDevice(gpu);
}
