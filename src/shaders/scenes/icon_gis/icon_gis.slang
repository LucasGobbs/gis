// The gis icon: a stick of chalk (giz) raymarched in 3D. A plain
// flat-capped cylinder with a tangerine-sector wedge carved out of the
// top rim - the trace of the first drawing. Time-stable (iTime unused):
// the --shot icon render and the live scene show the same frame. Only
// the chalk floats in frame: no ground, deep-ink backdrop, tangerine
// cut faces.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
RWTexture2D<float4> out_tex;

static const float R = 0.5;  // stick radius
static const float H = 1.3;  // stick height, centered on the origin
static const float NOTCH_HALF_ANGLE = 0.45; // wedge spans ~52 degrees
static const float NOTCH_DEPTH = 0.40;      // how far down the rim it bites

// Notch direction in xz, facing the camera (unit length; matches the
// camera azimuth (1.2, 1.9)).
static const float2 NOTCH_DIR = float2(0.534, 0.845);

float cross2(float2 a, float2 b) {
    return a.x * b.y - a.y * b.x;
}

// The tangerine-sector notch: negative inside the carved region.
// Angular sector around NOTCH_DIR (cross-product test, no atan2),
// restricted to the front half-plane and the top band of the stick.
// The angular test alone also fires on the far side of the circle
// (sin period); the front-half-plane term kills that lobe.
float sdNotch(float3 p) {
    float m = atan2(NOTCH_DIR.y, NOTCH_DIR.x);
    float2 u1 = float2(cos(m + NOTCH_HALF_ANGLE), sin(m + NOTCH_HALF_ANGLE));
    float2 u2 = float2(cos(m - NOTCH_HALF_ANGLE), sin(m - NOTCH_HALF_ANGLE));
    // Inside the sector both cross products are positive; min() is
    // negative once outside either boundary radius.
    float ang = -min(cross2(u2, p.xz), cross2(p.xz, u1));
    float front = -dot(p.xz, NOTCH_DIR);        // negative toward camera
    float band = (H * 0.5 - NOTCH_DEPTH) - p.y; // negative in the top band
    return max(ang, max(front, band));
}

// The chalk: plain cylinder minus the notch.
float sdChalk(float3 p) {
    float d = max(length(p.xz) - R, abs(p.y) - H * 0.5);
    return max(d, -sdNotch(p));
}

float map(float3 p) {
    return sdChalk(p);
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
        t += d * 0.9;
        if (t > 40.0) break;
    }
    return -1.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 uv = scene_uv(fragCoord, Uniforms.iResolution);

    // Fixed orbit camera, tilted down to expose the top rim cut.
    float3 ro = float3(1.2, 1.15, 1.9);
    float3 look = float3(0.0, 0.05, 0.0);
    float3 fwd = normalize(look - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.25 + right * uv.x + up * uv.y);

    // Studio key from the upper left, cool sky fill.
    float3 L = normalize(float3(-0.6, 0.9, 0.4));

    float hit = raymarch(ro, rd);
    float3 col;
    if (hit < 0.0) {
        // Deep-ink backdrop: quiet vertical gradient plus vignette.
        float3 top = float3(0.11, 0.12, 0.18);
        float3 bottom = float3(0.05, 0.055, 0.09);
        col = lerp(bottom, top, uv.y * 0.5 + 0.5);
        col *= 1.0 - 0.35 * dot(uv, uv);
    } else {
        float3 pos = ro + rd * hit;
        float3 n = calcNormal(pos);
        float dif = saturate(dot(n, L));
        float sky = 0.5 + 0.5 * n.y;

        col = float3(0.93, 0.93, 0.95) * (0.34 * sky + 0.78 * dif);

        // Tangerine cut faces: at a carved surface the notch SDF sits
        // at ~0 while the cylinder SDF is negative (material removed);
        // on the untouched body surface it is the reverse.
        float body = max(length(pos.xz) - R, abs(pos.y) - H * 0.5);
        bool onCut = -sdNotch(pos) > body;

        if (onCut) {
            // Exposed "flesh": warm tangerine, softly lit.
            col = float3(0.96, 0.52, 0.18) * (0.62 + 0.38 * dif);
            col += float3(0.96, 0.52, 0.18) * sky * 0.20;
        } else {
            // Porcelain chalk body: cool white with a soft key.
            col = float3(0.93, 0.93, 0.95) * (0.28 * sky + 0.72 * dif);
            // Fine chalk grain.
            col += hash21(fragCoord) * 0.03;
            // Cool rim against the dark backdrop.
            float rim = pow(1.0 - saturate(dot(n, -rd)), 3.0);
            col += rim * float3(0.55, 0.65, 0.85) * 0.25;
        }
    }

    out_tex[id.xy] = float4(orderedDither(col, 6.0, id.xy), 1.0);
}
