package sdl

import "core:c"
import glove "../.."
import sdl3 "vendor:sdl3"

create :: proc() -> glove.Adapter {
	return {event_type = typeid_of(sdl3.Event), register_event = register_event}
}

register_event :: proc(user_data: rawptr, system: ^glove.System, raw_event: rawptr) -> bool {
	_ = user_data
	event := cast(^sdl3.Event)raw_event

	#partial switch event.type {
	case .KEY_DOWN, .KEY_UP:
		key, ok := key_from_scancode(event.key.scancode)
		if !ok do return false
		glove.key_set(system, key, event.key.down)
		return true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button, ok := mouse_button_from_sdl(event.button.button)
		if !ok do return false
		glove.mouse_set_button(system, button, event.button.down)
		glove.mouse_move(system, {event.button.x, event.button.y}, {})
		return true
	case .MOUSE_MOTION:
		glove.mouse_move(
			system,
			{event.motion.x, event.motion.y},
			{event.motion.xrel, event.motion.yrel},
		)
		return true
	case .MOUSE_WHEEL:
		wheel := [2]f32{event.wheel.x, event.wheel.y}
		if event.wheel.direction == .FLIPPED do wheel = -wheel
		glove.mouse_scroll(system, wheel)
		glove.mouse_move(system, {event.wheel.mouse_x, event.wheel.mouse_y}, {})
		return true
	case .WINDOW_FOCUS_LOST:
		glove.focus_set(system, false)
		return true
	case .WINDOW_FOCUS_GAINED:
		glove.focus_set(system, true)
		return true
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		glove.request_quit(system)
		return true
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
		window := sdl3.GetWindowFromID(event.window.windowID)
		if window != nil {
			w, h: c.int
			pw, ph: c.int
			sdl3.GetWindowSize(window, &w, &h)
			sdl3.GetWindowSizeInPixels(window, &pw, &ph)
			glove.window_resize(system, {i32(w), i32(h)}, {i32(pw), i32(ph)})
		}
	return true
	}
	return false
}

key_from_scancode :: proc(scancode: sdl3.Scancode) -> (glove.Key, bool) {
	key := glove.Key(scancode)
	return key, glove.key_is_valid(key)
}

mouse_button_from_sdl :: proc(button: u8) -> (glove.Mouse_Button, bool) {
	if button < sdl3.BUTTON_LEFT || button > sdl3.BUTTON_X2 do return .Unknown, false
	mouse_button := glove.Mouse_Button(button)
	return mouse_button, glove.mouse_button_is_valid(mouse_button)
}
