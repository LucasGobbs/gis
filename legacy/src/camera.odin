package main

import "core:math"
import "core:math/linalg"

Vec3 :: [3]f32

CameraType :: enum {
	ORBIT,
}

// Camera struct in the cubes/gbbfx style: explicit basis vectors plus a
// cached projection, rebuilt on aspect changes.
Camera :: struct {
	type:       CameraType,
	position:   Vec3,
	direction:  Vec3,
	up, right:  Vec3,
	yaw, pitch: f32,
	projection: matrix[4, 4]f32,
}

camera_create :: proc(
	camera_type: CameraType = .ORBIT,
	position: Vec3 = Vec3{0, 0, 3.0},
	target: Vec3 = Vec3{},
	projection: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) -> Camera {
	world_up := Vec3{0, 1, 0}
	direction := linalg.normalize(target - position)
	camera_yaw := math.atan2(direction.z, direction.x)
	camera_pitch := math.asin(direction.y)
	right := linalg.normalize(linalg.cross(direction, world_up))
	up := linalg.normalize(linalg.cross(right, direction))
	return Camera {
		type       = camera_type,
		position   = position,
		up         = up,
		right      = right,
		direction  = direction,
		yaw        = camera_yaw,
		pitch      = camera_pitch,
		projection = projection,
	}
}

camera_rotate :: proc(camera: ^Camera, yaw_delta, pitch_delta: f32) {
	camera.yaw += yaw_delta
	pitch_limit := linalg.to_radians(f32(89))
	camera.pitch = math.clamp(camera.pitch + pitch_delta, -pitch_limit, pitch_limit)

	cos_pitch := math.cos(camera.pitch)
	camera.direction = linalg.normalize(
		Vec3 {
			math.cos(camera.yaw) * cos_pitch,
			math.sin(camera.pitch),
			math.sin(camera.yaw) * cos_pitch,
		},
	)

	world_up := Vec3{0, 1, 0}
	camera.right = linalg.normalize(linalg.cross(camera.direction, world_up))
	camera.up = linalg.normalize(linalg.cross(camera.right, camera.direction))
}

// Rebuilds the projection with a different aspect ratio (viewport resize).
// Keeps the same fov/near/far as the previous projection.
camera_set_aspect :: proc(camera: ^Camera, aspect: f32) {
	camera.projection = linalg.matrix4_perspective(
		linalg.to_radians(f32(70)),
		aspect,
		0.1,
		1000,
	)
}

camera_view :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
	return linalg.matrix4_look_at_f32(
		camera.position,
		camera.position + camera.direction,
		camera.up,
	)
}

camera_view_projection :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
	return camera.projection * camera_view(camera)
}

// Camera data written into SceneUniforms. Matrices are column-major to
// match `column_major float4x4` in Slang; view-space z is positive forward
// and the projection maps near..far to Metal/D3D NDC z [0,1].
CameraUniforms :: struct {
	view_projection: [16]f32,
	position:        [3]f32,
	right:           [3]f32,
	up:              [3]f32,
	forward:         [3]f32,
}

camera_dot :: proc(a, b: [3]f32) -> f32 {
	return a.x*b.x + a.y*b.y + a.z*b.z
}

camera_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {
		a.y*b.z - a.z*b.y,
		a.z*b.x - a.x*b.z,
		a.x*b.y - a.y*b.x,
	}
}

camera_normalize :: proc(vector: [3]f32) -> [3]f32 {
	length := math.sqrt(camera_dot(vector, vector))
	return vector / length
}

// Column-major matrix multiplication: result = a * b.
mat4_mul :: proc(a, b: [16]f32) -> (out: [16]f32) {
	for column in 0 ..< 4 {
		for row in 0 ..< 4 {
			for k in 0 ..< 4 {
				out[column*4 + row] += a[k*4 + row] * b[column*4 + k]
			}
		}
	}
	return
}

// Flattens a camera into the SceneUniforms layout: flattened column-major
// view_projection plus the basis vectors.
camera_uniforms :: proc(camera: ^Camera, aspect: f32) -> CameraUniforms {
	DIST :: 2.6
	FOV_SCALE :: 1.2 // 1 / tan(fov/2)
	NEAR :: 0.5
	FAR :: 5.0

	projection := [16]f32 {
		FOV_SCALE / aspect, 0, 0, 0,
		0, FOV_SCALE, 0, 0,
		0, 0, FAR / (FAR - NEAR), 1,
		0, 0, -NEAR * FAR / (FAR - NEAR), 0,
	}

	// View rows: right, up, forward, then translation. Stored by columns.
	view := [16]f32 {
		camera.right.x, camera.up.x, camera.direction.x, 0,
		camera.right.y, camera.up.y, camera.direction.y, 0,
		camera.right.z, camera.up.z, camera.direction.z, 0,
		-camera_dot(camera.right, camera.position),
		-camera_dot(camera.up, camera.position),
		-camera_dot(camera.direction, camera.position),
		1,
	}

	return {
		view_projection = mat4_mul(projection, view),
		position        = camera.position,
		right           = camera.right,
		up              = camera.up,
		forward         = camera.direction,
	}
}

// Orbit camera around the origin: a temporary Camera on the sphere of
// radius DIST looking at the origin, flattened by camera_uniforms.
// Byte-exact with the previous hand-rolled version (same DIST/FOV_SCALE/
// NEAR/FAR and the same column-major layout), so shaders are untouched.
camera_orbit :: proc(camera_yaw, camera_pitch, aspect: f32) -> CameraUniforms {
	DIST :: 2.6

	cos_yaw, sin_yaw := math.cos(camera_yaw), math.sin(camera_yaw)
	cos_pitch, sin_pitch := math.cos(camera_pitch), math.sin(camera_pitch)
	position := [3]f32{DIST*cos_pitch*sin_yaw, DIST*sin_pitch, DIST*cos_pitch*cos_yaw}
	camera := camera_create(.ORBIT, position, Vec3{})
	camera.projection = linalg.MATRIX4F32_IDENTITY
	return camera_uniforms(&camera, aspect)
}

// Free flycam: same projection and flattening as the orbit camera, but
// positioned/yaw/pitched by the user (WASD + drag). Looking direction
// follows the yaw/pitch convention of camera_create (atan2(z,x) yaw,
// asin(y) pitch).
camera_flycam :: proc(fly_pos: Vec3, fly_yaw, fly_pitch, aspect: f32) -> CameraUniforms {
	cos_pitch, sin_pitch := math.cos(fly_pitch), math.sin(fly_pitch)
	forward := [3]f32{cos_pitch*math.sin(fly_yaw), sin_pitch, cos_pitch*math.cos(fly_yaw)}
	camera := camera_create(.ORBIT, fly_pos, fly_pos + forward)
	camera.projection = linalg.MATRIX4F32_IDENTITY
	return camera_uniforms(&camera, aspect)
}
