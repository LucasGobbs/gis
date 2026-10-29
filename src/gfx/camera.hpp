// Camera math, ported verbatim from legacy/src/camera.odin (camera_uniforms
// / camera_orbit / camera_flycam). Byte-exact with the Odin implementation
// so the Slang shaders (column_major float4x4, Metal NDC z in [0,1]) are
// untouched.
//
// Contract:
//   - All matrices are COLUMN-MAJOR (column*4 + row indexing), matching
//     `column_major float4x4` in SceneUniforms (src/shaders/common.slang).
//   - View is right-handed look-at with forward = direction of look
//     (view-space z is positive forward).
//   - Projection maps near..far to NDC z [0,1] (Metal/D3D convention), not
//     OpenGL [-1,1]. An identity VP therefore clips everything with NDC
//     z < 0 — the historic "dragon see-through" bug.
//   - Vertical FOV is preserved across aspect changes (FOV_SCALE scales
//     column 0 by 1/aspect); aspect = render-target width / height.
#pragma once

namespace camera {

// Legacy constants (camera.odin camera_uniforms / frame.odin autorotate).
inline constexpr float kDist = 2.6f;             // orbit sphere radius
inline constexpr float kFovScale = 1.2f;         // 1 / tan(fov/2)
inline constexpr float kNear = 0.5f;
inline constexpr float kFar = 50.0f;
inline constexpr float kAutorotateYawRate = 0.4f; // rad/s (frame.odin)
inline constexpr float kDefaultPitch = 0.55f;     // rad (frame.odin AUTOROTATE)

// Same memory layout as legacy CameraUniforms.
struct Uniforms {
    float view_projection[16];
    float position[3];
    float right[3];
    float up[3];
    float forward[3];
};

// Orbit camera on the sphere of radius dist (wheel zoom; kDist default)
// looking at the origin.
Uniforms orbit(float yaw, float pitch, float dist, float aspect);

// Free flycam: forward from (yaw, pitch) — atan2(z, x) yaw, asin(y) pitch
// convention — positioned at pos. With pos/yaw/pitch taken from the orbit
// sphere position for the same yaw/pitch, it reproduces the orbit frame
// (legacy input_bindings.odin flycam-inherits-orbit contract).
Uniforms flycam(const float pos[3], float yaw, float pitch, float aspect);

} // namespace camera
