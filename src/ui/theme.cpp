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

// Per-skin chrome palette. tray/bench/panel surfaces, text tiers, borders and
// the state accent. Mirrors the editor's token papers so chrome and code share
// one identity per skin.
struct Chrome {
    const char* tray, *bench, *panel, *text, *muted, *border, *control, *accent;
};
constexpr Chrome kChrome[] = {
    // Dark = Darkroom (the gis identity).
    {"#191A1F", "#1A1B20", "#1E2026", "#DEE0E6", "#828894", "#FFFFFF17",
     "#4A4D55", "#E8A857"},
    // Light.
    {"#F2F3F5", "#FFFFFF", "#E8EAEF", "#1F2024", "#6F747E", "#00000017",
     "#B9BEC9", "#9A5B0A"},
    // Monokai.
    {"#1F201B", "#272822", "#2F312A", "#F8F8F2", "#75715E", "#FFFFFF17",
     "#49483E", "#F92672"},
    // Solarized dark.
    {"#00212B", "#002B36", "#073642", "#93A1A1", "#586E75", "#FFFFFF17",
     "#0D4250", "#B58900"},
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

QString surface_tray() { return chrome().tray; }
QString surface_bench() { return chrome().bench; }
QString surface_panel() { return chrome().panel; }
QString text_primary() { return chrome().text; }
QString text_muted() { return chrome().muted; }
QString frame_border() { return chrome().border; }
QString control_border() { return chrome().control; }
QString safelight() { return chrome().accent; }

} // namespace theme
