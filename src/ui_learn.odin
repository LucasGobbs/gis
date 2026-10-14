package main

// LEARN mode: markdown-based learning trails. Pages live in
// assets/trails/*.md; "index" is the home page. Parsing and rendering
// live in src/md_learn.odin (md4c parser + Odin renderer); this file
// keeps trail loading, link navigation and the panel header. The
// feature that matters is the bridge to practice: [label](scene:NAME)
// loads the scene AND opens the editor on its entry file,
// [label](trail:NAME) navigates between pages.
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


// Follows a link target collected during rendering: "scene:NAME"
// loads the scene and opens the editor on it; "trail:NAME" navigates.
// Runs after md_render returns, never during parsing (learn_load
// frees learn_text under the parser's feet).
learn_follow_link :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor, target: string) {
	if strings.has_prefix(target, "scene:") {
		file := strings.trim_prefix(target, "scene:")
		for &s, i in sm.scenes {
			if s.title == file {
				emit(SceneSelected(i))
				// ed.files entries omit the .slang suffix (ied_file_path
				// appends it). The prefix comes from the scene's root: user
				// scenes live under gis_scenes/, not scenes/.
				msg: OpenFile
				msg_set(&msg.rel, fmt.tprintf("%s%s", ied_unit_prefix(file), file))
				emit(msg)
				return
			}
		}
		return
	}
	if strings.has_prefix(target, "trail:") {
		learn_load(strings.trim_prefix(target, "trail:"))
	}
}


// Renders the trail page through the md4c parser + Odin renderer
// (src/md_learn.odin). Parses and draws in one pass; a clicked link is
// collected during parsing and followed afterwards.
learn_render_page :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	cfg := Md_Config{
		text          = im.GetStyle().Colors[im.Col.Text],
		text_strong   = {1, 1, 1, 1},
		text_em       = {0.80, 0.85, 0.95, 1},
		text_dim      = im.GetStyle().Colors[im.Col.TextDisabled],
		accent        = ACCENT,
		h1            = {0.95, 0.92, 0.88, 1},
		link          = LINK_BLUE,
		code_bg       = {1, 1, 1, 0.045},
		chip_bg       = {1, 1, 1, 0.06},
		code_edge     = ACCENT_SEMITRANSPARENT,
		code_colors   = md_code_colors(ed),
		keywords      = CODE_KEYWORDS,
		ns            = CODE_NS,
		host          = CODE_HOST_IDENTS,
		tip_chip      = trc("click to copy"),
		tip_block     = trc("click: copy line · double-click: copy block"),
		on_copy       = proc(text: string) { notify(.INFO, "copied: %s", text) },
	}
	pending, ok := md_render(learn_text, &cfg)
	if !ok do return
	if pending != "" do learn_follow_link(ui, sm, ed, pending)
}

// LEARN code-token colors mirrored from the code editor's current
// theme, so the trail's syntax highlighting matches what the user sees
// in the editor. Reads the live palette off the ite component.
md_code_colors :: proc(ed: ^ImGuiEditor) -> Md_Code_Colors {
	palette: [24]u32
	ite_get_palette_u32(ed.handle, &palette[0], len(palette))
	return Md_Code_Colors{
		text             = u32_to_vec4(palette[0]),  // text
		keyword          = u32_to_vec4(palette[1]),  // keyword
		declaration      = u32_to_vec4(palette[2]),  // declaration (function calls)
		number           = u32_to_vec4(palette[3]),  // number
		known_identifier = u32_to_vec4(palette[8]),  // knownIdentifier (host idents, namespaces)
		comment          = u32_to_vec4(palette[9]),  // comment
	}
}

u32_to_vec4 :: proc(c: u32) -> im.Vec4 {
	return im.Vec4{
		f32(c & 0xFF) / 255,
		f32((c >> 8) & 0xFF) / 255,
		f32((c >> 16) & 0xFF) / 255,
		f32((c >> 24) & 0xFF) / 255,
	}
}


CODE_HOST_IDENTS :: []string{"Uniforms", "Params", "input"}

CODE_KEYWORDS :: []string{
	"float", "float2", "float3", "float4", "int", "int2", "uint", "bool",
	"return", "if", "else", "for", "while", "struct", "public", "import",
	"namespace", "uniform", "const", "void", "in", "out", "inout",
	"switch", "case", "break", "continue", "true", "false",
}

CODE_NS :: []string{"Space", "Camera", "Noise", "Sdf"}


ui_learn_panel :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	if learn_text == "" do learn_load("index")
	im.TextDisabled(trc("learn"))
	if learn_page != "index" {
		// Back to the trail index.
		im.TextColored(LINK_BLUE, "%s", strings_to_c(tr("← all trails")))
		if im.IsItemHovered() {
			im.SetMouseCursor(.Hand)
			link_min := im.GetItemRectMin()
			link_max := im.GetItemRectMax()
			im.DrawList_AddLine(
				im.GetWindowDrawList(),
				{link_min.x, link_max.y - 1},
				{link_max.x, link_max.y - 1},
				im.GetColorU32Vec4(LINK_BLUE),
				1,
			)
			if im.IsMouseClicked(.Left) {
				learn_load("index")
				return
			}
		}
		im.Separator()
	}
	learn_render_page(ui, sm, ed)
}
