# GIS - Gobbi Interactive Shaders (WIP)

## About

GIS is a desktop playground for real-time GPU shaders. Scenes are plain [Slang](https://shader-slang.org/) files. Save one and the pipeline hot-swaps on the next frame, with no windowing code, buffers or boilerplate in between.

![status](https://img.shields.io/badge/status-research%20prototype-orange)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.23150234.svg)](https://doi.org/10.5281/zenodo.23150234)

![Typing a pink rim light into the dragon shader, then turning it cyan](repository_assets/dragon_live_coding.gif)

Three lines added to the Stanford dragon's fragment shader, one line to use them, one save. A second save turns the glow from pink to cyan. Recordings: [24 s](repository_assets/dragon_live_coding_short.mp4) · [66 s](repository_assets/dragon_live_coding.mp4). More in the [gallery](GALLERY.md).

## Usage

The code goes in, the picture follows. Here is the edit at 4x speed.

![Typing the rim light](repository_assets/gif_typing_rim_light.gif)

And the moment of the save, pink first, then cyan.

| save | save again |
| --- | --- |
| ![Pink rim after the save](repository_assets/gif_save_pink_result.gif) | ![Cyan rim after the second save](repository_assets/gif_save_cyan_result.gif) |

<img src="repository_assets/d09_rim_result_split.png" alt="The dragon with its pink rim light" width="900">

## Tags in shaders generates UI at Runtime

Add a `[UiSlider]` or `[UiColor]` field to a params struct and a control appears. Pick a color and the render follows.

![Picking a new tint and moving a slider on waves](repository_assets/gif_waves_color_change.gif)

| before | after |
| --- | --- |
| <img src="repository_assets/w01_controls_original.png" alt="waves with its controls panel" width="440"> | <img src="repository_assets/w02_tint_and_sliders_edited.png" alt="waves after a new tint" width="440"> |

Change a default in the source, save, and the new value is live.

| typing | after the save |
| --- | --- |
| <img src="repository_assets/w08_typing_default_color.png" alt="Typing a new default color" width="440"> | <img src="repository_assets/w09_after_save_hot_reload.png" alt="waves in orange after the save" width="440"> |

## Break it, it keeps running

A failed compile never blanks the screen. The last working pipeline stays up and the error comes back into the editor as an annotation. The editor talks to `slangd`, so you get diagnostics, hover docs, go-to-definition, rename and completion while you type.

## See the pipeline

Every scene is a graph. The model and skybox feed the pass, the `settings` node broadcasts the uniforms, and each pass node shows a live preview of its own output.

<img src="repository_assets/d05_graph_fullscreen.png" alt="The dragon scene as a render graph in fullscreen" width="900">

| audit_plasma | waves |
| --- | --- |
| <img src="repository_assets/p02_graph_fullscreen.png" alt="audit_plasma graph" width="440"> | <img src="repository_assets/w06_graph_fullscreen.png" alt="waves graph" width="440"> |

## One scene, many looks

Edit the plasma's scale and palette and the red blobs become a blue and green grid.

| before | typing | after |
| --- | --- | --- |
| <img src="repository_assets/p01_split_controls_panel.png" alt="plasma before" width="290"> | <img src="repository_assets/p04_typing_palette.png" alt="typing the palette" width="290"> | <img src="repository_assets/p05_result_split.png" alt="plasma after" width="290"> |

## Arrange your workspace

F3 cycles the preview between a split view, a full-window view and a floating window.

| split | full | floating |
| --- | --- | --- |
| <img src="repository_assets/d09_rim_result_split.png" alt="split" width="290"> | <img src="repository_assets/d10_rim_result_full.png" alt="full" width="290"> | <img src="repository_assets/d11_rim_result_float.png" alt="floating" width="290"> |

The code font can be bigger, or switched to a pixel face.

<img src="repository_assets/d06_pixel_font.png" alt="Editor using the pixel font" width="900">

## What's in the box

- **Learning trail.** Ten scenes from `01_hello_pixel` to `10_multipass`, one idea each, with live "Try:" exercises.
- **3D scenes.** Load `.glb` / `.gltf` models, orbit them, and wrap them in an equirectangular skybox.
- **Pixel inspector.** Click the scene to read a pixel, and watch up to eight values per pass from inside the shader.
- **Exports.** PNG and GIF straight from the viewport.
- **Your own scenes.** Drop a folder with a `.slang` file in `gis_scenes/`, or create one in the app.

## Run it

macOS on Apple Silicon is the validated platform. The GPU layer is SDL3 GPU, so Linux and Windows (Vulkan) are the intended targets.

```sh
brew install qt sdl3 qscintilla2 cmake
git clone --recursive https://github.com/LucasGobbs/gis && cd gis
make run
```

The Slang compiler ships with the repo, so no separate install is needed. More detail in [docs/DETAILS.md](docs/DETAILS.md).

## License

MIT. Vendored components keep their own licenses.
