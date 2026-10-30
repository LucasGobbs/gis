# Design (gis)

Darkroom bench identity: dark neutral surfaces, amber safelight accent,
JetBrains Mono voice. One visual system for chrome, editor and the SDL
preview frame (the preview is chrome, not a guest window).

## Theme

Dark-first, scene-derived: a learner edits shaders late at night in a dim
room; the render preview must be the brightest thing on screen while chrome
recedes. Four skins (Dark/Light/Monokai/Solarized) drive BOTH the Qlementine
widgets and the hand-styled chrome via `theme::` accessors; switching skins
re-dresses everything including preview overlays.

## Color

Strategy: Restrained. Tinted dark neutrals + one amber accent (safelight),
reserved for live/active state (bake indicator, active mode, snap targets,
checked preview buttons). Chrome palette per skin lives in `src/ui/theme.cpp`
(`kChrome`); Qlementine tokens in `assets/themes/<skin>.json`.

| Role | Dark value | Source |
|---|---|---|
| Tray (strip) | `#191A1F` | theme::surface_tray |
| Bench (topbar) | `#1A1B20` | theme::surface_bench |
| Panel | `#1E2026` | theme::surface_panel |
| Workspace | `#131418` | qlementine backgroundColorWorkspace |
| Text | `#DEE0E6` | theme::text_primary |
| Text muted | `#828894` | theme::text_muted |
| Frame border | `#FFFFFF17` | theme::frame_border |
| Control border | `#4A4D55` | theme::control_border |
| Safelight accent | `#E8A857` | theme::safelight |
| Error | `#F26B5C` | pipelineErrorBar |

Amber dosage: accents ≤ ~10% of any surface. Never neon, never glow.

## Typography

- UI + code: JetBrains Mono (vendored), 9pt chrome, 12pt code default.
- Sergamon (pixel face): branding/titlebar + optional code face (pixel-size
  tuned to the 8px grid).
- Hierarchy via weight/letter-spacing on muted uppercase captions
  (`QLabel[caption="true"]`), not size jumps.

## Components

- **Topbar** (28px, bench surface): scene selector, + new, preview segmented
  control (float/split/full, active = amber tint + border), save (bakes
  amber border while building), pause.
- **Strip** (52px): mode navigation icons; active mode = white-10% wash.
- **Side panel**: resizable by edge drag; live px readout in a tooltip;
  chevron grip visible at rest.
- **Preview frame** (SDL child window): 1px CALayer border + 6px corner
  radius; Qt overlays add the themed border, snap zones (2px dashed
  safelight) during drags, and the split gutter (10px grab band,
  draggable 20-80%).
- **Panels**: persistent QStackedWidget pages; captions uppercase
  letter-spaced muted; controls use Qlementine defaults (no custom chrome).

## Motion

180ms OutCubic springs for panel open/close (prefers-reduced-motion
honoured: instant). Preview/snap transitions are instant state flips: a
docked frame must never lag the cursor.

## Layout

Topbar → body: strip | side panel | elastic center (editor + docked/floating
preview). The viewport rect is the dock target for split/full snap zones;
the preview may float anywhere but defaults top-right below the tab row.

<!-- Generated from code + dark.json by /impeccable document. Register:
product. Personality: playful lab (see PRODUCT.md). -->
