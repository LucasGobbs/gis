package main

// Sidebar: the VS Code-style activity strip (icon column) and its docked
// mode panels (controls, files, graph, export, effects), the settings
// gear popup, the panel grain background, and the resize handle. Split
// out of ui.odin.

import im "../vendor/odin-imgui"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

// Trail page base names for the scene combo's third group: every
// assets/trails/*.md, sorted, extension stripped. Temp-allocated; built
// per frame the combo popup is open. Picking one opens the LEARN panel
// on the trail instead of switching the render scene.
files_trail_names :: proc() -> [dynamic]string {
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

// ---------------------------------------------------------------------------
// Sidebar: a VS Code-style activity strip (narrow icon column) plus a
// docked panel whose content depends on the selected mode. The strip stays
// when the panel is collapsed; SPACE (zen mode) hides both.

STRIP_W :: 46

// Strip glyph geometry: the drawings are authored from these numbers, so
// every icon shares one bounding square and reads optically centered in
// its 34 px slot. The old glyphs were 14-16 px hand-offsets; at 34 px
// slots they floated small and off-center.
STRIP_BUTTON :: 34
STRIP_CENTER :: f32(STRIP_BUTTON / 2)
GLYPH_R      :: f32(10)  // glyph bounding half-extent (20 px art in 34 px slot)
GLYPH_STROKE :: f32(1.7) // stroke weight matching the larger art
STRIP_STEP   :: 42       // vertical slot pitch (button + 8 px gap)
STRIP_TOP    :: 10       // inset from the strip's top edge

// One activity-strip button: 34 px slot with a glyph drawn via the draw
// list (the font has no icon glyphs). The active mode gets the accent
// tint; hover brightens. Returns true when clicked.
ui_strip_button :: proc(ui: ^Ui, mode: SidebarMode, index: int) -> bool {
	draw_list := im.GetWindowDrawList()
	im.SetCursorPos({(STRIP_W - STRIP_BUTTON) / 2, STRIP_TOP + f32(index) * STRIP_STEP})
	pos := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(fmt.ctprintf("##strip%d", index), {STRIP_BUTTON, STRIP_BUTTON})
	hovered := im.IsItemHovered()
	active := ui.mode == mode && ui.panel_open
	cx := pos.x + STRIP_CENTER
	cy := pos.y + STRIP_CENTER
	if hovered {
		// VS Code-style affordance: tooltip naming the panel, hand cursor.
		im.SetTooltip("%s", strings_to_c(tr(SIDEBAR_MODE_NAMES[mode])))
		im.SetMouseCursor(.Hand)
	}
	// The active tint is the strip's animated pill (ui_activity_strip);
	// buttons only draw the hover wash.
	if !active && hovered {
		im.DrawList_AddRectFilled(draw_list, pos, {pos.x + STRIP_BUTTON, pos.y + STRIP_BUTTON}, im.GetColorU32Vec4({1, 1, 1, 0.07}), 8)
	}
	icon_col := im.GetColorU32Vec4(
		active ? ACCENT :
		hovered ? ICON_HOVER : ICON_IDLE,
	)
	R := GLYPH_R // glyph half-extent; all art spans cx±R, cy±R
	switch mode {
	case .CONTROLS:
		// Sliders: three rails with knobs at different offsets.
		knobs := [3]f32{-4, 3, -5}
		for k, i in knobs {
			y := cy - R + 3 + f32(i) * (R - 1)
			im.DrawList_AddLine(draw_list, {cx - R, y}, {cx + R, y}, icon_col, GLYPH_STROKE)
			im.DrawList_AddCircleFilled(draw_list, {cx + k, y}, 2.8, icon_col)
		}
	case .FILES:
		// Folder: body outline with a raised tab on the top edge.
		im.DrawList_AddRect(draw_list, {cx - R, cy - 4}, {cx + R, cy + R}, icon_col, 2.5, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - R, cy - 4}, {cx - R, cy - R + 1}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - R, cy - R + 1}, {cx - 3, cy - R + 1}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - 3, cy - R + 1}, {cx - 1, cy - 4}, icon_col, GLYPH_STROKE)
	case .LEARN:
		// Open book: two page halves around a spine.
		im.DrawList_AddLine(draw_list, {cx, cy - R}, {cx, cy + R}, icon_col, GLYPH_STROKE) // spine
		im.DrawList_AddLine(draw_list, {cx, cy - R}, {cx - R, cy - 4}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - R, cy - 4}, {cx - R, cy + R - 1}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - R, cy + R - 1}, {cx, cy + R}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx, cy - R}, {cx + R, cy - 4}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx + R, cy - 4}, {cx + R, cy + R - 1}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx + R, cy + R - 1}, {cx, cy + R}, icon_col, GLYPH_STROKE)
	case .GRAPH:
		// Graph: two nodes linked by an edge.
		im.DrawList_AddLine(draw_list, {cx - 3, cy - 3}, {cx + 3, cy + 3}, icon_col, GLYPH_STROKE)
		im.DrawList_AddCircle(draw_list, {cx - 6, cy - 6}, 4, icon_col, 0, GLYPH_STROKE)
		im.DrawList_AddCircle(draw_list, {cx + 6, cy + 6}, 4, icon_col, 0, GLYPH_STROKE)
	case .EXPORT:
		// Export: an arrow dropping into a tray.
		im.DrawList_AddLine(draw_list, {cx, cy - R}, {cx, cy}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - 5, cy - 5}, {cx, cy}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx + 5, cy - 5}, {cx, cy}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - R, cy + 3}, {cx - R, cy + R}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx + R, cy + 3}, {cx + R, cy + R}, icon_col, GLYPH_STROKE)
		im.DrawList_AddLine(draw_list, {cx - R, cy + R}, {cx + R, cy + R}, icon_col, GLYPH_STROKE)
	case .EFFECTS:
		// Ink droplet: teardrop.
		im.DrawList_AddCircleFilled(draw_list, {cx, cy + 3}, 5.4, icon_col)
		im.DrawList_AddTriangleFilled(draw_list, {cx - 5, cy + 1}, {cx + 5, cy + 1}, {cx, cy - R}, icon_col)
	case .SHORTCUTS:
		// Keyboard: deck outline with two rows of keycaps.
		im.DrawList_AddRect(draw_list, {cx - R, cy - 7}, {cx + R, cy + 7}, icon_col, 2.5, GLYPH_STROKE)
		for r in 0 ..< 2 {
			for k in 0 ..< 3 {
				kx := cx - 6.5 + f32(k) * 6.5
				ky := cy - 2.6 + f32(r) * 5.2
				im.DrawList_AddRectFilled(draw_list, {kx - 1.9, ky - 1.6}, {kx + 1.9, ky + 1.6}, icon_col, 1)
			}
		}
	}
	return clicked
}

// The icon column. Clicking a different mode selects it; clicking the
// active mode's icon collapses/expands the panel (VS Code behavior).
// Save and pause sit under the modes (the actions the old title bar
// owned); the settings gear pins to the bottom edge.
ui_activity_strip :: proc(ui: ^Ui, ied: ^ImGuiEditor, x_off: f32) {
	imgui_io := im.GetIO()
	im.SetNextWindowPos({x_off, 0}, .Always)
	im.SetNextWindowSize({STRIP_W, imgui_io.DisplaySize.y}, .Always)
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
	im.PushStyleVar(.WindowRounding, 0) // docked chrome is square
	if im.Begin("##activity_strip", nil, flags) {
		draw_list := im.GetWindowDrawList()
		modes := [7]SidebarMode{.CONTROLS, .FILES, .LEARN, .GRAPH, .EXPORT, .EFFECTS, .SHORTCUTS}

		// Animated selection pill: slides to the active mode's slot
		active_idx := 0
		for m, i in modes {
			if m == ui.mode {
				active_idx = i
				break
			}
		}
		anim_step(&ui.pill, f32(STRIP_TOP) + STRIP_CENTER + f32(active_idx * STRIP_STEP), imgui_io.DeltaTime, &ui.fx)
		if ui.panel_open {
			win_pos := im.GetWindowPos()
			pill_y := win_pos.y + ui.pill.value
			im.DrawList_AddRectFilled(draw_list, {win_pos.x + 6, pill_y - STRIP_CENTER}, {win_pos.x + 40, pill_y + STRIP_CENTER}, im.GetColorU32Vec4(ACCENT_SEMITRANSPARENT), 8)
		}

		for m, i in modes {
			if ui_strip_button(ui, m, i) {
				if ui.mode == m {
					emit(TogglePanel{})
				} else {
					emit(SetMode(m))
				}
			}
		}

		// Save + pause cluster, one step under the last mode: the two
		// window actions the old title bar owned. Buttons record hover
		// into Ui fields; the glyphs draw after with the same data.
		cluster_top := STRIP_TOP + f32(len(modes)) * STRIP_STEP + 6
		im.SetCursorPos({(STRIP_W - STRIP_BUTTON) / 2, cluster_top})
		if im.InvisibleButton("##strip_save", {STRIP_BUTTON, STRIP_BUTTON}) {
			emit(SaveAll{})
		}
		ui.save_hover = im.IsItemHovered()
		if ui.save_hover {
			im.SetTooltip("%s", strings_to_c(tr("save all (Cmd+S)")))
			im.SetMouseCursor(.Hand)
		}
		im.SetCursorPos({(STRIP_W - STRIP_BUTTON) / 2, cluster_top + STRIP_BUTTON + 8})
		if im.InvisibleButton("##strip_pause", {STRIP_BUTTON, STRIP_BUTTON}) {
			emit(TogglePause{})
		}
		ui.pause_hover = im.IsItemHovered()
		if ui.pause_hover {
			im.SetTooltip("%s", strings_to_c(ui.params.paused ? tr("play") : tr("pause")))
			im.SetMouseCursor(.Hand)
		}
		ui_strip_save_glyph(draw_list, ui, imgui_io)
		ui_strip_pause_glyph(draw_list, ui)

		// Settings gear pinned to the bottom edge. Glyph: ring + 8 spokes.
		gear_y := imgui_io.DisplaySize.y - STRIP_BUTTON - STRIP_TOP
		im.SetCursorPos({(STRIP_W - STRIP_BUTTON) / 2, gear_y})
		gear_pos := im.GetCursorScreenPos()
		if im.InvisibleButton("##strip_settings", {STRIP_BUTTON, STRIP_BUTTON}) {
			im.OpenPopup("##settings")
		}
		gear_hovered := im.IsItemHovered()
		if gear_hovered {
			im.DrawList_AddRectFilled(draw_list, gear_pos, {gear_pos.x + STRIP_BUTTON, gear_pos.y + STRIP_BUTTON}, im.GetColorU32Vec4({1, 1, 1, 0.07}), 8)
		}
		gear_center := im.Vec2{gear_pos.x + STRIP_CENTER, gear_pos.y + STRIP_CENTER}
		gear_color := im.GetColorU32Vec4(
			gear_hovered ? ICON_HOVER : ICON_IDLE,
		)
		im.DrawList_AddCircle(draw_list, gear_center, 3.8, gear_color, 0, GLYPH_STROKE)
		for i in 0 ..< 8 {
			angle := f32(i) * math.PI / 4
			cos_a, sin_a := math.cos(angle), math.sin(angle)
			im.DrawList_AddLine(draw_list, {gear_center.x + 6.0 * cos_a, gear_center.y + 6.0 * sin_a}, {gear_center.x + 8.8 * cos_a, gear_center.y + 8.8 * sin_a}, gear_color, GLYPH_STROKE)
		}

		// Settings popup: appearance knobs, one place only. Two
		// independent font sizes: the code editor's (pushed around the
		// text component) and the UI's (style FontSizeBase). Captions sit
		// on their own rows: trailing slider labels overflowed the
		// auto-sized popup.
		// Tall enough for every row (language, theme, two fonts, glass,
		// transparency, two pan knobs): anchored to the window bottom
		// (the gear sits there), clamped so short windows keep it fully
		// on screen.
		settings_h := min(f32(480), imgui_io.DisplaySize.y - 12)
		im.SetNextWindowPos({STRIP_W + 6, imgui_io.DisplaySize.y - settings_h}, .Appearing)
		im.SetNextWindowSizeConstraints({0, 0}, {f32(360), settings_h})
		if im.BeginPopup("##settings", {}) {
			im.TextDisabled(trc("language"))
			im.SetNextItemWidth(130)
			if im.BeginCombo("##lang", strings_to_c(LANGUAGE_TAGS[app_language]), {}) {
				for tag, lang_value in LANGUAGE_TAGS {
					if im.Selectable(strings_to_c(tag), lang_value == app_language, {}) {
						i18n_set_language(lang_value)
					}
				}
				im.EndCombo()
			}
			im.TextDisabled(trc("theme"))
			im.SetNextItemWidth(130)
			if im.BeginCombo("##theme", strings_to_c(THEME_NAMES[ied.theme]), {}) {
				for name, theme_value in THEME_NAMES {
					if im.Selectable(strings_to_c(name), theme_value == ied.theme, {}) {
						ied.theme = theme_value
						ied_apply_theme(ied)
						ui_prefs_dirty = true
					}
				}
				im.EndCombo()
			}
			im.TextDisabled(trc("editor font"))
			im.SetNextItemWidth(130)
			if im.SliderFloat("##edfont", &ied.font_size, 10, 28, "%.0f") {
				ui_prefs_dirty = true
			}
			im.TextDisabled(trc("ui font"))
			im.SetNextItemWidth(130)
			if im.SliderFloat("##uifont", &ui.font_size, 12, 22, "%.0f") {
				im.GetStyle().FontSizeBase = ui.font_size
				ui_prefs_dirty = true
			}
			if im.Checkbox(trc("glass"), &ied.bg_transparent) {
				ite_set_glass(ied.handle, ied.bg_transparent, ied.glass_alpha)
				ui_prefs_dirty = true
			}
			im.TextDisabled(trc("transparency"))
			im.SetNextItemWidth(130)
			if im.SliderFloat("##galpha", &ied.glass_alpha, 0.10, 1.00, "%.2f") {
				// Live-reapply when glass is on (the floating window's
				// frame alpha reads glass_alpha every frame).
				if ied.bg_transparent {
					ite_set_glass(ied.handle, true, ied.glass_alpha)
				}
				ui_prefs_dirty = true
			}
			im.TextDisabled(trc("graph pan friction"))
			im.SetNextItemWidth(130)
			im.SliderFloat("##panfric", &sg_pan_friction, 1, 10, "%.1f")
			im.TextDisabled(trc("graph pan max speed"))
			im.SetNextItemWidth(130)
			im.SliderFloat("##panspeed", &sg_pan_max_speed, 1000, 12000, "%.0f")
			im.EndPopup()
		}
		// Flush deferred prefs once per settings-popup close (not per
		// slider tick): one file write per settings session, not 60/s.
		if ui_prefs_dirty && !im.IsPopupOpen("##settings") {
			if ui_prefs_editor != nil {
				ui_prefs_save(ui, ui_prefs_editor)
			}
			ui_prefs_dirty = false
		}
		// 1 px separator between the strip and the panel/scene.
		im.DrawList_AddLine(
			draw_list,
			{STRIP_W - 0.5, 0},
			{STRIP_W - 0.5, imgui_io.DisplaySize.y},
			im.GetColorU32Vec4({1, 1, 1, 0.09}),
		)
	}
	im.End()
	im.PopStyleVar(2)
	im.PopStyleColor(2)
}
// Save glyph (floppy: body outline, metal shutter top-right, label slot
// bottom), drawn from the strip cluster geometry. The save flash (amber
// fade + drawn-in check) plays on top; main sets ui.save_flash = 1 on a
// successful save.
ui_strip_save_glyph :: proc(draw_list: ^im.DrawList, ui: ^Ui, imgui_io: ^im.IO) {
	strip_x := im.GetWindowPos().x
	slot_x := strip_x + (STRIP_W - STRIP_BUTTON) / 2
	slot_y := STRIP_TOP + f32(7) * STRIP_STEP + 6
	size := f32(STRIP_BUTTON)
	save_min := im.Vec2{slot_x, slot_y}
	if ui.save_hover {
		im.DrawList_AddRectFilled(draw_list, save_min, {save_min.x + size, save_min.y + size}, im.GetColorU32Vec4({1, 1, 1, 0.08}), 8)
	}
	save_color := im.GetColorU32(.Text, 1.0)
	im.DrawList_AddRect(draw_list, {save_min.x + 7, save_min.y + 7}, {save_min.x + size - 7, save_min.y + size - 7}, save_color, 2, 1.6)
	im.DrawList_AddRectFilled(draw_list, {save_min.x + size - 14, save_min.y + 9}, {save_min.x + size - 9, save_min.y + 16}, save_color)
	im.DrawList_AddRect(draw_list, {save_min.x + 12, save_min.y + size - 14}, {save_min.x + size - 12, save_min.y + size - 8}, save_color, 1, 1.4)

	if ui.save_flash > 0 {
		ui.save_flash = max(0, ui.save_flash - imgui_io.DeltaTime * 1.4)
		flash := ui.save_flash
		im.DrawList_AddRectFilled(
			draw_list,
			{save_min.x + 7, save_min.y + 7},
			{save_min.x + size - 7, save_min.y + size - 7},
			im.GetColorU32Vec4({ACCENT.x, ACCENT.y, ACCENT.z, 0.45 * flash}),
			2,
		)
		check_progress := min(1, (1 - flash) * 3.3)
		x1, y1 := save_min.x + 13, save_min.y + size * 0.55
		x2, y2 := save_min.x + size * 0.42, save_min.y + size - 13
		x3, y3 := save_min.x + size - 13, save_min.y + 13
		check_color := im.GetColorU32Vec4({1, 1, 1, 0.9})
		first_leg := min(check_progress / 0.35, 1)
		second_leg := min(max(0, (check_progress - 0.35) / 0.65), 1)
		if first_leg > 0 {
			im.DrawList_AddLine(draw_list, {x1, y1}, {x1 + (x2 - x1) * first_leg, y1 + (y2 - y1) * first_leg}, check_color, 1.8)
		}
		if second_leg > 0 {
			im.DrawList_AddLine(draw_list, {x2, y2}, {x2 + (x3 - x2) * second_leg, y2 + (y3 - y2) * second_leg}, check_color, 1.8)
		}
	}
}

// Pause/play glyph: bars while running, triangle while paused (the block
// shows the action the click will take), from the strip cluster geometry.
ui_strip_pause_glyph :: proc(draw_list: ^im.DrawList, ui: ^Ui) {
	strip_x := im.GetWindowPos().x
	slot_x := strip_x + (STRIP_W - STRIP_BUTTON) / 2
	slot_y := STRIP_TOP + f32(7) * STRIP_STEP + 6 + STRIP_BUTTON + 8
	size := f32(STRIP_BUTTON)
	pause_min := im.Vec2{slot_x, slot_y}
	if ui.pause_hover {
		im.DrawList_AddRectFilled(draw_list, pause_min, {pause_min.x + size, pause_min.y + size}, im.GetColorU32Vec4({1, 1, 1, 0.08}), 8)
	}
	icon_color := im.GetColorU32(.Text, 1.0)
	if ui.params.paused {
		triangle_inset := f32(11)
		im.DrawList_AddTriangleFilled(
			draw_list,
			{pause_min.x + triangle_inset, pause_min.y + triangle_inset},
			{pause_min.x + triangle_inset, pause_min.y + size - triangle_inset},
			{pause_min.x + size - triangle_inset + 4, pause_min.y + size / 2},
			icon_color,
		)
	} else {
		bar_width := f32(5)
		im.DrawList_AddRectFilled(draw_list, {pause_min.x + 11, pause_min.y + 10}, {pause_min.x + 11 + bar_width, pause_min.y + size - 10}, icon_color)
		im.DrawList_AddRectFilled(draw_list, {pause_min.x + size - 11 - bar_width, pause_min.y + 10}, {pause_min.x + size - 11, pause_min.y + size - 10}, icon_color)
	}
}

ui_panel_width :: proc(ui: ^Ui, mode: SidebarMode, display_w: f32) -> f32 {
	// The user's dragged width wins once set (VS Code: one sidebar width
	// for every mode), clamped to a sane band.
	if ui.user_w > 0 {
		return clamp(ui.user_w, 220, display_w * 0.85)
	}
	switch mode {
	case .CONTROLS:
		return 300
	case .FILES:
		return 280
	case .LEARN:
		return 340
	case .GRAPH:
		if ui.graph_max do return display_w - STRIP_W
		return display_w * 0.52
	case .EXPORT:
		return 280
	case .EFFECTS:
		return 280
	case .SHORTCUTS:
		return 320
	}
	return 300
}

// CONTROLS mode: the classic controls (view options, export, interaction,
// the active scene's reflected params).
ui_controls_panel :: proc(ui: ^Ui, sm: ^SceneManager) {
	im.TextDisabled(trc("controls"))
	// Time: the running clock, shown live. Type a value (or use the +/-
	// steppers) and commit with Enter to jump the scene to that time.
	im.SetNextItemWidth(140)
	im.InputFloat(trc("time (s)"), ui.time, 0.5, 5.0, "%.2f")
	im.Checkbox(trc("color"), &ui.params.color)
	im.Checkbox(trc("3D view"), &ui.params.view3d)
	im.SameLine()
	im.Checkbox(trc("grid"), &ui.params.grid)
	im.TextUnformatted(fmt.ctprintf(tr("gen %.2f ms"), ui.gen_ms))
	im.TextUnformatted(fmt.ctprintf(tr("fps %.0f · cpu %.1f ms"), ui.fps_ema, ui.cpu_ms_ema))

	if im.CollapsingHeader(trc("debug"), {}) {
		im.TextDisabled(trc("return debug_* from the shader"))
		im.TextColored(DEBUG_NAN, "%s", "NaN")
		im.SameLine()
		im.TextColored(DEBUG_INF, "%s", "+Inf")
		im.SameLine()
		im.TextColored(DEBUG_NEG_INF, "%s", "-Inf")
		im.Checkbox(trc("pixel inspector"), &ui.pixel_inspect_enabled)
		if ui.pixel_inspect_enabled {
			im.TextDisabled(trc("click the scene to sample"))
			if ui.pixel_inspect_pending {
				im.TextDisabled(trc("waiting for GPU..."))
			}
			if ui.pixel_inspect_valid {
				im.TextUnformatted(fmt.ctprintf("pixel  %d, %d", ui.pixel_x, ui.pixel_y))
				im.TextUnformatted(fmt.ctprintf("uv     %.4f, %.4f", ui.pixel_uv[0], ui.pixel_uv[1]))
				im.TextUnformatted(fmt.ctprintf("scene  %.4f, %.4f", ui.pixel_scene_uv[0], ui.pixel_scene_uv[1]))
				im.TextColored(
					{ui.pixel_rgba[0], ui.pixel_rgba[1], ui.pixel_rgba[2], 1},
					"rgba   %.3f, %.3f, %.3f, %.3f",
					ui.pixel_rgba[0],
					ui.pixel_rgba[1],
					ui.pixel_rgba[2],
					ui.pixel_rgba[3],
				)
				if len(sm.scenes) > 0 {
					scene := &sm.scenes[sm.current]
					if scene.pipeline.output_pass >= 0 && scene.pipeline.output_pass < len(scene.passes) {
						im.TextUnformatted(fmt.ctprintf("pass   %s", scene.passes[scene.pipeline.output_pass].name))
					}
				}
			}
			if ui.pixel_inspect_valid && len(sm.scenes) > 0 {
				scene := &sm.scenes[sm.current]
				im.SeparatorText(trc("pixel provenance"))
				if ui.debug_provenance_pending do im.TextDisabled(trc("reading pass outputs..."))
				for pass, i in scene.passes {
					if i >= DEBUG_WATCH_MAX_PASSES || !ui.debug_provenance_path[i] do continue
					if !ui.debug_provenance_valid[i] {
						im.TextDisabled(fmt.ctprintf("%s · pending", pass.name))
						continue
					}
					value := ui.debug_provenance_rgba[i]
					im.TextColored(
						{value[0], value[1], value[2], 1},
						"%s  [%.3f, %.3f, %.3f, %.3f]",
						strings_to_c(pass.name), value[0], value[1], value[2], value[3],
					)
				}
				if scene_has_debug_watches(scene) {
					if im.Button(trc("refresh watches")) {
						ui.debug_watch_request = true
						ui.debug_watch_sampled = false
					}
					if ui.debug_watch_pending {
						im.SameLine()
						im.TextDisabled(trc("reading watches..."))
					}
					if ui.debug_watch_sampled {
						found := false
						for watch, record_index in ui.debug_watches {
							if !watch.valid do continue
							slot := record_index % DEBUG_WATCH_COUNT
							found = true
							label := fmt.tprintf(tr("watch %d"), slot)
							if int(watch.pass) < len(scene.passes) {
								pass := &scene.passes[watch.pass]
								if pass.debug_watch_labels[slot] != "" do label = pass.debug_watch_labels[slot]
								if len(scene.passes) > 1 {
									im.SameLine()
								}
							}
							switch watch.count {
							case 1: im.TextUnformatted(fmt.ctprintf("%s = %.4f", label, watch.value[0]))
							case 2: im.TextUnformatted(fmt.ctprintf("%s = [%.4f, %.4f]", label, watch.value[0], watch.value[1]))
							case 3: im.TextUnformatted(fmt.ctprintf("%s = [%.4f, %.4f, %.4f]", label, watch.value[0], watch.value[1], watch.value[2]))
							case: im.TextUnformatted(fmt.ctprintf("%s = [%.4f, %.4f, %.4f, %.4f]", label, watch.value[0], watch.value[1], watch.value[2], watch.value[3]))
							}
						}
						if !found do im.TextDisabled(trc("no debug_watch values for this pixel"))
					}
				} else {
					im.TextDisabled(trc("add debug_watch_* in the shader"))
					im.SameLine()
					im.TextDisabled("(?)")
					if im.IsItemHovered() && im.BeginTooltip() {
						im.TextUnformatted("fragment:")
						im.TextDisabled("debug_watch_fragment(slot, value,")
						im.TextDisabled("  uint2(input.gl_FragCoord.xy), Uniforms)")
						im.Spacing()
						im.TextUnformatted("compute:")
						im.TextDisabled("debug_watch_compute(slot, value, id.xy, Uniforms)")
						im.Spacing()
						im.TextDisabled("The value expression becomes its label.")
						im.EndTooltip()
					}
				}
			}
		}
	}
	if im.CollapsingHeader(trc("interaction"), {}) {
		if im.RadioButton(trc("autorotate"), ui.params.interaction == .AUTOROTATE) {
			ui.params.interaction = .AUTOROTATE
		}
		if im.RadioButton(trc("mouse rotation"), ui.params.interaction == .MOUSE_ROTATE) {
			ui.params.interaction = .MOUSE_ROTATE
		}
	}

	// The active scene's annotated params, in a visually separate section.
	if len(sm.scenes) > 0 {
		scene := &sm.scenes[sm.current]
		if len(scene.widgets) > 0 {
			im.SeparatorText(fmt.ctprintf(tr("%s params"), scene.title))
			for &w, i in scene.widgets {
				widget_id := fmt.ctprintf("%s##w%d", w.label, i)
				switch w.kind {
				case .SLIDER:
					im.SliderFloat(widget_id, &w.value[0], w.min, w.max, "%.2f")
				case .TOGGLE:
					im.Checkbox(widget_id, &w.on)
				case .COLOR:
					ui_color_param(fmt.ctprintf("%s##w%d", w.label, i), &w.value)
				}
			}
		}
	}
}

// EXPORT mode: frame and animation capture. PNG grabs the current frame
// at the current app_time; the GIF renders [gif_start, gif_end] one
// frame per app frame (progress below) and assembles with ffmpeg on a
// worker thread.
ui_export_panel :: proc(ui: ^Ui) {
	im.TextDisabled(trc("export"))
	if im.Button(trc("export png")) {
		button_min := im.GetItemRectMin()
		button_max := im.GetItemRectMax()
		emit(ExportAction{kind = .PNG, at = {(button_min.x + button_max.x) / 2, (button_min.y + button_max.y) / 2}})
	}
	im.SameLine()
	im.TextUnformatted(fmt.ctprintf(tr("frame at t = %.2f s"), ui.time^))

	im.SeparatorText("gif")
	im.SetNextItemWidth(140)
	im.InputFloat(trc("start (s)"), &ui.gif_start, 0.5, 1.0, "%.2f")
	im.SetNextItemWidth(140)
	im.InputFloat(trc("end (s)"), &ui.gif_end, 0.5, 1.0, "%.2f")
	ui.gif_start = max(ui.gif_start, 0)
	ui.gif_end = max(ui.gif_end, ui.gif_start)
	frames := max(1, int((ui.gif_end - ui.gif_start) * GIF_FPS))
	im.TextUnformatted(fmt.ctprintf(tr("%d frames @ %d fps"), frames, GIF_FPS))
	// Output size is fixed by the ffmpeg filter (scale=480:-1); surface it
	// so the panel doesn't hide what the artifact will be.
	im.TextDisabled(fmt.ctprintf(tr("output: %d px wide"), GIF_OUT_W))
	// Live capture progress + disabled button while a capture runs.
	if gif_capture.active {
		im.ProgressBar(min(1, f32(gif_capture.frame) / f32(max(1, gif_capture.frames))), {-1, 0}, fmt.ctprintf("%d / %d", gif_capture.frame, gif_capture.frames))
	} else if im.Button(trc("export gif")) {
		button_min := im.GetItemRectMin()
		button_max := im.GetItemRectMax()
		emit(ExportAction{kind = .GIF, at = {(button_min.x + button_max.x) / 2, (button_min.y + button_max.y) / 2}})
	}
	if gif_capture.done {
		im.TextDisabled(trc("assembling gif..."))
	}
}

// EFFECTS mode: the FX showroom. Global intensity (off = the static
// fallback), per-effect toggles, and preview triggers.
ui_fx_panel :: proc(ui: ^Ui) {
	fx_settings := &ui.fx
	im.TextDisabled(trc("effects"))

	im.SetNextItemWidth(140)
	if im.BeginCombo("##fx_intensity", trc(FX_INTENSITY_NAMES[fx_settings.intensity]), {}) {
		for name, v in FX_INTENSITY_NAMES {
			if im.Selectable(trc(name), v == fx_settings.intensity, {}) {
				emit(SetFxIntensity(v))
			}
		}
		im.EndCombo()
	}

	// Toggles route through update (app.odin): the checkbox edits a copy,
	// the real field flips only there.
	develop := fx_settings.develop
	if im.Checkbox(trc("develop transition"), &develop) {
		emit(ToggleFx(.DEVELOP))
	}
	springs := fx_settings.springs
	if im.Checkbox(trc("springs"), &springs) {
		emit(ToggleFx(.SPRINGS))
	}
	grain := fx_settings.grain
	if im.Checkbox(trc("paper grain"), &grain) {
		emit(ToggleFx(.GRAIN))
	}

	// Develop style: which transition plays on scene switch.
	im.TextDisabled(trc("develop style"))
	im.SetNextItemWidth(140)
	if im.BeginCombo("##fx_devstyle", trc(FX_DEVELOP_STYLE_NAMES[fx_settings.develop_style]), {}) {
		for name, v in FX_DEVELOP_STYLE_NAMES {
			if im.Selectable(trc(name), v == fx_settings.develop_style, {}) {
				fx_settings.develop_style = v
			}
		}
		im.EndCombo()
	}

	im.Spacing()
	im.SeparatorText(trc("preview"))
	if im.Button(trc("develop")) {
		emit(DevelopPreview{})
	}
}

// FILES mode: the scene combo (was the title-bar selector), the active
// scene's files as a tree (entry shader first, then modules), graph.json
// access, and the shared modules. Picking a scene queues ui.scene_chosen
// (ui_build forwards it through update()); files open in the editor.
ui_files_panel :: proc(ui: ^Ui, sm: ^SceneManager, ed: ^ImGuiEditor) {
	// Keep the list fresh (template-created scenes, external files); the
	// rescan is append-only and cheap.
	ui.files_frame += 1
	if ui.files_frame % 120 == 1 {
		ied_rescan(ed)
	}

	active_title := len(sm.scenes) > 0 ? sm.scenes[sm.current].title : ""
	im.TextDisabled(trc("file explorer"))
	// "+ new" on the caption row (was the title bar's button): creates a
	// scene from a template. Popup logic mirrors the old title-bar one.
	if im.SmallButton("+ new") {
		im.OpenPopup("##scene_new")
		ui.new_scene_open = true
	}
	if im.IsItemHovered() {
		im.SetTooltip("%s", strings_to_c(tr("create scene from template")))
	}
	ui_files_new_scene_popup(ui)

	// Scene picker: plain grouped combo. The old title bar sized its
	// popup explicitly to dodge an ImGui auto-fit ratchet that only
	// bites always-resized windows; a panel combo auto-fits fine.
	if len(sm.scenes) > 0 {
		current_title := sm.scenes[sm.current].title
		ui.selector_open = false
		im.SetNextItemWidth(-1)
		if im.BeginCombo("##scene_sel", strings_to_c(current_title), {.HeightLarge}) {
			ui.selector_open = true
			im.TextDisabled(trc("scenes"))
			for &s, i in sm.scenes {
				root, has_root := scene_roots[s.title]
				if has_root && root == USER_SCENES_DIR do continue
				if im.Selectable(strings_to_c(s.title), i == sm.current, {}) {
					ui.scene_chosen = i
				}
			}
			im.Separator()
			im.TextDisabled(trc("user scenes"))
			for &s, i in sm.scenes {
				root, has_root := scene_roots[s.title]
				if !has_root || root != USER_SCENES_DIR do continue
				if im.Selectable(strings_to_c(s.title), i == sm.current, {}) {
					ui.scene_chosen = i
				}
			}
			// Trail pages: jump to the LEARN panel, not a scene switch.
			trails := files_trail_names()
			if len(trails) > 0 {
				im.Separator()
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
		// Tooltip outside the popup scope: tooltips opened inside it are
		// clipped to the popup window.
		if !ui.selector_open && im.IsItemHovered() {
			im.SetTooltip("%s", strings_to_c(tr("switch scene")))
			im.SetMouseCursor(.Hand)
		}
	}

	if active_title == "" do return
	im.Spacing()

	// Scene unit as a tree: the entry shader (defines the scene) first,
	// then modules sorted as scanned. One draw-list glyph per row (the
	// mono font ships no icons).
	scene_header := fmt.ctprintf("%s##unit", active_title)
	if im.TreeNodeEx(scene_header, {.DefaultOpen, .SpanFullWidth}) {
		ui.files_open_scene = true
		im.Indent()
		// Entry shader row (the scene itself).
		entry_rel := fmt.tprintf("%s/%s", active_title, active_title)
		entry_file := fmt.tprintf("%s%s", ied_unit_prefix(active_title), entry_rel)
		if im.Selectable(fmt.ctprintf("%s##entry", active_title)) {
			ied_load_named(ed, entry_file)
			ed.open = true
		}
		ui_files_row_context(ui, entry_file)
		// Module files (passes).
		prefix := ied_unit_prefix(active_title)
		for file in ed.files {
			if file == entry_file do continue
			if !strings.has_prefix(file, prefix) do continue
			rel := file[len(prefix):]
			if im.Selectable(fmt.ctprintf("%s##f%s", rel, file), false) {
				ied_load_named(ed, file)
				ed.open = true
			}
			ui_files_row_context(ui, file)
		}
		// The scene's node graph: the GRAPH sidebar mode is its editor,
		// so selecting this row navigates there instead of the editor.
		if im.Selectable("graph.json##tree", false) {
			emit(SetMode(.GRAPH))
		}
		if im.IsItemHovered() {
			im.SetTooltip(trc("node graph"))
		}
		im.Unindent()
		im.TreePop()
	} else {
		ui.files_open_scene = false
	}

	// Shared modules: imports available to every scene.
	if im.TreeNodeEx(fmt.ctprintf("%s##shared", tr("shared")), {.DefaultOpen, .SpanFullWidth}) {
		ui.files_open_shared = true
		im.Indent()
		for file in ed.files {
			if strings.has_prefix(file, "scenes/") || strings.has_prefix(file, "gis_scenes/") do continue
			if im.Selectable(fmt.ctprintf("%s##f%s", file, file), false) {
				ied_load_named(ed, file)
				ed.open = true // surface the floating editor on the file
			}
		}
		im.Unindent()
		im.TreePop()
	} else {
		ui.files_open_shared = false
	}
}

// Right-click context on a FILES row: rename (deferred popup: a popup
// opened inside the context popup dies with it).
ui_files_row_context :: proc(ui: ^Ui, file: string) {
	if im.BeginPopupContextItem() {
		if im.Selectable(trc("rename"), false, {}) {
			msg: BeginRenameModule
			msg_set(&msg.scene, "")
			msg_set(&msg.file, file)
			emit(msg)
		}
		im.EndPopup()
	}
}

// New-scene popup (was the title bar's): name + template kind, driven by
// ui.new_scene_open like the rename popups (state opens it, the shown
// edge cancels it).
ui_files_new_scene_popup :: proc(ui: ^Ui) {
	shown := im.BeginPopup("##scene_new")
	if shown {
		im.TextDisabled(trc("scene name"))
		im.SetNextItemWidth(-1)
		entered := im.InputText(
			"##new_name",
			cstring(&ui.new_name_buf[0]),
			len(ui.new_name_buf),
			{.EnterReturnsTrue},
		)
		if im.RadioButton(trc("compute"), ui.new_kind == .COMPUTE) do ui.new_kind = .COMPUTE
		im.SameLine()
		if im.RadioButton(trc("graphics 2d"), ui.new_kind == .GRAPHICS_2D) do ui.new_kind = .GRAPHICS_2D
		im.SameLine()
		if im.RadioButton(trc("graphics 3d"), ui.new_kind == .GRAPHICS_3D) do ui.new_kind = .GRAPHICS_3D
		create_name := strings.trim_space(string(cstring(&ui.new_name_buf[0])))
		name_ok := scene_name_valid(create_name) && !scene_name_taken(create_name)
		if create_name != "" && !scene_name_valid(create_name) {
			im.TextColored(ERROR_RED, "%s", trc("invalid name"))
		} else if create_name != "" && scene_name_taken(create_name) {
			im.TextColored(ERROR_RED, "%s", trc("name already exists"))
		}
		if (entered || im.Button(trc("create"))) && name_ok {
			msg: CreateScene
			msg.kind = ui.new_kind
			msg_set(&msg.name, create_name)
			emit(msg)
		}
		// The popup closes when the created scene becomes the pending
		// selection (success); dismissal clears the typed name below.
		if ui.pending_scene == create_name && create_name != "" {
			for i in 0 ..< len(ui.new_name_buf) do ui.new_name_buf[i] = 0
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
	if !shown && ui.new_scene_open {
		// Dismissed (ESC, outside click): clear the typed name so the
		// next open starts fresh.
		for i in 0 ..< len(ui.new_name_buf) do ui.new_name_buf[i] = 0
		ui.new_scene_open = false
	}
}

// Create mod_N.slang (first free N) in the active scene's directory
// (its real root: src/shaders/scenes for built-ins, gis_scenes for
// user scenes), seed it with a header comment, rescan the editor and
// open the new tab.
files_new_scene_module :: proc(ed: ^ImGuiEditor, scene: string) {
	scene_dir := fmt.tprintf("%s/%s", scene_root_dir(scene), scene)
	base := ""
	for n := 1; ; n += 1 {
		candidate := fmt.tprintf("mod_%d.slang", n)
		if !os.exists(fmt.tprintf("%s/%s", scene_dir, candidate)) {
			base = candidate
			break
		}
	}
	name := base[:len(base) - len(".slang")]
	path := fmt.tprintf("%s/%s", scene_dir, base)
	content := fmt.tprintf("// %s: scene-owned module created from the file explorer.\n", base)
	if write_err := os.write_entire_file(path, transmute([]u8)content); write_err != nil {
		notify(.ERROR, "could not create %s", path)
		return
	}
	ied_rescan(ed)
	ied_load_named(ed, fmt.tprintf("%s/%s/%s", scene_root_dir(scene), scene, name))
	ed.open = true
	notify(.INFO, "created %s", path)
}


// Paper grain behind the panel content: the scanned paper texture, slow
// UV drift, barely-there alpha (fx.grain). Draws into the current window
// (the side panel) before any widgets.
ui_draw_grain :: proc(ui: ^Ui) {
	if !fx_on(&ui.fx) || !ui.fx.grain || fx_grain_binding == nil do return
	draw_list := im.GetWindowDrawList()
	win_pos := im.GetWindowPos()
	win_size := im.GetWindowSize()
	tex_ref := im.TextureRef {
		_TexID = im.TextureID(uintptr(fx_grain_binding)),
	}
	im.ImDrawList_AddImage(
		draw_list,
		tex_ref,
		win_pos,
		{win_pos.x + win_size.x, win_pos.y + win_size.y},
		{f32(im.GetTime()) * 0.002, 0},
		{f32(im.GetTime()) * 0.002 + win_size.x / 1024, win_size.y / 1024},
		im.GetColorU32Vec4({1, 1, 1, 0.05}),
	)
}

// Panel resize handle: an 8px strip just outside the panel's right edge
// (inside the panel the border pixel belongs to the panel and hover never
// reached the handle). Drag sets ui.user_w: one user width for every
// mode (VS Code behavior). Amber seam while hovering/dragging.
ui_panel_edge :: proc(ui: ^Ui, panel_x: f32) {
	imgui_io := im.GetIO()
	im.SetNextWindowPos({panel_x + ui.panel_w.value + 1, 0}, .Always)
	im.SetNextWindowSize({8, imgui_io.DisplaySize.y}, .Always)
	edge_flags := im.WindowFlags {
		.NoTitleBar,
		.NoResize,
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
		.NoBackground,
		.NoScrollbar,
		.NoScrollWithMouse,
	}
	// Zero padding: on an 8px window the default 12px padding pushes the
	// button's hit rect out of the strip entirely.
	im.PushStyleVarVec2(.WindowPadding, {0, 0})
	if im.Begin("##panel_edge", nil, edge_flags) {
		im.InvisibleButton("##edge_btn", {8, imgui_io.DisplaySize.y})
		edge_hovered := im.IsItemHovered()
		edge_active := im.IsItemActive()
		if edge_hovered || edge_active {
			im.SetMouseCursor(.ResizeEW)
		}
		if edge_active {
			ui.user_w = clamp(
				imgui_io.MousePos.x - STRIP_W - ui.sidebar_x.value + 3,
				220,
				imgui_io.DisplaySize.x * 0.85,
			)
			ui_prefs_dragging = true
		} else if ui_prefs_dragging {
			// Release: persist the final dragged width once (not per frame).
			ui_prefs_dragging = false
			if ied := ui_prefs_editor; ied != nil {
				ui_prefs_save(ui, ied)
			}
		}
		if edge_hovered || edge_active {
			draw_list := im.GetWindowDrawList()
			edge_x := panel_x + ui.panel_w.value - 0.5
			im.DrawList_AddLine(
				draw_list,
				{edge_x, 0},
				{edge_x, imgui_io.DisplaySize.y},
				im.GetColorU32Vec4(ACCENT_SOFT),
			)
		}
	}
	im.End()
	im.PopStyleVar()
}

// One shortcuts-table row: the key/chord as an amber chip, then the
// translated description. Keys stay raw (not i18n vocabulary).
ui_key_row :: proc(key, desc: string) {
	im.TextColored(ACCENT, "%s", strings_to_c(key))
	im.SameLine(0, 12)
	im.TextWrapped(strings_to_c(desc))
}

// SHORTCUTS mode: every command the app answers to, grouped by context.
// Mirrors assets/input.ini (window keys) plus editor chords and mouse
// actions; keep the three in sync.
ui_shortcuts_panel :: proc(ui: ^Ui) {
	im.TextDisabled(trc("shortcuts"))

	im.SeparatorText(trc("window"))
	ui_key_row("F1", tr("zen mode: toggle sidebar + editor"))
	ui_key_row("F2", tr("toggle shader editor"))
	ui_key_row("F3", tr("toggle editor glass"))
	ui_key_row("F4", tr("theater mode"))
	ui_key_row("F5", tr("mobile theater (9:16)"))
	ui_key_row("Cmd+B", tr("toggle sidebar"))
	ui_key_row("Esc", tr("close tooltip / quit"))

	im.SeparatorText(trc("editor"))
	ui_key_row("Cmd+S", tr("save all"))
	ui_key_row("Cmd+click", tr("go to definition"))
	ui_key_row("Cmd+Shift+D", tr("duplicate line"))
	ui_key_row("Alt+-", tr("navigate back"))
	ui_key_row("Ctrl+Z/Y", tr("undo / redo"))

	im.SeparatorText(trc("graph"))
	ui_key_row("SPACE (hold)", tr("pan the node graph; release glides"))
	ui_key_row("scroll", tr("zoom around the cursor"))
	ui_key_row("right-click", tr("new node on empty canvas; menu on a node"))

	im.SeparatorText(trc("scene"))
	ui_key_row("click", tr("pixel inspector: click the scene to sample"))
	ui_key_row("hover", tr("hold the mouse on a symbol for docs; wheel to scroll"))
}
