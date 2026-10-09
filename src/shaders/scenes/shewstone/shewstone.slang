// Shewstone: John Dee's scrying mirror, the ancestor of the monitor.
// An obsidian sphere on paper circled in ink. It shows nothing you did
// not put there: a dark body, a rim of the world it sits in, and one
// ember inside that breathes when you do. The anti-oracle by
// construction — the stone only returns what you wrote.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float sdSphere(float3 p, float3 c, float r) {
    return length(p - c) - r;
}

static const float STONE_R = 0.55;
static const float3 STONE_C = float3(0.0, 0.56, 0.0);

float map(float3 p) {
    float d = p.y; // ground
    d = min(d, sdSphere(p, STONE_C, STONE_R));
    return d;
}

// Material id: 0 = ground, 1 = ink circle, 2 = stone. Geometry order
// matters: the stone wins over the floor, the ink ring wins over both
// only where it actually lies (the ground plane).
float2 mapMat(float3 p) {
    float2 res = float2(p.y, 0.0);
    float stone = sdSphere(p, STONE_C, STONE_R);
    if (stone < res.x) res = float2(stone, 2.0);
    // The scrying circle: a hand-drawn ink ring around the stone.
    float ring = abs(length(p.xz) - (STONE_R + 0.55)) - 0.02;
    if (p.y < 0.01 && ring < res.x) res = float2(ring, 1.0);
    return res;
}

float3 calcNormal(float3 p) {
    float e = 0.0015;
    return normalize(float3(
        map(p + float3(e, 0, 0)) - map(p - float3(e, 0, 0)),
        map(p + float3(0, e, 0)) - map(p - float3(0, e, 0)),
        map(p + float3(0, 0, e)) - map(p - float3(0, 0, e))));
}

float2 raymarch(float3 ro, float3 rd) {
    float t = 0.0;
    for (int i = 0; i < 96; i++) {
        float2 d = mapMat(ro + rd * t);
        if (d.x < 0.001 * max(t, 1.0)) return float2(t, d.y);
        t += d.x * 0.85;
        if (t > 40.0) break;
    }
    return float2(-1.0, 0.0);
}

float softShadow(float3 ro, float3 rd) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 24; i++) {
        float d = map(ro + rd * t);
        res = min(res, 10.0 * d / t);
        t += clamp(d, 0.03, 0.5);
        if (res < 0.005 || t > 8.0) break;
    }
    return saturate(res);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 uv = scene_uv(fragCoord, Uniforms.iResolution);

    float t = Uniforms.iTime;

    // Slow orbit at reading distance, slightly above the ring.
    float a = t * 0.06;
    float3 ro = float3(sin(a) * 2.2, 1.3 + sin(t * 0.08) * 0.08, cos(a) * 2.2);
    float3 fwd = normalize(STONE_C - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.6 + right * uv.x + up * uv.y);

    float breathe = 0.75 + 0.25 * sin(t * 0.1);
    float3 L = normalize(float3(0.5, 0.8, 0.4));

    float2 hit = raymarch(ro, rd);
    float3 col;
    if (hit.x < 0.0) {
        float horizon = exp(-abs(rd.y) * 2.0);
        col = float3(0.30, 0.24, 0.18) * horizon;
    } else {
        float3 pos = ro + rd * hit.x;
        float3 n = calcNormal(pos);
        int mat = int(hit.y + 0.5);

        float sh = softShadow(pos + n * 0.004, L);
        float dif = saturate(dot(n, L));

        if (mat == 2) {
            // Obsidian: near-black body. What you see on it is only what
            // surrounds it — the paper world bent back as a fresnel rim,
            // and the key light as a single hard star.
            float fres = pow(1.0 - saturate(dot(n, -rd)), 2.5);
            col = float3(0.015, 0.012, 0.014);
            // The world's rim: paper and amber reflected at grazing.
            col += fres * float3(0.75, 0.62, 0.45) * (0.35 + 0.4 * sh);
            // One hard star of light.
            float3 H = normalize(L - rd);
            col += pow(saturate(dot(n, H)), 220.0) * breathe * float3(1.0, 0.85, 0.6);
            // The ember inside: a soft pulse that arrives with your
            // breath, not before it.
            float ember = pow(saturate(dot(n, -rd)), 3.0) * breathe;
            col += ember * float3(0.5, 0.18, 0.05) * 0.5;
        } else if (mat == 1) {
            // The ink ring: dark, glossy where the key catches it.
            col = float3(0.05, 0.04, 0.04);
            float3 H = normalize(L - rd);
            col += pow(saturate(dot(n, H)), 60.0) * sh * 0.3 * float3(0.9, 0.8, 0.7);
        } else {
            // Paper, with the stone's shadow pooling in it.
            float3 paper = paper_tex.SampleLevel(paper_sampler, pos.xz * 0.25 + 0.5, 0).rgb;
            col = paper * (0.35 + 0.75 * sh) * float3(1.0, 0.95, 0.85);
            col += paper * 0.15 * float3(0.75, 0.8, 0.95);
        }
    }

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
