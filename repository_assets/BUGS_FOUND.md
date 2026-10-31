# Bugs found while shooting the README prints

Found by driving the real app (macOS, fullscreen, `gis_host`) on `dragon_showcase`,
`audit_plasma` and `waves`. Status: **open** unless marked fixed.

## Fixed during the shoot

| # | Bug | Fix |
| --- | --- | --- |
| F1 | Cmd+S saved only once per file. After the first save every later edit left the tab clean and Cmd+S did nothing. `Editor::save_all` reset `doc.dirty` but not the widget's modified flag, so `modificationChanged` never fired again. | `doc.widget->setModified(false)` in `src/ui/editor.cpp` `save_all`. |

## Open

| # | Where | What happens | Repro |
| --- | --- | --- | --- |
| 1 | Controls panel, `waves` | After a hot reload that adds a `[UiSlider]` field to the params struct, the panel keeps the old widgets: no `softness` slider appears. Switching scene and back is the only refresh seen. | Add `[UiSlider(0.01, 0.5, 0.01, 0.2)] public float softness;` to `WavesParams`, Cmd+S. |
| 2 | Controls panel, `waves` | After a reload the panel keeps showing the user's last values (pink swatch `C46C98`) while the viewport renders the shader defaults (blue). Panel and render disagree. | Pick a tint, edit the shader, Cmd+S. |
| 3 | Controls panel, `waves` | The native colour panel does not update the viewport or the swatch while open. The change lands only on OK. | Click the `tint` swatch, click the colour wheel. |
| 4 | Controls panel | The numeric spin boxes next to the `frequency` and `speed` sliders are clipped to an unreadable sliver at the panel's default width. | Open CONTROLS on `waves`. |
| 5 | Shortcuts | `Cmd+B` is documented as "sidebar" (README, `assets/input.ini` action `toggle_sidebar`) but runs `toggle_zen()`: it hides the editor and sidebar and fullscreens the viewport. | Press Cmd+B. |
| 6 | Sidebar | Clicking the active strip icon does not collapse the panel. Only the small edge pill does, and it is hidden in GRAPH mode. | Click the active strip icon. |
| 7 | Graph fullscreen | The exit button moves with the window width. A click at the old position hits the canvas, and later keystrokes then land in the graph. | Enter graph fullscreen, resize or change scene, click the old button position. |
| 8 | Editor diagnostics | After saving, slangd squiggles appear on valid lines (`import "../../common";`, `public struct`, `WavesParams`) and the editor shows `pipeline has no viewport output` on `waves`. They disappear later. | Edit `waves.slang`, save, screenshot within about 10 s. |
| 9 | Viewport | A pixel-inspector toast appears (and stacks) on every click in the viewport, including the clicks that only close a colour dialog. | Click the viewport twice. |
| 10 | Preview FULL | In FULL mode the first editor line is cut off by the viewport top edge. | Press F3 until FULL. |
| 11 | Editor | Typing past the right edge scrolls the editor horizontally and it does not scroll back. Lines then render clipped on the left until Home is pressed. | Type a 100-column line. |
| 12 | Crash | Qlementine `PolishedWidgetRegistry::removeAndDeleteEventFilters` SEGV, seen once when the app was force-quit while the graph panel was open (`QFocusFramePrivate::update` to `inheritStyle`). Not reproduced in a loop of 3 open/close cycles. | See `~/Library/Logs/DiagnosticReports/gis_host-2026-10-30-183537.ips`. |
| 13 | Startup | The window now stays black for about 4 s while shaders compile before the first reveal. A splash would hide the wait. | Launch the app. |
| 14 | Graph autosave | The app rewrites `graph.json` of the open scene on its own while the graph is open. Sessions leave the file diff dirty (`dragon_showcase`, `waves`, `audit_plasma`). | Open GRAPH, quit, `git diff`. |
