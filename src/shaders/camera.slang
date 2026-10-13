// Camera: rays from the host-supplied basis. Position and orientation
// are computed in Odin (camera.odin) and arrive as SceneUniforms fields;
// no camera movement happens in Slang. Learning trail: raymarching.
// Usage: Camera::ray(Uniforms, uv, focal).

namespace Camera {
    import "../../common";

    public float3 ray(SceneUniforms u, float2 uv, float focal) {
        return normalize(u.iCameraForward * focal + u.iCameraRight * uv.x + u.iCameraUp * uv.y);
    }

    public float3 origin(SceneUniforms u) {
        return u.iCameraPosition;
    }

    public float3 ray_from(float3 ro, float3 fwd, float3 right, float3 up, float2 uv, float focal) {
        return normalize(fwd * focal + right * uv.x + up * uv.y);
    }

}
