// Noise primitives moved from common: hash, value noise, fbm.
// Learning trail: noise. Usage: Noise::fbm(...), Noise::hash21(...).

namespace Noise {
    public float hash21(float2 p) {
        return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
    }

    public float valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = p - i;
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
    }

    public float fbm(float2 p, int octaves, float lacunarity, float gain) {
        float sum = 0.0;
        float amp = 0.5;
        float2 q = p;
        [MaxIters(12)]
        for (int i = 0; i < octaves; i++) {
            sum += amp * valueNoise(q);
            q = q * lacunarity + float2(17.3, 9.1);
            amp *= gain;
        }
        return sum;
    }

}
