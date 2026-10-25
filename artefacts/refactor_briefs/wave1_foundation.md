# Onda 1 — Foundation (4 agentes paralelos)

## Contratos compartilhados

### A) package glove (src/glove/)
- Copiar INTACTO de /Users/gobbi/Desktop/code/projects/cubes/src/glove/:
  types.odin, bindings.odin, system.odin, adapter.odin,
  adapters/sdl/*, adapters/mock/*, tests/glove_test.odin (mesmos subpaths).
- package `glove`. Nenhuma mudança de conteúdo.

### B) package gfx (src/gfx/)
- package `gfx`; imports: `glove "../glove"`, sdl `vendor:sdl3`.
- Arquivos: gfx.odin, resource_handle.odin, buffer.odin, texture.odin,
  sampler.odin, uploader.odin.
- Gfx:
  ```
  Gfx :: struct {
      window: ^sdl.Window,
      gpu: ^sdl.GPUDevice,
      window_size: [2]i32,
      shader_format: sdl.GPUShaderFormat,
      swapchain_format: sdl.GPUTextureFormat,
      depth_texture: ^sdl.GPUTexture,
      command_buffer: ^sdl.GPUCommandBuffer,
      swapchain: ^sdl.GPUTexture,
      frame_open: bool,
      inputs: glove.System,
      running: bool,
      // pools (resource_handle): buffers, textures, samplers + Handle_Pool cada
  }
  ```
- create(gfx, window_title, window_width, window_height) -> bool:
  sdl.Init({.VIDEO}), CreateWindow, CreateGPUDevice({.MSL,.SPIRV}, true, nil),
  ClaimWindowForGPUDevice, GetWindowSize, depth D32_FLOAT,
  shader_format detectado via sdl.GetGPUDeviceDriver (padrão do
  cubes/compute/compute.odin: MSL em Darwin, SPIRV caso contrário),
  swapchain_format via sdl.GetGPUSwapchainTextureFormat.
- gfx_begin_frame(gfx) -> bool / gfx_end_frame(gfx) / gfx_set_present_mode
  (VSYNC/IMMEDIATE/MAILBOX, fallback vsync) / gfx_aspect_ratio /
  gfx_input(gfx) -> ^glove.System / destroy (libera recursos vivos dos pools
  + depth texture).
- PROIBIDO em gfx: Renderer, Scene, Model, Camera, Font, callbacks de game
  (Gfx_Game_*_Proc, gfx_render, gfx_update).
- resource_handle.odin: cópia fiel de cubes/src/gbbfx/resource_handle.odin
  (Resource_Handle{index, generation}, Buffer_Handle/Texture_Handle/
  Sampler_Handle distinct, Handle_Pool + acquire/contains/release/destroy).
- buffer.odin: Buffer{handle, length, size, usage, _staging_data: []byte,
  _data_submitted: bool} + gfx_buffer_create_from_bytes / gfx_buffer_stage /
  gfx_buffer_get / gfx_buffer_destroy — adaptado de
  cubes/src/gbbfx/buffer.odin renomeando _temporary_raw_data->_staging_data,
  _raw_data_is_submited->_data_submitted.
- texture.odin / sampler.odin: análogos, baseados em
  cubes/src/gbbfx/texture.odin e sampler.odin.
- uploader.odin: baseado em cubes/src/gbbfx/uploader.odin com DUAS correções:
  1. BUG do flush no cubes: itera up.pending e faz append(&up.pending, s) no
     mesmo slice — corrigir coletando em slice temporário e clear antes.
  2. API de download:
     - uploader_download_buffer_begin(up, source: ^sdl.GPUBuffer, byte_size: u32) -> Staging
     - uploader_download_texture_begin(up, source: ^sdl.GPUTexture, width, height: u32) -> Staging
     (criam transfer DOWNLOAD, copy pass própria se up.pass == nil, registram em pending)
     - staging_ready(up, staging) -> bool  (QueryGPUFence)
     - staging_read(staging) -> []byte     (MapGPUTransferBuffer)
     - staging_release(up, staging)        (Unmap + ReleaseGPUFence + ReleaseGPUTransferBuffer, volta pra free list)
- Estilo: variáveis locais >= 4 letras (exceção i/j/k/n/x para índices).
- Verificação: `odin check src/gfx` (se falhar por glove ausente, repetir
  uma vez quando glove existir; falha só por vendor:sdl3 de ambiente → reportar).

### C) package render_graph (src/render_graph/render_graph.odin)
- package `render_graph`; imports: apenas core:* (sem sdl/imgui/main).
- Portar de src/pipeline.odin (package main) a parte de dados/validação:
  - SgGraphJson/SgGraphNodeJson/SgGraphLinkJson -> Graph_Json/Node_Json/Link_Json
  - PIPELINE_SCHEMA_VERSION -> GRAPH_SCHEMA_VERSION (=1)
  - pipeline_graph_path -> graph_path; pipeline_endpoint -> endpoint
  - PipelineRoute -> Route{consumer: int, input_name: string, producer: int}
  - PipelinePlan -> Plan{order: [dynamic]int, routes: [dynamic]Route, output_pass: int}
  - plan_destroy / plan_equal / plan_path(plan, pass_count, max_passes)
    (DEBUG_WATCH_MAX_PASSES vira parâmetro; constante local PLAN_PATH_MAX_PASSES=8)
  - Pass_Descriptor :: struct { key, name: string, input_textures: [dynamic]string, output_pin: string }
  - plan_build(passes: []Pass_Descriptor, doc: ^Graph_Json) -> (plan: Plan, error_message: string, ok: bool)
    — portar FIELMENTE a lógica das linhas 112–211 do pipeline.odin
    (self-cycle, duplicate producer, input inexistente, endpoint "show2d:frame",
    topological sort, fallback, "pipeline has no viewport output").
  - plan_default(passes: []Pass_Descriptor) -> Plan (portar linhas 93–110).
- NÃO editar src/pipeline.odin (adapter fica para a onda 2).
- Verificação: `odin check src/render_graph`.

### D) Remoção partículas + som (package main)
- APAGAR src/fx_sound.odin inteiro.
- fx.odin: remover seção "Ink particles" (FxParticleKind, FX_MAX_PARTICLES,
  FxParticle, fx_particles, fx_alive, fx_last_mouse, fx_celebrate_pos,
  fx_burst, fx_particles_step, FX_SHADES, fx_spawn, fx_ring, fx_trail,
  fx_particles_draw) e comentários da seção. Manter: FxIntensity/
  FX_INTENSITY_NAMES, FxDevelopStyle/FX_DEVELOP_STYLE_NAMES, Fx (SEM campos
  `particles` e `sound`), fx_defaults (sem esses campos), fx_on,
  fx_grain_binding, Anim, anim_step.
- Call sites (remover linhas/branches; sem linhas mortas):
  - main.odin: 121 (fx_sfx_play .ZEN), 643-646 (bloco fx_settings/fx_sfx_init —
    fx_settings só existia para partículas/som; remover global também,
    que está declarada em fx_sound.odin), 1247 (.SAVE), 1292-1294
    (.SCENE_SWITCH sfx + fx_burst), 1499 e 1513 (.EXPORT).
  - app.odin: cases .PARTICLES (183-184) e .SOUND (189-190) do switch ToggleFx;
    fx_burst em 198.
  - ui.odin: 237-251 (fx_particles_step/draw + bloco cursor trail inteiro).
  - ui_sidebar.odin: 463-467 (checkbox ink particles), 475-479 (checkbox sound),
    502 (fx_burst).
  - ui_chrome.odin: 180 (fx_celebrate_pos = ...; manter ui.scene_sel_rect).
  - imgui_editor.odin: 163-171 campos type_burst (text_pos, line_h, char_w,
    type_burst_ns — manter os que outros usos citarem; verificar), função
    de typefx (guard 188-193, burst 200, sfx .TYPE 203): remover a função
    inteira e seus call sites.
  - imgui_nodes.odin: 1890-1896 (fx_trail).
  - scene_runtime.odin: 1238 (.BUILD_OK), 1240 (.BUILD_ERROR).
  - i18n.odin: remover entradas "ink particles" (es ~140, pt ~262) e
    "sound" (es ~169, pt ~290).
- Verificação: grep -rn "fx_sfx|fx_particle|fx_burst|fx_trail|fx_ring|fx_celebrate|FxParticle|FxSfx|fx_settings" src/ → vazio.

## Regras gerais
- Cada agente edita APENAS seus arquivos. NÃO rodar formatter/build geral.
- Odin em /opt/homebrew/bin/odin. Baseline: `odin check ./src` passa.
- Sem docs/README. Sem emojis.
