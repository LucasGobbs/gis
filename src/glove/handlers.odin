package glove


// Named-action lookup, handler registration and the per-frame dispatch
// that runs them. Handlers fire only through dispatch: capture filtering
// and trigger evaluation live here, never in the app.

import "core:log"

action_find :: proc(system: ^System, name: string) -> (Button_Action, bool) {
	for action, index in system.button_actions {
		if action.name == name do return Button_Action(index), true
	}
	return {}, false
}

axis_2d_find :: proc(system: ^System, name: string) -> (Axis_2D_Action, bool) {
	for action, index in system.axis_2d_actions {
		if action.name == name do return Axis_2D_Action(index), true
	}
	return {}, false
}

set_action_respects :: proc(system: ^System, action: Button_Action, respects: Captures) {
	assert(button_action_is_valid(system, action))
	system.button_actions[int(action)].respects = respects
}

on_button :: proc(
	system: ^System,
	action: Button_Action,
	trigger: Trigger,
	handler: Button_Handler,
	user_data: rawptr = nil,
) {
	assert(button_action_is_valid(system, action))
	assert(handler != nil)
	context.allocator = system.allocator
	append_elem(
		&system.button_handlers,
		Button_Handler_Entry{action = action, trigger = trigger, handler = handler, user_data = user_data},
	)
}

on_axis_2d :: proc(
	system: ^System,
	action: Axis_2D_Action,
	handler: Axis_2D_Handler,
	user_data: rawptr = nil,
) {
	assert(axis_2d_action_is_valid(system, action))
	assert(handler != nil)
	context.allocator = system.allocator
	append_elem(
		&system.axis_2d_handlers,
		Axis_2D_Handler_Entry{action = action, handler = handler, user_data = user_data},
	)
}

on_resize :: proc(system: ^System, handler: Window_Handler, user_data: rawptr = nil) {
	assert(handler != nil)
	context.allocator = system.allocator
	append_elem(&system.resize_handlers, handler)
	append_elem(&system.resize_handler_data, user_data)
}

on_quit :: proc(system: ^System, handler: Quit_Handler, user_data: rawptr = nil) {
	assert(handler != nil)
	context.allocator = system.allocator
	append_elem(&system.quit_handlers, handler)
	append_elem(&system.quit_handler_data, user_data)
}

// Capture filter for this frame, set once before dispatch: actions whose
// `respects` intersects it are skipped. Queries stay raw — capture gates
// dispatch only (e.g. the shader mouse uniform reads position over UI).
set_captures :: proc(system: ^System, captures: Captures) {
	system.captures = captures
}

// Captured, per the action's `respects` mask.
captured :: proc(system: ^System, respects: Captures) -> bool {
	return respects & system.captures != {}
}

dispatch :: proc(system: ^System) {
	for entry in system.button_handlers {
		data := &system.button_actions[int(entry.action)]
		if captured(system, data.respects) do continue
		fire: bool
		switch entry.trigger {
		case .Pressed:  fire = data.state.pressed
		case .Released: fire = data.state.released
		case .Down:     fire = data.state.down
		case .Changed:  fire = false
		}
		if fire {
			if system.action_log_enabled do log.infof("[input] action %s (%v)", data.name, entry.trigger)
			entry.handler(entry.user_data, system, entry.action)
		}
	}

	for entry in system.axis_2d_handlers {
		// Axis actions carry no respects mask: any active capture gates
		// them (they are driven by raw keys/mouse, never app-typed text).
		if system.captures != {} do continue
		state := &system.axis_2d_actions[int(entry.action)].state
		if state.changed do entry.handler(entry.user_data, system, entry.action, state.value)
	}

	if system.window_resized {
		for handler, index in system.resize_handlers {
			handler(system.resize_handler_data[index], system, system.window_size, system.window_pixel_size)
		}
	}

	if system.quit_requested && !system.quit_dispatched {
		for handler, index in system.quit_handlers {
			handler(system.quit_handler_data[index], system)
		}
		system.quit_dispatched = true
	}
}
