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
#include <QPointer>
#include <QVariantAnimation>
#include <QPushButton>
#include <QScrollArea>
#include <QListWidget>
#include <QStackedWidget>
#include <QTreeWidget>

#include <QString>
#include <QWidget>
#include <QCloseEvent>



class QHBoxLayout;

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
constexpr int kGraphFullscreenReserve = 0; // central_ is hidden in GRAPH fullscreen: any leftover width would be spread over strip+panel (fixed widths), shifting the strip
constexpr int kStripIcon = 24;   // icon square inside a strip button
// Top-bar toolbar sizing (Plan 07): the header is 28px tall; buttons fit
// INSIDE it (the old 34px buttons clipped 6px top/bottom). Icons 16px in
// 24px buttons; divider groups keep 12px gaps.
constexpr int kToolbarBtn = 24;
constexpr int kToolbarIcon = 16;
enum class Sidebar_Mode { CONTROLS, FILES, LEARN, GRAPH, EXPORT, EFFECTS, SHORTCUTS };
constexpr int kModeCount = 7; // number of Sidebar_Mode values
enum class Interaction_Mode { AUTOROTATE, MOUSE_ROTATE };
enum class Preview_Mode { FLOAT, SPLIT, FULL };
using editor::Editor_Theme; // the settings menu + editor skins share it

struct Ui_State {
    bool paused = false;
    bool color = false;
    Interaction_Mode interaction = Interaction_Mode::AUTOROTATE;

    // Layout preset (P3-N4): Normal, Zen, Theater and Mobile are MUTUALLY
    // EXCLUSIVE. One enum replaces the 2^n matrix of independent flags that
    // produced the "code editor vanished" bug. Toggling one preset leaves
    // the others (the restore slots below hold the Normal-state values).
    // plan9: Normal=Development (all tools), Presentation (code+preview
    // emphasized, pipeline compact via GRAPH strip access), Pipeline
    // (graph emphasized). Zen/Theater/Mobile stay as before.
    enum class Layout_Preset { Normal, Zen, Theater, Mobile, Presentation,
                               Pipeline };
    Layout_Preset layout = Layout_Preset::Normal;
    Sidebar_Mode mode = Sidebar_Mode::CONTROLS;
    bool panel_open = true;
    float font_size = 14;
    float editor_font = 14;
    bool editor_pixel_font = false; // Sergamon pixel face for the code editor
    Preview_Mode preview = Preview_Mode::SPLIT; // default: code | preview
    float split_left = 0.42f;   // SPLIT: editor's fraction (plan5: ~42% editor | 58% preview)
    int snap_hover = -1;        // while dragging: 0=left 1=right -1=none (host writes, shell paints)
    bool editor_split = true;  // code | shader preview side-by-side (legacy prefs key)
    bool fullscreen_view = false; // F2: viewport page (preview hidden)
    bool graph_fullscreen = false; // transient, never persisted (prefs_save writes explicit keys)
    bool preview_hinted = false; // first-run drag hint shown once
    QPoint preview_nudge;        // keyboard arrow nudges for the FLOAT frame (host consumes)
    Editor_Theme theme = Editor_Theme::DARK;
    float user_w = 0;           // dragged panel width; 0 = per-mode default
    // Per-mode dragged widths (plan5): dragging FILES no longer rewrites
    // CONTROLS' width. Index = Sidebar_Mode; 0 = no user width for that mode
    // (falls back to panel_width_for's per-mode default).
    float user_w_mode[kModeCount] = {0, 0, 0, 0, 0, 0, 0};

    float gif_start = 0;
    float gif_end = 5;

    // Restore slots: the Normal-state values a preset hid. One set (the old
    // duplicate theater/mobile slots are gone — presets are exclusive).
    float saved_ui_font = 14, saved_ed_font = 14;
    bool saved_open = true;
    // plan9: preview geometry + sidebar mode are part of the restore.
    Preview_Mode saved_preview = Preview_Mode::SPLIT;
    float saved_split_left = 0.42f;
    Sidebar_Mode saved_mode = Sidebar_Mode::CONTROLS;
};

// Prefs: assets/ui.prefs, same keys as the Odin app.
void prefs_load(Ui_State& ui);
void prefs_save(const Ui_State& ui);

QString panel_width_for(const Ui_State& ui, Sidebar_Mode mode, int display_w);

// Frameless-window edge hit test (Plan 02 §4): the resize edges within a
// 5px band of the window border, or an empty Qt::Edges set.
Qt::Edges window_edge_at(const QPoint& window_pos);

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
    // plan9 workspace presets (F6 cycles Development → Presentation →
    // Pipeline → back; also in the settings gear menu).
    void cycle_workspace();
    // Saves all dirty editor tabs; host wires save_all_requested to a build.
    int save_all() { return editor_ ? editor_->save_all() : 0; }
    int dirty_count() const { return editor_ ? editor_->dirty_count() : 0; }
    // Global theme switch: re-skins the persistent chrome (topbar, strip,
    // scene list, panel frame, icons) from theme::'s active palette. The
    // settings menu calls theme::set_app_theme() first, then this.
    void apply_chrome_theme();
    // Bake feedback: amber border on the save button while a scene build
    // runs (host tick feeds it from Build_State).
    void set_baking(bool on);
    void set_preview_mode(Preview_Mode mode); // single entry: topbar/F3/drop
    QWidget* preview_overlay(); // snap-zone overlay (lazy; child of Shell)
    QWidget* preview_frame_overlay(); // themed border frame over the SDL window
    void set_preview_frame_rect(const QRect& global_rect);
    void set_snap_hover(int zone); // 0=split 1=full -1=none; paints the zones
    void set_split_gutter(float left_fraction); // drag path: instant follow
    void settle_split_gutter(float left_fraction); // drop path: spring settle
    void cycle_preview_mode(); // F3: float -> split -> full
    // Live safelight (overdrive): the host feeds the rendered frame's
    // average color; the chrome accents breathe with the shader.
    void set_live_tint(const QColor& c);
    // O2: PiP context label — scene name + target size, parked on the
    // preview's top edge. Hidden when the PiP is gone (fullscreen page).
    void set_pip_overlay(const QString& text, const QRect& global_rect);
signals:
    void scene_selected(int index);
    void scene_open_requested(const QString& title);
    void save_all_requested();
    // EXPORT panel: PNG of the current frame (host owns the GPU readback).
    void png_export_requested();
    // GIF: capture frames in [start,end] seconds, assemble at 17 fps.
    void gif_export_requested(float start_s, float end_s);
    // CONTROLS: reset the camera to the autorotate default (host owns the
    // camera state; the shell only requests).
    void camera_reset_requested();
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
    // Preview-mode segmented buttons in the topbar (FLOAT/SPLIT/FULL).
    QPushButton* preview_btns_[3] = {nullptr, nullptr, nullptr};
    void update_preview_buttons();
    // Snap-zone overlay + preview frame border (children of Shell).
    QWidget* preview_overlay_ = nullptr;
    bool gutter_dragging_ = false;
    bool gutter_hot_ = false; // cursor near the gutter: band lit amber
    QLabel* preview_hint_ = nullptr; // one-shot drag hint under the frame
    QColor live_tint_;               // frame-average color from the host
    QVariantAnimation* bake_pulse_ = nullptr;  // amber border wave while baking
    QVariantAnimation* bake_flash_ = nullptr;  // green success flash
    void update_live_tint_border();  // restore frame to live tint/theme
    QLabel* snap_left_ = nullptr;
    QLabel* snap_right_ = nullptr;
    QLabel* preview_border_ = nullptr;   // themed 1px frame over the SDL window
    QLabel* preview_gutter_ = nullptr;   // SPLIT drag handle (editor|preview)
    // Preview frame affordances: 1px themed border + snap zones + gutter.
    void update_preview_overlays();
    bool gutter_hit(const QPoint& global_pos) const;
    void update_split_layout(); // clamp editor width to the split fraction
    void update_panel_edge();
    void update_graph_cover(); // fullscreen GRAPH panel covers the central editor stack
    QWidget* topbar();
    QWidget* strip();
    QScrollArea* panel();
    QWidget* controls_panel();
    QWidget* files_panel();
    QWidget* editor_dock();
    QWidget* learn_panel();
    learn::Trail_View* trail_view_ = nullptr; // persists; pages swap in place
    QWidget* export_panel();
    QWidget* effects_panel();
    QWidget* shortcuts_panel();
    void apply_mode(Sidebar_Mode mode);
    QWidget* page_for(Sidebar_Mode mode);
    void sync_strip_buttons(Sidebar_Mode mode);
    // Ctor pieces.
    void setup_autosave();
    void bind_shortcuts();
    void restore_workspace();
    // Topbar pieces.
    void build_traffic_lights(QHBoxLayout* layout);
    void build_preview_segment(QHBoxLayout* layout);
    void build_save_pause(QHBoxLayout* layout);
    // Layout preset helpers.
    void save_normal_state();
    void restore_normal_state();
    void enter_preset(Ui_State::Layout_Preset preset);
    void persist_prefs(); // prefs_save with Normal-state values while a preset is active
    // Settings menu pieces.
    void add_language_menu(QMenu& settings);
    void add_theme_menu(QMenu& settings);
    void add_workspace_menu(QMenu& settings);
    void add_font_actions(QMenu& settings);
    // Files tree pieces.
    void route_tree_click(QTreeWidgetItem* item);
    void show_tree_context_menu(const QPoint& pos);
    void rename_shader_file(QTreeWidgetItem* item);
    // set_baking pieces.
    void restyle_save_button(bool on);
    void stop_bake_animations();
    void start_bake_pulse();
    void start_bake_flash();
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
    QWidget* panel_pages_[kModeCount] = {}; // Sidebar_Mode -> page; held by widget, never by stack index
    QPointer<QVariantAnimation> panel_anim_; // at most one live open/close tween
    QPointer<QVariantAnimation> split_anim_; // at most one live split settle
    QPushButton* new_btn_ = nullptr;         // "+ new"; re-tinted on theme switch
    QTreeWidget* files_tree_ = nullptr;          // persistent explorer tree
    QWidget* files_panel_page_ = nullptr;        // FILES page widget
    QPushButton* panel_edge_ = nullptr;
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
    QString pip_style_color_;        // last state color applied to pip_overlay_
    int pip_style_font_ = 0;         // last editor font size applied to it
    QString pip_text_;               // last caption text (adjustSize skip)
    int editor_w_drag_ = 0;          // editor width frozen while gutter drags
    QWidget* sdl_host_ = nullptr;
    QStackedWidget* central_ = nullptr;
    void show_editor(bool on);
    bool panel_cursor_ = false;      // SplitHCursor active on panel divider
};

} // namespace shell
