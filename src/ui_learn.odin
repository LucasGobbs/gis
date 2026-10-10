package main

// LEARN mode: markdown-based learning trails. Pages live in
// assets/trails/*.md; "index" is the home page. The renderer is a
// deliberate md-lite: headers, bullets, fenced code blocks, and inline
// links: because the feature that matters is the bridge to practice:
// [label](scene:NAME) loads the scene AND opens the editor on its entry
// file, [label](trail:NAME) navigates between pages.
import im "../vendor/odin-imgui"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

LEARN_DIR :: "assets/trails"

learn_page: string // current page base name ("" = not loaded yet)
learn_text: string // owned page content

learn_load :: proc(page: string) {
	path := fmt.tprintf("%s/%s.md", LEARN_DIR, page)
	file_data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		log.errorf("learn: could not read %s", path)
		return
	}
	delete(learn_text)
	learn_text = strings.clone(string(file_data))
	delete(learn_page)
	learn_page = strings.clone(page)
}

// True when the next segment still fits before the panel's right
// edge. cursor_x is the x a SameLine(0, 0) would continue at (the
// last segment's item-rect max), not GetCursorScreenPos(): after a
// text item that is already the next line's start. SameLine's spacing
// is 0, so the segment lands exactly at cursor_x.
// Wrapped text used by every trail page line: plain lines, link-line
// segments, and labels all share it so long text always breaks at the
// containing block's width instead of overflowing the sidebar. An
// optional color replaces the default text color (pushed manually
// because TextWrapped has no colored variant).
learn_text_wrapped :: proc(text: cstring, color := im.Vec4{-1, -1, -1, -1}) {
	if color.x >= 0 do im.PushStyleColorVec4(.Text, color)
	im.TextWrapped("%s", text)
	if color.x >= 0 do im.PopStyleColor()
}

learn_segment_fits :: proc(seg: string, cursor_x, right_edge: f32) -> bool {
	return cursor_x + im.CalcTextSize(strings_to_c(seg)).x <= right_edge
}

// Renders one inline segment run: plain text interleaved with
// [label](target) links. Targets are "scene:NAME" (load scene + open
// editor) and "trail:NAME" (navigate). Segments wrap at the panel
// width; long ones continue on the next line.
learn_render_rich_line :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor, line: string) {
	// Lines without links wrap at the panel width; link lines flow
	// inline (content authors keep those short).
	if strings.index(line, "](") < 0 {
		learn_text_wrapped(strings_to_c(line))
	}
	// Right edge (screen space) this line's segments must stay inside,
	// measured once from the entry cursor: GetContentRegionAvail() is
	// cursor-relative, so the bullet indent is included for free and
	// the edge stays valid across wrapped continuation lines.
	right_edge := im.GetCursorScreenPos().x + im.GetContentRegionAvail().x
	remaining := line
	first_segment := true
	// X where the next SameLine(0, 0) segment would land: the last
	// drawn item's rect max, or the entry cursor before any segment.
	cursor_x := im.GetCursorScreenPos().x
	link_color := im.Vec4{0.55, 0.75, 0.95, 1}

	for {
		open_bracket := strings.index(remaining, "[")
		if open_bracket < 0 do break
		close_bracket := strings.index(remaining[open_bracket:], "](")
		if close_bracket < 0 do break
		close_bracket += open_bracket
		link_end := strings.index(remaining[close_bracket + 2:], ")")
		if link_end < 0 do break
		link_end += close_bracket + 2
		label := remaining[open_bracket + 1:close_bracket]
		target := remaining[close_bracket + 2:link_end]
		// Segment before the link.
		if open_bracket > 0 {
			if !first_segment && learn_segment_fits(remaining[:open_bracket], cursor_x, right_edge) {
				im.SameLine(0, 0)
			}
			learn_text_wrapped(strings_to_c(remaining[:open_bracket]))
			cursor_x = im.GetItemRectMax().x
			first_segment = false
		}
		if !first_segment && learn_segment_fits(label, cursor_x, right_edge) {
			im.SameLine(0, 0)
		}
		learn_text_wrapped(strings_to_c(label), link_color)
		if im.IsItemHovered() {
			link_min := im.GetItemRectMin()
			link_max := im.GetItemRectMax()
			im.DrawList_AddLine(
				im.GetWindowDrawList(),
				{link_min.x, link_max.y - 1},
				{link_max.x, link_max.y - 1},
				im.GetColorU32Vec4(link_color),
				1,
			)
			if im.IsMouseClicked(.Left) {
				if strings.has_prefix(target, "scene:") {
					file := strings.trim_prefix(target, "scene:")
					for &s, i in sm.scenes {
						if s.title == file {
							emit(SceneSelected(i))
							// ed.files entries omit the .slang suffix
							// (ied_file_path appends it).
							entry := fmt.tprintf("scenes/%s/%s", file, file)
							ied_load_named(ed, entry)
							ed.open = true
							break
						}
					}
				} else if strings.has_prefix(target, "trail:") {
					learn_load(strings.trim_prefix(target, "trail:"))
					return // the page changed under us; stop rendering it
				}
			}
		}
		cursor_x = im.GetItemRectMax().x
		first_segment = false
		remaining = remaining[link_end + 1:]
	}
	if len(remaining) > 0 {
		if !first_segment && learn_segment_fits(remaining, cursor_x, right_edge) {
			im.SameLine(0, 0)
		}
		learn_text_wrapped(strings_to_c(remaining))
	}
}

learn_render_page :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	in_code := false
	code_lines := 0
	for line in strings.split_lines(learn_text, context.temp_allocator) {
		if strings.has_prefix(line, "```") {
			in_code = !in_code
			if in_code do code_lines = 0
			continue
		}
		if in_code {
			// Fenced block: dim text over a subtle strip, indented.
			// TextDisabled doesn't wrap; push the disabled color manually
			// around TextWrapped so long code lines stay inside the panel.
			// The strip is drawn before the text, so it can't know the
			// wrapped height; skip it when the line won't fit unwrapped
			// (cosmetic compromise, wrapped code is rare in trail pages).
			code_min := im.GetCursorScreenPos()
			code_width := im.GetContentRegionAvail().x
			code_height := im.GetTextLineHeight()
			fits := im.CalcTextSize(fmt.ctprintf("  %s", line)).x <= code_width
			if fits {
				im.DrawList_AddRectFilled(
					im.GetWindowDrawList(),
					{code_min.x, code_min.y},
					{code_min.x + code_width, code_min.y + code_height},
					im.GetColorU32Vec4({1, 1, 1, 0.05}),
				)
			}
			im.PushStyleColorVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
			im.TextWrapped("  %s", strings_to_c(line))
			im.PopStyleColor()
			code_lines += 1
			continue
		}
		trimmed := strings.trim_space(line)
		switch {
		case trimmed == "":
			im.Spacing()
		case strings.has_prefix(trimmed, "## "):
			im.Spacing()
			learn_text_wrapped(strings_to_c(trimmed[3:]), {0.91, 0.66, 0.34, 1})
		case strings.has_prefix(trimmed, "# "):
			learn_text_wrapped(strings_to_c(trimmed[2:]), {0.95, 0.92, 0.88, 1})
			im.Separator()
			im.Spacing()
		case strings.has_prefix(trimmed, "- "):
			im.Bullet()
			learn_render_rich_line(ui, sm, ed, trimmed[2:])
		case:
			learn_render_rich_line(ui, sm, ed, trimmed)
		}
	}
}

ui_learn_panel :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	if learn_text == "" do learn_load("index")
	im.TextDisabled(trc("learn"))
	if learn_page != "index" {
		// Back to the trail index.
		im.TextColored({0.55, 0.75, 0.95, 1}, "%s", strings_to_c(tr("← all trails")))
		if im.IsItemHovered() && im.IsMouseClicked(.Left) {
			learn_load("index")
			return
		}
		im.Separator()
	}
	learn_render_page(ui, sm, ed)
}
