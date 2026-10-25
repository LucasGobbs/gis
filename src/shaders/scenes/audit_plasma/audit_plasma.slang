// AUDIT SCENE: plasma to exercise the port hot-reload + widgets path.
// Minimal deps: common only, one slider widget, time-driven plasma.
import "../../common";

public struct PlasmaParams {
    [UiSlider(0.5, 8.0, 0.1, 2.0)]
    public float warp;
};

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
ConstantBuffer<PlasmaParams> Params;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    float t = Uniforms.iTime;
    float2 p = uv * 6.28318 * Params.warp;
    float v = sin(p.x + t)
            + sin(p.y + t * 1.3)
            + sin(p.x + p.y + t * 0.7)
            + sin(length(uv - 0.5) * 12.0 - t * 2.0);
    v = v * 0.25;
    float3 col = float3(0.95, 0.4, 0.1) * (0.55 + 0.45 * cos(v * 3.0 + float3(0.0, 2.1, 4.2) + t * 0.4));
    // vignette to check bottom-up vs top-down coord assumptions
    float d = length(uv - 0.5);
    col *= 1.0 - d * d;
    return float4(col, 1.0);
}
