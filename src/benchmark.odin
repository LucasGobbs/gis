package main

// Benchmark harness (--benchmark [frames], --benchmark-debug): CPU and GPU
// samples per frame after a warmup, logged once both buffers fill. CPU
// sample = whole loop iteration; GPU sample = texture generation (submit →
// completion), fed from frame_timing.odin.

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"

BenchmarkStats :: struct {
	mean, stddev, median, q1, q3, p95, p99, min, max: f32,
}

benchmark_stats :: proc(samples: []f32) -> BenchmarkStats {
	result: BenchmarkStats
	if len(samples) == 0 do return result
	sorted := make([]f32, len(samples), context.temp_allocator)
	copy(sorted, samples)
	slice.sort(sorted)
	for value in sorted do result.mean += value
	result.mean /= f32(len(sorted))
	for value in sorted {
		deviation := value - result.mean
		result.stddev += deviation * deviation
	}
	result.stddev = math.sqrt(result.stddev / f32(len(sorted)))
	percentile :: proc(values: []f32, fraction: f32) -> f32 {
		index := int(math.round(fraction * f32(len(values) - 1)))
		return values[clamp(index, 0, len(values) - 1)]
	}
	result.min = sorted[0]
	result.max = sorted[len(sorted) - 1]
	result.q1 = percentile(sorted, 0.25)
	result.median = percentile(sorted, 0.50)
	result.q3 = percentile(sorted, 0.75)
	result.p95 = percentile(sorted, 0.95)
	result.p99 = percentile(sorted, 0.99)
	return result
}

benchmark_log :: proc(label: string, samples: []f32) {
	stats := benchmark_stats(samples)
	log.infof(
		"[benchmark] %s n=%d mean=%.4fms std=%.4f median=%.4f q1=%.4f q3=%.4f p95=%.4f p99=%.4f min=%.4f max=%.4f",
		label, len(samples), stats.mean, stats.stddev, stats.median, stats.q1, stats.q3, stats.p95, stats.p99, stats.min, stats.max,
	)
}

Benchmark :: struct {
	frames: int, // 0 = off
	warmup: int,
	debug:  bool,
	frame:  int,
	cpu:    [dynamic]f32,
	gpu:    [dynamic]f32,
}

benchmark_init :: proc(o: Options) -> Benchmark {
	return Benchmark{
		frames = o.benchmark_frames,
		warmup = o.benchmark_warmup,
		debug  = o.benchmark_debug,
	}
}

benchmark_active :: proc(b: ^Benchmark) -> bool {
	return b.frames > 0
}

// Same gate for CPU and GPU samples, matching today's condition.
benchmark_wants_sample :: proc(b: ^Benchmark) -> bool {
	return b.frame >= b.warmup && len(b.cpu) < b.frames
}

// Appends the CPU sample when wanted, bumps the frame counter, and logs +
// returns true once both buffers are full (caller breaks the loop).
benchmark_end_frame :: proc(b: ^Benchmark, cpu_ms: f32, scene_title: string) -> bool {
	if benchmark_wants_sample(b) {
		append(&b.cpu, cpu_ms)
	}
	b.frame += 1
	if len(b.cpu) >= b.frames && len(b.gpu) >= b.frames {
		mode := b.debug ? "debug" : "baseline"
		benchmark_log(fmt.tprintf("cpu mode=%s scene=%s", mode, scene_title), b.cpu[:])
		benchmark_log(fmt.tprintf("gpu mode=%s scene=%s", mode, scene_title), b.gpu[:])
		return true
	}
	return false
}
