# Onda 2 — Integration (2 agentes paralelos, arquivos disjuntos)

Estado de entrada: src/glove, src/gfx (com uploader bidirecional), src/render_graph
existem; partículas/som removidos.

## Agente E — app integration
Arquivos: src/main.odin, src/shot.odin, src/model.odin, src/scene_runtime.odin,
src/hotreload.odin, src/window_macos.odin, src/camera.odin, src/fx.odin (só grain),
src/app.odin (só se necessário). NÃO tocar src/pipeline.odin nem src/imgui_nodes.odin
(agente F). Coordenar via hub se interface de pipeline mudar.

1. main.odin: substituir device/window/frame management manual (sdl.Init,
   CreateWindow, CreateGPUDevice, ClaimWindowForGPUDevice, depth texture,
   WaitAndAcquireGPUSwapchainTexture, acquire/submit, present mode) pelo
   package gfx: `gfx_state: gfx.Gfx`, `gfx.create(&gfx_state, "gis", 1280, 780)`,
   frame loop com gfx_begin_frame/gfx_end_frame, gfx_set_present_mode
   (IMMEDIATE quando benchmark), gfx_input(). Substituir uploads manuais
   (paper textures ~152-170, black fallback ~208-229, debug_watch_buffer) por
   gfx_texture_create_from_bytes / gfx_buffer_create_from_bytes + Uploader
   (uploader_begin/upload_*/flush_blocking). fx_grain_binding =
   rawptr(gfx_texture_get(&gfx_state, paper_handle).handle).
2. shot.odin: substituir os 3 readbacks DOWNLOAD+fence manuais (pixel inspector,
   debug watch readback submit/poll/destroy, export_png) por uploader_download_*
   + staging_ready/staging_read/staging_release. Manter semântica async.
3. model.odin: substituir transfer buffer manual (107-142) por
   gfx_buffer_create_from_bytes (vb+ib) + uploader_upload_buffer +
   uploader_flush_blocking (um copy pass único).
4. scene_runtime.odin: targets de pass continuam raw ^sdl.GPUTexture (pool gfx
   é para assets, não targets por cena). export_gif mantém readback existente.
   API camera_orbit intacta para call sites.
5. camera.odin: Camera struct estilo cubes/src/gbbfx/camera.odin
   (position/direction/up/right/yaw/pitch/projection; camera_create/rotate/
   set_aspect/view/view_projection) + camera_uniforms(camera, aspect) ->
   CameraUniforms. camera_orbit(yaw, pitch, aspect) vira wrapper: monta Camera
   temporária (posição na esfera raio DIST=2.6 olhando a origem) e chama
   camera_uniforms. Valores EXATOS preservados: DIST 2.6, FOV_SCALE 1.2,
   NEAR 0.5, FAR 5.0. Layout de CameraUniforms EXATO (view_projection [16]f32,
   position/right/up/forward [3]f32, col-major, NDC z [0,1]) — shaders não mudam.
6. font (abstração, SEM wiring no app — mesma política do resto do gfx):
   portar cubes/src/gbbfx/font.odin para src/gfx/font.odin (package gfx):
   Font/Font_Metric/Font_Quad/font_create/destroy/text_width/glyph_quad/
   layout. O atlas deve usar gfx_texture_create_from_bytes + Uploader (leia
   o corpo de font_create do cubes 41-98 e substitua o transfer buffer
   manual, se houver, pelo uploader). Nomes locais >= 4 letras. A UI do app
   NÃO passa a usar font — ImGui continua cuidando das fontes da UI; a
   abstração fica disponível. Verificar que `odin check src/gfx` segue limpo.
7. Verificação: `odin check ./src` — erros em pipeline.odin/imgui_nodes.odin

## Agente F — pipeline adapter + imgui_nodes
Arquivos: src/pipeline.odin, src/imgui_nodes.odin. NÃO tocar os do agente E.

1. pipeline.odin vira adapter fino sobre render_graph com aliases de tipo
   (mantêm assinaturas usadas por main/scene_runtime/imgui_nodes — zero diff
   nos call sites):
   ```
   PipelinePlan :: render_graph.Plan
   PipelineRoute :: render_graph.Route
   SgGraphJson :: render_graph.Graph_Json
   SgGraphNodeJson :: render_graph.Node_Json
   SgGraphLinkJson :: render_graph.Link_Json
   DEBUG_WATCH_MAX_PASSES :: render_graph.PLAN_PATH_MAX_PASSES
   ```
   pipeline_plan_build/load/default/equal/path/destroy/endpoint/graph_path
   delegam a render_graph, convertendo scene.passes -> []render_graph.Pass_Descriptor
   (key, name, input_textures = pass.sampler_textures, output_pin = campo real
   de ScenePass que guarda o nome do output — descobrir lendo scene_runtime.odin).
   pipeline_plan_build fica responsável por ler/parsear graph.json e montar o doc.
2. Remover de pipeline.odin toda lógica de validação/sort duplicada (agora é
   propriedade do render_graph).
3. imgui_nodes.odin: ajustar para os aliases (esperado zero-diff ou mínimo).
4. Verificação: erros no próprio escopo corrigir; erros em arquivos do E, reportar.

## Regras
- Variáveis locais >= 4 letras em código novo/editado (renomeação geral é onda 3).
- Sem formatter global. Sem docs.

## Notas da onda 1 (contratos entregues)
- render_graph.plan_path(plan, pass_count, max_passes) retorna []bool
  alocado com context.temp_allocator (PLAN_PATH_MAX_PASSES=8 é constante
  local do render_graph, não array fixo). pipeline_plan_path no adapter
  deve converter para o retorno [DEBUG_WATCH_MAX_PASSES]bool que os call
  sites esperam (manter assinatura é preferível).
- render_graph.graph_path(scene, scene_root) recebe a raiz como parâmetro
  (scene_root_dir é package main) — o adapter passa scene_root_dir(scene).
- gfx.staging tem campos device e usage (UPLOAD/DOWNLOAD; free list filtra
  por usage — transfer DOWNLOAD não é reutilizado para upload).
- gfx tem ainda gfx_poll_events (bomba de eventos) e gfx_request_quit.
- glove: testes em src/glove/tests (odin test) passam 5/5.
