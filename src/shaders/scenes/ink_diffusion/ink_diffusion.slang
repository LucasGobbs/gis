// Anicca: the image dissolves in its own matter; impermanence kept
// with care. Buddhism (anicca); Hallnäs & Redström, Slow Design
// (2001). Stateless — each frame recomputes the drop's whole life.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 p = scene_uv(fragCoord, Uniforms.iResolution);

    float t = Uniforms.iTime;

    // Domain warp: the paper drinks unevenly. Drift is scene-scaled
    // (t * 0.05), the environment clock untouched.
    float drift = t * 0.05;
    float2 q = float2(
        fbm(p * 2.0 + 0.3 * drift, 4, 2.0, 0.5),
        fbm(p * 2.0 + 5.2, 4, 2.0, 0.5));
    float2 p2 = p + 0.6 * (q - 0.5) * 2.0;

    // 40 s cycle: a drop falls, spreads, and is absorbed. The cycle
    // index seeds a new drop position; nothing carries over.
    float cycle = floor(t / 40.0);
    float tc = fmod(t, 40.0);
    float2 o = float2(
        hash21(float2(cycle, 1.0)) - 0.5,
        hash21(float2(cycle, 2.0)) - 0.5) * 0.4;

    // Diffusion: sigma grows like sqrt(tc) (true diffusion scaling);
    // peak density falls as the blot thins. At cycle end the drop is
    // gone — the paper is blank again, and it is not a loss.
    float sigma = 0.08 + 0.05 * sqrt(tc);
    float r = length(p2 - o);
    float ink = exp(-r * r / (sigma * sigma));
    ink *= 1.0 - smoothstep(35.0, 40.0, tc);

    float3 paper = float3(0.93, 0.90, 0.84);
    float3 ink_col = float3(0.10, 0.09, 0.08);
    float3 amber = float3(0.91, 0.62, 0.30);

    // Paper grain consumed in the base (binding rule) and under the
    // blot: ink never fully covers the tooth of the sheet.
    float g = paper_tex.SampleLevel(paper_sampler, p * 0.5 + 0.5, 0).r;
    float3 col = lerp(paper, ink_col, saturate(ink) * (1.0 - 0.15 * g));
    col *= 1.0 - 0.04 * g;

    // Amber wet edge only at the diffusion front, where density
    // crosses its half-value: the boundary of the spreading.
    col += amber * smoothstep(0.02, 0.0, abs(ink - 0.5)) * 0.25;

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
