package main

// Native OS file-open dialog via tinyfiledialogs (vendored C, linked as
// vendor/tinyfiledialogs/libtfd.a). Used by the node graph to pick image
// and model files without an in-app picker. Blocking: called from the UI
// thread on an explicit user action only.

import "core:c"
import "core:strings"

foreign import tfd "../vendor/tinyfiledialogs/libtfd.a"

// Filter pattern list passed verbatim to tinyfd_openFileDialog
// ("*.png;*.jpg"). The count argument takes the pattern count.
@(default_calling_convention = "c")
foreign tfd {
	tinyfd_openFileDialog :: proc(
		title:           cstring,
		default_path:    cstring,
		num_filters:     c.int,
		filter_patterns: [^]cstring,
		filter_desc:     cstring,
		allow_multiple:  c.int,
	) -> cstring ---
}

// Image and model filters the node graph offers.
NATIVE_FILTER_IMAGE :: [2]string{"*.png", "*.jpg;*.jpeg"}
NATIVE_FILTER_MODEL :: [1]string{"*.glb"}

// Opens a native file dialog; returns the chosen path and ok=false when
// the user cancels (or the dialog fails). The returned string is caller-
// owned (heap-allocated with the context allocator).
native_open_file :: proc(title: string, filter_patterns: []string) -> (path: string, ok: bool) {
	title_c := strings.clone_to_cstring(title, context.temp_allocator)
	desc := "Files"
	desc_c := strings.clone_to_cstring(desc, context.temp_allocator)
	patterns_c := make([dynamic]cstring, 0, len(filter_patterns), context.temp_allocator)
	defer delete(patterns_c)
	for pattern in filter_patterns {
		append(&patterns_c, strings.clone_to_cstring(pattern, context.temp_allocator))
	}
	result := tinyfd_openFileDialog(
		title_c,
		nil,
		c.int(len(patterns_c)),
		raw_data(patterns_c),
		desc_c,
		0,
	)
	if result == nil do return "", false
	return strings.clone_from_cstring(result), true
}
