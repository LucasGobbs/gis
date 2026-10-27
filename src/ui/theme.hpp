// Visual identity for the Qt port: the EDITOR theme (DARK/LIGHT/MONOKAI/
// SOLARIZED) drives the WHOLE app — one Qlementine theme JSON per editor skin
// (assets/themes/*.json), swapped at runtime via QlementineStyle::setThemeJson-
// Path. Fonts by role: JetBrains Mono for code/UI text, Sergamon (pixel) for
// branding. App_Theme mirrors editor::Editor_Theme's order (cast between
// them); documented coupling — keep both in sync.
#pragma once

#include <QApplication>
#include <QString>

namespace oclero::qlementine {
class QlementineStyle; // real definition: oclero/qlementine/style/QlementineStyle.hpp
}

namespace theme {

// App-wide skins, one per editor theme. Order MUST match
// editor::Editor_Theme (DARK, LIGHT, MONOKAI, SOLARIZED).
enum class App_Theme { Dark, Light, Monokai, Solarized };

// Loads vendored fonts.
void load_fonts();

// One-time startup look: fonts + Qlementine style ownership (Dark theme).
// host_main creates the QlementineStyle and hands it over here.
void apply_palette(QApplication& app, oclero::qlementine::QlementineStyle* style);

// Runtime switch: swaps the Qlementine theme (every widget, menu, scrollbar).
// The Shell repolishes its chrome stylesheets + editor_->set_theme after.
void set_app_theme(App_Theme theme);

// The active skin.
App_Theme app_theme();

// Chrome palette of the ACTIVE theme (the old constexpr darkroom hexes; now
// per-skin so the whole chrome re-skins on theme switch).
QString surface_tray();
QString surface_bench();
QString surface_panel();
QString text_primary();
QString text_muted();
QString frame_border();
QString control_border();
QString safelight();

// Fonts by role.
QFont code_font(int point_size);      // editor + monospace UI
QFont pixel_code_font(int point_size); // Sergamon pixel face (code editor option)
QFont ui_font(int point_size);      // labels, buttons, lists
QFont display_font(int pixel_size); // Sergamon, branding/titlebar only

} // namespace theme
