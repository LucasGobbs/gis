// Camera math + uniform fill regression tests (no GPU, no Qt).
// Verifies the legacy port contract: column-major VP, Metal z [0,1],
// aspect in column 0, flycam-inherits-orbit, and the byte layout that
// scene_write_uniforms pokes into pass cbuffers.
#include "gfx/camera.hpp"
#include "gfx/scene_runtime.hpp"
#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include <cmath>
#include <cstring>

using camera::Uniforms;

namespace {

float dot3(const float* a, const float* b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

// Apply column-major VP to (p, 1):
// clip[row] = sum_col VP[col*4 + row] * p[col], with p[3] = 1.
void apply_vp(const float* vp, const float p[3], float out[4]) {
    for (int row = 0; row < 4; ++row) {
        float sum = 0.0f;
        for (int col = 0; col < 3; ++col)
            sum += vp[col * 4 + row] * p[col];
        sum += vp[3 * 4 + row]; // w row times 1
        out[row] = sum;
    }
}

} // namespace

TEST_CASE("orbit: projection scales x by aspect, preserves vertical FOV",
          "[camera]") {
    // yaw = 0 puts right on +x, so column 0 row 0 is exactly the raw
    // projection entry FOV_SCALE / aspect.
    const float aspect = 16.0f / 9.0f;
    const Uniforms u = camera::orbit(0.0f, camera::kDefaultPitch, camera::kDist, aspect);
    REQUIRE(u.view_projection[0] ==
            Catch::Approx(camera::kFovScale / aspect).margin(1e-6));
    // Vertical scale row is untouched by aspect (FOV_SCALE * up.y).
    REQUIRE(u.view_projection[5] ==
            Catch::Approx(camera::kFovScale * u.up[1]).margin(1e-6));
}

TEST_CASE("orbit: position on sphere, basis orthonormal, looks at origin",
          "[camera]") {
    const Uniforms u = camera::orbit(0.7f, 0.3f, camera::kDist, 1.0f);
    const float len =
        std::sqrt(dot3(u.position, u.position));
    REQUIRE(len == Catch::Approx(camera::kDist).margin(1e-5));
    REQUIRE(dot3(u.right, u.up) == Catch::Approx(0.0f).margin(1e-6));
    REQUIRE(dot3(u.right, u.forward) == Catch::Approx(0.0f).margin(1e-6));
    REQUIRE(dot3(u.up, u.forward) == Catch::Approx(0.0f).margin(1e-6));
    for (int i = 0; i < 3; ++i) {
        REQUIRE(std::fabs(std::sqrt(dot3(u.right, u.right)) - 1.0f) < 1e-6);
        // forward points from position toward origin
        REQUIRE(u.forward[i] == Catch::Approx(-u.position[i] / camera::kDist).margin(1e-6));
    }
}

TEST_CASE("orbit: NDC z of near/far planes maps to 0/1 (Metal)", "[camera]") {
    const Uniforms u = camera::orbit(0.0f, 0.55f, camera::kDist, 1.0f);
    // Points on the view axis d units IN FRONT of the eye (forward points
    // at the origin): legacy z->[0,1] projection gives
    // NDC z = (d - n) * f / ((f - n) * d).
    auto ndc_z_at = [&](float d) {
        const float p[3] = {u.position[0] + d * u.forward[0],
                            u.position[1] + d * u.forward[1],
                            u.position[2] + d * u.forward[2]};
        float clip[4];
        apply_vp(u.view_projection, p, clip);
        return clip[2] / clip[3];
    };
    REQUIRE(ndc_z_at(camera::kNear) == Catch::Approx(0.0f).margin(1e-5));
    REQUIRE(ndc_z_at(camera::kFar) == Catch::Approx(1.0f).margin(1e-5));
    // Mid-range stays inside [0,1] — the identity-VP bug clipped z<0.
    const float mid = ndc_z_at((camera::kNear + camera::kFar) * 0.5f);
    REQUIRE(mid > 0.0f);
    REQUIRE(mid < 1.0f);
    // The origin itself (dragon center) is inside the frustum.
    const float origin[3] = {0, 0, 0};
    float clip[4];
    apply_vp(u.view_projection, origin, clip);
    const float origin_z = clip[2] / clip[3];
    REQUIRE(origin_z > 0.0f);
    REQUIRE(origin_z < 1.0f);
}

TEST_CASE("flycam with orbit spot reproduces orbit frame", "[camera]") {
    // Legacy contract (input_bindings.odin toggle_flycam): activation
    // copies the orbit spot — fly_pos = orbit position for the same
    // yaw/pitch, fly_yaw/fly_pitch = orbit yaw/pitch. camera_flycam's
    // forward convention (cp*sin, sp, cp*cos) differs from the orbit's
    // look-at-the-origin direction (cp*sin(yaw+pi), -sp, cp*cos(yaw+pi)),
    // so the first fly frame looks outward from the sphere position —
    // that asymmetry is IN the legacy source; position, projection scale
    // and basis orthonormality are what must match.
    const float yaw = 1.1f, pitch = -0.2f;
    const Uniforms orb = camera::orbit(yaw, pitch, camera::kDist, 1.5f);
    const float spot[3] = {orb.position[0], orb.position[1], orb.position[2]};
    const Uniforms fly = camera::flycam(spot, yaw, pitch, 1.5f);
    for (int i = 0; i < 3; ++i)
        REQUIRE(fly.position[i] == Catch::Approx(orb.position[i]).margin(1e-6));
    // Projection scale rows (aspect + vertical FOV) identical up to the
    // right-vector sign flip documented above.
    const float vp_scale = fly.view_projection[0] / orb.view_projection[0];
    REQUIRE(std::fabs(vp_scale) == Catch::Approx(1.0f).margin(1e-6));
    REQUIRE(fly.view_projection[5] ==
            Catch::Approx(orb.view_projection[5]).margin(1e-6));
    // Fly basis orthonormal.
    REQUIRE(dot3(fly.right, fly.up) == Catch::Approx(0.0f).margin(1e-6));
    REQUIRE(dot3(fly.forward, fly.forward) == Catch::Approx(1.0f).margin(1e-6));
}

TEST_CASE("scene_write_uniforms fills camera fields by reflection offsets",
          "[camera][uniforms]") {
    // Hand-build a scene with one pass / one cbuffer carrying the camera
    // fields at known offsets, then check the poked bytes.
    scene::Runtime_Scene sc;
    scene::Scene_Pass pass;
    pass.name = "main";
    scene::CBuffer cb;
    cb.block.assign(256, 0);
    cb.fields.push_back(scene::Uniform_Field{"iViewProjection", 0});
    cb.fields.push_back(scene::Uniform_Field{"iCameraPosition", 64});
    cb.fields.push_back(scene::Uniform_Field{"iCameraForward", 80});
    pass.cbuffers.push_back(std::move(cb));
    sc.passes.push_back(std::move(pass));

    const Uniforms u = camera::orbit(0.4f, 0.55f, camera::kDist, 1.3f);
    scene::scene_write_uniforms(sc, 640.f, 480.f, 1.0f, false, 0.f, 0.f, false, u);

    const auto& filled = sc.passes[0].cbuffers[0];
    REQUIRE(filled.block.size() == 256);
    REQUIRE(std::memcmp(filled.block.data(), u.view_projection, 64) == 0);
    REQUIRE(std::memcmp(filled.block.data() + 64, u.position, 12) == 0);
    REQUIRE(std::memcmp(filled.block.data() + 80, u.forward, 12) == 0);
}
