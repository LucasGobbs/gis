package sdl

import "core:c"
import glove "../.."
import sdl3 "vendor:sdl3"

Raw_Event_Forwarder :: #type proc(user_data: rawptr, event: ^sdl3.Event)

// Owns the per-frame sdl.PollEvent drain. Every event first goes to the
// forwarder (the ImGui backend), then into the glove system; the drain
// ends with exactly one glove.update — per-event updates would wipe the
// pressed edge between events of the same frame.
Pump :: struct {
	forwarder:      Raw_Event_Forwarder,
	forwarder_data: rawptr,
}

pump_set_forwarder :: proc(pump: ^Pump, forwarder: Raw_Event_Forwarder, user_data: rawptr) {
	pump.forwarder = forwarder
	pump.forwarder_data = user_data
}

pump_poll :: proc(pump: ^Pump, system: ^glove.System) {
	event: sdl3.Event
	for sdl3.PollEvent(&event) {
		if pump.forwarder != nil do pump.forwarder(pump.forwarder_data, &event)
		glove.register_event(system, &event)
	}
	glove.update(system)
}

// Seeds window_size/window_pixel_size at startup: no resize event fires
// for the initial size, and the first frame already needs both.
pump_seed_window :: proc(system: ^glove.System, window: ^sdl3.Window) {
	w, h: c.int
	pw, ph: c.int
	sdl3.GetWindowSize(window, &w, &h)
	sdl3.GetWindowSizeInPixels(window, &pw, &ph)
	glove.window_resize(system, {i32(w), i32(h)}, {i32(pw), i32(ph)})
	glove.update(system)
}
