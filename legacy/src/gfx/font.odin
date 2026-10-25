// Simple font renderer: bakes a TTF into a glyph atlas with stb_truetype,
// uploads it as a texture, and lays out text as pixel-space quads (y-down,
// origin at the baseline). Projection is the caller's problem — the editor
// maps quads to NDC, game UI can map them however it likes. Available as
// an abstraction only: the app's UI keeps using ImGui fonts.
package gfx

import "core:math"
import "core:os"
import stbtt "vendor:stb/truetype"

FONT_FIRST_CHAR :: 32
FONT_CHAR_COUNT :: 95 // ASCII 32..126
FONT_ATLAS_SIZE :: 256

// UV of the solid white block in the atlas, for drawing rects with the same
// texture.
FONT_WHITE_U :: 1.5 / FONT_ATLAS_SIZE
FONT_WHITE_V :: (FONT_ATLAS_SIZE - 1.5) / FONT_ATLAS_SIZE

Font_Metric :: struct {
	// Glyph bounding box in atlas pixels, plus placement offsets.
	x0, y0, x1, y1: f32,
	xoff, yoff:     f32,
	xadvance:       f32,
}

Font_Quad :: struct {
	x0, y0, x1, y1: f32, // pixel space, y-down
	s0, t0, s1, t1: f32, // atlas UV
}

Font :: struct {
	texture:      Texture_Handle,
	metrics:      [FONT_CHAR_COUNT]Font_Metric,
	line_height:  i32,
	// Distance from a line's top to the baseline; add it to a top-left y
	// before laying out text.
	baseline:     i32,
}

font_create :: proc(gfx_state: ^Gfx, path: string, pixel_height: f32 = 16) -> (Font, bool) {
	font_data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil do return {}, false

	pixels := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE, context.temp_allocator)
	chars: [FONT_CHAR_COUNT]stbtt.bakedchar
	baked := stbtt.BakeFontBitmap(
		raw_data(font_data),
		0,
		pixel_height,
		raw_data(pixels),
		FONT_ATLAS_SIZE,
		FONT_ATLAS_SIZE,
		FONT_FIRST_CHAR,
		FONT_CHAR_COUNT,
		raw_data(chars[:]),
	)
	if baked == 0 do return {}, false

	font := Font {
		line_height = i32(pixel_height) + 2,
		baseline    = i32(pixel_height),
	}
	for char_metric, char_index in chars {
		font.metrics[char_index] = {
			x0 = f32(char_metric.x0), y0 = f32(char_metric.y0),
			x1 = f32(char_metric.x1), y1 = f32(char_metric.y1),
			xoff = char_metric.xoff, yoff = char_metric.yoff,
			xadvance = char_metric.xadvance,
		}
	}

	// White block for solid rects.
	pixels[(FONT_ATLAS_SIZE - 2) * FONT_ATLAS_SIZE + 0] = 0xFF
	pixels[(FONT_ATLAS_SIZE - 2) * FONT_ATLAS_SIZE + 1] = 0xFF
	pixels[(FONT_ATLAS_SIZE - 1) * FONT_ATLAS_SIZE + 0] = 0xFF
	pixels[(FONT_ATLAS_SIZE - 1) * FONT_ATLAS_SIZE + 1] = 0xFF

	// Alpha8 -> white RGBA8 so textured pipelines can multiply tint.
	rgba_pixels := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE * 4, context.temp_allocator)
	for alpha, pixel_index in pixels {
		rgba_pixels[pixel_index * 4 + 0] = 0xFF
		rgba_pixels[pixel_index * 4 + 1] = 0xFF
		rgba_pixels[pixel_index * 4 + 2] = 0xFF
		rgba_pixels[pixel_index * 4 + 3] = alpha
	}
	font.texture = gfx_texture_create(
		gfx_state,
		FONT_ATLAS_SIZE,
		FONT_ATLAS_SIZE,
		.R8G8B8A8_UNORM,
		.SAMPLER,
	)
	atlas := gfx_texture_get(gfx_state, font.texture)
	atlas._staging_data = rgba_pixels
	uploader_begin(&gfx_state.uploader)
	uploader_upload_texture(&gfx_state.uploader, font.texture)
	uploader_flush_blocking(&gfx_state.uploader)
	atlas._staging_data = nil
	return font, true
}

font_destroy :: proc(gfx_state: ^Gfx, font: ^Font) {
	gfx_texture_destroy(gfx_state, font.texture)
	font^ = {}
}

font_text_width :: proc(font: ^Font, text: string) -> f32 {
	width: f32
	for char_code in text {
		if char_code < FONT_FIRST_CHAR || char_code >= FONT_FIRST_CHAR + FONT_CHAR_COUNT do continue
		width += font.metrics[char_code - FONT_FIRST_CHAR].xadvance
	}
	return width
}

// One glyph as a quad; advances x by the glyph's advance. Returns false for
// characters outside the baked range.
font_glyph_quad :: proc(font: ^Font, char_code: rune, x, y: ^f32) -> (Font_Quad, bool) {
	if char_code < FONT_FIRST_CHAR || char_code >= FONT_FIRST_CHAR + FONT_CHAR_COUNT do return {}, false
	metric := font.metrics[char_code - FONT_FIRST_CHAR]
	round_x := math.floor(x^ + metric.xoff)
	round_y := math.floor(y^ + metric.yoff)
	quad := Font_Quad {
		x0 = round_x,
		y0 = round_y,
		x1 = round_x + (metric.x1 - metric.x0),
		y1 = round_y + (metric.y1 - metric.y0),
		s0 = metric.x0 / FONT_ATLAS_SIZE,
		t0 = metric.y0 / FONT_ATLAS_SIZE,
		s1 = metric.x1 / FONT_ATLAS_SIZE,
		t1 = metric.y1 / FONT_ATLAS_SIZE,
	}
	x^ += metric.xadvance
	return quad, true
}

font_layout :: proc(font: ^Font, text: string, x, y: ^f32, quads: ^[dynamic]Font_Quad) {
	for char_code in text {
		quad, ok := font_glyph_quad(font, char_code, x, y)
		if ok do append(quads, quad)
	}
}
