# gis — Arquitetura e Funcionamento

Documento de mapeamento interno da aplicação (gerado por leitura do código,
2026-10-14). O README cobre features para o usuário; este documento cobre
**como o código funciona**: subsistemas, ciclo de vida, fluxos de dados e as
decisões de design que os sustentam.

## Visão geral

`gis` (Gobbi Interactive Shaders) é um ambiente desktop de live-coding de
shaders em Odin + SDL3 GPU. A ideia central: **cenas são dados, não código**.
Cada pasta em `src/shaders/scenes/` com um `.slang` é uma cena descoberta em
runtime; o app gera um manifest do goose sob demanda, roda `goose-build`
(slangc) em uma worker thread, interpreta a reflexão JSON e monta os pipelines
SDL GPU dinamicamente — nenhum shader de cena é compilado dentro do binário.

- **Linguagem**: Odin (`dev-2026-08+`), ~18.4k linhas em `src/`
- **GPU**: SDL3 GPU API (Metal no macOS; SPIR-V/Vulkan no Linux/Windows)
- **UI**: Dear ImGui (vendored) + imnodes (node editor) + ImGuiColorTextEdit
  (editor de código) + md4c (markdown)
- **Compilação de shaders**: goose (repo irmão `../goose`) + slangc/slangd
  vendored em `vendor/slang/`
- **Alvos**: `make` (baked: Metal + SPIR-V) e hot-reload (só o alvo do host —
  `SCENE_TARGET`: `metal` no Darwin, `spirv` caso contrário)

## Estrutura do repositório

```
src/
  main.odin            entry: options → host_init → loop host_frame → destroy
  host.odin            Host struct + lifecycle + host_present (blit/UI)
  frame.odin           host_frame: as 28 fases do frame, em ordem fixa
  app.odin             arquitetura Elm: Msg/update/Cmd/interpret
  scene_runtime.odin   descoberta, build assíncrono, reflexão, pipelines
  render_graph/        algoritmos do grafo (validação, DAG, rotas)
  pipeline.odin        adapter graph.json ↔ runtime; assets de usuário
  imgui_nodes.odin     node editor (imnodes): pins, layout, gestos
  imgui_editor.odin    editor de código (ImGuiColorTextEdit + slangd LSP)
  lsp.odin             cliente LSP mínimo (stdio, JSON-RPC)
  inspect.odin         readback GPU→CPU (pixel, watches, provenance)
  blit.odin            pipelines de apresentação (2D/3D/preview)
  frame_timing.odin    telemetria de frame
  selftest.odin        harnesses --*-test
  cli.odin             options_parse (todos os flags)
  ui*.odin             sidebar (activity bar), chrome, i18n
  md_learn.odin        renderer markdown do painel LEARN
  scene_templates.odin templates "+ new" (compute/2D/3D)
  hotreload.odin       semântica de ownership do blob (baked vs runtime)
  glove/               input (keymap, ações, adapters SDL)
  gfx/                 wrapper SDL GPU (handles com geração, uploader)
  shaders/             infra shaders (blit, blit3d, develop) + common
  shaders/scenes/      o corpus de cenas (uma pasta por cena)
  generated/           artifacts do goose (baked: blit/blit3d/develop)
  generated/scenes/    artifacts das cenas (gitignored; build em runtime)
gis_scenes/            cenas do usuário (fora da árvore do repo)
vendor/                slang, odin-imgui, ImGuiColorTextEdit, imnodes, md4c
artefacts/             docs de produto/design, paper, benchmarks
```

## Ciclo de vida

```
main.odin
  options_parse (cli.odin) → i18n_init → selftest_before_window
  host_init (host.odin)
    gfx.create (janela + GPU device)
    glove input system (pump SDL)
    scene_rescan → catálogo de cenas; compile SOMENTE a cena inicial
    blit_init, targets, inspector, assets, UI, editor, node graph
  for host_frame(&h) {}   ← frame.odin
  host_destroy
```

### O frame (frame.odin, 28 fases numeradas)

Ordem fixa, comentada no próprio código. Resumo das fases críticas:

1. **Reset do temp allocator** — todo `tprintf`/scan/JSON do frame aloca no
   temp; sem o `free_all` por frame, "memory keeps climbing". Strings
   persistidas são clones, nunca temp.
2. **Hot-reload** — `scene_poll` (veja abaixo), bloqueado durante captura GIF.
3. **Readback polls** — pixel inspector, watches, provenance; selftests
   consomem os resultados.
5. **Input pump** — um `pump_poll` por frame; ImGui captura teclado/mouse
   (WantCapture*) e glove respeita os captures. Quit passa por guarda de
   trabalho não salvo; sair salva o `graph.json` primeiro (posições dos nós
   só autosavam em troca de cena ou tick de 600 frames).
7. **ImGui frame** — `ui_build` constrói os widgets (emitem Msgs);
   `ied_tick` roda o editor (LSP sync, diagnósticos); previews dos nós
   apontam para `targets.previews` (frame anterior, downsampled).
9. **Msg drain → Cmd interpret** — o núcleo da arquitetura Elm (abaixo).
10–11. **Troca de cena** — drop de readbacks obsoletos, `scene_ensure_loaded`
   com rollback para a cena anterior se a nova falhar.
20. **Submit da cena** — `submit_scene_frame`: um command buffer, passes na
   ordem do `Plan` (topológica), cada pass lê o alvo do produtor pela rota.
   Timed por fence (`gen_timer`) — o tempo de geração vira EMA na UI.
21. **Readbacks** — pedidos de pixel/watch enfileirados APÓS o submit.
22–23. **Exports** — `--shot` espera o fence (evita frame preto no --once);
   PNG/GIF baixam a `scene_tex` do frame corrente.
24. **Present** — blit da cena para a swapchain (2D) ou pass 3D com depth
   (heightfield), depois overlay ImGui.
25. **Latency report** — `[latency] edit->pixel: N ms` (build request →
   primeiro frame submetido; mediana ≈0.69 s no M4).

## Arquitetura de aplicação: Elm incremental (app.odin)

Tudo que pode acontecer no app é um `Msg`; todo `Msg` é aplicado em exatamente
um lugar (`update`); a view (`ui_build`) emite mensagens em vez de mutar
estado. Efeitos que tocam OS/filesystem/GPU são `Cmd`s (bit_set) executados
pelo interpretador (`host_interpret`), nunca por widgets.

```
widgets (ui_build) ──emit(Msg)──▶ msg_buf [64/frame]
                                   │ host_drain
                                   ▼
              update(app, msg) ─▶ Cmds (estado puro muda aqui)
                                   │ host_interpret
                                   ▼
        efeitos: QUIT, MOBILE_*, SAVE_ALL, EXPORT_PNG/GIF, DEVELOP
```

Adicionar uma feature = novo variante `Msg` + um `case` no `update` + view
emitindo. O buffer é de 64 mensagens por frame (cap fixo, além do uso real).

## Runtime de cenas (scene_runtime.odin)

### Modelo de dados

```
SceneManager ─ scenes: [dynamic]RuntimeScene, current: int
RuntimeScene ─ title, source, mtime, loaded, user_owned
               passes: [dynamic]ScenePass
               widgets: [dynamic]UiWidget   ← mesclados da reflexão
               pipeline: PipelinePlan       ← ver render_graph
               pipeline_error: string
ScenePass ── name, graph_key, kind (COMPUTE|GRAPHICS)
             compute|graphics: ^sdl.GPUPipeline
             sampler_textures/names (bind por nome)
             cbuffers (offsets, block bytes, presença por stage)
             debug_watch_labels[8], uses_model, vertex_attrs
```

Uniforms nomeados `iResolution/iTime/iFbm/iColorMode/iManual/iMousePos/...`
são preenchidos pelo app; campos com atributos `[UiSlider]/[UiToggle]/
[UiColor]` (definidos em `common.slang`) viram widgets no sidebar, valores
fan-out para os cbuffers por nome de campo.

### Descoberta e build assíncrono

- `scene_poll` (a cada frame): aplica builds prontos (`scene_build_pump`) e,
  a cada `SCENE_POLL_INTERVAL_MS = 100ms`, escaneia o disco: drop de cenas
  removidas, add de novas, mtime da cena ativa, e mtimes dos módulos
  compartilhados (`common, space, camera, noise, sdf`) — mudança em módulo
  dispara rebuild da cena ativa e limpa o registro de falhas.
- **Worker thread dedicada** (`scene_build_worker`): `scene_poll` só PEDI o
  build; a worker executa goose-build (process exec + IO). Pedidos durante um
  build coalescem (`scene_build_again`). Guardas de corrida:
  - `scene_applying` + cond: o build espera o reload terminar de ler os
    artifacts (senão o pump parseia JSON meio escrito).
  - `scene_failed: map[nome]mtime`: cena quebrada só é re-tentada quando o
    source muda de novo (senão o build falho re-roda todo frame).
  - A worker tem temp_allocator próprio + `free_all` por build (senão
    sessions longas inflam).
- `scenes_build` (na worker): escreve
  `src/generated/scenes/manifest.json` (`targets: [SCENE_TARGET]`,
  `commonUniforms: true`, entry + módulos como `cena__modulo`), serializa
  builds entre instâncias via lockfile O_EXCL (`.build.lock`, stale > 1min é
  tomado), roda `../goose/goose-build --manifest ... --slang vendor/slang/bin/slangc`.
  Erros do slangc → `build_errors_parse` (mutex) → squiggles no editor.

### Reflexão → pipeline

`scene_reload` parseia `<artifact>.refl.json` (mesmo schema CLI do Slang que
o goose emite): kind do param, `binding.used`, slots por stage, threadGroupSize
(default `{8,8,1}`), vertex attrs (`varyingInput`), campos de cbuffer. De lá
saem pipelines SDL GPU, contagens de recursos, widgets e os pins do node
editor. **A reflexão é a autoridade das interfaces; graph.json é autoridade do
roteamento.**

### Hot reload com preservação de falha

Build quebrado NUNCA apaga a tela: o pipeline anterior fica ativo e o erro
volta como anotação no editor (`build_errors_version` para caching das camadas
de UI). Save → watcher (100ms) → build assíncrono → pump aplica no frame →
pipeline swap → `latency_report`.

## Node graph: render_graph + pipeline + imgui_nodes

Três camadas com papéis separados:

1. **`render_graph/render_graph.odin`** (puro, sem SDL): tipos JSON
   (`Graph_Json`, `Node_Json`, `Link_Json`, `GRAPH_SCHEMA_VERSION = 1`),
   validação (ciclos, produtores duplicados, outputs ausentes, endpoints
   incompatíveis), eleição de output pass, ordenação estável do DAG
   (`Plan.order`), rotas de recursos (`Resource_Route`: FILE /
   TARGET_WRITE / TARGET_READ — o lado READ é a aresta atrasada do
   ping-pong entre frames), e `plan_path` (cadeia até o output, para
   provenance de pixel).
2. **`pipeline.odin`** (adapter): converte `ScenePass` → `Pass_Descriptor`,
   mantém caches de assets de usuário (texturas, modelos, samplers por
   `filter:address`) e aplica o plano no reload.
3. **`imgui_nodes.odin`** (UI, imnodes): renderiza os nós com pins derivados
   da reflexão, gestos de link com **staging + confirmação** (modal
   "##pipeline_change" mostra from → to, e "replaces X" quando o input já
   tinha produtor — um produtor por input), layout em camadas
   (`sg_compute_layout`: depth por relaxação + ordenação barycenter),
   autosave do `graph.json`, previews por pass (downsample do output em
   `targets.previews`), minimap, pan com momentum no trackpad.

### graph.json — documento e manifest

O mesmo arquivo é o documento do editor e o manifest de runtime. Links são
pin-qualified:

```json
{ "from": "comp:scenes/10_multipass/10_multipass:computeMain:out_tex",
  "to":   "comp:scenes/10_multipass/pass_1:computeMain:input_tex" }
```

Nós: `params` (uniforms broadcast — pins marcados, sem link desenhado),
`image` (textura de arquivo ou target com filtro/address/w/h), `object3d`
(stage_in ModelVertex), `comp:`/`gfx:` (passes), `show2d` (viewport), `ui:`
(widgets como nós). Mudança no arquivo → `pipeline_scene_refresh` (mtime)
→ `pipeline_plan_load` → rejeição mantém o **last known-good plan** e notifica;
aceitação troca o plano e re-carrega assets.

Uniforms são "wireless": nenhum link de uniform existe no grafo (broadcast
por marca de pino); os links desenhados são apenas recursos/execução.

## Editor de código + LSP (imgui_editor.odin, lsp.odin)

- **Componente**: ImGuiColorTextEdit via wrapper C (`ite_*`), compilado no
  Makefile com os mesmos `IMGUI_DISABLE_OBSOLETE_*` do lib imgui.
- **Tabs seguem a cena**: o entry + todo módulo importado transitivamente
  (BFS com resolução relativa/bare). `Cmd+S` salva todas as abas sujas —
  shader é o único estado persistente do app; o watcher reconstrói.
- **LSP**: cliente stdio próprio (JSON-RPC, Content-Length) para o slangd
  vendored. Síncrono de propósito: o callback de completion roda na render
  thread e o slangd local responde em ms. didChange com debounce ~300ms
  (18 frames); `publishDiagnostics` → squiggles com range (line/col start/end);
  completion (`textDocument/completion`) alimenta o popup do ite; hover docs,
  go-to-definition (Cmd+click, resolve no arquivo corrente → demais .slang →
  tabela builtin) e rename.
- Erros de build (slangc via goose) e diagnósticos (slangd) são dois canais
  independentes que convergem nas squiggles do editor.

## Debug: watches, pixel inspector, provenance (inspect.odin)

- `debug_watch_fragment(slot, expr, coord, Uniforms)` /
  `debug_watch_compute(...)`: até 8 slots por pass. Apenas o thread/pixel
  selecionado escreve; labels extraídos do source (parse dos markers
  `debug_watch_*(` — strings nunca cruzam a GPU). Buffers indexados por
  `pass × slot`, copiados assíncrono (gfx.Staging), exibidos no frame
  seguinte.
- **Pixel inspector**: clique na cena → download 1×1 RGBA8 do target.
- **Provenance multipass**: o mesmo clique baixa o pixel de CADA pass
  upstream (via `plan_path`) e mostra a cadeia causal no painel e nos nós.
- Gotcha documentado no código (apple, 2026-10-03): Slang atribui índices de
  textura Metal por ordem de declaração e depois dead-code elimina recursos
  não usados — debug write que não consome o sample desalinha os índices do
  SDL (tela preta, MSL válido). Regra: samplers primeiro, storage depois.

## Infra de GPU (gfx/), input (glove/), apresentação

- `gfx/`: wrapper fino SDL GPU — janela/device/swapchain, pools de
  buffer/texture/sampler com **handles generation-checked** (use-after-free de
  handle detectável), uploader com filas de staging (uploads e downloads).
- `glove/`: input próprio sobre SDL com keymap declarativo
  (`assets/input.ini`), ações, captures (integração com ImGui), adapters
  testáveis. `--input-log` loga o stream cru.
- `blit.odin`: apresentação — fullscreen blit 2D, pass 3D (heightfield com
  depth) e o preview pipeline (R8G8B8A8_UNORM) dos thumbnails.

## CLI e self-tests

Flags: `--scene N|name`, `--headless`, `--once`, `--shot path`, `--benchmark N`
(`--benchmark-debug` semeia pixel central), `--pixel-test`, `--watch-test`,
`--graph-test`, `--graph-click-test`, `--ied-test`, `--pan-test`,
`--notify-test`, `--mobile`, `--metrics`, `--hover-debug`, `--input-log`,
`--3d`, `--color`. Cada self-test exercita um subsistema fim-a-fim
(ex.: `./main_debug --scene 10 --watch-test 400 300` valida seleção, writes
multipass, readback, labels e provenance).

## Decisões de design (e o porquê)

1. **Cenas como dados + manifest gerado em runtime** — adicionar cena = criar
   pasta; zero código/restart. O goose é invocado pela app com um manifest
   gerado na hora (só o alvo do host no hot-reload; baked `goose.json` para
   infra shaders com metal+spirv).
2. **Build em worker + pump no frame** — save não trava a UI; GPU só é
   tocada na main thread (criação de pipeline); builds concorrentes coalescem.
3. **Reflexão como autoridade de interface / graph.json como autoridade de
   roteamento** — os pins nunca divergem do que o shader declara; o usuário
   roteia, o validador garante (ciclos, tipos, produtor único).
4. **Last known-good em todos os níveis** — build quebrado mantém pipeline;
   graph.json inválido mantém plano; cena que falha ao carregar faz rollback
   para a anterior. A tela nunca apaga.
5. **Elm incremental para UI** — estado central, Msg/update únicos, efeitos
   como dados; widgets nunca chamam SDL/OS/GPU.
6. **temp allocator por frame (e por build)** — gerenciamento de memória
   explícito: temp para scratch, clones para persistência, MEM_TRACE
   opcional para investigar leaks.
7. **LSP síncrono** — simplicidade deliberada: slangd local responde em ms;
   caminho async documentado como follow-up se latência aparecer.
8. **Cenas do usuário fora da árvore** (`gis_scenes/`) — sobrevivem a updates
   do repo; shadowing de nome sobre built-ins.
9. **Lockfile entre instâncias** — dois builds dev na mesma árvore não
   corrompem artifacts entre si.
10. **Provenance por caminho do plano** — reusa o DAG já validado; a cadeia
    causal do pixel é `plan_path` + readbacks 1×1, sem instrumentação extra.

## Pontos de extensão (relevantes para o editor JS / render graph)

- O par reflexão↔pins e o schema `graph.json` são estáveis e documentados —
  um editor externo (ex.: LiteGraph + CodeMirror no browser, spike em
  `../wgpu/gis.html`) pode ler/escrever o mesmo documento.
- `plan_path` + provenance já expõem a topologia necessária para visualizar
  cadeias de passes fora do app.
- `slangd` roda como processo separado via stdio — um bridge WebSocket daria
  hover/completion ao CodeMirror sem duplicar lógica.
- O `SCENE_TARGET` por plataforma e o formato dos `.refl.json` são os dois
  únicos contratos binários/de formato entre app e toolchain.
