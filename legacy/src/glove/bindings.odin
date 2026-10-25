package glove

bind_key :: proc(
	system: ^System,
	action: Button_Action,
	key: Key,
	modifiers: Modifiers = {},
) {
	assert(button_action_is_valid(system, action))
	assert(key_is_valid(key))
	context.allocator = system.allocator
	append_elem(
		&system.key_bindings,
		Key_Binding{action = action, key = key, modifiers = modifiers},
	)
}

bind_mouse_button :: proc(system: ^System, action: Button_Action, button: Mouse_Button) {
	assert(button_action_is_valid(system, action))
	assert(mouse_button_is_valid(button))
	context.allocator = system.allocator
	append_elem(
		&system.mouse_button_bindings,
		Mouse_Button_Binding{action = action, button = button},
	)
}

bind_button_axis_2d :: proc(system: ^System, action: Axis_2D_Action, desc: Button_Axis_2D_Desc) {
	assert(axis_2d_action_is_valid(system, action))
	assert(key_is_valid(desc.up))
	assert(key_is_valid(desc.down))
	assert(key_is_valid(desc.left))
	assert(key_is_valid(desc.right))
	context.allocator = system.allocator
	append_elem(
		&system.button_axis_2d_bindings,
		Button_Axis_2D_Binding{action = action, desc = desc},
	)
}

resolve_buttons :: proc(system: ^System) {
	for &action in system.button_actions do action.state.down = false

	for binding in system.key_bindings {
		if !system.keys[int(binding.key)] do continue
		// Exact-modifier match: S alone does not fire gui+s, and gui+s
		// does not fire when extra modifiers are held. Exception: when
		// the bound key IS a modifier key (hold_gui = lgui), comparing
		// modifiers would always fail (holding LGUI sets .Gui), so only
		// the key state counts.
		if binding.key < .LSHIFT || binding.key > .RGUI {
			if system.modifiers != binding.modifiers do continue
		}
		system.button_actions[int(binding.action)].state.down = true
	}

	for binding in system.mouse_button_bindings {
		if system.mouse.buttons[int(binding.button)] {
			system.button_actions[int(binding.action)].state.down = true
		}
	}

	for &action in system.button_actions {
		action.state.pressed = action.state.down && !action.previous_down
		action.state.released = !action.state.down && action.previous_down
	}
}

resolve_axis_2d :: proc(system: ^System) {
	for &binding in system.button_axis_2d_bindings {
		previous := binding.value
		binding.value = evaluate_button_axis_2d(system, binding.desc)

		if binding.value != {} && binding.value != previous {
			system.actuation_serial += 1
			binding.last_actuation_serial = system.actuation_serial
		}
	}

	for &action, action_index in system.axis_2d_actions {
		selected := -1
		selected_serial: u64

		if action.owner_binding >= 0 &&
		   action.owner_binding < len(system.button_axis_2d_bindings) {
			owner := &system.button_axis_2d_bindings[action.owner_binding]
			if owner.action == Axis_2D_Action(action_index) && owner.value != {} {
				selected = action.owner_binding
				selected_serial = owner.last_actuation_serial
			}
		}

		for binding, binding_index in system.button_axis_2d_bindings {
			if binding.action != Axis_2D_Action(action_index) || binding.value == {} do continue
			if selected < 0 || binding.last_actuation_serial > selected_serial {
				selected = binding_index
				selected_serial = binding.last_actuation_serial
			}
		}

		action.owner_binding = selected
		action.state.value = {}
		if selected >= 0 {
			action.state.value = system.button_axis_2d_bindings[selected].value
		}
		action.state.changed = action.state.value != action.state.previous
	}
}

evaluate_button_axis_2d :: proc(system: ^System, desc: Button_Axis_2D_Desc) -> [2]f32 {
	value: [2]f32
	if system.keys[int(desc.right)] do value.x += 1
	if system.keys[int(desc.left)] do value.x -= 1
	if system.keys[int(desc.up)] do value.y += 1
	if system.keys[int(desc.down)] do value.y -= 1

	if desc.normalize && value.x != 0 && value.y != 0 {
		INV_SQRT_TWO :: f32(0.7071067811865475)
		value *= INV_SQRT_TWO
	}
	return value
}
