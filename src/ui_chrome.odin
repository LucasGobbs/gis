package main

// Toolbar: the in-app bar rendered below the native window frame (the
// OS owns the title bar and its window controls): the scene selector,
// scene creation, save/pause. Split out of ui.odin.

import "core:fmt"
import im "../vendor/odin-imgui"
import "core:os"
import "core:slice"
import sdl "vendor:sdl3"
import "core:strings"

// ---------------------------------------------------------------------------
// Toolbar: scene switching, scene creation from templates, save/pause.
// Emits messages (app.odin) instead of returning them.

// Height of the in-app toolbar row, below the native window frame.
TITLEBAR_H :: 38

// Title bar (see above): scene switching, scene creation from templates,
// window controls. Emits messages (app.odin) instead of returning them.

// Trail page base names for the scene selector's third group: every
// assets/trails/*.md, sorted, extension stripped. Temp-allocated; built
// per frame the combo popup is open. Picking one opens the LEARN panel
// on the trail instead of switching the render scene.
titlebar_trail_names :: proc() -> [dynamic]string {
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	entries, err := os.read_directory_by_path(LEARN_DIR, 0, context.temp_allocator)
	if err != nil do return names
	for entry in entries {
		if entry.type != .Regular do continue
		if !strings.has_suffix(entry.name, ".md") do continue
		append(&names, strings.trim_suffix(entry.name, ".md"))
	}
	slice.sort(names[:])
	return names
}

ui_toolbar :: proc(ui: ^Ui, sm: ^SceneManager, window: ^sdl.Window, ied: ^ImGuiEditor) {

	// A template-created scene appeared in the rescan: select it now.
	// Only clear the pending title once the watcher actually discovered
	// the new scene: the async build takes a few frames, and clearing
	// early loses the selection entirely.
	if ui.pending_scene != "" {
		for &s, i in sm.scenes {
			if s.title == ui.pending_scene {
				emit(SceneSelected(i))
				delete(ui.pending_scene)
				ui.pending_scene = ""
				break
			}
		}
	}

	imgui_io := im.GetIO()
	im.SetNextWindowPos({0, 0}, .Always)
	im.SetNextWindowSize({imgui_io.DisplaySize.x, TITLEBAR_H}, .Always)
	flags := im.WindowFlags {
		.NoTitleBar,
		.NoResize,
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
		.NoScrollbar,
		.NoScrollWithMouse,
		.NoBringToFrontOnFocus,
	}
	im.PushStyleColorVec4(.WindowBg, {0.102, 0.106, 0.125, 1})
	im.PushStyleColorVec4(.Border, {0, 0, 0, 0})
	im.PushStyleVarVec2(.WindowPadding, {0, 0})
	im.PushStyleVarVec2(.FramePadding, {10, 4})
	// Docked chrome is square: rounding belongs to floating
	// surfaces only: rounded corners against flush neighbors clash.
	im.PushStyleVar(.WindowRounding, 0)
	if im.Begin("##titlebar", nil, flags) {
		draw_list := im.GetWindowDrawList()

		frame_y := (TITLEBAR_H - (im.GetFontSize() + 8)) / 2

		// Scene selector: click shows all available scenes.
		im.PushStyleColorVec4(.FrameBg, {1, 1, 1, 0.05})
		im.PushStyleColorVec4(.FrameBgHovered, {1, 1, 1, 0.10})
		im.PushStyleColorVec4(.FrameBgActive, {1, 1, 1, 0.15})
		current_title := len(sm.scenes) > 0 ? sm.scenes[sm.current].title : "?"
		im.SetCursorPos({10, frame_y})
		im.SetNextItemWidth(210)
		if im.BeginCombo("##scene_sel", strings_to_c(current_title), {.HeightLarge}) {
			// Grouped popup: built-in scenes grouped by the learning trail
			// that introduces them (a "(scene:TITLE)" link in its page),
			// then built-ins no trail covers, user scenes, and the trail
			// pages themselves. Groups are computed per open frame
			// (temp-allocated); a group with no members renders no caption.
			trails := titlebar_trail_names()
			trail_texts := make(map[string]string, 8, context.temp_allocator)
			for trail in trails {
				if trail == "index" do continue
				path := fmt.tprintf("%s/%s.md", LEARN_DIR, trail)
				if data, read_err := os.read_entire_file(path, context.temp_allocator); read_err == nil {
					trail_texts[trail] = string(data)
				}
			}
			scene_trail := make(map[string]string, len(sm.scenes), context.temp_allocator)
			for &s, _ in sm.scenes {
				if root, has_root := scene_roots[s.title]; has_root && root == USER_SCENES_DIR {
					continue
				}
				for trail in trails {
					text, ok := trail_texts[trail]
					if !ok do continue
					if strings.contains(text, fmt.tprintf("(scene:%s)", s.title)) {
						scene_trail[s.title] = trail
						break
					}
				}
			}
			// Trail-context groups first, in trail page order.
			grouped := false
			for trail in trails {
				if _, ok := trail_texts[trail]; !ok do continue
				caption_done := false
				for &s, i in sm.scenes {
					if scene_trail[s.title] != trail do continue
					if !caption_done {
						if grouped do im.Separator()
						im.TextDisabled(strings_to_c(trail))
						caption_done = true
						grouped = true
					}
					if im.Selectable(strings_to_c(s.title), i == sm.current, {}) {
						emit(SceneSelected(i))
					}
				}
			}
			// Built-ins no trail introduces, then user scenes.
			builtin_done, user_done := false, false
			for &s, i in sm.scenes {
				if _, in_trail := scene_trail[s.title]; in_trail do continue
				root, has_root := scene_roots[s.title]
				is_user := has_root && root == USER_SCENES_DIR
				if is_user && !user_done {
					if builtin_done || grouped do im.Separator()
					im.TextDisabled(trc("user scenes"))
					user_done = true
				} else if !is_user && !builtin_done {
					if grouped do im.Separator()
					im.TextDisabled(trc("scenes"))
					builtin_done = true
				}
				if im.Selectable(strings_to_c(s.title), i == sm.current, {}) {
					emit(SceneSelected(i))
				}
			}
			if len(trails) > 0 {
				if builtin_done || user_done || grouped do im.Separator()
				im.TextDisabled(trc("trails"))
				for trail in trails {
					if im.Selectable(strings_to_c(trail), false, {}) {
						learn_load(trail)
						emit(SetMode(.LEARN))
					}
				}
			}
			im.EndCombo()
		}
		{
			rect_min := im.GetItemRectMin()
			rect_max := im.GetItemRectMax()
			ui.scene_sel_rect = {rect_min.x, rect_min.y, rect_max.x, rect_max.y}
		}
		im.PopStyleColor(3)

		// Scene templates: create a new scene file from scratch.
		im.SameLine(0, 8)
		im.SetNextItemWidth(92)
		if im.BeginCombo("##new_kind", trc("+ new"), {}) {
			if im.Selectable(trc("compute"), false, {}) {
				if title, ok := scene_create(.COMPUTE); ok {
					ui.pending_scene = title
				}
			}
			if im.Selectable(trc("graphics 2d"), false, {}) {
				if title, ok := scene_create(.GRAPHICS_2D); ok {
					ui.pending_scene = title
				}
			}
			if im.Selectable(trc("graphics 3d"), false, {}) {
				if title, ok := scene_create(.GRAPHICS_3D); ok {
					ui.pending_scene = title
				}
			}
			im.EndCombo()
		}

		// Save-all (floppy) left of pause: same drawn-icon style: the font
		// has no 💾 glyph. Saves every dirty editor tab (ied_save_all).
		size := f32(22)
		save_x := imgui_io.DisplaySize.x - 10 - size - 8 - size
		im.SetCursorPos({save_x, (TITLEBAR_H - size) / 2})
		if im.InvisibleButton("##saveall", {size, size}) {
			emit(SaveAll{})
		}
		save_min := im.GetItemRectMin()
		if im.IsItemHovered() {
			im.DrawList_AddRectFilled(draw_list, save_min, {save_min.x + size, save_min.y + size}, im.GetColorU32Vec4({1, 1, 1, 0.08}), 4)
		}
		save_color := im.GetColorU32(.Text, 1.0)
		// Floppy: body outline, metal shutter top-right, label slot bottom.
		im.DrawList_AddRect(draw_list, {save_min.x + 3, save_min.y + 3}, {save_min.x + size - 3, save_min.y + size - 3}, save_color, 2, 1.4)
		im.DrawList_AddRectFilled(draw_list, {save_min.x + size - 10, save_min.y + 4}, {save_min.x + size - 5, save_min.y + 10}, save_color)
		im.DrawList_AddRect(draw_list, {save_min.x + 7, save_min.y + size - 9}, {save_min.x + size - 7, save_min.y + size - 4}, save_color, 1, 1.2)

		// Save flash: amber fill fading out, with a check that draws
		// itself in during the first third of the fade (main sets
		// ui.save_flash = 1 on a successful save).
		if ui.save_flash > 0 {
			ui.save_flash = max(0, ui.save_flash - imgui_io.DeltaTime * 1.4)
			flash := ui.save_flash
			im.DrawList_AddRectFilled(
				draw_list,
				{save_min.x + 3, save_min.y + 3},
				{save_min.x + size - 3, save_min.y + size - 3},
				im.GetColorU32Vec4({0.91, 0.66, 0.34, 0.45 * flash}),
				2,
			)
			check_progress := min(1, (1 - flash) * 3.3)
			x1, y1 := save_min.x + 6, save_min.y + size * 0.55
			x2, y2 := save_min.x + 9.5, save_min.y + size - 6.5
			x3, y3 := save_min.x + size - 4.5, save_min.y + 5.5
			check_color := im.GetColorU32Vec4({1, 1, 1, 0.9})
			first_leg := min(check_progress / 0.35, 1)
			second_leg := min(max(0, (check_progress - 0.35) / 0.65), 1)
			if first_leg > 0 {
				im.DrawList_AddLine(draw_list, {x1, y1}, {x1 + (x2 - x1) * first_leg, y1 + (y2 - y1) * first_leg}, check_color, 1.6)
			}
			if second_leg > 0 {
				im.DrawList_AddLine(draw_list, {x2, y2}, {x2 + (x3 - x2) * second_leg, y2 + (y3 - y2) * second_leg}, check_color, 1.6)
			}
		}

		// Pause/play on the right edge: drawn icon (the font has no ⏸/▶
		// glyphs), one block showing the action the click will take:
		// bars while running, triangle while paused.
		im.SetCursorPos({imgui_io.DisplaySize.x - 10 - size, (TITLEBAR_H - size) / 2})
		if im.InvisibleButton("##pauseplay", {size, size}) {
			ui.params.paused = !ui.params.paused
		}
		pause_min := im.GetItemRectMin()
		if im.IsItemHovered() {
			im.DrawList_AddRectFilled(draw_list, pause_min, {pause_min.x + size, pause_min.y + size}, im.GetColorU32Vec4({1, 1, 1, 0.08}), 4)
		}
		icon_color := im.GetColorU32(.Text, 1.0)
		if ui.params.paused {
			triangle_inset := f32(5)
			im.DrawList_AddTriangleFilled(
				draw_list,
				{pause_min.x + triangle_inset, pause_min.y + triangle_inset},
				{pause_min.x + triangle_inset, pause_min.y + size - triangle_inset},
				{pause_min.x + size - triangle_inset + 2, pause_min.y + size / 2},
				icon_color,
			)
		} else {
			bar_width := f32(4)
			im.DrawList_AddRectFilled(draw_list, {pause_min.x + 5, pause_min.y + 5}, {pause_min.x + 5 + bar_width, pause_min.y + size - 5}, icon_color)
			im.DrawList_AddRectFilled(draw_list, {pause_min.x + size - 5 - bar_width, pause_min.y + 5}, {pause_min.x + size - 5, pause_min.y + size - 5}, icon_color)
		}

		// 1 px separator between the chrome and the scene below.
		im.DrawList_AddLine(
			draw_list,
			{0, TITLEBAR_H - 0.5},
			{imgui_io.DisplaySize.x, TITLEBAR_H - 0.5},
			im.GetColorU32Vec4({1, 1, 1, 0.09}),
		)
	}
	im.End()
	im.PopStyleVar(3)
	im.PopStyleColor(2)
}
