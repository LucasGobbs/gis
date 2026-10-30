// Shell implementation: title bar, strip, panels, prefs, modes.
#include "shell.hpp"
#include "i18n.hpp"
#include "notify.hpp"
#include "theme.hpp"

#include <QCheckBox>
#include <QColorDialog>
#include <QDoubleSpinBox>
#include <QFile>
#include <QFileInfo>
#include <QHBoxLayout>
#include <QInputDialog>
#include <QLabel>
#include <QColor>
#include <QIcon>
#include <QImage>
#include <QPainter>
#include <QMenu>
#include <QPushButton>
#include <QRadioButton>
#include <QResizeEvent>
#include <QMouseEvent>
#include <QMessageBox>
#include <QScrollArea>
#include <QSlider>
#include <QTimer>
#include <QToolTip>
#include <QWindow>
#include "input_map.hpp"
#include <QShortcut>
#include <QApplication>
#include <algorithm>
#include <QVBoxLayout>
#include <Qsci/qsciscintilla.h>
#include <Qsci/qsciscintillabase.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#endif
#include <QDirIterator>
#include <QSet>
#include <QTreeWidget>

#include <cstdio>
#include <fstream>
#include <dirent.h>
#include <functional>
#include <QTreeWidgetItemIterator>

namespace shell {

static const char* kPrefsFile = "assets/ui.prefs";

bool reduced_motion() {
#ifdef __APPLE__
    CFBooleanRef flag = (CFBooleanRef)CFPreferencesCopyAppValue(
        CFSTR("reduceMotion"), CFSTR("com.apple.universalaccess"));
    if (flag) {
        bool on = CFBooleanGetValue(flag);
        CFRelease(flag);
        return on;
    }
#endif
    return false;
}

// ---- prefs ----

void prefs_load(Ui_State& ui) {
    std::ifstream f(kPrefsFile);
    if (!f.good()) return;
    std::string line;
    while (std::getline(f, line)) {
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq);
        std::string value = line.substr(eq + 1);
        if (key == "theme") {
            int v = std::atoi(value.c_str());
            if (v >= 0 && v <= int(Editor_Theme::SOLARIZED)) ui.theme = Editor_Theme(v);
        } else if (key == "editor_font") {
            ui.editor_font = std::clamp(std::atof(value.c_str()), 10.0, 28.0);
        } else if (key == "editor_pixel_font") {
            ui.editor_pixel_font = value == "1";
        } else if (key == "editor_split") {
            ui.editor_split = value == "1";
        } else if (key == "preview") {
            int v = std::atoi(value.c_str());
            if (v >= 0 && v <= int(Preview_Mode::FULL)) ui.preview = Preview_Mode(v);
        } else if (key == "preview_hinted") {
            ui.preview_hinted = value == "1";
        } else if (key == "split_left") {
            double v = std::atof(value.c_str());
            if (v >= 0.2 && v <= 0.8) ui.split_left = float(v);
        } else if (key == "ui_font") {
            ui.font_size = std::clamp(std::atof(value.c_str()), 12.0, 22.0);
        } else if (key.rfind("panel_width_", 0) == 0) { // panel_width_<mode>
            int idx = std::atoi(key.c_str() + 12);
            double v = std::atof(value.c_str());
            if (idx >= 0 && idx < kModeCount && v >= 220)
                ui.user_w_mode[idx] = float(v);
        } else if (key == "layout") { // plan9: workspace preset persists
            int v = std::atoi(value.c_str());
            if (v >= 0 && v <= int(Ui_State::Layout_Preset::Pipeline))
                ui.layout = Ui_State::Layout_Preset(v);
        } else if (key == "panel_width") { // legacy global width (pre-plan5)
            double v = std::atof(value.c_str());
            if (v >= 220) ui.user_w = float(v);
        }
    }
}

void prefs_save(const Ui_State& ui) {
    std::ofstream f(kPrefsFile, std::ios::trunc);
    if (!f.good()) {
        notify::notify(notify::Kind::ERROR_, "prefs: could not write assets/ui.prefs");
        return;
    }
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.0f", ui.user_w);
    f << "theme=" << int(ui.theme) << "\n"
      << "editor_font=" << int(ui.editor_font) << "\n"
      << "editor_pixel_font=" << (ui.editor_pixel_font ? 1 : 0) << "\n"
      << "editor_split=" << (ui.editor_split ? 1 : 0) << "\n"
      << "preview=" << int(ui.preview) << "\n"
      << "preview_hinted=" << (ui.preview_hinted ? 1 : 0) << "\n"
      << "split_left=" << ui.split_left << "\n"
      << "layout=" << int(ui.layout) << "\n"
      << "ui_font=" << int(ui.font_size) << "\n";
    for (int i = 0; i < kModeCount; ++i) {
        if (ui.user_w_mode[i] > 0) {
            char w[64];
            std::snprintf(w, sizeof w, "%.0f", ui.user_w_mode[i]);
            f << "panel_width_" << i << "=" << w << "\n";
        }
    }
    // Legacy global width: kept as fallback for older builds reading prefs.
    f << "panel_width=" << (ui.user_w > 0 ? buf : "") << "\n";
    // ofstream flushes on destruction; good() here catches mid-stream failure.
    if (!f.good())
        notify::notify(notify::Kind::ERROR_, "prefs: write failed mid-stream");
}


static QString mode_name(Sidebar_Mode mode) {
    switch (mode) {
    case Sidebar_Mode::CONTROLS: return i18n::tr("controls");
    case Sidebar_Mode::FILES: return i18n::tr("file explorer");
    case Sidebar_Mode::LEARN: return i18n::tr("learn");
    case Sidebar_Mode::GRAPH: return i18n::tr("graph");
    case Sidebar_Mode::EXPORT: return i18n::tr("export");
    case Sidebar_Mode::EFFECTS: return i18n::tr("effects");
    case Sidebar_Mode::SHORTCUTS: return i18n::tr("shortcuts");
    }
    return {};
}

using theme::tinted_icon;

// Icon tint follows the active skin's primary text; re-applied per theme.
static QColor icon_tint() { return theme::text_primary(); }

// Topbar icons shared by the builders and the theme re-tint (so a theme
// switch cannot swap glyphs).
//   FLOAT → action/ungroup.svg (free/unattached frame)
//   SPLIT → action/separate-horizontal.svg (two panes side-by-side)
//   FULL  → action/fullscreen.svg (expand to whole canvas)
// Plan 07: Qlementine 16px set (the 24px set lacks these three).
static const char* const kPreviewIcons[3] = {
    ":/qlementine/icons/16/action/ungroup.svg",
    ":/qlementine/icons/16/action/separate-horizontal.svg",
    ":/qlementine/icons/16/action/fullscreen.svg",
};
// action/save-all only ships at 16px (upscaled = blur); the 24px save glyph
// is the crisp same-verb choice.
static const char* const kSaveIcon = ":/qlementine/icons/24/action/save.svg";
static const char* const kNewIcon = ":/qlementine/icons/24/document/new.svg";

QString panel_width_for(const Ui_State& ui, Sidebar_Mode mode, int display_w) {
    if (mode == Sidebar_Mode::GRAPH && ui.graph_fullscreen)
        return QString::number(std::max(display_w - kStripW - kGraphFullscreenReserve, 0));
    const int idx = int(mode);
    if (idx >= 0 && idx < kModeCount) {
        if (ui.user_w_mode[idx] > 0)
            return QString::number(std::clamp(ui.user_w_mode[idx],
                                              float(theme::kPanelMinW),
                                              display_w * 0.85f), 'f', 0);
        // Legacy single dragged width (pre-plan5 prefs): still honored so
        // the old value keeps meaning "the width I chose".
        if (ui.user_w > 0)
            return QString::number(std::clamp(ui.user_w,
                                              float(theme::kPanelMinW),
                                              display_w * 0.85f), 'f', 0);
    }
    switch (mode) {
    case Sidebar_Mode::CONTROLS: return "300";
    case Sidebar_Mode::FILES: return "280";
    case Sidebar_Mode::LEARN: return "340";
    case Sidebar_Mode::GRAPH: return QString::number(display_w * 0.52, 'f', 0);
    case Sidebar_Mode::EXPORT: return "280";
    case Sidebar_Mode::EFFECTS: return "280";
    case Sidebar_Mode::SHORTCUTS: return "320";
    }
    return "300";
}

static bool scene_name_valid(const QString& name) {
    if (name.isEmpty() || name.size() > 64) return false;
    for (QChar c : name) {
        if (!(c.isLetterOrNumber() || c == '_')) return false;
    }
    return true;
}

static bool scene_name_taken(const QString& name,
                             const std::map<std::string, std::string>& roots) {
    return roots.find(name.toStdString()) != roots.end();
}

static QStringList trail_names() {
    QStringList out;
    DIR* d = opendir("assets/trails");
    if (!d) return out;
    while (dirent* e = readdir(d)) {
        QString n = QString::fromUtf8(e->d_name);
        if (n.endsWith(".md")) out << n.chopped(3);
    }
    closedir(d);
    std::sort(out.begin(), out.end());
    return out;
}

// ---- Shell ----


// ---- Chrome stylesheets (theme-aware) ----
// Built from theme::'s ACTIVE palette on every call; the ctor and
// apply_chrome_theme() share them so a theme switch re-skins everything.
static QString scene_list_qss() {
    return QString("QWidget { background: %1; }"
                   "QPushButton { text-align: left; padding: 6px 14px; border: none;"
                   " border-radius: 4px; color: %2; background: transparent;"
                   " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
                   "QPushButton:disabled { color: %3; }"
                   "QPushButton:hover:enabled { background: rgba(232,168,87,0.18); }"
                   "QPushButton:checked { background: rgba(232,168,87,0.28);"
                   " color: %4; }")
        .arg(theme::surface_tray(), theme::text_primary(), theme::text_muted(),
             theme::safelight());
}
static QString scene_list_items_qss() {
    return QString("QListWidget { background: transparent; border: none;"
                   " outline: none; font-family: 'JetBrains Mono', monospace;"
                   " font-size: 9pt; color: %1; }"
                   "QListWidget::item { padding: 6px 14px; border-radius: 4px; }"
                   "QListWidget::item:hover { background: rgba(232,168,87,0.18); }"
                   "QListWidget::item:selected { background: rgba(232,168,87,0.28);"
                   " color: %2; }")
        .arg(theme::text_primary(), theme::safelight());
}
static QString topbar_qss() {
    // Plan 07: toolbar states from theme tokens (the old rgba(232,168,87,…)
    // amber literals broke contrast on light skins). Disabled: muted, no
    // background; pressed: deeper wash than hover; active: hover wash +
    // safelight border.
    return QString("QWidget { background: %1; }"
                   "QPushButton { background: transparent; border: none;"
                   " border-radius: 5px; padding: 2px 8px; color: %2;"
                   " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
                   "QPushButton[hovered=\"true\"]:enabled { background: %3; }"
                   "QPushButton:pressed { background: %4; }"
                   "QPushButton:disabled { color: %5; }"
                   "QPushButton[active=\"true\"] { background: %3;"
                   " border: 1px solid %6; }"
                   "QPushButton:focus { border: 1px solid %6; }")
        .arg(theme::surface_bench(), theme::text_primary(),
             theme::hover_overlay(), theme::pressed_overlay(),
             theme::text_muted(), theme::safelight());
}
static QString strip_qss() {
    return QString("QWidget { background: %1; }"
                   "QPushButton { border: 1px solid transparent;"
                   " background: transparent; border-radius: 8px; }"
                   "QPushButton[hovered=\"true\"] { background: rgba(255,255,255,0.07); }"
                   "QPushButton[active=\"true\"] {"
                   " background: rgba(255,255,255,0.10); }"
                   "QPushButton:focus { border: 1px solid %2; }")
        .arg(theme::surface_bench(), theme::safelight());
}
static QString panel_qss() {
    return QString("QWidget { background: %1; color: %2; font-size: 9pt; }"
                   "QPushButton { background: rgba(255,255,255,0.06); border: none;"
                   " border-radius: 4px; padding: 4px 8px; }"
                   "QPushButton[hovered=\"true\"] { background: rgba(255,255,255,0.12); }"
                   "QLabel[caption=\"true\"] { color: %3; font-weight: 700;"
                   " letter-spacing: 1px; }"
                   "QCheckBox, QRadioButton { color: %2; spacing: 7px; }"
                   "QCheckBox::indicator, QRadioButton::indicator { width: 14px; height: 14px; }"
                   "QCheckBox::indicator:checked, QRadioButton::indicator:checked {"
                   " background: %4; border: 1px solid %4; border-radius: 3px; }"
                   "QCheckBox::indicator:unchecked, QRadioButton::indicator:unchecked {"
                   " background: transparent; border: 1px solid %6; border-radius: 3px; }"
                   "QDoubleSpinBox, QComboBox { background: rgba(255,255,255,0.05);"
                   " border: none; border-radius: 4px; padding: 3px 6px;"
                   " selection-background-color: %4; selection-color: %5; }")
        .arg(theme::surface_panel(), theme::text_primary(), theme::text_muted(),
             theme::safelight(), theme::surface_workspace(), theme::control_border());
}
static QString panel_edge_qss() {
    return QString("QPushButton#panelEdge { background: rgba(232,168,87,0.14);"
                   " border: none; border-radius: 3px; color: %1; font-size: 9pt; }"
                   "QPushButton#panelEdge[hovered=\"true\"] { background: rgba(232,168,87,0.38); }")
        .arg(theme::safelight());
}

Shell::Shell(QWidget* parent, scene::Scene_Manager& mgr,
             std::map<std::string, std::string>& roots)
    : QWidget(parent), mgr_(mgr), roots_(roots) {
    prefs_load(ui);
    // Boot with the persisted skin: Qlementine theme + chrome constants
    // BEFORE any widget builds (they read theme::'s accessors).
    theme::set_app_theme(theme::App_Theme(int(ui.theme)));
    i18n::init();

    auto* outer = new QVBoxLayout(this);
    outer->setContentsMargins(0, 0, 0, 0);
    outer->setSpacing(0);
    outer->addWidget(topbar());
    // Scene list panel: docked under the top bar, toggled by the selector.
    scene_list_ = new QWidget(this);
    scene_list_->setStyleSheet(scene_list_qss());
    scene_list_layout_ = new QVBoxLayout(scene_list_);
    scene_list_layout_->setContentsMargins(10, 8, 10, 10);
    scene_list_layout_->setSpacing(2);
    // OVERLAY: floats above everything (top-right under the top bar) and
    // pushes NOTHING down. Plan 07 P2 fix: as a plain child widget it hid
    // UNDER the native SDL NSWindow (NSWindowAbove) whenever it overlapped
    // the preview — the right half of the window, exactly where it opens.
    // Qt::ToolTip + StaysOnTop = a real top-level window above the SDL
    // child, like the toast layer; no focus steal, no taskbar entry.
    scene_list_->setWindowFlags(Qt::ToolTip | Qt::FramelessWindowHint |
                                Qt::WindowStaysOnTopHint);
    scene_list_->setAutoFillBackground(true);
    scene_list_->hide();
    auto* body = new QHBoxLayout();
    body->setContentsMargins(0, 0, 0, 0);
    body->setSpacing(0);
    body->addWidget(strip());
    sdl_host_ = new QWidget(this);
    sdl_host_->setAttribute(Qt::WA_NativeWindow); // own NSView to host SDL
    // Sidebar on the LEFT (next to the strip), per the layout contract; the
    // editor owns the rest of the window permanently.
    body->addWidget(panel());                     // fixed width via apply_mode
    central_ = new QStackedWidget(this);
    central_->addWidget(editor_dock());           // page 0: code editor (always)
    central_->addWidget(sdl_host_);               // page 1: fullscreen viewport (zen)
    central_->setCurrentIndex(0);
    body->addWidget(central_, 1);                 // elastic center
    outer->addLayout(body, 1);
    apply_mode(ui.mode);

    setup_autosave();
    // Tab order (P1 audit): top bar left→right, then the mode strip. The
    // panel content is built once per mode, so its widgets inherit the
    // default (visual) order.
    setTabOrder(selector_btn_, save_btn_);
    setTabOrder(save_btn_, pause_btn_);
    setTabOrder(pause_btn_, strip_buttons_.front());
    for (size_t i = 1; i < strip_buttons_.size(); ++i)
        setTabOrder(strip_buttons_[i - 1], strip_buttons_[i]);
    // Menubar signals: Preferences re-opens the shared settings menu; Close
    // closes the active editor tab, else collapses the side panel (Cmd+W).
    connect(this, &Shell::preferences_requested, this,
            &Shell::open_settings_menu);
    connect(this, &Shell::close_requested, this, [this] {
        if (ui.mode == Sidebar_Mode::FILES && editor_ &&
            editor_->currentWidget()) {
            editor_->close_current_tab();
            return;
        }
        ui.panel_open = false;
        animate_panel_to(0);
    });
    // SPLIT adaptation: the code editor must NOT keep the whole viewport
    // width while the preview docks beside it; the max-width clamp re-runs
    // on every mode/preview change and window resize.
    connect(this, &Shell::mode_changed, this,
            [this](shell::Sidebar_Mode) { update_split_layout(); });
    bind_shortcuts();
    refresh_scenes();
    // Outside-click dismissal for the floating scene list: the list is a
    // plain overlay (not a native popup), so a press on ANY other widget
    // must close it. Application-level filter watches every press.
    // Also drives the side-panel divider's hover cursor: the divider band
    // sits INSIDE the QScrollArea, whose viewport consumes mouse moves —
    // Shell::mouseMoveEvent never sees that hover. The app filter does.
    qApp->installEventFilter(this);
    // Preview segmented control + overlays mirror the persisted mode.
    update_preview_buttons();
    update_preview_overlays();
    restore_workspace();
}

// Graph layout autosave: every 10 s (the Odin 600-frame tick) and on quit.
// Scene switch flushes separately in the host's scene_selected.
void Shell::setup_autosave() {
    if (qEnvironmentVariableIsSet("GIS_NO_AUTOSAVE")) return;
    auto* autosave = new QTimer(this);
    autosave->setInterval(10000);
    connect(autosave, &QTimer::timeout, this, &Shell::flush_graph_layout);
    autosave->start();
    connect(qApp, &QCoreApplication::aboutToQuit, this, &Shell::flush_graph_layout);
}

// input.ini as the single key source (BUG-10). Window-mode actions bind
// here; editor chords stay Qt-native (Find/Ctrl+G/Escape).
void Shell::bind_shortcuts() {
    auto bind_action = [this](const char* action, const char* fallback,
                              void (Shell::*slot)()) {
        QVector<QKeySequence> seqs = input_map::load("assets/input.ini", action);
        if (seqs.isEmpty()) seqs.push_back(QKeySequence(fallback)); // ini fallback
        for (const QKeySequence& seq : seqs)
            connect(new QShortcut(seq, this), &QShortcut::activated, this, slot);
    };
    bind_action("toggle_theater", "F4", &Shell::toggle_theater);
    bind_action("toggle_mobile", "F5", &Shell::toggle_mobile);
    bind_action("cycle_workspace", "F6", &Shell::cycle_workspace);
    bind_action("toggle_editor", "F2", &Shell::toggle_editor);
    bind_action("cycle_preview", "F3", &Shell::cycle_preview_mode);
    // FLOAT geometry by keyboard (critique P2): arrows nudge the floating
    // frame; the host consumes ui.preview_nudge in its tick and moves the
    // real rect (persisted via pip_save_prefs on the next drag/save).
    const Qt::Key nudge_keys[4] = {Qt::Key_Left, Qt::Key_Right, Qt::Key_Up,
                                   Qt::Key_Down};
    const QPoint nudge_dirs[4] = {{-8, 0}, {8, 0}, {0, -8}, {0, 8}};
    for (int d = 0; d < 4; ++d) {
        auto* sc = new QShortcut(QKeySequence(int(nudge_keys[d]) | Qt::META),
                                 this);
        connect(sc, &QShortcut::activated, this, [this, delta = nudge_dirs[d]] {
            if (ui.preview != Preview_Mode::FLOAT) return;
            ui.preview_nudge += delta;
        });
    }
    // Cmd+1..5: sidebar modes (files, graph, controls, export, commands),
    // in strip order. Same show_mode path as a strip click.
    const Sidebar_Mode mode_keys[5] = {
        Sidebar_Mode::FILES, Sidebar_Mode::GRAPH,     Sidebar_Mode::CONTROLS,
        Sidebar_Mode::EXPORT, Sidebar_Mode::SHORTCUTS,
    };
    for (int i = 0; i < 5; ++i) {
        auto* sc = new QShortcut(QKeySequence(QString("Meta+%1").arg(i + 1)), this);
        connect(sc, &QShortcut::activated, this,
                [this, mode = mode_keys[i]] { show_mode(mode); });
    }
    for (const QKeySequence& seq : input_map::load("assets/input.ini", "toggle_sidebar")) {
        auto* sc = new QShortcut(seq, this);
        connect(sc, &QShortcut::activated, this, [this] { toggle_zen(); });
    }
}

// plan9: a persisted non-Normal workspace re-applies on boot (the ctor built
// Normal's chrome; set_layout saves the Normal values and shapes the
// workspace). Normal needs nothing.
void Shell::restore_workspace() {
    if (ui.layout == Ui_State::Layout_Preset::Normal) return;
    const auto persisted = ui.layout;
    ui.layout = Ui_State::Layout_Preset::Normal; // force the shape pass
    set_layout(persisted);
}


void Shell::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    // GRAPH panel width depends on window width (0: full-width canvas) and
    // panel_width_for clamps user_w to a width fraction. Re-running
    // apply_mode on every resize would rebuild the panel content, so only
    // the user-width clamp needs the refresh; the default per-mode widths
    // are constants. Keep apply_mode out of the resize path.
    if (panel_ && ui.mode == Sidebar_Mode::GRAPH && ui.graph_fullscreen && ui.panel_open)
        panel_->setFixedWidth(panel_width_for(ui, ui.mode, width()).toInt());
    update_panel_edge();
    update_preview_overlays(); // snap zones follow the window
    update_split_layout(); // editor clamp tracks the new viewport width
}

// Frameless resize bands (Plan 02 §4): 5px inside every window edge.
// Window-local coords; the caller converts from global.
Qt::Edges window_edge_at(const QPoint& window_pos) {
    constexpr int kEdge = 5;
    const QWidget* w = QApplication::activeWindow();
    if (!w) return {};
    const QRect r = w->rect();
    if (!r.contains(window_pos)) return {}; // outside (incl. titlebar band above)
    Qt::Edges edges;
    if (window_pos.x() < kEdge) edges |= Qt::LeftEdge;
    if (window_pos.x() >= r.width() - kEdge) edges |= Qt::RightEdge;
    if (window_pos.y() < kEdge) edges |= Qt::TopEdge;
    if (window_pos.y() >= r.height() - kEdge) edges |= Qt::BottomEdge;
    return edges;
}

// ---- Side panel ("MenubarDetails": the panel that opens to the right of
// the icon strip — CONTROLS/FILES/GRAPH/... — when a strip button is
// clicked; this name maps the Plan 02 task wording onto the code) ----

// The drag zone is an 8px band on the panel's left edge (inside the panel
// AND the window edge beside it, so the grab is forgiving). 8px unifies the
// grab difficulty with the preview gutter (critique P2: 6 vs 10 bands).
bool Shell::panel_resize_hit(const QPoint& global_pos) const {
    if (!panel_ || !panel_->isVisible() || ui.mode == Sidebar_Mode::GRAPH)
        return false;
    const int edge = panel_->mapToGlobal(QPoint(0, 0)).x();
    return qAbs(global_pos.x() - edge) <= 4;
}

// Snap zones in VIEWPORT coords (the space between sidebar and window
// right): left half = split dock, whole space = fullscreen dock. Global
// rects so the host can hit-test the drag in the same space.
static QRect viewport_global_rect(const Shell* shell) {
    QWidget* vp = shell->viewport();
    return QRect(vp->mapToGlobal(QPoint(0, 0)), vp->size());
}

// SPLIT gutter: hit band around the editor|preview boundary line.
bool Shell::gutter_hit(const QPoint& global_pos) const {
    if (ui.preview != Preview_Mode::SPLIT || ui.fullscreen_view || !viewport())
        return false;
    const QRect vp_g = viewport_global_rect(this);
    if (!vp_g.contains(global_pos)) return false;
    const int split_x = vp_g.left() + int(vp_g.width() * ui.split_left);
    return qAbs(global_pos.x() - split_x) <= 4; // 8px grip: matches kPipEdge
}

// SPLIT: the editor keeps only its fraction of the viewport (the SDL frame
// covers the rest). Other modes release the clamp.
void Shell::update_split_layout() {
    if (!editor_dock_) return;
    if (ui.preview != Preview_Mode::SPLIT || ui.fullscreen_view) {
        editor_dock_->setMaximumWidth(QWIDGETSIZE_MAX);
        editor_w_drag_ = 0;
        return;
    }
    QWidget* vp = viewport();
    if (!vp) return;
    const int editor_w = std::clamp(int(vp->width() * ui.split_left),
                                    theme::kEditorMinW,
                                    vp->width() - theme::kEditorMinW);
    // Gutter drag: freeze the editor's width for the whole gesture (Plan 04
    // Task A). Rewriting maximumWidth per mouse-move re-lays-out and repaints
    // QScintilla ~120x/s — the drag stutter. The Preview itself keeps moving:
    // the host's per-tick setFrame covers the freed space immediately.
    // Commit happens in settle_split_gutter; a window resize mid-drag still
    // clamps through the same path (frozen value recomputed from vp width).
    if (gutter_dragging_) {
        if (editor_w_drag_ == 0)
            editor_w_drag_ = std::clamp(editor_dock_->width(),
                                        theme::kEditorMinW,
                                        vp->width() - theme::kEditorMinW);
        editor_dock_->setMaximumWidth(editor_w_drag_);
        editor_dock_->setMinimumWidth(std::min(editor_w_drag_,
                                               theme::kEditorMinW));
        return;
    }
    editor_w_drag_ = 0;
    editor_dock_->setMaximumWidth(editor_w);
    editor_dock_->setMinimumWidth(std::min(editor_w, theme::kEditorMinW));
}

void Shell::mousePressEvent(QMouseEvent* event) {
    const QPoint gp = event->globalPosition().toPoint();
    if (event->button() == Qt::LeftButton && panel_resize_hit(gp)) {
        panel_dragging_ = true;
        event->accept();
        return;
    }
    if (event->button() == Qt::LeftButton && gutter_hit(gp)) {
        gutter_dragging_ = true;
        event->accept();
        return;
    }
    QWidget::mousePressEvent(event);
}

// Top-bar press = window drag. The native title bar is styled transparent
// (host_main.mm), so without this the header clicks land on Qt widgets and
// the window never moves. Installed as an event filter ON the top bar: the
// bar's styled background ACCEPTS background presses, so Shell::
// mousePressEvent never saw them; from the filter, startSystemMove works.
// Buttons inside the bar accept their own presses (no filter interference).
// Plan 07 P2 fix: QlementineStyle caches the QSS :hover wash — after the
// first click the background stays lit forever (strip, topbar, traffic
// lights… every icon button). Driving hover through a PROPERTY instead of
// the pseudo-class forces a repolish on Enter/Leave, so the wash is painted
// and cleared deterministically.
static void set_btn_hovered(QPushButton* btn, bool hovered) {
    if (btn->property("hovered").toBool() == hovered) return;
    btn->setProperty("hovered", hovered);
    btn->style()->unpolish(btn);
    btn->style()->polish(btn);
    btn->update();
}

bool Shell::eventFilter(QObject* watched, QEvent* event) {
    // Hover tracking for every QPushButton in the shell (app-level filter
    // sees Enter/Leave for all of them).
    if (event->type() == QEvent::Enter || event->type() == QEvent::Leave) {
        if (auto* btn = qobject_cast<QPushButton*>(watched))
            set_btn_hovered(btn, event->type() == QEvent::Enter);
    }
    // Outside-click dismissal: any press NOT inside the open scene list
    // (and not on the selector that toggles it) closes the list. The
    // filter is application-level (installed in the ctor).
    if (event->type() == QEvent::MouseButtonPress && scene_list_ &&
        scene_list_->isVisible()) {
        auto* press = static_cast<QMouseEvent*>(event);
        const QPoint gp = press->globalPosition().toPoint();
        bool inside_list = scene_list_->rect().contains(
            scene_list_->mapFromGlobal(gp));
        QWidget* hit = qApp->widgetAt(gp);
        bool on_selector = hit == selector_btn_ ||
                           (hit && hit->parentWidget() == selector_btn_);
        if (!inside_list && !on_selector) show_scene_list(false);
    }
    // Frameless window: no native resize bands left — the filter supplies
    // them. A press within 5px of a window edge starts the NATIVE system
    // resize for that edge; hover shows the matching resize cursor. Runs
    // on EVERY widget (app-level filter) so edges work over the editor,
    // the SDL child's Qt-side siblings and the chrome alike.
    if (event->type() == QEvent::MouseButtonPress &&
        static_cast<QMouseEvent*>(event)->button() == Qt::LeftButton) {
        const QPoint gp = static_cast<QMouseEvent*>(event)
                              ->globalPosition()
                              .toPoint();
        if (Qt::Edges edges = window_edge_at(mapFromGlobal(gp));
            edges != Qt::Edges()) {
            if (windowHandle() && windowHandle()->startSystemResize(edges))
                return true; // native resize owns the gesture
        }
    }
    if (event->type() == QEvent::MouseMove) {
        const QPoint gp = static_cast<QMouseEvent*>(event)
                              ->globalPosition()
                              .toPoint();
        const Qt::Edges edges = window_edge_at(mapFromGlobal(gp));
        const bool over_chrome = watched == topbar_;
        if (edges != Qt::Edges()) {
            const Qt::CursorShape shape =
                (edges & (Qt::LeftEdge | Qt::RightEdge)) &&
                        !(edges & (Qt::TopEdge | Qt::BottomEdge))
                    ? Qt::SizeHorCursor
                    : (edges & (Qt::TopEdge | Qt::BottomEdge)) &&
                              !(edges & (Qt::LeftEdge | Qt::RightEdge))
                          ? Qt::SizeVerCursor
                          : Qt::SizeFDiagCursor;
            setCursor(shape);
        } else if (over_chrome || watched == this) {
            unsetCursor();
        }
    }
    // Side-panel divider hover: SplitHCursor over the 8px grab band. Lives
    // HERE because the panel's scroll viewport eats mouse moves before
    // Shell::mouseMoveEvent would see them (Plan 02 §2).
    if (panel_ && (event->type() == QEvent::MouseMove ||
                   event->type() == QEvent::Leave)) {
        QWidget* panel_vp = panel_->viewport();
        if (watched == panel_vp || watched == panel_) {
            const bool leave = event->type() == QEvent::Leave;
            const QPoint gp = leave
                                  ? QPoint(-1, -1)
                                  : static_cast<QMouseEvent*>(event)
                                        ->globalPosition()
                                        .toPoint();
            const bool on_band = !leave && panel_resize_hit(gp);
            if (panel_cursor_ != on_band) {
                panel_cursor_ = on_band;
                panel_->setCursor(on_band ? Qt::SplitHCursor
                                          : Qt::ArrowCursor);
            }
        }
    }
    // Window drag + double-click maximize (Plan 02 §3/§4). The filter runs
    // on the TOPBAR only: childAt() reports the interactive child under the
    // cursor; empty regions hit the bar itself. A press on the bar (any
    // non-interactive area) starts the NATIVE system move — no geometry
    // math, no coordinates to break per-DPI. Double-click on the same
    // background toggles maximize/restore through the platform path
    // (showMaximized/showNormal preserve the pre-maximize geometry).
    if (watched == topbar_) {
        if (event->type() == QEvent::MouseButtonPress) {
            auto* me = static_cast<QMouseEvent*>(event);
            if (me->button() == Qt::LeftButton &&
                !topbar_->childAt(me->position().toPoint()) &&
                windowHandle() && windowHandle()->startSystemMove())
                return true; // drag consumed the press
        }
        if (event->type() == QEvent::MouseButtonDblClick) {
            auto* me = static_cast<QMouseEvent*>(event);
            if (me->button() == Qt::LeftButton &&
                !topbar_->childAt(me->position().toPoint())) {
                // Never stack a maximize on top of an already-fullscreen
                // state; restore returns to the pre-maximize geometry
                // (tracked by the platform window, no manual bookkeeping).
                if (isMaximized())
                    showNormal();
                else if (windowHandle() &&
                         windowHandle()->windowStates() &
                             Qt::WindowFullScreen)
                    ; // fullscreen (F4/theater): leave it alone
                else
                    showMaximized();
                return true;
            }
        }
    }
    return QWidget::eventFilter(watched, event);
}

void Shell::mouseMoveEvent(QMouseEvent* event) {
    const QPoint gp = event->globalPosition().toPoint();
    if (panel_dragging_) {
        // Right edge grows leftward: width = window right - cursor.
        const int win_right = mapToGlobal(QPoint(width(), 0)).x();
        float w = float(win_right - gp.x());
        w = std::clamp(w, float(theme::kPanelMinW), width() * 0.85f);
        const int idx = int(ui.mode);
        if (idx >= 0 && idx < kModeCount) ui.user_w_mode[idx] = w; // per-mode (plan5)
        ui.user_w = w; // legacy key stays in sync for older builds
        panel_->setFixedWidth(int(w));
        // Live size readout where the cursor is: the number IS the
        // affordance (drag feels like an editorial resize tool).
        QToolTip::showText(gp + QPoint(12, 0),
                           QString("%1 px").arg(int(w)), panel_);
        event->accept();
        return;
    }
    if (gutter_dragging_) {
        // Re-fraction the split from the cursor position in the viewport.
        const QRect vp_g = viewport_global_rect(this);
        float f = float(gp.x() - vp_g.left()) / float(vp_g.width());
        set_split_gutter(f);
        QToolTip::showText(gp + QPoint(12, 0),
                           QString("%1 %").arg(int(f * 100 + 0.5f)), viewport());
        event->accept();
        return;
    }
    // Gutter hover affordance: the band brightens when the cursor is near,
    // so the drag affordance is visible BEFORE the first grab (the cursor
    // alone is a weak signal on a dark theme).
    bool near_gutter = gutter_hit(gp) || panel_resize_hit(gp);
    if (gutter_hot_ != near_gutter) {
        gutter_hot_ = near_gutter;
        if (preview_gutter_)
            preview_gutter_->setStyleSheet(
                QString("QLabel { background: %1; border-radius: 2px; }")
                    .arg(near_gutter ? theme::safelight() : theme::frame_border()));
    }
    setCursor(near_gutter ? Qt::SplitHCursor : Qt::ArrowCursor);
    QWidget::mouseMoveEvent(event);
}


void Shell::mouseReleaseEvent(QMouseEvent* event) {
    if (panel_dragging_) {
        persist_prefs();
        panel_dragging_ = false;
        QToolTip::hideText();
        event->accept();
        return;
    }
    if (gutter_dragging_) {
        gutter_dragging_ = false; // freeze cleared in settle_split_gutter
        editor_w_drag_ = 0;       // commit the frozen width at drag end
        settle_split_gutter(ui.split_left); // damped spring + persist once
        event->accept();
        return;
    }
    QWidget::mouseReleaseEvent(event);
}

// Native window close (red light / Cmd+Q): confirm before losing unsaved
// editor tabs — the old hand-rolled close light owned this check.
void Shell::closeEvent(QCloseEvent* event) {
    if (dirty_count() > 0) {
        QMessageBox::StandardButton pick = QMessageBox::question(
            this, i18n::tr("unsaved changes"),
            i18n::tr("unsaved tabs quit anyway?"),
            QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel,
            QMessageBox::Save);
        if (pick == QMessageBox::Cancel) {
            event->ignore();
            return;
        }
        if (pick == QMessageBox::Save) save_all();
    }
    QWidget::closeEvent(event);
}

void Shell::leaveEvent(QEvent* event) {
    if (!panel_dragging_) unsetCursor();
    panel_cursor_ = false; // re-arm the divider hover for the next entry
    QWidget::leaveEvent(event);
}

// "+ new": creates a scene from the 2D graphics template under
// gis_scenes/<name>/. The 3-kind picker lands with the full parity pass;
// compute-only scenes can be authored by hand meanwhile.
void Shell::create_scene_dialog() {
    bool ok = false;
    QString name = QInputDialog::getText(this, i18n::tr("create scene from template"),
                                         i18n::tr("scene name"), QLineEdit::Normal, {}, &ok);
    if (!ok || name.isEmpty()) return;
    if (!scene_name_valid(name)) {
        notify::notify(notify::Kind::ERROR_, i18n::tr("invalid name"));
        return;
    }
    if (scene_name_taken(name, roots_)) {
        notify::notify(notify::Kind::ERROR_, i18n::tr("name already exists"));
        return;
    }
    const QString dir = QString("%1/%2").arg(scene::USER_SCENES_DIR).arg(name);
    const QString path = dir + "/" + name + ".slang";
    if (QFile::exists(path)) { // open(WriteOnly) would truncate the user's scene
        notify::notify(notify::Kind::ERROR_, i18n::tr("name already exists"));
        return;
    }
    const bool dir_ok = QDir().mkpath(dir);
    QFile f(path);
    if (!dir_ok || !f.open(QIODevice::WriteOnly | QIODevice::Text) ||
        f.write("// New 2D graphics scene.\nimport \"../../src/shaders/common\";\n") < 0) {
        notify::notify(notify::Kind::ERROR_, QString("scene create failed: %1").arg(dir));
        return;
    }
    notify::notify(notify::Kind::INFO, i18n::tr("created %s").replace("%s", name));
    refresh_scenes();
}

// The FILES-panel combo's scene model: groups trails, built-ins and user
// scenes. The strip no longer owns a selector (no title bar); the menu
// lives on the FILES panel's selector button.
void Shell::rebuild_selector_menu() {
    if (!selector_menu_) return;
    selector_menu_->clear();
    for (QString trail : trail_names()) {
        if (trail == "index") continue;
        QAction* caption = selector_menu_->addAction(trail);
        caption->setEnabled(true);
        connect(caption, &QAction::triggered, this, [this, trail] {
            ui.mode = Sidebar_Mode::LEARN;
            ui.panel_open = true;
            apply_mode(ui.mode); // builds/raises trail_view_
            if (trail_view_) trail_view_->load(trail);
        });
    }
    bool user_done = false, builtin_done = false;
    for (size_t i = 0; i < mgr_.scenes.size(); ++i) {
        const auto& s = mgr_.scenes[i];
        QString title = QString::fromStdString(s.title);
        bool is_user = s.user_owned;
        if (is_user && !user_done) {
            selector_menu_->addSeparator();
            QAction* caption = selector_menu_->addAction(i18n::tr("user scenes"));
            caption->setEnabled(false);
            user_done = true;
        } else if (!is_user && !builtin_done) {
            QAction* caption = selector_menu_->addAction(i18n::tr("scenes"));
            caption->setEnabled(false);
            builtin_done = true;
        }
        QAction* action = selector_menu_->addAction(title);
        action->setCheckable(true);
        action->setChecked(int(i) == mgr_.current);
        connect(action, &QAction::triggered, this, [this, i] {
            emit scene_selected(int(i));
        });
    }
    if (selector_btn_) {
        selector_btn_->setText(mgr_.scenes.empty()
                                   ? "?"
                                   : QString::fromStdString(mgr_.scenes[size_t(mgr_.current)].title));
    }
}

void Shell::refresh_scenes() {
    rebuild_selector_menu();
    sync_scene_menu(); // native menubar Scene menu mirrors the selector
}

// Toggles the docked scene list; rebuilds its rows from the selector menu
// model (same grouping: trails, scenes, user scenes).
void Shell::show_scene_list(bool on) {
    if (!scene_list_) return;
    if (!on) {
        scene_list_->hide();
        return;
    }
    if (!selector_menu_) selector_menu_ = new QMenu(selector_btn_);
    rebuild_selector_menu();
    // QListWidget, not per-row QPushButtons: checkable buttons under
    // QlementineStyle cache the hover/checked look (the same style-cache
    // bug the mode strip had) — rows STAY highlighted after the mouse
    // leaves, "marking several". Item-based hover is single by design.
    if (!scene_list_widget_) {
        scene_list_widget_ = new QListWidget(scene_list_);
        scene_list_widget_->setFrameShape(QFrame::NoFrame);
        scene_list_widget_->setStyleSheet(scene_list_items_qss());
        connect(scene_list_widget_, &QListWidget::itemClicked, this,
                [this](QListWidgetItem* item) {
            QAction* action = item->data(Qt::UserRole).value<QAction*>();
            show_scene_list(false);
            if (action && action->isEnabled()) action->trigger();
        });
        scene_list_layout_->addWidget(scene_list_widget_);
        scene_list_layout_->addStretch(1); // once: re-adding on every open grew the layout
    }
    scene_list_widget_->clear();
    for (QAction* action : selector_menu_->actions()) {
        if (action->isSeparator()) continue;
        auto* item = new QListWidgetItem(action->text(), scene_list_widget_);
        item->setData(Qt::UserRole, QVariant::fromValue(action));
        if (!action->isEnabled()) { // section caption (trails/user/builtin)
            item->setFlags(Qt::NoItemFlags);
            item->setForeground(QColor(theme::text_muted()));
        } else if (action->isChecked()) { // the active scene
            item->setForeground(QColor(theme::safelight()));
        }
    }
    scene_list_->setFixedHeight(std::min(
        420, int(scene_list_->sizeHint().height())));
    // Overlay geometry: right-aligned under the selector button, above
    // everything. Plan 07 P2 fix: scene_list_ is a Qt::ToolTip TOP-LEVEL
    // window (floats over the native SDL child), so setGeometry takes
    // GLOBAL screen coords — the old local (width()-280, kTopbarH) put it
    // behind the macOS menu bar whenever the window wasn't at (0,0),
    // which read as "the selector does nothing".
    const QPoint list_global =
        mapToGlobal(QPoint(width() - 280, kTopbarH));
    scene_list_->setGeometry(list_global.x(), list_global.y(), 280,
                             scene_list_->height());
    scene_list_->raise();
    scene_list_->show();
}

// ---- Top bar (macOS style) ----

// OUR traffic lights (frameless window): close/minimize/zoom ride the left
// edge — the 80px reserve for the native lights is gone. Close routes
// through Shell::closeEvent (dirty-tab confirm); minimize and zoom go
// through the native window-state APIs.
void Shell::build_traffic_lights(QHBoxLayout* layout) {
    auto* lights = new QWidget(topbar_);
    lights->setObjectName("trafficLights");
    auto* lights_layout = new QHBoxLayout(lights);
    lights_layout->setContentsMargins(0, 0, 0, 0);
    lights_layout->setSpacing(8);
    const struct {
        const char* color;
        const char* tip;
        const char* acc;
    } lights_def[3] = {
        {"#ff5f57", "close window", "close window"},
        {"#febc2e", "minimize", "minimize"},
        {"#28c840", "zoom", "zoom"},
    };
    for (int i = 0; i < 3; ++i) {
        auto* light = new QPushButton(lights);
        light->setFixedSize(12, 12);
        light->setCursor(Qt::PointingHandCursor);
        light->setToolTip(i18n::tr(lights_def[i].tip));
        light->setAccessibleName(i18n::tr(lights_def[i].acc));
        light->setFocusPolicy(Qt::NoFocus);
        light->setStyleSheet(
            QString("QPushButton { background: %1; border: 1px solid"
                    " rgba(0,0,0,0.22); border-radius: 6px; }"
                    "QPushButton[hovered=\"true\"] { border: 1px solid rgba(0,0,0,0.36); }")
                .arg(lights_def[i].color));
        switch (i) {
        case 0:
            connect(light, &QPushButton::clicked, this, &Shell::close);
            break;
        case 1:
            connect(light, &QPushButton::clicked, this,
                    [this] { windowHandle() ? windowHandle()->showMinimized()
                                            : (void)0; });
            break;
        case 2:
            connect(light, &QPushButton::clicked, this, [this] {
                if (isMaximized())
                    showNormal();
                else
                    showMaximized();
            });
            break;
        }
        lights_layout->addWidget(light);
    }
    layout->addWidget(lights);
    layout->addSpacing(10);
}

// Preview mode segmented control: FLOAT | SPLIT | FULL. One state, three
// doors: topbar buttons, F3 cycle, drag-drop snap all land here.
void Shell::build_preview_segment(QHBoxLayout* layout) {
    const Preview_Mode p_modes[3] = {Preview_Mode::FLOAT, Preview_Mode::SPLIT,
                                     Preview_Mode::FULL};
    // plan10 tooltips: verb + destination, no "preview:" prefix noise —
    // the segmented control IS the preview control.
    const char* p_tips[3] = {"float the preview", "dock preview: split",
                             "dock preview: full"};
    for (int i = 0; i < 3; ++i) {
        auto* btn = new QPushButton(topbar_);
        btn->setIcon(tinted_icon(kPreviewIcons[i], icon_tint(), kToolbarIcon));
        btn->setIconSize(QSize(kToolbarIcon, kToolbarIcon));
        // Fused segmented look: adjacent, shared hover; fits the 28px bar.
        btn->setFixedSize(kToolbarBtn + 4, kToolbarBtn);
        btn->setToolTip(i18n::tr(p_tips[i]));
        btn->setAccessibleName(i18n::tr(p_tips[i]));
        btn->setFocusPolicy(Qt::TabFocus);
        btn->setProperty("active", ui.preview == p_modes[i]);
        connect(btn, &QPushButton::clicked, this,
                [this, mode = p_modes[i]] { set_preview_mode(mode); });
        preview_btns_[i] = btn;
        layout->addWidget(btn, 0, Qt::AlignVCenter);
    }
}

// Save + pause: window-level actions in the chrome (the strip keeps only
// mode navigation + settings). Cmd+S lives in the native File menu
// (menubar.cpp) — no in-window QShortcut, or the key would fire twice.
void Shell::build_save_pause(QHBoxLayout* layout) {
    layout->addSpacing(8);
    save_btn_ = new QPushButton(topbar_);
    save_btn_->setIcon(tinted_icon(kSaveIcon, icon_tint(), kToolbarIcon));
    save_btn_->setIconSize(QSize(kToolbarIcon, kToolbarIcon));
    save_btn_->setFixedSize(kToolbarBtn, kToolbarBtn);
    save_btn_->setToolTip(i18n::tr("save all (Cmd+S)"));
    save_btn_->setAccessibleName(i18n::tr("save all (Cmd+S)"));
    save_btn_->setFocusPolicy(Qt::TabFocus);
    connect(save_btn_, &QPushButton::clicked, this, [this] {
        save_all(); // writes dirty tabs; then host rebuilds the scene
        emit save_all_requested();
    });
    layout->addWidget(save_btn_);

    pause_btn_ = new QPushButton(topbar_);
    pause_btn_->setIcon(tinted_icon(":/qlementine/icons/24/media/pause.svg",
                                    icon_tint(), kToolbarIcon));
    pause_btn_->setIconSize(QSize(kToolbarIcon, kToolbarIcon));
    pause_btn_->setFixedSize(kToolbarBtn, kToolbarBtn);
    pause_btn_->setToolTip(i18n::tr("pause"));
    pause_btn_->setAccessibleName(i18n::tr("pause"));
    pause_btn_->setFocusPolicy(Qt::TabFocus);
    connect(pause_btn_, &QPushButton::clicked, this, [this] {
        ui.paused = !ui.paused; // the host polls ui.paused each tick
        pause_btn_->setIcon(tinted_icon(
            ui.paused ? ":/qlementine/icons/24/media/play.svg"
                      : ":/qlementine/icons/24/media/pause.svg",
            icon_tint(), kToolbarIcon));
        pause_btn_->setToolTip(ui.paused ? i18n::tr("play") : i18n::tr("pause"));
        pause_btn_->setAccessibleName(ui.paused ? i18n::tr("play")
                                                 : i18n::tr("pause"));
    });
    layout->addWidget(pause_btn_);
}

QWidget* Shell::topbar() {
    if (topbar_) return topbar_;
    topbar_ = new QWidget(this);
    topbar_->setObjectName("topbar"); // test + a11y discovery anchor
    topbar_->setFixedHeight(kTopbarH);
    topbar_->setStyleSheet(topbar_qss());
    auto* layout = new QHBoxLayout(topbar_);
    // OUR traffic lights (frameless window): close/minimize/zoom ride the
    // left edge — the 80px reserve for the native lights is gone.
    // Close routes through Shell::closeEvent (dirty-tab confirm); minimize
    // and zoom go through the native window-state APIs.
    layout->setContentsMargins(12, 0, 12, 0);
    layout->setSpacing(8);
    build_traffic_lights(layout);

    // ---- GROUP: project (scene selector + new scene) ----
    // Selector: scene list popup; the button IS the current scene's name.
    // Plan 07 P2 (user direction): no icon — the title in a larger mono
    // voice with the safelight accent carries it (colorize: the amber marks
    // the one primary control of the bar).
    selector_btn_ = new QPushButton(topbar_);
    selector_btn_->setObjectName("sceneSelector");
    selector_btn_->setMinimumHeight(kToolbarBtn + 4);
    selector_btn_->setMaximumHeight(kToolbarBtn + 4);
    selector_btn_->setCursor(Qt::PointingHandCursor);
    selector_btn_->setToolTip(i18n::tr("scenes"));
    selector_btn_->setAccessibleName(i18n::tr("scenes"));
    // Initial title: the ctor's refresh_scenes ran before this widget
    // existed; the host's scene_switched → refresh_scenes keeps it current.
    if (!mgr_.scenes.empty())
        selector_btn_->setText(
            QString::fromStdString(mgr_.scenes[size_t(mgr_.current)].title));
    selector_btn_->setStyleSheet(
        QString("QPushButton#sceneSelector { background: transparent;"
                " border: 1px solid %1; border-radius: 6px; padding: 2px 14px;"
                " color: %2; font-family: 'JetBrains Mono', monospace;"
                " font-size: 11pt; font-weight: 600; }"
                "QPushButton#sceneSelector[hovered=\"true\"] {"
                " background: %3; border-color: %4; }"
                "QPushButton#sceneSelector:pressed { background: %5;"
                " border-color: %4; }"
                "QPushButton#sceneSelector:focus { border-color: %4; }")
            .arg(theme::control_border(), theme::safelight(),
                 theme::hover_overlay(), theme::safelight(),
                 theme::pressed_overlay()));
    connect(selector_btn_, &QPushButton::clicked, this, [this] {
        // Inline scene list docked UNDER the top bar: native QMenu/Qt::Popup
        // windows lose the mouse to the frameless-window coordinate drift
        // and to the SDL child racing (both proven in this build); an
        // in-layout panel uses the exact widget pipeline the top bar and
        // strip already use, which works. show_scene_list rebuilds the
        // model on open.
        show_scene_list(!scene_list_ || !scene_list_->isVisible());
    });
    layout->addWidget(selector_btn_);

    new_btn_ = new QPushButton(i18n::tr("+ new"), topbar_);
    new_btn_->setIcon(tinted_icon(kNewIcon, icon_tint(), kToolbarIcon));
    new_btn_->setIconSize(QSize(kToolbarIcon, kToolbarIcon));
    new_btn_->setToolTip(i18n::tr("new scene"));
    new_btn_->setAccessibleName(i18n::tr("new scene"));
    new_btn_->setFocusPolicy(Qt::TabFocus);
    connect(new_btn_, &QPushButton::clicked, this, &Shell::create_scene_dialog);
    layout->addWidget(new_btn_);

    // ---- GROUP divider: project | shader workflow ----
    auto* divider_1 = new QFrame(topbar_);
    divider_1->setFrameShape(QFrame::VLine);
    divider_1->setFixedHeight(16);
    divider_1->setStyleSheet(
        QString("QFrame { color: %1; }").arg(theme::control_border()));
    layout->addSpacing(6);
    layout->addWidget(divider_1);
    layout->addSpacing(6);

    build_preview_segment(layout);

    build_save_pause(layout);

    layout->addStretch(1); // window drag area: everything right of the group
    return topbar_;
}

QWidget* Shell::strip() {
    if (strip_) return strip_;
    strip_ = new QWidget(this);
    strip_->setFixedWidth(kStripW);
    // NOT checkable + dynamic property: mixing QlementineStyle (app style)
    // with :checked stylesheet states left a permanent whitish wash on
    // clicked buttons (the style cached the checked look; setChecked(false)
    // from apply_mode didn't clear it). The active look is driven by the
    // "active" property, repolished on every apply_mode.
    strip_->setStyleSheet(strip_qss());
    auto* layout = new QVBoxLayout(strip_);
    layout->setContentsMargins(0, kStripTop, 0, kStripTop);
    layout->setSpacing(kStripStep - kStripButton);
    layout->setAlignment(Qt::AlignTop | Qt::AlignHCenter);

    // Strip mode buttons: 1 files, 2 graph, 3 controls (scene params),
    // 4 export, 5 commands. Settings stays the separate gear popup.
    // LEARN and EFFECTS are gone (fx removed per the layout contract).
    const Sidebar_Mode modes[5] = {
        Sidebar_Mode::FILES, Sidebar_Mode::GRAPH,     Sidebar_Mode::CONTROLS,
        Sidebar_Mode::EXPORT, Sidebar_Mode::SHORTCUTS,
    };
    // Plan 07 P2: REST/SELECTED icon pairs. apply_mode swaps to the
    // selected glyph when the mode is the active one and back otherwise —
    // the old code only restyled via QSS [active] and never reset icons,
    // so the folder-open glyph stuck after switching away.
    //   FILES    → file/folder.svg        ↔ file/folder-open.svg
    //   GRAPH    → file/vector.svg (16px: the "vector" render-graph glyph)
    //   CONTROLS → navigation/sliders-horizontal.svg (same)
    //   EXPORT   → action/download.svg (same)
    //   SHORTCUTS→ hardware/keyboard.svg (same)
    const char* icons[5] = {
        ":/qlementine/icons/24/file/folder.svg",
        ":/qlementine/icons/16/file/vector.svg",
        ":/qlementine/icons/24/navigation/sliders-horizontal.svg",
        ":/qlementine/icons/24/action/download.svg",
        ":/qlementine/icons/24/hardware/keyboard.svg",
    };
    const char* icons_active[5] = {
        ":/qlementine/icons/24/file/folder-open.svg",
        ":/qlementine/icons/16/file/vector.svg",
        ":/qlementine/icons/24/navigation/sliders-horizontal.svg",
        ":/qlementine/icons/24/action/download.svg",
        ":/qlementine/icons/24/hardware/keyboard.svg",
    };
    for (int i = 0; i < 5; ++i) {
        auto* btn = new QPushButton(strip_);
        btn->setIcon(tinted_icon(icons[i], icon_tint(), kStripIcon));
        btn->setIconSize(QSize(kStripIcon, kStripIcon));
        btn->setFixedSize(kStripButton, kStripButton);
        btn->setToolTip(mode_name(modes[i]));
        btn->setAccessibleName(mode_name(modes[i]));
        btn->setFocusPolicy(Qt::TabFocus);
        // Icon pair lives on the button properties; apply_mode swaps them.
        btn->setProperty("icon_rest", icons[i]);
        btn->setProperty("icon_active", icons_active[i]);
        btn->setProperty("mode", int(modes[i])); // enum order ≠ strip order
        connect(btn, &QPushButton::clicked, this, [this, mode = modes[i]] {
            // Re-clicking the active button does NOT collapse: collapse is
            // the panel edge chevron's job (recognition over recall — a
            // double click by habit must never hide the panel).
            if (ui.mode != mode) ui.mode = mode;
            ui.panel_open = true;
            apply_mode(ui.mode);
        });
        strip_buttons_.push_back(btn);
        layout->addWidget(btn, 0, Qt::AlignHCenter);
    }
    layout->addStretch(1);
    // Settings: the gear's popup, promoted to the strip (3rd slot visually
    // grouped after graph/export; bottom keeps it a tool, not a mode).
    gear_btn_ = new QPushButton(strip_);
    gear_btn_->setIcon(tinted_icon(
        ":/qlementine/icons/24/navigation/settings.svg", icon_tint(), kStripIcon));
    gear_btn_->setIconSize(QSize(kStripIcon, kStripIcon));
    gear_btn_->setFixedSize(kStripButton, kStripButton);
    // Tooltip dinâmica (W4): o gear anuncia o estado ativo — tema, fonte,
    // idioma — em uma linha. Atualizada ao abrir o settings.
    gear_btn_->setToolTip(i18n::tr("settings"));
    gear_btn_->setAccessibleName(i18n::tr("settings"));
    gear_btn_->setFocusPolicy(Qt::TabFocus);
    layout->setAlignment(gear_btn_, Qt::AlignHCenter);
    connect(gear_btn_, &QPushButton::clicked, this, &Shell::open_settings_menu);
    layout->addWidget(gear_btn_);
    return strip_;
}

QScrollArea* Shell::panel() {
    if (panel_) return panel_;
    panel_ = new QScrollArea(this);
    panel_->setWidgetResizable(true);
    panel_->setFrameShape(QFrame::NoFrame);
    panel_->setStyleSheet(panel_qss());
    // Persistent panel: one QStackedWidget with a page per sidebar mode.
    // Pages are built ONCE and kept alive — mode switches only change the
    // visible index, so tree expand state, selection and scroll survive
    // (the old clear-and-rebuild destroyed all of it on 22 call sites).
    panel_stack_ = new QStackedWidget();
    panel_stack_->setContentsMargins(0, 0, 0, 0);
    auto* holder = new QWidget();
    auto* holder_layout = new QVBoxLayout(holder);
    holder_layout->setContentsMargins(12, 10, 12, 10);
    holder_layout->setSpacing(6);
    holder_layout->addWidget(panel_stack_);
    panel_->setWidget(holder);

    // Collapse affordance: a chevron rides the panel's LEFT edge. Hover
    // turns the edge amber (the drag affordance now has a visible face);
    // click toggles the panel (same spring as the strip's active mode).
    // Parent = Shell, NOT the QScrollArea: the scroll viewport is a sibling
    // that covers panel children, so a panel-child chevron never paints.
    panel_edge_ = new QPushButton(this);
    panel_edge_->setObjectName("panelEdge");
    panel_edge_->setToolTip(i18n::tr("toggle panel"));
    panel_edge_->setAccessibleName(i18n::tr("toggle panel"));
    panel_edge_->setFocusPolicy(Qt::NoFocus);
    panel_edge_->setFixedSize(12, 56);
    // Resting state VISIBLE (a hover-only affordance is no affordance):
    // dim amber pill, brightening on hover.
    panel_edge_->setStyleSheet(panel_edge_qss());
    connect(panel_edge_, &QPushButton::clicked, this, [this] {
        ui.panel_open = !ui.panel_open;
        apply_mode(ui.mode);
    });
    update_panel_edge();
    return panel_;
}

void Shell::update_panel_edge() {
    update_graph_cover();
    if (!panel_ || !panel_edge_) return;
    if (!panel_->isVisible() || panel_->width() <= 1 || ui.mode == Sidebar_Mode::GRAPH) {
        panel_edge_->hide();
        return;
    }
    panel_edge_->setText(ui.panel_open ? "‹" : "›");
    const QPoint edge = panel_->mapTo(this, QPoint(0, 0)) -
                        QPoint(panel_edge_->width() / 2, 0);
    panel_edge_->setGeometry(edge.x(), panel_->mapTo(this, QPoint(0, 0)).y() +
                             (panel_->height() - panel_edge_->height()) / 2,
                             panel_edge_->width(), panel_edge_->height());
    panel_edge_->show();
    panel_edge_->raise();
}

void Shell::update_graph_cover() {
    if (!central_) return;
    central_->setVisible(!(ui.mode == Sidebar_Mode::GRAPH && ui.graph_fullscreen && ui.panel_open));
}

static QLabel* caption(const QString& text) {
    auto* label = new QLabel(text);
    label->setProperty("caption", true);
    return label;
}

// Darkroom color row: a swatch button (the color IS the button), the hex
// value beside it, and a QColorDialog on click. Edits write through to the
// widget triple; hex display follows the swatch.
static QWidget* make_color_row(scene::Runtime_Scene* scene,
                               const scene::Uniform_Widget& widget) {
    auto* row = new QWidget();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(8);
    auto* name = new QLabel(QString::fromStdString(widget.label));
    layout->addWidget(name);
    QColor color(int(widget.value[0] * 255 + 0.5f), int(widget.value[1] * 255 + 0.5f),
                 int(widget.value[2] * 255 + 0.5f));

    auto* swatch = new QPushButton(row);
    swatch->setFixedSize(44, 22);
    swatch->setCursor(Qt::PointingHandCursor);
    auto paint_swatch = [swatch](const QColor& c) {
        swatch->setStyleSheet(
            QString("QPushButton { background: %1; border: 1px solid rgba(255,255,255,0.14);"
                    " border-radius: 4px; }"
                    "QPushButton:hover { border: 1px solid rgba(255,255,255,0.32); }")
                .arg(c.name()));
    };
    paint_swatch(color);

    // plan8: the hex value is EDITABLE (type #RRGGBB, Enter applies) —
    // the swatch stays the dialog affordance, the field is the precision path.
    auto* hex = new QLineEdit(color.name().toUpper().mid(1), row); // no '#'
    hex->setStyleSheet(QString("color: %1; font-family: 'JetBrains Mono', monospace;"
                               " background: transparent; border: none;")
                           .arg(theme::text_muted()));
    hex->setFixedWidth(56);
    hex->setCursorPosition(0);

    auto write_through = [scene, label = widget.label](const QColor& picked) {
        // Resolve the widget at fire time: the panel can outlive a
        // hot-reload scene swap that rebuilt scene.widgets.
        for (auto& wgt : scene->widgets)
            if (wgt.label == label) {
                wgt.value[0] = picked.redF();
                wgt.value[1] = picked.greenF();
                wgt.value[2] = picked.blueF();
                break;
            }
    };
    auto open_picker = [label = widget.label, swatch, hex, paint_swatch,
                        write_through, color]() {
        QColor picked = QColorDialog::getColor(color, swatch, QObject::tr("pick color"));
        if (!picked.isValid()) return;
        write_through(picked);
        paint_swatch(picked);
        hex->setText(picked.name().toUpper().mid(1));
    };
    QObject::connect(swatch, &QPushButton::clicked, swatch, open_picker);
    // Typed hex: accept "#RRGGBB" or "RRGGBB"; invalid keeps the old value.
    QObject::connect(hex, &QLineEdit::returnPressed, hex, [hex,
                                                           paint_swatch, write_through]() {
        QColor parsed(QString("#") + hex->text().remove('#'));
        if (!parsed.isValid()) {
            notify::notify(notify::Kind::WARN, "hex: use RRGGBB");
            return;
        }
        write_through(parsed);
        paint_swatch(parsed);
        hex->setText(parsed.name().toUpper().mid(1));
    });

    layout->addWidget(swatch);
    layout->addWidget(hex);
    layout->addStretch(1);
    return row;
}

// plan8: slider (continuous feel) + field (exact value), sharing one model —
// "fields, sliders, or combinations based on their actual interaction
// requirements".
static QLayout* make_slider_row(scene::Runtime_Scene* scene,
                                const scene::Uniform_Widget& widget,
                                QWidget* parent) {
    const QString label = QString::fromStdString(widget.label);
    auto* slider = new QSlider(Qt::Horizontal, parent);
    const float span = qMax(widget.max - widget.min, 0.001f);
    const int steps = qMax(1, int(span / qMax(widget.step, span / 100.0f)));
    slider->setRange(0, steps);
    slider->setValue(int((widget.value[0] - widget.min) / span * steps + 0.5f));
    auto* spin = new QDoubleSpinBox(parent);
    spin->setRange(widget.min, widget.max);
    spin->setSingleStep(widget.step);
    spin->setDecimals(2);
    spin->setValue(widget.value[0]);
    spin->setButtonSymbols(QAbstractSpinBox::NoButtons);
    spin->setFixedWidth(64);
    auto apply_value = [scene, label](double v) {
        // Resolve the widget at fire time: the panel can outlive a
        // hot-reload scene swap that rebuilt scene.widgets (captured refs
        // would dangle).
        for (auto& wgt : scene->widgets)
            if (wgt.label == label.toStdString()) { wgt.value[0] = float(v); break; }
    };
    QObject::connect(spin, &QDoubleSpinBox::valueChanged, spin, apply_value);
    QObject::connect(spin, &QDoubleSpinBox::valueChanged, slider,
                     [slider, widget, span, steps](double v) {
                         slider->blockSignals(true); // field -> slider only
                         slider->setValue(int((v - widget.min) / span * steps + 0.5f));
                         slider->blockSignals(false);
                     });
    QObject::connect(slider, &QSlider::valueChanged, slider,
                     [spin, widget, span, steps, apply_value](int pos) {
                         const double v = widget.min + span * double(pos) / steps;
                         spin->blockSignals(true); // slider -> field only
                         spin->setValue(v);
                         spin->blockSignals(false);
                         apply_value(v);
                     });
    auto* row = new QHBoxLayout();
    row->addWidget(new QLabel(label), 0);
    row->addWidget(slider, 1);
    row->addWidget(spin, 0);
    return row;
}

static QWidget* make_toggle_row(scene::Runtime_Scene* scene,
                                const scene::Uniform_Widget& widget,
                                QWidget* parent) {
    const QString label = QString::fromStdString(widget.label);
    auto* check = new QCheckBox(label, parent);
    check->setChecked(widget.on);
    QObject::connect(check, &QCheckBox::toggled, check, [scene, label](bool on) {
        for (auto& wgt : scene->widgets)
            if (wgt.label == label.toStdString()) { wgt.on = on; break; }
    });
    return check;
}

QWidget* Shell::controls_panel() {
    auto* w = new QWidget();
    auto* layout = new QVBoxLayout(w);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);
    // Rows pack at the top; a single trailing stretch fills the rest. The
    // old per-row stretch=1 spread the few widgets across the whole panel.
    layout->addWidget(caption(i18n::tr("controls")), 0);

    if (!mgr_.scenes.empty()) {
        auto* scene = &mgr_.scenes[size_t(mgr_.current)];
        // Reflected widgets ([UiSlider]/[UiToggle]/[UiColor]), grouped per
        // declaring module file; the row label is the shader variable name.
        std::string shown_module;
        for (auto& widget : scene->widgets) {
            if (widget.node) continue; // rendered as its own graph node
            // Group header per source file: "noises" or "noises · pass_1".
            if (widget.module != shown_module) {
                shown_module = widget.module;
                QString file = QString::fromStdString(shown_module);
                file.replace(QString::fromStdString(scene->title + "__"), "");
                layout->addWidget(caption(file), 0);
            }
            switch (widget.kind) {
            case scene::Uniform_Widget::Kind::SLIDER:
                layout->addLayout(make_slider_row(scene, widget, w));
                break;
            case scene::Uniform_Widget::Kind::TOGGLE:
                layout->addWidget(make_toggle_row(scene, widget, w));
                break;
            case scene::Uniform_Widget::Kind::COLOR:
                // Swatch + hex row (the darkroom picker): the swatch IS the
                // button, the hex value sits right of it; clicking the swatch
                // opens the color dialog. No three spinboxes.
                layout->addWidget(make_color_row(scene, widget));
                break;
            }
        }
    }

    layout->addWidget(caption(i18n::tr("interaction")), 0);
    for (int m = 0; m < 2; ++m) {
        QString label =
            m == 0 ? i18n::tr("autorotate") : i18n::tr("mouse rotation");
        auto* radio = new QRadioButton(label, w);
        radio->setChecked(ui.interaction == Interaction_Mode(m));
        connect(radio, &QRadioButton::toggled, this,
                [this, m](bool on) { if (on) ui.interaction = Interaction_Mode(m); });
        layout->addWidget(radio, 0);
    }
    // Camera reset + hint: the host owns camera state; this only requests.
    auto* cam_reset = new QPushButton(i18n::tr("reset camera"), w);
    connect(cam_reset, &QPushButton::clicked, this,
            [this] { emit camera_reset_requested(); });
    layout->addWidget(cam_reset, 0);
    layout->addWidget(
        caption(i18n::tr("drag orbit · wheel zoom · tab flycam · R reset")), 0);
    layout->addStretch(1);
    return w;
}

QWidget* Shell::editor_dock() {
    if (editor_dock_) return editor_dock_;
    editor_dock_ = new QWidget(this); // owned by Shell; files panel borrows it
    auto* layout = new QVBoxLayout(editor_dock_);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    // Bake error bar (P1-N2): the last bake failure lives HERE, on the
    // editor, where the eye already is — not only in the GRAPH panel. Hidden
    // when the last bake succeeded; scene_switched/set_baking update it.
    pipeline_error_bar_ = new QLabel(editor_dock_);
    pipeline_error_bar_->setObjectName("pipelineErrorBar");
    pipeline_error_bar_->setStyleSheet(
        QString("QLabel#pipelineErrorBar { background: rgba(242,107,92,0.16);"
                " color: %1; padding: 4px 12px; font-size: 9pt; }")
            .arg(theme::error()));
    pipeline_error_bar_->setWordWrap(true);
    pipeline_error_bar_->hide();
    layout->addWidget(pipeline_error_bar_);
    editor_ = new editor::Editor(editor_dock_);
    editor_->set_theme(ui.theme); // persisted prefs decide the first skin
    editor_->set_editor_font(int(ui.editor_font)); // prefs persist the size
    editor_->set_pixel_font(ui.editor_pixel_font); // prefs persist the face
    connect(editor_, &editor::Editor::font_changed, this, [this](int pt) {
        ui.editor_font = pt; // Cmd+= / Cmd+- update the persisted size
        persist_prefs();
    });
    // Split (code | preview): the floating editor button flips SPLIT <->
    // FLOAT in the shell's single preview state; the host reshapes the SDL
    // preview window each tick from ui.preview.
    connect(editor_, &editor::Editor::split_toggled, this, [this](bool on) {
        ui.editor_split = on; // kept for prefs symmetry
        set_preview_mode(on ? Preview_Mode::SPLIT : Preview_Mode::FLOAT);
    });
    if (!mgr_.scenes.empty()) {
        const auto& scene = mgr_.scenes[size_t(mgr_.current)];
        editor_->load_unit(QString::fromStdString(scene.title),
                           scene::scene_root_dir(roots_, scene.title).c_str());
    }
    // Mirror the persisted preview mode into the editor's split button
    // (its floating toggle reads split_on_ to pick its corner). split_
    // current() toggles; only call when the persisted state says SPLIT.
    if (ui.preview == Preview_Mode::SPLIT && !editor_->split_on())
        editor_->split_current(); // emits split_toggled -> maps back to SPLIT (no-op)
    // Cmd+= / Cmd+-: font zoom in the code editor (works with any tab up).
    auto* zoom_in_sc = new QShortcut(QKeySequence::ZoomIn, editor_dock_);
    zoom_in_sc->setContext(Qt::WidgetWithChildrenShortcut);
    connect(zoom_in_sc, &QShortcut::activated, editor_, &editor::Editor::zoom_in);
    auto* zoom_out_sc = new QShortcut(QKeySequence::ZoomOut, editor_dock_);
    zoom_out_sc->setContext(Qt::WidgetWithChildrenShortcut);
    connect(zoom_out_sc, &QShortcut::activated, editor_, &editor::Editor::zoom_out);
    layout->addWidget(editor_, 1);
    editor_dock_->show();
    return editor_dock_;
}

// File-tree leaf kinds (stored in Qt::UserRole + 1).
enum Tree_Kind { kShader, kGraph, kAsset };

static QIcon file_icon_for(const QString& path) {
    const QString suffix = QFileInfo(path).suffix().toLower();
    const char* res = ":/qlementine/icons/16/file/file.svg";
    if (suffix == "slang") res = ":/qlementine/icons/16/file/file-script.svg";
    else if (suffix == "json") res = ":/qlementine/icons/16/file/markup.svg";
    else if (suffix == "png" || suffix == "jpg" || suffix == "jpeg")
        res = ":/qlementine/icons/16/file/picture.svg";
    else if (suffix == "glb" || suffix == "gltf" || suffix == "obj")
        res = ":/qlementine/icons/16/shape/cube.svg";
    return tinted_icon(res, QColor(theme::text_muted()), 14);
}

// Refill the persistent files tree: called on first build and every scene
// switch. Keeps the QTreeWidget alive (expand state of groups the refill
// re-sets intentionally; per-item selection resets — acceptable, the scene
// changed).
void Shell::refresh_files_tree() {
    if (!files_tree_) return;
    files_tree_->clear();
    QString active =
        mgr_.scenes.empty() ? QString() : QString::fromStdString(mgr_.scenes[size_t(mgr_.current)].title);
    // W1: group headers — uppercase, letter-spaced, muted; visually anchor
    // the three sections in a narrow panel (F-shaped scan).
    auto add_group = [this](const QString& title) -> QTreeWidgetItem* {
        auto* item = new QTreeWidgetItem(files_tree_, QStringList{title.toUpper()});
        item->setFlags(Qt::ItemIsEnabled);
        QFont f = item->font(0);
        f.setPointSizeF(7.5);
        f.setLetterSpacing(QFont::AbsoluteSpacing, 1.0);
        item->setFont(0, f);
        item->setForeground(0, QColor(theme::text_muted()));
        return item;
    };
    auto add_leaf = [&](QTreeWidgetItem* parent, const QString& name,
                        const QString& rel, Tree_Kind kind) {
        auto* item = new QTreeWidgetItem(parent, QStringList{name});
        item->setData(0, Qt::UserRole, rel);
        item->setData(0, Qt::UserRole + 1, (int)kind);
        item->setIcon(0, file_icon_for(rel));
        if (kind == kAsset)
            item->setToolTip(0, i18n::tr("route it in the render graph"));
        return item;
    };

    if (!active.isEmpty()) {
        auto* unit = add_group(active);
        unit->setIcon(0, tinted_icon(":/qlementine/icons/16/file/folder-open.svg",
                                     QColor(theme::text_muted()), 14));
        // EVERY file in the scene dir: entry shader first, then modules,
        // graph.json, then extras (images, meshes) the scene ships with.
        QString root = QString::fromStdString(scene::scene_root_dir(roots_, active.toStdString()));
        QString prefix = root + "/" + active + "/";
        QStringList files;
        QDirIterator it(prefix, QDir::Files);
        while (it.hasNext()) files << it.next();
        files.sort();
        QString entry = prefix + active + ".slang";
        if (QFileInfo::exists(entry))
            add_leaf(unit, active, "scenes/" + active + "/" + active, kShader);
        for (const QString& f : files) {
            if (f == entry) continue;
            QFileInfo info(f);
            if (info.suffix() == "slang") {
                add_leaf(unit, info.completeBaseName(),
                         "scenes/" + active + "/" + info.completeBaseName(), kShader);
            } else if (info.fileName() == "graph.json") {
                auto* graph_item = add_leaf(unit, info.fileName(), f, kGraph);
                graph_item->setToolTip(0, i18n::tr("graph"));
            } else {
                add_leaf(unit, info.fileName(), f, kAsset);
            }
        }
        unit->setExpanded(true);
    }

    auto* shared = add_group(i18n::tr("shared"));
    shared->setIcon(0, tinted_icon(":/qlementine/icons/16/file/folder.svg",
                                   QColor(theme::text_muted()), 14));
    {
        QStringList slang;
        QDirIterator it("src/shaders", QStringList() << "*.slang", QDir::Files,
                        QDirIterator::Subdirectories);
        while (it.hasNext()) slang << it.next();
        slang.sort();
        for (const QString& f : slang) {
            QString rel = f;
            if (rel.startsWith("src/shaders/")) rel = rel.mid(QString("src/shaders/").size());
            if (rel.startsWith("scenes/") || rel.startsWith("gis_scenes/")) continue;
            add_leaf(shared, rel, rel, kShader);
        }
    }
    shared->setExpanded(true);

    auto* assets = add_group(i18n::tr("assets"));
    assets->setIcon(0, tinted_icon(":/qlementine/icons/16/file/folder.svg",
                                   QColor(theme::text_muted()), 14));
    {
        struct Group { const char* dir; const char* filter; };
        // QDir nameFilters do NOT split on spaces: one pattern per entry.
        const Group groups[] = {{"assets/models", "*.glb"},
                                {"assets/models", "*.gltf"},
                                {"assets/skybox", "*.png"},
                                {"assets/skybox", "*.jpg"},
                                {"assets", "*.jpg"},
                                {"assets", "*.png"}};
        QSet<QString> seen;
        for (const Group& g : groups) {
            QDirIterator it(g.dir, QStringList() << g.filter, QDir::Files);
            while (it.hasNext()) {
                QString f = it.next();
                if (seen.contains(f)) continue;
                seen.insert(f);
                auto* item = add_leaf(assets, QFileInfo(f).fileName(), f, kAsset);
                item->setForeground(0, QColor(theme::text_muted()));
            }
        }
    }
    assets->setExpanded(true);
}

// Click routing: shader leaves open in the editor; graph.json flips to the
// GRAPH mode; assets are route material for the graph.
void Shell::route_tree_click(QTreeWidgetItem* item) {
    const QString rel = item->data(0, Qt::UserRole).toString();
    const int kind = item->data(0, Qt::UserRole + 1).toInt();
    if (rel.isEmpty()) return;
    if (kind == kGraph) {
        show_mode(Sidebar_Mode::GRAPH);
        return;
    }
    if (kind == kShader) {
        editor_dock(); // lazy-create + load the scene unit
        editor_->load_named(rel);
        show_editor(true);
    }
    if (kind == kAsset) {
        // W3: an asset is route material — the render graph is where it
        // gets wired into the scene. No dead-end click.
        show_mode(Sidebar_Mode::GRAPH);
    }
}

// Rename (context menu on shader leaves of user-owned scenes). Builtin
// scenes live in the repo: renaming there is refused with a hint.
void Shell::show_tree_context_menu(const QPoint& pos) {
    QTreeWidget* tree = files_tree_;
    QTreeWidgetItem* item = tree->itemAt(pos);
    if (!item) return;
    int kind = item->data(0, Qt::UserRole + 1).toInt();
    if (kind != kShader) return; // folders, graph, assets: no rename
    QString rel = item->data(0, Qt::UserRole).toString();
    if (!rel.startsWith("scenes/")) return; // shared modules: repo-owned
    QString scene = rel.section('/', 1, 1);
    bool user_owned = scene::scene_root_dir(roots_, scene.toStdString()) == scene::USER_SCENES_DIR;

    QMenu menu(tree);
    QAction* rename_action = menu.addAction(i18n::tr("rename"));
    rename_action->setEnabled(user_owned);
    if (!user_owned)
        rename_action->setText(i18n::tr("built-in: edit in the repo"));
    QAction* picked = menu.exec(tree->mapToGlobal(pos));
    if (picked != rename_action || !user_owned) return;

    // Inline edit: make the item editable for the edit session only.
    item->setFlags(item->flags() | Qt::ItemIsEditable);
    tree->editItem(item, 0);
    // itemChanged (rename_shader_file) handles the disk rename; flags reset there.
}

// Commit: rename on disk, preserve extension, rescan everything.
void Shell::rename_shader_file(QTreeWidgetItem* item) {
    QTreeWidget* tree = files_tree_;
    // itemChanged fires for programmatic setText too (restore paths):
    // only treat it as a rename attempt when the label differs from the
    // stored rel's base name; restores land here as a no-op.
    int kind = item->data(0, Qt::UserRole + 1).toInt();
    QString rel = item->data(0, Qt::UserRole).toString();
    if (kind != kShader || !rel.startsWith("scenes/")) return;
    QString scene = rel.section('/', 1, 1);
    if (scene::scene_root_dir(roots_, scene.toStdString()) != scene::USER_SCENES_DIR) return;
    QString old_base = rel.section('/', -1);
    if (item->text(0) == old_base) return; // restore or unchanged edit

    QString new_name = item->text(0).trimmed();
    QString root_dir = QString::fromStdString(scene::scene_root_dir(roots_, scene.toStdString()));
    QString old_path = root_dir + "/" + scene + "/" + old_base + ".slang";
    QString new_base = new_name; // entry rename keeps the unit title
    QString new_path = root_dir + "/" + scene + "/" + new_base + ".slang";

    if (new_name.isEmpty() || new_base == old_base ||
        QFileInfo::exists(new_path) || new_name.contains('/')) {
        // Invalid or no-op: restore the label, keep the file.
        item->setText(0, old_base);
        item->setFlags(item->flags() & ~Qt::ItemIsEditable);
        return;
    }
    if (!QFile::rename(old_path, new_path)) {
        notify::notify(notify::Kind::ERROR_,
                       i18n::tr("rename failed: fix manually: %s, %s")
                           .replace("%s", old_path).replace("%s", new_path));
        item->setText(0, old_base);
        item->setFlags(item->flags() & ~Qt::ItemIsEditable);
        return;
    }
    item->setFlags(item->flags() & ~Qt::ItemIsEditable);
    // Only the FILE is renamed; the scene keeps its title. Reflect the
    // new module name in the label and rel.
    const QString new_rel = "scenes/" + scene + "/" + new_base;
    item->setText(0, new_base);
    item->setData(0, Qt::UserRole, new_rel);
    if (editor_) editor_->rescan();
    // O3: flash the renamed row amber, then fade back to muted —
    // confirms WHERE the change landed (the toast only says THAT).
    item->setForeground(0, QColor(0xE8, 0xA8, 0x57));
    // A scene switch refills the tree within the 1.2 s window, deleting the
    // item: re-resolve it by rel path at fire time instead of holding it.
    QTimer::singleShot(1200, tree, [tree, new_rel] {
        for (QTreeWidgetItemIterator it(tree); *it; ++it) {
            if ((*it)->data(0, Qt::UserRole).toString() == new_rel) {
                (*it)->setForeground(0, QColor(theme::text_primary()));
                break;
            }
        }
    });
    notify::notify(notify::Kind::INFO,
                   i18n::tr("renamed %s → %s")
                       .replace("%s", old_base).replace("%s", new_base));
}

QWidget* Shell::files_panel() {
    // Persistent page: the tree is built once and REFILLED on scene switch
    // (refresh_files_tree). Expand state of untouched groups survives.
    if (files_tree_) return files_panel_page_;
    auto* w = new QWidget();
    files_panel_page_ = w;
    auto* layout = new QVBoxLayout(w);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(4);

    // The persistent explorer tree: built once here, refilled by
    // refresh_files_tree() on scene switch.
    files_tree_ = new QTreeWidget(w);
    auto* tree = files_tree_;
    tree->setHeaderHidden(true);
    tree->setRootIsDecorated(true);
    tree->setIndentation(14);
    tree->setContextMenuPolicy(Qt::CustomContextMenu);
    tree->setStyleSheet(
        QString("QTreeWidget { background: transparent; border: none;"
                " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
                "QTreeWidget::item { height: 22px; }"
                "QTreeWidget::item:selected { background: rgba(232,168,87,0.22); color: %1; }"
                "QTreeWidget::item:hover { background: rgba(255,255,255,0.06); }"
                "QTreeWidget::branch { background: transparent; }")
            .arg(theme::text_primary()));

    connect(tree, &QTreeWidget::itemClicked, this,
            [this](QTreeWidgetItem* item, int) { route_tree_click(item); });

    connect(editor_, &editor::Editor::tab_activated, this,
            [this](const QString& rel) {
        if (!graph_view_ || !graph_panel_visible()) return;
        // The graph node carries a scheme prefix (comp adds ":<entry>"):
        // select_node_for_key matches comp keys by "<rel>:" prefix.
        graph_view_->select_node_for_key("gfx:" + rel);
        graph_view_->select_node_for_key("comp:" + rel + ":");
    });

    connect(tree, &QTreeWidget::customContextMenuRequested, this,
            [this](const QPoint& pos) { show_tree_context_menu(pos); });
    connect(tree, &QTreeWidget::itemChanged, this,
            [this](QTreeWidgetItem* item, int col) {
        if (col == 0) rename_shader_file(item);
    });

    refresh_files_tree();
    layout->addWidget(files_tree_, 1);
    return w;
}

QWidget* Shell::learn_panel() {
    // One persistent view, built once and kept in its page (page state
    // survives opening FILES and coming back).
    if (!trail_view_) {
        trail_view_ = new learn::Trail_View(this);
        connect(trail_view_, &learn::Trail_View::scene_requested, this,
                [this](const QString& title) {
                    emit scene_open_requested(title);
                });
    }
    trail_view_->setParent(nullptr);
    auto* w = new QWidget();
    auto* layout = new QVBoxLayout(w);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    layout->addWidget(caption(i18n::tr("learn")));
    layout->addWidget(trail_view_, 1);
    return w;
}

QWidget* Shell::export_panel() {
    auto* w = new QWidget();
    auto* layout = new QVBoxLayout(w);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);
    layout->addWidget(caption(i18n::tr("export")), 0);
    auto* png = new QPushButton(i18n::tr("export png"), w);
    connect(png, &QPushButton::clicked, this, [this] { emit png_export_requested(); });
    layout->addWidget(png, 0);
    layout->addWidget(caption("gif"), 0);
    auto* start = new QDoubleSpinBox(w);
    start->setRange(0, 999);
    start->setValue(ui.gif_start);
    auto* end = new QDoubleSpinBox(w);
    end->setRange(0, 999);
    end->setValue(ui.gif_end);
    end->setMinimum(start->value()); // I-307: never start > end
    connect(start, &QDoubleSpinBox::valueChanged, this, [this, end](double v) {
        ui.gif_start = float(v);
        end->setMinimum(float(v));
    });
    connect(end, &QDoubleSpinBox::valueChanged, this,
            [this](double v) { ui.gif_end = float(v); });
    auto* row1 = new QHBoxLayout();
    row1->addWidget(new QLabel(i18n::tr("start (s)")));
    row1->addWidget(start, 1);
    layout->addLayout(row1);
    auto* row2 = new QHBoxLayout();
    row2->addWidget(new QLabel(i18n::tr("end (s)")));
    row2->addWidget(end, 1);
    layout->addLayout(row2);
    auto* gif = new QPushButton(i18n::tr("export gif"), w);
    connect(gif, &QPushButton::clicked, this, [this] {
        emit gif_export_requested(ui.gif_start, ui.gif_end);
    });
    layout->addWidget(gif, 0);
    layout->addStretch(1);
    return w;
}

QWidget* Shell::effects_panel() {
    auto* w = new QWidget();
    auto* layout = new QVBoxLayout(w);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);
    layout->addWidget(caption(i18n::tr("effects")), 0);
    // Not wired to the runtime yet (Odin parity pass pending): disabled so
    // the panel never offers controls that do nothing (affordance honesty).
    layout->addWidget(caption(i18n::tr("develop transition")), 0);
    auto* develop = new QCheckBox(i18n::tr("develop transition"), w);
    layout->addWidget(develop, 0);
    auto* springs = new QCheckBox(i18n::tr("springs"), w);
    layout->addWidget(springs, 0);
    auto* grain = new QCheckBox(i18n::tr("paper grain"), w);
    layout->addWidget(grain, 0);
    for (QWidget* box : {develop, springs, grain}) box->setEnabled(false);
    layout->addStretch(1);
    return w;
}

QWidget* Shell::shortcuts_panel() {
    auto* w = new QWidget();
    auto* layout = new QVBoxLayout(w);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(4);
    layout->addWidget(caption(i18n::tr("shortcuts")));
    auto row = [&](const QString& key, const QString& desc) {
        auto* line = new QHBoxLayout();
        auto* chip = new QLabel(key);
        chip->setStyleSheet(QString("color: %1; font-weight: 600;")
                                .arg(theme::text_primary()));
        auto* desc_label = new QLabel(desc);
        desc_label->setWordWrap(true);
        line->addWidget(chip);
        line->addWidget(desc_label, 1);
        layout->addLayout(line, 0); // rows pack at the top; stretch at end
    };
    layout->addWidget(caption(i18n::tr("window")), 0);
    row("F1", i18n::tr("zen mode: toggle sidebar + editor"));
    row("F2", i18n::tr("toggle shader editor"));
    row("F3", i18n::tr("cycle preview: float, split, full"));
    row("F4", i18n::tr("theater mode"));
    row("F5", i18n::tr("mobile theater (9:16)"));
    row("F6", i18n::tr("cycle workspace: development, presentation, pipeline"));
    row("Cmd+B", i18n::tr("toggle sidebar"));
    row("Esc", i18n::tr("close tooltip / quit"));
    layout->addWidget(caption(i18n::tr("editor")), 0);
    row("Cmd+S", i18n::tr("save all"));
    row("Cmd+click", i18n::tr("go to definition"));
    row("Cmd+Shift+D", i18n::tr("duplicate line"));
    row("Alt+-", i18n::tr("navigate back"));
    row("Ctrl+Z/Y", i18n::tr("undo / redo"));
    layout->addWidget(caption(i18n::tr("graph")), 0);
    row("SPACE", i18n::tr("pan the node graph; release glides"));
    row("scroll", i18n::tr("zoom around the cursor"));
    row("right-click", i18n::tr("new node on empty canvas; menu on a node"));
    layout->addWidget(caption(i18n::tr("scene")), 0);
    row("click", i18n::tr("pixel inspector: click the scene to sample"));
    layout->addStretch(1);
    return w;
}

void Shell::show_editor(bool on) {
    if (!central_) return;
    ui.fullscreen_view = !on;
    central_->setCurrentIndex(on ? 0 : 1); // 0 = editor (always-on default),
    if (on) editor_dock(); // lazy-create   // 1 = fullscreen viewport (F2/zen)
}

// ---- Layout presets (P3-N4) ----
// Normal | Zen | Theater | Mobile are mutually exclusive. Entering a preset
// saves the Normal-state values ONCE; leaving restores them and returns to
// Normal. No more 2^n flag matrix: toggling Zen while Theater is up leaves
// Theater cleanly instead of interleaving hidden state.
// Normal-state values a preset hides; restored on leaving the preset.
void Shell::save_normal_state() {
    ui.saved_ui_font = ui.font_size;
    ui.saved_ed_font = ui.editor_font;
    ui.saved_open = ui.panel_open;
    ui.saved_preview = ui.preview;
    ui.saved_split_left = ui.split_left;
    ui.saved_mode = ui.mode;
}

// plan9: preview mode/split + sidebar mode are part of the restore too —
// the whole workspace.
void Shell::restore_normal_state() {
    ui.font_size = ui.saved_ui_font;
    ui.editor_font = ui.saved_ed_font;
    if (editor_) editor_->set_editor_font(int(ui.saved_ed_font));
    ui.panel_open = ui.saved_open;
    ui.preview = ui.saved_preview;
    ui.split_left = ui.saved_split_left;
    ui.mode = ui.saved_mode;
    update_preview_buttons();
}

// Per-preset deltas applied on top of the saved Normal state.
void Shell::enter_preset(Ui_State::Layout_Preset preset) {
    if (preset == Ui_State::Layout_Preset::Normal) {
        if (strip_) strip_->setVisible(true);
        show_editor(true);
    } else if (preset == Ui_State::Layout_Preset::Zen) {
        // F1: sidebar (strip + panel) gone, fullscreen viewport.
        if (strip_) strip_->setVisible(false);
        ui.panel_open = false;
        show_editor(false);
    } else if (preset == Ui_State::Layout_Preset::Theater ||
               preset == Ui_State::Layout_Preset::Mobile) {
        // F4 bigger type + chrome hidden / F5 9:16 portrait. Theater and
        // Mobile share the chrome path; only the host's window aspect
        // differs (Mobile signals it via ui.layout for the resize).
        ui.font_size = 18;
        ui.editor_font = 21;
        if (editor_) editor_->set_editor_font(21);
        ui.panel_open = false;
        show_editor(true);
    } else if (preset == Ui_State::Layout_Preset::Presentation) {
        // plan9 Presentation: code + preview emphasized, chrome minimal.
        // SPLIT preview (predictable 42/58), panel closed (recoverable via
        // strip/chevron), editor font up one notch for recordings. The
        // user's preview-mode/split choice is RESTORED on leaving.
        ui.font_size = 16;
        ui.editor_font = 16;
        if (editor_) editor_->set_editor_font(16);
        ui.panel_open = false;
        ui.preview = Preview_Mode::SPLIT;
        ui.split_left = 0.42f;
        update_preview_buttons();
        show_editor(true);
    } else if (preset == Ui_State::Layout_Preset::Pipeline) {
        // plan9 Pipeline: the graph IS the workspace (GRAPH mode open,
        // wide), editor + preview retained via the SPLIT dock on return.
        ui.preview = Preview_Mode::FLOAT;
        ui.panel_open = true;
        ui.mode = Sidebar_Mode::GRAPH;
        ui.user_w_mode[int(Sidebar_Mode::GRAPH)] = 0; // per-mode default 0.52·w
        update_preview_buttons();
        show_editor(true);
    }
}

void Shell::set_layout(Ui_State::Layout_Preset preset) {
    if (ui.layout == preset) {
        set_layout(Ui_State::Layout_Preset::Normal); // toggle off -> Normal
        return;
    }
    // Leaving any active preset: restore the Normal-state values.
    if (ui.layout != Ui_State::Layout_Preset::Normal) restore_normal_state();
    ui.layout = preset;
    if (preset != Ui_State::Layout_Preset::Normal) save_normal_state();
    enter_preset(preset);
    persist_prefs(); // plan9: workspace choice persists across restarts
    apply_mode(ui.mode);
}

// While a preset is active the live font/preview fields hold the PRESET's
// values; persisting them would make the next boot treat them as the Normal
// state. Write the saved Normal values instead.
void Shell::persist_prefs() {
    if (ui.layout == Ui_State::Layout_Preset::Normal) {
        prefs_save(ui);
        return;
    }
    Ui_State normal = ui;
    normal.font_size = ui.saved_ui_font;
    normal.editor_font = ui.saved_ed_font;
    normal.preview = ui.saved_preview;
    normal.split_left = ui.saved_split_left;
    prefs_save(normal);
}

// plan9: F6 cycles the three recording workspaces (Development →
// Presentation → Pipeline → Development). Zen/Theater/Mobile stay on
// their own keys — the cycle covers the trio the SHORTCUTS panel lists.
void Shell::cycle_workspace() {
    using LP = Ui_State::Layout_Preset;
    switch (ui.layout) {
    case LP::Presentation: set_layout(LP::Pipeline); break;
    case LP::Pipeline: set_layout(LP::Normal); break;
    default: set_layout(LP::Presentation); break; // Normal/Zen/... enter
    }
}

void Shell::toggle_editor() {
    // F2: flip between the always-on editor (PiP preview floating) and a
    // fullscreen viewport page.
    bool editor_up = central_ && central_->currentIndex() == 0;
    show_editor(!editor_up);
}

// ---- Preview modes (FLOAT | SPLIT | FULL) ----

// The single entry point: topbar buttons, F3 and drag-drop snaps all land
// here. The host reads ui.preview each tick and reshapes the SDL window;
// prefs persist the choice.
void Shell::set_preview_mode(Preview_Mode mode) {
    if (ui.preview == mode) return;
    ui.preview = mode;
    update_preview_buttons();
    update_preview_overlays();
    update_split_layout(); // editor clamps/unclamps with the mode
    persist_prefs();
}

void Shell::cycle_preview_mode() {
    int next = (int(ui.preview) + 1) % 3;
    set_preview_mode(Preview_Mode(next));
}

void Shell::update_preview_buttons() {
    const Preview_Mode modes[3] = {Preview_Mode::FLOAT, Preview_Mode::SPLIT,
                                   Preview_Mode::FULL};
    for (int i = 0; i < 3; ++i) {
        QPushButton* btn = preview_btns_[i];
        if (!btn) continue;
        bool active = ui.preview == modes[i];
        if (btn->property("active").toBool() != active) {
            btn->setProperty("active", active);
            btn->style()->unpolish(btn);
            btn->style()->polish(btn);
            btn->update();
        }
    }
}

QWidget* Shell::preview_overlay() {
    if (preview_overlay_) return preview_overlay_;
    preview_overlay_ = new QWidget(this);
    preview_overlay_->setAttribute(Qt::WA_TransparentForMouseEvents);
    preview_overlay_->hide();
    const QString zone_qss =
        QString("QLabel { border: 2px dashed %1; border-radius: 8px;"
                " background: %2; color: %1;"
                " font-family: 'JetBrains Mono', monospace; font-size: 9pt;"
                " letter-spacing: 1px; }")
            .arg(theme::safelight(), theme::frame_border());
    auto make_zone = [this, &zone_qss](const char* name) {
        auto* z = new QLabel(preview_overlay_);
        z->setObjectName(name);
        z->setStyleSheet(zone_qss);
        z->setAlignment(Qt::AlignCenter);
        z->hide();
        return z;
    };
    snap_left_ = make_zone("snapLeft");
    snap_left_->setText(i18n::tr("drop: dock split"));
    snap_right_ = make_zone("snapRight");
    snap_right_->setText(i18n::tr("drop: dock split"));
    return preview_overlay_;
}

QWidget* Shell::preview_frame_overlay() {
    if (preview_border_) return preview_border_;
    preview_border_ = new QLabel(this);
    preview_border_->setAttribute(Qt::WA_TransparentForMouseEvents);
    preview_border_->setStyleSheet(
        QString("QLabel { border: 1px solid %1; border-radius: 6px;"
                " background: transparent; }")
            .arg(theme::control_border()));
    preview_border_->hide();
    return preview_border_;
}

void Shell::set_snap_hover(int zone) {
    ui.snap_hover = zone;
    update_preview_overlays();
}

// Drag path: instant follow (the cursor IS the physics), no persistence.
void Shell::set_split_gutter(float left_fraction) {
    ui.split_left = std::clamp(left_fraction, 0.2f, 0.8f);
    update_preview_overlays();
    update_split_layout(); // drag: editor frozen; non-drag: follows boundary
    // No prefs_save here: the spring-settle on release persists once.
}

// Drop path (snap zones / topbar): settle with one damped spring so the
// dock lands like a mass on a soft spring, then persists the final value.
void Shell::settle_split_gutter(float left_fraction) {
    gutter_dragging_ = false; // editor width freeze ends with the gesture
    editor_w_drag_ = 0;
    if (split_anim_) split_anim_->stop(); // never stack two springs on split_left
    ui.split_left = std::clamp(left_fraction, 0.2f, 0.8f);
    if (reduced_motion()) {
        update_preview_overlays();
        update_split_layout();
        persist_prefs();
        return;
    }
    const float target = ui.split_left;
    const float delta = target - 0.5f;
    auto* anim = new QVariantAnimation(this);
    split_anim_ = anim;
    anim->setDuration(240);
    anim->setStartValue(target + delta * 0.05f);          // overshoot in
    anim->setKeyValueAt(0.55, target - delta * 0.035f);   // crosses once
    anim->setEndValue(target);
    anim->setEasingCurve(QEasingCurve::OutCubic);
    connect(anim, &QVariantAnimation::valueChanged, this,
            [this](const QVariant& v) {
                ui.split_left = v.toFloat();
                update_preview_overlays();
                update_split_layout();
            });
    connect(anim, &QVariantAnimation::finished, this, [this, target] {
        ui.split_left = target;
        update_preview_overlays();
        update_split_layout();
        persist_prefs();
    });
    anim->start(QAbstractAnimation::DeleteWhenStopped);
}

// Live safelight (overdrive): the host feeds the average color of the
// rendered frame once a second; the preview frame border and the gutter
// breathe with the shader. Blend with the theme accent (60/40) so the
// result stays legible on every skin; disabled by reduced-motion respect
// is unnecessary (color, not motion) but the restyle is throttled 1x/s.
void Shell::set_live_tint(const QColor& c) {
    if (!c.isValid()) return;
    QColor mixed = QColor::fromRgb(
        (theme::safelight_rgb().red() * 3 + c.red()) / 4,
        (theme::safelight_rgb().green() * 3 + c.green()) / 4,
        (theme::safelight_rgb().blue() * 3 + c.blue()) / 4);
    if (mixed == live_tint_) return;
    live_tint_ = mixed;
    update_live_tint_border(); // border follows the mixed tint
    if (preview_gutter_)
        preview_gutter_->setStyleSheet(
            QString("QLabel { background: %1; border-radius: 2px; }")
                .arg(live_tint_.name()));
}

void Shell::update_preview_overlays() {
    QWidget* vp = viewport();
    if (!vp || ui.fullscreen_view) {
        if (preview_border_) preview_border_->hide();
        if (preview_overlay_) preview_overlay_->hide();
        return;
    }
    // Frame border: FLOAT always; SPLIT gets it too while the gutter is
    // visible, so the preview reads as a panel of this app, not a guest
    // window. FULL needs no frame (it IS the space).
    if (ui.preview == Preview_Mode::FLOAT ||
        ui.preview == Preview_Mode::SPLIT) {
        preview_frame_overlay()->show();
    } else if (preview_border_) {
        preview_border_->hide();
    }
    // Snap zones only while a drag is aiming (host reports via snap_hover).
    if (ui.snap_hover >= 0 && ui.preview == Preview_Mode::FLOAT) {
        preview_overlay();
        const QRect vp_g = viewport_global_rect(this);
        preview_overlay_->setGeometry(QRect(mapFromGlobal(vp_g.topLeft()),
                                            vp_g.size()));
        const int half = vp_g.width() / 2;
        const QRect left(mapFromGlobal(vp_g.topLeft()), QSize(half, vp_g.height()));
        const QRect right(mapFromGlobal(QPoint(vp_g.left() + half, vp_g.top())),
                          QSize(vp_g.width() - half, vp_g.height()));
        snap_left_->setGeometry(left);
        snap_right_->setGeometry(right);
        (ui.snap_hover == 0 ? snap_left_ : snap_right_)->show();
        (ui.snap_hover == 0 ? snap_right_ : snap_left_)->hide();
        preview_overlay_->raise();
        preview_overlay_->show();
    } else if (preview_overlay_) {
        preview_overlay_->hide();
    }
    // Frame border + gutter geometry land in a second pass: the host calls
    // set_preview_frame_rect() each tick with the live SDL rect, and
    // resizeEvent() keeps overlays glued while the window resizes.
}

// Host tick: the live SDL rect (Qt global coords) drives the themed frame
// and, in SPLIT, the gutter band on the editor|preview boundary.
void Shell::set_preview_frame_rect(const QRect& global_rect) {
    QWidget* vp = viewport();
    if (!vp || ui.fullscreen_view || global_rect.isEmpty()) {
        if (preview_border_) preview_border_->hide();
        if (preview_gutter_) preview_gutter_->hide();
        return;
    }
    if (ui.preview == Preview_Mode::FLOAT ||
        ui.preview == Preview_Mode::SPLIT) {
        preview_frame_overlay()->setGeometry(
            QRect(mapFromGlobal(global_rect.topLeft()), global_rect.size()));
        preview_frame_overlay()->raise();
        preview_frame_overlay()->show();
    } else if (preview_border_) {
        preview_border_->hide();
    }
    // First-run discovery hint (P1): FLOAT says nothing about being
    // draggable; show one amber caption under the frame for 2.5s, once,
    // the first time a FLOAT session reaches a live frame.
    if (ui.preview == Preview_Mode::FLOAT && !ui.preview_hinted) {
        ui.preview_hinted = true; // one shot: even an early quit keeps it
        persist_prefs();
        if (!preview_hint_) {
            preview_hint_ = new QLabel(this);
            preview_hint_->setAttribute(Qt::WA_TransparentForMouseEvents);
            preview_hint_->setStyleSheet(
                QString("QLabel { background: %1;"
                        " color: %2; padding: 3px 10px; border-radius: 3px;"
                        " font-family: 'JetBrains Mono', monospace;"
                        " font-size: 8pt; }")
                    .arg(theme::overlay_scrim(220), theme::safelight()));
            preview_hint_->setText(i18n::tr("drag me: dock left or right"));
            preview_hint_->adjustSize();
            QTimer::singleShot(theme::hint_duration_ms(), preview_hint_, &QWidget::hide);
        }
        preview_hint_->move(mapFromGlobal(global_rect.topLeft()) +
                            QPoint(6, global_rect.height() + 4));
        preview_hint_->raise();
        preview_hint_->show();
    } else if (preview_hint_ && ui.preview != Preview_Mode::FLOAT) {
        preview_hint_->hide();
    }
    // Gutter: a 10px grab band centered on the split boundary. Draggable:
    // press+move re-fractions the split (set_split_gutter).
    if (ui.preview == Preview_Mode::SPLIT) {
        if (!preview_gutter_) {
            preview_gutter_ = new QLabel(this);
            preview_gutter_->setAttribute(Qt::WA_TransparentForMouseEvents);
            preview_gutter_->setStyleSheet(
                QString("QLabel { background: %1; border-radius: 2px; }")
                    .arg(theme::frame_border()));
        }
        const int gx = mapFromGlobal(QPoint(global_rect.left(), 0)).x();
        preview_gutter_->setGeometry(gx - 5, mapFromGlobal(global_rect.topLeft()).y(),
                                     10, global_rect.height());
        preview_gutter_->raise();
        preview_gutter_->show();
    } else if (preview_gutter_) {
        preview_gutter_->hide();
    }
}

graph_editor::Node_View* Shell::graph_view_typed() {
    if (graph_view_) return graph_view_;
    graph_view_ = new graph_editor::Node_View(this);
    // Wired at creation, not in files_panel(): the GRAPH panel can open before the Files tab is ever built.
    connect(graph_view_, &graph_editor::Node_View::node_selected, this,
            [this](const QString& key, const QString&) {
        // Node key: "gfx:<scene>/<file>" or "comp:<scene>/<file>:<entry>";
        // the editor rel drops the scheme AND the compute entry suffix.
        QString rel = key.startsWith("comp:") ? key.mid(5).section(':', 0, 0)
                                              : key.mid(4);
        editor_dock(); // lazy-create
        editor_->load_named(rel);
        show_editor(true);
    });
    connect(graph_view_, &graph_editor::Node_View::fullscreen_toggled, this, [this](bool on) {
        ui.graph_fullscreen = on;
        animate_panel_to(panel_width_for(ui, Sidebar_Mode::GRAPH, width()).toInt());
        update_panel_edge();
    });
    return graph_view_;
}

void Shell::animate_panel_to(int target_w) {
    if (!panel_) return;
    if (panel_anim_) panel_anim_->stop(); // overlapping runs would fight over setFixedWidth
    if (target_w > 0) panel_->show();
    if (reduced_motion()) { // instant transition, no tween
        panel_->setFixedWidth(target_w);
        if (target_w <= 1) panel_->hide();
        else panel_->show();
        if (central_ && central_->layout()) central_->layout()->activate();
        update_panel_edge();
        return;
    }
    // Animate the panel's real width with a QVariantAnimation driving
    // setFixedWidth: maximumWidth interpolation is useless here (its rest
    // value is QWIDGETSIZE_MAX, so the tween would spend ~98% of the run
    // above any usable width and the panel would snap instead of slide).
    // One live instance at most (panel_anim_), DeleteWhenStopped.
    auto* anim = new QVariantAnimation(this);
    panel_anim_ = anim;
    anim->setDuration(180);
    anim->setEasingCurve(QEasingCurve::OutCubic); // darkroom motion: damped ease-out
    anim->setStartValue(panel_->width());
    anim->setEndValue(target_w);
    connect(anim, &QVariantAnimation::valueChanged, this, [this](const QVariant& v) {
        int w = v.toInt();
        panel_->setFixedWidth(w);
        if (w <= 1) panel_->hide();
        // Native child (sdl_host_) geometry must follow the spring.
        update_panel_edge();
    });
    connect(anim, &QVariantAnimation::finished, this, [this] {
        if (ui.panel_open && panel_->width() > 1) panel_->show();
        update_panel_edge();
        // The editor clamp was computed against the mid-animation viewport width
        // (e.g. 160 px while graph fullscreen hid it): re-derive at the final width.
        if (central_ && central_->layout()) central_->layout()->activate();
        update_split_layout();
    });
    anim->start(QAbstractAnimation::DeleteWhenStopped);
}

// Global theme switch: re-skins every PERSISTENT chrome widget from theme::'s
// active palette. Panels/editor rebuild per mode/scene and read the palette at
// build time, so they pick the theme up on the next apply_mode/scene_switched.
void Shell::apply_chrome_theme() {
    if (scene_list_) scene_list_->setStyleSheet(scene_list_qss());
    if (scene_list_widget_)
        scene_list_widget_->setStyleSheet(scene_list_items_qss());
    if (topbar_) topbar_->setStyleSheet(topbar_qss());
    if (strip_) strip_->setStyleSheet(strip_qss());
    if (panel_) panel_->setStyleSheet(panel_qss());
    if (panel_edge_) panel_edge_->setStyleSheet(panel_edge_qss());
    // Icons: tinted at build time, so re-tint with the active theme's text.
    const QColor icon = icon_tint();
    if (save_btn_) save_btn_->setIcon(tinted_icon(kSaveIcon, icon, kToolbarIcon));
    if (new_btn_) new_btn_->setIcon(tinted_icon(kNewIcon, icon, kToolbarIcon));
    if (pause_btn_)
        pause_btn_->setIcon(tinted_icon(ui.paused
                                            ? ":/qlementine/icons/24/media/play.svg"
                                            : ":/qlementine/icons/24/media/pause.svg",
                                        icon, kToolbarIcon));
    if (gear_btn_)
        gear_btn_->setIcon(tinted_icon(
            ":/qlementine/icons/24/navigation/settings.svg", icon, kStripIcon));
    // Preview segmented buttons: re-tint icons; overlays re-read the
    // palette (frame border, snap dashes, gutter band). The pip caption's
    // cached style must go too — its state colors follow the theme.
    pip_style_color_.clear();
    pip_text_.clear();
    for (int i = 0; i < 3; ++i)
        if (preview_btns_[i])
            preview_btns_[i]->setIcon(tinted_icon(kPreviewIcons[i], icon, kToolbarIcon));
    if (preview_border_)
        preview_border_->setStyleSheet(
            QString("QLabel { border: 1px solid %1; border-radius: 6px;"
                    " background: transparent; }")
                .arg(theme::control_border()));
    if (preview_gutter_)
        preview_gutter_->setStyleSheet(
            QString("QLabel { background: %1; border-radius: 2px; }")
                .arg(theme::frame_border()));
    if (preview_overlay_) {
        const QString zone_qss =
            QString("QLabel { border: 2px dashed %1; border-radius: 8px;"
                    " background: %2; }")
                .arg(theme::safelight(), theme::frame_border());
        snap_left_->setStyleSheet(zone_qss);
        snap_right_->setStyleSheet(zone_qss);
    }
    update_preview_overlays();
    // plan13: the editor skin drives the pipeline graph too — grid, node
    // bodies, wires and the live delegates all re-derive from the tokens.
    // Lazy: a graph that was never opened has no instance to restyle.
    if (graph_view_) graph_view_->apply_theme();
    // Strip icons bake their tint at build time: drop the cached icon name
    // so the sync re-tints them with the new palette.
    for (auto* btn : strip_buttons_) btn->setProperty("current_icon", QString());
    sync_strip_buttons(ui.mode);
    update();
}

// Strip button states: exactly one button mirrors (mode, panel_open). The
// click already flipped Qt's own checked flag, so set ALL buttons
// explicitly: no stale "active" marks survive the pass.
void Shell::sync_strip_buttons(Sidebar_Mode mode) {
    for (QPushButton* btn : strip_buttons_) {
        // The "mode" property IS the mapping (FILES,GRAPH,CONTROLS,...)
        // which does NOT match the enum's numeric order (CONTROLS=0, ...).
        const bool active =
            btn->property("mode").toInt() == int(mode) && ui.panel_open;
        // Plan 07 P2: icon follows state — folder→folder-open on FILES,
        // and back on every other mode.
        const QString want = active ? btn->property("icon_active").toString()
                                    : btn->property("icon_rest").toString();
        if (btn->property("current_icon").toString() != want) {
            btn->setProperty("current_icon", want);
            btn->setIcon(
                tinted_icon(want.toUtf8().constData(), icon_tint(), kStripIcon));
        }
        if (btn->property("active").toBool() != active) {
            btn->setProperty("active", active);
            // Repolish: the stylesheet selector [active="true"] only
            // re-evaluates when the style is invalidated.
            btn->style()->unpolish(btn);
            btn->style()->polish(btn);
            btn->update();
        }
    }
}

// Lazily builds the persistent page for a mode. Pages are tracked by widget,
// not stack index: removeWidget (scene_switched) shifts later indices.
// LEARN/EFFECTS keep their pages for menu access, they just have no strip
// button.
QWidget* Shell::page_for(Sidebar_Mode mode) {
    QWidget*& slot = panel_pages_[size_t(mode)];
    if (slot) return slot;
    QWidget* page = nullptr;
    switch (mode) {
    case Sidebar_Mode::CONTROLS: page = controls_panel(); break;
    case Sidebar_Mode::FILES: page = files_panel(); break;
    case Sidebar_Mode::LEARN: page = learn_panel(); break;
    case Sidebar_Mode::GRAPH: page = graph_view_typed(); break;
    case Sidebar_Mode::EXPORT: page = export_panel(); break;
    case Sidebar_Mode::EFFECTS: page = effects_panel(); break;
    case Sidebar_Mode::SHORTCUTS: page = shortcuts_panel(); break;
    }
    if (!page) return nullptr;
    panel_stack_->addWidget(page);
    slot = page;
    return page;
}

void Shell::apply_mode(Sidebar_Mode mode) {
    // Mode switch owns the canvas: the floating scene list would otherwise
    // strand over the new panel (no native popup auto-dismiss here).
    if (scene_list_ && scene_list_->isVisible()) show_scene_list(false);
    sync_strip_buttons(mode);
    if (!ui.panel_open) {
        animate_panel_to(0);
        if (central_ && central_->layout()) central_->layout()->activate();
        return;
    }
    int target = panel_width_for(ui, mode, this->width()).toInt();
    animate_panel_to(target);
    if (central_ && central_->layout()) central_->layout()->activate();
    if (central_) central_->setCurrentIndex(0); // editor page, always
    QWidget* page = page_for(mode);
    if (page) {
        // Scene-bound pages refresh their data on entry (cheap, in-place).
        if (mode == Sidebar_Mode::GRAPH && !mgr_.scenes.empty()) {
            const auto& scene = mgr_.scenes[size_t(mgr_.current)];
            graph_view_->set_scene(scene);
            graph_view_->load_layout(QString::fromStdString(scene.title),
                                     QString::fromStdString(
                                         scene::scene_root_dir(roots_, scene.title)),
                                     scene);
            graph_view_->set_fullscreen_state(ui.graph_fullscreen);
        }
        page->show();
        panel_stack_->setCurrentWidget(page);
    }
    emit mode_changed(mode);
}

// Save-button border while a build runs: amber when on, none when idle.
void Shell::restyle_save_button(bool on) {
    save_btn_->setStyleSheet(on ? QString("QPushButton { border: 1px solid %1; }")
                                      .arg(theme::safelight())
                                : "QPushButton { border: none; }");
    save_btn_->style()->unpolish(save_btn_);
    save_btn_->style()->polish(save_btn_);
    save_btn_->update();
}

// LIFETIME: the bake animations are member-owned and parented to the Shell
// (no DeleteWhenStopped): the host calls set_baking every tick, and a
// deleteLater'd animation left a dangling member that SEGV'd on the next
// tick (invalid vptr). They are deleted synchronously here, never later.
void Shell::stop_bake_animations() {
    if (bake_pulse_) {
        bake_pulse_->stop();
        delete bake_pulse_;
        bake_pulse_ = nullptr;
    }
    if (bake_flash_) {
        bake_flash_->stop();
        delete bake_flash_;
        bake_flash_ = nullptr;
    }
}

// Bake pulse: while the build runs the preview frame's border breathes
// amber. Reduced motion: static amber border, no wave.
void Shell::start_bake_pulse() {
    if (reduced_motion()) {
        preview_border_->setStyleSheet(
            QString("QLabel { border: 1px solid %1; border-radius: 6px;"
                    " background: transparent; }")
                .arg(theme::safelight()));
        return;
    }
    bake_pulse_ = new QVariantAnimation(this);
    bake_pulse_->setStartValue(theme::bake_pulse_alpha_min() / 100.0);
    bake_pulse_->setEndValue(1.0);
    bake_pulse_->setDuration(theme::bake_pulse_duration_ms());
    bake_pulse_->setLoopCount(-1); // runs until the bake ends
    bake_pulse_->setEasingCurve(QEasingCurve::InOutSine);
    connect(bake_pulse_, &QVariantAnimation::valueChanged, this,
            [this](const QVariant& v) {
                QColor c = theme::safelight_rgb();
                c.setAlphaF(v.toDouble());
                if (preview_border_)
                    preview_border_->setStyleSheet(
                        QString("QLabel { border: 1px solid %1;"
                                " border-radius: 6px;"
                                " background: transparent; }")
                            .arg(c.name(QColor::HexArgb)));
            });
    bake_pulse_->start(); // runs until set_baking stops it
}

// Bake end: one green flash on success; on failure (or reduced motion) the
// frame returns to its normal tint immediately.
void Shell::start_bake_flash() {
    const bool bake_ok =
        mgr_.scenes.empty() ||
        mgr_.scenes[size_t(mgr_.current)].pipeline_error.empty();
    if (!bake_ok || reduced_motion()) {
        update_live_tint_border(); // restore normal/live-tint frame
        return;
    }
    bake_flash_ = new QVariantAnimation(this);
    bake_flash_->setStartValue(1.0);
    bake_flash_->setEndValue(0.0);
    bake_flash_->setDuration(theme::bake_flash_duration_ms());
    bake_flash_->setEasingCurve(QEasingCurve::OutCubic);
    connect(bake_flash_, &QVariantAnimation::valueChanged, this,
            [this](const QVariant& v) {
                QColor c = theme::success_rgb();
                c.setAlphaF(v.toDouble());
                if (preview_border_)
                    preview_border_->setStyleSheet(
                        QString("QLabel { border: 1px solid %1;"
                                " border-radius: 6px;"
                                " background: transparent; }")
                            .arg(c.name(QColor::HexArgb)));
            });
    connect(bake_flash_, &QVariantAnimation::finished, this,
            [this] { update_live_tint_border(); });
    bake_flash_->start(); // finished() restores the border; member freed on next set_baking
}

// Bake feedback: an amber border rides the save button while a scene build
// is running (the save → 1-3 s silence → preview-jump loop needed visible
// state), and the preview frame pulses with it.
void Shell::set_baking(bool on) {
    if (!save_btn_) return;
    const QString prop = on ? "1" : "0";
    if (save_btn_->property("baking") == prop) return;
    save_btn_->setProperty("baking", prop);
    restyle_save_button(on);
    if (!on) update_pipeline_error_bar(); // bake finished: surface failures
    stop_bake_animations();
    if (!preview_border_) return;
    if (on) start_bake_pulse();
    else start_bake_flash();
}

// Restores the preview border to its current live-tint (or theme) color.
void Shell::update_live_tint_border() {
    if (!preview_border_) return;
    preview_border_->setStyleSheet(
        QString("QLabel { border: 1px solid %1; border-radius: 6px;"
                " background: transparent; }")
            .arg(live_tint_.isValid() ? live_tint_.name()
                                      : theme::control_border()));
}

// plan8 viewport caption — parked on the VIEWPORT's top-left corner (Qt
// area, never under the SDL child NSWindow). Shows WHAT is rendering, at
// WHICH resolution, WHICH pass, and the render state (compiling/paused/
// ERROR). Global rect in Qt coords (top-left origin); the host passes the
// viewport rect each tick.
void Shell::set_pip_overlay(const QString& text, const QRect& global_rect) {
    if (!pip_overlay_) {
        pip_overlay_ = new QLabel(this);
        pip_overlay_->setObjectName("pipOverlay");
        pip_overlay_->setAttribute(Qt::WA_TransparentForMouseEvents);
    }
    if (text.isEmpty() || global_rect.isEmpty()) {
        pip_overlay_->hide();
        return;
    }
    // Per-tick path (60 Hz): the style depends only on the state word +
    // theme, the font only on the editor font size. Cache both and skip the
    // rebuild when unchanged — setStyleSheet + adjustSize were ~0.25 ms per
    // tick in the drag budget (Plan 04 Task A).
    const bool error = text.contains(" · ERROR: ");
    const bool compiling = text.endsWith(" · compiling");
    const bool paused = text.endsWith(" · paused");
    const QString state_color = error ? theme::error()
                                : compiling ? theme::safelight()
                                : paused ? theme::text_primary()
                                : theme::text_muted();
    if (state_color != pip_style_color_ || ui.editor_font != pip_style_font_) {
        pip_style_color_ = state_color;
        pip_style_font_ = ui.editor_font;
        pip_overlay_->setStyleSheet(
            QString("QLabel#pipOverlay { background: %1;"
                    " color: %2; padding: 3px 10px 3px 8px; font-size: 8pt;"
                    " font-family: 'JetBrains Mono', monospace;"
                    " border-left: 2px solid %2; border-radius: 3px; }")
                .arg(theme::overlay_scrim(210), state_color));
        QFont readout = theme::code_font(8);
        readout.setLetterSpacing(QFont::AbsoluteSpacing, 0.3);
        pip_overlay_->setFont(readout);
        pip_text_.clear(); // font change invalidates the cached size
    }
    if (text != pip_text_) {
        pip_text_ = text;
        pip_overlay_->setText(text);
        pip_overlay_->adjustSize();
    }
    // Anchor to the preview frame rect the host passes (global coords):
    // the caption belongs ON the preview surface, not parked at the
    // viewport's top-left where it covers the editor's file selector.
    const QPoint anchor = global_rect.isEmpty()
                              ? viewport()->mapToGlobal(QPoint(0, 0))
                              : global_rect.topLeft();
    pip_overlay_->move(mapFromGlobal(anchor) + QPoint(6, 6));
    pip_overlay_->raise();
    pip_overlay_->show();
}

// P1-N2: the last bake failure, persistent and on-site (editor top). The
// GRAPH panel kept the only copy before; this bar shows it where the user
// already is, and survives until the next successful bake.
void Shell::update_pipeline_error_bar() {
    if (!pipeline_error_bar_) return;
    if (mgr_.scenes.empty()) {
        pipeline_error_bar_->hide();
        return;
    }
    const auto& scene = mgr_.scenes[size_t(mgr_.current)];
    if (scene.pipeline_error.empty()) {
        pipeline_error_bar_->hide();
        return;
    }
    pipeline_error_bar_->setText(QString("%1 · %2")
                                     .arg(QString::fromStdString(scene.title),
                                          QString::fromStdString(scene.pipeline_error)));
    pipeline_error_bar_->show();
}

void Shell::scene_switched() {
    refresh_scenes();
    refresh_files_tree(); // persistent tree: refill for the incoming scene
    update_pipeline_error_bar(); // failure banner follows the active scene
    // CONTROLS page shows the ACTIVE scene's reflected params: invalidate it
    // on scene change (a persistent page would keep the old scene's params).
    // removeWidget shifts later stack indices, which is why pages are held
    // by widget (panel_pages_) and never by index.
    QWidget*& controls = panel_pages_[size_t(Sidebar_Mode::CONTROLS)];
    if (controls) {
        panel_stack_->removeWidget(controls);
        controls->deleteLater();
        controls = nullptr;
    }
    apply_mode(ui.mode); // rebuild active panel for the new scene
    // Editor tabs follow the scene: drop the old unit's clean tabs, load
    // the new unit's files (dirty tabs survive; ied_close_unit rule).
    if (editor_ && !mgr_.scenes.empty()) {
        editor_->rescan();
        const auto& scene = mgr_.scenes[size_t(mgr_.current)];
        editor_->load_unit(QString::fromStdString(scene.title),
                           scene::scene_root_dir(roots_, scene.title).c_str());
    }
}

void Shell::flush_graph_layout() {
    // Only flush when the graph panel is UP: a stale nodes_ list (canvas
    // closed while the scene rebuilt) would downgrade graph.json, dropping
    // reflection-derived pass nodes. The panel's own load_layout re-syncs
    // from the current reflection on every entry; the scene-switch flush in
    // the host stays (it saves the OUTGOING scene's open canvas).
    if (!graph_panel_visible()) return;
    if (graph_view_ && graph_view_->dirty_layout() && !mgr_.scenes.empty()) {
        const auto& scene = mgr_.scenes[size_t(mgr_.current)];
        graph_view_->save_layout(QString::fromStdString(scene.title),
                                 QString::fromStdString(
                                     scene::scene_root_dir(roots_, scene.title)));
        graph_view_->clear_dirty();
    }
}

// ---- Native menubar surface (src/ui/menubar.cpp) ----

void Shell::set_scene_menu(QMenu* menu) {
    scene_menu_ = menu;
    sync_scene_menu();
}

// Mirrors the selector menu's grouping (trails caption, scenes, user scenes)
// into the native Scene menu; one checkable action per scene.
void Shell::sync_scene_menu() {
    if (!scene_menu_) return;
    scene_menu_->clear();
    for (size_t i = 0; i < mgr_.scenes.size(); ++i) {
        QAction* a = scene_menu_->addAction(
            QString::fromStdString(mgr_.scenes[i].title));
        a->setCheckable(true);
        a->setChecked(long(i) == mgr_.current);
        connect(a, &QAction::triggered, this, [this, i] {
            emit scene_selected(int(i));
        });
    }
    if (mgr_.scenes.empty()) {
        QAction* none = scene_menu_->addAction(i18n::tr("scenes"));
        none->setEnabled(false);
    }
}

void Shell::show_mode(Sidebar_Mode mode) {
    ui.mode = mode;
    ui.panel_open = true;
    apply_mode(mode);
}

void Shell::editor_undo_redo(bool redo) {
    if (!editor_) return;
    auto* edit = qobject_cast<QsciScintilla*>(editor_->currentWidget());
    if (!edit) return;
    edit->SendScintilla(redo ? QsciScintillaBase::SCI_REDO
                             : QsciScintillaBase::SCI_UNDO);
}

void Shell::editor_open_find() {
    if (editor_) editor_->open_find();
}

void Shell::editor_zoom(bool in) {
    if (!editor_) return;
    if (in) editor_->zoom_in();
    else editor_->zoom_out();
}

// Shared size picker for the font submenus. Checkable so the current size
// shows its mark.
static void exec_size_menu(QWidget* parent, std::initializer_list<int> sizes,
                           int current, const std::function<void(int)>& apply) {
    QMenu menu(parent);
    for (int pt : sizes) {
        QAction* a = menu.addAction(QString::number(pt) + " pt");
        a->setCheckable(true);
        a->setChecked(current == pt);
        QObject::connect(a, &QAction::triggered, &menu, [apply, pt] { apply(pt); });
    }
    menu.exec(QCursor::pos());
}

void Shell::add_language_menu(QMenu& settings) {
    auto* lang_menu = settings.addMenu(i18n::tr("language"));
    struct Lang { const char* tag; i18n::Language lang; };
    static const Lang langs[] = {{"EN", i18n::Language::EN},
                                 {"ES", i18n::Language::ES},
                                 {"PT", i18n::Language::PT}};
    for (const Lang& l : langs) {
        QAction* a = lang_menu->addAction(l.tag);
        a->setCheckable(true);
        a->setChecked(i18n::app_language == l.lang);
        connect(a, &QAction::triggered, this, [this, l] {
            i18n::set_language(l.lang);
            // Panels rebuild with new strings; topbar tooltips/chrome
            // pick up the new language on next restart.
            apply_mode(ui.mode);
        });
    }
}

void Shell::add_theme_menu(QMenu& settings) {
    auto* theme_menu = settings.addMenu(i18n::tr("theme"));
    struct Theme { const char* name; Editor_Theme theme; };
    static const Theme themes[] = {{"dark", Editor_Theme::DARK},
                                   {"light", Editor_Theme::LIGHT},
                                   {"monokai", Editor_Theme::MONOKAI},
                                   {"solarized", Editor_Theme::SOLARIZED}};
    for (const Theme& t : themes) {
        // plan13 preview: a 3-stripe swatch (panel | text | accent) shows
        // the identity at a glance — set BEFORE switching, from the
        // chrome palette of THAT theme (not the active one).
        const auto swatch = [t] {
            const theme::App_Theme at = theme::App_Theme(int(t.theme));
            QPixmap pm(44, 16);
            QPainter p(&pm);
            const QColor panel = QColor(theme::panel_of(at));
            p.fillRect(0, 0, 16, 16, panel);
            p.fillRect(16, 0, 14, 16, QColor(theme::text_of(at)));
            p.fillRect(30, 0, 14, 16, QColor(theme::accent_of(at)));
            p.end();
            return QIcon(pm);
        }();
        QAction* a = theme_menu->addAction(swatch, t.name);
        a->setCheckable(true);
        a->setChecked(ui.theme == t.theme);
        connect(a, &QAction::triggered, this, [this, t] {
            ui.theme = t.theme;
            persist_prefs();
            // Editor + WHOLE app chrome follow one skin: the editor tabs
            // here, every Qlementine widget + the shell chrome via the
            // App_Theme swap (enum order mirrors Editor_Theme's).
            if (editor_) editor_->set_theme(t.theme);
            theme::set_app_theme(theme::App_Theme(int(t.theme)));
            apply_chrome_theme();
            apply_mode(ui.mode); // current panel rebuilds with new palette
        });
    }
}

// plan9: workspace presets — one checked action per layout, same
// set_layout path as the F6 cycle (state-preserving by construction).
void Shell::add_workspace_menu(QMenu& settings) {
    auto* workspace_menu = settings.addMenu(i18n::tr("workspace"));
    struct Workspace { const char* name; Ui_State::Layout_Preset preset; };
    static const Workspace workspaces[] = {
        {"development", Ui_State::Layout_Preset::Normal},
        {"presentation", Ui_State::Layout_Preset::Presentation},
        {"pipeline", Ui_State::Layout_Preset::Pipeline},
        {"zen", Ui_State::Layout_Preset::Zen},
        {"theater", Ui_State::Layout_Preset::Theater},
        {"mobile", Ui_State::Layout_Preset::Mobile},
    };
    for (const Workspace& w : workspaces) {
        QAction* a = workspace_menu->addAction(w.name);
        a->setCheckable(true);
        a->setChecked(ui.layout == w.preset);
        connect(a, &QAction::triggered, this,
                [this, w] { set_layout(w.preset); });
    }
}

void Shell::add_font_actions(QMenu& settings) {
    connect(settings.addAction(i18n::tr("editor font")), &QAction::triggered,
            this, [this] {
        exec_size_menu(this, {10, 12, 14, 16, 18, 20, 24, 28},
                       int(ui.editor_font), [this](int pt) {
            ui.editor_font = pt;
            persist_prefs();
            if (editor_) editor_->set_editor_font(pt);
        });
    });
    // Pixel face for the code editor: Sergamon (the branding bitmap font)
    // instead of JetBrains Mono. Experimental; persisted in ui.prefs.
    auto* pixel = settings.addAction(i18n::tr("pixel code font"));
    pixel->setCheckable(true);
    pixel->setChecked(ui.editor_pixel_font);
    connect(pixel, &QAction::toggled, this, [this](bool on) {
        ui.editor_pixel_font = on;
        persist_prefs();
        if (editor_) editor_->set_pixel_font(on);
    });
    connect(settings.addAction(i18n::tr("ui font")), &QAction::triggered,
            this, [this] {
        exec_size_menu(this, {12, 13, 14, 16, 18, 20, 22},
                       int(ui.font_size), [this](int pt) {
            ui.font_size = pt;
            persist_prefs();
            // The "ui font" was persisted but never applied: the app
            // font was hardcoded code_font(12) in apply_palette.
            qApp->setFont(theme::ui_font(pt));
            // QSS font-size overrides would still pin widget text;
            // rebuilt panels drop their stylesheets, so scale
            // follows the app font (also fixes stale styles).
            apply_mode(ui.mode);
        });
    });
}

// Settings menu: shared by the strip gear and the menubar's Preferences
// (Cmd+,). Both surfaces show the same language/theme/font options.
void Shell::open_settings_menu() {
    // W4: the gear announces the active state (theme · editor font · lang)
    // so the tooltip doubles as a wayfinding summary.
    static const char* theme_names[] = {"dark", "light", "monokai", "solarized"};
    gear_btn_->setToolTip(QString("settings · %1 · %2pt · %3")
                              .arg(theme_names[int(ui.theme)])
                              .arg(int(ui.editor_font))
                              .arg(i18n::app_language == i18n::Language::EN ? "EN"
                                   : i18n::app_language == i18n::Language::ES ? "ES"
                                                                              : "PT"));
    QMenu settings(this);
    add_language_menu(settings);
    add_theme_menu(settings);
    add_workspace_menu(settings);
    add_font_actions(settings);
    settings.exec(QCursor::pos());
}

} // namespace shell
