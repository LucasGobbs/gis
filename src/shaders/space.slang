// Space mappings between dimensions and containment checks.
// Aspect-correct scene coordinates, pinhole projection, plane hits.
// Learning trail: raycasting-gpu. Usage: Space::pixel_to_uv(...) etc.

namespace Space {
    public float2 pixel_to_uv(float2 fragCoord, float3 iResolution) {
        return (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    }

    public float2 pixel_to_unit(float2 fragCoord, float3 iResolution) {
        return fragCoord / iResolution.xy;
    }

    public bool inside_box2(float2 p, float2 lo, float2 hi) {
        return all(p >= lo) && all(p <= hi);
    }

    public bool inside_box3(float3 p, float3 lo, float3 hi) {
        return all(p >= lo) && all(p <= hi);
    }

    public float2 project_xy(float3 p) {
        return p.xy;
    }

    public float2 project_xz(float3 p) {
        return p.xz;
    }

    public float2 perspective_2d(float3 p, float focal) {
        return p.xy * (focal / max(p.z, 1e-4));
    }

    public float ray_t_plane(float3 ro, float3 rd, float planeY) {
        if (abs(rd.y) < 1e-4) return -1.0;
        return -(ro.y - planeY) / rd.y;
    }

    public float3 plane_hit(float3 ro, float3 rd, float planeY, float fallbackDist) {
        float t = ray_t_plane(ro, rd, planeY);
        if (t <= 0.0) return ro + rd * fallbackDist;
        return ro + rd * t;
    }

    public float map_range2(float x, float2 from, float2 to) {
        if (from.x == from.y) return to.x;
        return lerp(to.x, to.y, (x - from.x) / (from.y - from.x));
    }

    public float saturate_range2(float x, float2 from, float2 to) {
        float v = map_range2(x, from, to);
        return clamp(v, to.x, to.y);
    }

}
