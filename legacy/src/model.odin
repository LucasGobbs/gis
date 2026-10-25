package main

import gfx "./gfx"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import gltf "vendor:cgltf"
import sdl "vendor:sdl3"

// Default 3D model for model-viewer scenes. At startup the app loads the
// first .glb/.gltf found in assets/ (cgltf) and interleaves
// POSITION/NORMAL/TEXCOORD_0 into the fixed vertex layout below; without
// a file it falls back to a generated UV sphere, so a default model
// always exists. Graphics scenes whose vertex entry takes a [[stage_in]]
// struct get this model drawn indexed (see scene_runtime.odin); the
// buffers also carry COMPUTE_STORAGE_READ for compute scenes later.

MODEL_PITCH   :: 32 // bytes per vertex: float3 + float3 + float2
MODEL_OFF_POS :: 0
MODEL_OFF_NRM :: 12
MODEL_OFF_UV  :: 24
Model :: struct {
	vb, ib:      ^sdl.GPUBuffer,
	vb_handle, ib_handle: gfx.Buffer_Handle,
	index_count: u32,
	name:        string, // UI label (from filename or "icosphere")
	source:      string, // file path or generator note
}


// Attribute offsets in the fixed model layout, by shader attribute
// location: 0 = position, 1 = normal, 2 = uv.
model_attr_offset :: proc(location: int) -> (u32, bool) {
	switch location {
	case 0:
		return MODEL_OFF_POS, true
	case 1:
		return MODEL_OFF_NRM, true
	case 2:
		return MODEL_OFF_UV, true
	}
	return 0, false
}

// Recenters and rescales interleaved vertices so the model fits the
// unit sphere (max radius 1 from its bounds center). Required for
// real-world meshes like the dragon, which are not unit-sized.
model_normalize_bounds :: proc(vertices: []u8) {
	n := len(vertices) / MODEL_PITCH
	if n == 0 do return
	min_v := [3]f32{1e30, 1e30, 1e30}
	max_v := [3]f32{-1e30, -1e30, -1e30}
	for i in 0 ..< n {
		vertex_pos := ([^]f32)(&vertices[i * MODEL_PITCH])
		for component in 0 ..< 3 {
			min_v[component] = min(min_v[component], vertex_pos[component])
			max_v[component] = max(max_v[component], vertex_pos[component])
		}
	}
	center := [3]f32 {
		(min_v[0] + max_v[0]) / 2,
		(min_v[1] + max_v[1]) / 2,
		(min_v[2] + max_v[2]) / 2,
	}
	max_r: f32 = 1e-30
	for i in 0 ..< n {
		vertex_pos := ([^]f32)(&vertices[i * MODEL_PITCH])
		dx := vertex_pos[0] - center[0]
		dy := vertex_pos[1] - center[1]
		dz := vertex_pos[2] - center[2]
		dist_sq := dx * dx + dy * dy + dz * dz
		max_r = max(max_r, dist_sq)
	}
	scale := 1 / math.sqrt(max_r)
	for i in 0 ..< n {
		vertex_pos := ([^]f32)(&vertices[i * MODEL_PITCH])
		vertex_pos[0] = (vertex_pos[0] - center[0]) * scale
		vertex_pos[1] = (vertex_pos[1] - center[1]) * scale
		vertex_pos[2] = (vertex_pos[2] - center[2]) * scale
	}
}

model_upload :: proc(gfx_state: ^gfx.Gfx, vertices: []u8, indices: []u32, source: string) -> Model {
	model: Model
	model.source = source
	model.index_count = u32(len(indices))

	model.vb_handle = gfx.gfx_buffer_create_from_bytes(
		gfx_state,
		vertices,
		.VERTEX,
	)
	ib_bytes := make([]u8, len(indices) * 4)
	defer delete(ib_bytes)
	for value, byte_index in indices {
		ib_bytes[byte_index*4 + 0] = u8(value)
		ib_bytes[byte_index*4 + 1] = u8(value >> 8)
		ib_bytes[byte_index*4 + 2] = u8(value >> 16)
		ib_bytes[byte_index*4 + 3] = u8(value >> 24)
	}
	model.ib_handle = gfx.gfx_buffer_create_from_bytes(
		gfx_state,
		ib_bytes,
		.INDEX,
	)

	// One copy pass carries both transfers.
	gfx.uploader_begin(&gfx_state.uploader)
	gfx.uploader_upload_buffer(&gfx_state.uploader, model.vb_handle)
	gfx.uploader_upload_buffer(&gfx_state.uploader, model.ib_handle)
	gfx.uploader_flush_blocking(&gfx_state.uploader)

	model.vb = gfx.gfx_buffer_get(gfx_state, model.vb_handle).handle
	model.ib = gfx.gfx_buffer_get(gfx_state, model.ib_handle).handle
	return model
}

// Loads every .glb/.gltf in assets/models plus the generated icosphere
// as a fallback entry, sorted by filename. Names come from the files.
model_load_all :: proc(gfx_state: ^gfx.Gfx) -> [dynamic]Model {
	models: [dynamic]Model
	entries, read_err := os.read_directory_by_path("assets/models", 0, context.temp_allocator)
	if read_err == nil {
		paths: [dynamic]string
		defer delete(paths)
		for entry in entries {
			lower := strings.to_lower(entry.name, context.temp_allocator)
			if strings.has_suffix(lower, ".glb") || strings.has_suffix(lower, ".gltf") {
				append(&paths, strings.clone(entry.fullpath))
			}
		}
		slice.sort(paths[:])
		for path in paths {
			if model, loaded := model_load_gltf(gfx_state, path); loaded {
				base := filepath.base(path)
				dot_index := strings.last_index(base, ".")
				if dot_index > 0 do base = base[:dot_index]
				model.name = strings.clone(base)
				append(&models, model)
				log.infof("model: loaded %s", path)
			}
		}
	}
	if len(models) == 0 {
		log.info("model: no .glb/.gltf in assets/models/, using generated icosphere")
	}
	fallback := model_load_sphere(gfx_state)
	fallback.name = "icosphere"
	append(&models, fallback)
	return models
}

model_load_gltf :: proc(gfx_state: ^gfx.Gfx, path: string) -> (Model, bool) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	options: gltf.options
	data, parse_result := gltf.parse_file(options, path_c)
	if parse_result != .success || data == nil {
		log.errorf("model: failed to parse %s", path)
		return {}, false
	}
	defer gltf.free(data)
	if gltf.load_buffers(options, data, path_c) != .success {
		log.errorf("model: failed to load buffers of %s", path)
		return {}, false
	}

	vertices: [dynamic]u8
	indices: [dynamic]u32
	defer delete(vertices)
	defer delete(indices)

	for mesh in data.meshes {
		for prim in mesh.primitives {
			if prim.type != .triangles do continue
			pos_acc, nrm_acc, uv_acc: ^gltf.accessor
			for attr in prim.attributes {
				#partial switch attr.type {
				case .position:
					pos_acc = attr.data
				case .normal:
					nrm_acc = attr.data
				case .texcoord:
					uv_acc = attr.data
				}
			}
			if pos_acc == nil do continue

			// Unpack each attribute stream once, then interleave.
			count := int(pos_acc.count)
			positions := make([]f32, count * 3, context.temp_allocator)
			_ = gltf.accessor_unpack_floats(pos_acc, raw_data(positions), uint(count * 3))
			normals: []f32
			if nrm_acc != nil {
				normals = make([]f32, count * 3, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(nrm_acc, raw_data(normals), uint(count * 3))
			}
			uvs: []f32
			if uv_acc != nil {
				uvs = make([]f32, count * 2, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(uv_acc, raw_data(uvs), uint(count * 2))
			}

			base := u32(len(vertices) / MODEL_PITCH)
			for i in 0 ..< count {
				vertex_row: [MODEL_PITCH]u8
				put3 :: proc(dest: ^[MODEL_PITCH]u8, offset: int, x, y, z: f32) {
					(^f32)(&dest[offset + 0])^ = x
					(^f32)(&dest[offset + 4])^ = y
					(^f32)(&dest[offset + 8])^ = z
				}
				put3(&vertex_row, MODEL_OFF_POS, positions[i*3], positions[i*3+1], positions[i*3+2])
				if normals != nil {
					put3(&vertex_row, MODEL_OFF_NRM, normals[i*3], normals[i*3+1], normals[i*3+2])
				}
				if uvs != nil {
					(^f32)(&vertex_row[MODEL_OFF_UV + 0])^ = uvs[i*2]
					(^f32)(&vertex_row[MODEL_OFF_UV + 4])^ = uvs[i*2+1]
				}
				append(&vertices, ..vertex_row[:])
			}
			if prim.indices != nil {
				for i in 0 ..< int(prim.indices.count) {
					append(&indices, base + u32(gltf.accessor_read_index(prim.indices, uint(i))))
				}
			} else {
				for i in 0 ..< count {
					append(&indices, base + u32(i))
				}
			}
		}
	}
	if len(indices) == 0 {
		log.errorf("model: %s has no triangles", path)
		return {}, false
	}
	model_normalize_bounds(vertices[:])
	return model_upload(gfx_state, vertices[:], indices[:], path), true
}

// Icosphere fallback: subdivided icosahedron. Uniform triangles, no
// pole singularity and no UV seam: UV spheres show cap seams and sliver
// artifacts under shading; an icosphere avoids the whole class.
model_load_sphere :: proc(gfx_state: ^gfx.Gfx) -> Model {
	SUBDIV :: 4
	PHI :: 1.6180339887498948482
	base_verts := [12][3]f32 {
		{-1, PHI, 0}, {1, PHI, 0}, {-1, -PHI, 0}, {1, -PHI, 0},
		{0, -1, PHI}, {0, 1, PHI}, {0, -1, -PHI}, {0, 1, -PHI},
		{PHI, 0, -1}, {PHI, 0, 1}, {-PHI, 0, -1}, {-PHI, 0, 1},
	}
	faces := [20][3]u32 {
		{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
		{1, 5, 9}, {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
		{3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8}, {3, 8, 9},
		{4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1},
	}

	normalize :: proc(vec: [3]f32) -> [3]f32 {
		length := math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
		return {vec.x / length, vec.y / length, vec.z / length}
	}
	verts: [dynamic][3]f32
	defer delete(verts)
	for vec in base_verts do append(&verts, normalize(vec))

	indices: [dynamic]u32
	defer delete(indices)
	for face in faces do append(&indices, face[0], face[1], face[2])
	when SUBDIV > 0 {
	for level in 1 ..= SUBDIV {
		// Split every triangle at its edge midpoints (normalized back to
		// the unit sphere); winding follows the parent face.
		next_verts: [dynamic][3]f32
		next_indices: [dynamic]u32
		push_v :: proc(list: ^[dynamic][3]f32, vec: [3]f32) -> u32 {
			append(list, vec)
			return u32(len(list) - 1)
		}
		for i := 0; i < len(indices); i += 3 {
			vert_a := verts[indices[i]]
			vert_b := verts[indices[i + 1]]
			vert_c := verts[indices[i + 2]]
			mid_ab := normalize({(vert_a.x + vert_b.x) / 2, (vert_a.y + vert_b.y) / 2, (vert_a.z + vert_b.z) / 2})
			mid_bc := normalize({(vert_b.x + vert_c.x) / 2, (vert_b.y + vert_c.y) / 2, (vert_b.z + vert_c.z) / 2})
			mid_ca := normalize({(vert_c.x + vert_a.x) / 2, (vert_c.y + vert_a.y) / 2, (vert_c.z + vert_a.z) / 2})
			idx_a := push_v(&next_verts, vert_a)
			idx_b := push_v(&next_verts, vert_b)
			idx_c := push_v(&next_verts, vert_c)
			idx_ab := push_v(&next_verts, mid_ab)
			idx_bc := push_v(&next_verts, mid_bc)
			idx_ca := push_v(&next_verts, mid_ca)
			append(&next_indices, idx_a, idx_ab, idx_ca, idx_b, idx_bc, idx_ab, idx_c, idx_ca, idx_bc, idx_ab, idx_bc, idx_ca)
		}
		clear(&verts)
		append(&verts, ..next_verts[:])
		delete(next_verts)
		clear(&indices)
		append(&indices, ..next_indices[:])
		delete(next_indices)
	}
	}

	vertices: [dynamic]u8
	defer delete(vertices)
	write_f :: proc(dest: ^[MODEL_PITCH]u8, offset: int, value: f32) {
		(^f32)(&dest[offset])^ = value
	}
	for sphere_pos in verts {
		u_coord := math.atan2(sphere_pos.z, sphere_pos.x) / (2 * math.PI) + 0.5
		v_coord := math.acos(clamp(sphere_pos.y, -1, 1)) / math.PI
		vertex_row: [MODEL_PITCH]u8
		write_f(&vertex_row, MODEL_OFF_POS + 0, sphere_pos.x)
		write_f(&vertex_row, MODEL_OFF_POS + 4, sphere_pos.y)
		write_f(&vertex_row, MODEL_OFF_POS + 8, sphere_pos.z)
		write_f(&vertex_row, MODEL_OFF_NRM + 0, sphere_pos.x)
		write_f(&vertex_row, MODEL_OFF_NRM + 4, sphere_pos.y)
		write_f(&vertex_row, MODEL_OFF_NRM + 8, sphere_pos.z)
		write_f(&vertex_row, MODEL_OFF_UV + 0, u_coord)
		write_f(&vertex_row, MODEL_OFF_UV + 4, v_coord)
		append(&vertices, ..vertex_row[:])
	}
	return model_upload(gfx_state, vertices[:], indices[:], "generated icosphere")
}
