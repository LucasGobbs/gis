// Mashrabiya: a lattice of eight-pointed stars between the viewer and a
// warm sun. The screen itself is almost invisible; what you watch is the
// light it edits — star-shaped shadows crawling over the paper floor as
// the sun drifts. The girih vocabulary (two rotated squares) as a
// machine for slowing light down.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float sdBox2D(float2 p, float2 b) {
    float2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Eight-pointed star (khatam): union of two squares rotated 45 degrees.
float sdStar2D(float2 p, float r) {
    float c = 0.7071;
    float2 q = float2(c * p.x - c * p.y, c * p.x + c * p.y);
    return min(sdBox2D(p, float2(r, r)), sdBox2D(q, float2(r, r)));
}

// The screen: a slab pierced by a lattice of stars. Repetition in x and
// y with a half-cell offset every other row, as in girih tiling.
float sdScreen(float3 p) {
    float slab = sdBox(p - float3(0.0, 1.6, 0.0), float3(3.4, 1.8, 0.06));
    float2 cell = float2(1.1, 1.1);
    float2 g = p.xy - float3(0.0, 1.6, 0.0).xy;
    float2 id = floor(g / cell);
    float rowShift = (abs(id.y - 2.0 * floor(id.y * 0.5)) > 0.5) ? cell.x * 0.5 : 0.0;
    float2 gv = g - (id + 0.5) * cell - float2(rowShift, 0.0);
    float star = sdStar2D(gv, 0.36);
    return max(slab, -star); // stars are holes
}

float map(float3 p) {
    float d = p.y; // ground
    d = min(d, sdScreen(p));
    // Two slim jambs so the screen reads as architecture, not a portal.
    d = min(d, sdBox(p - float3(-3.6, 1.9, 0.0), float3(0.25, 1.9, 0.25)));
    d = min(d, sdBox(p - float3(3.6, 1.9, 0.0), float3(0.25, 1.9, 0.25)));
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
    for (int i = 0; i < 96; i++) {
        float d = map(ro + rd * t);
        if (d < 0.001 * max(t, 1.0)) return t;
        t += d * 0.85;
        if (t > 60.0) break;
    }
    return -1.0;
}

float softShadow(float3 ro, float3 rd) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 24; i++) {
        float d = map(ro + rd * t);
        res = min(res, 10.0 * d / t);
        t += clamp(d, 0.03, 0.5);
        if (res < 0.005 || t > 10.0) break;
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

    // Slow observer: a slight drift, mostly still, facing the screen.
    float3 ro = float3(sin(t * 0.05) * 0.7, 1.5 + sin(t * 0.07) * 0.1, -5.5);
    float3 look = float3(0.0, 1.5, 0.0);
    float3 fwd = normalize(look - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.5 + right * uv.x + up * uv.y);

    // The sun behind the lattice drifts slowly; the star shadows crawl.
    float sunA = t * 0.04;
    float3 L = normalize(float3(sin(sunA) * 0.7, 0.55 + 0.1 * sin(t * 0.023), 0.85));
    float breathe = 0.85 + 0.15 * sin(t * 0.1);

    float hit = raymarch(ro, rd);
    float3 col;
    if (hit < 0.0) {
        float horizon = exp(-abs(rd.y) * 2.0);
        float glow = pow(saturate(dot(rd, L)), 5.0);
        col = float3(0.40, 0.31, 0.23) * horizon;
        col += float3(0.95, 0.66, 0.34) * glow * breathe;
    } else {
        float3 pos = ro + rd * hit;
        float3 n = calcNormal(pos);

        float3 albedo = float3(0.93, 0.90, 0.84);
        if (pos.y < 0.01) {
            float3 paper = paper_tex.SampleLevel(paper_sampler, pos.xz * 0.12 + 0.5, 0).rgb;
            albedo = paper;
        } else {
            // The screen itself: dark wood silhouette against the sun.
            albedo = float3(0.16, 0.11, 0.08);
        }

        float dif = saturate(dot(n, L));
        float sh = softShadow(pos + n * 0.004, L);
        float sky = 0.5 + 0.5 * n.y;
        col = albedo * 0.35 * sky * float3(0.78, 0.82, 0.96);
        col += albedo * dif * sh * breathe * float3(1.0, 0.85, 0.62) * 1.3;

        // Light leaking around and through the lattice onto this side.
        float behind = pow(saturate(dot(rd, L)), 10.0);
        col += float3(0.95, 0.66, 0.34) * behind * sh * 0.25;

        float fog = 1.0 - exp(-hit * 0.02);
        float3 fogCol = float3(0.42, 0.33, 0.24) * breathe;
        col = lerp(col, fogCol, fog);
    }

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
