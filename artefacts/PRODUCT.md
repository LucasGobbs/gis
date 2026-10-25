# Product

## Register

product

## Users

Graphics programmer / shader artist working solo (the author), in long
iteration sessions at a dim desk. He judges scene color and texture
constantly, hot-reloads shader code dozens of times per hour, and switches
between scenes, params, code, and the node graph without breaking flow.

## Product Purpose

gis is a shader playground: every .slang file under
src/shaders/scenes is a scene, discovered and rebuilt at runtime. It exists
to shorten the loop between writing a shader and seeing it: title-bar scene
switching, reflected scene params, an integrated editor with LSP
diagnostics, a node graph, and PNG/GIF export. Success means the UI
disappears; the scene is the product.

## Brand Personality

Linear/Raycast-style precision. Three words: precise, quiet, fast. Mono
type, one accent, dense information, zero decoration. The tool should feel
like a well-kept instrument, not like a product page.

## Anti-references

None named explicitly; derived from the Linear/Raycast personality choice:

- SaaS dashboard clichés: identical card grids, gradients, hero metrics,
  corporate blue.
- IDE clutter: nested panels, separators everywhere, chrome heavier than
  content.
- Neon-on-black "gamer dev" aesthetics: saturated purple/cyan glow.
- Sterile all-white light mode as the only option.

## Design Principles

1. **The scene is the product.** Chrome is neutral and gets out of the way;
   tinted neutrals keep scene colors reading true.
2. **One accent, earned.** The amber marks state (selection, active,
   hover); it never decorates.
3. **Familiar over novel.** VS Code/Linear patterns (activity bar, tabs,
   Cmd+B/Cmd+S, traffic lights); no invented affordances.
4. **Native where possible.** Per-platform conventions (macOS window
   chrome, hit-test drag/resize, rounded corners) instead of cross-platform
   lowest common denominator.
5. **Density is a feature.** Mono type, compact rows, no padding theater.
6. **Demos are a first-class surface.** The app is also a stage: theater
   mode (F3) composes a recording-ready frame in one shortcut — zen
   sidebar, docked editor, larger type, all restored on exit.

## Accessibility & Inclusion

No special requirements (personal tool). Default good contrast; dark UI is
justified by the use context (dim room, continuous color judgment).
