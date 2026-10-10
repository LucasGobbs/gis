// Overdrive FX layer: motion primitives. The safelight amber is the only
// hue, motion is damped ease-out, and intensity .OFF is a clean static
// fallback (no animation, hard scene cuts, as if the layer didn't exist).
package main

import "core:math"
import "core:math/rand"

FxIntensity :: enum {
	FULL,
	SUBTLE,
	OFF,
}

FX_INTENSITY_NAMES := [FxIntensity]string {
	.FULL   = "full",
	.SUBTLE = "subtle",
	.OFF    = "off (static)",
}

FxDevelopStyle :: enum {
	RANDOM,   // every scene switch picks one at random
	DEVELOP,  // photo-develop luminance bath
	DISSOLVE, // ordered-dither pixel dissolve
	IRIS,     // circular iris from the scene selector
}

FX_DEVELOP_STYLE_NAMES := [FxDevelopStyle]string {
	.RANDOM   = "random",
	.DEVELOP  = "develop",
	.DISSOLVE = "dissolve",
	.IRIS     = "iris",
}

Fx :: struct {
	intensity:     FxIntensity,
	develop:       bool, // darkroom "develop" transition on scene switch
	develop_style: FxDevelopStyle,
	springs:       bool, // animated selection pill, fades
	grain:         bool, // paper grain behind panels
}

fx_defaults :: proc() -> Fx {
	return Fx {
		intensity = .FULL,
		develop   = false,
		springs   = true,
		grain     = true,
		develop_style = .RANDOM,
	}
}

fx_on :: proc(fx: ^Fx) -> bool {
	return fx.intensity != .OFF
}

// --- Develop transition ----------------------------------------------------

// Darkroom transition state: t runs 0 → 1 (0 = transition start, 1 = done,
// normal blit). prev_scene seeds on the first frame so the initial load
// doesn't count as a scene change.
Develop :: struct {
	t:          f32,
	prev_scene: int,
}

develop_init :: proc() -> Develop {
	return Develop{t = 1, prev_scene = -1}
}

// Any scene change (whatever the Msg path) restarts the transition when
// the effect is enabled; returns true when the scene changed so the
// caller can do its own per-change bookkeeping.
develop_on_scene_change :: proc(d: ^Develop, fx: ^Fx, scene_index: int) -> bool {
	if d.prev_scene < 0 do d.prev_scene = scene_index
	changed := d.prev_scene != scene_index
	d.prev_scene = scene_index
	if changed && fx_on(fx) && fx.develop {
		d.t = 0
	}
	return changed
}

// Cmd .DEVELOP: restart on demand.
develop_request :: proc(d: ^Develop, fx: ^Fx) {
	if fx_on(fx) && fx.develop {
		d.t = 0
	}
}

// Advances the transition (paused clock or not: it is UI chrome, not
// scene state).
develop_step :: proc(d: ^Develop, delta_time: f32, intensity: FxIntensity) {
	if d.t < 1 {
		duration := f32(1.0) if intensity == .FULL else f32(0.7)
		d.t = min(1, d.t + delta_time / duration)
	}
}

// Fragment variant: RANDOM re-rolls per transition; otherwise the picked
// style (enum starts after RANDOM).
develop_variant :: proc(fx: ^Fx) -> i32 {
	if fx.develop_style == .RANDOM {
		return i32(rand.int_max(3))
	}
	return i32(fx.develop_style) - 1
}

// (Develop previews are DevelopPreview messages routed through update;
// see app.odin.)

// The paper texture (SDL_GPUTexture*), set by main after asset load; the
// panels sample it for the grain background. rawptr here keeps fx.odin
// free of the SDL import.
fx_grain_binding: rawptr

// --- Spring ---------------------------------------------------------------

Anim :: struct {
	value, target: f32,
}

// Damped approach with ease-out feel: fast at FULL, softer at SUBTLE,
// snapping when springs or the whole layer are off.
anim_step :: proc(anim: ^Anim, target: f32, delta_time: f32, effects: ^Fx) {
	anim.target = target
	if !fx_on(effects) || !effects.springs {
		anim.value = target
		return
	}
	rate := f32(14) if effects.intensity == .FULL else f32(8)
	anim.value += (anim.target - anim.value) * (1 - math.exp(-rate * delta_time))
}

