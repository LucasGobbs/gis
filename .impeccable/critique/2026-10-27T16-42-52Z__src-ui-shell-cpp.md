---
target: preview dock flow + sidebar resize
total_score: 33
p0_count: 0
p1_count: 1
timestamp: 2026-10-27T16-42-52Z
slug: src-ui-shell-cpp
---
# Critique: preview dock flow + sidebar resize (src/ui/shell.cpp, host_main.mm)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | px/% readouts, bake dot, snap captions: every gesture confirms |
| 2 | Match System / Real World | 3 | "drop: dock split" clear; "eye" icon for FLOAT is a stretch |
| 3 | User Control and Freedom | 3 | Three doors to every mode; no way to resize FLOAT by keyboard |
| 4 | Consistency and Standards | 3 | Gutter band and sidebar edge behave alike; FLOAT edge-hit bands 6px vs gutter 10px |
| 5 | Error Prevention | 3 | Snap zones constrain drop targets; drop at window edge can clamp oddly |
| 6 | Recognition Rather Than Recall | 3 | Topbar segmented control visible at rest; F3 is documented only in SHORTCUTS panel |
| 7 | Flexibility and Efficiency | 4 | Topbar + F3 + drag-snap + editor button: four doors, persisted state |
| 8 | Aesthetic and Minimalist Design | 4 | One accent, one frame style, captions only during drag |
| 9 | Error Recovery | 3 | Bad bake keeps last frame; a botched dock recovers via topbar click |
| 10 | Help and Documentation | 3 | SHORTCUTS panel + tooltips; no inline hint for drag-snap discovery |
| **Total** | | **33/40** | **Good: address weak areas** |

## Anti-Patterns Verdict

**LLM assessment**: Not AI slop. The system is opinionated (darkroom + amber safelight), uses one accent with discipline, and the preview reads as app chrome rather than a guest window. Layout is not a card grid; affordances appear only during gestures. Weak spot: the FLOAT icon (eye) says "peek", not "float".

**Deterministic scan**: detector unavailable in this skill install (exits 1, "bundled detector not found"); ran an intact copy from another project against src/ui + host_main.mm: **0 findings in 19 files** (web-markup rules; low signal for Qt C++, noted as caveat). No browser overlay: not a web target.

## Overall Impression

The dock/float/split system now behaves like a real artistic app (Affinity-style snap, live readouts). Biggest remaining opportunity: **discoverability of the drag gesture**. The topbar teaches modes, but nothing at rest says "you can drag this frame into a zone"; that knowledge lives in tooltips and the SHORTCUTS panel.

## What's Working

- **State honesty**: one `ui.preview` state drives topbar, host window shape, overlays, and prefs. No flag matrix, no desync (the old editor_split bug class is gone).
- **Gestures report themselves**: px readout on sidebar drag, % on gutter drag, captions inside snap zones during drag.
- **Theme coherence**: overlays re-skin from `theme::` on all 4 skins; the amber accent means "live" everywhere it appears.

## Priority Issues

- **[P1] Snap-drag is invisible at rest.** Nothing about the floating frame suggests it is draggable into zones until you happen to grab it. Fix: 2s hint on first FLOAT boot (caption under the frame: "drag me: dock left/right"), then never again. Suggested command: `onboard`.
- **[P2] FLOAT edge-hit bands (6px) vs gutter band (10px)**: inconsistent grab difficulty for the same gesture class. Fix: unify to 8px. Suggested command: `polish`.
- **[P2] Keyboard-free resize/dock**: mode switching has F3, but a keyboard user cannot move or resize the FLOAT frame. Fix: arrow-key nudge when frame focused, or dock/undock items in the Scene menu. Suggested command: `harden`.
- **[P3] "Eye" icon semantics**: FLOAT = free window, not peek. Swap to `empty-slot.svg` (frame-like) or a dedicated pip glyph. Suggested command: `polish`.
- **[P3] Disabled EFFECTS checkboxes** (develop/springs/grain) sit in the strip as a mode button although the panel is dead weight; affordance honesty is right, but the button invites a dead end. Fix: hide the strip entry until wired. Suggested command: `distill`.

## Persona Red Flags

**Alex (Power User)**: F3 + Cmd+B + drag-snap: fast. Gap: no keyboard resize of the floating frame; no double-click to snap left/right (expects double-click = maximize-to-half, Affinity/Windows convention).

**Jordan (First-Timer)**: Icon-only topbar trio: tooltips exist, but at rest nothing explains float/split/full. "Eye" glyph invites wrong guess. The SHORTCUTS panel is 2 clicks away and named "shortcuts", not "help".

**Sam (Accessibility)**: Drag-only gestures (preview move, gutter, sidebar) have no keyboard equivalents; tooltips carry the px readout but QToolTip is not announced by VoiceOver. Snap zones are transparent-for-mouse and visual-only. Keyboard path exists for mode (topbar buttons are tab-focusable), not for geometry.

## Minor Observations

- Snap caption and zones disappear instantly on drop; a 150ms fade would sell the "it landed" moment.
- `panel_width=` prefs line saves an empty value when user_w is 0; harmless but noisy.
- Zen mode hides the strip; the preview controls stay in the topbar (good), but F2/Cmd+B labels in SHORTCUTS predate the preview-cycle rename.

## Questions to Consider

- What if dropping the frame anywhere over the CODE half docked split automatically (no zones needed: drop target = space itself)?
- Does FLOAT need free positioning at all, or would 3 anchor slots (left/center/right) cover 95% of use and kill the drag state entirely?
- Would a 150ms settle animation on drop make the dock feel physical rather than instantaneous?
