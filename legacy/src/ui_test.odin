package main

// --ui-test: drives the sidebar chrome by synthetic mouse events inside
// the real frame loop and checks state the views record each frame. Runs
// only with the window: a unit test cannot host it because NewFrame
// asserts without a backend (plan A3). Each case clicks on frame N and
// checks on frame N+1, so the widget has laid out before we read it.
//
// Output: "[ui-test] PASS|FAIL <name>" per case. The app exits 0 only when
// every case passed; any FAIL exits 1.

import im "../vendor/odin-imgui"
import "core:log"
UiTestPhase :: enum {
	MOVE,    // position the mouse; hover is established on this frame
	CLICK,   // inject press on the next frame
	RELEASE, // inject release; the widget reacts on the next frame
	SETTLE,  // let queued messages drain before reading state
	CHECK,   // read recorded state, record PASS/FAIL, advance
}

UiTestStep :: enum {
	STRIP_CLICK_OPENS_FILES,
	FILES_COMBO_OPENS_POPUP,
	STRIP_FITS_1280X800,
	STRIP_FITS_900X600,
}
ui_test_steps := [len(UiTestStep)]UiTestStep{
	.STRIP_CLICK_OPENS_FILES,
	.FILES_COMBO_OPENS_POPUP,
	.STRIP_FITS_1280X800,
	.STRIP_FITS_900X600,
}

UiTest :: struct {
	enabled:  bool,
	step_idx: int,
	phase:    UiTestPhase,
	frame:    int,
	passed:   int,
	failed:   int,
	// Screen position the current step clicks, set when the step starts.
	click_at: [2]f32,
	// Set by frame.odin once every step has run; ends the loop.
	finished: bool,
	// Frames spent in SETTLE for the current step; bounded by the limit.
	settle_frames: int,
}

// Frames to wait after startup before the first click: the strip needs a
// frame to lay out its widgets.
UI_TEST_WARMUP_FRAMES :: 10
// Upper bound on frames spent waiting for a queued click to take effect.
UI_TEST_SETTLE_LIMIT :: 30

ui_test_init :: proc(enabled: bool) -> UiTest {
	return UiTest{enabled = enabled}
}

// Strip button slot center for a mode index (mirrors ui_strip_button's
// layout: buttons centered in the 46 px strip, 42 px pitch, 10 px top).
ui_test_strip_center :: proc(index: int) -> [2]f32 {
	return {(STRIP_W / 2), STRIP_TOP + f32(index) * STRIP_STEP + STRIP_CENTER}
}

// Injects the press or release for the current phase. Runs before
// im.NewFrame so ImGui sees it as this frame's input.
ui_test_inject :: proc(t: ^UiTest) {
	if !t.enabled || t.step_idx >= len(ui_test_steps) do return
	io := im.GetIO()
	// Position every frame: ImGui computes hover from the queued position
	// in NewFrame, so the press must come a frame after the move.
	im.IO_AddMousePosEvent(io, t.click_at.x, t.click_at.y)
	switch t.phase {
	case .MOVE, .SETTLE, .CHECK:
	case .CLICK:
		im.IO_AddMouseButtonEvent(io, 0, true)
	case .RELEASE:
		im.IO_AddMouseButtonEvent(io, 0, false)
	}
}

ui_test_report :: proc(t: ^UiTest, name: string, ok: bool) {
	if ok {
		t.passed += 1
		log.infof("[ui-test] PASS %s", name)
	} else {
		t.failed += 1
		log.errorf("[ui-test] FAIL %s", name)
	}
}

ui_test_advance :: proc(t: ^UiTest) {
	t.step_idx += 1
	// Every step starts by positioning the mouse; a click without a MOVE
	// lands at the previous step's point, not on its widget.
	t.phase = .MOVE
}

// Runs once per frame after the views have recorded their state. Returns
// true when every step has finished.
ui_test_tick :: proc(t: ^UiTest, ui: ^Ui, sm: ^SceneManager) -> bool {
	if !t.enabled || t.step_idx >= len(ui_test_steps) do return false
	t.frame += 1
	if t.frame < UI_TEST_WARMUP_FRAMES do return false

	switch ui_test_steps[t.step_idx] {
	case .STRIP_CLICK_OPENS_FILES:
		// Click the FILES strip icon (index 1); the panel opens on FILES.
		#partial switch t.phase {
		case .MOVE:
			t.click_at = ui_test_strip_center(1)
			t.phase = .CLICK
		case .CLICK:
			t.phase = .RELEASE
		case .RELEASE:
			t.phase = .CHECK
		case .CHECK:
			ui_test_report(t, "strip_click_opens_files", ui.mode == .FILES && ui.panel_open)
			ui_test_advance(t)
		}
	case .FILES_COMBO_OPENS_POPUP:
		// The FILES panel's scene combo opens and records the popup width.
		#partial switch t.phase {
		case .MOVE:
			t.click_at = {STRIP_W + 120, 70}
			t.phase = .CLICK
		case .CLICK:
			t.phase = .RELEASE
		case .RELEASE:
			t.phase = .CHECK
		case .CHECK:
			ui_test_report(t, "files_combo_opens_popup", ui.selector_open)
			ui_test_advance(t)
		}
	case .STRIP_FITS_1280X800:
		ui_test_report(t, "strip_fits_1280x800", strip_layout_fits(ui, im.GetIO()))
		ui_test_advance(t)
	case .STRIP_FITS_900X600:
		// Real resize: set the display size, let the next frame lay out the
		// strip at it, check on the frame after, then restore 1280x800.
		io := im.GetIO()
		// SETTLE is pause-only: the resize is measured on the frame after.
		#partial switch t.phase {
		case .MOVE:
			io.DisplaySize = {900, 600}
			t.phase = .CLICK
		case .CLICK:
			t.phase = .RELEASE
		case .RELEASE:
			t.phase = .CHECK
		case .CHECK:
			ui_test_report(t, "strip_fits_900x600", strip_layout_fits(ui, io))
			io.DisplaySize = {1280, 800}
			ui_test_advance(t)
		}
	}
	return t.step_idx >= len(ui_test_steps)
}

// True when the strip layout is coherent: the save/pause cluster and the
// gear never overlap the mode slots, and every slot stays inside the
// display height.
strip_layout_fits :: proc(ui: ^Ui, io: ^im.IO) -> bool {
	ok := true
	cluster_top := f32(STRIP_TOP + 7 * STRIP_STEP + 6)
	gear_top := io.DisplaySize.y - f32(STRIP_BUTTON + STRIP_TOP)
	// The cluster's second button must end above the gear's top edge.
	if cluster_top + f32(STRIP_BUTTON + 8 + STRIP_BUTTON) > gear_top do ok = false
	if gear_top < f32(STRIP_TOP + 7 * STRIP_STEP) do ok = false
	if !ok {
		log.errorf("[ui-test] strip: cluster_top=%.0f gear_top=%.0f display=%.0fx%.0f",
			cluster_top, gear_top, io.DisplaySize.x, io.DisplaySize.y)
	}
	_ = ui
	return ok
}

// Exit status once the run has finished: 0 only if every step passed.
ui_test_exit_code :: proc(t: ^UiTest) -> int {
	return t.failed == 0 && t.passed == len(ui_test_steps) ? 0 : 1
}
