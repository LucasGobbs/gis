package main

// User-facing error/notice toasts, drawn top-right of the window.
// Replaces fatal error paths (SDL asserts, build failures) with visible
// notifications: the app keeps running, the user sees what happened.
// Duplicate messages within a short window refresh the existing toast
// instead of flooding (a per-frame SDL validation error would otherwise
// spawn 60 toasts a second).
import im "../vendor/odin-imgui"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

NotifyKind :: enum {
	INFO,
	WARN,
	ERROR,
}

Notice :: struct {
	text: string, // owned
	kind: NotifyKind,
	age:  f32,
	hits: int, // repeated occurrences folded into this toast
}

NOTIFY_LIFETIME :: f32(7.0)
NOTIFY_FADE :: f32(0.6)
NOTIFY_DEDUP_WINDOW :: f32(2.0)
NOTIFY_MAX :: 5

notices: [dynamic]Notice
notify_mu: sync.Mutex

// Saved main-thread context for the SDL assertion callback (a "c" proc
// on an arbitrary thread).
g_sdl_context: runtime.Context

notify :: proc(kind: NotifyKind, fmt_str: string, args: ..any) {
	sync.mutex_lock(&notify_mu)
	defer sync.mutex_unlock(&notify_mu)
	message := fmt.tprintf(fmt_str, ..args)
	// Dedupe: same text seen recently -> refresh and count, no new card.
	for &existing in notices {
		if existing.text == message && existing.age < NOTIFY_DEDUP_WINDOW {
			existing.age = 0
			existing.hits += 1
			return
		}
	}
	append(&notices, Notice{text = strings.clone(message), kind = kind})
	for len(notices) > NOTIFY_MAX {
		delete(notices[0].text)
		ordered_remove(&notices, 0)
	}
}

// Packs a color WITHOUT the style alpha that im.GetColorU32Vec4 bakes
// in: toasts must stay opaque regardless of surrounding panel state.
ncol :: proc(r, g, b, a: f32) -> u32 {
	channel :: proc(channel_value: f32) -> u32 {
		return u32(clamp(channel_value, 0, 1) * 255 + 0.5)
	}
	return channel(a) << 24 | channel(b) << 16 | channel(g) << 8 | channel(r)
}

// Toast colors follow the darkroom palette: amber accent for warnings,
// signal red for errors, neutral text for info.
notify_kind_color :: proc(kind: NotifyKind) -> im.Vec4 {
	switch kind {
	case .INFO:
		return SIGNATURE_BLUE
	case .WARN:
		return ACCENT
	case .ERROR:
		return ERROR_RED
	}
	return {1, 1, 1, 1}
}

// Foreground overlay, called once per frame after all windows. Cards
// slide in from the right, hold, then fade; a click dismisses.
notify_draw :: proc(dt: f32) {
	sync.mutex_lock(&notify_mu)
	defer sync.mutex_unlock(&notify_mu)
	if len(notices) == 0 do return
	imgui_io := im.GetIO()
	draw_list := im.GetForegroundDrawList()
	card_width := f32(340)
	padding := f32(10)
	left_x := imgui_io.DisplaySize.x - card_width - 12
	top_y := f32(10)
	for i := len(notices) - 1; i >= 0; i -= 1 {
		notice := &notices[i]
		notice.age += dt
		if notice.age >= NOTIFY_LIFETIME {
			delete(notice.text)
			ordered_remove(&notices, i)
			continue
		}
		// Entrance slide (first 0.25s) and exit fade (last NOTIFY_FADE).
		slide := min(notice.age / 0.25, 1)
		x_offset := (1 - slide * slide) * 40
		alpha := 1 - math.smoothstep(NOTIFY_LIFETIME - NOTIFY_FADE, NOTIFY_LIFETIME, notice.age)
		stack_index := f32(len(notices) - 1 - i) // stack order: newest at top
		card_height := padding * 2 + im.GetTextLineHeight() * 1.15
		card_y := top_y + stack_index * (card_height + 8)
		card_min := im.Vec2{left_x + x_offset, card_y}
		card_max := im.Vec2{left_x + card_width + x_offset, card_y + card_height}
		// Click to dismiss.
		mouse := imgui_io.MousePos
		if imgui_io.MouseClicked[0] &&
		   mouse.x >= card_min.x && mouse.x <= card_max.x &&
		   mouse.y >= card_min.y && mouse.y <= card_max.y {
			delete(notice.text)
			ordered_remove(&notices, i)
			continue
		}
		accent := notify_kind_color(notice.kind)
		im.DrawList_AddRectFilled(draw_list, card_min, card_max, ncol(0.09, 0.09, 0.10, alpha), 6)
		// Accent bar: square corners, clipped inside the card's rounding.
		im.DrawList_AddRectFilled(
			draw_list,
			card_min,
			{card_min.x + 3, card_max.y},
			ncol(accent.x, accent.y, accent.z, alpha),
		)
		label := notice.text
		if notice.hits > 1 {
			label = fmt.tprintf("%s (×%d)", notice.text, notice.hits)
		}
		im.DrawList_AddText(
			draw_list,
			{card_min.x + padding + 4, card_min.y + padding - 1},
			ncol(0.92, 0.92, 0.92, alpha),
			strings_to_c(label),
		)
	}
}

// SDL assertion handler: validation errors (bad bindings, invalid state)
// become error toasts instead of the abort dialog. The app keeps running
// with the previous frame's state; the log keeps the full condition.
sdl_assert_notify :: proc "c" (data: ^sdl.AssertData, userdata: rawptr) -> sdl.AssertState {
	context = g_sdl_context
	condition := string(data.condition)
	source_file := string(data.filename)
	log.errorf("SDL assert: %s (%s:%s:%d, ×%d)", condition, source_file, string(data.function), data.linenum, data.trigger_count)
	notify(.ERROR, "GPU: %s", condition)
	return .IGNORE
}
