// Visual identity for the Qt port: darkroom palette from artefacts/DESIGN.md,
// JetBrains Mono for code/UI text, Sergamon (pixel) as the optional display
// face for the branding bits. Palette-only styling (no QSS) keeps it native.
#pragma once

#include <QApplication>

namespace theme {

// Loads vendored fonts. Returns the Qt font ids for fallback wiring.
void load_fonts();

// Applies the darkroom palette (near-black surfaces, proof-white text,
// amber #E8A857 reserved for state).
void apply_palette(QApplication& app);

// Fonts by role.
QFont code_font(int point_size);    // editor + monospace UI
QFont ui_font(int point_size);      // labels, buttons, lists
QFont display_font(int pixel_size); // Sergamon, branding/titlebar only

// Surfaces and text, straight from artefacts/DESIGN.md (single source of
// truth — inline hex in widget stylesheets was drifting: 4 near-identical
// blacks across topbar/strip/panel/scene-list).
constexpr const char* kSurfaceTray = "#191A1F";    // scene list overlay
constexpr const char* kSurfaceBench = "#1A1B20";   // top bar + mode strip
constexpr const char* kSurfacePanel = "#1E2026";   // side panel
constexpr const char* kTextPrimary = "#DEE0E6";    // proof white
constexpr const char* kTextMuted = "#828894";      // fog: captions, hints (≥4.5:1 on every surface — DESIGN.md's #757A85 measured 4.27:1)
constexpr const char* kFrameBorder = "#FFFFFF17";  // separators/frames

constexpr const char* kSafelight = "#E8A857"; // amber: state, never decoration
} // namespace theme
