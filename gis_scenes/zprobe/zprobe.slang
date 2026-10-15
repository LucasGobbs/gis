// Host-path probe scene: horizontal gradient straight from fragCoord.
// Not for humans; delete after the cpp host diagnosis.
import "../../src/shaders/common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float3 a = float3(1.0, 0.0, 0.0); // red at left
    float3 b = float3(0.0, 0.0, 1.0); // blue at right
    float u = input.gl_FragCoord.x / Uniforms.iResolution.x;
    return float4(lerp(a, b, u), 1.0);
}
