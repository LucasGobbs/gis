// Native menu bar implementation. macOS: a parentless QMenuBar becomes the
// system menu bar; MenuRole remaps About/Preferences/Quit into the app menu.
// Every label goes through i18n so ES/PT follow the rest of the UI.
#include "menubar.hpp"

#include "i18n.hpp"

#include <QAction>
#include <QActionGroup>
#include <QApplication>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QPointer>

namespace shell {

void build_native_menus(Shell& shell) {
    auto* bar = new QMenuBar(nullptr); // parentless: native menu bar on macOS
#ifdef Q_OS_MACOS
    bar->setNativeMenuBar(true);
#else
    // Windows phase 2: in-window bar, parent it to the shell there.
    bar->setNativeMenuBar(false);
#endif

    // ---- App menu (gis): About, Preferences, Quit ----
    QAction* about = bar->addAction(i18n::tr("about gis"));
    about->setMenuRole(QAction::AboutRole);
    QObject::connect(about, &QAction::triggered, [] {
        QMessageBox::about(nullptr, "gis",
                           "gis — Gobbi Interactive Shaders (Qt port)");
    });
    QAction* prefs = bar->addAction(i18n::tr("settings"));
    prefs->setMenuRole(QAction::PreferencesRole);
    prefs->setShortcut(QKeySequence::Preferences);
    // The gear's menu IS the settings surface; route through the shell.
    QPointer<Shell> sh = &shell;
    QObject::connect(prefs, &QAction::triggered, [sh] {
        if (sh) emit sh->preferences_requested();
    });

    QAction* quit = bar->addAction(i18n::tr("quit"));
    quit->setMenuRole(QAction::QuitRole);
    quit->setShortcut(QKeySequence::Quit);
    QObject::connect(quit, &QAction::triggered,
                     [] { QApplication::quit(); });

    // ---- File ----
    QMenu* file = bar->addMenu(i18n::tr("file"));
    QAction* new_scene = file->addAction(i18n::tr("new scene"));
    new_scene->setShortcut(QKeySequence::New);
    QObject::connect(new_scene, &QAction::triggered, [sh] {
        if (sh) sh->create_scene_dialog();
    });
    QAction* save = file->addAction(i18n::tr("save all"));
    save->setShortcut(QKeySequence::Save);
    QObject::connect(save, &QAction::triggered, [sh] {
        if (sh) emit sh->save_all_requested();
    });
    file->addSeparator();
    QAction* png = file->addAction(i18n::tr("export png"));
    png->setShortcut(QKeySequence("Ctrl+E"));
    QObject::connect(png, &QAction::triggered, [sh] {
        if (sh) emit sh->png_export_requested();
    });
    QAction* gif = file->addAction(i18n::tr("export gif"));
    gif->setShortcut(QKeySequence("Ctrl+G"));
    QObject::connect(gif, &QAction::triggered, [sh] {
        // Menu items carry no parameter: the prefs' stored start/end apply
        // (same values the export panel's button sends).
        if (sh) emit sh->gif_export_requested(sh->ui.gif_start, sh->ui.gif_end);
    });
    file->addSeparator();
    QAction* close = file->addAction(i18n::tr("close"));
    close->setShortcut(QKeySequence::Close);
    QObject::connect(close, &QAction::triggered, [sh] {
        if (sh) emit sh->close_requested();
    });

    // ---- Scene: checkable exclusive list, mirrored from the selector ----
    QMenu* scene = bar->addMenu(i18n::tr("scene"));
    shell.set_scene_menu(scene); // shell repopulates on refresh_scenes()

    // ---- Edit ----
    QMenu* edit = bar->addMenu(i18n::tr("edit"));
    QAction* undo = edit->addAction(i18n::tr("undo"));
    undo->setShortcut(QKeySequence::Undo);
    QObject::connect(undo, &QAction::triggered, [sh] {
        if (sh) sh->editor_undo_redo(false);
    });
    QAction* redo = edit->addAction(i18n::tr("redo"));
    redo->setShortcut(QKeySequence::Redo);
    QObject::connect(redo, &QAction::triggered, [sh] {
        if (sh) sh->editor_undo_redo(true);
    });
    edit->addSeparator();
    QAction* find = edit->addAction(i18n::tr("find"));
    find->setShortcut(QKeySequence::Find);
    QObject::connect(find, &QAction::triggered, [sh] {
        if (sh) sh->editor_open_find();
    });
    edit->addSeparator();
    QAction* zoom_in = edit->addAction(i18n::tr("zoom in"));
    zoom_in->setShortcut(QKeySequence::ZoomIn);
    QObject::connect(zoom_in, &QAction::triggered, [sh] {
        if (sh) sh->editor_zoom(true);
    });
    QAction* zoom_out = edit->addAction(i18n::tr("zoom out"));
    zoom_out->setShortcut(QKeySequence::ZoomOut);
    QObject::connect(zoom_out, &QAction::triggered, [sh] {
        if (sh) sh->editor_zoom(false);
    });

    // ---- Help ----
    QMenu* help = bar->addMenu(i18n::tr("help"));
    QAction* shortcuts = help->addAction(i18n::tr("shortcuts"));
    QObject::connect(shortcuts, &QAction::triggered, [sh] {
        if (sh) sh->show_mode(Sidebar_Mode::SHORTCUTS);
    });
    QAction* learn = help->addAction(i18n::tr("learn"));
    QObject::connect(learn, &QAction::triggered, [sh] {
        if (sh) sh->show_mode(Sidebar_Mode::LEARN);
    });
}

} // namespace shell
