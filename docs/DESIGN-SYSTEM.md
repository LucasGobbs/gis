# gis Design System — "Graphics Laboratory" (plan4)

Foundation implemented on the existing `theme::` mechanism (plan3 brief:
`artefacts/improvement_plan/brief_graphics_laboratory.md`). No widget rewrites;
Qlementine keeps owning controls, `theme::` owns chrome tokens.

## Files responsible for shared styles

| File | Role |
|---|---|
| `src/ui/theme.hpp` / `theme.cpp` | **Single token source**: per-skin chrome palette (`kChrome`), semantic states, node-resource hues, shared dims (pulse/flash/hint), shared geometry constants |
| `src/ui/editor.cpp` (`kEditorSkins` + `skin_for`) | Per-skin code tokens (paper/text/keyword/type/number/comment/string/preproc/operator/margins/selection); find bar + split button restyle from the same table |
| `assets/themes/{dark,light,monokai,solarized}.json` | Qlementine widget tokens (surfaces, primary, borders) — must stay hue-aligned with `kChrome` |
| QSS builders in `shell.cpp` (`scene_list_qss`, `topbar_qss`, `strip_qss`, `panel_qss`, `panel_edge_qss`) | Chrome stylesheets composed from `theme::` accessors |

## 1. Color tokens (per skin, `theme::`)

Surfaces step darker toward the edges: `surface_panel` > `surface_bench` >
`surface_tray` > `surface_workspace` (the lit-bench hierarchy). Text: primary /
muted. Borders: `frame_border` (white-12% hairlines), `control_border`.

Semantic states (never color-only; pair with icon/label):

| Token | Dark | Meaning |
|---|---|---|
| `safelight` | `#E8A857` | live/active ONLY: bake border, checked modes, snap zones |
| `error` | `#F26B5C` | bake failure, diagnostic underline, error toast |
| `success` | `#2BB5A0` | bake-ok flash |
| `info` | `#9EC2F2` | toasts (info), learn links |
| `resource_rgb(kind)` | Params=accent, Compute=violet, Graphics=blue, Output=green, Neutral=gray | GRAPH node boundaries + data-defined links |

## 2. Shared dims (skin-independent)

- `overlay_scrim(alpha)` — caption/hint plates over the render (`rgba(19,20,24,α)`).
- `bake_pulse_alpha_min()` 35% floor, `bake_pulse_duration_ms()` 600,
  `bake_flash_duration_ms()` 380, `hint_duration_ms()` 2500.

## 3. Shared geometry (`theme.hpp` constexpr)

`kRadiusPanel 6`, `kRadiusControl 4`, `kRadiusZone 8`, `kSplitGutterW 10`,
`kEdgeBandW 8`, `kPanelMinW 220`, `kEditorMinW 240`.

## 4. Typography

- UI + code: JetBrains Mono (vendored). UI chrome 9pt; code 12pt default
  (zoom 10–28pt); LEARN prose 10pt.
- Hierarchy: weight + letter-spaced uppercase `QLabel[caption="true"]`, not size jumps.
- Sergamon: titlebar branding + opt-in pixel code face only.
- Code-face tokens come ONLY from `kEditorSkins` — widgets must not hardcode hexes.

## 5. Interaction states (one vocabulary)

hover = white-5→12% wash or amber-14→38% (edge affordances); checked/active =
amber-22–28% + 1px amber border; focus = 1px safelight border; disabled =
muted text (never pretend); error = persistent error bar (`rgba(error,0.16)`
bg + `error` text) until next good bake; loading = amber pulse on the preview
frame border (reduced-motion: static border).

## 6. Rules

1. New widget styling reads `theme::`/`skin_for` — no hex literals in widgets.
2. Amber = live/active only (Safelight Rule); semantic colors never decorative.
3. State is never color-only: icon/label/text pairing required.
4. New dims/timing go through `theme.hpp` constants, not per-file values.
5. Qlementine JSON and `kChrome` stay hue-aligned per skin (checked in the
   plan4 screenshots: dark/light/monokai/solarized).
