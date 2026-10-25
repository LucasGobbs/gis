package main

// Validation test for scene_name_valid (scene_templates.odin). Run with
// `odin test src`; the plan's fallback applies if the main package cannot
// host tests (SDL dependency) - then delete this file and rely on the
// manual pass below.

import "core:testing"

@(test)
scene_name_valid_accepts_plain_names :: proc(t: ^testing.T) {
	accepted := [4]string{"meu_shader", "a1", "x-y", "A_b-C9"}
	for name in accepted {
		testing.expectf(t, scene_name_valid(name), "scene_name_valid(%q) = false, want true", name)
	}
}

@(test)
scene_name_valid_rejects_bad_names :: proc(t: ^testing.T) {
	rejected := [5]string{"", "1abc", "a/b", "..", "49_characters_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}
	for name in rejected {
		testing.expectf(t, !scene_name_valid(name), "scene_name_valid(%q) = true, want false", name)
	}
}
