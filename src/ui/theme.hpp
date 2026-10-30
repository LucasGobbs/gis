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
QString surface_workspace();
QString text_primary();
QString text_muted();
QString frame_border();
QString control_border();
// Toolbar state overlays (Plan 07): translucent text-tinted washes for the
// top bar buttons — hover and pressed. Derived per skin so light themes get
// dark washes and dark themes get light ones (contrast both ways).
QString hover_overlay();
QString pressed_overlay();
QString safelight();
QColor safelight_rgb();


// plan13 theme previews: panel/text/accent of ANY theme (menu swatches).
QColor panel_of(App_Theme t);
QColor text_of(App_Theme t);
QColor accent_of(App_Theme t);

// Semantic states (per skin). Colour is never the sole signal: callers pair
// these with icon/label changes (Safelight Rule).
QString error();
QString success();
QString info();
QColor error_rgb();
QColor success_rgb();
QColor info_rgb();

// Node-graph resource hues (GRAPH boundaries + data-defined link colors).
enum class Resource_Kind { Params, Compute, Graphics, Output, Neutral };
QColor resource_rgb(Resource_Kind kind);
QString resource_hex(Resource_Kind kind);

// Shared dims/states, skin-independent (one definition, no per-file literals).
QString overlay_scrim(int alpha);          // caption/hint plates over the render
int bake_pulse_alpha_min();                // amber breathing floor (%)
int bake_pulse_duration_ms();
int bake_flash_duration_ms();
int hint_duration_ms();                    // first-run drag hint

// Shared geometry (ui_layout parity; used by shell + editor chrome).
constexpr int kRadiusPanel = 6;      // preview frame, find bar, toasts
constexpr int kRadiusControl = 4;    // buttons, inputs, chips
constexpr int kRadiusZone = 8;       // snap zones
constexpr int kSplitGutterW = 10;    // split grab band (px)
constexpr int kEdgeBandW = 8;        // FLOAT edge-resize band (px, unified)
constexpr int kPanelMinW = 220;      // side-panel clamp floor
constexpr int kEditorMinW = 240;     // SPLIT editor clamp floor

// Fonts by role.
QFont code_font(int point_size);      // editor + monospace UI
QFont pixel_code_font(int point_size); // Sergamon pixel face (code editor option)
QFont ui_font(int point_size);      // labels, buttons, lists
QFont display_font(int pixel_size); // Sergamon, branding/titlebar only

} // namespace theme
