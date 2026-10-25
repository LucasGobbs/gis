---
name: gis
description: A shader playground — every .slang file is a scene, discovered and rebuilt live.
colors:
  safelight-amber: "#E8A857"
  darkroom-black: "#131418"
  bench-gray: "#1A1B20"
  tray-gray: "#191A1F"
  proof-white: "#DEE0E6"
  fog-gray: "#828894"
  signal-close: "#F26159"
  signal-minimize: "#F7BF30"
  signal-zoom: "#30C742"
  signal-dimmed: "#66666E"
  frame-rest: "#FFFFFF0D"
  frame-hover: "#FFFFFF1A"
  frame-active: "#FFFFFF26"
  separator: "#FFFFFF17"
typography:
  body:
    fontFamily: "JetBrains Mono, monospace"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.0
  code:
    fontFamily: "JetBrains Mono, monospace"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.1
  label:
    fontFamily: "JetBrains Mono, monospace"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.0
rounded:
  chrome: "0px"
  frame: "5px"
  popup: "6px"
  window: "8px"
  os-window: "12px"
spacing:
  xs: "5px"
  sm: "6px"
  md: "8px"
  lg: "10px"
  xl: "12px"
components:
  button-default:
    backgroundColor: "#FFFFFF12"
    textColor: "{colors.proof-white}"
    rounded: "{rounded.frame}"
    padding: "5px 10px"
  button-hover:
    backgroundColor: "#FFFFFF21"
    textColor: "{colors.proof-white}"
    rounded: "{rounded.frame}"
  frame-default:
    backgroundColor: "{colors.frame-rest}"
    textColor: "{colors.proof-white}"
    rounded: "{rounded.frame}"
    padding: "4px 10px"
  frame-hover:
    backgroundColor: "{colors.frame-hover}"
    textColor: "{colors.proof-white}"
    rounded: "{rounded.frame}"
  tab-active:
    backgroundColor: "#FFFFFF2E"
    textColor: "{colors.proof-white}"
    rounded: "{rounded.frame}"
  strip-item-active:
    backgroundColor: "#E8A85738"
    textColor: "{colors.safelight-amber}"
    rounded: "{rounded.window}"
---

# Design System: gis

## 1. Overview

**Creative North Star: "The Darkroom"**

A darkroom is where an image is revealed: dim, quiet, every surface neutral
so nothing fogs the print. gis's UI is that room. The scene
being rendered is the photograph emerging in the tray; the interface is the
bench, the tongs, the timer — present, precise, and deliberately colorless.

The single accent is the safelight. In a real darkroom the amber lamp is
the one light that lets you work without exposing the paper; here the amber
marks state (selection, active, hover) without ever contaminating the
artist's judgment of scene color. Its rarity is functional, not stylistic.

This system rejects SaaS dashboard clichés (card grids, gradients,
corporate blue), IDE clutter (nested panels, separator spaghetti), and
neon-on-black "gamer dev" glow. Depth comes from tonal layering, not
shadows; hierarchy comes from two text tones, not from font families.

**Key Characteristics:**
- Tinted dark neutrals in three layers: bench (chrome), darkroom (panels),
  tray (popups).
- One amber accent, reserved for state.
- JetBrains Mono everywhere; two text tones (proof, fog) instead of a type
  scale.
- Flat by default; 1px separators instead of shadows.
- Native macOS chrome: traffic lights, rounded OS corners, hit-test
  drag/resize.

## 2. Colors

The palette is a darkroom: near-black working surfaces, a single safelight
amber, and native signal colors borrowed from macOS window chrome.

### Primary
- **Safelight Amber** (#E8A857): the only accent. Marks state: the active
  sidebar mode's tint and icon, checked boxes, the active slider grab,
  selection background (at 35% alpha), keyboard-nav cursor. Never used for
  decoration, large fills, or text.

### Neutral
- **Darkroom Black** (#131418): panel background (sidebar panels, floating
  windows), at 97% opacity over the scene.
- **Bench Gray** (#1A1B20): window chrome — activity strip.
  One step lighter than panels so chrome reads as structure.
- **Tray Gray** (#191A1F): popup surfaces (combos, the settings gear menu),
  at 98% opacity.
- **Proof White** (#DEE0E6): primary text and active glyphs.
- **Fog Gray** (#828894): disabled text, section captions ("controls",
  "scenes"), the status row, inactive icons.
- **Frame tints** (white at 5% / 10% / 15%): rest, hover, active for
  framed controls (combos, checkboxes). Buttons run slightly brighter
  (7% / 13% / 18%).
- **Separator** (white at ~9–10%): 1px rules beside the strip, between
  sections.

### Signals
- **Signal Close** (#F26159), **Signal Minimize** (#F7BF30), **Signal
  Zoom** (#30C742): the traffic lights, exact macOS hues. **Signal Dimmed**
  (#66666E) replaces all three when the window is unfocused, matching
  native behavior.

### Named Rules
**The Safelight Rule.** The amber accent is the only non-neutral color in
the UI and exists only to mark state. If a screen shows amber on something
that isn't selected, active, or hovered, the screen is wrong.

**The Fog Rule.** The UI never introduces a second hue near the scene. A
shader artist judging color must be able to trust every pixel that isn't
chrome.

## 3. Typography

**Display/Body/Code Font:** JetBrains Mono (vendored, OFL); the atlas
bitmap default is forbidden.

**Character:** one voice for chrome, labels, and code. Monospace is the
instrument panel aesthetic: aligned, dense, honest. There is no display
role; nothing shouts.

### Hierarchy
- **Body** (400, 16px UI default, 1.0): every control, label, and caption.
  Adjustable 12–22px in settings.
- **Code** (400, 16px editor default, ~1.1): the shader editor, with its
  own size setting (10–28px) independent of the UI font.
- **Label** (400, same size as body): section captions. Hierarchy is
  carried by color — Fog Gray for captions, Proof White for content —
  never by a second family or a weight jump.

### Named Rules
**The One Voice Rule.** One mono family carries everything. To rank two
pieces of text, dim one (proof → fog); never add a family, a display cut,
or a weight above 500.

**The Two Sizes Rule.** Exactly two font-size knobs exist (UI, editor) and
they never scale each other. Everything else inherits.

## 4. Elevation

The system is flat. No component casts a shadow; the only shadow in the
product is the one macOS draws under the OS window itself. Depth is tonal:
Bench Gray chrome floats over Darkroom Black panels, Tray Gray popups float
over both, and 1px separators (~9% white) mark structural joints — at
the strip's right edge, between panel sections.

### Named Rules
**The Flat-By-Default Rule.** Depth = layer tint + 1px rule. If a
component seems to need a shadow, it needs a better tint step instead.

## 5. Components

### Window Frame
No title bar: the SDL window is borderless and the app owns every pixel.
Scene selection, scene creation, save and pause live in the activity
strip and the FILES panel; the scene canvas runs edge to edge.

### Activity Strip
46px column at the left edge, full height, Bench Gray. Mode icons are
drawn glyphs (mono fonts ship no icon set) authored inside a shared
20px bounding square centered in the 34px slot (sliders, folder, book,
graph, export, droplet, keyboard), with 1.7px strokes so the larger art
keeps its optical weight. The active mode gets an amber 22% tint and
amber glyph (8px radius); hover gets 7% white. Save (floppy) and
pause/play sit one step under the modes; the settings gear pins to the
bottom. Clicking the active mode collapses its panel; Cmd+B hides the
whole strip.

### Files Panel (tree)
The FILES panel is a tree, not a flat path list: a scene combo on top
(grouped: scenes, user scenes, trails), then the scene unit as a folder
node — the entry shader first, then its modules, then graph.json — and
a `shared` node for cross-scene imports. Rows carry small sheet glyphs;
right-click renames (the entry rename IS the scene rename).

### Color Param (picker)
The old ColorEdit3 row (small patch, RGB fields, options gear) is
replaced: the swatch IS the button (2x frame height wide, full frame
height tall, the color itself as the fill), the hex value sits right of
it (click copies), and clicking the swatch opens a ColorPicker3 popup
(saturation/value square + hue bar, hex display, no alpha, no options
menu). Amber stays out of it: the swatch shows the scene's own color.

### Buttons
- **Shape:** gently rounded (5px).
- **Default:** white at 7%, Proof White text, compact padding (5px 10px).
- **Hover / Active:** white at 13% / 18%. No border, no shadow, no color.

### Frames (combos, checkboxes, sliders)
- **Shape:** 5px radius, no border.
- **Rest / Hover / Active:** white at 5% / 10% / 15%.
- **Check marks and active slider grabs:** Safelight Amber — state, per the
  Safelight Rule.

### Tabs (editor)
Small buttons in a row; the visible tab reads pressed (white 18%). A
leading `•` marks unsaved changes; `×` closes. Tabs follow the active
scene: the scene file plus every module it imports.

### Qt Port (cpp_port) Equivalents
The Qt shell mirrors the ImGui system with named constants instead of
drawn glyphs: `kTitlebarH 38`, `kStripButton 34`, `kStripStep 42`,
`kStripTop 10`, `kToolbarIcon 24`. Icons come from qlementine's SVG set
(24px preferred, 16px fallback scaled smooth), tinted `#dfe0e6` via
Source+SourceIn; active state stays Safelight `#e8a857`. Panel widths are
per-mode (`panel_width_for`: 280–340px, GRAPH collapses the side panel to 0
— the canvas is the center stack page). Strip clicks: first click selects
the mode and opens the panel; clicking the active mode toggles the panel.
Prefs persist to `assets/ui.prefs` (theme, fonts, panel width, glass).

### Panels
Darkroom Black at 97% opacity, 8px window rounding, docked full height.
Section captions in Fog Gray (`controls`, `scenes`, `shared`); scene
params under a SeparatorText.

### Popups
Tray Gray at 98%, 6px rounding. Captions on their own rows (trailing
slider labels overflow auto-sized popups — forbidden).

### Node Graph
The canvas is Bench Gray over the Darkroom panel, grid lines at separator
strength. Node title bars follow the Safelight Rule: the scene unit (the
current print) wears amber as an alpha wash (22% / 35% / 50% for rest /
hover / selected); shared modules stay neutral (white 8% / 12% / 18%).
Output pins are amber; inputs and definitions walk the neutral scale. The
hint caption is always wrapped; a single-line caption forces a horizontal
scrollbar and breaks the canvas.

### Motion
One motion language, all of it damped ease-out (exponential approach, no
bounce): the selection pill slides between strip icons; sidebar modes
slide their content in from the left (~160ms, cubic); the panel collapses
by width spring; zen mode (SPACE / Cmd+B) slides the whole sidebar off
the left edge; the editor springs in from the right on F1. State changes
get ink: particle bursts on save/export/scene switch, and scene switches
develop like a photograph (see Effects). The `off` intensity is a full
static fallback: no animation anywhere, hard cuts.

**The Motion Conveys State Rule.** Every animation answers "what just
changed": a selection moved, a panel collapsed, a scene switched, a file
saved. If an animation doesn't answer that, it is decoration and it gets
cut. No ambient loops, no choreography, no bounce.

### Named Rules
**The Earned Familiarity Rule.** Every component must already exist in the
user's muscle memory (VS Code, macOS, Linear). A novel affordance needs a
written defense or it gets cut.

**The Concentric Radii Rule.** Rounding belongs to floating surfaces only.
Docked chrome (strip, sidebar panels) is square (0px); floating
windows are 8px; popups 6px; controls 5px inside them; the OS window
itself is 12px. Rounded corners against flush neighbors always clash.

## 6. Do's and Don'ts

### Do:
- **Do** keep every neutral tinted toward the blue-gray bench family; pure
  #000 and #fff are forbidden anywhere in the UI.
- **Do** draw icons as line glyphs (draw list) when the font lacks them —
  traffic lights, strip icons, pause, gear are all drawn.
- **Do** reserve amber for state and keep it under ~5% of any screen.
- **Do** use 1px separators (white ≤10%) for structure instead of shadows
  or nested borders.
- **Do** match native macOS behavior for window chrome: glyphs on group
  hover, dimmed lights when unfocused, double-click-free drag regions.

### Don't:
- **Don't** build SaaS dashboard clichés: identical card grids, gradients,
  hero metrics, corporate blue (PRODUCT.md anti-reference).
- **Don't** nest panels or draw separators everywhere; IDE clutter is the
  named failure mode.
- **Don't** use neon purple/cyan glow or "gamer dev" saturation — the
  accent is amber and it is alone.
- **Don't** use glassmorphism decoratively. The editor's glass mode is a
  functional see-through for watching the scene behind the code, not a
  style.
- **Don't** put text at Fog Gray on anything but captions, disabled state,
  and status lines; content stays Proof White.
- **Don't** invent affordances: no custom scrollbars, no modal-first
  flows, no side-stripe accent borders, no gradient text.
