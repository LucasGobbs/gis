# Product

## Register

product

## Users

Shaders learners and live-coders: students and developers exploring Slang GPU
shaders in a desktop live-coding environment. They alternate fast between
reading a trail, editing code, and watching the preview react. Users work in
long sessions on Apple Silicon Macs, often at night, expecting the app to feel
like a darkroom bench: tools at hand, preview always visible, nothing moving
that doesn't report state.

## Product Purpose

gis is a zero-boilerplate live shader editor: scenes are plain Slang files,
saving recompiles and hot-swaps the pipeline, failures keep the last working
frame on screen. Success = edit → save → see, in one glance; the preview is a
first-class panel (float, split, full) rather than a loose SDL window floating
bugged-looking over the chrome. The whole app reads as one unit: every panel
(dockable preview included) shares the same theme, borders, and chrome.

## Brand Personality

Playful lab: precise but curious. 3 words: precise, tactile, playful.
Emotional goal: the confidence of a pro tool with the friendliness of a lab
bench. JetBrains Mono voice everywhere; the amber safelight accent reads as
"this is live/active", reserved for live/active state (bake indicator, active
mode, dock affordances while dragging).

## Anti-references

- Genérico VS Code clone: file-tree-plus-editor vanilla layout, blue links,
  blue selection, stock icon look.
- Neon cyberpunk shader-toy: glow, chromatic glow text, neon-on-black clichê.
- Cards/vidro decorativo: glassmorphism, side stripes, hero metrics.

## Design Principles

1. **Preview is chrome, not window.** The SDL preview behaves like every other
   panel: themed frame, dock/float/split/full via topbar segmented control +
   drag-snap, never a loose borderless window.
2. **Affordances visible at rest.** Resize bands light on hover, grips visible,
   drag shows snap zones + size readout, release = dock.
3. **One unit: same vocabulary everywhere.** One frame style for panels and
   the preview frame; amber = live/active; mono voice; one icon set
   (Qlementine icons, tinted from the active palette).
4. **Failure-preserving, state-honest.** A dock/resize gesture never blanks
   the render or hides an error: the last working preview stays up while
   frames move; disabled controls never pretend.

## Accessibility & Inclusion

Honour macOS "reduce motion" (already gated in shell.cpp): panel springs and
dock transitions become instant. All preview/split controls get tooltips +
accessible names; drag affordances have keyboard equivalents via the topbar
segmented control. Color is never the only signal (state pairs amber with
icon/label change).

<!-- Descriptive. Register + playful-lab personality set after user interview;
per-surface overrides (drenched campaign pages etc.) live task-scoped. -->
