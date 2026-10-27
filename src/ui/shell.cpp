// Shell implementation: title bar, strip, panels, prefs, modes.
#include "shell.hpp"
#include "i18n.hpp"
#include "notify.hpp"
#include "theme.hpp"

#include <QCheckBox>
#include <QColorDialog>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFileDialog>
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
#include <QSpinBox>
#include <QTimer>
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

#include <algorithm>
#include <climits>
#include <cstdio>
#include <fstream>
#include <dirent.h>
#include <fstream>
#include <sstream>

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
static const char* USER_SCENES_DIR_const = "gis_scenes";

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
        } else if (key == "ui_font") {
            ui.font_size = std::clamp(std::atof(value.c_str()), 12.0, 22.0);
        } else if (key == "panel_width") {
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
      << "ui_font=" << int(ui.font_size) << "\n"
      << "panel_width=" << (ui.user_w > 0 ? buf : "") << "\n";
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

// qlementine icons ship black SVGs; recolor via Source+SourceIn.
// qlementine's 24px set is partial (158 of ~870 icons); fall back to the 16px SVG.
static QIcon tinted_icon(const char* resource, const QColor& color, int size = kStripIcon) {
    QString path = resource;
    if (!QFile::exists(path)) path.replace("/24/", "/16/");
    // Render at 2x and TAG the pixmap with devicePixelRatio 2: without the
    // tag Qt sees a 48 LOGICAL px glyph inside the 24 px button and paints
    // it from the top-left corner (the "icon in the corner" bug). With the
    // tag the 48 device px map to 24 logical px, centered by the style.
    QPixmap src = QIcon(path).pixmap(size * 2, size * 2);
    src.setDevicePixelRatio(2.0);
    QImage tint(src.size(), QImage::Format_ARGB32_Premultiplied);
    tint.setDevicePixelRatio(2.0);
    tint.fill(Qt::transparent);
    QPainter p(&tint);
    p.setCompositionMode(QPainter::CompositionMode_Source);
    p.drawPixmap(0, 0, src);
    p.setCompositionMode(QPainter::CompositionMode_SourceIn);
    p.fillRect(tint.rect(), color); // recolor keeping the SVG alpha
    p.end();
    QPixmap out = QPixmap::fromImage(tint);
    out.setDevicePixelRatio(2.0);
    return QIcon(out);
}

static const char* kIconColor = "#dfe0e6";

QString panel_width_for(const Ui_State& ui, Sidebar_Mode mode, int display_w) {
    if (ui.user_w > 0)
        return QString::number(std::clamp(ui.user_w, 220.0f, display_w * 0.85f), 'f', 0);
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
    return QString("QWidget { background: %1; }"
                   "QPushButton { background: rgba(255,255,255,0.05); border: none;"
                   " border-radius: 5px; padding: 4px 12px; color: %2;"
                   " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
                   "QPushButton:hover { background: rgba(255,255,255,0.12); }"
                   "QPushButton:focus { border: 1px solid %3; }")
        .arg(theme::surface_bench(), theme::text_primary(), theme::safelight());
}
static QString strip_qss() {
    return QString("QWidget { background: %1; }"
                   "QPushButton { border: 1px solid transparent;"
                   " background: transparent; border-radius: 8px; }"
                   "QPushButton:hover { background: rgba(255,255,255,0.07); }"
                   "QPushButton[active=\"true\"] {"
                   " background: rgba(255,255,255,0.10); }"
                   "QPushButton:focus { border: 1px solid %2; }")
        .arg(theme::surface_bench(), theme::safelight());
}
static QString panel_qss() {
    return QString("QWidget { background: %1; color: %2; font-size: 9pt; }"
                   "QPushButton { background: rgba(255,255,255,0.06); border: none;"
                   " border-radius: 4px; padding: 4px 8px; }"
                   "QPushButton:hover { background: rgba(255,255,255,0.12); }"
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
             theme::safelight(), "#131418", theme::control_border());
}
static QString panel_edge_qss() {
    return QString("QPushButton#panelEdge { background: rgba(232,168,87,0.14);"
                   " border: none; border-radius: 3px; color: %1; font-size: 9pt; }"
                   "QPushButton#panelEdge:hover { background: rgba(232,168,87,0.38); }")
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
    const bool shell_null = qEnvironmentVariableIsSet("GIS_SHELL_NULL");
    const bool no_strip = qEnvironmentVariableIsSet("GIS_SKIP_STRIP");
    const bool no_panel = qEnvironmentVariableIsSet("GIS_SKIP_PANEL");

    if (shell_null) return; // bisect: bare widget, no UI built
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
    // pushes NOTHING down. Qt::ToolTip keeps it click-through-free without
    // stealing focus; parent Shell keeps it inside our frameless window.
    scene_list_->setWindowFlags(Qt::Widget);
    scene_list_->setAutoFillBackground(true);
    scene_list_->hide();
    auto* body = new QHBoxLayout();
    body->setContentsMargins(0, 0, 0, 0);
    body->setSpacing(0);
    if (!no_strip) body->addWidget(strip());
    sdl_host_ = new QWidget(this);
    sdl_host_->setAttribute(Qt::WA_NativeWindow); // own NSView to host SDL
    // Sidebar on the LEFT (next to the strip), per the layout contract; the
    // editor owns the rest of the window permanently.
    if (!no_panel) body->addWidget(panel());      // fixed width via apply_mode
    central_ = new QStackedWidget(this);
    central_->addWidget(editor_dock());           // page 0: code editor (always)
    central_->addWidget(sdl_host_);               // page 1: fullscreen viewport (zen)
    central_->setCurrentIndex(0);
    body->addWidget(central_, 1);                 // elastic center
    outer->addLayout(body, 1);
    if (!no_panel) apply_mode(ui.mode);

    // Graph layout autosave: every 10 s (the Odin 600-frame tick) and on
    // quit. Scene switch flushes separately in the host's scene_selected.
    if (!qEnvironmentVariableIsSet("GIS_NO_AUTOSAVE")) {
        auto* autosave = new QTimer(this);
        autosave->setInterval(10000);
        connect(autosave, &QTimer::timeout, this, &Shell::flush_graph_layout);
        autosave->start();
        connect(qApp, &QCoreApplication::aboutToQuit, this, &Shell::flush_graph_layout);
    }
    // Tab order (P1 audit): top bar left→right, then the mode strip. The
    // panel content rebuilds per mode, so its widgets inherit the default
    // (visual) order — fine, it is recreated after each apply_mode.
    if (!no_strip && !no_panel && selector_btn_ && save_btn_ && pause_btn_ &&
        !strip_buttons_.empty()) {
        setTabOrder(selector_btn_, save_btn_);
        setTabOrder(save_btn_, pause_btn_);
        setTabOrder(pause_btn_, strip_buttons_.front());
        for (size_t i = 1; i < strip_buttons_.size(); ++i)
            setTabOrder(strip_buttons_[i - 1], strip_buttons_[i]);
    }
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
    // input.ini as the single key source (BUG-10). Window-mode actions bind
    // here; editor chords stay Qt-native (Find/Ctrl+G/Escape).
    auto bind_action = [this](const char* action, const char* fallback,
                              void (Shell::*slot)()) {
        QVector<QKeySequence> seqs = input_map::load("assets/input.ini", action);
        if (seqs.isEmpty()) seqs.push_back(QKeySequence(fallback)); // ini fallback
        for (const QKeySequence& seq : seqs)
            connect(new QShortcut(seq, this), &QShortcut::activated, this, slot);
    };
    bind_action("toggle_zen", "F1", &Shell::toggle_zen);
    bind_action("toggle_editor", "F2", &Shell::toggle_editor);
    bind_action("toggle_theater", "F4", &Shell::toggle_theater);
    bind_action("toggle_mobile", "F5", &Shell::toggle_mobile);
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
    if (!qEnvironmentVariableIsSet("GIS_SKIP_REFRESH")) refresh_scenes();
    // Outside-click dismissal for the floating scene list: the list is a
    // plain overlay (not a native popup), so a press on ANY other widget
    // must close it. Application-level filter watches every press.
    qApp->installEventFilter(this);
}


void Shell::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    // GRAPH panel width depends on window width (0: full-width canvas) and
    // panel_width_for clamps user_w to a width fraction. Re-running
    // apply_mode on every resize would rebuild the panel content, so only
    // the user-width clamp needs the refresh; the default per-mode widths
    // are constants. Keep apply_mode out of the resize path.
    update_panel_edge();
}

// ---- Panel resize (drag the right panel's left edge) ----

// The drag zone is a 6px band on the panel's left edge (inside the panel
// AND the window edge beside it, so the grab is forgiving).
bool Shell::panel_resize_hit(const QPoint& global_pos) const {
    if (!panel_ || !panel_->isVisible() || ui.mode == Sidebar_Mode::GRAPH)
        return false;
    const int edge = panel_->mapToGlobal(QPoint(0, 0)).x();
    return qAbs(global_pos.x() - edge) <= 3;
}

void Shell::mousePressEvent(QMouseEvent* event) {
    const QPoint gp = event->globalPosition().toPoint();
    if (event->button() == Qt::LeftButton && panel_resize_hit(gp)) {
        panel_dragging_ = true;
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
bool Shell::eventFilter(QObject* watched, QEvent* event) {
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
    if (watched == topbar_ && event->type() == QEvent::MouseButtonPress) {
        auto* me = static_cast<QMouseEvent*>(event);
        if (me->button() == Qt::LeftButton) {
            QWidget* hit = topbar_->childAt(me->position().toPoint());
            if (!hit && windowHandle() && windowHandle()->startSystemMove())
                return true; // drag consumed the press
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
        w = std::clamp(w, 220.0f, width() * 0.85f);
        ui.user_w = w; // persisted by prefs_save on quit/settings
        panel_->setFixedWidth(int(w));
        event->accept();
        return;
    }
    // Affordance: stretch cursor on the hit band.
    setCursor(panel_resize_hit(gp) ? Qt::SplitHCursor : Qt::ArrowCursor);
    QWidget::mouseMoveEvent(event);
}


void Shell::mouseReleaseEvent(QMouseEvent* event) {
    if (panel_dragging_) {
        prefs_save(ui);
        panel_dragging_ = false;
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
    const QString dir = QString("%1/%2").arg(USER_SCENES_DIR_const).arg(name);
    const bool dir_ok = QDir().mkpath(dir);
    QFile f(dir + "/" + name + ".slang");
    if (!dir_ok || !f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        notify::notify(notify::Kind::ERROR_, QString("scene create failed: %1").arg(dir));
        return;
    }
    f.write("// New 2D graphics scene.\nimport \"../../src/shaders/common\";\n");
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
    if (selector_btn_)
        selector_btn_->setText(mgr_.scenes.empty()
                                   ? "?"
                                   : QString::fromStdString(mgr_.scenes[size_t(mgr_.current)].title));
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
    scene_list_layout_->addStretch(1);
    scene_list_->setFixedHeight(std::min(
        420, int(scene_list_->sizeHint().height())));
    // Overlay geometry: right-aligned under the top bar, above everything.
    scene_list_->setParent(this);
    scene_list_->setGeometry(width() - 280, kTopbarH, 280,
                             scene_list_->height());
    scene_list_->raise();
    scene_list_->show();
}

// ---- Top bar (macOS style) ----

QWidget* Shell::topbar() {
    if (topbar_) return topbar_;
    topbar_ = new QWidget(this);
    topbar_->installEventFilter(this); // background press = window drag
    topbar_->setFixedHeight(kTopbarH);
    topbar_->setStyleSheet(topbar_qss());
    auto* layout = new QHBoxLayout(topbar_);
    // Left margin clears the NATIVE traffic lights (~70px from the window
    // edge under the transparent title bar); the window supplies them now.
    layout->setContentsMargins(80, 0, 12, 0);
    layout->setSpacing(8);

    selector_btn_ = new QPushButton("…", topbar_);
    connect(selector_btn_, &QPushButton::clicked, this, [this] {
        // Lazy menu: a QMenu alive at shell.show() gets polished by
        // Qlementine, whose polishMenu has a use-after-free when the menu
        // is re-polished during the show pass (ASan-proven). The menu is
        // only needed on the first click — create it here, once.
        if (!selector_menu_) selector_menu_ = new QMenu(selector_btn_);
        // Inline scene list docked UNDER the top bar: native QMenu/Qt::Popup
        // windows lose the mouse to the frameless-window coordinate drift
        // and to the SDL child racing (both proven in this build); an
        // in-layout panel uses the exact widget pipeline the top bar and
        // strip already use, which works.
        rebuild_selector_menu();
        show_scene_list(!scene_list_ || !scene_list_->isVisible());
    });
    layout->addWidget(selector_btn_);

    auto* new_btn = new QPushButton(i18n::tr("+ new"), topbar_);
    connect(new_btn, &QPushButton::clicked, this, &Shell::create_scene_dialog);
    layout->addWidget(new_btn);
    layout->addStretch(1);

    // Save + pause: window-level actions in the chrome (the strip keeps
    // only mode navigation + settings). Cmd+S lives in the native File menu
    // (menubar.cpp) — no in-window QShortcut, or the key would fire twice.
    save_btn_ = new QPushButton(topbar_);
    save_btn_->setIcon(tinted_icon(":/qlementine/icons/24/action/save-all.svg",
                                   QColor(kIconColor)));
    save_btn_->setIconSize(QSize(kStripIcon, kStripIcon));
    save_btn_->setFixedSize(kStripButton, kStripButton);
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
                                    QColor(kIconColor)));
    pause_btn_->setIconSize(QSize(kStripIcon, kStripIcon));
    pause_btn_->setFixedSize(kStripButton, kStripButton);
    pause_btn_->setToolTip(i18n::tr("pause"));
    pause_btn_->setAccessibleName(i18n::tr("pause"));
    pause_btn_->setFocusPolicy(Qt::TabFocus);
    connect(pause_btn_, &QPushButton::clicked, this, [this] {
        ui.paused = !ui.paused;
        pause_btn_->setIcon(tinted_icon(
            ui.paused ? ":/qlementine/icons/24/media/play.svg"
                      : ":/qlementine/icons/24/media/pause.svg",
            QColor(kIconColor)));
        pause_btn_->setToolTip(ui.paused ? i18n::tr("play") : i18n::tr("pause"));
        pause_btn_->setAccessibleName(ui.paused ? i18n::tr("play")
                                                 : i18n::tr("pause"));
        emit pause_toggled();
    });
    layout->addWidget(pause_btn_);
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
    const char* icons[5] = {
        ":/qlementine/icons/24/file/folder.svg",
        ":/qlementine/icons/24/misc/items-tree.svg",
        ":/qlementine/icons/24/navigation/sliders-horizontal.svg",
        ":/qlementine/icons/24/action/download.svg",
        ":/qlementine/icons/24/hardware/keyboard.svg",
    };
    for (int i = 0; i < 5; ++i) {
        auto* btn = new QPushButton(strip_);
        btn->setIcon(tinted_icon(icons[i], QColor(kIconColor)));
        btn->setIconSize(QSize(kStripIcon, kStripIcon));
        btn->setFixedSize(kStripButton, kStripButton);
        btn->setToolTip(mode_name(modes[i]));
        btn->setAccessibleName(mode_name(modes[i]));
        btn->setFocusPolicy(Qt::TabFocus);
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
        ":/qlementine/icons/24/navigation/settings.svg", QColor(kIconColor)));
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

    auto* hex = new QLabel(color.name().toUpper().mid(1), row); // no '#': the swatch shows the color
    hex->setStyleSheet("color: #8c9099; font-family: 'JetBrains Mono', monospace;");
    hex->setCursor(Qt::PointingHandCursor);

    auto open_picker = [scene, label = widget.label, swatch, hex, paint_swatch, color]() {
        QColor picked = QColorDialog::getColor(color, swatch, QObject::tr("pick color"));
        if (!picked.isValid()) return;
        // Resolve the widget at fire time: the panel can outlive a
        // hot-reload scene swap that rebuilt scene.widgets.
        for (auto& wgt : scene->widgets)
            if (wgt.label == label) {
                wgt.value[0] = picked.redF();
                wgt.value[1] = picked.greenF();
                wgt.value[2] = picked.blueF();
                break;
            }
        paint_swatch(picked);
        hex->setText(picked.name().toUpper().mid(1));
    };
    QObject::connect(swatch, &QPushButton::clicked, swatch, open_picker);
    QObject::connect(hex, &QLabel::linkActivated, hex, open_picker); // click the hex opens too

    layout->addWidget(swatch);
    layout->addWidget(hex);
    layout->addStretch(1);
    return row;
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
            QString label = QString::fromStdString(widget.label);
            switch (widget.kind) {
            case scene::Uniform_Widget::Kind::SLIDER: {
                auto* slider = new QDoubleSpinBox(w);
                slider->setRange(widget.min, widget.max);
                slider->setSingleStep(widget.step);
                slider->setValue(widget.value[0]);
                slider->setDecimals(2);
                connect(slider, &QDoubleSpinBox::valueChanged, this,
                        [scene, label](double v) {
                            // Resolve the widget at fire time: the panel can
                            // outlive a hot-reload scene swap that rebuilt
                            // scene.widgets (captured refs would dangle).
                            for (auto& wgt : scene->widgets)
                                if (wgt.label == label.toStdString()) { wgt.value[0] = float(v); break; }
                        });
                auto* row = new QHBoxLayout();
                row->addWidget(new QLabel(label));
                row->addWidget(slider, 1);
                layout->addLayout(row);
                break;
            }
            case scene::Uniform_Widget::Kind::TOGGLE: {
                auto* check = new QCheckBox(label, w);
                check->setChecked(widget.on);
                connect(check, &QCheckBox::toggled, this, [scene, label](bool on) {
                    for (auto& wgt : scene->widgets)
                        if (wgt.label == label.toStdString()) { wgt.on = on; break; }
                });
                layout->addWidget(check);
                break;
            }
            case scene::Uniform_Widget::Kind::COLOR: {
                // Swatch + hex row (the darkroom picker): the swatch IS the
                // button, the hex value sits right of it; clicking the swatch
                // opens the color dialog. No three spinboxes.
                layout->addWidget(make_color_row(scene, widget));
                break;
            }
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
        "QLabel#pipelineErrorBar { background: rgba(242,107,92,0.16);"
        " color: #F26B5C; padding: 4px 12px; font-size: 9pt; }");
    pipeline_error_bar_->setWordWrap(true);
    pipeline_error_bar_->hide();
    layout->addWidget(pipeline_error_bar_);
    editor_ = new editor::Editor(editor_dock_);
    editor_->set_theme(ui.theme); // persisted prefs decide the first skin
    editor_->set_editor_font(int(ui.editor_font)); // prefs persist the size
    editor_->set_pixel_font(ui.editor_pixel_font); // prefs persist the face
    connect(editor_, &editor::Editor::font_changed, this, [this](int pt) {
        ui.editor_font = pt; // Cmd+= / Cmd+- update the persisted size
        prefs_save(ui);
    });
    // Split (code | preview): the host reads shell.ui.editor_split each
    // tick and shapes the SDL preview window accordingly.
    connect(editor_, &editor::Editor::split_toggled, this, [this](bool on) {
        ui.editor_split = on;
    });
    editor_->rescan();
    if (!mgr_.scenes.empty()) {
        const auto& scene = mgr_.scenes[size_t(mgr_.current)];
        editor_->load_unit(QString::fromStdString(scene.title),
                           scene::scene_root_dir(roots_, scene.title).c_str());
    }
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

QWidget* Shell::graph_view() {
    if (!graph_view_) graph_view_ = new graph_editor::Node_View(this);
    return graph_view_;
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
    auto file_icon = [](const QString& path) -> QIcon {
        const QString suffix = QFileInfo(path).suffix().toLower();
        const char* res = ":/qlementine/icons/16/file/file.svg";
        if (suffix == "slang") res = ":/qlementine/icons/16/file/file-script.svg";
        else if (suffix == "json") res = ":/qlementine/icons/16/file/markup.svg";
        else if (suffix == "png" || suffix == "jpg" || suffix == "jpeg")
            res = ":/qlementine/icons/16/file/picture.svg";
        else if (suffix == "glb" || suffix == "gltf" || suffix == "obj")
            res = ":/qlementine/icons/16/shape/cube.svg";
        return tinted_icon(res, QColor(theme::text_muted()), 14);
    };
    enum Kind { kShader, kGraph, kAsset };
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
                        const QString& rel, Kind kind) {
        auto* item = new QTreeWidgetItem(parent, QStringList{name});
        item->setData(0, Qt::UserRole, rel);
        item->setData(0, Qt::UserRole + 1, (int)kind);
        item->setIcon(0, file_icon(rel));
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
        "QTreeWidget { background: transparent; border: none;"
        " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
        "QTreeWidget::item { height: 22px; }"
        "QTreeWidget::item:selected { background: rgba(232,168,87,0.22); color: #DEE0E6; }"
        "QTreeWidget::item:hover { background: rgba(255,255,255,0.06); }"
        "QTreeWidget::branch { background: transparent; }");

    // Click routing: shader leaves open in the editor; graph.json flips to
    // the GRAPH mode; assets are context-only (no dead-end affordance).
    enum Kind { kShader, kGraph, kAsset };
    connect(tree, &QTreeWidget::itemClicked, this,
            [this](QTreeWidgetItem* item, int) {
        QString rel = item->data(0, Qt::UserRole).toString();
        int kind = item->data(0, Qt::UserRole + 1).toInt();
        if (rel.isEmpty()) return;
        if (kind == kGraph) {
            ui.mode = Sidebar_Mode::GRAPH;
            ui.panel_open = true;
            apply_mode(ui.mode);
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
            ui.mode = Sidebar_Mode::GRAPH;
            ui.panel_open = true;
            apply_mode(ui.mode);
        }
    });

    // ---- Rename (context menu on shader leaves of user-owned scenes) ----
    // Builtin scenes live in the repo: renaming there is refused with a hint.
    connect(tree, &QTreeWidget::customContextMenuRequested, this,
            [this](const QPoint& pos) {
        QTreeWidget* tree = qobject_cast<QTreeWidget*>(sender());
        QTreeWidgetItem* item = tree->itemAt(pos);
        if (!item) return;
        int kind = item->data(0, Qt::UserRole + 1).toInt();
        if (kind != kShader) return; // folders, graph, assets: no rename
        QString rel = item->data(0, Qt::UserRole).toString();
        if (!rel.startsWith("scenes/")) return; // shared modules: repo-owned
        QString scene = rel.section('/', 1, 1);
        bool user_owned = scene::scene_root_dir(roots_, scene.toStdString()) == "gis_scenes";

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
        // commitData (below) handles the disk rename; flags reset there.
    });
    // Commit: rename on disk, preserve extension, rescan everything.
    connect(tree, &QTreeWidget::itemChanged, this, [this](QTreeWidgetItem* item, int col) {
        if (col != 0) return;
        auto* tree = qobject_cast<QTreeWidget*>(sender());
        if (!tree) return;
        // itemChanged fires for programmatic setText too (restore paths):
        // only treat it as a rename attempt when the label differs from the
        // stored rel's base name; restores land here as a no-op.
        int kind = item->data(0, Qt::UserRole + 1).toInt();
        QString rel = item->data(0, Qt::UserRole).toString();
        if (kind != kShader || !rel.startsWith("scenes/")) return;
        QString scene = rel.section('/', 1, 1);
        if (scene::scene_root_dir(roots_, scene.toStdString()) != "gis_scenes") return;
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
        item->setText(0, new_base);
        item->setData(0, Qt::UserRole, "scenes/" + scene + "/" + new_base);
        if (editor_) editor_->rescan();
        // O3: flash the renamed row amber, then fade back to muted —
        // confirms WHERE the change landed (the toast only says THAT).
        item->setForeground(0, QColor(0xE8, 0xA8, 0x57));
        QTreeWidgetItem* flash_item = item;
        QTimer::singleShot(1200, tree, [flash_item, tree] {
            if (tree) flash_item->setForeground(0, QColor(theme::text_primary()));
        });
        notify::notify(notify::Kind::INFO,
                       i18n::tr("renamed %s → %s")
                           .replace("%s", old_base).replace("%s", new_base));
    });

    refresh_files_tree();
    layout->addWidget(files_tree_, 1);
    return w;
}

QWidget* Shell::learn_panel() {
    // One persistent view; the panel's content widget is deleted on every
    // apply_mode, so the view is re-parented in, not recreated (page state
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
        chip->setStyleSheet("color: #d7dae2; font-weight: 600;");
        auto* desc_label = new QLabel(desc);
        desc_label->setWordWrap(true);
        line->addWidget(chip);
        line->addWidget(desc_label, 1);
        layout->addLayout(line, 0); // rows pack at the top; stretch at end
    };
    layout->addWidget(caption(i18n::tr("window")), 0);
    row("F1", i18n::tr("zen mode: toggle sidebar + editor"));
    row("F2", i18n::tr("toggle shader editor"));
    row("F3", i18n::tr("toggle floating preview"));
    row("F4", i18n::tr("theater mode"));
    row("F5", i18n::tr("mobile theater (9:16)"));
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
void Shell::set_layout(Ui_State::Layout_Preset preset) {
    if (ui.layout == preset) {
        set_layout(Ui_State::Layout_Preset::Normal); // toggle off -> Normal
        return;
    }
    // Leaving any active preset: restore the Normal-state values.
    if (ui.layout != Ui_State::Layout_Preset::Normal) {
        ui.font_size = ui.saved_ui_font;
        ui.editor_font = ui.saved_ed_font;
        if (editor_) editor_->set_editor_font(int(ui.saved_ed_font));
        ui.panel_open = ui.saved_open;
    }
    ui.layout = preset;
    if (preset == Ui_State::Layout_Preset::Normal) {
        ui.sidebar_open = true;
        if (strip_) strip_->setVisible(true);
        show_editor(true);
    } else if (preset == Ui_State::Layout_Preset::Zen) {
        // F1: sidebar (strip + panel) gone, fullscreen viewport.
        ui.saved_ui_font = ui.font_size;
        ui.saved_ed_font = ui.editor_font;
        ui.saved_open = ui.panel_open;
        ui.sidebar_open = false;
        if (strip_) strip_->setVisible(false);
        ui.panel_open = false;
        show_editor(false);
    } else if (preset == Ui_State::Layout_Preset::Theater ||
               preset == Ui_State::Layout_Preset::Mobile) {
        // F4 bigger type + chrome hidden / F5 9:16 portrait. Theater and
        // Mobile share the chrome path; only the host's window aspect
        // differs (Mobile signals it via ui.layout for the resize).
        ui.saved_ui_font = ui.font_size;
        ui.saved_ed_font = ui.editor_font;
        ui.saved_open = ui.panel_open;
        ui.font_size = 18;
        ui.editor_font = 21;
        if (editor_) editor_->set_editor_font(21);
        ui.panel_open = false;
        show_editor(true);
    }
    apply_mode(ui.mode);
}

void Shell::toggle_editor() {
    // F2: flip between the always-on editor (PiP preview floating) and a
    // fullscreen viewport page.
    bool editor_up = central_ && central_->currentIndex() == 0;
    show_editor(!editor_up);
}

graph_editor::Node_View* Shell::graph_view_typed() {
    if (!graph_view_) graph_view_ = new graph_editor::Node_View(this);
    return graph_view_;
}

void Shell::animate_panel_to(int target_w) {
    if (!panel_) return;
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
    // Instances are per-run, DeleteWhenStopped (no member state to race).
    auto* anim = new QVariantAnimation(this);
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
    const QColor icon(kIconColor);
    if (save_btn_)
        save_btn_->setIcon(tinted_icon(":/qlementine/icons/24/action/save-all.svg",
                                       icon));
    if (pause_btn_)
        pause_btn_->setIcon(tinted_icon(ui.paused
                                            ? ":/qlementine/icons/24/media/play.svg"
                                            : ":/qlementine/icons/24/media/pause.svg",
                                        icon));
    if (gear_btn_)
        gear_btn_->setIcon(tinted_icon(
            ":/qlementine/icons/24/navigation/settings.svg", icon));
    for (auto* btn : strip_buttons_) btn->update();
    update();
}

void Shell::apply_mode(Sidebar_Mode mode) {
    // Mode switch owns the canvas: the floating scene list would otherwise
    // strand over the new panel (no native popup auto-dismiss here).
    if (scene_list_ && scene_list_->isVisible()) show_scene_list(false);
    // Strip checked states: exactly one button mirrors (mode, panel_open).
    // The click already flipped Qt's own checked flag, so set ALL buttons
    // explicitly here: no stale "active" marks survive the pass.
    for (size_t i = 0; i < strip_buttons_.size(); ++i) {
        bool active = Sidebar_Mode(i) == mode && ui.panel_open;
        if (strip_buttons_[i]->property("active").toBool() != active) {
            strip_buttons_[i]->setProperty("active", active);
            // Repolish: the stylesheet selector [active="true"] only
            // re-evaluates when the style is invalidated.
            strip_buttons_[i]->style()->unpolish(strip_buttons_[i]);
            strip_buttons_[i]->style()->polish(strip_buttons_[i]);
            strip_buttons_[i]->update();
        }
    }

    // Persistent pages: build each mode's panel ONCE, then flip the stack
    // index. Tree expand state, selection, scroll position and form edits
    // all survive mode switches (the old clear-and-rebuild destroyed them).
    // Page order mirrors Sidebar_Mode's enum order; LEARN/EFFECTS keep their
    // pages for menu access, they just have no strip button.
    auto ensure_page = [this](Sidebar_Mode mode) -> QWidget* {
        int idx = panel_page_index_[(size_t)mode];
        if (idx >= 0) return panel_stack_->widget(idx);
        QWidget* page = nullptr;
        switch (mode) {
        case Sidebar_Mode::CONTROLS: page = controls_panel(); break;
        case Sidebar_Mode::FILES: page = files_panel(); break;
        case Sidebar_Mode::LEARN: page = learn_panel(); break;
        case Sidebar_Mode::GRAPH: page = graph_view(); break;
        case Sidebar_Mode::EXPORT: page = export_panel(); break;
        case Sidebar_Mode::EFFECTS: page = effects_panel(); break;
        case Sidebar_Mode::SHORTCUTS: page = shortcuts_panel(); break;
        }
        if (!page) return nullptr;
        idx = panel_stack_->addWidget(page);
        panel_page_index_[(size_t)mode] = idx;
        return page;
    };
    if (!ui.panel_open) {
        animate_panel_to(0);
        if (central_ && central_->layout()) central_->layout()->activate();
        return;
    }
    int target = panel_width_for(ui, mode, this->width()).toInt();
    animate_panel_to(target);
    if (central_ && central_->layout()) central_->layout()->activate();
    if (central_) central_->setCurrentIndex(0); // editor page, always
    QWidget* page = ensure_page(mode);
    if (page) {
        // Scene-bound pages refresh their data on entry (cheap, in-place).
        if (mode == Sidebar_Mode::GRAPH && !mgr_.scenes.empty()) {
            const auto& scene = mgr_.scenes[size_t(mgr_.current)];
            graph_view_->set_scene(scene);
            graph_view_->load_layout(QString::fromStdString(scene.title),
                                     QString::fromStdString(
                                         scene::scene_root_dir(roots_, scene.title)),
                                     scene);
        }
        page->show();
        panel_stack_->setCurrentWidget(page);
    }
    emit mode_changed(mode);
}

// Bake feedback: an amber dot rides the save button while a scene build is
// running (the save → 1-3 s silence → preview-jump loop needed visible state).
void Shell::set_baking(bool on) {
    if (!save_btn_) return;
    const QString prop = on ? "1" : "0";
    if (save_btn_->property("baking") == prop) return;
    save_btn_->setProperty("baking", prop);
    // Restyle: amber border while baking; none when idle.
    save_btn_->setStyleSheet(on ? "QPushButton { border: 1px solid #E8A857; }"
                                : "QPushButton { border: none; }");
    save_btn_->style()->unpolish(save_btn_);
    save_btn_->style()->polish(save_btn_);
    save_btn_->update();
    if (!on) update_pipeline_error_bar(); // bake finished: surface failures
}

// O2: PiP context label — parked on the preview's top edge, shows WHAT is
// rendering and at WHICH resolution. Global rect in Qt coords (top-left
// origin); the host converts from the Cocoa PiP rect each tick.
void Shell::set_pip_overlay(const QString& text, const QRect& global_rect) {
    if (!pip_overlay_) {
        pip_overlay_ = new QLabel(this);
        pip_overlay_->setObjectName("pipOverlay");
        pip_overlay_->setStyleSheet(
            "QLabel#pipOverlay { background: rgba(19,20,24,200);"
            " color: #828894; padding: 2px 8px; font-size: 8pt;"
            " font-family: 'JetBrains Mono', monospace;"
            " border-radius: 3px; }");
        pip_overlay_->setAttribute(Qt::WA_TransparentForMouseEvents);
    }
    if (text.isEmpty() || global_rect.isEmpty()) {
        pip_overlay_->hide();
        return;
    }
    pip_overlay_->setText(text);
    pip_overlay_->adjustSize();
    // Top-left INSIDE the PiP, 6px inset (reads as a caption, not chrome).
    pip_overlay_->move(global_rect.topLeft() + QPoint(6, 6));
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
    int& controls_idx = panel_page_index_[(size_t)Sidebar_Mode::CONTROLS];
    if (controls_idx >= 0) {
        QWidget* old = panel_stack_->widget(controls_idx);
        panel_stack_->removeWidget(old);
        if (old) old->deleteLater();
        controls_idx = -1;
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

// Settings menu: shared by the strip gear and the menubar's Preferences
// (Cmd+,). Extracted from the gear lambda so both surfaces show the same
// language/theme/font options.
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
    auto* theme_menu = settings.addMenu(i18n::tr("theme"));
    struct Theme { const char* name; Editor_Theme theme; };
    static const Theme themes[] = {{"dark", Editor_Theme::DARK},
                                   {"light", Editor_Theme::LIGHT},
                                   {"monokai", Editor_Theme::MONOKAI},
                                   {"solarized", Editor_Theme::SOLARIZED}};
    for (const Theme& t : themes) {
        QAction* a = theme_menu->addAction(t.name);
        a->setCheckable(true);
        a->setChecked(ui.theme == t.theme);
        connect(a, &QAction::triggered, this, [this, t] {
            ui.theme = t.theme;
            prefs_save(ui);
            // Editor + WHOLE app chrome follow one skin: the editor tabs
            // here, every Qlementine widget + the shell chrome via the
            // App_Theme swap (enum order mirrors Editor_Theme's).
            if (editor_) editor_->set_theme(t.theme);
            theme::set_app_theme(theme::App_Theme(int(t.theme)));
            apply_chrome_theme();
            apply_mode(ui.mode); // current panel rebuilds with new palette
        });
    }
    connect(settings.addAction(i18n::tr("editor font")), &QAction::triggered,
            this, [this] {
        QMenu sizes(this);
        for (int pt : {10, 12, 14, 16, 18, 20, 24, 28}) {
            auto* a = sizes.addAction(QString::number(pt) + " pt");
            a->setChecked(int(ui.editor_font) == pt);
            connect(a, &QAction::triggered, this, [this, pt] {
                ui.editor_font = pt;
                prefs_save(ui);
                if (editor_) editor_->set_editor_font(pt);
            });
        }
        sizes.exec(QCursor::pos());
    });
    // Pixel face for the code editor: Sergamon (the branding bitmap font)
    // instead of JetBrains Mono. Experimental; persisted in ui.prefs.
    auto* pixel = settings.addAction(i18n::tr("pixel code font"));
    pixel->setCheckable(true);
    pixel->setChecked(ui.editor_pixel_font);
    connect(pixel, &QAction::toggled, this, [this](bool on) {
        ui.editor_pixel_font = on;
        prefs_save(ui);
        if (editor_) editor_->set_pixel_font(on);
    });
    connect(settings.addAction(i18n::tr("ui font")), &QAction::triggered,
            this, [this] {
        QMenu sizes(this);
        for (int pt : {12, 13, 14, 16, 18, 20, 22}) {
            auto* a = sizes.addAction(QString::number(pt) + " pt");
            a->setChecked(int(ui.font_size) == pt);
            connect(a, &QAction::triggered, this, [this, pt] {
                ui.font_size = pt;
                prefs_save(ui);
                // The "ui font" was persisted but never applied: the app
                // font was hardcoded code_font(12) in apply_palette.
                qApp->setFont(theme::ui_font(pt));
                // QSS font-size overrides would still pin widget text;
                // rebuilt panels drop their stylesheets, so scale
                // follows the app font (also fixes stale styles).
                apply_mode(ui.mode);
            });
        }
        sizes.exec(QCursor::pos());
    });
    settings.exec(QCursor::pos());
}

} // namespace shell
