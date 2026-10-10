// graph-node: combine AND
// Combinator created from the node graph: a AND of its two inputs.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> a_tex;

[[vk::binding(2, 0)]]
SamplerState a_sampler;

[[vk::binding(3, 0)]]
Texture2D<float4> b_tex;

[[vk::binding(4, 0)]]
SamplerState b_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) %!(MISSING CLOSE BRACE)    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 %!(MISSING CLOSE BRACE)    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    float4 a = a_tex.Sample(a_sampler, uv);
    float4 b = b_tex.Sample(b_sampler, uv);
    return min(a, b);
}
