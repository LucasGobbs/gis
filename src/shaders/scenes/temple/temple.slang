// Sanctum: a votive temple as digital axis mundi. A slow pilgrim camera
// drifts through a colonnade toward a stepped fractal tower, lit by a
// warm key that breathes (~10 s). Sacred-geometry vocabulary (repetition,
// recursion, light through lattice) rendered in the atelier's materials:
// paper, amber and ink. Original form inspired by the geometric
// tradition — not a replica of any real sacred site.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> paper_tex;

[[vk::binding(2, 0)]]
SamplerState paper_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

// The camera flies the aisle along z; the tower stands far ahead.
static const float TOWER_Z = 18.0;

// Polynomial smooth-min: melts levels into one mass instead of
// stair-stepping them.
float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdColumn(float3 p, float r) {
    return length(p.xz) - r;
}

// Round-arched colonnade: columns plus a lintel, repeated down z and
// mirrored across the aisle. Openings let the key light rake through.
float sdColonnade(float3 p) {
    float3 q = float3(abs(p.x), p.y, p.z);
    q.x -= 3.2;
    q.z = q.z - round(q.z / 4.0) * 4.0; // cell repeat every 4 m
    float col = sdColumn(q, 0.22);
    // Lintel between column tops, thin and high so sky falls through
    // the arch openings instead of a solid band.
    float lintel = sdBox(float3(q.x, q.y - 4.2, q.z), float3(0.28, 0.35, 2.2));
    return min(col, lintel);
}

// The sanctum: a stepped fractal tower (axis mundi). Each level shrinks
// and melts into the next (smooth-min), recalling muqarnas vaults and
// ziggurat silhouettes without copying any real monument.
float sdTower(float3 p) {
    float3 base = float3(0.0, 0.0, TOWER_Z);
    p -= base;
    float d = 1e9;
    float w = 3.4;
    float h = 0.0;
    for (int i = 0; i < 7; i++) {
        float lvl = sdBox(p - float3(0.0, h + w * 0.22, 0.0), float3(w, w * 0.22, w));
        d = smin(d, lvl, 0.35);
        h += w * 0.42;
        w *= 0.68;
    }
    return d;
}

// Floor with a faint prayer-rug border: darker band near the edges.
float map(float3 p) {
    float d = p.y; // ground plane
    d = min(d, sdColonnade(p));
    d = min(d, sdTower(p));
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
        if (t > 80.0) break;
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

    // Pilgrim drift: a slow walk down the aisle with a soft sway, gaze
    // lifted toward the tower. Roughly 4 minutes to arrive, then hold.
    float travel = min(t * 0.055, 14.0);
    float3 ro = float3(sin(t * 0.12) * 0.5, 1.55 + sin(t * 0.1) * 0.08, -2.0 + travel);
    float3 look = float3(0.0, 3.2, ro.z + 8.0);
    float3 fwd = normalize(look - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.5 + right * uv.x + up * uv.y);

    // The key light breathes (period ~63 s): a high warm sun raking
    // through the colonnade from the left.
    float breathe = 0.75 + 0.25 * sin(t * 0.1);
    float3 L = normalize(float3(-0.55, 0.75, 0.35));

    float hit = raymarch(ro, rd);
    float3 col;
    if (hit < 0.0) {
        // Sky: warm haze that never goes black, brighter toward the
        // light — the tower's silhouette stands against it.
        float horizon = exp(-abs(rd.y) * 2.0);
        float glow = pow(saturate(dot(rd, L)), 5.0);
        col = float3(0.42, 0.33, 0.25) * horizon * breathe;
        col += float3(0.9, 0.62, 0.34) * glow * breathe;
    } else {
        float3 pos = ro + rd * hit;
        float3 n = calcNormal(pos);

        // Materials: paper everywhere, amber only at grazing light.
        float3 albedo = float3(0.93, 0.90, 0.84);
        if (pos.y < 0.01) {
            // Floor: world-mapped paper with a dark aisle border.
            float3 paper = paper_tex.SampleLevel(paper_sampler, pos.xz * 0.12 + 0.5, 0).rgb;
            float border = smoothstep(2.6, 3.1, abs(pos.x));
            albedo = paper * lerp(0.55, 1.0, border);
        }

        float dif = saturate(dot(n, L));
        float sh = softShadow(pos + n * 0.004, L);
        float sky = 0.5 + 0.5 * n.y;
        col = albedo * 0.42 * sky * float3(0.78, 0.82, 0.96);
        // Cool bounce from the floor so shadowed flanks keep shape.
        col += albedo * 0.16 * saturate(-n.y + 0.6) * float3(0.9, 0.85, 0.75);
        col += albedo * dif * sh * breathe * float3(1.0, 0.85, 0.62) * 1.35;
        // Amber rim where surfaces graze the key light.
        float rim = pow(1.0 - saturate(dot(n, -rd)), 3.0) * dif * sh;
        col += rim * float3(0.91, 0.62, 0.30) * 0.6;

        // Distance fog into warm haze, lighter so the vault breathes.
        float fog = 1.0 - exp(-hit * 0.018);
        float glow = pow(saturate(dot(rd, L)), 4.0);
        float3 fogCol = float3(0.45, 0.35, 0.25) * (0.75 + glow) * breathe;
        col = lerp(col, fogCol, fog);

        // Sanctum glow: a faint amber halo bleeding over the tower's
        // summit as the key passes behind it.
        float behind = pow(saturate(dot(rd, L)), 24.0);
        col += float3(0.95, 0.65, 0.32) * behind * sh * 0.35;
    }

    out_tex[id.xy] = float4(orderedDither(col, 5.0, id.xy), 1.0);
}
