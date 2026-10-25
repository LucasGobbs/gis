package main

// Markdown renderer for the LEARN panel: md4c (C parser, vendored in
// vendor/md4c) driving an Odin renderer structured after the block/span
// handler model of mekhontsev/imgui_md (MIT). Parsing decisions here:
//
//  - Handlers render directly into the current ImGui window; no
//    intermediate layout pass. State lives in Md_Render (the fields
//    imgui_md keeps as members).
//  - Links never navigate during parsing. A click only records
//    pending_href; the caller follows it after md_render returns,
//    because learn_load frees learn_text under the parser's feet.
//  - Text wrapping uses Font_CalcWordWrapPosition per run instead of
//    TextWrapped, so link/chip segments can continue on the row via
//    SameLine(0, 0) — the row is closed by end_inline at the next
//    block boundary, never by a trailing SameLine chain. That is the
//    fix for the "link tail wraps onto its own line and orphans a
//    leading ':'" class of bugs.
//  - Code blocks: full fenced-block highlighting with the moved
//    ui_learn tokenizer, one panel behind all lines, click copies the
//    hovered line, double-click copies the block. Inline code renders
//    as a click-to-copy chip.
//  - Colors arrive via Md_Config (prose from the ImGui style, code
//    tokens from the code editor's theme); no app color literals here.
import "base:runtime"
import "core:c"
import "core:log"
import "core:fmt"
import "core:strings"
import im "../vendor/odin-imgui"

foreign import md4c "../vendor/md4c/libmd4c.a"

MD_CHAR :: c.char
MD_SIZE :: c.uint
MD_OFFSET :: c.uint

// Enum member order mirrors vendor/md4c/md4c.h exactly (MD_BLOCK_DOC =
// 0 ... MD_BLOCK_BLANK; MD_SPAN_EM = 0 ... MD_SPAN_MARK;
// MD_TEXT_NORMAL = 0 ... MD_TEXT_LATEXMATH).
MD_BLOCKTYPE :: enum c.int {
	DOC, QUOTE, UL, OL, LI, HR, H, CODE, HTML, P, TABLE, THEAD, TBODY, TR, TH, TD,
	FOOTNOTE_DEF_SECTION, FOOTNOTE_DEF, ADMONITION, BLANK,
}
MD_SPANTYPE :: enum c.int {
	EM, STRONG, A, IMG, CODE, INS, DEL, LATEXMATH, LATEXMATH_DISPLAY, WIKILINK,
	U, SPOILER, SUPERSCRIPT, SUBSCRIPT, FOOTNOTE_REF, MARK,
}
MD_TEXTTYPE :: enum c.int {
	NORMAL = 0, NULLCHAR, BR, SOFTBR, ENTITY, CODE, HTML, LATEXMATH,
}
MD_ALIGN :: enum c.int { DEFAULT = 0, LEFT, CENTER, RIGHT }

MD_ATTRIBUTE :: struct {
	text:          [^]MD_CHAR,
	size:          MD_SIZE,
	substr_types:  [^]MD_TEXTTYPE,
	substr_offsets: [^]MD_OFFSET,
}
MD_BLOCK_UL_DETAIL :: struct { is_tight: c.int, mark: MD_CHAR }
MD_BLOCK_OL_DETAIL :: struct { start: c.uint, is_tight: c.int, mark_delimiter: MD_CHAR }
MD_BLOCK_LI_DETAIL :: struct { is_task: c.int, task_mark: MD_CHAR, task_mark_offset: MD_OFFSET }
MD_BLOCK_H_DETAIL :: struct { level: c.uint }
MD_BLOCK_CODE_DETAIL :: struct { info: MD_ATTRIBUTE, lang: MD_ATTRIBUTE, fence_char: MD_CHAR }
MD_BLOCK_TABLE_DETAIL :: struct { col_count: c.uint, head_row_count: c.uint, body_row_count: c.uint }
MD_BLOCK_TD_DETAIL :: struct { align: MD_ALIGN }
MD_SPAN_A_DETAIL :: struct { href: MD_ATTRIBUTE, title: MD_ATTRIBUTE, is_autolink: c.int }
MD_SPAN_IMG_DETAIL :: struct { src: MD_ATTRIBUTE, title: MD_ATTRIBUTE }

MD_PARSER :: struct {
	abi_version: c.uint,
	flags:       c.uint,
	enter_block: proc "c" (MD_BLOCKTYPE, rawptr, rawptr) -> c.int,
	leave_block: proc "c" (MD_BLOCKTYPE, rawptr, rawptr) -> c.int,
	enter_span:  proc "c" (MD_SPANTYPE, rawptr, rawptr) -> c.int,
	leave_span:  proc "c" (MD_SPANTYPE, rawptr, rawptr) -> c.int,
	text:        proc "c" (MD_TEXTTYPE, [^]MD_CHAR, MD_SIZE, rawptr) -> c.int,
	debug_log:   proc "c" (cstring, rawptr),
	syntax:      proc "c" (),
}

MD_FLAG_TABLES        :: 0x100
MD_FLAG_STRIKETHROUGH :: 0x200
MD_FLAG_UNDERLINE     :: 0x4000

@(default_calling_convention = "c")
foreign md4c {
	md_parse :: proc(text: [^]MD_CHAR, size: MD_SIZE, parser: ^MD_PARSER, userdata: rawptr) -> c.int ---
}

// Colors, tokenizer word lists, tooltip strings, copy callback: all
// supplied by the embedder (src/ui_learn.odin builds them from the
// shared UI palette).
Md_Config :: struct {
	// Prose colors, read from the live ImGui style by the caller.
	text, text_strong, text_em, text_dim, accent, h1, link: im.Vec4,
	// Code panel/chip chrome.
	code_bg, chip_bg, code_edge: im.Vec4,
	// Token colors for code blocks/chips, resolved by the caller at
	// render time — normally from the code editor's current theme so
	// the LEARN highlights match it.
	code_colors: Md_Code_Colors,
	keywords:  []string, // CODE_KEYWORDS
	ns:        []string, // CODE_NS
	host:      []string, // CODE_HOST_IDENTS
	tip_chip:  cstring, // trc("click to copy")
	tip_block: cstring, // trc("click: copy line · double-click: copy block")
	on_copy:   proc(text: string), // called after SetClipboardText; caller shows the toast
}

// The subset of the editor palette the LEARN tokenizer uses. Values are
// ImGui Vec4 (RGBA 0..1); derive from the editor's ABGR u32 slots.
Md_Code_Colors :: struct {
	text, keyword, declaration, number, known_identifier, comment: im.Vec4,
}

Md_List :: struct { cur_ol: u32, delim: u8, is_ol: bool }

Md_Table :: struct {
	next_col:   int,
	last_pos:   im.Vec2, // window-local, like imgui_md's m_table_last_pos
	col_pos:    [dynamic]f32,
	row_pos:    [dynamic]f32,
	in_header:  bool,
	in_body:    bool,
}

// Per-render state: the member fields of imgui_md's subclass, plus the
// config pointer and the click-out channel.
Md_Render :: struct {
	cfg:           ^Md_Config,
	href:          string, // current span_a href; "" when not inside a link
	pending_href:  string, // set on click; caller reads after md_render returns
	link_buf:      [dynamic]u8,  // link label text, drawn when the span closes
	holding_link:  bool, // inside span_a: label chunks accumulate in link_buf
	armed_link:    string, // drawn-on-next-text link label; "" when none pending
	armed_href:    string, // the armed link's href, kept for color/click
	hlevel:        u32,
	is_strong:     bool,
	is_em:         bool,
	is_underline:  bool,
	is_strike:     bool,
	is_image:      bool,
	inline_open:   bool, // last emitted item is inline text on the current row
	in_code_block: bool,
	in_span_code:  bool,
	code_buf:      [dynamic]u8, // collects MD_TEXT_CODE for the current block/span
	list_stack:    [dynamic]Md_List,
	widget_seq:    int, // unique ImGui widget IDs across one md_render call
	table:         Md_Table,
}

HEADING_SCALE :: [6]f32{1.6, 1.35, 1.2, 1.1, 1.0, 1.0}

// Renders `text` into the current ImGui window. Returns the href of a
// link clicked during rendering ("" when none) and whether the parse
// succeeded. On failure the page stays undrawn and the error is logged.
md_render :: proc(text: string, cfg: ^Md_Config) -> (pending: string, ok: bool) {
	if text == "" {
		return "", true
	}
	r := Md_Render{
		cfg        = cfg,
		code_buf   = make([dynamic]u8, context.temp_allocator),
		link_buf   = make([dynamic]u8, context.temp_allocator),
		list_stack = make([dynamic]Md_List, context.temp_allocator),
		table = Md_Table{
			col_pos = make([dynamic]f32, context.temp_allocator),
			row_pos = make([dynamic]f32, context.temp_allocator),
		},
	}
	parser := MD_PARSER{
		flags       = MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_UNDERLINE,
		enter_block = md_enter_block,
		leave_block = md_leave_block,
		enter_span  = md_enter_span,
		leave_span  = md_leave_span,
		text        = md_text_cb,
	}
	rc := md_parse(
		([^]MD_CHAR)(raw_data(text)),
		MD_SIZE(len(text)),
		&parser,
		&r,
	)
	if rc != 0 {
		log.errorf("learn: md_parse failed (rc=%d)", rc)
		return "", false
	}
	return r.pending_href, true
}

////////////////////////////////////////////////////////////////////////////////
// C trampolines. `context` is not inherited through a C call, so each
// trampoline restores it before touching Odin memory.

md_enter_block :: proc "c" (t: MD_BLOCKTYPE, d: rawptr, u: rawptr) -> c.int {
	context = runtime.default_context()
	r := (^Md_Render)(u)
	switch t {
	case .H:    block_h(r, (^MD_BLOCK_H_DETAIL)(d), true)
	case .CODE: block_code(r, true)
	case .UL:   block_ul(r, (^MD_BLOCK_UL_DETAIL)(d), true)
	case .OL:   block_ol(r, (^MD_BLOCK_OL_DETAIL)(d), true)
	case .LI:   block_li(r, true)
	case .HR:   block_hr(r, true)
	case .P:    block_p(r, true)
	case .QUOTE, .DOC, .HTML: // no-op
	case .TABLE: block_table(r, true)
	case .THEAD: block_thead(r, true)
	case .TBODY: block_tbody(r, true)
	case .TR:    block_tr(r, true)
	case .TH:    block_td(r, true)
	case .TD:    block_td(r, true)
	case .BLANK, .FOOTNOTE_DEF_SECTION, .FOOTNOTE_DEF, .ADMONITION: // not enabled by flags
	}
	return 0
}

md_leave_block :: proc "c" (t: MD_BLOCKTYPE, d: rawptr, u: rawptr) -> c.int {
	context = runtime.default_context()
	r := (^Md_Render)(u)
	switch t {
	case .H:    block_h(r, (^MD_BLOCK_H_DETAIL)(d), false)
	case .CODE: block_code(r, false)
	case .UL:   block_ul(r, (^MD_BLOCK_UL_DETAIL)(d), false)
	case .OL:   block_ol(r, (^MD_BLOCK_OL_DETAIL)(d), false)
	case .LI:   block_li(r, false)
	case .HR:   block_hr(r, false)
	case .P:    block_p(r, false)
	case .QUOTE, .DOC, .HTML: // no-op
	case .TABLE: block_table(r, false)
	case .THEAD: block_thead(r, false)
	case .TBODY: block_tbody(r, false)
	case .TR:    block_tr(r, false)
	case .TH:    block_td(r, false)
	case .TD:    block_td(r, false)
	case .BLANK, .FOOTNOTE_DEF_SECTION, .FOOTNOTE_DEF, .ADMONITION:
	}
	return 0
}

md_enter_span :: proc "c" (t: MD_SPANTYPE, d: rawptr, u: rawptr) -> c.int {
	context = runtime.default_context()
	r := (^Md_Render)(u)
	#partial switch t {
	case .EM:     span_em(r, true)
	case .STRONG: span_strong(r, true)
	case .A:      span_a(r, (^MD_SPAN_A_DETAIL)(d), true)
	case .IMG:    span_img(r, true)
	case .CODE:   span_code(r, true)
	case .DEL:    span_del(r, true)
	case .U:      span_u(r, true)
	case: // INS, LATEXMATH*, WIKILINK, SPOILER, SUPER/SUBSCRIPT, FOOTNOTE_REF, MARK: no-op
	}
	return 0
}

md_leave_span :: proc "c" (t: MD_SPANTYPE, d: rawptr, u: rawptr) -> c.int {
	context = runtime.default_context()
	r := (^Md_Render)(u)
	#partial switch t {
	case .EM:     span_em(r, false)
	case .STRONG: span_strong(r, false)
	case .A:      span_a(r, (^MD_SPAN_A_DETAIL)(d), false)
	case .IMG:    span_img(r, false)
	case .CODE:   span_code(r, false)
	case .DEL:    span_del(r, false)
	case .U:      span_u(r, false)
	case:
	}
	return 0
}

md_text_cb :: proc "c" (t: MD_TEXTTYPE, s: [^]MD_CHAR, n: MD_SIZE, u: rawptr) -> c.int {
	context = runtime.default_context()
	r := (^Md_Render)(u)
	md_text(r, t, s[:n])
	return 0
}

////////////////////////////////////////////////////////////////////////////////
// Block handlers (port of imgui_md BLOCK_*).

// Closes the row opened by inline text/chips before a block-level
// item. A link left armed at a block boundary (paragraph ended with a
// link) flushes unglued.
end_inline :: proc(r: ^Md_Render) {
	if r.armed_link != "" {
		render_link_text(r, r.armed_link)
		r.armed_link = ""
		r.armed_href = ""
	}
	if r.inline_open {
		im.NewLine()
		r.inline_open = false
	}
}

block_p :: proc(r: ^Md_Render, e: bool) {
	if e {
		end_inline(r)
	} else {
		// imgui_md only closes the paragraph row outside lists; tight
		// list items close via LI's NewLine on the next entry.
		r.inline_open = false
		if len(r.list_stack) == 0 {
			im.NewLine()
		}
	}
}

block_h :: proc(r: ^Md_Render, d: ^MD_BLOCK_H_DETAIL, e: bool) {
	if e {
	heading_scale := HEADING_SCALE
		r.hlevel = u32(d.level)
		scale := heading_scale[min(max(int(d.level) - 1, 0), 5)]
		im.PushFontFloat(nil, im.GetStyle().FontSizeBase * scale)
		if d.level == 1 {
			im.PushStyleColorVec4(.Text, r.cfg.h1)
		} else if d.level == 2 {
			im.PushStyleColorVec4(.Text, r.cfg.accent)
		}
	} else {
		if d.level == 1 || d.level == 2 {
			im.PopStyleColor()
		}
		im.PopFont()
		r.inline_open = false
		r.hlevel = 0
		if d.level <= 2 {
			im.Separator()
		}
	}
}

block_code :: proc(r: ^Md_Render, e: bool) {
	if e {
		end_inline(r)
		clear(&r.code_buf)
		r.in_code_block = true
	} else {
		r.in_code_block = false
		render_code_block(r, string(r.code_buf[:]))
	}
}

block_ul :: proc(r: ^Md_Render, d: ^MD_BLOCK_UL_DETAIL, e: bool) {
	if e {
		append(&r.list_stack, Md_List{delim = u8(d.mark), is_ol = false})
	} else {
		pop(&r.list_stack)
		if len(r.list_stack) == 0 {
			im.NewLine()
		}
	}
}

block_ol :: proc(r: ^Md_Render, d: ^MD_BLOCK_OL_DETAIL, e: bool) {
	if e {
		append(&r.list_stack, Md_List{cur_ol = d.start, delim = u8(d.mark_delimiter), is_ol = true})
	} else {
		pop(&r.list_stack)
		if len(r.list_stack) == 0 {
			im.NewLine()
		}
	}
}

block_li :: proc(r: ^Md_Render, e: bool) {
	if e {
		im.NewLine()
		if len(r.list_stack) > 0 {
			nfo := &r.list_stack[len(r.list_stack) - 1]
			if nfo.is_ol {
				im.Text("%d%c", nfo.cur_ol, nfo.delim)
				nfo.cur_ol += 1
				im.SameLine()
			} else {
				// imgui_md bullets only '*'; the trails use '-', which
				// is an equally valid CommonMark marker, so all three
				// bullet glyphs get the Bullet treatment.
				if nfo.delim == '*' || nfo.delim == '-' || nfo.delim == '+' {
					cx := im.GetCursorPosX()
					im.SetCursorPosX(cx - im.GetStyle().FramePadding.x * 2)
					im.Bullet()
				} else {
					im.Text("%c", nfo.delim)
					im.SameLine()
				}
			}
		}
		im.Indent()
	} else {
		im.Unindent()
	}
}

block_hr :: proc(r: ^Md_Render, e: bool) {
	if !e {
		im.NewLine()
		im.Separator()
	}
}

// Table handlers: imgui_md's logic 1:1, window-local cursor
// coordinates like the original. Never visually verified with a trail
// page (no trail uses tables today).
block_table :: proc(r: ^Md_Render, e: bool) {
	if e {
		clear(&r.table.row_pos)
		clear(&r.table.col_pos)
		r.table.last_pos = im.GetCursorPos()
	} else {
		im.NewLine()
		r.table.last_pos.y = im.GetCursorPos().y
		append(&r.table.col_pos, r.table.last_pos.x)
		append(&r.table.row_pos, r.table.last_pos.y)

		wp := im.GetWindowPos()
		sp := im.GetStyle().ItemSpacing
		wx := wp.x + sp.x / 2
		wy := wp.y - sp.y / 2 - im.GetScrollY()

		for i := 0; i < len(r.table.col_pos); i += 1 {
			r.table.col_pos[i] += wx
		}
		for i := 0; i < len(r.table.row_pos); i += 1 {
			r.table.row_pos[i] += wy
		}

		c := im.GetColorU32Vec4(r.cfg.text_dim)
		dl := im.GetWindowDrawList()

		xmin := r.table.col_pos[0]
		xmax := r.table.col_pos[len(r.table.col_pos) - 1]
		for i := 0; i < len(r.table.row_pos); i += 1 {
			p := r.table.row_pos[i]
			// Row 1 is the header separator; slightly heavier, as in
			// imgui_md with m_table_header_highlight.
			w := f32(1.0)
			if i == 1 do w = 2.0
			im.DrawList_AddLine(dl, {xmin, p}, {xmax, p}, c, w)
		}
		ymin := r.table.row_pos[0]
		ymax := r.table.row_pos[len(r.table.row_pos) - 1]
		for i := 0; i < len(r.table.col_pos); i += 1 {
			p := r.table.col_pos[i]
			im.DrawList_AddLine(dl, {p, ymin}, {p, ymax}, c, 1.0)
		}
	}
}

block_thead :: proc(r: ^Md_Render, e: bool) {
	r.table.in_header = e
}

block_tbody :: proc(r: ^Md_Render, e: bool) {
	r.table.in_body = e
}

block_tr :: proc(r: ^Md_Render, e: bool) {
	im.SetCursorPosY(r.table.last_pos.y)
	if e {
		r.table.next_col = 0
		im.NewLine()
		append(&r.table.row_pos, im.GetCursorPosY())
	}
}

block_td :: proc(r: ^Md_Render, e: bool) {
	if e {
		if r.table.next_col < len(r.table.col_pos) {
			im.SetCursorPosX(r.table.col_pos[r.table.next_col])
		} else {
			append(&r.table.col_pos, r.table.last_pos.x)
		}
		r.table.next_col += 1
		im.Indent(r.table.col_pos[r.table.next_col - 1])
		im.SetCursorPos({r.table.col_pos[r.table.next_col - 1], r.table.row_pos[len(r.table.row_pos) - 1]})
	} else {
		p := im.GetCursorPos()
		im.Unindent(r.table.col_pos[r.table.next_col - 1])
		im.SetCursorPosX(p.x)
		if p.y > r.table.last_pos.y {
			r.table.last_pos.y = p.y
		}
	}
	im.TextUnformatted("")
	im.SameLine()
}

////////////////////////////////////////////////////////////////////////////////
// Text and span handlers.

md_text :: proc(r: ^Md_Render, t: MD_TEXTTYPE, s: []u8) {
	rest := s
	if (r.in_code_block || r.in_span_code) && t == .CODE {
		append(&r.code_buf, ..s[:])
		return
	}
	// Inside a link: the label accumulates; nothing is drawn until the
	// span closes (the hugging punctuation arrives after it).
	if r.holding_link {
		append(&r.link_buf, ..s[:])
		return
	}
	// An armed link (just closed) flushes glued to the next run.
	if r.armed_link != "" {
		if t == .NORMAL {
			rest = flush_armed_link(r, s)
		} else {
			// BR/SOFTBR/HTML right after a link: flush unglued.
			render_link_text(r, r.armed_link)
			r.armed_link = ""
			r.armed_href = ""
		}
	}
	switch t {
	case .NORMAL:
		if len(rest) > 0 {
			render_text(r, rest)
		}
	case .NULLCHAR: // nothing
	case .BR:
		im.NewLine()
		r.inline_open = false
	case .SOFTBR:
		// imgui_md's soft_break is empty, which glues "foo\nbar" into
		// "foobar"; a space keeps the words apart.
		im.TextUnformatted(" ")
		r.inline_open = true
	case .ENTITY:
		if string(s) == "&nbsp;" {
			im.TextUnformatted("")
			im.SameLine()
		} else {
			render_text(r, s)
		}
	case .HTML:
		if !check_html(r, s) {
			render_text(r, s)
		}
	case .LATEXMATH:
		render_text(r, s)
	case .CODE:
		// Outside code blocks/spans this is unreachable; render as text.
		render_text(r, s)
	}
}

to_bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

check_html :: proc(r: ^Md_Render, s: []u8) -> bool {
	if string(s) == "<br>" {
		im.NewLine()
		r.inline_open = false
		return true
	}
	if string(s) == "<hr>" {
		im.Separator()
		return true
	}
	if string(s) == "<u>" {
		r.is_underline = true
		return true
	}
	if string(s) == "</u>" {
		r.is_underline = false
		return true
	}
	return false // any other HTML renders literally
}

// Current text color: link > image alt > strong > em > normal.
current_text_color :: proc(r: ^Md_Render) -> im.Vec4 {
	cfg := r.cfg
	if r.href != "" do return cfg.link
	if r.is_image do return cfg.text_dim
	if r.is_strong do return cfg.text_strong
	if r.is_em do return cfg.text_em
	return cfg.text
}

// One wrapped text run. Splits at word-wrap boundaries, draws each
// chunk, and leaves the row open (inline_open) for the next inline
// item; blocks close it via end_inline.
render_text :: proc(r: ^Md_Render, s: []u8) {
	col := current_text_color(r)
	im.PushStyleColorVec4(.Text, col)
	defer im.PopStyleColor()

	// One NUL-terminated copy per run: the wrap end comes back as a
	// pointer inside this buffer, and its byte offset gives the chunk
	// length — valid for s too, the bytes are identical.
	text_c := strings.clone_to_cstring(string(s), context.temp_allocator)
	base := ([^]u8)(text_c)
	text_end_c := cstring(&base[len(s)])

	str := s[:]
	for len(str) > 0 {
		// Wrap limit: distance from the cursor to the window's right
		// content edge. When the cursor is already at or past the edge
		// (previous chunk ended exactly at it, or the panel shrank
		// under a SameLine continuation), the width goes zero/negative
		// and CalcWordWrapPosition finds no break — the run would
		// overflow and get clipped by the window ("text vanishing to
		// the right" when the sidebar narrows). Break the row first,
		// then measure a fresh full-width line.
		wl := wrap_right() - im.GetCursorScreenPos().x
		min_w :: f32(60)
		if wl < min_w && !r.table.in_body {
			im.NewLine()
			r.inline_open = false
			wl = wrap_right() - im.GetCursorScreenPos().x
		}
		if r.table.in_body {
			wl = 0
			if r.table.next_col < len(r.table.col_pos) {
				wl = r.table.col_pos[r.table.next_col]
			} else {
				wl = r.table.last_pos.x
			}
			wl -= im.GetCursorPosX()
		}
		end := im.Font_CalcWordWrapPosition(im.GetFont(), im.GetFontSize(), text_c, text_end_c, wl)
		n := len(str)
		if end != nil {
			off := int(uintptr(([^]u8)(end)) - uintptr(base))
			if off > 0 && off <= len(str) do n = off
		}
		te := str[:n]
		im.TextUnformatted(strings_to_c(string(te)))

		if r.href != "" {
			// Link click handling lives here, where the item rect is
			// the freshly drawn text chunk. A click only records the
			// href; the caller follows it after md_render returns.
			if im.IsItemHovered() {
				im.SetMouseCursor(.Hand)
				im.SetTooltip("%s", strings_to_c(r.href))
				if im.IsMouseClicked(.Left) {
					r.pending_href = strings.clone(r.href, context.temp_allocator)
				}
			}
			draw_item_line(r, im.GetItemRectMin(), im.GetItemRectMax(), true)
		}
		if r.is_underline {
			draw_item_line(r, im.GetItemRectMin(), im.GetItemRectMax(), true)
		}
		if r.is_strike {
			draw_item_line(r, im.GetItemRectMin(), im.GetItemRectMax(), false)
		}

		str = te[len(te):]
		for len(str) > 0 && str[0] == ' ' {
			str = str[1:]
		}
	}
	r.inline_open = true
}

// Underline (under=true) or strikethrough (under=false) across the
// last submitted item's rect.
draw_item_line :: proc(r: ^Md_Render, rmin, rmax: im.Vec2, under: bool) {
	a, b := rmin, rmax
	if !under {
		b.y -= im.GetFontSize() / 2
	}
	a.y = b.y
	col := im.GetColorU32Vec4(current_text_color(r))
	im.DrawList_AddLine(im.GetWindowDrawList(), a, b, col, 1.0)
}


span_em :: proc(r: ^Md_Render, e: bool) {
	r.is_em = e
}

span_strong :: proc(r: ^Md_Render, e: bool) {
	r.is_strong = e
}

span_u :: proc(r: ^Md_Render, e: bool) {
	r.is_underline = e
}

span_del :: proc(r: ^Md_Render, e: bool) {
	r.is_strike = e
}

span_img :: proc(r: ^Md_Render, e: bool) {
	// No texture loading: alt text renders dimmed via render_text.
	r.is_image = e
}

span_a :: proc(r: ^Md_Render, d: ^MD_SPAN_A_DETAIL, e: bool) {
	if e {
		href := string(d.href.text[:d.href.size])
		r.href = strings.clone(href, context.temp_allocator)
		clear(&r.link_buf)
		r.holding_link = true
	} else {
		// Don't draw yet: the punctuation hugging the link's closing
		// parenthesis (": troque…") arrives in the NEXT text callback,
		// and it must wrap together with the label — never orphaned at
		// the start of a line. Arm the link; the next md_text (or the
		// next block boundary) flushes label + glued tail as one unit.
		r.holding_link = false
		if len(r.link_buf) > 0 {
			r.armed_link = strings.clone(string(r.link_buf[:]), context.temp_allocator)
			r.armed_href = r.href
		}
		r.href = ""
	}
}

// Draws an armed link's label and glues any leading hugging
// punctuation of `s` onto it, so label + tail always wrap as one
// unit. Returns the remainder of s after the glued punctuation.
flush_armed_link :: proc(r: ^Md_Render, s: []u8) -> []u8 {
	rest := s
	glue := 0
	for glue < len(rest) && is_hugging_punct(rest[glue]) {
		glue += 1
	}
	combined := r.armed_link
	if glue > 0 {
		combined = fmt.tprintf("%s%s", r.armed_link, string(rest[:glue]))
	}
	render_link_text(r, combined)
	r.armed_link = ""
	r.armed_href = ""
	return rest[glue:]
}

is_hugging_punct :: proc(c: u8) -> bool {
	return c == ':' || c == ',' || c == '.' || c == ';' || c == '!' || c == '?' || c == ')' || c == '»'
}

// Link-colored, clickable wrapped text — the same wrap/click path as
// render_text, with the armed link's href restored so color and click
// handling engage.
render_link_text :: proc(r: ^Md_Render, text: string) {
	if len(text) == 0 {
		return
	}
	href := r.armed_href
	if href == "" do href = r.href
	r.href = href
	render_text(r, to_bytes(text))
	r.href = ""
}

span_code :: proc(r: ^Md_Render, e: bool) {
	if e {
		clear(&r.code_buf)
		r.in_span_code = true
	} else {
		r.in_span_code = false
		render_chip(r, string(r.code_buf[:]))
	}
}

////////////////////////////////////////////////////////////////////////////////
// Chips and code blocks.

// Right edge (screen space) inline items must stay inside.
wrap_right :: proc() -> f32 {
	return im.GetWindowPos().x + im.GetWindowSize().x - im.GetStyle().WindowPadding.x
}

// Inline code chip: rounded rect behind the text, click copies.
render_chip :: proc(r: ^Md_Render, code: string) {
	if len(code) == 0 {
		return
	}
	text_w := im.CalcTextSize(strings_to_c(code)).x
	w := text_w + 6
	h := im.GetTextLineHeight() + 2

	// Wrap to the next row when the chip doesn't fit — also when the
	// cursor is already past the edge (panel shrank under a SameLine
	// continuation): a zero/negative remaining width must not glue the
	// chip to a clipped position.
	if r.inline_open {
		if im.GetCursorScreenPos().x + w > wrap_right() {
			im.NewLine()
			r.inline_open = false
		} else {
			im.SameLine(0, 0)
		}
	}

	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, im.Vec2{pos.x + w, pos.y + h}, im.GetColorU32Vec4(r.cfg.chip_bg), 3)
	// Text drawn directly on the draw list so the rect stays behind it.
	im.DrawList_AddText(dl, im.Vec2{pos.x + 3, pos.y + 1}, im.GetColorU32Vec4(r.cfg.code_colors.declaration), strings_to_c(code))

	// The click target is the invisible button submitted last, so
	// IsItemHovered refers to it and not to earlier text. The ID must
	// be unique: ImGui drops duplicate-ID widgets in the same window,
	// so a fixed "##md_chip" would leave every chip after the first
	// without a click target.
	im.SetCursorScreenPos(pos)
	r.widget_seq += 1
	im.PushID(strings_to_c(fmt.tprintf("md_chip_%d", r.widget_seq)))
	im.InvisibleButton("##chip", {w, h})
	im.PopID()
	if im.IsItemHovered() {
		im.SetMouseCursor(.Hand)
		im.SetTooltip("%s", r.cfg.tip_chip)
		if im.IsMouseClicked(.Left) {
			im.SetClipboardText(strings_to_c(code))
			r.cfg.on_copy(code)
		}
	}
	r.inline_open = true
}

render_code_block :: proc(r: ^Md_Render, text: string) {
	lines, _ := strings.split_lines(text, context.temp_allocator)
	// A trailing newline from the parser must not add an empty row.
	if n := len(lines); n > 0 && lines[n - 1] == "" {
		lines = lines[:n - 1]
	}
	if len(lines) == 0 {
		return
	}

	rect_min := im.GetCursorScreenPos()
	width := im.GetContentRegionAvail().x
	pad :: f32(6)
	dl := im.GetWindowDrawList()

	// The per-segment TextColored items each advance the cursor by the
	// frame height plus ItemSpacing.y — with a pushed heading font the
	// row pitch drifts bigger line by line. Pin the vertical pitch to
	// one text line: every row is laid out at an exact
	// GetTextLineHeight() step via SetCursorScreenPos, and the
	// segments carry zero spacing via SameLine(0, 0).
	line_h := im.GetTextLineHeight()
	im.DrawList_ChannelsSplit(dl, 2)
	im.DrawList_ChannelsSetCurrent(dl, 1) // text layer
	row_y := make([dynamic]f32, context.temp_allocator)
	for line in lines {
		row := im.GetCursorScreenPos()
		append(&row_y, row.y)
		render_code_line(r, line, row, line_h)
	}
	rect_max := im.Vec2{rect_min.x, row_y[len(row_y) - 1] + line_h}
	im.DrawList_ChannelsSetCurrent(dl, 0)
	im.DrawList_AddRectFilled(
		dl,
		{rect_min.x - pad, rect_min.y - 2},
		{rect_min.x + width, rect_max.y + 4},
		im.GetColorU32Vec4(r.cfg.code_bg),
		4,
	)
	im.DrawList_AddLine(
		dl,
		{rect_min.x - pad + 1, rect_min.y - 2},
		{rect_min.x - pad + 1, rect_max.y + 4},
		im.GetColorU32Vec4(r.cfg.code_edge),
		2,
	)
	im.DrawList_ChannelsMerge(dl)

	// Click-to-copy: one invisible item spanning the block. Click
	// copies the hovered line, double-click the whole block. Unique
	// ID per block: duplicate widget IDs are dropped by ImGui.
	im.SetCursorScreenPos({rect_min.x - pad, rect_min.y - 2})
	r.widget_seq += 1
	im.PushID(strings_to_c(fmt.tprintf("md_block_%d", r.widget_seq)))
	im.InvisibleButton("##block", {width + pad * 2, (rect_max.y + 4) - (rect_min.y - 2)})
	im.PopID()
	if im.IsItemHovered() {
		im.SetMouseCursor(.Hand)
		im.SetTooltip("%s", r.cfg.tip_block)
		if im.GetMouseClickedCount(.Left) >= 2 {
			block_text := strings.join(lines, "\n", context.temp_allocator)
			im.SetClipboardText(strings_to_c(block_text))
			r.cfg.on_copy(block_text)
		} else if im.IsMouseClicked(.Left) {
			my := im.GetMousePos().y
			row := 0
			for i := 0; i < len(row_y); i += 1 {
				if row_y[i] <= my do row = i
			}
			im.SetClipboardText(strings_to_c(lines[row]))
			r.cfg.on_copy(lines[row])
		}
	}
	im.SetCursorScreenPos({rect_min.x, rect_max.y})
	r.inline_open = false
}

// One highlighted code line, laid out at an exact row position: all
// segments go on the draw list at fixed pitch (no ImGui cursor
// advancement), so the block's line spacing is exactly line_h and
// unaffected by ItemSpacing or pushed heading fonts.
render_code_line :: proc(r: ^Md_Render, line: string, row: im.Vec2, line_h: f32) {
	p := &r.cfg.code_colors
	dl := im.GetWindowDrawList()
	x := row.x + 4 // two-space visual indent
	flush :: proc(dl: ^im.DrawList, line: string, from, to: int, col: im.Vec4, x, y: f32) -> f32 {
		if to <= from do return x
		im.DrawList_AddText(dl, {x, y}, im.GetColorU32Vec4(col), strings_to_c(line[from:to]))
		return x + im.CalcTextSize(strings_to_c(line[from:to])).x
	}

	i := 0
	seg_start := 0
	y := row.y
	for i < len(line) {
		c := line[i]
		// Comment: rest of the line is dim. Trail code is ASCII, so
		// byte-wise scanning is safe; non-ASCII bytes travel inside a
		// plain segment.
		if c == '/' && i + 1 < len(line) && line[i + 1] == '/' {
			x = flush(dl, line, seg_start, i, p.text, x, y)
			x = flush(dl, line, i, len(line), p.comment, x, y)
			seg_start = len(line)
			break
		}
		// Identifier start: namespace, keyword, host object, function
		// call, or plain word.
		if is_ident_byte(c) && (i == 0 || !is_ident_byte(line[i - 1])) {
			j := i
			for j < len(line) && is_ident_byte(line[j]) {
				j += 1
			}
			word := line[i:j]
			if j + 1 < len(line) && line[j] == ':' && line[j + 1] == ':' {
				if slice_contains(r.cfg.ns, word) {
					x = flush(dl, line, seg_start, i, p.text, x, y)
					x = flush(dl, line, i, j + 2, p.known_identifier, x, y)
					seg_start = j + 2
					i = j + 2
					continue
				}
			}
			if slice_contains(r.cfg.host, word) {
				x = flush(dl, line, seg_start, i, p.text, x, y)
				x = flush(dl, line, i, j, p.known_identifier, x, y)
				seg_start = j
				i = j
				continue
			}
			if slice_contains(r.cfg.keywords, word) {
				x = flush(dl, line, seg_start, i, p.text, x, y)
				x = flush(dl, line, i, j, p.keyword, x, y)
				seg_start = j
				i = j
				continue
			}
			// Function call: identifier followed (after optional
			// spaces) by '('.
			k := j
			for k < len(line) && line[k] == ' ' {
				k += 1
			}
			if k < len(line) && line[k] == '(' {
				x = flush(dl, line, seg_start, i, p.text, x, y)
				x = flush(dl, line, i, j, p.declaration, x, y)
				seg_start = j
				i = j
				continue
			}
			i = j
			continue
		}
		// Number literal.
		if c >= '0' && c <= '9' && (i == 0 || !is_ident_byte(line[i - 1])) {
			j := i
			for j < len(line) && line[j] >= '0' && line[j] <= '9' || j < len(line) && (line[j] == '.' || line[j] == 'f') {
				j += 1
			}
			x = flush(dl, line, seg_start, i, p.text, x, y)
			x = flush(dl, line, i, j, p.number, x, y)
			seg_start = j
			i = j
			continue
		}
		i += 1
	}
	if seg_start < len(line) {
		flush(dl, line, seg_start, len(line), p.text, x, y)
	}
	// Keep the layout cursor in step with the drawn rows.
	im.SetCursorScreenPos({row.x, row.y + line_h})
}

slice_contains :: proc(list: []string, word: string) -> bool {
	for s in list {
		if s == word do return true
	}
	return false
}

is_ident_byte :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}
