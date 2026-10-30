# gis — Gobbi Interactive Shaders

A desktop live-coding environment for learning and experimenting with real-time GPU
shaders: no windowing, buffers, or pipeline boilerplate between you and the first
pixel. Scenes are plain [Slang](https://shader-slang.org/) files discovered from a
folder; saving a file recompiles it incrementally on a background thread and hot-swaps
the pipeline. A failed build never blanks the screen: the last working pipeline stays
up and the error comes back into the editor as an annotation.

![status](https://img.shields.io/badge/status-research%20prototype-orange)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.23150234.svg)](https://doi.org/10.5281/zenodo.23150234)

## Features

- **Zero-boilerplate scenes**: a scene is a folder with a `.slang` file in
  `src/shaders/scenes/`; it appears in the app automatically. Ships a designed
  ten-scene learning trail (`01_hello_pixel` … `10_multipass`, one concept per
  scene with live "Try:" exercises) plus older development fixtures.
- **Selective builds**: startup and hot reload compile only the active scene,
  its `pass_*.slang` modules, and imported utilities. Other scene titles stay in
  the catalog and are compiled when selected.
- **Language-server editing**: the code editor embeds `slangd`, the official Slang
  language server: diagnostics, hover docs, go-to-definition, rename, completion.
- **Reflection-checked pipeline graph**: reflection derives typed ports from the
  Slang declarations; `graph.json` stores the executable pass topology. Creating
  or detaching an edge in the node editor changes the runtime pipeline after a
  confirmation step. Invalid JSON, cycles, duplicate producers, missing outputs,
  or incompatible endpoints keep the last valid pipeline active.
- **Failure-preserving hot reload**: dependency-tracked incremental builds on a
  worker thread; broken code keeps the previous pipeline on screen.
- **Node previews and pixel provenance**: every pass node on the graph canvas
  shows its output thumbnail; clicking the scene samples the pixel and shows the
  causal chain across upstream passes.
- **3D model viewer scenes**: glTF (`.glb`/`.gltf`) loading, orbit camera, equirectangular
  skyboxes; `graph.json` may route user models/textures into any pass input.
- **Learning trails**: the LEARN panel renders markdown docs
  (`assets/trails/*.md`) with live links — `[label](scene:NAME)` opens the scene,
  `[label](trail:NAME)` navigates; code blocks highlight with the editor theme.
- **Failure-preserving assets**: paper textures, skyboxes, and a model library
  load at startup; a missing skybox is skipped, missing paper/model is fatal.
- **User scenes vs built-ins**: scenes under `src/shaders/scenes/` are
  the built-in catalog; new scenes (created in-app or dropped in
  `gis_scenes/<name>/<name>.slang`) live outside the source tree and are
  marked with a dot in the scene selector. A user scene with the same
  name as a built-in one shadows it. Because user scenes sit two levels
  below the repo root, their shared-module import is
  `import "../../src/shaders/common";` (the in-app template already
  emits it).
- **Visual debugging**: `debug_scalar`, `debug_signed`, `debug_vector`,
  `debug_normal`, `debug_mask`, `debug_nan_inf`, compiler squiggles, async
  1×1 pixel inspection, eight GPU-watch slots per pass, and restore to the
  last loadable source version.
- **Cross-platform GPU**: built on the SDL3 GPU API (Metal on macOS, SPIR-V/Vulkan
  on Linux/Windows). Currently validated on macOS/Metal (Apple Silicon).

## Requirements

- A C++20 toolchain (clang++ / AppleClang 17 validated) with CMake ≥ 3.22
- Qt 6, SDL3, QScintilla2 (Homebrew on macOS: `brew install qt sdl3 qscintilla2 cmake`)
- The [goose](https://github.com/LucasGobbs/goose) submodule (shipped in
  `vendor/goose/`): `git clone --recursive` or `git submodule update --init`.
  It carries a vendored Slang distribution (`vendor/goose/vendor/slang/`,
  macOS arm64) so shader compilation needs **no separate Slang install**;
  a system install is picked up as fallback for anything the vendored dist
  misses (e.g. `libslang-llvm.dylib`, excluded from the submodule — over
  GitHub's 100 MB file limit).

## Build & run

```sh
git clone --recursive https://github.com/LucasGobbs/gis gis && cd gis
make build      # configure + build (build/gis_host)
make run        # shaders bake + build + run (hot reload enabled)
make test       # Catch2 suite (17 cases)
make shaders    # bake scene artifacts only (slangc via goose-build)
```

The Odin app that predates this port is kept under `legacy/` (own Makefile)
until the C++ app closes the last parity window; it is not part of the
default build.

## Layout

```
src/                   the app: gfx/, gfx/render_graph/, ui/, export/, host_main.mm
src/shaders/           shared Slang modules + the scene corpus (scenes/<name>/)
src/generated/         goose-baked artifacts (msl/spv/refl.json/glue), gitignored
tests/                 Catch2 suite (render graph, shell, inspect)
vendor/goose/          submodule: goose-build + vendored Slang
vendor/                cgltf, stb_image, md4c, fonts, editor wrappers
assets/                textures, models, skyboxes, trails, input.ini, ui.prefs
gis_scenes/            user scenes (shadow built-ins of the same name)
exports/               PNG/GIF output
legacy/                the previous Odin app (kept runnable, not built by default)
docs/                  port development history (audit, bug hunt, gate log)
```

## Editable pipeline graph

Each scene may persist `graph.json`. Shader source remains authoritative for pass
interfaces; reflection supplies the available typed pins. JSON links are
authoritative for execution order and resource routing:

```json
{
  "version": 1,
  "scene": "10_multipass",
  "links": [
    {
      "from": "comp:scenes/10_multipass/10_multipass:computeMain:out_tex",
      "to": "comp:scenes/10_multipass/pass_1:computeMain:input_tex"
    },
    {
      "from": "comp:scenes/10_multipass/pass_1:computeMain:out_tex",
      "to": "show2d:frame"
    }
  ]
}
```

The runtime topologically sorts the pass DAG and allocates a stable output target
for every pass. The editor stages `connect`/`disconnect`, displays the endpoints,
and writes JSON only after confirmation. A disconnected `input_tex` samples a
black fallback; reconnecting restores the producer without editing either shader.

## GPU debug watches

Enable **Debug → pixel inspector**, then click the scene. Instrument up to eight
`float`, `float2`, `float3`, or `float4` expressions in each pass:

```slang
// Fragment shader
debug_watch_fragment(0, color, uint2(input.gl_FragCoord.xy), Uniforms);

// Compute shader
debug_watch_compute(0, value, id.xy, Uniforms);
```

Only the selected fragment or dispatch thread writes. Records are indexed by
`pass × slot`, copied asynchronously after the frame, and shown on the next
frame. Labels (`color`, `value`) are extracted from the source expression;
strings never cross the GPU boundary. The same selection downloads the output
pixel from every upstream pass and displays its causal chain in the Debug panel
and graph nodes. Scenes `01_hello_pixel`, `09_compute`, and `10_multipass` are
working examples.

## Input map

`assets/input.ini` is the single key source (ini: `action = [mod+]key`; mods
`shift|ctrl|alt|gui`): F1 zen, F2 editor, F3 preview cycle (float/split/full),
F4 theater, F5 mobile,
Cmd+S save-all, Cmd+B sidebar, Tab flycam, Q/E fly up/down. Window actions
fall back to compiled defaults when the file is missing.

## License

MIT (see LICENSE). Vendored components keep their own licenses.
