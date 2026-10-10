# Decompor `main` (src/main.odin) em subsistemas

## Contexto

`main` tem 1240 linhas (239–1479) e mistura: parsing de CLI, init de janela/GPU/ImGui, carregamento de assets, criação de pipelines de blit, alvos offscreen, glue de readbacks de pixel/debug-watch/provenance, harnesses de self-test (`--pan-test`, `--pixel-test`, `--watch-test`, `--notify-test`, `--ied-test`, `--graph-test`), exportação (`--shot`, PNG, GIF), timing de frame, benchmark, lógica de transição develop/FX, câmera 3D e o loop com ~20 blocos inline.

Dois pontos de nomenclatura do pedido:
- O fence GPU (`pending_fence`, `fence_t0`) mede **tempo de geração de textura** (submit → conclusão GPU), exposto como `ui_state.gen_ms`. Não é FPS. FPS (`fps_ema`) é EMA do tempo de iteração do loop inteiro na CPU. Os dois são separados em `frame_timing.odin` e mantêm seus significados.
- `export_gif` está em `scene_runtime.odin`, não em `main`. Só o chamador está em `main`.

Estado final pretendido: `main` ≈ 15 linhas (parse de opções, init, loop `for host_frame(&h) {}`, shutdown). Comportamento idêntico; nenhuma flag de CLI removida.

## Approach

Ordem: passos 1–10 extraem sem mudar a estrutura de dados (estado continua em locais de `main`); cada passo deixa o build verde. Passo 11 agrupa locais em `Host`. Passo 12 quebra o loop em `host_frame`.

**1. `src/cli.odin` (novo).** `Options` struct com: `once, headless, force3d, force_color, start_mobile, start_graph, metrics, pixel_test, watch_test, pan_test, notify_test, ied_test, ied_debug_clicks, hover_debug, graph_test, benchmark_frames (int, 0=off), benchmark_warmup (60), benchmark_debug, start_scene (int), start_scene_name (string), shot_path (string), pixel_test_pos ([2]f32 = {400,300})`.
- `options_parse(args: []string) -> Options`: copia exatamente o `for` das linhas 263–359 (incluindo `--watch-test` que liga `pixel_test` e `watch_test`; `--graph-test` liga `start_graph` e `ing_selftest`; `--pan-test` liga `pan_test`, `pan_test_debug`, `start_graph`).
- `options_apply_globals(o: Options)`: atribui os globais que outros arquivos leem: `ied_debug_clicks`, `ied_selftest`, `hover_debug`, `show_metrics`, `pan_test_debug`, `ing_selftest`.
- `--graph-click-test`: hoje só seta `start_graph = true` e a variável local `graph_click_test` nunca é lida em `main`. Manter como alias de `--graph`; remover a variável local. Antes, `grep -rn "click_test" src/` para confirmar que nenhum global a lê; se ler, propagar para esse global em `options_apply_globals`.

**2. `src/benchmark.odin` (novo).** Mover `BenchmarkStats`, `benchmark_stats`, `benchmark_log` (main.odin 200–237) sem alteração.
- `Benchmark :: struct { frames, warmup: int, debug: bool, frame: int, cpu, gpu: [dynamic]f32 }`; `benchmark_init(o: Options) -> Benchmark`.
- `benchmark_active(b) -> bool` = `b.frames > 0`.
- `benchmark_wants_sample(b) -> bool` = `b.frame >= b.warmup && len(samples) < b.frames`. Usado para CPU e GPU (mesma condição de hoje).
- `benchmark_end_frame(b: ^Benchmark, cpu_ms: f32, scene_title: string) -> bool`: se `wants` → append CPU; `b.frame += 1`; se `len(cpu) >= frames && len(gpu) >= frames` → loga com `benchmark_log` (labels `"cpu mode=%s scene=%s"` / `"gpu ..."`, mode = `debug ? "debug" : "baseline"`) e retorna `true` (encerra). Caso contrário `false`.
- Presente imediato no startup (main 424–427): fica em `host_init` quando `benchmark_active`.

**3. `src/frame_timing.odin` (novo).**
- `Frame_Timing :: struct { start: u64, fps_ema, cpu_ms_ema: f32, initialized: bool }`.
  - `frame_timing_begin(t)`: `t.start = sdl.GetPerformanceCounter()`. Chamado na primeira linha do loop, antes de `free_all` (como hoje).
  - `frame_timing_elapsed_ms(t) -> f32`: `(now - start) / freq * 1000`.
  - `frame_timing_record(t, ui)`: lógica das linhas 1449–1460 (`measured_fps = frame_ms > 0 ? 1000/frame_ms : 0`; primeira amostra inicializa; depois `0.95/0.05`) escrevendo em `ui.fps_ema`, `ui.cpu_ms_ema`.
- `Gen_Timer :: struct { pending: ^sdl.GPUFence, t0: u64, initialized: bool }`.
  - `gen_timer_begin(t)`: `t.t0 = GetPerformanceCounter()` (antes do submit, linha 1188).
  - `gen_timer_track(t, fence)`: `t.pending = fence`.
  - `gen_timer_poll(t, gpu, ui) -> (sample: f32, ready: bool)`: se `pending != nil && QueryGPUFence` → `ReleaseGPUFence`, calcula `sample` (ms), `pending = nil`, EMA em `ui.gen_ms` (primeira amostra inicializa). Retorna `(sample, true)`. Chamador alimenta `benchmark.gpu` se `benchmark_wants_sample`.
  - `gen_timer_reset(t)`: `initialized = false` (troca de cena, hoje `gen_initialized = false`).
  - `gen_timer_wait(t, gpu)`: `WaitForGPUFences` + release + `pending = nil`, com o warn existente (caminho `--shot`, linhas 1253–1260).

**4. `src/shot.odin` (existente) recebe exportação.**
- Mover `GIF_FPS`, `GIF_DIR` (scene_runtime.odin 1493–1494) e `export_gif` (1684–1742) para `shot.odin`. Assinatura inalterada.
- Após remover, checar imports não usados em `scene_runtime.odin` (Odin falha com import não usado) e remover os que sobrarem.
- Adicionar `export_frame_png(uploader, scene_tex, w, h, title) -> bool`: `path := export_path(title, "png")`, `save_texture_png`, `log.infof("saved %s")` (linhas 1267–1271).
- Adicionar `export_shot(...)`: `save_texture_png(..., shot_path)` (linha 1261), usado pelo `--shot`.
- Cabeçalho do arquivo atualizado: "Frame export: PNG, GIF, --shot. Readback primitives live in inspect.odin."

**5. `src/blit.odin` (novo).** Mover `create_shader`, `link_pipeline`, `link_pipeline_format`, `create_pipeline` (main 45–128). Ler os corpos 45–128 antes de mover (não lidos nesta sessão; o corpo é elidido na leitura).
- `Blit :: struct { pipeline, develop_pipeline, pipeline3d: ^sdl.GPUGraphicsPipeline, sampler, preview_sampler: ^sdl.GPUSampler, preview_pipeline: ^sdl.GPUGraphicsPipeline }`.
- `blit_init(gpu, window) -> (Blit, bool)`: copia **na mesma ordem** o bloco 451–561 (blit, develop, blit3d com shaders liberados logo após `CreateGPUGraphicsPipeline`, blit_sampler NEAREST, preview_pipeline R8G8B8A8_UNORM, preview_sampler LINEAR). Mantém cada `free_blob_if_hot` e a segunda chamada `shader_glue.blit_vertex()` / `blit_fragment()` exatamente como estão (não deduplicar). Mantém as mensagens `log.error*` atuais.
- `blit_destroy(gpu, b: ^Blit)`: `ReleaseGPUGraphicsPipeline`/`ReleaseGPUSampler` com guarda `!= nil`.
- `blit3d_camera(yaw, pitch, dist, aspect) -> shader_glue.Blit3dVertexCamera`: math de 1312–1337 (origin `{0,0.15,0}`, fovTan 0.577, nearZ 0.1, farZ 30) sem alteração.
- `blit_draw_3d` / `blit_draw_2d`: NÃO extrair ainda; o bloco de present fica em `frame.odin` (passo 12) e chama `blit` structs.

**6. `src/targets.odin` (novo).**
- `PREVIEW_SIZE :: 128`.
- `Render_Targets :: struct { scene: ^sdl.GPUTexture, depth: ^sdl.GPUTexture, passes, previews: [dynamic]^sdl.GPUTexture, w, h: i32 }`.
- `create_scene_target(gpu, w, h)` (main 170–184) movido para cá.
- `targets_needs_resize(t, w, h, pass_count) -> bool`: `scene == nil || t.w != w || t.h != h || len(passes) != pass_count`.
- `targets_resize(t, gpu, w, h, pass_count) -> bool`: mesma ordem de 856–911: release scene → create scene; release+clear passes → create `pass_count`; release+clear previews → create `pass_count+1` com `PREVIEW_SIZE`; release depth → create `D32_FLOAT`; `t.w, t.h = w, h`. Cada falha: `log.errorf` igual ao atual e `return false`.
- `targets_destroy(gpu, t)`: libera scene, depth, passes e previews com guarda `!= nil`. (Hoje não libera scene/depth/previews no shutdown; `DestroyGPUDevice` os cobre. Liberar explicitamente é aceitável.)

**7. `src/assets.odin` (novo).**
- `Assets :: struct { paper_textures: [2]gfx.Texture_Handle, paper_sampler: ^sdl.GPUSampler, skybox_names: [dynamic]string, skybox_textures: [dynamic]gfx.Texture_Handle, black_texture: gfx.Texture_Handle, models: [dynamic]Model, model_names: [dynamic]string }`.
- `load_texture` (main 130–168) e `create_black_texture` (186–195) movidos para cá.
- `PAPER_PATHS :: [2]string{"assets/watercolor_paper.jpg", "assets/parchment.jpg"}`. Remover `paper_names` (local morto, linha 646).
- `assets_load(a, gfx_state, gpu) -> bool`: paper textures (648–656, `return false` em falha → chamador loga como hoje), skybox scan (658–681, mesma lógica de nome e `warnf`), `create_black_texture`, `model_load_all` + checagem `len==0 || models[0].vb == nil` (686–690), `paper_sampler` (693–707).
- `assets_destroy(gfx_state?, a)`: NÃO liberar texturas aqui (são do `gfx.destroy`). Só libera o `paper_sampler`, arrays dinâmicos e `model_names`.
- `model_names`: confirmar com `grep -rn "model_names" src/` se ui lê; se não, remover.

**8. `src/inspect.odin` (novo).** Mover de `shot.odin` linhas 12–169 (tipos `PixelReadback`, `PassPixelReadback`, `DebugWatchSample`, `DebugWatchReadback`, constantes `DEBUG_WATCH_*` e funções `*_begin/_poll/_cancel`). Remover esses itens de `shot.odin` (que fica com export, passo 4).
- `Inspector :: struct { pixel: PixelReadback, watch: DebugWatchReadback, provenance: PassPixelReadback }`.
- `inspector_cancel_pending(ins, uploader)`: cancela cada um se `pending` (mesmas condições de 851–853 e 1466–1468).
- `inspector_on_resize(ins, ui)`: zera `ui.pixel_inspect_pending`, `ui.debug_watch_pending` (linhas 854–855; não mexe em `valid`/`request`).
- `inspector_on_scene_change(ins, ui, uploader)`: cancela pendentes (1029–1031) e zera campos de 1032–1040 exatamente como estão.
- `inspector_poll(ins, ui, uploader) -> (pixel_ready, watches_ready, prov_changed, prov_complete: bool)`: lógica de 771–824 que **atualiza `ui`**. Sem logs; logs vão para `selftest.odin`.
- `inspector_request_scene_debug(ins, ui, scene, scene_tex, resources, w, h, watch_buffer, frame)`: linhas 1206–1231 (watch readback begin + provenance begin + flags).
- `inspector_request_pixel(ins, ui, scale, uploader, scene_tex, w, h)`: linhas 1232–1247.
- `inspector_destroy(ins, uploader)`: linhas 1465–1468 (pass_tex release fica no `targets_destroy`).

**9. `src/selftest.odin` (novo).** Concentra todos os harnesses.
- `Selftest :: struct { pixel, watch, pan, notify: bool, pixel_pos: [2]f32, watches_ready: bool, pan_frame, notify_frame: int }`; `selftest_init(o: Options) -> Selftest`.
- Startup, antes da janela (chamado logo após `i18n_init`): se `notify` → três `notify(...)` (369–373).
- Startup, após `ui_init`/editor: `pan` → `editor.open = false` (629); `start_graph` → `ui.mode = .GRAPH`, `editor.open = false`, `ui.graph_max = true` (631–635); `ied_test` → `editor.open = true` (636); `start_mobile` → `emit(ToggleMobile{})` (637); `ing_selftest` → criar `graph.scene`, `sg_create_pass` COMPUTE e GRAPHICS (638–642). Como hoje, `ing_selftest` depende de `editor`, `graph` existirem.
- `selftest_request_pixel(st, ui)`: se `pixel && !pending && !valid` → `request_pos = pixel_pos`, `request = true` (1062–1065).
- `selftest_pan_inject(st, io, window_size)`: linhas 919–933 (posição fake + wheel 10..40).
- `selftest_notify_tick(st, dt)`: linhas 1072–1080 (re-dispara a cada 60 frames) + `notify_draw` é chamado pelo chamador.
- `selftest_on_pixel(st, ui) -> quit: bool`: se `pixel`: loga `[pixel-test] ...` (785–791); retorna `!watch` (quit se não for watch-test).
- `selftest_on_watches(st, ui, scene)`: se `watch`: loga `[watch-test] ...` com labels de `scene.passes[...].debug_watch_labels` (800–816); seta `watches_ready = true`.
- `selftest_on_provenance(st, ui, prov: ^PassPixelReadback, scene) -> quit: bool`: se `watch && watches_ready`: loga `[provenance-test] ...` (825–836); retorna `true` (quit).
- Mantém a ordem: pixel-test sai do loop com `break main_loop` somente quando `!watch_test`.

**10. `src/fx.odin` (existente) recebe `Develop`.**
- `Develop :: struct { t: f32, prev_scene: int }`; `develop_init() -> Develop { t = 1, prev_scene = -1 }`.
- `develop_on_scene_change(d, fx: ^Fx, scene_index: int) -> bool`: copia 1050–1059 (`if prev < 0 → prev = index`; se mudou: `prev = index`, `if fx_on(fx) && fx.develop → t = 0`; retorna `changed`). Chamador faz `input_ctx.model_orbiting=false`, `set_title`, `gen_timer_reset`, `inspector_on_scene_change`.
- `develop_request(d, fx)`: `if fx_on(fx) && fx.develop → t = 0` (1020–1023, Cmd `.DEVELOP`).
- `develop_step(d, dt, intensity: FxIntensity)`: `if t < 1 { dur = intensity == .FULL ? 1.0 : 0.7; t = min(1, t + dt/dur) }` (1092–1095).
- `develop_variant(fx, rand) -> i32`: RANDOM → `rand.int_max(3)`, senão `i32(style) - 1` (1368–1373).
- Comportamento `develop_t` idêntico ao atual.

**11. `src/host.odin` (novo): `Host` e ciclo de vida.**
- `Host :: struct` agrupa TODO estado local de `main` que hoje é inicializado em 403–744 e usado no loop: `options`, `selftest`, `benchmark`, `gfx: gfx.Gfx`, `inputs: glove.System`, `input_pump: glove_sdl.Pump`, `input_ctx: Input_Context`, `scene_mgr: SceneManager`, `ui: ^Ui`, `editor: ^ImGuiEditor`, `graph: ^NodeGraph`, `application: App`, `blit: Blit`, `targets: Render_Targets`, `inspector: Inspector`, `assets: Assets`, `develop: Develop`, `timing: Frame_Timing`, `gen: Gen_Timer`, `app_time: f32`, `prev_ticks: u64`, `previous_interaction: InteractionMode`, `mobile_geo: [4]i32`, `imgui_ready: bool`, `headless: bool`, `skybox...` (fica em `assets`).
- `host_init(h: ^Host, o: Options) -> bool`: ordem exata de `main`:
  1. `sdl.SetAssertionHandler` + `g_sdl_context = context` (396–398).
  2. `gfx.create(&h.gfx, "gis", 800, 600)` (403–407); `user_assets_set_gfx`; `defer`-free: o chamador registra `defer host_destroy(h)` **logo após** `host_init` retornar true; em falha parcial, `host_init` chama `host_destroy` ele mesmo (ver contingência).
  3. `glove.system_create(glove_sdl.create())`, `pump_seed_window` (414–417).
  4. `SetWindowMinimumSize` se `!headless` (418–423); presente imediato se `benchmark_active` (424–427).
  5. `scene_rescan` (430–434); `--scene <name>` (438–447).
  6. `set_title` (449 e 750) — ver item "não verificado" abaixo.
  7. `blit_init` (451–561).
  8. `ui_init()`; `force3d`, `pixel_test`, `force_color` → flags (563–566).
  9. Se `!headless`: `im.CHECKVERSION`, `CreateContext`, fonte JetBrainsMono (576–580), `ui_apply_style`, `im_sdl.InitForSDLGPU`, `im_sdlgpu.Init` (570–590); `imgui_ready = true`. `ied_init`/`ing_init` (594–597).
  10. `App{ui, sm = &scene_mgr, ed, ing, win}` (601–607); `Input_Context{...}` (611–620); `input_bindings_init` (621); `pump_set_forwarder(imgui_forward_event)` se `!headless` (622–626).
  11. `selftest_after_ui_init` (passo 9).
  12. `assets_load` (644–707); `fx_grain_binding = rawptr(gfx.gfx_texture_get(&gfx, assets.paper_textures[0]).handle)` (712).
  13. `ui.time = &h.app_time`; `previous_interaction = ui.params.interaction`; `prev_ticks = sdl.GetTicks()` (752–754, 728).
  14. `ui_init` params: `view3d`, `pixel_inspect_enabled`, `color` (564–566).
- `host_destroy(h)`: nil-guarded, ordem inversa: `inspector_destroy`, `targets_destroy`, `blit_destroy`, `assets_destroy`, se `imgui_ready`: `ite_destroy(editor.handle)`, `ine_destroy(graph.handle)`, `im_sdlgpu.Shutdown`, `im_sdl.Shutdown` (1469–1474); `gfx.destroy(&h.gfx)`; `glove.system_destroy(&h.inputs)`.
- `main` final:
  ```
  main :: proc() {
      h: Host
      o := options_parse(os.args[1:])
      options_apply_globals(o)
      context.logger = log.create_console_logger(.Info)
      i18n_init()
      selftest_before_window(o)
      MEM_TRACE block (378–391), inalterado
      if !host_init(&h, o) do return
      defer host_destroy(&h)
      for host_frame(&h) {}
      log.info("Exiting")
  }
  ```
  A ordem de defers do MEM_TRACE é preservada: o defer de tracking é registrado antes e roda por último.

**12. `src/frame.odin` (novo): `host_frame(h: ^Host) -> bool` (retorna `false` para sair do loop).** Sequência, cada passo chamando um proc já criado acima:
  1. `frame_timing_begin`; `free_all(context.temp_allocator)`.
  2. `scene_poll`; `pipeline_scene_refresh`; `pipeline_scene_reload` (766–770).
  3. `inspector_poll`; `selftest_on_pixel` → `false` se quit; `selftest_on_watches`; `selftest_on_provenance` → `false` se quit (771–836). Ver nota de `break main_loop` em `selftest`.
  4. `if len(scenes) == 0 → return false` (838).
  5. `glove_sdl.pump_poll`; `glove.quit_requested → false`; `pixel_size` (841–846).
  6. Se `targets_needs_resize`: `inspector_cancel_pending`, `inspector_on_resize`, `targets_resize`; falha → `false` (848–911).
  7. Se `!headless`: `im_sdlgpu.NewFrame`, `im_sdl.NewFrame`, `selftest_pan_inject`, `im.NewFrame`, captures (`set_captures`), feed do grafo (`ing_pass_tex` … `ing_n_passes`, 945–952), `ui_build`, `ied_open_scene`, `ied_tick`, `ied_frame` (916–959).
  8. `if !headless → glove.dispatch`; `if input_ctx.quit → false` (963–964).
  9. Drenar mensagens: `cmds := host_drain(h)` (`msg_buf`/`update` em loop, 971–979); `quit, export := host_interpret(h, cmds)` (980–1025). `if quit → false`.
  10. Troca de cena solicitada: `requested := scene_mgr.current`; `inspector_on_scene_change` se mudou; `scene_ensure_loaded` ou rollback (1027–1045).
  11. Bookkeeping de troca: `if develop_on_scene_change(...)` → `input_ctx.model_orbiting=false`, `set_title`, `gen_timer_reset`, `if fx_on && develop → develop_t = 0` (já coberto por `develop_on_scene_change`) (1047–1059).
  12. `selftest_request_pixel`; `current := scene_mgr.current` (1062–1066).
  13. Se `!headless`: `if show_metrics → im.ShowMetricsWindow`; `selftest_notify_tick`; `notify_draw(dt)`; `im.Render()` (1067–1082).
  14. `ticks`, `delta_time`, `app_time += dt` se `!paused`, `develop_step` (1084–1095).
  15. Interação: `if previous != current → input_on_interaction(&input_ctx, ui, app_time)` (1099–1106). Esta função contém a lógica de `model_yaw/model_pitch/model_orbiting` (1100–1105); deve ir para `input_bindings.odin`.
  16. `input_frame(...)`; `mouse_pos`, `mouse_click`; `camera_for_frame(ui, input_ctx, app_time, aspect)` (1108–1120). Esta função vai para `camera.odin`, ao lado de `camera_orbit`.
  17. Debug watch buffer: `ensure` (1122–1133); `debug_enabled`, `debug_pixel_top` (1135–1139); `scene_write_uniforms` (1140–1150).
  18. Gen timer: `if sample, ok := gen_timer_poll(...); ok && benchmark_wants_sample → append gpu` (1152–1170).
  19. `resources := SceneResources{...}` (1173–1184).
  20. `gen_timer_begin`; `submit_scene_frame`; `gen_timer_track`; falha → `false` (1186–1205).
  21. `if ui.debug_watch_request → inspector_request_scene_debug` (1206–1231); `if ui.pixel_inspect_request → inspector_request_pixel` (1232–1247).
  22. `if shot_path != "" → gen_timer_wait; export_shot; return false` (1253–1263). Mantém a ordem: `wait` antes de salvar.
  23. `#partial switch export`: `.PNG → export_frame_png`, `.GIF → export_gif(...)` (1266–1285).
  24. Present (1287–1423): `host_present(h, width, height, swapchain flags)` é um proc novo em `frame.odin`: `gfx_begin_frame` (falha → `log.errorf` + retorna `false`); `defer gfx_end_frame`; se `swapchain != nil`: branch `view3d` (`blit3d_camera` + `BeginGPURenderPass` com depth, push uniforms, bind samplers, `DrawGPUPrimitives(6*256*256)`) ou branch 2D (develop se `develop_active`, senão blit; `DrawGPUPrimitives(3)`); ImGui pass se `!headless` (1301–1421). `defer` garante que `gfx_end_frame` roda antes de `latency_report` (como hoje, linha 1423).
  25. `latency_report()` (1425).
  26. Benchmark: `if benchmark_active && benchmark_end_frame(&h.benchmark, frame_timing_elapsed_ms, title) → false`; `if benchmark_debug → ui.pixel_inspect_valid = true; pixel_x/y = width/2, height/2` (1426–1443). Nota: `benchmark_debug` deve rodar **antes** de `benchmark_end_frame` para manter o `frame` consistente; conferir pela ordem de 1433–1443.
  27. `frame_timing_record(&h.timing, ui)` (1449–1460).
  28. `if once → false` (1461). Retorna `true`.
- `host_drain(h) -> Cmds`: `for msg_count > 0 { … update(&application, message) }` (app.odin); retorna `cmds`.
- `host_interpret(h, cmds) -> (quit: bool, export: ExportRequest)`: `switch` 980–1025 com os mesmos efeitos. `MOBILE_ENTER/EXIT` (989–1009) viram `mobile_enter(h)` / `mobile_exit(h)`, com `mobile_geo` no `Host`. `SAVE_ALL` → `ied_save_all` + `ui.save_flash = 1`. `QUIT` → `inspector_cancel_debug_watch` (cancela `debug_watch_readback` se pending e zera `ui.debug_watch_pending/sampled`) e `quit = true`. `DEVELOP` → `develop_request`. `EXPORT_PNG/GIF` → `export = .PNG/.GIF`.
- Atualizar o comentário de `app.odin` (linha 6: "interpreter in main.odin") para apontar `frame.odin: host_interpret`.

**Remoções obrigatórias (locais mortos/inúteis hoje):** `paper_names` (646), `preview_scene_tex` (725), `frame_ok` (1292), `graph_click_test` (245/351, passo 1), `pixel_scene_uv` não é morto (usado no pixel), não remover.

## Arquivos críticos e âncoras

- `src/main.odin` 239–1479: fonte de todos os blocos. Reler cada faixa antes de mover; números são de leitura desta sessão.
- `src/scene_runtime.odin` 1493–1494 e 1684–1742: `GIF_*` e `export_gif` vão para `shot.odin`. Checar imports não usados depois.
- `src/shot.odin` inteiro: readbacks saem (passo 8), export fica (passo 4).
- `src/app.odin` 95–187 (`update`) e 6 (comentário do interpretador): `update` não muda; só o comentário.
- `src/input_bindings.odin` 94–127 (`input_frame`) e 1099–1106 de main (interação): destino de `input_on_interaction`.
- `src/fx.odin` 35–55: destino de `Develop`.

## Verificação

Antes de qualquer edição: `glob src/shaders/scenes/*` para escolher dois cenas (um de passo único, um multi-pass). Nomes exatos vêm da listagem, não do comentário em `scene_runtime.odin`.

1. **Baseline:** antes do passo 1, build do estado atual e cópia do binário:
   `odin build ./src -out:/tmp/main_base -debug -define:HOT_RELOAD=true`
   Se `vendor/ImGuiColorTextEdit/libite.a` faltar, `make vendor/ImGuiColorTextEdit/libite.a` primeiro.
   Nota: `make run`/`make debug` dependem do alvo `shaders-hot`, que não aparece no Makefile lido; usar o `odin build` acima. Confirmar com `make -n run` antes de afirmar que o Makefile funciona.
2. **Build verde após cada passo:** o mesmo `odin build`. Sem novos warnings de import/variável não usada.
3. **Shot determinístico, headless:** `/tmp/main_base --once --headless --scene <A> --shot /tmp/base_A.png` e o mesmo com o binário novo → `md5sum` igual. Repetir para o cena B. Critério de sucesso: hashes idênticos. Se não forem idênticos por fonte de não determinismo já existente, comparar visualmente os dois PNGs e registrar.
4. **Harnesses de self-test** (cada um com `--once` quando aplicável; comparar stdout sem timestamps com `diff`):
   - `--pixel-test 400 300` → linha `[pixel-test] pixel=...`.
   - `--watch-test 400 300` → linhas `[watch-test]` e `[provenance-test]`; processo sai sozinho.
   - `--benchmark 60` → linhas `[benchmark] cpu mode=baseline ...` e `gpu ...` no mesmo formato.
   - `--ied-test`, `--graph-test`, `--pan-test`, `--notify-test`, `--mobile`: iniciar com `timeout 10`, verificar que sobe sem panic e que `Exiting` aparece ao fechar/timeout. Para `--pan-test` observar que o log `pan_test_debug` continua saindo.
5. **Vazamentos:** build com `-define:MEM_TRACE=true` antes e depois, `--once`; contar linhas `LEAK:`. Não pode aumentar.
6. **Dono único por conceito (grep):** `grep -rn "gen_ms\|fps_ema\|cpu_ms_ema" src/` → só `frame_timing.odin` escreve. `grep -rn "export_gif\|export_path\|save_texture_png" src/` → só `shot.odin` define. `grep -rn "create_pipeline\|load_texture\|create_scene_target\|benchmark_log" src/` → definições só nos arquivos novos.
7. **Tamanho:** `main` com ≤ 20 linhas de corpo; `host_frame` ≤ ~120 linhas (a seção de present é o maior bloco e pode ser um proc separado, conforme passo 12.24).
8. **Manual (não automatizável aqui; reportar como não verificado se não for feito):** troca de cena com transição develop; botões PNG e GIF do painel EXPORT (arquivo em `exports/`); clique do pixel inspector; toggle 3D; F4 mobile; F3 theater.

## Premissas e contingências

- Comportamento idêntico. Sem features novas. Nenhuma flag de CLI removida; `--graph-click-test` continua como alias de `--graph` (estado atual).
- Dev harnesses (`--pan-test`, `--pixel-test`, `--watch-test`, `--ied-test`, `--graph-test`, `--notify-test`, `--benchmark`, `--shot`) são mantidos: são a única verificação automatizada disponível e outros módulos leem seus globais.
- `Host` é alocado uma vez em `main` (`h: Host`) e **nunca copiado**. Ponteiros para campos de `h` são registrados em glove (`&h.input_ctx` como user_data), em `ui.time` (`&h.app_time`) e no `App`. Copiar `Host` por valor quebra esses ponteiros silenciosamente. Se for preciso passar `Host` a uma proc, usar `^Host`.
- Early-return leak: hoje, os `return` de init (ex.: falha de `blit3d_pipeline`) não chamam `gfx.destroy`. O novo `host_init` registra o teardown desde o começo: em falha parcial, `host_init` chama `host_destroy(h)` antes de retornar `false`. Todas as liberações são nil-guarded. Esta é a única mudança de comportamento intencional (menos vazamento em falha de init).
- Contingência: se a extração de `blit_init` mudar a ordem de `free_blob_if_hot` e causar double-free, restaurar a ordem original linha a linha. Não tentar "consertar" a duplicação de `blit_vertex()`.
- Contingência: se `inspector_poll` mudar a ordem de logs em relação a atualização de `ui`, restaurar a ordem original antes de seguir.
- Passo 0 (antes de qualquer mudança): `odin build ./src -out:/tmp/main_base -debug -define:HOT_RELOAD=true` no estado atual. Registrar o resultado. Se falhar, o erro é o primeiro item a corrigir, não parte da refatoração.
- `set_title`: declarado como local em main.odin:744 e chamado em :449, antes da declaração. Inferência (não compilada): Odin só enxerga local após a declaração, então :449 não compila. Confirmar no passo 0; se compilar, a decisão continua válida por clareza. Decisão: mover para proc de pacote `set_window_title(window, title)` em `host.odin` (passo 11); manter as duas chamadas (startup e troca de cena) apontando para ela.
- Locais só escritos, nunca lidos: `graph_click_test` (:245, :351), `paper_names` (:646), `preview_scene_tex` (:725), `model_names` (:691–692), `frame_ok` (:1292). Decisão: deletar todos. Odin rejeita local não usado; se o passo 0 acusar algum deles, confirma a remoção.
- Corpos lidos (main.odin:45–128): `create_shader`, `link_pipeline`, `link_pipeline_format`, `create_pipeline`. `create_pipeline` já faz `defer free_blob_if_hot` nas duas glues. Decisão: `blit_init` chama `create_pipeline` para blit e develop sem liberar blobs de novo; liberar blobs de blit3d e preview apenas nas linhas 483–484 e 538–539 (já existentes). Não há double-free se essa divisão for mantida.
- Risco registrado, sem mudança de ordem: main.odin:767–781 indexa `scenes[current]` antes do guard `len(scenes) == 0` (:838). Implementação mantém a ordem; não corrigir nesta refatoração.
- `model_names` e `paper_names`: confirmados sem leitura (grep acima); deletar conforme decisão acima.
