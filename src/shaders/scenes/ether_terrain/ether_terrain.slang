// The mathematical sublime: a range whose scale imagination cannot
// embrace and reason knows continues. Kant, Critique of Judgment
// (1790), the dynamically sublime of magnitude; Burke, Enquiry.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

// Heightfield: the ridge is fbm itself — no authored peaks, only
// accumulated noise, so the range visibly continues past every edge.
float terrain_height(float2 xz) {
    return 1.2 * fbm(xz * 0.15, 4, 2.0, 0.5);
}

float map(float3 p) {
    return p.y - terrain_height(p.xz);
}

float3 calc_normal(float3 p) {
    float e = 0.003;
    return normalize(float3(
        map(p + float3(e, 0, 0)) - map(p - float3(e, 0, 0)),
        map(p + float3(0, e, 0)) - map(p - float3(0, e, 0)),
        map(p + float3(0, 0, e)) - map(p - float3(0, 0, e))));
}

// Slow march with relaxed step (the relaxed factor follows the guide
// rule t += d * 0.7; 96 steps, break past 90).
float raymarch(float3 ro, float3 rd) {
    float t = 0.0;
    for (int i = 0; i < 64; i++) {
        float d = map(ro + rd * t);
        if (d < 0.001 * max(t, 1.0)) return t;
        t += d * 0.7;
        if (t > 90.0) break;
    }
    return -1.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 uv = scene_uv(fragCoord, Uniforms.iResolution);

    float t = Uniforms.iTime;
    // 0.1 Hz breath: 6 cycles per minute, the dhikr tempo.
    float breathe = 0.5 + 0.5 * sin(6.2831853 * 0.1 * t);

    // Slow traverse: ~25 s per terrain unit capped at 30 units, so the
    // range never ends inside a session. Derivative drift (0.2 amplitude)
    // stays a fraction of the breath, not a second metronome.
    float travel = min(t * 0.04, 30.0);
    float3 ro = float3(0.0, 2.2 + 0.2 * sin(0.07 * t), -travel);
    float3 look = ro + float3(0.0, -0.4, 6.0);
    float3 fwd = normalize(look - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.5 + right * uv.x + up * uv.y);

    float3 paper = float3(0.93, 0.90, 0.84);
    float3 ink = float3(0.10, 0.09, 0.08);
    float3 amber = float3(0.91, 0.62, 0.30);

    // Grazing raking light from the left-front; physically a single
    // directional source, no divergent rays, no bloom.
    float3 L = normalize(float3(-0.5, 0.35, 0.8));

    float hit = raymarch(ro, rd);
    float3 col;
    if (hit < 0.0) {
        // Sky: paper-to-haze gradient only. No disc, no ray, no halo
        // object — light is where the gradient leans, not a thing drawn.
        float haze = exp(-abs(rd.y) * 3.0);
        col = lerp(float3(0.88, 0.85, 0.80), paper, saturate(rd.y * 2.0 + 0.5));
        col = lerp(col, float3(0.88, 0.85, 0.80), haze * 0.6);
    } else {
        float3 pos = ro + rd * hit;
        float3 n = calc_normal(pos);
        float dif = saturate(dot(n, L));
        // Ink shadows over paper light: the mountain is drawn, not lit
        // like plastic. Paper texture consumed here (binding rule).
        float g = paper_tex.SampleLevel(paper_sampler, pos.xz * 0.35 + 0.5, 0).r;
        col = paper * (0.35 + 0.65 * dif) * (1.0 - 0.10 * g);
        // Ink crevice darkening where the surface turns from the light.
        col = lerp(col, ink * 0.6, saturate((0.15 - dif) * 4.0) * 0.5);
    }

    // Distance fog: the far ridges dissolve into haze — the range
    // continues beyond what is visible; reason knows it keeps going.
    float fog = 1.0 - exp(-max(hit, 0.0) * 0.025);
    col = lerp(col, float3(0.88, 0.85, 0.80), fog);

    // Amber halo toward the light, breathing: presence without an
    // object, saturation instead of bloom.
    float halo = pow(saturate(dot(rd, L)), 8.0) * 0.25 * breathe;
    col += amber * halo;

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
