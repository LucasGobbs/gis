// Stage 4 shell: macOS-style top bar (traffic lights + scene selector +
// "+ new"), activity strip with 7 modes + save/pause, docked panels
// (controls/files/learn/graph/export/effects/shortcuts), settings gear,
// prefs (assets/ui.prefs), i18n, toasts. Qt Widgets replace Dear ImGui;
// layout uses named constants mirroring ui_layout.odin. The window is
// frameless: this top bar IS the chrome.
#pragma once

#include "editor.hpp"
#include "learn.hpp"
#include "graph_editor.hpp"
#include "gfx/scene_runtime.hpp"

#include <QMenu>
#include <QPropertyAnimation>
#include <QPushButton>
#include <QScrollArea>
#include <QListWidget>
#include <QStackedWidget>
#include <QTreeWidget>

#include <QString>
#include <QWidget>
#include <QCloseEvent>



namespace shell {

// Honours the OS "reduce motion" preference (macOS Accessibility). Qt 6 has
// no cross-platform equivalent, so gate non-essential animation on this.
// Definition in shell.cpp (CoreFoundation lives out of this header).
bool reduced_motion();

// Layout constants (ui_layout.odin). The window is natively framed: the OS
// title bar is styled transparent and melts into the Qt header — the Qt top
// bar is a toolbar under the native traffic lights.
constexpr int kTopbarH = 28;     // matches the macOS titlebar band (~28px)
constexpr int kStripButton = 34;
constexpr int kStripStep = 42;
constexpr int kStripTop = 10;
constexpr int kStripW = 52;      // strip column width
constexpr int kStripIcon = 24;   // icon square inside a strip button
enum class Sidebar_Mode { CONTROLS, FILES, LEARN, GRAPH, EXPORT, EFFECTS, SHORTCUTS };
enum class Interaction_Mode { AUTOROTATE, MOUSE_ROTATE };
using editor::Editor_Theme; // the settings menu + editor skins share it
enum class Scene_Template_Kind { COMPUTE, GRAPHICS_2D, GRAPHICS_3D };
enum class Fx_Intensity { OFF, SUBTLE, FULL };
enum class Fx_Kind { DEVELOP, SPRINGS, GRAIN };

struct Ui_State {
    bool paused = false;
    bool color = false;
    bool view3d = false;
    bool grid = false;
    Interaction_Mode interaction = Interaction_Mode::AUTOROTATE;

    // Layout preset (P3-N4): Normal, Zen, Theater and Mobile are MUTUALLY
    // EXCLUSIVE. One enum replaces the 2^n matrix of independent flags that
    // produced the "code editor vanished" bug. Toggling one preset leaves
    // the others (the restore slots below hold the Normal-state values).
    enum class Layout_Preset { Normal, Zen, Theater, Mobile };
    Layout_Preset layout = Layout_Preset::Normal;
    bool sidebar_open = true;   // zen hides it (derived from layout in toggles)
    Sidebar_Mode mode = Sidebar_Mode::CONTROLS;
    bool panel_open = true;
    float font_size = 14;
    float editor_font = 14;
    bool editor_pixel_font = false; // Sergamon pixel face for the code editor
    bool editor_split = true;  // code | shader preview side-by-side (default)
    bool fullscreen_view = false; // F2: viewport page (PiP hidden)
    Editor_Theme theme = Editor_Theme::DARK;
    float user_w = 0;           // dragged panel width; 0 = per-mode default

    float gif_start = 0;
    float gif_end = 5;

    // Restore slots: the Normal-state values a preset hid. One set (the old
    // duplicate theater/mobile slots are gone — presets are exclusive).
    float saved_ui_font = 14, saved_ed_font = 14;
    bool saved_open = true, saved_ed_open = false;
};

// Prefs: assets/ui.prefs, same keys as the Odin app.
void prefs_load(Ui_State& ui);
void prefs_save(const Ui_State& ui);

QString panel_width_for(const Ui_State& ui, Sidebar_Mode mode, int display_w);


// The whole chrome widget: owns strip + panel. Sits above the SDL child
// view via raising; the render surface fills the window behind.
class Shell : public QWidget {
    Q_OBJECT
public:
    explicit Shell(QWidget* parent, scene::Scene_Manager& mgr,
                   std::map<std::string, std::string>& roots);

    Ui_State ui;

    // The elastic center (editor page / fullscreen viewport page): the
    // anchor every host-side geometry computation targets. sdl_host_ is the
    // native-window content page and can be hidden — its bounds go stale.
    QWidget* viewport() const { return central_; }

    // ---- Native menubar surface (src/ui/menubar.cpp) ----
    // Scene menu mirror: the menubar's Scene menu is repopulated on every
    // refresh_scenes(); the shell owns the population (selector menu code).
    void set_scene_menu(QMenu* menu);
    // Mode via menu: same path as a strip click (open + rebuild panel).
    void show_mode(Sidebar_Mode mode);
    // Editor passthroughs for the Edit menu (no-ops without open tabs).
    void editor_undo_redo(bool redo);
    void editor_open_find();
    void editor_zoom(bool in);
    // Settings surface: strip gear + menubar Preferences share it.
    void open_settings_menu();
    // "+ new" creates a scene from a template (QInputDialog for the name;
    // the Odin-side 3-kind picker lands with the full parity pass). Public:
    // the File menu's New Scene item uses it too.
    void create_scene_dialog();

    // Host calls after mgr_.current changed and the scene is loaded.
    void scene_switched();
    // Saves the current scene's graph.json when the node canvas is dirty.
    void flush_graph_layout();
    // Typed access for the host's preview feed (GRAPH panel up).
    graph_editor::Node_View* graph_view_typed();
    bool graph_panel_visible() const {
        return ui.panel_open && ui.mode == Sidebar_Mode::GRAPH;
    }
    // Layout presets (P3-N4): Normal/Zen/Theater/Mobile, mutually exclusive.
    void set_layout(Ui_State::Layout_Preset preset);
    void toggle_zen() { set_layout(Ui_State::Layout_Preset::Zen); }
    void toggle_editor();
    void toggle_theater() { set_layout(Ui_State::Layout_Preset::Theater); }
    void toggle_mobile() { set_layout(Ui_State::Layout_Preset::Mobile); }
    // Saves all dirty editor tabs; host wires save_all_requested to a build.
    int save_all() { return editor_ ? editor_->save_all() : 0; }
    // Unsaved editor tabs (for the quit confirm).
    int dirty_count() const { return editor_ ? editor_->dirty_count() : 0; }
    // Global theme switch: re-skins the persistent chrome (topbar, strip,
    // scene list, panel frame, icons) from theme::'s active palette. The
    // settings menu calls theme::set_app_theme() first, then this.
    void apply_chrome_theme();
    // Bake feedback: amber border on the save button while a scene build
    // runs (host tick feeds it from Build_State).
    void set_baking(bool on);
    // O2: PiP context label — scene name + target size, parked on the
    // preview's top edge. Hidden when the PiP is gone (fullscreen page).
    void set_pip_overlay(const QString& text, const QRect& global_rect);

signals:
    void scene_selected(int index);
    void scene_open_requested(const QString& title);
    void pause_toggled();
    void save_all_requested();
    // EXPORT panel: PNG of the current frame (host owns the GPU readback).
    void png_export_requested();
    // GIF: capture frames in [start,end] seconds, assemble at 17 fps.
    void gif_export_requested(float start_s, float end_s);
    void mode_changed(shell::Sidebar_Mode mode);
    // Menubar: Preferences (Cmd+,) opens the settings menu; Close (Cmd+W)
    // closes the active editor tab or hides the side panel.
    void preferences_requested();
    void close_requested();
    // True while a Qt popup (scene menu) overlaps the viewport: the host
    // makes the SDL child window mouse-transparent for the duration, or the
    // NSWindowAbove child swallows the popup's clicks (menu draws above but
    // the child hits first).
    void popup_mouse_shield(bool on);

public slots:
    void refresh_scenes();

protected:
    void resizeEvent(QResizeEvent* event) override;
    void closeEvent(QCloseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void leaveEvent(QEvent* event) override;
    bool eventFilter(QObject* watched, QEvent* event) override;

private:
    // Panel left-edge drag: hit test + in-progress flag. The drag rewrites
    // ui.user_w (persisted in prefs), so the width survives restarts.
    bool panel_resize_hit(const QPoint& global_pos) const;
    bool panel_dragging_ = false;

    QPushButton* panel_edge_ = nullptr;
    void update_panel_edge();
    QWidget* topbar();
    QWidget* strip();
    QScrollArea* panel();
    QWidget* controls_panel();
    QWidget* files_panel();
    QWidget* editor_dock();
    QWidget* graph_view();
    QWidget* learn_panel();
    learn::Trail_View* trail_view_ = nullptr; // persists; pages swap in place
    QWidget* export_panel();
    QWidget* effects_panel();
    QWidget* shortcuts_panel();
    void apply_mode(Sidebar_Mode mode);
    void rebuild_selector_menu();
    // Docked scene list under the top bar (the selector's dropdown): an
    // in-layout panel because native QMenu/Qt::Popup windows lose the
    // mouse in this frameless + SDL-child setup.
    void show_scene_list(bool on);
    QWidget* scene_list_ = nullptr;
    QVBoxLayout* scene_list_layout_ = nullptr;
    // Panel open/close spring: animates the width to the target over
    // ~180 ms ease-out. One transition shared by every open/close path
    // (strip clicks, collapse, mode switches).
    void animate_panel_to(int target_w);

    scene::Scene_Manager& mgr_;
    std::map<std::string, std::string>& roots_;
    QWidget* topbar_ = nullptr;
    QWidget* strip_ = nullptr;
    QPushButton* save_btn_ = nullptr;
    QPushButton* pause_btn_ = nullptr;
    QScrollArea* panel_ = nullptr;
    QStackedWidget* panel_stack_ = nullptr;  // one persistent page per mode
    int panel_page_index_[7] = {-1, -1, -1, -1, -1, -1, -1}; // Sidebar_Mode -> stack idx
    QTreeWidget* files_tree_ = nullptr;          // persistent explorer tree
    QWidget* files_panel_page_ = nullptr;        // FILES page widget
    QLabel* pipeline_error_bar_ = nullptr;       // last bake failure, on-editor
    QLabel* pip_overlay_ = nullptr;              // PiP context label (O2)
    void update_pipeline_error_bar();
    void refresh_files_tree();                   // refill on scene switch
    QMenu* selector_menu_ = nullptr;
    QPushButton* selector_btn_ = nullptr;
    QPushButton* gear_btn_ = nullptr; // settings; re-tinted on theme switch
    QListWidget* scene_list_widget_ = nullptr; // docked scene list rows
    QMenu* scene_menu_ = nullptr;     // native Scene menu (menubar.cpp)
    void sync_scene_menu();
    graph_editor::Node_View* graph_view_ = nullptr;
    std::vector<QPushButton*> strip_buttons_;
    editor::Editor* editor_ = nullptr;
    QWidget* editor_dock_ = nullptr; // editor + status bar
    QWidget* sdl_host_ = nullptr;
    QStackedWidget* central_ = nullptr;
    void show_editor(bool on);
};

} // namespace shell
