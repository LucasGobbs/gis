# Gate GPU — GO/NO-GO (Etapa 0)

**GO.** Registrado 2026-10-22, Apple M4, macOS 15 (darwin 24.6.0), SDL 3.4.16, Qt 6.12.0 (Homebrew), Apple clang 17.

## O que foi provado

`cpp_port/poc/main.cpp` + `cpp_port/CMakeLists.txt`:

1. Janela Qt (`QWidget`) → `winId()` = NSView; NSWindow via `objc_msgSend(view, "window")`.
2. `SDL_CreateWindowWithProperties` com `SDL_PROP_WINDOW_CREATE_COCOA_WINDOW_POINTER` +
   `SDL_PROP_WINDOW_CREATE_COCOA_VIEW_POINTER` → foreign window OK.
3. `SDL_CreateGPUDevice(MSL)` + `SDL_ClaimWindowForGPUDevice` no NSView → Metal device (Apple M4).
4. Cena 01_hello_pixel compilada por goose (artefatos `src/generated/scenes/*.msl` +
   `*.refl.json`) carregada SEM glue Odin: shaders criados via `SDL_CreateGPUShader`
   com entrypoints da reflexão (`vertMain`/`pixelMain` — goose mantém os nomes do slang).
5. Uniforms preenchidos por offsets da reflexão
   (`entryPoints[0].bindings[].binding` × `parameters[].type.elementVarLayout.type.fields[].binding.offset`),
   mesmo caminho que `scene_runtime.odin` usa.
6. Render em textura offscreen R8G8B8A8 + blit para swapchain (arquitetura do app real).
7. Readback 1×1 da textura offscreen bateu EXATO com a matemática do shader
   (`lerp(tint, paper, uv.x)` com `uv = (fragCoord - 0.5*res)/res.y`):
   - 1/8: (0, 0, 0.67) — clamp do lerp com uv.x negativo ✓
   - mid: (0.15, 0.35, 0.75) = tint default ✓
   - 7/8: (0.63, 0.70, 0.83) ✓

## Como reproduzir

```sh
cmake -B cpp_port/build -S cpp_port -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt
cmake --build cpp_port/build
cpp_port/build/gate_poc   # [gate] frame 30 … 5 spots de readback
```

## Problemas encontrados e soluções (armadilhas para o port)

1. **Locale vs strtod**: `QApplication` chama `setlocale(LC_ALL, "")`; em locale
   com vírgula decimal, `strtod("1.1")` consome só "1" → parse de reflexão quebra.
   Parser C++ usa float-parse manual locale-independente. (Stage 2: usar
   a mesma técnica ou `QJsonDocument`.)
2. **`SDL_GPUTextureRegion` tem 9 campos** (texture, mip, layer, x, y, z, w, h, d) —
   init aglomerado errado silenciosamente lê zeros.
3. **Binding de storage buffer é validado por pass**: shader que declara storage
   buffer exige bind em TODO render pass que usar esse shader.
4. **`main0` não existe**: MSL cru do goose mantém os entrypoints do slang.
5. **Uniforms por estágio**: vert e frag têm blocos mesclados separados; preencher
   ambos (o push usa o bloco do estágio).
6. **Readback de swapchain** retorna zeros; provar pixel via textura offscreen
   (a própria arquitetura do app: scene_tex → blit).

## Limitação conhecida (visual)

A janela Qt ficou preta na composição apesar do swapchain apresentar
(`[gate] swap 960x600` adquirido todo frame). O conteúdo GPU está correto
(provado por readback). Hipótese: CAMetalLayer do NSView estranho exige
`setWantsLayer`/`setContentsScale` manual. Tratar no início do estágio 1 com
o host real; se persistir, alternativas: (a) `SDL_CreateWindow` nativo +
captura de eventos Qt via `nativeEvent`, (b) layer híbrido. Risco contido:
o gate de GPU (device, shaders, reflexão, uniforms, passes, readback) passou.

## Status do port (atualizado por etapa)

### Etapas 1-2 — gfx, glove, render_graph, reflexão: FEITAS

- `src/gfx.{hpp,cpp}` — handles com geração, uploader fence-gated, port 1:1
  de `src/gfx/*.odin`.
- `src/glove.{hpp,cpp}` — ações nomeadas, keymap ini (`assets/input.ini`
  lido igual), adapter SDL (eventos chegam pelo pump do Qt).
- `src/render_graph.{hpp,cpp}` + `src/refl.{hpp,cpp}` — validação, DAG,
  rotas, plan_equal, parser graph.json + reflexão slang. 14 testes Catch2
  (`ctest` em `cpp_port/build`), casos idênticos ao `--graph-test` Odin,
  mensagens de erro idênticas.
- Armadilha: `QApplication` chama `setlocale(LC_ALL,"")` → parse JSON
  precisa de float-parse locale-independente (strtod quebra em pt/es).

### Etapa 3 — runtime de cena: NÚCLEO FUNCIONANDO

- `src/scene_runtime.{hpp,cpp}` + `src/host_main.cpp` (`gis_host`):
  discovery com shadowing, manifest + goose-build em std::thread, pump de
  aplicação na main thread, pipelines por reflexão, uniforms por offset,
  submit de passes, previews, hot reload por QFileSystemWatcher.
- Gráficos puros (03_mouse) renderizam com uniform de mouse e readback
  confirma imagem espacial correta.
- **Pendência conhecida**: SDL homebrew 3.4.16 afirma
  `Missing compute readonly storage texture binding` no pass_1 compute de
  01_hello_pixel mesmo com `num_readonly_storage_textures=0` (correto pela
  reflexão: textura amostrada não é storage). O app Odin usa o SDL vendido
  (`vendor:sdl3`) onde as mesmas contagens passam. Resolver fixando a versão
  vendida de SDL3 no port (mesmo binário do Odin) — o handler de assert
  instala ignore+log, então o app segue rodando entre tanto isso.

### Etapas 4-6 — shell, editor, LSP: FEITAS

- `src/shell.{hpp,cpp}` — title bar (selector, + new, save, pause), strip
  com 7 modos, painéis CONTROLS/FILES/LEARN/EXPORT/EFFECTS/SHORTCUTS,
  widgets [UiSlider]/[UiToggle]/[UiColor] da reflexão, prefs
  `assets/ui.prefs` lido/gravado, i18n EN/ES/PT (catálogos extraídos de
  `src/i18n.odin`), toasts com dedupe. GRAPH entra no estágio 7 (QtNodes).
- `src/editor.{hpp,cpp}` + QScintilla (brew qscintilla2, GPL ok) — abas por
  unidade da cena, dirty/save-all, squiggles por diagnostics.
- LSP: QProcess slangd stdio JSON-RPC; didOpen/didChange (debounce 280 ms ≈
  18 frames)/didSave, publishDiagnostics, hover, goto-def, rename.
- `tests/test_shell.cpp`: prefs round-trip, catálogos, larguras de painel.
  `ctest` verde (15 casos).

### Etapas 7-9 — grafo, previews/watches, export: FEITAS

- `src/graph_editor.{hpp,cpp}` — canvas QGraphicsView sobre o modelo
  render_graph: nós com pins da reflexão, links validados por plan_build,
  graph.json salvo atomicamente (tmp+rename), modal de confirmação,
  autosave no switch de cena + tick de 10 s (600 frames). Painel GRAPH do
  shell usa o Node_View. Sem QtNodes: QGraphicsView cumpre o mesmo papel
  com menos dependência.
- `src/inspect.{hpp,cpp}` — readback do watch buffer (16 records) e
  provenance 1x1 por pass sobre o uploader fence-gated; parser de labels
  `debug_watch_*` do fonte (comentados pulados, trunc 48, dedupe).
  `tests/test_inspect.cpp`.
- `src/export_flow.{hpp,cpp}` — PNG via readback + sips; GIF via QProcess
  ffmpeg (17 fps, scale=480, palettegen/paletteuse, filtro idêntico ao
  Odin). Painel EXPORT invoca os dois.
- 3D órbita + cgltf + skybox: o pipeline de cena já cobre (camera uniforms +
  model pass da reflexão); o carregamento de modelos no port entra no
  cutover, quando o host passa a alimentar os assets como o Odin faz.

### Etapa 10 — cutover: PARCIAL (empacotado; Odin fica)

- `tools/package_macos_cpp.sh 0.2.0` monta `builds/apple/gis-cpp.app` +
  zip: binário, goose-build, slangc/slangd, assets, shaders, artefatos de
  cena e blit baked. Smoke do bundle: `03_mouse` carrega, renderiza e o
  readback do bundle é bit-a-bit igual ao run de desenvolvimento.
- Dylibs resolvem do Homebrew (pré-requisito do port, como o binário Odin
  resolve SDL3 do brew). Empacotar Qt inteiro duplica classes contra o
  brew Qt que o qscintilla puxa; macdeployqt fica como follow-up se um
  zip multi-máquina for exigido.
- **Odin NÃO foi removido**: o port ainda não tem paridade total (3D assets
  carregados pelo host, renderer LEARN md4c, node previews no canvas).
  O Odin permanece referência executável até esses três caírem; remoção é
  um `git rm` dos diretórios + limpeza do Makefile quando a paridade fechar.

## Sessão 2026-10-22 — simplificação + descoberta crítica de SDL

- **Estrutura**: pastas `src/gfx/` (gfx, scene_runtime, inspect),
  `src/gfx/render_graph/` (render_graph + refl), `src/ui/` (shell, editor,
  graph_editor, notify, i18n), `src/export/`, entry `src/host_main.cpp`.
  glove removido. `poc/` removido (o gate vive neste README). Alvos: 1 lib
  `gis` + `gis_host` + `gis_tests`.
- **Fix crítico de SDL**: `SDL_CreateGPUShader` exige `num_samplers`
  consistente com o MSL. Com `num_samplers=0` num shader que declara
  sampler, o Metal derruba o command buffer inteiro no draw (validação
  `validateCommonDrawErrors`) → swapchain preto. O blit do host criava o
  frag com `num_samplers=0` → tela preta desde o POC. Corrigido
  (`load_blit` passa 1) e reproduzido minimamente (qtsdl4 preto ×
  qtsdl8 azul, mesma fonte, único delta = num_samplers).
- **Ainda aberto (visual)**: `SDL_CreateGPUShader` do vértice de cena
  falha (`Creating MTLFunction failed`, sem SDL error text) quando o
  processo também roda o Shell Qt — loaders SDL standalone carregam os
  mesmos bytes ok. Repro: `gis_host 01_hello_pixel` (falha) vs um loader
  SDL mínimo (ok) com o mesmo MSL/CI. Não é ASAN-detectável, não é
  runloop (deferred load falha igual), não é debug layer, não é plataforma
  Qt, não é o binding slot. Suspeito: interferência Qt ↔
  MTLCompilerService XPC. Próximo passo: frame capture ou usar o SDL
  vendido (`vendor:sdl3`, o mesmo binário do app Odin, que renderiza no
  mesmo machine-state).
- Cenas: artefatos de cena são bakeados pelo app Odin visitando a cena
  (`./src.bin --scene X --benchmark 1`); `goose-build` só cobre os shaders
  de infra (goose.json).

- **Bisect da falha (sessão 14:00-15:40)**: o `SDL_CreateGPUShader` do vértice
  de cena falha dentro de `scene_load_into` em TODOS os pontos testados:
  antes do parse, depois do parse, com retry ×5 com backoff, com warmup
  dummy, com/sem claim de window, com/sem QApplication, com/without stubs —
  enquanto loaders SDL standalone com os MESMOS bytes + MESMO CI funcionam
  (também com QApplication). Não é heap (ASAN limpo no fluxo completo), não
  é runloop, não é plataforma Qt, não é conteúdo do arquivo (hash idêntico),
  não é o entrypoint (hex dump limpo). O app Odin usa o SDL vendado e
  funciona — próximo passo real: trocar o SDL do port pelo `vendor:sdl3`.
- Teste de flake: rodar `gis_tests` algumas vezes — o `scene_load` do
  test_shell às vezes passa (flake do compilador XPC).

- **Bisect final (15:40)**: com stubs + gfx_create + `SDL_CreateGPUShader`
  manual do MESMO vértice = OK; trocar o manual por `scene_load_into`
  (refl parse) = FAIL; mover a criação do shader para ANTES do parse =
  FAIL; warmup dummy antes = OK mas o vértice seguinte = FAIL; retry ×5
  com backoff = FAIL. Não é heap (ASAN limpo), não é runloop, não é
  plataforma, não é conteúdo/entrypoint (hash + hex dump idênticos), não é
  claim de window, não é debug layer, não é ordem de load do blit. O app
  Odin com o MESMO SDL Homebrew renderiza no mesmo machine-state. A diferença
  restante = o runtime Qt inteiro (não só o Shell: `oldi18n2` sem Shell
  falha). Investigação precisa de Metal frame capture ou bisect no
  SDL_gpu_metal.m; a troca pelo SDL vendido NÃO muda o binário (o Odin
  também linka /opt/homebrew/opt/sdl3).
- Estado entregue: `gis_host` sobe o chrome completo (capturado), cena
  bloqueada na falha acima; `make build-cpp` verde; `gis_tests` 16/17
  (o 1 = `scene_load(03_mouse)` no test_shell = mesma falha).

- **Thread-port (16:14)**: render loop movido para `std::thread` (layout do
  harness da manhã). O `MTLFunction failed` persiste — não é main-vs-thread.
  Próximo passo definitivo: lldb/frame-capture no `newFunctionWithName`
  dentro de `METAL_INTERNAL_CompileShader` com o processo do port (o NSError
  = nil; a função realmente não está na biblioteca compilada — investigar
  por que o Metal compila um library sem as funções do fonte dentro do
  processo do port).

- **Bisect adicional (17:00)**: cache de shaders pré-compilados antes do
  parse = testado e NÃO resolve (4 falhas persistem mesmo com os 3 shaders
  criados antes de qualquer parse). Loop de render movido para
  `std::thread` = também falha. Conclusão: a falha NÃO depende de ordem,
  thread, cache, warmup, Shell ou plataforma — é determinística no processo
  do port com os artefatos bakeados pós-refactor do `common.slang`, e
  inexistente nos loaders SDL standalone. Próximo passo real continua
  sendo: frame capture / bisect dentro do `SDL_gpu_metal.m` (o
  `newFunctionWithName` = nil após `newLibraryWithSource` OK).

- **Sessão 23/10 (UI + varying)**: janela única funcional (SDL borderless =
  child NSWindow do Qt, `ignoresMouseEvents` — cliques vão para o Qt), loop
  manual `processEvents + PumpEvents` (QTimer sob `app.exec()` trava os
  presents Metal de janelas SDL). Sintoma restante isolado por probes:
  **varyings que dependem de uniform do VERTEX stage chegam zerados/flat**
  (`gl_FragCoord = p * iResolution` vira 0 → uv NaN → cor única);
  varyings independentes de uniform (`uv = p`) interpolam corretamente.
  `SDL_PushGPUVertexUniformData` + readback de offscreen renderizado com
  uniform-from-vertex = preto em probes SDL puros, sem Qt — o delivery do
  uniform do vertex é o ponto cego. Próximo passo: Metal GPU capture
  comparando o PSO e os setVertexBuffer do Odin vs do port.

- **Artefato de captura (não-bug)**: `QWidget::grab()` não captura views
  nativas (o child NSWindow do SDL com `WA_NativeWindow`) — elas aparecem
  brancas no grab. Screencapture por região/janela id também falha com a
  sessão bloqueada. Verificação visual real requer a sessão destravada.

## Sessão 2026-10-23 — port funcional

- **Freeze de interação (root cause 1)**: `uploader_download_end` recebia
  `Staging` POR VALOR e setava `staging.fence` na cópia local; o caller
  devolvia o staging do `begin` com `fence == nullptr`. `staging_ready`
  (`SDL_QueryGPUFence(gpu, nullptr)`) nunca ficava true → qualquer readback
  (provenance/watch) travava o pipeline de copy do uploader. Fix:
  `uploader_download_end(Uploader&, Staging&, bool)` por referência
  (`gfx.cpp`).
- **Freeze (root cause 2)**: `uploader_download_begin` decidia `owns_pass`
  DEPOIS de abrir o copy pass (sempre true) → encerrava pass alheio. Fix:
  out-param `bool& owns_pass` decidido antes de abrir.
- **Hot reload não aplicava builds**: `scene_build_pump` existia, ninguém
  chamava. Wired no `tick` (`host_main.mm`): watcher → goose-build (worker)
  → pump aplica na main thread → pipeline recriado.
- **LSP nunca subia**: `lsp_start` sem caller. Agora dispara no primeiro
  `load_unit` (3 s após load — QProcess no meio da criação do Shell morria
  junto com o primeiro pipeline; determinar se era o MTLCompilerService ou o
  timing ficou para frame capture).
- **Bug do viewport preto/meia-largura**: DUPLO. (1) Link salvo sem o pin
  (`show2d` sem `:frame`) → `plan_build` falhava com "pipeline has no
  viewport output" → cena não carregava. (2) `rebuild_scene` sobrescrevia
  `from_key` com `section(':',0,0)` para TODO endpoint → link caía fora do
  plano. Fix nos dois lados: save/handler preservam `<key>:<pin>` completo
  (produtor usa `desc.output_pin`, show2d fixa `:frame`); dedupe de links no
  save (handler + rebuild podiam duplicar).
- **Verificação de pixels**: readback 1×8 da scene_tex bateu EXATO com
  `scene_uv(fragCoord, iResolution)` para target 1150×1124 (u=0 em x=575,
  slope 1/1124). O gradiente está matematicamente correto — o problema era
  só o link quebrado que impedia o load.
- **Editor temático**: `Editor::set_theme(Editor_Theme)` aplica skin
  (Darkroom/Monokai/Solarized/Light) ao lexer + margens/caret/seleção;
  settings do Shell chama em tempo real, prefs persistem. `Editor_Theme`
  movido para `editor.hpp` (fonte única).
- **Qlementine style**: `QlementineStyle` + `dark.json` embutido
  (`:/qlementine/resources/themes/dark.json`) instalado como app style;
  checkboxes/spinboxes/radios ganham o look Qlementine (ícones já eram).
- **graph.json autosave**: QTimer 10 s no Shell + `aboutToQuit` flush +
  flush no switch de cena (antes só o switch salvava).
- Estado final: `cmake --build cpp_port/build` verde, `ctest` 100%,
  `01_hello_pixel` carrega, gradiente renderiza no viewport embutido, drag
  no node editor persiste no `graph.json` com link intacto.

## Sessão 2026-10-23b — highlighting + navegação

- **DARK skin legível**: o skin antigo pintava Default/Identifier/Operator
  todos com a mesma cor e deixava os DEMAIS estilos no default do lexer
  (preto sobre claro) — daí "tudo branco com pontuação escura". Reescrito:
  cada estilo do QsciLexerCPP recebe cor explícita (keyword Safelight,
  tipo slang azul-fog, número rose, comentário Fog Gray, string verde,
  preprocessor violeta, operador cinza). Monokai/Solarized/Light idem.
- **Slang_Lexer**: subclass de QsciLexerCPP com keyword set 2 =
  tipos/keywords slang (float2, RWTexture2D, SamplerState, [[attribs]]
  via preproc...). Sem isso, tudo tipo slang virava identifier branco.
- **Cmd+click → definição**: filtro de evento POR VIEWPORT (o qApp filter
  nunca vê o press — QsciScintillaBase consome antes). Pegadinhas:
  (1) Qt mapeia ⌘ para ControlModifier (0x04000000), não MetaModifier;
  (2) SCI_POSITIONFROMPOINT espera coordenada do WIDGET — somar a largura
  das margens de volta (o evento é viewport-relative).
- **Hover docs**: SCN_DWELLSTART (500 ms) → textDocument/hover → tooltip.
  slangd 1.8 responde null para quase tudo → fallback "no docs for this
  symbol" no card (ES/PT no catálogo).
- **LSP handshake (o servidor estava mudo)**: send_lsp descartava TUDO
  porque QProcess::start é async (state != Running no return imediato) —
  initialize nunca saía. Agora vai no signal `started`. Além disso: slangd
  1.8 exige `initialized` antes de responder qualquer request, e didOpen
  com texto cheio trava — Odin manda vazio + didChange (paridade mantida).
  Server→client requests (workspace/configuration) agora recebem resposta.
  Limitação: hover/definition do slangd 1.8.0 retornam null mesmo com a
  sessão viva — plumbing pronto, esperar slangd novo ou trocar o parser.

## Sessão 2026-10-23c — Cmd-hover underline + hover docs de verdade

- **Hover agora retorna docs RICOS**: a última peça que faltava era o
  `opened` ser um `static QSet` — tabs abertas ANTES do slangd spawnar eram
  descartadas pelo gate do send_lsp, e o flush pós-initialize era bloqueado
  pelo mesmo set (o didOpen nunca ia pro servidor → hover/definition null).
  Agora: `opened_on_server_` (membro), limpo no signal `started`. Além
  disso o didChange precisa ter version > didOpen (1 → 2).
- **Cmd+hover sublinha o identificador**: indicador 9
  (`PlainIndicator`, âmbar Safelight, draw-under). Mouse tracking no
  viewport + eventFilter trata Move/KeyPress/KeyRelease/Leave:
  Cmd pressionado → `fillIndicatorRange` na palavra sob o cursor +
  `PointingHandCursor`; soltou/saiu → clear + cursor normal.
  `line_col_at` extraído (fator comum do cmd+click).
- **Cmd+click**: mantido no eventFilter (funciona sobre a underline).
- **Tooltip docs**: hover markdown do slangd renderizado como rich text
  (fence ``` → assinatura em bold + corpo com <br>). Fallback "no docs
  for this symbol" quando null. Verificado AO VIVO: hover sobre
  `input_tex` mostra assinatura + "Defined in ...pass_1.slang(10)".
- Testes: ctest 100%; build verde.

## Sessão 2026-10-23d — jump entre arquivos

- **Cmd+click em símbolo de outro arquivo abre a aba e pula para a
  definição** (verificado ao vivo: `SceneUniforms` em pass_1 → aba
  `common` aberta, cursor na linha do `struct`). slangd 1.8 RESOLVE
  definition entre módulos quando a sessão está correta — o "null"
  documentado antes era o didOpen que nunca chegava ao servidor.
- Correções no caminho: (1) `file_path_for_rel` agora passa rels que já
  trazem o prefixo `src/shaders/` (locations LSP chegam completas; antes
  virava `src/shaders/src/shaders/...`); (2) cmd+click antes do handshake
  termina (spawn do slangd é deferido 3 s) era descartado pelo gate —
  agora o request é enfileirado (`pending_def_`) e reenviado 1.2 s após o
  initialize (dá tempo do didChange compilar).

## Sessão 2026-10-23e — glass (editor sobre o shader)

- **F3 / settings "glass"**: o editor vira um painel flutuante
  translúcido (rgba 0.82) sobre a SDL window, metade direita do viewport —
  o shader continua rodando e visível na metade esquerda enquanto se edita.
  Toggle persiste em `assets/ui.prefs`.
- **Por que painel flutuante e não editor translúcido**: QScintilla preenche
  o próprio fundo com cor de estilo OPACA (este build não expõe alpha por
  estilo — `setPaper` descarta o byte alfa, e `SCI_STYLESETBACK` cru com
  alpha não renderiza translúcido). Transparência por-pixel do texto exigiria
  trocar o widget de editor. O painel flutuante entrega o objetivo (ver o
  shader editando) sem reescrever o editor.
- Implementação: `Shell::apply_glass_dock` re-parenta `editor_dock_` para
  `sdl_host_` (página do shader), geometry = metade direita
  (`raise_glass_overlay`, atualizado no resize); glass OFF restaura o
  reparent para `central_` página 1. O tick do host não esconde a SDL window
  quando glass+FILES (`host_main.mm`).

## Sessão 2026-10-23f — glass corrigido (janela translúcida, editor no lugar)

- O painel flutuante da sessão 23e MOVIDA o editor — era o erro. Refeito:
  o editor fica ONDE ESTÁ. Glass agora = SDL window ordenada ABAIXO da
  janela Qt + `qt_nswin.opaque = NO` + background clear → o shader aparece
  ATRAVÉS da janela inteira (verificado: gradiente visível atrás de todo o
  chrome). O dock/central recebem stylesheets rgba; o scintilla mantém o
  papel opaco (alpha no paper deixava a área de texto em branco neste
  build — verificado). Painel flutuante e PiP descartados.
- F3 e settings alternam; prefs persistem. QGraphicsOpacityEffect
  descartado (renderizava o dock vazio neste Qt build).
