# Onda 3 — Naming sweep (5 agentes paralelos) + verificação final

Regra: variáveis LOCAIS com nome < 4 letras devem ser renomeadas para nomes
descritivos. Exceções permitidas: i, j, k, n, x (e y) quando usados como
índice/contador/coordenada numérica; `a, b` como operandos de operações
simétricas (ex.: mat4_mul(a, b), plan_equal(a, b)).

RESTRIÇÃO CRÍTICA: renomear APENAS variáveis locais. NÃO renomear campos de
struct, procs, tipos, globais — em Odin não há private e quebraria call sites
em outros arquivos (e os packages novos devem manter os nomes do cubes).

Grupos disjuntos (cada agente só toca seus arquivos):
- G1: src/main.odin, src/model.odin, src/shot.odin, src/app.odin,
      src/window_macos.odin, src/hotreload.odin, src/camera.odin, src/fx.odin
- G2: src/imgui_nodes.odin
- G3: src/imgui_editor.odin, src/lsp.odin
- G4: src/scene_runtime.odin, src/pipeline.odin, src/scene_templates.odin
- G5: src/ui.odin, src/ui_chrome.odin, src/ui_sidebar.odin, src/ui_learn.odin,
      src/notify.odin, src/i18n.odin

Cada agente: renomear locals < 4 letras (fora das exceções) com nomes
descritivos, preservando comportamento. Reportar lista de renomes por arquivo.
NÃO rodar formatter/build geral (verificação central ao final).

## Verificação final (agente principal, após a onda)
1. `odin check ./src` — zero erros.
2. `odin check src/gfx src/glove src/render_graph` (individualmente).
3. `make shaders` — bake de shaders ok.
4. `make debug` (ou odin build -out:main_debug) — binário construído.
5. Smoke: `./main_debug --scene 1 --benchmark 60` — 60 frames reais na GPU.
