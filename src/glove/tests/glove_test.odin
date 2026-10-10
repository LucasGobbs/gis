package glove_tests

import glove ".."
import mock "../adapters/mock"
import glove_sdl "../adapters/sdl"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
glove_wasd_resolves_axis_2d :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	move := glove.add_axis_2d(&inputs, "player.move")
	glove.bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event := mock.key_event(.W, true)
	testing.expect(t, glove.register_event(&inputs, &event))
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{0, 1})
	event = mock.key_event(.D, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	INV_SQRT_TWO :: f32(0.7071067811865475)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{INV_SQRT_TWO, INV_SQRT_TWO})

	events := [2]mock.Event{mock.key_event(.W, false), mock.key_event(.A, true)}
	testing.expect_value(t, glove.register_events(&inputs, events[:]), 2)
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{})
}

@(test)
glove_button_reports_update_edges :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	quit := glove.add_button(&inputs, "app.quit")
	glove.bind_key(&inputs, quit, .ESCAPE)

	event := mock.key_event(.ESCAPE, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.down(&inputs, quit))
	testing.expect(t, glove.pressed(&inputs, quit))
	glove.update(&inputs)
	testing.expect(t, !glove.pressed(&inputs, quit))
	event = mock.key_event(.ESCAPE, false)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.released(&inputs, quit))
}

@(test)
glove_sdl_translates_keyboard_and_focus_loss :: proc(t: ^testing.T) {
	inputs := glove.system_create(glove_sdl.create())
	defer glove.system_destroy(&inputs)
	move := glove.add_axis_2d(&inputs, "player.move")
	glove.bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = .W
	event.key.down = true
	testing.expect(t, glove.register_event(&inputs, &event))
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{0, 1})
	event = {}
	event.type = .WINDOW_FOCUS_LOST
	testing.expect(t, glove.register_event(&inputs, &event))
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{})
}

@(test)
glove_sdl_translates_mouse :: proc(t: ^testing.T) {
	inputs := glove.system_create(glove_sdl.create())
	defer glove.system_destroy(&inputs)
	click := glove.add_button(&inputs, "ui.click")
	glove.bind_mouse_button(&inputs, click, .X2)

	events: [3]sdl.Event
	events[0].type = .MOUSE_BUTTON_DOWN
	events[0].button.button = sdl.BUTTON_X2
	events[0].button.down = true
	events[1].type = .MOUSE_MOTION
	events[1].motion.x = 15
	events[1].motion.y = 30
	events[1].motion.xrel = 5
	events[1].motion.yrel = 10
	events[2].type = .MOUSE_WHEEL
	events[2].wheel.x = 1
	events[2].wheel.y = -2
	events[2].wheel.direction = .FLIPPED
	glove.register_events(&inputs, events[:])
	glove.update(&inputs)
	testing.expect(t, glove.pressed(&inputs, click))
	testing.expect_value(t, glove.mouse_delta(&inputs), [2]f32{5, 10})
	testing.expect_value(t, glove.mouse_wheel(&inputs), [2]f32{-1, 2})
}

@(test)
glove_mock_drives_mouse :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	click := glove.add_button(&inputs, "ui.click")
	glove.bind_mouse_button(&inputs, click, .Left)
	events := [3]mock.Event {
		mock.mouse_button_event(.Left, true),
		mock.mouse_move_event({40, 50}, {3, -2}),
		mock.mouse_scroll_event({0, 1}),
	}
	glove.register_events(&inputs, events[:])
	glove.update(&inputs)
	testing.expect(t, glove.pressed(&inputs, click))
	testing.expect_value(t, glove.mouse_position(&inputs), [2]f32{40, 50})
	testing.expect_value(t, glove.mouse_delta(&inputs), [2]f32{3, -2})
}

@(test)
glove_chord_requires_exact_modifiers :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	save := glove.add_button(&inputs, "save")
	glove.bind_key(&inputs, save, .S, {.Gui})

	event := mock.key_event(.LGUI, true)
	glove.register_event(&inputs, &event)
	event = mock.key_event(.S, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.pressed(&inputs, save))

	event = mock.key_event(.LGUI, false)
	glove.register_event(&inputs, &event)
	event = mock.key_event(.S, false)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	event = mock.key_event(.S, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, !glove.pressed(&inputs, save))

	event = mock.key_event(.S, false)
	glove.register_event(&inputs, &event)
	event = mock.key_event(.LGUI, true)
	glove.register_event(&inputs, &event)
	event = mock.key_event(.LSHIFT, true)
	glove.register_event(&inputs, &event)
	event = mock.key_event(.S, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, !glove.pressed(&inputs, save))
}

@(test)
glove_modifier_key_binding_ignores_modifier_state :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	hold := glove.add_button(&inputs, "hold")
	glove.bind_key(&inputs, hold, .LGUI)

	event := mock.key_event(.LGUI, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.down(&inputs, hold))
}

@(private)
counting_counter: int

@(private)
counting_handler :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	counting_counter += 1
}

@(test)
glove_dispatch_respects_captures :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	act := glove.add_button(&inputs, "act")
	glove.bind_key(&inputs, act, .S)
	glove.set_action_respects(&inputs, act, {.Keyboard})
	glove.on_button(&inputs, act, .Pressed, counting_handler)

	event := mock.key_event(.S, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	glove.set_captures(&inputs, {.Keyboard})
	counting_counter = 0
	glove.dispatch(&inputs)
	testing.expect(t, counting_counter == 0)

	glove.set_captures(&inputs, {})
	glove.dispatch(&inputs)
	testing.expect(t, counting_counter == 1)
}

@(test)
glove_dispatch_fires_once_per_press :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	act := glove.add_button(&inputs, "act")
	glove.bind_key(&inputs, act, .S)
	glove.on_button(&inputs, act, .Pressed, counting_handler)

	event := mock.key_event(.S, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	counting_counter = 0
	glove.dispatch(&inputs)
	glove.update(&inputs)
	glove.dispatch(&inputs)
	testing.expect(t, counting_counter == 1)
}

@(test)
glove_window_resize_and_quit :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	quit_count := 0
	glove.on_quit(&inputs, quit_handler, &quit_count)

	event := mock.window_resize_event({800, 600}, {1600, 1200})
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.window_resized(&inputs))
	testing.expect_value(t, glove.window_pixel_size(&inputs), [2]i32{1600, 1200})
	glove.update(&inputs)
	testing.expect(t, !glove.window_resized(&inputs))

	event = mock.quit_event()
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.quit_requested(&inputs))
	quit_count = 0
	glove.dispatch(&inputs)
	glove.dispatch(&inputs)
	testing.expect(t, quit_count == 1)
}

@(private)
quit_handler :: proc(user_data: rawptr, system: ^glove.System) {
	_ = system
	(cast(^int)user_data)^ += 1
}

@(test)
glove_keymap_parses_and_warns :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	save := glove.add_button(&inputs, "save")
	glove.add_button(&inputs, "bogus")

	tmp := os.get_env_alloc("TMPDIR", context.allocator)
	path := strings.concatenate([]string{tmp, "/glove_test_keymap.ini"})
	write_err := os.write_entire_file(path, "[keys]\nsave = gui+s\n# ignored comment\nbogus = q\nsave = notakey\n")
	testing.expect(t, write_err == nil)
	defer os.remove(path)

	loaded := glove.keymap_load(&inputs, path)
	testing.expect(t, loaded)

	event := mock.key_event(.LGUI, true)
	glove.register_event(&inputs, &event)
	event = mock.key_event(.S, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.pressed(&inputs, save))
}

