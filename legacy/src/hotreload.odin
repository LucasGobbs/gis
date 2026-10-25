package main

import goose "../../vendor/goose/src"

// Frees the shader blob when the glue proc OWNS it. Ownership follows the
// generated glue mode — goose sets Code.owns_blob (true only when the proc
// read the artifact from disk at runtime with --hot-reload) — NOT the
// HOT_RELOAD build flag: with `-define:HOT_RELOAD=true` against a baked
// glue, the blob points into static #load data and freeing it aborts in
// malloc ("pointer being freed was not allocated"). Mixed baked/runtime
// generated files (partial regenerations) are handled per blob.
free_blob_if_hot :: proc(glue: goose.GraphicsParameters) {
	if glue.code.owns_blob && glue.code.blob.size > 0 {
		delete(glue.code.blob.data[:glue.code.blob.size])
	}
}
