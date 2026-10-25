#include "theme.hpp"

#include <QFontDatabase>
#include <QPalette>

namespace theme {

static int jetbrains_id = -1;
static int sergamon_id = -1;

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

void apply_palette(QApplication& app) {
    QPalette pal;
    const QColor darkroom(0x13, 0x14, 0x18); // #131418
    const QColor bench(0x1A, 0x1B, 0x20);    // #1A1B20
    const QColor tray(0x19, 0x1A, 0x1F);     // #191A1F
    const QColor proof(0xDE, 0xE0, 0xE6);    // #DEE0E6
    const QColor fog(0x82, 0x88, 0x94);      // #828894 (lifted from #757A85: ≥4.5:1 text contrast)
    const QColor amber(0xE8, 0xA8, 0x57);    // #E8A857 safelight

    pal.setColor(QPalette::Window, darkroom);
    pal.setColor(QPalette::Base, bench);
    pal.setColor(QPalette::AlternateBase, tray);
    pal.setColor(QPalette::WindowText, proof);
    pal.setColor(QPalette::Text, proof);
    pal.setColor(QPalette::ButtonText, proof);
    pal.setColor(QPalette::BrightText, amber);
    pal.setColor(QPalette::Highlight, amber);
    pal.setColor(QPalette::HighlightedText, darkroom);
    pal.setColor(QPalette::ToolTipBase, tray);
    pal.setColor(QPalette::ToolTipText, proof);
    pal.setColor(QPalette::PlaceholderText, fog);
    pal.setColor(QPalette::Disabled, QPalette::WindowText, fog);
    pal.setColor(QPalette::Disabled, QPalette::Text, fog);
    pal.setColor(QPalette::Disabled, QPalette::ButtonText, fog);
    pal.setColor(QPalette::Disabled, QPalette::Base, darkroom);
    app.setPalette(pal);
    app.setFont(code_font(12));
    // Global polish: dark scrollbars, editor tabs, tooltips, menu popups.
    app.setStyleSheet(
        "QScrollBar:vertical { background: #131418; width: 10px; margin: 0; }"
        "QScrollBar::handle:vertical { background: #2a2c33; border-radius: 4px;"
        " min-height: 24px; }"
        "QScrollBar::handle:vertical:hover { background: #3a3d45; }"
        "QScrollBar::add-line, QScrollBar::sub-line { height: 0; width: 0; }"
        "QScrollBar:horizontal { background: #131418; height: 10px; margin: 0; }"
        "QScrollBar::handle:horizontal { background: #2a2c33; border-radius: 4px;"
        " min-width: 24px; }"
        "QTabBar::tab { background: #1a1b20; color: #8c9099; padding: 5px 12px;"
        " border: none; border-right: 1px solid #131418; }"
        "QTabBar::tab:selected { background: #25272e; color: #DEE0E6; }"
        "QTabBar::tab:hover { color: #DEE0E6; }"
        "QMenu { background: #1a1b20; color: #DEE0E6; border: 1px solid #25272e;"
        " padding: 4px; }"
        "QMenu::item { padding: 4px 18px; border-radius: 4px; }"
        "QMenu::item:selected { background: #E8A857; color: #131418; }"
        "QToolTip { background: #191a1f; color: #DEE0E6; border: 1px solid #25272e;"
        " padding: 3px 6px; }");

} // namespace theme
}
