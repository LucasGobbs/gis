package mock

import glove "../.."

Event_Kind :: enum {
	Key,
	Keyboard_Reset,
	Mouse_Button,
	Mouse_Move,
	Mouse_Scroll,
	Mouse_Reset,
	Window_Resize,
	Quit,
	Focus,
}

Event :: struct {
	kind:      Event_Kind,
	key:       glove.Key,
	button:    glove.Mouse_Button,
	down:      bool,
	position:  [2]f32,
	delta:     [2]f32,
	wheel:     [2]f32,
	size:      [2]i32,
	pixel_size: [2]i32,
	focused:   bool,
}

create :: proc() -> glove.Adapter {
	return {event_type = typeid_of(Event), register_event = register_event}
}

key_event :: proc(key: glove.Key, down: bool) -> Event {
	return {kind = .Key, key = key, down = down}
}

keyboard_reset_event :: proc() -> Event {
	return {kind = .Keyboard_Reset}
}

mouse_button_event :: proc(button: glove.Mouse_Button, down: bool) -> Event {
	return {kind = .Mouse_Button, button = button, down = down}
}

mouse_move_event :: proc(position, delta: [2]f32) -> Event {
	return {kind = .Mouse_Move, position = position, delta = delta}
}

mouse_scroll_event :: proc(wheel: [2]f32) -> Event {
	return {kind = .Mouse_Scroll, wheel = wheel}
}

mouse_reset_event :: proc() -> Event {
	return {kind = .Mouse_Reset}
}

window_resize_event :: proc(size, pixel_size: [2]i32) -> Event {
	return {kind = .Window_Resize, size = size, pixel_size = pixel_size}
}

quit_event :: proc() -> Event {
	return {kind = .Quit}
}

focus_event :: proc(focused: bool) -> Event {
	return {kind = .Focus, focused = focused}
}

register_event :: proc(user_data: rawptr, system: ^glove.System, raw_event: rawptr) -> bool {
	_ = user_data
	event := cast(^Event)raw_event
	switch event.kind {
	case .Key:
		glove.key_set(system, event.key, event.down)
	case .Keyboard_Reset:
		glove.keyboard_reset(system)
	case .Mouse_Button:
		glove.mouse_set_button(system, event.button, event.down)
	case .Mouse_Move:
		glove.mouse_move(system, event.position, event.delta)
	case .Mouse_Scroll:
		glove.mouse_scroll(system, event.wheel)
	case .Mouse_Reset:
		glove.mouse_reset(system)
	case .Window_Resize:
		glove.window_resize(system, event.size, event.pixel_size)
	case .Quit:
		glove.request_quit(system)
	case .Focus:
		glove.focus_set(system, event.focused)
	}
	return true
}
