package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// Scene templates for the toolbar's "+ new" popup. The user names the
// scene; it lands in USER_SCENES_DIR (<name>/<name>.slang), the scene
// watcher discovers it on the next frame, compiles it, and lists it:
// no code change or restart needed.

SceneTemplateKind :: enum {
	COMPUTE,
	GRAPHICS_2D,
	GRAPHICS_3D,
}

TEMPLATE_COMPUTE :: `// New compute scene: one thread per pixel writing out_tex.
// User scenes live in gis_scenes/<name>/: two levels below the repo
// root, so the shared module import carries the extra hop.
import "../../src/shaders/common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    float2 p = scene_uv(fragCoord, Uniforms.iResolution);
    float v = 0.5 + 0.5 * sin(10.0 * length(p) - Uniforms.iTime);
    out_tex[id.xy] = float4(float3(v), 1.0);
}
`

TEMPLATE_GRAPHICS_2D :: `// New 2D graphics scene: fullscreen triangle, per-pixel fragment.
// User scenes live in gis_scenes/<name>/: two levels below the repo
// root, so the shared module import carries the extra hop.
import "../../src/shaders/common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 p = scene_uv(input.gl_FragCoord, Uniforms.iResolution);
    float v = 0.5 + 0.5 * sin(10.0 * length(p) - Uniforms.iTime);
    return float4(float3(v), 1.0);
}
`

TEMPLATE_GRAPHICS_3D :: `// New 3D graphics scene: renders the loaded model with wrapped diffuse.
// User scenes live in gis_scenes/<name>/: two levels below the repo
// root, so the shared module import carries the extra hop.
import "../../src/shaders/common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> skybox_tex;

[[vk::binding(2, 0)]]
SamplerState skybox_sampler;

[shader("vertex")]
ModelVaryings vertMain(ModelVertex input, uint vertexIndex : SV_VertexID) {
    return model_scene_vertex(input, vertexIndex, Uniforms);
}

[shader("fragment")]
float4 pixelMain(ModelVaryings input) : SV_Target0 {
    float3 n = normalize(input.normal);
    float3 L = normalize(float3(0.5, 0.8, -0.6));
    float dif = 0.35 + 0.65 * saturate(dot(n, L));
    return model_scene_fragment(input, Uniforms, skybox_tex, skybox_sampler, float3(0.7) * dif);
}
`

template_source :: proc(kind: SceneTemplateKind) -> string {
	switch kind {
	case .COMPUTE:     return TEMPLATE_COMPUTE
	case .GRAPHICS_2D: return TEMPLATE_GRAPHICS_2D
	case .GRAPHICS_3D: return TEMPLATE_GRAPHICS_3D
	}
	return ""
}

// Valid scene name: ASCII letter first, then letters/digits/_/-, max
// 48 chars (fits a 64-byte input buffer). Starting with a letter keeps
// "." and ".." out.
scene_name_valid :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > 48 do return false
	if !(('a' <= name[0] && name[0] <= 'z') || ('A' <= name[0] && name[0] <= 'Z')) do return false
	for c in name[1:] {
		if !(('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') || c == '_' || c == '-') do return false
	}
	return true
}

// A name is taken when a scene directory with it already exists under
// either root (catalog scan or built-in tree check): never overwrite.
scene_name_taken :: proc(name: string) -> bool {
	for catalog_name in scene_names_on_disk() {
		if catalog_name == name do return true
	}
	return os.exists(fmt.tprintf("%s/%s", SCENES_DIR, name))
}

// Creates a named scene unit (directory with the entry shader) under
// USER_SCENES_DIR. Refuses invalid or taken names; returns the scene
// title for follow-up selection.
scene_create_named :: proc(kind: SceneTemplateKind, name: string) -> (title: string, succeeded: bool) {
	if !scene_name_valid(name) || scene_name_taken(name) do return "", false
	source := template_source(kind)
	// User scenes live outside the source tree (USER_SCENES_DIR): they
	// survive repo updates and read as "mine" in the scene selector.
	scene_dir := fmt.tprintf("%s/%s", scene_user_dir(), name)
	if os.make_directory(scene_dir) != nil {
		log.errorf("new scene: failed to create %s", scene_dir)
		return "", false
	}
	path := fmt.tprintf("%s/%s.slang", scene_dir, name)
	if os.write_entire_file(path, transmute([]u8)source) != nil {
		log.errorf("new scene: failed to write %s", path)
		return "", false
	}
	log.infof("new scene: created %s", path)
	return strings.clone(name), true
}
