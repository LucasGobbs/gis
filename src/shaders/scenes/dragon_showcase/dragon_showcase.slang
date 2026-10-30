// Stanford dragon showcase: spinning chrome-ish reflections over the
// skybox. The mesh rotates around Y in the shader (iTime-driven spin);
// reflection = skybox sampled along the reflected view ray, blended with
// the diffuse base by a fresnel term. The background pass samples the
// same skybox equirectangular (handled by model_scene_fragment).
//
// Model: GIS_MODEL=stanford_dragon (assets/models). Skybox: GIS_SKYBOX.
// Both fall back to the defaults (sphere, none) when unset — see
// host_main.mm assets wiring.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> skybox_tex;

[[vk::binding(2, 0)]]
SamplerState skybox_sampler;

[[vk::binding(3, 0)]]
Texture2D<float4> base_color_tex;

[[vk::binding(4, 0)]]
SamplerState base_color_sampler;

// Y-axis spin shared by vertex (mesh) and fragment (reflection vector).
float3x3 spin_y(float t) {
    float s = sin(t);
    float c = cos(t);
    return float3x3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c);
}

[shader("vertex")]
ModelVaryings vertMain(ModelVertex input, uint vertexIndex : SV_VertexID) {
    if (Uniforms.iManual < 0.5) {
        // Spin the model around its Y axis; the dragon's origin sits at
        // its base, so lift the pivot to the visual middle first.
        float3x3 R = spin_y(Uniforms.iTime * 0.6);
        input.position = mul(R, input.position - float3(0.0, 9.0, 0.0)) +
                         float3(0.0, 9.0, 0.0);
        input.normal = normalize(mul(R, input.normal));
    }
    return model_scene_vertex(input, vertexIndex, Uniforms);
}

[shader("fragment")]
float4 pixelMain(ModelVaryings input, bool is_front : SV_IsFrontFace) : SV_Target0 {
    if (Uniforms.iManual > 0.5)
        return model_scene_fragment(input, Uniforms, skybox_tex,
                                    skybox_sampler, float3(0.0));

    float3 n = normalize(input.normal);
    if (!is_front) n = -n;
    // Per-fragment view vector from the host camera (iCameraPosition is
    // world-space, mesh spin is applied before model_scene_vertex).
    float3 vdir = normalize(Uniforms.iCameraPosition - input.world);
    // Reflection vector in world space (the mesh spins, the env stays —
    // that sweep of the skybox across the surface IS the effect).
    float3 r = reflect(-vdir, n);
    float2 suv = float2(atan2(r.z, r.x) / 6.2831853 + 0.5,
                        acos(saturate(r.y)) / 3.14159265);
    float3 env = skybox_tex.SampleLevel(skybox_sampler, suv, 0).rgb;

    // Sample base color texture; fallback to bronze if unavailable
    float3 base = float3(0.80, 0.52, 0.22);
    float4 tex_sample = base_color_tex.Sample(base_color_sampler, input.uv);
    if (tex_sample.a > 0.0 || (tex_sample.r + tex_sample.g + tex_sample.b) > 0.0) {
        base = tex_sample.rgb;
    }

    // Chrome-ish shading: env reflection modulated by fresnel, plus a
    // wrapped diffuse base tinted by texture so the silhouette never dies.
    float fresnel = pow(1.0 - saturate(dot(n, vdir)), 3.0);
    float3 L = normalize(float3(0.5, 0.8, -0.6));
    float wrap = 0.5;
    float dif = saturate((dot(n, L) + wrap) / (1.0 + wrap));
    float3 H = normalize(L + vdir);
    float spe = pow(saturate(dot(n, H)), 48.0) * 0.6;

    float3 col = base * (0.35 + 0.85 * dif) +
                 env * lerp(0.35, 0.9, fresnel) +
                 env * spe;
    // Soft filmic-ish curve so highlights roll off instead of clipping.
    col = col / (col + 0.6) * 1.1;
    return model_scene_fragment(input, Uniforms, skybox_tex,
                                skybox_sampler, col);
}
