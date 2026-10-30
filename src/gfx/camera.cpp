// Ported verbatim from legacy/src/camera.odin. Byte-exact math: same
// constants, same column-major layout, same look-at construction. Do not
// "modernize" into a matrix library — shader compatibility depends on the
// exact numbers.
#include "camera.hpp"

#include <cmath>

namespace camera {
namespace {

float dot3(const float* a, const float* b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

void cross3(const float* a, const float* b, float* out) {
    out[0] = a[1] * b[2] - a[2] * b[1];
    out[1] = a[2] * b[0] - a[0] * b[2];
    out[2] = a[0] * b[1] - a[1] * b[0];
}

void normalize3(float* v) {
    const float len = std::sqrt(dot3(v, v));
    v[0] /= len;
    v[1] /= len;
    v[2] /= len;
}

// Column-major mat4 multiply: out = a * b (legacy mat4_mul).
void mat4_mul(const float* a, const float* b, float* out) {
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k)
                sum += a[k * 4 + row] * b[col * 4 + k];
            out[col * 4 + row] = sum;
        }
    }
}

// Legacy camera_create basis + camera_uniforms flattening.
Uniforms make_uniforms(const float pos[3], const float target[3], float aspect) {
    float direction[3] = {target[0] - pos[0], target[1] - pos[1], target[2] - pos[2]};
    normalize3(direction);
    const float world_up[3] = {0.0f, 1.0f, 0.0f};
    float right[3], up[3];
    cross3(direction, world_up, right);
    normalize3(right);
    cross3(right, direction, up);
    normalize3(up);

    const float projection[16] = {
        kFovScale / aspect, 0.0f, 0.0f, 0.0f,
        0.0f, kFovScale, 0.0f, 0.0f,
        0.0f, 0.0f, kFar / (kFar - kNear), 1.0f,
        0.0f, 0.0f, -kNear * kFar / (kFar - kNear), 0.0f,
    };
    // View rows: right, up, forward, then translation. Stored by columns.
    const float view[16] = {
        right[0], up[0], direction[0], 0.0f,
        right[1], up[1], direction[1], 0.0f,
        right[2], up[2], direction[2], 0.0f,
        -dot3(right, pos), -dot3(up, pos), -dot3(direction, pos), 1.0f,
    };

    Uniforms u{};
    mat4_mul(projection, view, u.view_projection);
    for (int i = 0; i < 3; ++i) {
        u.position[i] = pos[i];
        u.right[i] = right[i];
        u.up[i] = up[i];
        u.forward[i] = direction[i];
    }
    return u;
}

} // namespace

Uniforms orbit(float yaw, float pitch, float dist, float aspect) {
    const float cy = std::cos(yaw), sy = std::sin(yaw);
    const float cp = std::cos(pitch), sp = std::sin(pitch);
    const float pos[3] = {dist * cp * sy, dist * sp, dist * cp * cy};
    const float origin[3] = {0.0f, 0.0f, 0.0f};
    return make_uniforms(pos, origin, aspect);
}

Uniforms flycam(const float pos[3], float yaw, float pitch, float aspect) {
    const float cp = std::cos(pitch), sp = std::sin(pitch);
    const float forward[3] = {cp * std::sin(yaw), sp, cp * std::cos(yaw)};
    const float target[3] = {pos[0] + forward[0], pos[1] + forward[1],
                             pos[2] + forward[2]};
    return make_uniforms(pos, target, aspect);
}

} // namespace camera
