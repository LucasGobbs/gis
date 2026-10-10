package main

// Appearance preferences persistence: editor theme, the two font sizes,
// the dragged panel width, and the editor glass state. Written to
// assets/ui.prefs on every change (tiny file, no debounce needed) and
// restored at startup. Same spirit as assets/i18n.lang.

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// Drag bookkeeping: the panel-edge handler has no editor reference, so
// ied_init registers it here and the drag-end flushes one save.
// Set by settings-popup widgets instead of saving per slider tick;
// flushed by ui_activity_strip when the popup closes.
ui_prefs_dirty: bool
ui_prefs_dragging: bool
ui_prefs_editor:  ^ImGuiEditor

UI_PREFS_FILE :: "assets/ui.prefs"

// Loads saved prefs into the UI and editor states. Missing file or
// fields fall back to the struct defaults (no migration needed: the
// file is recreated on the next knob change).
ui_prefs_load :: proc(ui: ^Ui, ed: ^ImGuiEditor) {
	data, read_err := os.read_entire_file(UI_PREFS_FILE, context.temp_allocator)
	if read_err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		eq := strings.index(line, "=")
		if eq < 0 do continue
		key := line[:eq]
		value := strings.trim_space(line[eq + 1:])
		switch key {
		case "theme":
			if v, ok := strconv.parse_int(value); ok && v >= 0 && v < int(EditorTheme.SOLARIZED) + 1 {
				ed.theme = EditorTheme(v)
				ied_apply_theme(ed)
			}
		case "editor_font":
			if v, ok := strconv.parse_f64(value); ok {
				ed.font_size = math.clamp(f32(v), 10, 28)
			}
		case "ui_font":
			if v, ok := strconv.parse_f64(value); ok {
				ui.font_size = math.clamp(f32(v), 12, 22)
			}
		case "panel_width":
			if v, ok := strconv.parse_f64(value); ok && v >= 220 {
				ui.user_w = f32(v)
			}
		case "glass":
			if v, ok := strconv.parse_int(value); ok {
				ed.bg_transparent = v != 0
			}
		}
	}
}

// Saves the current appearance knobs. Called on every knob change (the
// sliders fire per tick while dragging: the write is a few hundred
// bytes, fine at 60 Hz for a drag).
ui_prefs_save :: proc(ui: ^Ui, ed: ^ImGuiEditor) {
	width := ui.user_w > 0 ? fmt.tprintf("%.0f", ui.user_w) : ""
	content := fmt.tprintf(
		"theme=%d\neditor_font=%.0f\nui_font=%.0f\npanel_width=%s\nglass=%d\n",
		int(ed.theme), ed.font_size, ui.font_size, width, ed.bg_transparent ? 1 : 0,
	)
	if write_err := os.write_entire_file(UI_PREFS_FILE, transmute([]u8)content); write_err != nil {
		log.errorf("prefs: could not write %s", UI_PREFS_FILE)
	}
}
