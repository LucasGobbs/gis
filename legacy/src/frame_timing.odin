package main

// Frame timing, two independent clocks (do not conflate them):
//   - FPS (`ui.fps_ema`): EMA of the WHOLE loop iteration measured on the
//     CPU — reflects the display cadence vsync locks us to.
//   - Generation time (`ui.gen_ms`): EMA of submit → GPU completion of the
//     scene frame, measured with a GPU fence. Includes queue wait.

import sdl "vendor:sdl3"

import "core:log"

Frame_Timing :: struct {
	start:        u64, // performance counter at loop top
	fps_ema:      f32,
	cpu_ms_ema:   f32,
	initialized:  bool,
}

frame_timing_begin :: proc(t: ^Frame_Timing) {
	t.start = sdl.GetPerformanceCounter()
}

frame_timing_elapsed_ms :: proc(t: ^Frame_Timing) -> f32 {
	return f32(f64(sdl.GetPerformanceCounter() - t.start) / f64(sdl.GetPerformanceFrequency()) * 1000)
}

// End-of-frame telemetry: EMA over the whole iteration.
frame_timing_record :: proc(t: ^Frame_Timing, ui: ^Ui) {
	frame_ms := frame_timing_elapsed_ms(t)
	measured_fps := frame_ms > 0 ? 1000 / frame_ms : 0
	if !t.initialized {
		ui.fps_ema = measured_fps
		ui.cpu_ms_ema = frame_ms
		t.initialized = true
	} else {
		ui.fps_ema = 0.95 * ui.fps_ema + 0.05 * measured_fps
		ui.cpu_ms_ema = 0.95 * ui.cpu_ms_ema + 0.05 * frame_ms
	}
}

Gen_Timer :: struct {
	pending:     ^sdl.GPUFence,
	t0:          u64, // submit-side performance counter
	initialized: bool,
}

// Called right before the scene submit.
gen_timer_begin :: proc(t: ^Gen_Timer) {
	t.t0 = sdl.GetPerformanceCounter()
}

gen_timer_track :: proc(t: ^Gen_Timer, fence: ^sdl.GPUFence) {
	t.pending = fence
}

// Polls the pending fence; on completion samples the generation time into
// the EMA and returns (sample_ms, true). Returns (0, false) otherwise.
gen_timer_poll :: proc(t: ^Gen_Timer, gpu: ^sdl.GPUDevice, ui: ^Ui) -> (f32, bool) {
	if t.pending == nil || !sdl.QueryGPUFence(gpu, t.pending) {
		return 0, false
	}
	complete_ticks := sdl.GetPerformanceCounter()
	sample := f32(f64(complete_ticks - t.t0) / f64(sdl.GetPerformanceFrequency()) * 1000)
	sdl.ReleaseGPUFence(gpu, t.pending)
	t.pending = nil
	if !t.initialized {
		ui.gen_ms = sample
		t.initialized = true
	} else {
		ui.gen_ms = 0.95 * ui.gen_ms + 0.05 * sample
	}
	return sample, true
}

// Scene change: the next sample re-seeds the EMA.
gen_timer_reset :: proc(t: ^Gen_Timer) {
	t.initialized = false
}

// --shot path: block until the pending frame's fence completes so the
// export never races the first-ever submit (black-shot repro in --once).
gen_timer_wait :: proc(t: ^Gen_Timer, gpu: ^sdl.GPUDevice) {
	if t.pending == nil {
		return
	}
	fences := [1]^sdl.GPUFence{t.pending}
	succeeded := sdl.WaitForGPUFences(gpu, true, &fences[0], 1)
	if !succeeded do log.warnf("shot: render fence wait failed: %s", sdl.GetError())
	sdl.ReleaseGPUFence(gpu, t.pending)
	t.pending = nil
}
