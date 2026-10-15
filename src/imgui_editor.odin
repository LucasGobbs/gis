// Integrated ImGui shader editor (Dear ImGui + goossens' ImGuiColorTextEdit
// via the ite C wrapper): a floating window toggled with F1, separate from
// the sidebar. Its tabs follow the active scene: the scene file plus every
// module it transitively imports. Cmd+S is the application-wide save
// (every dirty tab, shader files are the app's only persistent state);
// the scene watcher rebuilds on write. Cmd+click jumps to the definition
// (current file first, then the other .slang files, e.g. common.slang).
package main

import im "../vendor/odin-imgui"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

foreign import ite "../vendor/ImGuiColorTextEdit/libite.a"

@(default_calling_convention = "c")
foreign ite {
	ite_create :: proc() -> rawptr ---
	ite_destroy :: proc(ed: rawptr) ---
	ite_set_text :: proc(ed: rawptr, utf8: cstring) ---
	ite_get_text :: proc(ed: rawptr) -> cstring ---
	ite_render :: proc(ed: rawptr, title: cstring, width: f32, height: f32) -> bool ---
	ite_set_tab_size :: proc(ed: rawptr, size: c.size_t) ---
	ite_set_leading_whitespace_only :: proc(ed: rawptr, on: bool) ---
	ite_get_undo_index :: proc(ed: rawptr) -> c.size_t ---
	ite_is_mouse_over_text :: proc(ed: rawptr, x: f32, y: f32) -> bool ---
	ite_get_word_at_mouse :: proc(ed: rawptr, x: f32, y: f32, buf: cstring, cap: c.size_t) -> c.size_t ---
	ite_text_metrics :: proc(ed: rawptr, out: [^]f32) ---
	ite_word_rect_at_mouse :: proc(ed: rawptr, x: f32, y: f32, out: [^]f32) -> bool ---
	ite_goto_line :: proc(ed: rawptr, line: c.size_t) ---
	ite_get_cursor_line :: proc(ed: rawptr) -> c.size_t ---
	ite_get_cursor_col :: proc(ed: rawptr) -> c.size_t ---
	ite_set_cursor_pos :: proc(ed: rawptr, line: c.size_t, col: c.size_t) ---
	ite_duplicate_line :: proc(ed: rawptr) ---
	ite_set_glass :: proc(ed: rawptr, on: bool, alpha: f32) ---
	ite_set_fade :: proc(ed: rawptr, alpha: f32) ---
	ite_set_palette_u32 :: proc(ed: rawptr, colors: [^]u32, count: c.size_t) ---
	ite_get_palette_u32 :: proc(ed: rawptr, colors: [^]u32, count: c.size_t) ---
	ite_use_dark_palette :: proc(ed: rawptr) ---
	ite_get_background_alpha :: proc(ed: rawptr) -> u32 ---
	ite_use_light_palette :: proc(ed: rawptr) ---
	ite_clear_diagnostics :: proc(ed: rawptr) ---
	ite_add_squiggle :: proc(ed: rawptr, line: c.size_t, col: c.size_t, msg: cstring) ---
	ite_add_squiggle_range :: proc(ed: rawptr, sl: c.size_t, sc: c.size_t, el: c.size_t, ec: c.size_t, msg: cstring) ---
	ite_add_error_marker :: proc(ed: rawptr, line: c.size_t, msg: cstring) ---
	ite_install_context_menu :: proc(ed: rawptr) ---
	ite_take_goto_word :: proc(ed: rawptr, buf: cstring, cap: c.size_t) -> bool ---
	ite_take_rename_word :: proc(ed: rawptr, buf: cstring, cap: c.size_t) -> bool ---
	ite_enable_completion :: proc(ed: rawptr, fn: IteCompletionFn, user: rawptr) ---
	ite_set_change_callback :: proc(ed: rawptr, fn: IteChangeFn, user: rawptr) ---
}

IteCompletionFn :: #type proc "c" (search_term: cstring, cursor_line: c.size_t, cursor_col: c.size_t, user: rawptr, out_buf: [^]u8, out_cap: c.size_t) -> c.int
IteChangeFn :: #type proc "c" (user: rawptr)

// Debug/self-test knobs (set from os.args in main).
ied_debug_clicks: bool
ied_selftest:     bool
ied_selftest_frame: int
// Self-test only: overrides the hovered word so the docs tooltip can be
// exercised without mouse input.
ied_debug_hover_word: string
// --hover-debug: logs the live hover pipeline (capture, dwell, lookup)
// to diagnose sessions where docs never appear.
hover_debug:    bool
hover_debug_ts: f64
// Self-test only: injected mouse position driving the REAL hover path
// (component capture + dwell) end to end.
hover_inject:        [2]f32
hover_inject_active: bool
goto_inject_pos:     [2]f32
// Cmd/Shift tracked from raw SDL key events (imgui_io.KeySuper proved unreliable).
ied_gui_held:   bool
ied_shift_held: bool

SHADER_DIR :: "src/shaders"

// One open document (a tab). `text` stashes the buffer while the tab is not
// the visible one so switching preserves unsaved edits; `dirty` is sticky
// because the component's undo index resets on every SetText.
OpenDoc :: struct {
	file:   int,   // index into ImGuiEditor.files
	text:   string, // owned; valid once loaded == true
	loaded: bool,
	dirty:  bool,
	last_good: string, // owned; source text from the last loadable pipeline
}

ImGuiEditor :: struct {
	handle:      rawptr,
	open:        bool, // floating window visible (F1 toggles)
	files:       [dynamic]string, // relative to SHADER_DIR, no .slang ("apple" -> "scenes/apple")
	current:     int,        // index into files of the visible document (-1: none)
	open_docs:   [dynamic]OpenDoc,
	current_open: int,       // index into open_docs of the visible document (-1: none)
	status:      string,
	saved_undo:  c.size_t,
	font_size:   f32, // code font in points; the UI font is Ui.font_size
	last_scene:  string,
	bg_transparent: bool,
	// Glass mode transparency (component palette + window frame alpha);
	// edited in the settings gear popup.
	glass_alpha: f32,
	theme:       EditorTheme,
	// Deferred goto-definition: the component moves the cursor to the click
	// point during Render of the same frame, clobbering an immediate jump,
	// so the word is recorded on click and the jump runs next frame.
	goto_word:   string,
	goto_pending: bool,
	// Diagnostics push caching.
	err_version: int,
	err_file:    int,
	// Live LSP sync: the component's change callback marks the document
	// dirty (works for typing AND programmatic SetText, unlike undo-index
	// deltas which SetText resets); the frame counter debounces ~300ms.
	lsp_dirty: bool,
	lsp_change_frames: int,
	lsp_diag_version: int,
	build_success_version: int,
	// Hover symbol docs: the word under the mouse is tracked while it
	// dwells (~0.4 s), then resolved once into a signature + doc comment
	// (ied_lookup_symbol) shown as a tooltip. Once shown, the tooltip
	// pins in place and stays alive while the mouse is inside it, so
	// long docs can actually be scrolled.
	hover_word:  string, // owned
	hover_dwell: int,
	hover_sig:   string, // owned; "" = unresolved/hidden
	hover_doc:   string, // owned
	hover_shown: bool,
	hover_pin:   im.Vec2, // pinned tooltip position
	hover_rect:  [4]f32, // last tooltip rect (min.xy, max.xy), padded
	hover_grace: f32,    // countdown while crossing from word to tooltip
	hover_footer: string, // owned; file:line or "slang builtin · see also"
	hover_doc_scroll: f32, // doc scroll offset (wheel inside the tooltip)
	// The window docks to the right edge until the user drags its title
	// bar somewhere else; after that ImGui owns the position. F1 and
	// theater mode reset this, re-docking the window.
	moved:        bool,
	dock_display: [2]f32, // DisplaySize the dock position was forced for
	// FX motion state: open/close spring, the tab-switch crossfade
	// overlay, and the status row's fade-in.
	open_anim:    Anim,
	tab_flash:    f32,
	last_open_tab: int,
	status_fade:  f32,
	last_status:  string, // owned
	// Fixed backing for `status` (no temp-allocator string, so the
	// per-frame free_all in main never frees memory the UI still shows).
	status_buf: [256]u8,
	// Context-menu "Rename symbol": the word to rename (owned), popup open
	// request, and the InputText buffer for the new name.
	rename_word: string,
	rename_open: bool,
	rename_buf:  [64]u8,
	// Navigation history (Option+'-' jumps back): cursor positions worth
	// returning to: goto-definition origins and moves larger than a few
	// lines. Keeps the last 32 (at least the 10 requested).
	nav_history:  [dynamic]NavPos,
	nav_snapshot: NavPos,
	nav_valid:    bool,
	// Ice scroll: wheel velocity that glides with exponential friction.
	scroll_vel: f32,
	// Text area origin (screen px) for word-lookups under the mouse.
	text_pos:      [2]f32,
}

NavPos :: struct {
	file: int, // index into ImGuiEditor.files
	line: int,
	col:  int,
}

// Component change callback: marks the document as needing an LSP sync.
ied_on_change :: proc "c" (user: rawptr) {
	context = runtime.default_context()
	editor := (^ImGuiEditor)(user)
	editor.lsp_dirty = true
	editor.lsp_change_frames = 0
}

EditorTheme :: enum {
	DARK,
	LIGHT,
	MONOKAI,
	SOLARIZED,
}

// Short labels: the toolbar combo is narrow so the row always fits the
// panel (long names pushed it past the right edge).
THEME_NAMES := [EditorTheme]string{
	.DARK      = "dark",
	.LIGHT     = "light",
	.MONOKAI   = "monokai",
	.SOLARIZED = "solarized",
}

// ImU32 is ABGR: (a<<24)|(b<<16)|(g<<8)|r.
col32 :: proc(ch_red: u32, ch_green: u32, ch_blue: u32, ch_alpha: u32 = 255) -> u32 {
	return (ch_alpha << 24) | (ch_blue << 16) | (ch_green << 8) | ch_red
}

// Palette slots, component Color enum order: text, keyword, declaration,
// number, string, punctuation, preprocessor, identifier, knownIdentifier,
// comment, background, cursor, selection, whitespace, matchingBracketBackground,
// matchingBracketActive, matchingBracketLevel1..3, matchingBracketError,
// lineNumber, currentLineNumber, currentLineHighlight, currentLineHighlightBorder.
theme_monokai :: proc() -> [24]u32 {
	return [24]u32{
	col32(0xF8, 0xF8, 0xF2), // text
	col32(0xF9, 0x26, 0x72), // keyword
	col32(0x66, 0xD9, 0xEF), // declaration
	col32(0xAE, 0x81, 0xFF), // number
	col32(0xE6, 0xDB, 0x74), // string
	col32(0xF8, 0xF8, 0xF2), // punctuation
	col32(0xF9, 0x26, 0x72), // preprocessor
	col32(0xF8, 0xF8, 0xF2), // identifier
	col32(0x66, 0xD9, 0xEF), // knownIdentifier
	col32(0x75, 0x71, 0x5E), // comment
	col32(0x27, 0x28, 0x22), // background
	col32(0xF8, 0xF8, 0xF0), // cursor
	col32(0x49, 0x48, 0x3E), // selection
	col32(0x3B, 0x3A, 0x32), // whitespace
	col32(0x49, 0x48, 0x3E), // matchingBracketBackground
	col32(0xA6, 0xE2, 0x2E), // matchingBracketActive
	col32(0xA6, 0xE2, 0x2E), // matchingBracketLevel1
	col32(0x66, 0xD9, 0xEF), // matchingBracketLevel2
	col32(0xFD, 0x97, 0x1F), // matchingBracketLevel3
	col32(0xF9, 0x26, 0x72), // matchingBracketError
	col32(0x75, 0x71, 0x5E), // lineNumber
	col32(0xF8, 0xF8, 0xF2), // currentLineNumber
	col32(0x3E, 0x3D, 0x32), // currentLineHighlight
	col32(0x3E, 0x3D, 0x32), // currentLineHighlightBorder
	}
}

theme_solarized :: proc() -> [24]u32 {
	return [24]u32{
	col32(0x83, 0x94, 0x96), // text (base0)
	col32(0x85, 0x99, 0x00), // keyword (green)
	col32(0x26, 0x8B, 0xD2), // declaration (blue)
	col32(0xD3, 0x36, 0x82), // number (magenta)
	col32(0x2A, 0xA1, 0x98), // string (cyan)
	col32(0x83, 0x94, 0x96), // punctuation
	col32(0xCB, 0x4B, 0x16), // preprocessor (orange)
	col32(0x83, 0x94, 0x96), // identifier
	col32(0x26, 0x8B, 0xD2), // knownIdentifier
	col32(0x58, 0x6E, 0x75), // comment (base01)
	col32(0x00, 0x2B, 0x36), // background (base03)
	col32(0x93, 0xA1, 0xA1), // cursor (base1)
	col32(0x07, 0x36, 0x42), // selection (base02)
	col32(0x07, 0x36, 0x42), // whitespace
	col32(0x07, 0x36, 0x42), // matchingBracketBackground
	col32(0xB5, 0x89, 0x00), // matchingBracketActive (yellow)
	col32(0xB5, 0x89, 0x00), // matchingBracketLevel1
	col32(0x26, 0x8B, 0xD2), // matchingBracketLevel2
	col32(0xCB, 0x4B, 0x16), // matchingBracketLevel3
	col32(0xDC, 0x32, 0x2F), // matchingBracketError (red)
	col32(0x58, 0x6E, 0x75), // lineNumber
	col32(0x93, 0xA1, 0xA1), // currentLineNumber
	col32(0x07, 0x36, 0x42), // currentLineHighlight
	col32(0x07, 0x36, 0x42), // currentLineHighlightBorder
	}
}

ied_apply_theme :: proc(editor: ^ImGuiEditor) {
	switch editor.theme {
	case .DARK:
		ite_use_dark_palette(editor.handle)
	case .LIGHT:
		ite_use_light_palette(editor.handle)
	case .MONOKAI:
		palette := theme_monokai()
		ite_set_palette_u32(editor.handle, &palette[0], len(palette))
	case .SOLARIZED:
		palette := theme_solarized()
		ite_set_palette_u32(editor.handle, &palette[0], len(palette))
	}
	// Glass mode's saved palette is stale after a theme swap; re-entering
	// glass re-saves from the new theme (wrapper resets the flag).
}

// The slangd instance backing autocomplete (nil when unavailable, the
// editor then just never pops suggestions).
ied_lsp: ^Lsp

// Render-thread callback for the autocomplete popup: syncs the document to
// slangd and returns matching completion items, newline-separated.
ied_completion_cb :: proc "c" (search_term: cstring, cursor_line: c.size_t, cursor_col: c.size_t, user: rawptr, out_buf: [^]u8, out_cap: c.size_t) -> c.int {
	context = runtime.default_context()
	editor := (^ImGuiEditor)(user)
	if ied_lsp == nil || editor.current < 0 do return 0
	doc_uri := ied_current_uri(editor)
	doc_text := string(ite_get_text(editor.handle))

	// Namespace member completion: `Space::` (with or without a typed
	// prefix after it) offers the module's public symbols directly.
	// slangd 1.8 answers `Space::` with the whole global scope instead
	// of the namespace members, so this case is handled locally against
	// the module file on disk. Falls through to slangd otherwise.
	if ns := ied_namespace_at(doc_text, int(cursor_line), int(cursor_col)); ns != "" {
		return ied_complete_namespace(ns, string(search_term), out_buf, out_cap)
	}

	items := lsp_complete(ied_lsp, doc_uri, doc_text, int(cursor_line), int(cursor_col))
	if len(items) == 0 do return 0
	match_count := 0
	written := 0
	term := strings.to_lower(string(search_term), context.temp_allocator)
	for item in items {
		// slangd ranks server-side; we only hard-filter by the typed prefix.
		if term != "" && !strings.has_prefix(strings.to_lower(item.label, context.temp_allocator), term) do continue
		if match_count >= 24 do break // keep the popup tight
		need := len(item.label) + 1
		if written + need >= int(out_cap) do break
		copy(out_buf[written:out_cap], item.label)
		written += len(item.label)
		out_buf[written] = '\n'
		written += 1
		match_count += 1
	}
	return c.int(match_count)
}

// Maps a typed namespace to its module file under src/shaders/. The
// namespace name matches the file name case-insensitively: `Space::`
// -> space.slang. "" when the namespace is unknown.
ied_namespace_module :: proc(ns: string) -> string {
	switch ns {
	case "Space":  return "space"
	case "Camera": return "camera"
	case "Noise":  return "noise"
	case "Sdf":    return "sdf"
	}
	return ""
}

// If the text before (line, col) is `<Namespace>::` — optionally with a
// partially typed member name after the `::` — returns the namespace
// name; "" otherwise. The partial member is not returned here: the
// popup passes it as `search_term` and filtering happens in
// ied_complete_namespace.
ied_namespace_at :: proc(doc_text: string, line, col: int) -> string {
	lines := strings.split_lines(doc_text, context.temp_allocator)
	if line < 0 || line >= len(lines) do return ""
	l := lines[line]
	if col < 0 || col > len(l) do return ""
	prefix := l[:col]

	// Strip a partially typed member name: `Space::pix` still counts.
	base := prefix
	if !strings.has_suffix(base, "::") {
		i := len(base)
		for i > 0 {
			c := base[i - 1]
			if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' {
				i -= 1
			} else {
				break
			}
		}
		if i == len(base) || i < 2 || base[i - 1] != ':' || base[i - 2] != ':' do return ""
		base = base[:i - 2]
	} else {
		base = base[:len(base) - 2]
	}

	// walk back over the namespace identifier
	i := len(base)
	for i > 0 {
		c := base[i - 1]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' {
			i -= 1
		} else {
			break
		}
	}
	if i == len(base) do return "" // no identifier before ::
	return base[i:]
}

// Offers the public symbols of one shared module, filtered by the typed
// prefix. Reads the module file on demand: these files are small and the
// callback fires only while the popup is open.
ied_complete_namespace :: proc(ns: string, search_term: string, out_buf: [^]u8, out_cap: c.size_t) -> c.int {
	context = runtime.default_context()
	module_name := ied_namespace_module(ns)
	if module_name == "" do return 0
	path := fmt.tprintf("src/shaders/%s.slang", module_name)
	src_bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return 0
	src := string(src_bytes)

	term := strings.to_lower(search_term, context.temp_allocator)
	match_count := 0
	written := 0
	for line in strings.split_lines(src, context.temp_allocator) {
		// public functions: `public <type> name(`; public structs: `public struct Name`
		if !strings.has_prefix(line, "public ") do continue
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 3 do continue
		name := fields[len(fields) - 1]
		if strings.has_suffix(name, "(") {
			name = name[:len(name) - 1]
		} else if fields[1] == "struct" {
			name = fields[2]
		} else {
			continue
		}
		if term != "" && !strings.has_prefix(strings.to_lower(name, context.temp_allocator), term) do continue
		if match_count >= 24 do break
		need := len(name) + 1
		if written + need >= int(out_cap) do break
		copy(out_buf[written:out_cap], name)
		written += len(name)
		out_buf[written] = '\n'
		written += 1
		match_count += 1
	}
	return c.int(match_count)
}

ied_init :: proc() -> ^ImGuiEditor {
	editor := new(ImGuiEditor)
	editor.handle = ite_create()
	ite_set_tab_size(editor.handle, 4)
	ite_set_leading_whitespace_only(editor.handle, true)
	ite_install_context_menu(editor.handle)
	editor.current = -1
	editor.current_open = -1
	editor.err_file = -1
	editor.font_size = 16
	editor.glass_alpha = 0.55
	editor.open = true
	editor.theme = .MONOKAI
	ied_apply_theme(editor)
	editor.last_open_tab = -1
	editor.status_fade = 1

	// slangd autocomplete (LSP): graceful no-op when the server is absent.
	if ied_lsp == nil {
		ied_lsp = lsp_start()
	}
	if ied_lsp != nil {
		ite_enable_completion(editor.handle, ied_completion_cb, editor)
		ite_set_change_callback(editor.handle, ied_on_change, editor)
	}

	ied_scan_dir(editor, "")
	ied_scan_scene_dirs(editor)
	ui_prefs_editor = editor
	log.infof("[imgui-editor] %d shaders under %s", len(editor.files), SHADER_DIR)
	return editor
}

// Scene units are directories under scenes/: scans each subdirectory's
// .slang files as "scenes/<unit>/<file>".
ied_scan_scene_dirs :: proc(editor: ^ImGuiEditor) {
	dir_path := fmt.tprintf("%s/scenes", SHADER_DIR)
	dir_handle, open_err := os.open(dir_path)
	if open_err != nil do return
	entries, dir_err := os.read_dir(dir_handle, -1, context.temp_allocator)
	os.close(dir_handle)
	if dir_err != nil do return
	for entry in entries {
		if entry.type != .Directory do continue
		ied_scan_dir(editor, fmt.tprintf("scenes/%s", entry.name))
	}
}

ied_scan_dir :: proc(editor: ^ImGuiEditor, sub_dir: string) {
	shader_dir := SHADER_DIR
	if sub_dir != "" {
		shader_dir = fmt.tprintf("%s/%s", SHADER_DIR, sub_dir)
	}
	dir_handle, open_err := os.open(shader_dir)
	if open_err != nil do return
	entries, dir_err := os.read_dir(dir_handle, -1, context.allocator)
	os.close(dir_handle)
	if dir_err != nil do return
	for entry in entries {
		if entry.type == .Directory {
			// Scenes live in per-scene folders (scenes/apple/apple.slang):
			// recurse so FILES and tabs see them.
			next := entry.name
			if sub_dir != "" {
				next = fmt.tprintf("%s/%s", sub_dir, entry.name)
			}
			ied_scan_dir(editor, next)
			continue
		}
		if !strings.has_suffix(entry.name, ".slang") do continue
		name := strings.trim_suffix(entry.name, ".slang")
		if sub_dir != "" {
			name = fmt.tprintf("%s/%s", sub_dir, name)
		}
		ied_append_file(editor, name)
	}
}

// Scans the user scene tree (gis_scenes/): files register under the
// "gis_scenes/<unit>/<file>" prefix, mirroring ied_scan_scene_dirs so
// FILES, tabs and the graph see user scenes next to the built-ins.
ied_scan_user_scenes :: proc(editor: ^ImGuiEditor) {
	user_dir := scene_user_dir()
	entries, scan_err := os.read_directory_by_path(user_dir, 0, context.temp_allocator)
	if scan_err != nil do return
	for entry in entries {
		if entry.type != .Directory do continue
		unit_dir := fmt.tprintf("%s/%s", user_dir, entry.name)
		files, dir_err := os.read_directory_by_path(unit_dir, 0, context.temp_allocator)
		if dir_err != nil do continue
		for file in files {
			if file.type != .Regular do continue
			if !strings.has_suffix(file.name, ".slang") do continue
			name := strings.trim_suffix(file.name, ".slang")
			ied_append_file(editor, fmt.tprintf("%s/%s/%s", USER_SCENES_DIR, entry.name, name))
		}
	}
}

// Append-only insert into editor.files (relative name, no .slang):
// rescans must keep OpenDoc.file indices stable, so an already-listed
// name is left untouched.
ied_append_file :: proc(editor: ^ImGuiEditor, name: string) {
	exists := false
	for existing_file in editor.files {
		if existing_file == name {
			exists = true
			break
		}
	}
	if exists do return
	append(&editor.files, strings.clone(name))
}

// Rediscover shader files (template-created scenes, files added
// externally). Deleted files stay listed: removing entries would
// invalidate OpenDoc.file indices.
ied_rescan :: proc(editor: ^ImGuiEditor) {
	ied_scan_dir(editor, "")
	ied_scan_scene_dirs(editor)
	ied_scan_user_scenes(editor)
}

// On-disk .slang path for a files-list name. Names under gis_scenes/
// are project-root-relative (the user tree sits outside src/shaders);
// everything else resolves under SHADER_DIR.
ied_file_path_for_rel :: proc(rel: string) -> string {
	if strings.has_prefix(rel, "gis_scenes/") {
		return fmt.tprintf("%s.slang", rel)
	}
	return fmt.tprintf("%s/%s.slang", SHADER_DIR, rel)
}

ied_file_path :: proc(editor: ^ImGuiEditor, file_idx: int) -> string {
	return ied_file_path_for_rel(editor.files[file_idx])
}

ied_current_uri :: proc(editor: ^ImGuiEditor) -> string {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return fmt.tprintf("file://%s/%s", cwd, ied_file_path(editor, editor.current))
}

// Make open_docs[open_idx] the visible document, loading its buffer from the
// stash (or disk on first open). Does NOT stash the outgoing document: use
// ied_switch for user-driven tab switches.
ied_show :: proc(editor: ^ImGuiEditor, open_idx: int) {
	shown_doc := &editor.open_docs[open_idx]
	if !shown_doc.loaded {
		data, read_err := os.read_entire_file(ied_file_path(editor, shown_doc.file), context.allocator)
		if read_err != nil {
			editor.status = fmt.bprintf(editor.status_buf[:], tr("could not read %s"), ied_file_path(editor, shown_doc.file))
			return
		}
		shown_doc.text = strings.clone(string(data))
		shown_doc.loaded = true
		if shown_doc.last_good == "" do shown_doc.last_good = strings.clone(shown_doc.text)
	}
	editor.current_open = open_idx
	editor.current = shown_doc.file
	ite_set_text(editor.handle, strings.clone_to_cstring(shown_doc.text, context.temp_allocator))
	editor.saved_undo = ite_get_undo_index(editor.handle)
	// Force a re-sync of the freshly shown document to slangd.
	editor.lsp_dirty = true
	editor.lsp_change_frames = 18
}

// Switch the visible document to open_docs[open_idx], stashing the outgoing
// buffer so unsaved edits survive the round-trip.
ied_switch :: proc(editor: ^ImGuiEditor, open_idx: int) {
	if open_idx < 0 || open_idx >= len(editor.open_docs) || open_idx == editor.current_open do return
	if editor.current_open >= 0 && editor.current_open < len(editor.open_docs) {
		outgoing_doc := &editor.open_docs[editor.current_open]
		delete(outgoing_doc.text)
		outgoing_doc.text = strings.clone(string(ite_get_text(editor.handle)))
		outgoing_doc.loaded = true
		outgoing_doc.dirty = outgoing_doc.dirty || ite_get_undo_index(editor.handle) != editor.saved_undo
	}
	ied_show(editor, open_idx)
}

// Open file idx in a tab (or switch to its tab when already open).
ied_load :: proc(editor: ^ImGuiEditor, file_idx: int) {
	if file_idx < 0 || file_idx >= len(editor.files) do return
	for open_doc, open_idx in editor.open_docs {
		if open_doc.file == file_idx {
			ied_switch(editor, open_idx)
			return
		}
	}
	append(&editor.open_docs, OpenDoc{file = file_idx})
	ied_switch(editor, len(editor.open_docs) - 1)
}

// Close the tab open_docs[open_idx]; shows a neighbor when the closed tab was
// the visible one.
ied_close :: proc(editor: ^ImGuiEditor, open_idx: int) {
	if open_idx < 0 || open_idx >= len(editor.open_docs) do return
	delete(editor.open_docs[open_idx].text)
	delete(editor.open_docs[open_idx].last_good)
	ordered_remove(&editor.open_docs, open_idx)
	if editor.current_open > open_idx {
		editor.current_open -= 1
	} else if editor.current_open == open_idx {
		// The visible document is gone; show a neighbor without stashing.
		if len(editor.open_docs) > 0 {
			ied_show(editor, min(open_idx, len(editor.open_docs) - 1))
		} else {
			editor.current_open = -1
			editor.current = -1
			ite_set_text(editor.handle, "")
			editor.saved_undo = ite_get_undo_index(editor.handle)
			editor.status = ""
		}
	}
}

ied_load_named :: proc(editor: ^ImGuiEditor, name: string) {
	for file_name, file_idx in editor.files {
		if file_name == name {
			ied_load(editor, file_idx)
			return
		}
	}
}
// The files-list prefix of a scene unit's own directory: gis_scenes for
// user scenes (their tree is outside src/shaders), scenes/ for built-ins.
ied_unit_prefix :: proc(unit: string) -> string {
	if scene_root_dir(unit) == USER_SCENES_DIR {
		return fmt.tprintf("%s/%s/", USER_SCENES_DIR, unit)
	}
	return fmt.tprintf("scenes/%s/", unit)
}

// Closes open docs under a scene unit's prefix. On a scene switch the
// previous unit's tabs go away, EXCEPT dirty ones: unsaved work is never
// destroyed, so those stay until the user saves (ied_save_all reaps them
// once clean).
ied_close_unit :: proc(editor: ^ImGuiEditor, unit: string) {
	if unit == "" do return
	prefix := ied_unit_prefix(unit)
	live_undo := ite_get_undo_index(editor.handle)
	// Walk backwards: ied_close mutates open_docs in place.
	for i := len(editor.open_docs) - 1; i >= 0; i -= 1 {
		tab_doc := &editor.open_docs[i]
		doc_rel := editor.files[tab_doc.file]
		if !strings.has_prefix(doc_rel, prefix) do continue
		dirty := tab_doc.dirty || (i == editor.current_open && live_undo != editor.saved_undo)
		if dirty do continue
		ied_close(editor, i)
	}
}

// Closes every open tab whose file index points at rel. Called before a
// rename removes/invalidates the name; callers must have saved first.
ied_close_file :: proc(editor: ^ImGuiEditor, rel: string) {
	// Walk backwards: ied_close mutates open_docs in place.
	for i := len(editor.open_docs) - 1; i >= 0; i -= 1 {
		if editor.files[editor.open_docs[i].file] == rel {
			ied_close(editor, i)
		}
	}
}

// Drops rel from editor.files and reindexes open tabs. ied_rescan is
// append-only by design (indices are OpenDoc state), so a renamed/
// deleted file needs this explicit removal to leave the lists.
ied_forget_file :: proc(editor: ^ImGuiEditor, rel: string) {
	ied_close_file(editor, rel)
	idx := -1
	for file_name, i in editor.files {
		if file_name == rel {
			idx = i
			break
		}
	}
	if idx < 0 do return
	delete(editor.files[idx])
	ordered_remove(&editor.files, idx)
	// Reindex every doc: OpenDoc.file points into editor.files.
	for &doc in editor.open_docs {
		if doc.file > idx do doc.file -= 1
	}
	// Visible-file tracking follows the same index space.
	if editor.current > idx {
		editor.current -= 1
	} else if editor.current == idx {
		editor.current = -1
	}
}

// Parse a slang import line: `import "../common";` (quoted, resolved
// relative to the importing file) or `import common;` (bare module,
// resolved at the SHADER_DIR root). Returns the raw import target.
ied_parse_import :: proc(line: string) -> (import_target: string, parsed_ok: bool) {
	trimmed := strings.trim_left_space(line)
	if !strings.has_prefix(trimmed, "import") do return "", false
	trimmed = strings.trim_left_space(trimmed[len("import"):])
	if trimmed == "" do return "", false
	if trimmed[0] == '"' {
		quote_end := strings.index_byte(trimmed[1:], '"')
		if quote_end < 0 do return "", false
		return trimmed[1:1 + quote_end], true
	}
	semi_end := strings.index_byte(trimmed, ';')
	if semi_end < 0 do return "", false
	return strings.trim_space(trimmed[:semi_end]), true
}

// Resolve an import target to a files-list name (relative to SHADER_DIR,
// no extension): quoted relative paths against the importing file's
// directory, bare names at the root.
ied_resolve_import :: proc(from_rel, target: string) -> string {
	target := strings.trim_suffix(target, ".slang")
	full := target
	if strings.has_prefix(target, ".") {
		if slash := strings.last_index(from_rel, "/"); slash >= 0 {
			full = fmt.tprintf("%s/%s", from_rel[:slash], target)
		}
	}
	// Normalize: resolve "." and ".." segments.
	parts := strings.split(full, "/", context.temp_allocator)
	normalized: [dynamic]string
	for part in parts {
		switch part {
		case "", ".":
		case "..":
			if len(normalized) > 0 do pop(&normalized)
		case:
			append(&normalized, part)
		}
	}
	return strings.join(normalized[:], "/", context.temp_allocator)
}

// The scene file plus every transitively imported module, breadth-first,
// scene first. Names match ImGuiEditor.files entries.
ied_scene_files :: proc(editor: ^ImGuiEditor, scene_rel: string) -> [dynamic]string {
	result := make([dynamic]string, 0, 8, context.temp_allocator)
	visited := make(map[string]bool, 16, context.temp_allocator)
	queue := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&queue, scene_rel)
	visited[scene_rel] = true
	for i := 0; i < len(queue); i += 1 {
		module_rel := queue[i]
		data, read_err := os.read_entire_file(
			ied_file_path_for_rel(module_rel),
			context.temp_allocator,
		)
		if read_err != nil do continue
		append(&result, module_rel)
		for line in strings.split_lines(string(data), context.temp_allocator) {
			import_target, parsed_ok := ied_parse_import(line)
			if !parsed_ok do continue
			resolved := ied_resolve_import(module_rel, import_target)
			if resolved == "" || visited[resolved] do continue
			visited[resolved] = true
			append(&queue, resolved)
		}
	}
	return result
}

// The files-list name of a scene: scenes/<title>/<title>.slang for
// built-ins, gis_scenes/<title>/<title>.slang for user scenes, matched
// by base name. "" when unknown.
ied_scene_rel :: proc(editor: ^ImGuiEditor, scene_name: string) -> string {
	for file_name in editor.files {
		if !strings.has_prefix(file_name, ied_unit_prefix(scene_name)) do continue
		base := file_name
		if slash := strings.last_index(base, "/"); slash >= 0 {
			base = base[slash + 1:]
		}
		if base == scene_name {
			return file_name
		}
	}
	return ""
}

// Follow the rendered scene: open its tab plus a tab per imported module
// (the scene ends up visible). Runs on scene change only; tabs the user
// opened for unrelated files are left alone.
ied_open_scene :: proc(editor: ^ImGuiEditor, scene_name: string) {
	if scene_name == editor.last_scene do return
	// Leaving a scene: its tabs close (dirty ones wait for the user to
	// save; they are reaped by ied_save_all once clean).
	old_scene := editor.last_scene
	editor.last_scene = scene_name
	ied_close_unit(editor, old_scene)
	scene_rel := ied_scene_rel(editor, scene_name)
	if scene_rel == "" do return
	files := ied_scene_files(editor, scene_rel)
	for module_rel, module_idx in files {
		if module_idx == 0 do continue // the scene itself is opened last
		ied_load_named(editor, module_rel)
	}
	ied_load_named(editor, scene_rel)
	// Force a re-sync of the freshly shown file to slangd.
	editor.lsp_dirty = true
	editor.lsp_change_frames = 18
}

// How many open tabs hold unsaved edits (the visible one's live undo
// state included). Gates ESC-quit: unsaved work must not vanish on a
// key the muscle memory reads as "close".
ied_dirty_count :: proc(editor: ^ImGuiEditor) -> int {
	dirty := 0
	live_undo := ite_get_undo_index(editor.handle)
	for tab_doc, i in editor.open_docs {
		if tab_doc.dirty || (i == editor.current_open && live_undo != editor.saved_undo) {
			dirty += 1
		}
	}
	return dirty
}

// Save every modified open document. Shader files are the app's only
// persistent state, so this IS the application-wide save (Cmd+S and the
// toolbar's "save all"). The visible document's text is stashed first so
// its latest edits are included. Returns the number of files written.
ied_save_all :: proc(editor: ^ImGuiEditor) -> int {
	if editor.current_open >= 0 && editor.current_open < len(editor.open_docs) {
		visible_doc := &editor.open_docs[editor.current_open]
		delete(visible_doc.text)
		visible_doc.text = strings.clone(string(ite_get_text(editor.handle)))
		visible_doc.loaded = true
		visible_doc.dirty = visible_doc.dirty || ite_get_undo_index(editor.handle) != editor.saved_undo
	}
	saved := 0
	for &open_doc in editor.open_docs {
		if !open_doc.loaded || !open_doc.dirty do continue
		path := ied_file_path(editor, open_doc.file)
		if os.write_entire_file(path, transmute([]u8)open_doc.text) != nil {
			editor.status = fmt.bprintf(editor.status_buf[:], tr("ERROR writing %s"), path)
			continue
		}
		open_doc.dirty = false
		saved += 1
	}
	if editor.current_open >= 0 {
		editor.saved_undo = ite_get_undo_index(editor.handle)
	}
	// Reap the now-clean tabs that don't belong to the current scene:
	// dirty tabs survived the switch so the user could save them; once
	// saved, they go away (scene and shared files never close here).
	if saved > 0 && editor.last_scene != "" {
		current_prefix := ied_unit_prefix(editor.last_scene)
		for i := len(editor.open_docs) - 1; i >= 0; i -= 1 {
			tab_doc := &editor.open_docs[i]
			doc_rel := editor.files[tab_doc.file]
			if !strings.has_prefix(doc_rel, "scenes/") && !strings.has_prefix(doc_rel, "gis_scenes/") do continue
			if strings.has_prefix(doc_rel, current_prefix) do continue
			if tab_doc.dirty do continue
			ied_close(editor, i)
		}
	}
	now_h, now_m, now_s := time.clock(time.now())
	if saved > 0 {
		editor.status = fmt.bprintf(editor.status_buf[:], tr("saved %d file(s) at %02d:%02d:%02d"), saved, now_h, now_m, now_s)
	} else {
		editor.status = fmt.bprintf(editor.status_buf[:], "%s", tr("nothing to save"))
	}
	return saved
}

ied_capture_last_good :: proc(editor: ^ImGuiEditor) {
	for &open_doc in editor.open_docs {
		if !open_doc.loaded || open_doc.dirty do continue
		data, read_err := os.read_entire_file(ied_file_path(editor, open_doc.file), context.temp_allocator)
		if read_err != nil do continue
		delete(open_doc.last_good)
		open_doc.last_good = strings.clone(string(data))
	}
}

ied_has_current_build_error :: proc(editor: ^ImGuiEditor) -> bool {
	if editor.current < 0 do return false
	current_rel := editor.files[editor.current]
	sync.mutex_lock(&scene_build_mu)
	defer sync.mutex_unlock(&scene_build_mu)
	for build_error in build_errors {
		if build_error.file == current_rel do return true
	}
	return false
}

ied_restore_last_good :: proc(editor: ^ImGuiEditor) -> bool {
	if editor.current_open < 0 || editor.current_open >= len(editor.open_docs) do return false
	current_doc := &editor.open_docs[editor.current_open]
	if current_doc.last_good == "" do return false
	ite_set_text(editor.handle, strings.clone_to_cstring(current_doc.last_good, context.temp_allocator))
	delete(current_doc.text)
	current_doc.text = strings.clone(current_doc.last_good)
	current_doc.loaded = true
	current_doc.dirty = true
	editor.lsp_dirty = true
	editor.lsp_change_frames = 0
	editor.status = fmt.bprintf(editor.status_buf[:], tr("restored last compiled version of %s"), editor.files[current_doc.file])
	return true
}

// Find a definition for word in text: a top-level line (column 0) declaring
// `word` as a function ("<ret> word(") or struct ("struct word", tolerating
// modifiers like "public").
ied_find_definition :: proc(text: string, word: string) -> (line: int, found: bool) {
	if word == "" do return 0, false
	needle := strings.concatenate({word, "("}, context.temp_allocator)
	struct_needle := strings.concatenate({"struct ", word}, context.temp_allocator)
	lines := strings.split_lines(text, context.temp_allocator)
	for line_text, line_idx in lines {
		if line_text == "" || line_text[0] == ' ' || line_text[0] == '\t' || line_text[0] == '/' do continue
		if strings.contains(line_text, struct_needle) do return line_idx, true
		paren_idx := strings.index(line_text, needle)
		if paren_idx > 0 {
			line_prefix := line_text[:paren_idx]
			if !strings.contains(line_prefix, "=") do return line_idx, true
		}
	}
	return 0, false
}

// Symbol docs for a word in text: the trimmed definition line (multi-line
// signatures joined) plus the contiguous //-comment block directly above
// it, newest line last. All strings use the temp allocator.
ied_symbol_in_text :: proc(text: string, word: string) -> (signature_text, doc_text: string, found: bool) {
	def_line, found_def := ied_find_definition(text, word)
	if !found_def do return "", "", false
	lines := strings.split_lines(text, context.temp_allocator)
	signature_text = strings.trim_space(lines[def_line])
	// Join continuation lines while the signature has no closing paren
	// (Slang parameters often wrap).
	for line_idx := def_line + 1; !strings.contains(signature_text, ")") && line_idx < len(lines); line_idx += 1 {
		signature_text = fmt.tprintf("%s %s", signature_text, strings.trim_space(lines[line_idx]))
	}
	// Doc block: contiguous // lines directly above the definition.
	sig_end := def_line - 1
	for sig_end >= 0 {
		gap_line := strings.trim_space(lines[sig_end])
		if gap_line != "" do break
		sig_end -= 1
	}
	doc_start := sig_end
	for doc_start >= 0 {
		comment_line := strings.trim_space(lines[doc_start])
		if !strings.has_prefix(comment_line, "//") do break
		doc_start -= 1
	}
	if sig_end >= 0 && doc_start < sig_end {
		for line_idx := doc_start + 1; line_idx <= sig_end; line_idx += 1 {
			doc_line := strings.trim_prefix(strings.trim_space(lines[line_idx]), "//")
			if doc_text == "" {
				doc_text = strings.trim_space(doc_line)
			} else {
				doc_text = fmt.tprintf("%s\n%s", doc_text, strings.trim_space(doc_line))
			}
		}
	}
	return signature_text, doc_text, true
}

// Curated docs for the Slang builtins the trail uses most. Consulted only
// when no user definition resolves, so project symbols always win.
IedBuiltinParam :: struct {
	name, desc: string,
}
IedBuiltinDoc :: struct {
	name, sig, doc: string,
	also:       string, // related builtins, clickable in the tooltip
	params:     []IedBuiltinParam,
}
IED_BUILTIN_DOCS := []IedBuiltinDoc {
	{
		"clamp",
		"T clamp<T>(T x, T minVal, T maxVal)",
		"Constrains x to `[minVal, maxVal]`: below minVal returns minVal, above maxVal returns maxVal. Works component-wise on vectors. `clamp(uv, 0.0, 1.0)` keeps coordinates inside the unit square.",
		"lerp, smoothstep",
		{{"x", "the value to constrain"}, {"minVal", "lower bound"}, {"maxVal", "upper bound"}},
	},
	{
		"lerp",
		"T lerp<T>(T a, T b, S t)",
		"Linear interpolation: `a + (b - a) * t`. t = 0 gives a, t = 1 gives b, 0.5 the midpoint; t outside `[0,1]` extrapolates. GLSL calls this `mix`.",
		"smoothstep, clamp",
		{{"a", "value at t = 0"}, {"b", "value at t = 1"}, {"t", "interpolant; outside [0,1] extrapolates"}},
	},
	{
		"smoothstep",
		"T smoothstep<T>(T edge0, T edge1, T x)",
		"Smooth Hermite transition from 0 to 1 as x goes from edge0 to edge1, with zero slope at both ends. The standard way to soften SDF edges: `smoothstep(-word, word, d)`.",
		"step, clamp, fwidth",
		{{"edge0", "where the transition starts (returns 0)"}, {"edge1", "where it ends (returns 1)"}, {"x", "value to remap"}},
	},
	{
		"step",
		"T step<T>(T edge, T x)",
		"0.0 when x < edge, 1.0 otherwise. A hard threshold; compare with smoothstep for a soft edge. `step(0.5, uv.x)` splits the image vertically.",
		"smoothstep, clamp",
		{{"edge", "threshold"}, {"x", "value to test"}},
	},
	{
		"fract",
		"T fract<T>(T x)",
		"Fractional part: `x - floor(x)`, always in `[0,1)`. Tiling and repetition primitive: `fract(uv * 4.0)` repeats the pattern 4x per axis.",
		"floor, lerp",
		{{"x", "value; the integer part is discarded"}},
	},
	{
		"ddx",
		"T ddx<T>(T x)",
		"Partial derivative of x along screen-space X, estimated from 2x2 pixel quads. Base of anti-aliased edges: `fwidth(d) = abs(ddx(d)) + abs(ddy(d))`.",
		"ddy, fwidth",
		{{"x", "value to differentiate"}},
	},
	{
		"ddy",
		"T ddy<T>(T x)",
		"Partial derivative of x along screen-space Y, estimated from 2x2 pixel quads. Pair with ddx for fwidth-based filtering.",
		"ddx, fwidth",
		{{"x", "value to differentiate"}},
	},
	{
		"fwidth",
		"T fwidth<T>(T x)",
		"Sum of absolute derivatives: `abs(ddx(x)) + abs(ddy(x))`. The standard anti-aliasing width for SDF edges: `smoothstep(-word, word, d)` with `w = fwidth(d) * 1.5`.",
		"ddx, ddy, smoothstep",
		{{"x", "value to differentiate"}},
	},
	{
		"floor",
		"T floor<T>(T x)",
		"Largest integer not greater than x. `floor(uv * 4.0)` picks the tile index while `fract` gives the position inside it.",
		"fract",
		{{"x", "value to round down"}},
	},
}

// Where a word is defined (current file first, then the other shaders):
// file name and 0-indexed line, for the tooltip footer.
ied_symbol_location :: proc(editor: ^ImGuiEditor, word: string) -> (file: string, line: int, found: bool) {
	if current_def, current_ok := ied_find_definition(string(ite_get_text(editor.handle)), word); current_ok {
		return editor.files[editor.current], current_def, true
	}
	for file_name, file_idx in editor.files {
		if file_idx == editor.current do continue
		data, read_err := os.read_entire_file(ied_file_path(editor, file_idx), context.temp_allocator)
		if read_err != nil do continue
		if other_def, other_ok := ied_find_definition(string(data), word); other_ok {
			return file_name, other_def, true
		}
	}
	return "", 0, false
}

// Swap the pinned tooltip to a related builtin (see-also link click):
// content and footer change, the tooltip stays put.
hover_swap_builtin :: proc(editor: ^ImGuiEditor, name: string) {
	for builtin in IED_BUILTIN_DOCS {
		if builtin.name == name {
			delete(editor.hover_word)
			editor.hover_word = strings.clone(builtin.name)
			delete(editor.hover_sig)
			editor.hover_sig = strings.clone(builtin.sig)
			delete(editor.hover_doc)
			editor.hover_doc = strings.clone(builtin.doc)
			if editor.hover_footer != "" {
				delete(editor.hover_footer)
				editor.hover_footer = ""
			}
			if editor.hover_dwell < 25 do editor.hover_dwell = 25
			return
		}
	}
}

// The builtin entry for the hovered word, or nil for project symbols.
hover_builtin_of :: proc(editor: ^ImGuiEditor) -> ^IedBuiltinDoc {
	for &builtin in IED_BUILTIN_DOCS {
		if builtin.name == editor.hover_word do return &builtin
	}
	return nil
}

// Minimal inline markdown for the docs tooltip: `code` spans render in
// the accent amber; lines without code spans wrap at the tooltip width.
hover_render_md :: proc(text: string) {
	code_col := ACCENT
	for line in strings.split_lines(text, context.temp_allocator) {
		if !strings.contains(line, "`") {
			im.TextWrapped(strings_to_c(line))
			continue
		}
		rest := line
		for len(rest) > 0 {
			span_start := strings.index(rest, "`")
			if span_start < 0 {
				im.TextUnformatted(strings_to_c(rest))
				break
			}
			if span_start > 0 {
				im.TextUnformatted(strings_to_c(rest[:span_start]))
				im.SameLine(0, 0)
			}
			after := rest[span_start + 1:]
			span_end := strings.index(after, "`")
			if span_end < 0 {
				// Unmatched backtick: render the rest literally.
				im.TextUnformatted(strings_to_c(rest[span_start:]))
				break
			}
			im.TextColored(code_col, "%s", strings_to_c(after[:span_end]))
			rest = after[span_end + 1:]
			if len(rest) > 0 do im.SameLine(0, 0)
		}
	}
}

// Dismiss the hover docs tooltip; ESC maps here before app quit.
ied_hover_close :: proc(editor: ^ImGuiEditor) {
	editor.hover_dwell = 0
	editor.hover_shown = false
	if editor.hover_sig != "" {
		delete(editor.hover_sig)
		editor.hover_sig = ""
		delete(editor.hover_doc)
		editor.hover_doc = ""
	}
	if editor.hover_footer != "" {
		delete(editor.hover_footer)
		editor.hover_footer = ""
	}
	editor.hover_doc_scroll = 0
}

// Resolve a symbol for hover docs: current file first, then the other
// shaders (same search order as goto-definition), then the builtin table.
ied_lookup_symbol :: proc(editor: ^ImGuiEditor, word: string) -> (signature_text, doc_text: string, found: bool) {
	if editor_sig, editor_doc, editor_ok := ied_symbol_in_text(string(ite_get_text(editor.handle)), word); editor_ok {
		return editor_sig, editor_doc, true
	}
	for file_name, file_idx in editor.files {
		if file_idx == editor.current do continue
		data, read_err := os.read_entire_file(ied_file_path(editor, file_idx), context.temp_allocator)
		if read_err != nil do continue
		if file_sig, file_doc, file_ok := ied_symbol_in_text(string(data), word); file_ok {
			return file_sig, file_doc, true
		}
	}
	for builtin in IED_BUILTIN_DOCS {
		if builtin.name == word do return builtin.sig, builtin.doc, true
	}
	return "", "", false
}

// Whole-word replace of old_name with new_name in text (identifier
// boundaries on both sides, so "fbm" doesn't touch "afbm"/"fbm2").
// Returns the original string and 0 when nothing matched.
text_replace_word :: proc(text, old_name, new_name: string) -> (string, int) {
	if old_name == "" do return text, 0
	text_builder := strings.builder_make(context.temp_allocator)
	count := 0
	start := 0
	for start <= len(text) - len(old_name) {
		match_idx := strings.index(text[start:], old_name)
		if match_idx < 0 do break
		match_pos := start + match_idx
		match_end := match_pos + len(old_name)
		is_word := (match_pos == 0 || !sg_is_ident(text[match_pos - 1])) && (match_end == len(text) || !sg_is_ident(text[match_end]))
		if !is_word {
			strings.write_string(&text_builder, text[start:match_end])
			start = match_end
			continue
		}
		strings.write_string(&text_builder, text[start:match_pos])
		strings.write_string(&text_builder, new_name)
		start = match_end
		count += 1
	}
	if count == 0 do return text, 0
	strings.write_string(&text_builder, text[start:])
	return strings.to_string(text_builder), count
}

// Slang keywords/builtin types: renaming one of these would corrupt every
// file, so the rename command refuses them outright.
IED_KEYWORDS := []string {
	"if", "else", "for", "while", "switch", "case", "break", "continue", "return",
	"struct", "class", "import", "public", "static", "const", "in", "out", "inout",
	"void", "bool", "int", "uint", "float", "half", "double", "true", "false",
	"let", "var", "cbuffer", "typedef", "enum", "interface", "namespace",
	"groupshared", "uniform", "discard",
	"bool2", "bool3", "bool4", "int2", "int3", "int4", "uint2", "uint3", "uint4",
	"float2", "float3", "float4", "half2", "half3", "half4",
	"double2", "double3", "double4",
	"Texture2D", "Texture3D", "TextureCube", "RWTexture2D", "SamplerState",
	"ConstantBuffer", "vector", "matrix",
}

ied_is_keyword :: proc(word: string) -> bool {
	for keyword in IED_KEYWORDS {
		if word == keyword do return true
	}
	return false
}

ied_open_doc :: proc(editor: ^ImGuiEditor, file_idx: int) -> (^OpenDoc, bool) {
	for &open_doc in editor.open_docs {
		if open_doc.file == file_idx do return &open_doc, true
	}
	return nil, false
}

// Renames old_name to new_name in every shader file (the context menu's
// "Rename symbol" command). The current document is replaced in the
// component, open tabs in their stash, the rest on disk; every touched
// file is written. NOTE: textual (not semantic) rename: occurrences in
// comments and strings are replaced too.
ied_rename :: proc(editor: ^ImGuiEditor, old_name, new_name: string) {
	if old_name == "" || new_name == "" || old_name == new_name do return
	if ied_is_keyword(old_name) {
		editor.status = fmt.bprintf(editor.status_buf[:], tr("refusing to rename keyword %s"), old_name)
		return
	}
	total := 0
	files_changed := 0
	for file_name, file_idx in editor.files {
		text := ""
		if file_idx == editor.current {
			text = string(ite_get_text(editor.handle))
		} else if open_doc, open_ok := ied_open_doc(editor, file_idx); open_ok && open_doc.loaded {
			text = open_doc.text
		} else {
			data, read_err := os.read_entire_file(ied_file_path(editor, file_idx), context.temp_allocator)
			if read_err != nil do continue
			text = string(data)
		}
		new_text, count := text_replace_word(text, old_name, new_name)
		if count == 0 do continue
		total += count
		files_changed += 1
		if file_idx == editor.current {
			ite_set_text(editor.handle, strings.clone_to_cstring(new_text, context.temp_allocator))
			// The file write below matches the component content: not dirty.
			editor.saved_undo = ite_get_undo_index(editor.handle)
			editor.lsp_dirty = true
		} else if open_doc, open_ok := ied_open_doc(editor, file_idx); open_ok {
			delete(open_doc.text)
			open_doc.text = strings.clone(new_text)
			open_doc.loaded = true
			open_doc.dirty = false // written below
		}
		if os.write_entire_file(ied_file_path(editor, file_idx), transmute([]u8)new_text) != nil {
			editor.status = fmt.bprintf(editor.status_buf[:], tr("ERROR writing %s"), ied_file_path(editor, file_idx))
			return
		}
	}
	editor.status = fmt.bprintf(editor.status_buf[:],
		tr("renamed %s → %s: %d occurrence(s) in %d file(s)"),
		old_name,
		new_name,
		total,
		files_changed,
	)
}

// Pushes a position onto the navigation history (dedup against the last
// entry; keeps the newest 32).
ied_nav_push :: proc(editor: ^ImGuiEditor, nav_pos: NavPos) {
	if history_len := len(editor.nav_history); history_len > 0 && editor.nav_history[history_len - 1] == nav_pos do return
	append(&editor.nav_history, nav_pos)
	if len(editor.nav_history) > 32 {
		ordered_remove(&editor.nav_history, 0)
	}
}

ied_nav_cursor :: proc(editor: ^ImGuiEditor) -> NavPos {
	return NavPos {
		file = editor.current,
		line = int(ite_get_cursor_line(editor.handle)),
		col  = int(ite_get_cursor_col(editor.handle)),
	}
}

// Option+'-': jump back to the previous cursor position (file included).
ied_nav_back :: proc(editor: ^ImGuiEditor) {
	if len(editor.nav_history) == 0 {
		editor.status = fmt.bprintf(editor.status_buf[:], "%s", tr("no previous position"))
		return
	}
	nav_pos := pop(&editor.nav_history)
	if nav_pos.file >= 0 && nav_pos.file != editor.current {
		ied_load(editor, nav_pos.file)
	}
	ite_set_cursor_pos(editor.handle, c.size_t(nav_pos.line), c.size_t(nav_pos.col))
	// The jump is the new snapshot: don't re-record it as a "big move".
	editor.nav_snapshot = NavPos{file = editor.current, line = nav_pos.line, col = nav_pos.col}
	editor.nav_valid = true
	editor.status = fmt.bprintf(editor.status_buf[:], tr("back to %s:%d:%d"), editor.files[editor.current], nav_pos.line + 1, nav_pos.col + 1)
}

// Per-frame cursor tracking: moves larger than 8 lines (or across files)
// push the previous position onto the history; small moves just update
// the snapshot silently.
ied_nav_tick :: proc(editor: ^ImGuiEditor) {
	if editor.current < 0 {
		editor.nav_valid = false
		return
	}
	nav_pos := ied_nav_cursor(editor)
	if !editor.nav_valid {
		editor.nav_snapshot = nav_pos
		editor.nav_valid = true
		return
	}
	if nav_pos.file != editor.nav_snapshot.file || abs(nav_pos.line - editor.nav_snapshot.line) > 8 {
		ied_nav_push(editor, editor.nav_snapshot)
	}
	editor.nav_snapshot = nav_pos
}

// Jump to the definition of word (current file, then the other shaders).
ied_goto_definition :: proc(editor: ^ImGuiEditor, word: string) {
	// Record the origin so Option+'-' returns here.
	if editor.current >= 0 {
		ied_nav_push(editor, ied_nav_cursor(editor))
	}
	if current_def, current_ok := ied_find_definition(string(ite_get_text(editor.handle)), word); current_ok {
		ite_goto_line(editor.handle, c.size_t(current_def))
		editor.status = fmt.bprintf(editor.status_buf[:], tr("%s: definition in %s.slang:%d"), word, editor.files[editor.current], current_def + 1)
		return
	}
	for file_name, file_idx in editor.files {
		if file_idx == editor.current do continue
		data, read_err := os.read_entire_file(ied_file_path(editor, file_idx), context.allocator)
		if read_err != nil do continue
		if other_def, other_ok := ied_find_definition(string(data), word); other_ok {
			ied_load(editor, file_idx)
			ite_goto_line(editor.handle, c.size_t(other_def))
			editor.status = fmt.bprintf(editor.status_buf[:], tr("%s: definition in %s.slang:%d"), word, file_name, other_def + 1)
			return
		}
	}
	editor.status = fmt.bprintf(editor.status_buf[:], tr("%s: no definition found"), word)
}

ied_request_goto_word :: proc(editor: ^ImGuiEditor, word: string) {
	if word == "" do return
	delete(editor.goto_word)
	editor.goto_word = strings.clone(word)
	editor.goto_pending = true
}

// Per-frame non-UI work: self-test driver, deferred goto-definition, the
// context-menu goto channel, the debounced LSP sync, and the diagnostics
// push. Runs regardless of sidebar mode so diagnostics keep flowing.
// Self-test driver: exercises goto/hover/docs/rename/glass/LSP flows
// without mouse input (--ied-test). Split out of ied_tick (KISS).
ied_selftest_tick :: proc(editor: ^ImGuiEditor) {
	ied_selftest_frame += 1
	// Live hover drive: hold the injected mouse where the sweep found
	// smoothstep so the real capture + dwell path runs (checked at 290).
	if hover_inject_active && ied_selftest_frame > 250 && ied_selftest_frame < 290 {
		imgui_io := im.GetIO()
		im.IO_AddMousePosEvent(imgui_io, hover_inject.x, hover_inject.y)
	}
	switch ied_selftest_frame {
	case 30:
		// Cross-file: hash21 lives in common.slang, used by scenes.
		if editor.current >= 0 {
			ied_request_goto_word(editor, "hash21")
		}
	case 45:
		cursor_line := ite_get_cursor_line(editor.handle)
		current_file := editor.current >= 0 ? editor.files[editor.current] : "?"
		// Expected: file switched to "common" at hash21's definition line.
		text := string(ite_get_text(editor.handle))
		want, found := ied_find_definition(text, "hash21")
		goto_ok := current_file == "common" && found && int(cursor_line) == want
		log.infof(
			"[ied-test] cross-file goto: %s.slang line %d (want common %d) %s",
			current_file,
			cursor_line,
			want,
			goto_ok ? "PASS" : "FAIL",
		)
	case 47:
		// Call-site resolution: words used at call sites must resolve
		// cross-file (goto-definition and hover docs share this path).
		words := [?]string{"fbm", "scene_uv", "appleDistances", "sdSegment", "is_outside", "frag_coord"}
		for word in words {
			_, _, found := ied_lookup_symbol(editor, word)
			log.infof("[ied-test] lookup %s: %s", word, found ? "OK" : "MISS")
		}
		// Doc extraction: frag_coord carries a //-comment above it.
		frag_sig, frag_doc, frag_found := ied_lookup_symbol(editor, "frag_coord")
		docs_ok := frag_found && strings.contains(frag_sig, "frag_coord") && strings.contains(frag_doc, "y up")
		log.infof("[ied-test] hover docs: sig=%q doc=%q %s", frag_sig, frag_doc, docs_ok ? "PASS" : "FAIL")
		// Builtin docs resolve without any user definition; a project
		// symbol still wins over the builtin table (clamp vs scene_uv).
		for builtin in IED_BUILTIN_DOCS {
			builtin_sig, builtin_doc, builtin_found := ied_lookup_symbol(editor, builtin.name)
			builtin_ok := builtin_found && builtin_sig != "" && builtin_doc != ""
			log.infof("[ied-test] builtin docs (%s): %s", builtin.name, builtin_ok ? "PASS" : "FAIL")
		}
	case 50:
		// Rename helper: whole-word replace respects identifier
		// boundaries (afbm/fbm2 untouched, comment + decl replaced).
		sample_text := "fbm(x) + afbm + fbm2(y) + fbm( z ); // fbm\nfloat fbm = 1.0;"
		out, n := text_replace_word(sample_text, "fbm", "noise_fbm")
		replace_ok := n == 4 &&
			strings.contains(out, "noise_fbm(x)") &&
			strings.contains(out, "noise_fbm( z )") &&
			strings.contains(out, "float noise_fbm = 1.0") &&
			strings.contains(out, "afbm") &&
			strings.contains(out, "fbm2(y)") &&
			!strings.contains(out, "noise_fbm2")
		log.infof("[ied-test] rename replace: %d replacements %s", n, replace_ok ? "PASS" : "FAIL")
		if !replace_ok do log.infof("[ied-test]   got: %s", out)
	case 70:
		// Glass mode visual check: same call path as the toolbar button.
		editor.bg_transparent = true
		ite_set_glass(editor.handle, true, editor.glass_alpha)
		log.info("[ied-test] glass enabled")
	case 80:
		// Glass toggle-spam regression (F3 pressed repeatedly across
		// open/close animations used to compound the palette alpha
		// until the text went invisible): toggle glass ON, force the
		// fade machinery through a full open/close/reopen cycle, then
		// toggle OFF — the palette must come back at full alpha.
		editor.bg_transparent = true
		ite_set_glass(editor.handle, true, editor.glass_alpha)
		editor.open = false // start the close spring (fade_active)
		log.info("[ied-test] glass toggle-spam: cycle 1")
	case 85:
		editor.open = true // reopen mid-spring: fade recapture path
	case 86:
		editor.bg_transparent = false
		ite_set_glass(editor.handle, false, editor.glass_alpha)
		editor.open = false // second cycle with glass OFF mid-anim
		log.info("[ied-test] glass toggle-spam: cycle 2")
	case 88:
		editor.open = true
	case 89:
		// Glass toggle-spam regression check: the saved palette must
		// have survived the spam cycles — background alpha back at
		// full (255) once glass is off, not compounded downward.
		editor.bg_transparent = true
		ite_set_glass(editor.handle, true, editor.glass_alpha)
		editor.bg_transparent = false
		ite_set_glass(editor.handle, false, editor.glass_alpha)
		editor.open = true
		bg_alpha := ite_get_background_alpha(editor.handle)
		log.infof("[ied-test] glass toggle-spam: bg alpha %d/255 %s", bg_alpha, bg_alpha == 255 ? "PASS" : "FAIL")
	case 90:
		// LSP chain check: completion straight from slangd for a known
		// prefix in common.slang (hash21 lives at line 29).
		if ied_lsp != nil {
			data, _ := os.read_entire_file("src/shaders/common.slang", context.temp_allocator)
			items := lsp_complete(ied_lsp, "file:///tmp/common.slang", string(data), 100, 4)
			log.infof("[ied-test] lsp completions: %d items", len(items))
			for item, i in items {
				if i >= 5 do break
				log.infof("[ied-test]   %s (%s)", item.label, item.detail)
			}
		} else {
			log.info("[ied-test] lsp unavailable")
		}
	case 94:
		// Theme machinery check: monokai on screen for the screenshot.
		editor.bg_transparent = false
		ite_set_glass(editor.handle, false, editor.glass_alpha)
		editor.theme = .MONOKAI
		ied_apply_theme(editor)
		log.info("[ied-test] monokai applied")
	case 95:
		// Member completion: right after "Uniforms." slangd must offer
		// the SceneUniforms fields (struct member access).
		if ied_lsp != nil {
			data, _ := os.read_entire_file("src/shaders/scenes/apple/apple.slang", context.temp_allocator)
			text := string(data)
			cursor_line, cursor_col := -1, 0
			if needle_idx := strings.index(text, "Uniforms.iResolution"); needle_idx >= 0 {
				prefix := text[:needle_idx + len("Uniforms.")]
				cursor_line = strings.count(prefix, "\n")
				cursor_col = len(prefix)
				if last_nl := strings.last_index(prefix, "\n"); last_nl >= 0 {
					cursor_col = len(prefix) - last_nl - 1
				}
			}
			// Real URI: imports ("../../common") must resolve for
			// slangd to know SceneUniforms' members.
			cwd, _ := os.get_working_directory(context.temp_allocator)
			doc_uri := fmt.tprintf("file://%s/src/shaders/scenes/apple/apple.slang", cwd)
			items := lsp_complete(ied_lsp, doc_uri, text, cursor_line, cursor_col)
			has_field := false
			for item in items {
				if item.label == "iTime" || item.label == "iFbm" {
					has_field = true
					break
				}
			}
			log.infof(
				"[ied-test] member completion after '.': %d items %s",
				len(items),
				has_field ? "PASS" : "FAIL",
			)
			for item, i in items {
				if i >= 5 do break
				log.infof("[ied-test]   %s (%s)", item.label, item.detail)
			}
		}
	case 100:
		// Live diagnostics check: break the DOCUMENT (not the file,
		// nothing is saved) and expect slangd to flag it. The goto test
		// above left the editor on common.slang, so reload apple first.
		if ied_lsp != nil {
			ied_load_named(editor, ied_scene_rel(editor, "apple"))
			text := string(ite_get_text(editor.handle))
			broken, found := strings.replace(text, "float3 bg = paper_texture;", "float3 bg = paper_texture", 1, context.temp_allocator)
			if found {
				ite_set_text(editor.handle, strings.clone_to_cstring(broken, context.temp_allocator))
				// Programmatic SetText may not fire the change callback;
				// force the dirty flag the way typing would.
				editor.lsp_dirty = true
				log.infof("[ied-test] document broken, dirty=%v", editor.lsp_dirty)
			} else {
				log.info("[ied-test] needle not found in document")
			}
		}
	case 130:
		if ied_lsp != nil {
			log.infof(
				"[ied-test] frame 130: dirty=%v diag_version=%d diag_files=%d",
				editor.lsp_dirty,
				ied_lsp.diag_version,
				len(ied_lsp.diagnostics),
			)
		}
	case 150:
		// Hover docs visual check: force the hovered word so the
		// signature + doc tooltip renders (screenshot target).
		ied_debug_hover_word = "smoothstep"
	case 155:
		// Shortcuts tab visual check (screenshot target).
		emit(SetMode(.SHORTCUTS))
	case 156:
		// Clear the forced hover word so later cases run clean.
		ied_debug_hover_word = ""
	case 160:
		// Mobile theater visual check (screenshot target).
		emit(ToggleMobile{})
	case 248:
		// The diagnostics case (100) leaves apple loaded; the sweep
		// needs 01_hello_pixel (uses both smoothstep-less builtins and
		// scene_uv) on screen, with a clean hover state.
		ied_load_named(editor, ied_scene_rel(editor, "01_hello_pixel"))
		ied_hover_close(editor)
	case 249:
		// Bring smoothstep's occurrence into the visible area.
		text := string(ite_get_text(editor.handle))
		if needle_idx := strings.index(text, "smoothstep"); needle_idx >= 0 {
			line := 0
			for char_idx := 0; char_idx < needle_idx; char_idx += 1 {
				if text[char_idx] == '\n' do line += 1
			}
			ite_goto_line(editor.handle, c.size_t(line))
		}
	case 250:
		// Sweep the text area until the component's own GetWordAt
		// returns smoothstep and scene_uv; the injected mouse then
		// dwells each one in turn.
		found_smooth, found_uv := false, false
		outer: for grid_y in 0 ..< 120 {
			for grid_x in 0 ..< 100 {
				x := editor.text_pos.x + f32(grid_x) * 6
				y := editor.text_pos.y + f32(grid_y) * 4
				word_buf: [128]u8
				n := ite_get_word_at_mouse(editor.handle, x, y, cstring(&word_buf[0]), len(word_buf))
				word := string(word_buf[:min(int(n), 127)])
				if word == "smoothstep" && !found_smooth {
					hover_inject = {x, y}
					hover_inject_active = true
					found_smooth = true
					log.infof("[ied-test] sweep: smoothstep capturable at (%.0f, %.0f)", x, y)
					word_rect: [4]f32
					rect_ok := ite_word_rect_at_mouse(editor.handle, x, y, &word_rect[0])
					log.infof(
						"[ied-test] word rect: ok=%v (%.0f, %.0f)-(%.0f, %.0f) %s",
						rect_ok, word_rect[0], word_rect[1], word_rect[2], word_rect[3],
						rect_ok && word_rect[2] > word_rect[0] && word_rect[3] > word_rect[1] ? "PASS" : "FAIL",
					)
				}
				if word == "scene_uv" && !found_uv {
					goto_inject_pos = {x, y}
					found_uv = true
					log.infof("[ied-test] sweep: scene_uv capturable at (%.0f, %.0f)", x, y)
				}
				if found_smooth && found_uv do break outer
			}
		}
		if !found_smooth do log.infof("[ied-test] sweep: smoothstep NOT capturable (FAIL)")
		if !found_uv do log.infof("[ied-test] sweep: scene_uv NOT capturable (FAIL)")
	case 251:
		// Capture map: for each pixel row of the text area, the words
		// the component returns at three x positions. Shows exactly
		// which screen regions produce captures.
		capture_out := strings.builder_make(context.temp_allocator)
		for grid_y in 0 ..< 120 {
			y := editor.text_pos.y + f32(grid_y) * 4
			row_words: [dynamic]string
			for grid_x in 0 ..< 3 {
				x := editor.text_pos.x + 80 + f32(grid_x) * 120
				word_buf: [128]u8
				n := ite_get_word_at_mouse(editor.handle, x, y, cstring(&word_buf[0]), len(word_buf))
				if n > 0 {
					word := string(word_buf[:min(int(n), 127)])
					if len(row_words) == 0 || row_words[len(row_words) - 1] != word {
						append(&row_words, strings.clone(word, context.temp_allocator))
					}
				}
			}
			if len(row_words) > 0 {
				strings.write_string(&capture_out, fmt.tprintf("y%.0f:%v | ", y, row_words))
			}
		}
		log.infof("[ied-test] capture map: %s", strings.to_string(capture_out))
	case 290:
		hover_ok := editor.hover_sig != "" && strings.contains(editor.hover_sig, "smoothstep")
		log.infof("[ied-test] live hover smoothstep: sig=%q %s", editor.hover_sig, hover_ok ? "PASS" : "FAIL")
		hover_inject_active = false
	case 291:
		// Live hover for scene_uv (defined only in common.slang).
		ied_hover_close(editor)
		hover_inject = goto_inject_pos
		hover_inject_active = true
	case 330:
		hover_ok := editor.hover_sig != "" && strings.contains(editor.hover_sig, "scene_uv")
		log.infof("[ied-test] live hover scene_uv: sig=%q %s", editor.hover_sig, hover_ok ? "PASS" : "FAIL")
		hover_inject_active = false
	case 331:
		// Cmd+click path: goto with the captured word, check landing.
		ied_request_goto_word(editor, "scene_uv")
	case 335:
		file := editor.current >= 0 ? editor.files[editor.current] : "?"
		line := ite_get_cursor_line(editor.handle)
		log.infof(
			"[ied-test] goto scene_uv landed: %s line %d (want common line 77) %s",
			file, line,
			file == "common" && int(line) == 77 ? "PASS" : "FAIL",
		)
	case 340:
		// Cmd+hover underline visual check (screenshot target): hold
		// Cmd over the last swept word.
		ied_gui_held = true
		hover_inject_active = true
	case 400:
		if ied_lsp != nil {
			diags, has_diags := ied_lsp.diagnostics[ied_scene_rel(editor, "apple")]
			log.infof(
				"[ied-test] live diagnostics: %d for scenes/apple %s (diag_version=%d, files=%d)",
				has_diags ? len(diags) : 0,
				has_diags && len(diags) > 0 ? "PASS" : "FAIL",
				ied_lsp.diag_version,
				len(ied_lsp.diagnostics),
			)
			for diag, diag_idx in diags {
				if diag_idx >= 3 do break
				log.infof("[ied-test]   line %d: %s", diag.line + 1, diag.msg)
			}
		}
	case 420:
		restored := ied_restore_last_good(editor)
		matches := false
		if restored && editor.current_open >= 0 {
			restored_doc := &editor.open_docs[editor.current_open]
			matches = string(ite_get_text(editor.handle)) == restored_doc.last_good
		}
		log.infof("[ied-test] restore last compiled: %s", restored && matches ? "PASS" : "FAIL")
	}
}

ied_tick :: proc(editor: ^ImGuiEditor) {
	// Self-test driver: exercises goto/hover/docs/rename/glass/LSP flows
	// without mouse input (--ied-test). Split out of ied_tick (KISS).
	if ied_selftest {
		ied_selftest_tick(editor)
	}

	// Deferred goto-definition (recorded last frame by Cmd+click or the
	// context menu).
	if editor.goto_pending {
		editor.goto_pending = false
		if ied_debug_clicks do log.debugf("[ied] executing deferred goto: %q", editor.goto_word)
		ied_goto_definition(editor, editor.goto_word)
		delete(editor.goto_word)
		editor.goto_word = ""
	}

	// Context-menu "Go to definition" and "Rename symbol" requests arrive
	// through the wrapper.
	{
		menu_buf: [128]u8
		if ite_take_goto_word(editor.handle, cstring(&menu_buf[0]), len(menu_buf)) {
			ied_request_goto_word(editor, string(cstring(&menu_buf[0])))
		}
		if ite_take_rename_word(editor.handle, cstring(&menu_buf[0]), len(menu_buf)) {
			delete(editor.rename_word)
			editor.rename_word = strings.clone(string(cstring(&menu_buf[0])))
			editor.rename_open = true
		}
	}

	// Navigation history: track cursor moves worth returning to.
	ied_nav_tick(editor)

	// Live LSP sync: debounce text changes (~300ms) into didChange;
	// publishDiagnostics arrive via the drain over the next frames.
	if ied_lsp != nil && editor.current >= 0 {
		if editor.lsp_dirty {
			editor.lsp_change_frames += 1
			if editor.lsp_change_frames >= 18 {
				lsp_sync(ied_lsp, ied_current_uri(editor), string(ite_get_text(editor.handle)))
				editor.lsp_dirty = false
				editor.lsp_change_frames = 0
			}
		}
		lsp_drain(ied_lsp)
	}

	// Push diagnostics (goose-build errors on save + live slangd diagnostics)
	if editor.build_success_version != build_success_version {
		editor.build_success_version = build_success_version
		ied_capture_last_good(editor)
	}
	// when either set changes or the current file changes. build_errors is
	// written by the scene build worker: hold its mutex while reading.
	lsp_diag_version := ied_lsp != nil ? ied_lsp.diag_version : 0
	sync.mutex_lock(&scene_build_mu)
	if editor.err_version != build_errors_version ||
	   editor.err_file != editor.current ||
	   editor.lsp_diag_version != lsp_diag_version {
		editor.err_version = build_errors_version
		editor.err_file = editor.current
		editor.lsp_diag_version = lsp_diag_version
		ite_clear_diagnostics(editor.handle)
		if editor.current >= 0 {
			current_rel := editor.files[editor.current]
			for build_error in build_errors {
				if build_error.file != current_rel do continue
				error_msg := strings.clone_to_cstring(build_error.msg, context.temp_allocator)
				error_line := c.size_t(max(0, build_error.line - 1))
				ite_add_squiggle(editor.handle, error_line, c.size_t(max(0, build_error.col - 1)), error_msg)
				ite_add_error_marker(editor.handle, error_line, error_msg)
			}
			if ied_lsp != nil {
				if diags, has_diags := ied_lsp.diagnostics[current_rel]; has_diags {
					for diag in diags {
						diag_end_line := diag.end_line
						if diag_end_line == 0 do diag_end_line = diag.line
						diag_col_end := diag.col_end
						if diag_col_end <= diag.col_start do diag_col_end = diag.col_start + 1
						diag_msg := strings.clone_to_cstring(diag.msg, context.temp_allocator)
						ite_add_squiggle_range(
							editor.handle,
							c.size_t(max(0, diag.line)),
							c.size_t(max(0, diag.col_start)),
							c.size_t(max(0, diag_end_line)),
							c.size_t(max(0, diag_col_end)),
							diag_msg,
						)
						ite_add_error_marker(editor.handle, c.size_t(max(0, diag.line)), diag_msg)
					}
				}
			}
		}
	}
	sync.mutex_unlock(&scene_build_mu)
}

// Editor panel content: toolbar, document tabs, the text component.
// Renders into the caller's window (the sidebar's EDITOR mode panel).
ied_panel :: proc(editor: ^ImGuiEditor) {
	imgui_io := im.GetIO()

	// Ice scroll: the wheel feeds a velocity that glides with exponential
	// friction instead of ImGui's hard line-step jumps. Horizontal stays
	// direct.
	if im.IsWindowHovered({.ChildWindows}) && imgui_io.MouseWheel != 0 {
		editor.scroll_vel += imgui_io.MouseWheel * 230
		imgui_io.MouseWheel = 0
	}
	if editor.scroll_vel != 0 {
		scroll_y := im.GetScrollY()
		im.SetScrollY(scroll_y - editor.scroll_vel * imgui_io.DeltaTime)
		editor.scroll_vel *= math.exp(-9 * imgui_io.DeltaTime)
		if abs(editor.scroll_vel) < 2 do editor.scroll_vel = 0
	}

	// No toolbar: saving lives in the strip's save button (and Cmd+S),
	// browsing in the FILES sidebar mode, and appearance knobs in the
	// strip's gear menu (ui_activity_strip). No status row either: the
	// tabs sit at the top.
	if ied_has_current_build_error(editor) && editor.current_open >= 0 {
		visible_doc := &editor.open_docs[editor.current_open]
		if visible_doc.last_good != "" {
			im.TextColored(ERROR_RED, "%s", strings_to_c(tr("build failed")))
			im.SameLine()
			if im.Button(trc("restore last compiled")) {
				_ = ied_restore_last_good(editor)
			}
		}
	}

	// Tabs: one per open document, a single box holding the title and its
	// close × (right zone). Click on the title area switches (preserving
	// unsaved edits), click on the × zone closes. The visible tab shows
	// the component's live dirty state, the others their stashed flag.
	tab_draw_list := im.GetWindowDrawList()
	live_undo := ite_get_undo_index(editor.handle)
	for tab_doc, i in editor.open_docs {
		im.PushIDInt(i32(i))
		tab_dirty := tab_doc.dirty || (i == editor.current_open && live_undo != editor.saved_undo)
		base := editor.files[tab_doc.file]
		if slash := strings.last_index(base, "/"); slash >= 0 {
			base = base[slash + 1:]
		}
		label := fmt.ctprintf("%s%s", tab_dirty ? "• " : "", base)
		pad_x := f32(8)
		close_w := f32(24) // the × zone inside the tab's right edge
		tab_height := f32(22)
		tab_width := pad_x * 2 + im.CalcTextSize(label).x + close_w
		tab_pos := im.GetCursorScreenPos()
		clicked := im.InvisibleButton("##tab", {tab_width, tab_height})
		hovered := im.IsItemHovered()
		in_close := hovered && im.GetMousePos().x >= tab_pos.x + tab_width - close_w

		box_col: im.Vec4 = {1, 1, 1, 0.04}
		if hovered do box_col = {1, 1, 1, 0.07}
		if i == editor.current_open do box_col = ACCENT_SEMITRANSPARENT
		im.DrawList_AddRectFilled(tab_draw_list, tab_pos, {tab_pos.x + tab_width, tab_pos.y + tab_height}, im.GetColorU32Vec4(box_col), 5)
		text_y := tab_pos.y + (tab_height - im.GetTextLineHeight()) / 2
		im.DrawList_AddText(tab_draw_list, {tab_pos.x + pad_x, text_y}, im.GetColorU32(.Text, 1.0), label)
		x_col: im.Vec4 = in_close ? DANGER_RED : ICON_IDLE
		im.DrawList_AddText(tab_draw_list, {tab_pos.x + tab_width - close_w + 5, text_y}, im.GetColorU32Vec4(x_col), "×")

		if clicked {
			if in_close {
				ied_close(editor, i)
				im.PopID()
				break // open_docs shrank; indices are stale
			}
			ied_switch(editor, i)
		}
		im.PopID()
		if i < len(editor.open_docs) - 1 {
			im.SameLine()
		}
	}

	if im.IsMouseClicked(.Left) && ied_debug_clicks {
		log.infof(
			"[ied] click: super=%v gui=%v pos=(%.0f,%.0f) over_text=%v",
			imgui_io.KeySuper,
			ied_gui_held,
			imgui_io.MousePos.x,
			imgui_io.MousePos.y,
			ite_is_mouse_over_text(editor.handle, imgui_io.MousePos.x, imgui_io.MousePos.y),
		)
	}

	// Cmd+hover hyperlink affordance: underline the word that a click
	// would jump from (Cmd+click below).
	if (imgui_io.KeySuper || ied_gui_held) && !im.IsMouseDown(.Left) &&
	   ite_is_mouse_over_text(editor.handle, imgui_io.MousePos.x, imgui_io.MousePos.y) {
		word_rect: [4]f32
		if ite_word_rect_at_mouse(editor.handle, imgui_io.MousePos.x, imgui_io.MousePos.y, &word_rect[0]) {
			fg_draw_list := im.GetForegroundDrawList()
			underline_col := im.GetColorU32Vec4(ACCENT_SOFT)
			im.DrawList_AddLine(fg_draw_list, {word_rect[0], word_rect[3] - 1.5}, {word_rect[2], word_rect[3] - 1.5}, underline_col, 1.2)
		}
	}

	// Cmd+click: record the word; the jump runs next frame.
	if (imgui_io.KeySuper || ied_gui_held) && im.IsMouseClicked(.Left) {
		if ite_is_mouse_over_text(editor.handle, imgui_io.MousePos.x, imgui_io.MousePos.y) {
			word_buf: [128]u8
			n := ite_get_word_at_mouse(editor.handle, imgui_io.MousePos.x, imgui_io.MousePos.y, cstring(&word_buf[0]), len(word_buf))
			if ied_debug_clicks do log.debugf("[ied] word at click: %q (n=%d)", string(word_buf[:min(int(n), 127)]), n)
			if n > 0 {
				ied_request_goto_word(editor, string(word_buf[:min(int(n), len(word_buf) - 1)]))
			}
		}
	}

	// Cmd+Shift+D: duplicate the current line.
	if (imgui_io.KeySuper || ied_gui_held) && (imgui_io.KeyShift || ied_shift_held) && im.IsKeyPressed(.D, false) {
		ite_duplicate_line(editor.handle)
	}

	// Rename popup (context menu's "Rename symbol"): pre-filled with the
	// word, Enter or the button applies the rename across all files.
	if editor.rename_open {
		im.OpenPopup(trc("Rename symbol"))
		editor.rename_open = false
		for i in 0 ..< len(editor.rename_buf) do editor.rename_buf[i] = 0
		copy(editor.rename_buf[:], editor.rename_word)
	}
	if im.BeginPopup(trc("Rename symbol"), {}) {
		im.TextUnformatted(fmt.ctprintf(tr("rename '%s' to:"), editor.rename_word))
		im.SetNextItemWidth(-1)
		apply := im.InputText(
			"##new_name",
			cstring(&editor.rename_buf[0]),
			len(editor.rename_buf),
			{.EnterReturnsTrue},
		)
		im.SameLine()
		if im.Button(trc("Rename")) do apply = true
		if apply {
			ied_rename(editor, editor.rename_word, string(cstring(&editor.rename_buf[0])))
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}

	// The code font size is independent of the UI font size
	// (Ui.font_size): push the editor's own size around the text
	// component only.
	if app_font != nil {
		im.PushFontFloat(app_font, editor.font_size)
	}
	// Tab-switch crossfade: a WindowBg overlay over the text area that
	// fades out quickly, so the incoming document appears to fade in.
	if editor.current_open != editor.last_open_tab {
		editor.last_open_tab = editor.current_open
		editor.tab_flash = 0.55
	}
	editor.tab_flash = max(0, editor.tab_flash - imgui_io.DeltaTime * 4)

	text_pos := im.GetCursorScreenPos()
	editor.text_pos = {text_pos.x, text_pos.y}
	avail := im.GetContentRegionAvail()
	ite_render(editor.handle, "##ied", avail.x, avail.y)
	if app_font != nil {
		im.PopFont()
	}
	if editor.tab_flash > 0 {
		flash_draw_list := im.GetWindowDrawList()
		im.DrawList_AddRectFilled(
			flash_draw_list,
			text_pos,
			{text_pos.x + avail.x, text_pos.y + avail.y},
			im.GetColorU32(.WindowBg, editor.tab_flash),
		)
	}

	// Status row: the last editor action ("saved N file(s) at HH:MM:SS",
	// "definition in common.slang:77", ...). Fades out after a few
	// seconds; a new status re-fades in. The 6s lifetime matches the
	// transient nature of these messages.
	if editor.status != "" {
		if editor.last_status != string(editor.status) {
			editor.status_fade = 1
		}
		editor.status_fade = max(0, editor.status_fade - imgui_io.DeltaTime * (editor.status_fade > 0.98 ? 0.0 : 0.35))
		if editor.status_fade <= 0 {
			editor.status = ""
		} else {
			im.Separator()
			im.PushStyleColorVec4(.Text, {TEXT_MUTED.x, TEXT_MUTED.y, TEXT_MUTED.z, editor.status_fade})
			im.TextWrapped("%s", strings_to_c(editor.status))
			im.PopStyleColor()
		}
		editor.last_status = strings.clone(string(editor.status))
	}

	// Hover symbol docs: dwell ~0.4 s on a word over the text, then show
	// its signature plus the doc comment above the definition. Once
	// shown, the tooltip pins and stays alive while the mouse is inside
	// it (wheel scrolls long docs); leaving the tooltip closes it.
	{
		mouse := imgui_io.MousePos
		over_tooltip :=
			editor.hover_shown &&
			mouse.x >= editor.hover_rect[0] && mouse.x <= editor.hover_rect[2] &&
			mouse.y >= editor.hover_rect[1] && mouse.y <= editor.hover_rect[3]
		word := ied_debug_hover_word
		over_text := !over_tooltip && ite_is_mouse_over_text(editor.handle, mouse.x, mouse.y)
		// --hover-debug: a left click reports what the component sees at
		// that exact position, plus the lookup result.
		if hover_debug && !over_tooltip && im.IsMouseClicked(.Left) {
			click_buf: [128]u8
			n := c.size_t(0)
			if over_text {
				n = ite_get_word_at_mouse(editor.handle, mouse.x, mouse.y, cstring(&click_buf[0]), len(click_buf))
			}
			cword := string(click_buf[:min(int(n), 127)])
			hover_sig, hover_doc, hover_found := ied_lookup_symbol(editor, cword)
			text_metrics: [8]f32
			ite_text_metrics(editor.handle, &text_metrics[0])
			log.infof(
				"[hover] click (%.0f, %.0f) over_text=%v word=%q found=%v sig=%q",
				mouse.x, mouse.y, over_text, cword, hover_found, hover_sig,
			)
			log.infof(
				"[hover] metrics cpos=(%.1f, %.1f) left=%.1f right=%.1f size=(%.1f, %.1f) glyph=(%.2f, %.2f)",
				text_metrics[0], text_metrics[1], text_metrics[2], text_metrics[3], text_metrics[4], text_metrics[5], text_metrics[6], text_metrics[7],
			)
			_ = hover_doc
		}
		if !over_tooltip && word == "" && !im.IsMouseDown(.Left) && over_text {
			hover_buf: [128]u8
			n := ite_get_word_at_mouse(editor.handle, mouse.x, mouse.y, cstring(&hover_buf[0]), len(hover_buf))
			word = string(hover_buf[:min(int(n), 127)])
			if hover_debug && word == "" && editor.hover_word == "" && im.GetTime() - hover_debug_ts > 1 {
				hover_debug_ts = im.GetTime()
				log.infof("[hover] over text but EMPTY capture at (%.0f, %.0f)", mouse.x, mouse.y)
			}
		}
		// Grace window: crossing the gap between the word and the pinned
		// tooltip keeps it open; a different word swaps immediately.
		if editor.hover_shown && !over_tooltip && word == "" {
			editor.hover_grace -= imgui_io.DeltaTime
		} else {
			editor.hover_grace = 0.35
		}
		different := word != "" && word != editor.hover_word
		gone := word == "" && word != editor.hover_word && editor.hover_grace <= 0
		if !over_tooltip && (different || gone) {
			if hover_debug && word != editor.hover_word {
				log.infof("[hover] capture: %q (was %q)", word, editor.hover_word)
			}
			delete(editor.hover_word)
			editor.hover_word = strings.clone(word)
			editor.hover_dwell = 0
			if editor.hover_sig != "" {
				delete(editor.hover_sig)
				editor.hover_sig = ""
				delete(editor.hover_doc)
				editor.hover_doc = ""
			}
			if editor.hover_footer != "" {
				delete(editor.hover_footer)
				editor.hover_footer = ""
			}
			editor.hover_doc_scroll = 0
			editor.hover_shown = false
		} else if !over_tooltip && word != "" {
			editor.hover_dwell += 1
			if editor.hover_dwell == 25 {
				hover_sig, hover_doc, hover_found := ied_lookup_symbol(editor, editor.hover_word)
				if hover_debug {
					log.infof("[hover] resolve %q: found=%v sig=%q", editor.hover_word, hover_found, hover_sig)
				}
				if hover_found {
					editor.hover_sig = strings.clone(hover_sig)
					editor.hover_doc = strings.clone(hover_doc)
					// Footer: definition site for project symbols (builtins
					// render their tag and links from the table instead).
					if def_file, def_line, loc_ok := ied_symbol_location(editor, editor.hover_word); loc_ok {
						editor.hover_footer = strings.clone(fmt.tprintf("%s:%d", def_file, def_line + 1))
					}
				}
			}
		}
		show := editor.hover_dwell >= 25 && editor.hover_sig != ""
		if show {
			if !editor.hover_shown {
				// Pin beside the cursor on the side with room, like a
				// native tooltip: right/below by default, flipping to
				// left/above near the viewport edges.
				line_h := im.GetTextLineHeightWithSpacing()
				doc_lines := min(strings.count(editor.hover_doc, "\n") + 2, 15)
				w_est := f32(470)
				h_est := f32(doc_lines + 1) * line_h + 22
				pin_x := mouse.x + 16
				if pin_x + w_est > imgui_io.DisplaySize.x - 8 do pin_x = mouse.x - w_est - 12
				pin_y := mouse.y + 14
				if pin_y + h_est > imgui_io.DisplaySize.y - 8 do pin_y = mouse.y - h_est - 10
				editor.hover_pin = {
					clamp(pin_x, 8, max(8, imgui_io.DisplaySize.x - w_est)),
					clamp(pin_y, 4, max(4, imgui_io.DisplaySize.y - 120)),
				}
			}
			im.SetNextWindowPos(editor.hover_pin, .Always)
			// Self-test: the physical mouse may be outside the window (or
			// never moved), so pin the tooltip inside the panel.
			if ied_debug_hover_word != "" {
				selftest_window_pos := im.GetWindowPos()
				im.SetNextWindowPos({selftest_window_pos.x - 40, selftest_window_pos.y + 160}, .Always)
			}
			if im.BeginTooltip() {
				// The wheel anywhere inside the tooltip scrolls its doc
				// region; without this it falls through to the editor.
				if im.IsWindowHovered() && imgui_io.MouseWheel != 0 {
					editor.hover_doc_scroll = max(0, editor.hover_doc_scroll - imgui_io.MouseWheel * 30)
					imgui_io.MouseWheel = 0
				}
				// Cap the tooltip: unwrapped docs used to grow right
				// without limit, and tall doc blocks had no scroll.
				im.PushTextWrapPos(im.GetCursorPosX() + 440)
				im.TextColored(SIGNATURE_BLUE, "%s", strings_to_c(editor.hover_sig))
				if editor.hover_doc != "" {
					im.Separator()
					line_h := im.GetTextLineHeightWithSpacing()
					doc_h := min(f32(strings.count(editor.hover_doc, "\n") + 1) * line_h, 14 * line_h)
					if im.BeginChild("##hoverdoc", {440, doc_h}, {}) {
						im.SetScrollY(editor.hover_doc_scroll)
						hover_render_md(editor.hover_doc)
					}
					im.EndChild()
				}
				if builtin := hover_builtin_of(editor); builtin != nil {
					// Parameter table for builtins.
					if len(builtin.params) > 0 {
						im.SeparatorText("params")
						for builtin_param in builtin.params {
							im.TextColored(ACCENT, "%s", strings_to_c(builtin_param.name))
							im.SameLine(0, 10)
							im.TextWrapped(strings_to_c(builtin_param.desc))
						}
					}
					// Footer: tag plus clickable see-also links; clicking
					// swaps the tooltip to that builtin in place.
					im.Separator()
					im.TextDisabled("%s", strings_to_c(tr("slang builtin · see also:")))
					rest := builtin.also
					for len(rest) > 0 {
						im.SameLine(0, 6)
						name := rest
						if comma_idx := strings.index(rest, ","); comma_idx >= 0 {
							name = rest[:comma_idx]
							rest = rest[comma_idx + 2:]
						} else {
							rest = ""
						}
						im.PushID(strings_to_c(name))
						if im.SmallButton(strings_to_c(name)) {
							hover_swap_builtin(editor, name)
						}
						im.PopID()
					}
				} else if editor.hover_footer != "" {
					im.Separator()
					im.TextDisabled("%s", strings_to_c(editor.hover_footer))
				}
				tooltip_pos := im.GetWindowPos()
				tooltip_size := im.GetWindowSize()
				editor.hover_rect = {tooltip_pos.x - 6, tooltip_pos.y - 6, tooltip_pos.x + tooltip_size.x + 6, tooltip_pos.y + tooltip_size.y + 6}
				im.PopTextWrapPos()
				im.EndTooltip()
			}
		}
		editor.hover_shown = show
	}
}

// The editor's floating window (F1 toggles); the panel content itself is
// ied_panel. Kept separate from the sidebar by design. Open/close springs
// the window in from the right edge (fx).
ied_frame :: proc(editor: ^ImGuiEditor, fx_state: ^Fx) {
	imgui_io := im.GetIO()
	anim_step(&editor.open_anim, editor.open ? 1 : 0, imgui_io.DeltaTime, fx_state)
	if editor.open_anim.value < 0.02 && !editor.open do return
	// Wide enough for the toolbar row (save all … theme) on small windows.
	win_w := max(imgui_io.DisplaySize.x * 0.45, 430)
	xoff := (1 - editor.open_anim.value) * 60
	dock_pos := im.Vec2{imgui_io.DisplaySize.x - win_w - 8 + xoff, 8}
	dock_size := im.Vec2{win_w, imgui_io.DisplaySize.y - 16}
	if mobile_theater {
		// Mobile theater (F5): editor docked to the bottom half of the
		// portrait window; the scene plays in the top half.
		dock_pos = {8, imgui_io.DisplaySize.y * 0.55}
		dock_size = {imgui_io.DisplaySize.x - 16, imgui_io.DisplaySize.y * 0.45 - 8}
	}
	// Docked until the user drags the title bar away; then ImGui owns
	// the position and size (still saved to imgui.ini). Forcing every
	// frame would make the drag impossible, so the dock position is
	// forced only during the open/close spring or when the window size
	// changes; in between, a position mismatch below detects the drag.
	display := [2]f32{imgui_io.DisplaySize.x, imgui_io.DisplaySize.y}
	force :=
		mobile_theater ||
		editor.open_anim.value < 1 ||
		(!editor.moved && display != editor.dock_display)
	if force {
		im.SetNextWindowPos(dock_pos, .Always)
		im.SetNextWindowSize(dock_size, .Always)
		if !editor.moved do editor.dock_display = display
	}
	// Deterministic startup: the editor always opens expanded; what the
	// user does after that is theirs (demo framing on every launch).
	im.SetNextWindowCollapsed(false, .Once)
	im.SetNextWindowBgAlpha((editor.bg_transparent ? editor.glass_alpha : 1.0) * editor.open_anim.value)
	// The ##ed2 suffix sidesteps a poisoned imgui.ini section saved with
	// an off-screen position when the app exits minimized (DisplaySize 0
	// makes the computed x negative); the fresh section starts clean.
	if !im.Begin(fmt.ctprintf("%s##ed2", tr("Shader editor")), &editor.open, {}) {
		im.End()
		return
	}
	// A position different from the dock means the user dragged the
	// title bar: hand the window over to ImGui from here on.
	if !editor.moved && !force && im.GetWindowPos() != dock_pos {
		editor.moved = true
	}
	// The window frame animates via open_anim; the content must fade too:
	// style alpha for the ImGui chrome (tabs), palette fade for the text
	// component (its raw draw-list colors ignore style alpha).
	im.PushStyleVar(.Alpha, editor.open_anim.value)
	ite_set_fade(editor.handle, editor.open_anim.value)
	ied_panel(editor)
	im.PopStyleVar()
	im.End()
}
