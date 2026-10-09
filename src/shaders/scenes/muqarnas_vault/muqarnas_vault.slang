// Muqarnas vault: a stalactite dome of recursive cells. Ring after ring
// of niches hangs from a hemisphere, each level smaller, melting into
// the next — the geometry of accumulated prayer. Light falls from the
// ocular at the top; the camera looks up from the center and turns very
// slowly, like someone lying on the carpet.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

static const float DOME_R = 6.0;

float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float sdSphere(float3 p, float3 c, float r) {
    return length(p - c) - r;
}

// The vault: a hemisphere shell plus hanging cells in polar rings.
// Ring k sits at polar angle theta_k with 6(k+1) cells, alternating
// phase; cells hang below the shell and shrink as they approach the
// crown — the muqarnas rhythm of niche upon niche.
float sdVault(float3 p) {
    // Dome shell (hemisphere above the floor).
    float dome = abs(length(p) - DOME_R) - 0.12;
    if (p.y < 0.0) dome = abs(length(p) - DOME_R) - 0.12;

    float d = dome;
    float radius = DOME_R;
    for (int ring = 0; ring < 3; ring++) {
        float theta = 0.22 + float(ring) * 0.24; // polar angle of the ring
        int count = 6 * (ring + 1);
        float cellR = radius * theta / float(count) * 2.4;
        float phase = (ring % 2 == 0) ? 0.0 : 3.14159 / float(count);
        for (int j = 0; j < 24; j++) {
            if (j >= count) break;
            float phi = phase + float(j) * 6.28318 / float(count);
            // Upper hemisphere: the niches cover the vault above,
            // facing down at the carpet (not the bare far side).
            float3 c = float3(
                sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)) * radius;
            // Cell hangs below the shell: a half-sphere niche.
            float cell = sdSphere(p, c * 1.02, cellR);
            d = smin(d, cell, cellR * 0.5);
        }
    }
    return d;
}

float map(float3 p) {
    float d = p.y + 2.0; // floor at y = -2
    d = min(d, sdVault(p - float3(0.0, 4.0, 0.0)));
    return d;
}

float3 calcNormal(float3 p) {
    float e = 0.0015;
    return normalize(float3(
        map(p + float3(e, 0, 0)) - map(p - float3(e, 0, 0)),
        map(p + float3(0, e, 0)) - map(p - float3(0, e, 0)),
        map(p + float3(0, 0, e)) - map(p - float3(0, 0, e))));
}

float raymarch(float3 ro, float3 rd) {
    float t = 0.0;
    for (int i = 0; i < 64; i++) {
        float d = map(ro + rd * t);
        if (d < 0.001 * max(t, 1.0)) return t;
        t += d * 0.8;
        if (t > 40.0) break;
    }
    return -1.0;
}

float softShadow(float3 ro, float3 rd) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 20; i++) {
        float d = map(ro + rd * t);
        res = min(res, 10.0 * d / t);
        t += clamp(d, 0.04, 0.6);
        if (res < 0.005 || t > 12.0) break;
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

    // Lying on the carpet: camera at the dome's center, gazing up at a
    // diagonal so the frame holds the upper vault, the light shaft and
    // a slice of the lit carpet — turning slowly on its own axis.
    float turn = t * 0.03;
    float3 ro = float3(0.0, -1.5, 0.0);
    float3 fwd = normalize(float3(sin(turn) * 0.5, 0.85, cos(turn) * 0.5));
    float3 right = normalize(cross(fwd, float3(0.0, 0.0, 1.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.3 + right * uv.x + up * uv.y);

    // Light from the ocular: a vertical warm shaft breathing slowly.
    float breathe = 0.75 + 0.25 * sin(t * 0.1);
    float3 L = normalize(float3(0.15, 1.0, 0.1));

    float hit = raymarch(ro, rd);
    float3 col;
    if (hit < 0.0) {
        // Through the crown: warm sky.
        float glow = pow(saturate(rd.y), 3.0);
        col = float3(0.85, 0.62, 0.38) * glow * breathe + float3(0.10, 0.08, 0.06);
    } else {
        float3 pos = ro + rd * hit;
        float3 n = calcNormal(pos);
        // Thin shell lit from both sides: the ocular sun reaches the
        // vault's upper interior through the opening, so the outward
        // gradient catches it; abs() keeps the inner face lit instead
        // of flipping it into darkness.
        float dif = abs(dot(n, L));

        float3 albedo = float3(0.90, 0.86, 0.78);
        if (pos.y < -1.95) {
            // The carpet: paper with a soft central medallion.
            float3 paper = paper_tex.SampleLevel(paper_sampler, pos.xz * 0.1 + 0.5, 0).rgb;
            float med = 1.0 - 0.4 * smoothstep(1.5, 2.5, length(pos.xz));
            albedo = paper * med;
        }

        // The ocular is an opening: the vault's inner surface must NOT
        // self-shadow from it (the shell would eat the whole shaft).
        // Only the carpet keeps the dome's shadow pooling in it.
        float sh = pos.y < -1.95 ? softShadow(pos + n * 0.004, L) : 1.0;
        float sky = 0.6 + 0.4 * abs(n.y);
        col = albedo * 0.55 * sky * float3(0.78, 0.8, 0.92);
        col += albedo * dif * sh * breathe * float3(1.0, 0.85, 0.62) * 1.5;

        // The ocular shaft as presence: a soft column of light under
        // the crown, bright near the axis, fading outward.
        float axis = length(pos.xz);
        float shaft = exp(-axis * axis * 0.6) * breathe;
        col += shaft * float3(0.95, 0.75, 0.45) * 0.25;

        // Amber pooling in the niches (light held by the cells).
        float niche = pow(saturate(dot(n, -L)), 2.0) * sh;
        col += niche * float3(0.91, 0.62, 0.30) * 0.35;

        // Cell structure: the niche rims read as amber edges against
        // the shaded vault, so the muqarnas rhythm shows.
        float rim = pow(1.0 - abs(dot(n, -rd)), 2.5);
        col += rim * float3(0.85, 0.58, 0.30) * 0.3;

        float fog = 1.0 - exp(-hit * 0.015);
        col = lerp(col, float3(0.35, 0.27, 0.19), fog);
    }

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
