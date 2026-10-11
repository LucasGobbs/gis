package main

import glove "./glove"
import im "../vendor/odin-imgui"
import im_sdl "../vendor/odin-imgui/backends/sdl3"
import "core:math"
import "core:math/linalg"
import "core:text/i18n"
import sdl "vendor:sdl3"

// The single file that binds input to behavior: named actions, their
// capture masks, and the handlers that run them. No keys here — which
// physical key or button triggers each action lives in
// assets/input.ini, parsed by the glove keymap loader (ini format).

INPUT_KEYMAP_FILE :: "assets/input.ini"

// Shared quit guard: unsaved editor tabs block every quit path (Esc,
// window close, Cmd+Q). First request toasts a warning and is absorbed;
// a second request within the window quits for real. Returns true when
// quitting may proceed.
quit_warn_until: f64 = -1
QUIT_CONFIRM_WINDOW :: 4.0 // seconds between warning and accepted quit

FLYCAM_SPEED :: 1.2 // units/s at base speed; hold_shift multiplies by 4
input_quit_allowed :: proc(ctx: ^Input_Context) -> bool {
	now := f64(sdl.GetPerformanceCounter()) / f64(sdl.GetPerformanceFrequency())
	if ctx.editor != nil && ied_dirty_count(ctx.editor) > 0 {
		if now < quit_warn_until {
			quit_warn_until = -1 // consumed: let this one through
			return true
		}
		quit_warn_until = now + QUIT_CONFIRM_WINDOW
		notify(.WARN, tr("unsaved changes: repeat to quit, or save (Cmd+S)"))
		return false
	}
	return true
}

// App-side input state. Odin has no closures, so handlers receive this
// through their user_data pointer.
Input_Context :: struct {
	ui:        ^Ui,
	editor:    ^ImGuiEditor, // nil in headless
	scene_mgr: ^SceneManager,
	window:    ^sdl.Window,
	quit:      bool, // read by main to break main_loop

	// 3D heightfield orbit
	orbiting:    bool,
	orbit_yaw:   f32,
	orbit_pitch: f32,
	orbit_dist:  f32,
	// Model viewer orbit
	model_orbiting: bool,
	model_yaw:      f32,
	model_pitch:    f32,

	// Shader iMouse
	mouse_pixel: [2]f32, // pixel coords, y up
	mouse_click: bool,

	// Free flycam: toggle with toggle_flycam, WASD to move, drag with
	// primary to look. Session-only state; the orbit camera stays the
	// default.
	flycam_active:  bool,
	fly_pos:        [3]f32,
	fly_yaw:        f32,
	fly_pitch:      f32,
	fly_initialized: bool,

}

imgui_forward_event :: proc(user_data: rawptr, event: ^sdl.Event) {
	_ = user_data
	im_sdl.ProcessEvent(event)
}

input_bindings_init :: proc(inputs: ^glove.System, input_ctx: ^Input_Context) {
	save_all := glove.add_button(inputs, "save_all")
	toggle_sidebar := glove.add_button(inputs, "toggle_sidebar")
	nav_back := glove.add_button(inputs, "nav_back")
	toggle_editor := glove.add_button(inputs, "toggle_editor")
	toggle_glass := glove.add_button(inputs, "toggle_glass")
	toggle_theater := glove.add_button(inputs, "toggle_theater")
	toggle_mobile := glove.add_button(inputs, "toggle_mobile")
	dismiss_or_quit := glove.add_button(inputs, "dismiss_or_quit")
	toggle_zen := glove.add_button(inputs, "toggle_zen")
	toggle_flycam := glove.add_button(inputs, "toggle_flycam")

	graph_grab := glove.add_button(inputs, "graph_grab")
	hold_gui := glove.add_button(inputs, "hold_gui")
	hold_shift := glove.add_button(inputs, "hold_shift")
	primary := glove.add_button(inputs, "primary")

	glove.set_action_respects(inputs, toggle_zen, {.Keyboard})
	glove.set_action_respects(inputs, graph_grab, {.Keyboard})
	// dismiss_or_quit and primary have no action-level mask: their
	// handlers branch on captures themselves (hover-close must work
	// while typing; the title-bar unzoom drag must work over UI).

	// Flycam axes: WASD on a normalized 2D axis; Q/E as plain buttons
	// (glove has no 1D axis). Keys are hard-bound here, not via the ini:
	// they are camera controls, not user-remappable actions.
	fly_move := glove.add_axis_2d(inputs, "fly.move")
	glove.bind_button_axis_2d(inputs, fly_move, {up = .W, down = .S, left = .A, right = .D, normalize = true})
	fly_up_btn := glove.add_button(inputs, "fly.up")
	fly_down_btn := glove.add_button(inputs, "fly.down")
	glove.bind_key(inputs, fly_up_btn, .E)
	glove.bind_key(inputs, fly_down_btn, .Q)

	glove.on_button(inputs, graph_grab, .Pressed, input_handle_graph_grab_pressed, input_ctx)
	glove.on_button(inputs, graph_grab, .Released, input_handle_graph_grab_released, input_ctx)

	glove.on_button(inputs, save_all, .Pressed, input_handle_save_all, input_ctx)
	glove.on_button(inputs, toggle_sidebar, .Pressed, input_handle_toggle_sidebar, input_ctx)
	glove.on_button(inputs, nav_back, .Pressed, input_handle_nav_back, input_ctx)
	glove.on_button(inputs, toggle_editor, .Pressed, input_handle_toggle_editor, input_ctx)
	glove.on_button(inputs, toggle_flycam, .Pressed, input_handle_toggle_flycam, input_ctx)
	glove.on_button(inputs, toggle_glass, .Pressed, input_handle_toggle_glass, input_ctx)
	glove.on_button(inputs, toggle_theater, .Pressed, input_handle_toggle_theater, input_ctx)
	glove.on_button(inputs, toggle_mobile, .Pressed, input_handle_toggle_mobile, input_ctx)
	glove.on_button(inputs, dismiss_or_quit, .Pressed, input_handle_dismiss_or_quit, input_ctx)
	glove.on_button(inputs, toggle_zen, .Pressed, input_handle_toggle_zen, input_ctx)
	glove.on_button(inputs, hold_gui, .Pressed, input_handle_gui_pressed, input_ctx)
	glove.on_button(inputs, hold_gui, .Released, input_handle_gui_released, input_ctx)
	glove.on_button(inputs, hold_shift, .Pressed, input_handle_shift_pressed, input_ctx)
	glove.on_button(inputs, hold_shift, .Released, input_handle_shift_released, input_ctx)
	glove.on_button(inputs, primary, .Pressed, input_handle_primary_pressed, input_ctx)
	glove.on_button(inputs, primary, .Released, input_handle_primary_released, input_ctx)

	glove.on_quit(inputs, input_handle_quit, input_ctx)

	glove.keymap_load(inputs, INPUT_KEYMAP_FILE)
}

// Continuous input read per frame after dispatch: orbit deltas, wheel
// zoom and the shader iMouse uniform. Runs in headless too (it only
// reads glove state).
input_frame :: proc(
	inputs: ^glove.System,
	input_ctx: ^Input_Context,
	pixel_scale: f32,
	pixel_height: i32,
	dt: f32,
) {
	ui := input_ctx.ui

	delta := glove.mouse_delta(inputs)
	if input_ctx.orbiting {
		input_ctx.orbit_yaw += delta.x * 0.012
		input_ctx.orbit_pitch = math.clamp(input_ctx.orbit_pitch + delta.y * 0.012, 0.1, 1.5)
	}
	if input_ctx.model_orbiting {
		input_ctx.model_yaw -= delta.x * 0.012
		input_ctx.model_pitch = math.clamp(input_ctx.model_pitch + delta.y * 0.012, -1.45, 1.45)
	}

	// Wheel zoom (3D view only, not over UI or while inspecting pixels).
	if ui.params.view3d && !ui.pixel_inspect_enabled && !ui.captures_mouse {
		wheel := glove.mouse_wheel(inputs)
		input_ctx.orbit_dist = math.clamp(
			input_ctx.orbit_dist * (1 - wheel.y * 0.1),
			0.8,
			8.0,
		)
	}

	// Mouse in pixel coordinates, y up to match frag_coord; clicks
	// landing on UI widgets do not count as scene clicks.
	pos := glove.mouse_position(inputs)
	input_ctx.mouse_pixel = [2]f32{pos.x * pixel_scale, f32(pixel_height) - pos.y * pixel_scale}
	input_ctx.mouse_click = glove.mouse_down(inputs, .Left) && !ui.captures_mouse && !ui.pixel_inspect_enabled

	if input_ctx.flycam_active {
		primary, ok := glove.action_find(inputs, "primary")
		if ok && glove.down(inputs, primary) && !ui.captures_mouse {
			input_ctx.fly_yaw -= delta.x * 0.006
			input_ctx.fly_pitch = math.clamp(input_ctx.fly_pitch - delta.y * 0.006, -1.5, 1.5)
		}
		cos_pitch := math.cos(input_ctx.fly_pitch)
		forward := [3]f32{
			cos_pitch * math.sin(input_ctx.fly_yaw),
			math.sin(input_ctx.fly_pitch),
			cos_pitch * math.cos(input_ctx.fly_yaw),
		}
		right := linalg.normalize(linalg.cross(forward, Vec3{0, 1, 0}))
		move := [2]f32{}
		if fm, ok := glove.axis_2d_find(inputs, "fly.move"); ok {
			move = glove.axis_2d(inputs, fm)
		}
		up_axis: f32
		if !ui.captures_mouse && !ui.pixel_inspect_enabled {
			fly_up_btn, _ := glove.action_find(inputs, "fly.up")
			fly_down_btn, _ := glove.action_find(inputs, "fly.down")
			hold_shift, _ := glove.action_find(inputs, "hold_shift")
			if glove.down(inputs, fly_up_btn) do up_axis += 1
			if glove.down(inputs, fly_down_btn) do up_axis -= 1
			speed := FLYCAM_SPEED * (glove.down(inputs, hold_shift) ? f32(4.0) : f32(1.0))
			step_dt := math.min(dt, 0.25)
			forward_planar := linalg.normalize(Vec3{forward.x, 0, forward.z})
			dpos :=
				forward_planar * move.y +
				right * move.x +
				Vec3{0, 1, 0} * up_axis
			input_ctx.fly_pos += dpos * (speed * step_dt)
		}
	}
}

// Button handlers ------------------------------------------------------

input_handle_save_all :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	emit(SaveAll{})
}

input_handle_toggle_sidebar :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	emit(ToggleSidebar{})
}

input_handle_toggle_flycam :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = system
	_ = action
	ctx := cast(^Input_Context)user_data
	ctx.flycam_active = !ctx.flycam_active
	// First activation: inherit the orbit camera's spot so the view
	// does not jump — same sphere position and look-at-the-origin
	// convention as camera_orbit (src/camera.odin).
	if ctx.flycam_active && !ctx.fly_initialized {
		DIST :: 2.6
		yaw := ctx.orbit_yaw
		pitch := ctx.orbit_pitch
		cos_yaw, sin_yaw := math.cos(yaw), math.sin(yaw)
		cos_pitch, sin_pitch := math.cos(pitch), math.sin(pitch)
		ctx.fly_pos = [3]f32{DIST*cos_pitch*sin_yaw, DIST*sin_pitch, DIST*cos_pitch*cos_yaw}
		ctx.fly_yaw = yaw
		ctx.fly_pitch = pitch
		ctx.fly_initialized = true
	}
}

input_handle_nav_back :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = system
	_ = action
	ctx := cast(^Input_Context)user_data
	if ctx.editor != nil do ied_nav_back(ctx.editor)
}

input_handle_toggle_editor :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = system
	_ = action
	ctx := cast(^Input_Context)user_data
	// The shader editor is a floating window, separate from the sidebar
	// by design. Reopening re-docks it (drops a user-dragged position).
	ctx.editor.open = !ctx.editor.open
	ctx.editor.moved = false
}

input_handle_toggle_glass :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = system
	_ = action
	ctx := cast(^Input_Context)user_data
	ctx.editor.bg_transparent = !ctx.editor.bg_transparent
	ite_set_glass(ctx.editor.handle, ctx.editor.bg_transparent, ctx.editor.glass_alpha)
}

input_handle_toggle_theater :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	emit(ToggleTheater{})
}

input_handle_toggle_mobile :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	emit(ToggleMobile{})
}

input_handle_dismiss_or_quit :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = action
	ctx := cast(^Input_Context)user_data
	// ESC dismisses the pinned hover docs first; quitting is suppressed
	// while ImGui captures the keyboard (typing in the editor must not
	// close the app) and gated by the shared unsaved-work guard.
	if ctx.editor != nil && ctx.editor.hover_shown {
		ied_hover_close(ctx.editor)
	} else if !glove.captured(system, {.Keyboard}) && input_quit_allowed(ctx) {
		ctx.quit = true
	}
}

input_handle_graph_grab_pressed :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	graph_grab_held = true
}

input_handle_graph_grab_released :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	graph_grab_held = false
}

input_handle_toggle_zen :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = system
	_ = action
	// F1 (was Tab, which the editor needs for indent): toggles the
	// sidebar (the same state Cmd+B flips) AND the floating code editor
	// in step — one key clears the chrome and one key brings it back.
	emit(ToggleSidebar{})
	ctx := cast(^Input_Context)user_data
	if ctx.editor != nil {
		ctx.editor.open = !ctx.editor.open
		ctx.editor.moved = false // re-dock on reopen, like F2 does
	}
}

input_handle_gui_pressed :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	ied_gui_held = true
}

input_handle_gui_released :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	ied_gui_held = false
}

input_handle_shift_pressed :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	ied_shift_held = true
}

input_handle_shift_released :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = user_data
	_ = system
	_ = action
	ied_shift_held = false
}

input_handle_quit :: proc(user_data: rawptr, system: ^glove.System) {
	_ = system
	ctx := cast(^Input_Context)user_data
	if input_quit_allowed(ctx) {
		ctx.quit = true
	}
}
// primary (left mouse button) press: pixel inspect, 3D orbit, model
// orbit. Every scene-facing branch skips captured clicks.
input_handle_primary_pressed :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = action
	ctx := cast(^Input_Context)user_data
	ui := ctx.ui
	pos := glove.mouse_position(system)

	if glove.captured(system, {.Mouse}) do return

	// Pixel inspect: a scene click requests an async 1x1 GPU readback.
	if ui.pixel_inspect_enabled && !ui.pixel_inspect_pending && !ui.captures_mouse {
		ui.pixel_request_pos = pos
		ui.pixel_inspect_request = true
		ui.pixel_inspect_valid = false
		return
	}

	// Orbit camera (3D view only; left-drag rotates, wheel zooms).
	if ui.params.view3d && !ui.pixel_inspect_enabled && !ui.captures_mouse {
		ctx.orbiting = true
		return
	}

	// Model camera: only active in mouse rotation mode.
	if !ui.params.view3d &&
	   !ui.pixel_inspect_enabled &&
	   ui.params.interaction == .MOUSE_ROTATE &&
	   ctx.scene_mgr.scenes[ctx.scene_mgr.current].uses_model &&
	   !ui.captures_mouse {
		ctx.model_orbiting = true
	}
}

input_handle_primary_released :: proc(user_data: rawptr, system: ^glove.System, action: glove.Button_Action) {
	_ = system
	_ = action
	ctx := cast(^Input_Context)user_data
	ctx.orbiting = false
	ctx.model_orbiting = false
}
