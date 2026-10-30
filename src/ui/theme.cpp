#include "theme.hpp"

#include <QFontDatabase>
#include <QPalette>

// Qlementine owns the widget look; the theme switch goes through its
// setThemeJsonPath (repolishes + repaints every widget).
#include <oclero/qlementine/style/QlementineStyle.hpp>

namespace theme {

static int jetbrains_id = -1;
static int sergamon_id = -1;
static oclero::qlementine::QlementineStyle* g_style = nullptr;
static App_Theme g_theme = App_Theme::Dark;

void load_fonts() {
    jetbrains_id = QFontDatabase::addApplicationFont(
        ":/fonts/JetBrainsMono-Regular.ttf");
    sergamon_id = QFontDatabase::addApplicationFont(":/fonts/Sergamon-Regular.ttf");
}

QFont code_font(int point_size) {
    if (jetbrains_id >= 0) {
        const QStringList fam = QFontDatabase::applicationFontFamilies(jetbrains_id);
        if (!fam.isEmpty()) return QFont(fam.first(), point_size);
    }
    return QFont("Menlo", point_size);
}

// Pixel face for the code editor option: Sergamon at PIXEL size (a bitmap-
// grid font scaled by points blurs; multiples of the native 8px grid stay
// crisp). point_size maps 1:1 so the editor's zoom persists meaningfully.
QFont pixel_code_font(int point_size) {
    if (sergamon_id >= 0) {
        const QStringList fam = QFontDatabase::applicationFontFamilies(sergamon_id);
        if (!fam.isEmpty()) {
            QFont f(fam.first());
            f.setPixelSize(point_size);
            f.setBold(false);
            return f;
        }
    }
    return code_font(point_size); // Sergamon missing: monospace fallback
}

QFont ui_font(int point_size) { return code_font(point_size); }

QFont display_font(int pixel_size) {
    if (sergamon_id >= 0) {
        const QStringList fam = QFontDatabase::applicationFontFamilies(sergamon_id);
        if (!fam.isEmpty()) {
            QFont f(fam.first());
            f.setPixelSize(pixel_size);
            return f;
        }
    }
    return code_font(12);
}

namespace {

// Per-skin chrome palette. tray/bench/panel surfaces, text tiers, borders,
// the state accent, semantic states and node-resource hues. Mirrors the
// editor's token papers so chrome and code share one identity per skin.
struct Chrome {
    const char* tray, *bench, *panel, *workspace, *text, *muted, *border, *control, *accent;
    const char* error;   // failure / bake failure
    const char* success; // bake-ok flash, valid states
    const char* warning; // deprecated path; same family as accent
    const char* info;    // toasts, learn links (signature blue)
    // Node-graph resource hues (GRAPH mode boundaries + data-defined links).
    const char* res_params;  // amber family
    const char* res_compute; // violet
    const char* res_graphics;// blue
    const char* res_output;  // green
    const char* res_neutral; // texture/mesh/widget
};
constexpr Chrome kChrome[] = {
    // Dark = Darkroom (the gis identity).
    {"#191A1F", "#1A1B20", "#1E2026", "#131418", "#DEE0E6", "#828894", "#FFFFFF17",
     "#4A4D55", "#E8A857",
     "#F26B5C", "#2BB5A0", "#E8A857", "#9EC2F2",
     "#E8A857", "#C99EF2", "#9EC2F2", "#A9D49E", "#8C9099"},
    // Light. muted derived to AA on panel (plan13 contrast rule: hue kept,
    // lightness stepped until >= 4.5:1).
    {"#F2F3F5", "#FFFFFF", "#E8EAEF", "#E4E6EB", "#1F2024", "#5F646E", "#00000017",
     "#B9BEC9", "#9A5B0A",
     "#B3382B", "#1E7A63", "#9A5B0A", "#2B5FA3",
     "#9A5B0A", "#7A4BA3", "#2B5FA3", "#3D7A36", "#6F747E"},
    // Monokai. muted/error lightened for AA on the olive panel (the raw
    // Monokai pink #F92672 is 3.48:1 — unusable as error text).
    {"#1F201B", "#272822", "#2F312A", "#1F201B", "#F8F8F2", "#9D9986", "#FFFFFF17",
     "#49483E", "#F92672",
     "#FF5EAA", "#A6E22E", "#E6DB74", "#66D9EF",
     "#F92672", "#AE81FF", "#66D9EF", "#A6E22E", "#75715E"},
    // Solarized dark. Same rule: base03-panel demands brighter muted/error.
    {"#00212B", "#002B36", "#073642", "#00212B", "#93A1A1", "#889EA5", "#FFFFFF17",
     "#0D4250", "#B58900",
     "#FF6A67", "#859900", "#B58900", "#268BD2",
     "#B58900", "#6C71C4", "#268BD2", "#859900", "#586E75"},
};

const Chrome& chrome() { return kChrome[int(g_theme)]; }

QString theme_json_path(App_Theme t) {
    switch (t) {
    case App_Theme::Light: return "assets/themes/light.json";
    case App_Theme::Monokai: return "assets/themes/monokai.json";
    case App_Theme::Solarized: return "assets/themes/solarized.json";
    default: return "assets/themes/dark.json";
    }
}

} // namespace

// ---- semantic tokens (public, per active skin) ----
QString error() { return chrome().error; }
QString success() { return chrome().success; }
QString info() { return chrome().info; }
QColor error_rgb() { return QColor(chrome().error); }
QColor success_rgb() { return QColor(chrome().success); }
QColor info_rgb() { return QColor(chrome().info); }
QColor resource_rgb(Resource_Kind kind) {
    switch (kind) {
    case Resource_Kind::Params: return QColor(chrome().res_params);
    case Resource_Kind::Compute: return QColor(chrome().res_compute);
    case Resource_Kind::Graphics: return QColor(chrome().res_graphics);
    case Resource_Kind::Output: return QColor(chrome().res_output);
    case Resource_Kind::Neutral: break;
    }
    return QColor(chrome().res_neutral);
}
QString resource_hex(Resource_Kind kind) { return resource_rgb(kind).name(); }

// ---- shared dims/states (skin-independent) ----
QString overlay_scrim(int alpha) { // caption/hint plates over the viewport
    return QString("rgba(19,20,24,%1)").arg(alpha);
}
int bake_pulse_alpha_min() { return 35; }   // %, amber breathing floor
int bake_pulse_duration_ms() { return 600; }
int bake_flash_duration_ms() { return 380; }
int hint_duration_ms() { return 2500; }     // drag-me first-run hint

void apply_palette(QApplication& app, oclero::qlementine::QlementineStyle* style) {
    g_style = style;
    g_theme = App_Theme::Dark;
    app.setFont(code_font(12));
}

void set_app_theme(App_Theme theme) {
    g_theme = theme;
    if (g_style) g_style->setThemeJsonPath(theme_json_path(theme));
}

App_Theme app_theme() { return g_theme; }

// plan13 theme previews: the palette of ANY theme (not just the active
// one) for the menu swatches. Fallback: out-of-range → Dark.
QColor panel_of(App_Theme t) {
    return t >= App_Theme::Dark && t <= App_Theme::Solarized
               ? QColor(kChrome[int(t)].panel)
               : QColor(kChrome[0].panel);
}
QColor text_of(App_Theme t) {
    return t >= App_Theme::Dark && t <= App_Theme::Solarized
               ? QColor(kChrome[int(t)].text)
               : QColor(kChrome[0].text);
}
QColor accent_of(App_Theme t) {
    return t >= App_Theme::Dark && t <= App_Theme::Solarized
               ? QColor(kChrome[int(t)].accent)
               : QColor(kChrome[0].accent);
}

QString surface_tray() { return chrome().tray; }
QString surface_workspace() { return chrome().workspace; }
QString surface_bench() { return chrome().bench; }
QString surface_panel() { return chrome().panel; }
QString text_primary() { return chrome().text; }
QString text_muted() { return chrome().muted; }
QString frame_border() { return chrome().border; }
QString control_border() { return chrome().control; }
QString safelight() { return chrome().accent; }
QColor safelight_rgb() { return QColor(chrome().accent); }

// Plan 07 toolbar states: a translucent wash of the skin's TEXT hue. Dark
// skins have light text → light wash on the dark surface; light skins have
// dark text → dark wash on white. Pressed = double alpha. Derived from the
// text color so every skin (incl. Solarized/Monokai) keeps contrast.
static QString text_wash(int alpha_hex) {
    const QColor text = QColor(chrome().text);
    return QString("rgba(%1,%2,%3,0.%4)")
        .arg(text.red()).arg(text.green()).arg(text.blue())
        .arg(alpha_hex);
}
QString hover_overlay() { return text_wash(14); }   // 0.14
QString pressed_overlay() { return text_wash(26); } // 0.26
} // namespace theme
