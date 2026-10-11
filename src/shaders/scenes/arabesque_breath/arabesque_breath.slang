// Dhikr as procedural remembrance: the pattern breathes at 0.1 Hz —
// six cycles per minute. Schimmel, Mystical Dimensions of Islam;
// Bernardi et al. (2001) on recitation rhythms; Grabar as foil.
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
    // The breath of the whole field: scale swells and settles at
    // 0.1 Hz. This is the remembrance tempo, not an ornament.
    float breathe = 0.5 + 0.5 * sin(6.2831853 * 0.1 * t);
    float scale = 1.0 + 0.06 * sin(6.2831853 * 0.1 * t);
    float2 pb = p * scale;

    // Eightfold symmetry: fold the angle into one sector. Inanimate
    // geometry only — the licensed domain permits no living figure.
    float theta = atan2(pb.y, pb.x);
    float sector = 6.2831853 / 8.0;
    float thetaF = abs(fmod(theta, sector) - sector * 0.5);
    float r = length(pb);
    float2 pp = r * float2(cos(thetaF), sin(thetaF));

    // Strapwork: two line families, one rotated 45 degrees, drawn in
    // the plane. The amber thread rides only where the straps cross.
    float d1 = abs(fract(pp.x * 6.0 + breathe * 0.5) - 0.5) / 6.0;
    float c45 = 0.70710678; // cos/sin of 45 deg
    float2 pp2 = float2(pp.x * c45 - pp.y * c45, pp.x * c45 + pp.y * c45);
    float d2 = abs(fract(pp2.x * 6.0 - breathe * 0.5) - 0.5) / 6.0;
    float line = min(d1, d2);

    float3 paper = float3(0.93, 0.90, 0.84);
    float3 ink_col = float3(0.10, 0.09, 0.08);
    float3 amber = float3(0.91, 0.62, 0.30);

    // Paper grain under everything (binding rule): the lattice sits
    // on toothed sheet, not on glass.
    float g = paper_tex.SampleLevel(paper_sampler, p * 0.5 + 0.5, 0).r;
    float3 col = paper * (1.0 - 0.04 * g);

    // Ink lines with soft width, breathing amplitude riding the phase.
    float strap = smoothstep(0.006, 0.002, line);
    col = lerp(col, ink_col, strap);

    // Amber accent only at crossings of the two families.
    col += amber * smoothstep(0.004, 0.0, line) * 0.25 * (0.5 + 0.5 * breathe);

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
