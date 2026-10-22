# cpp_port — ASan bug hunt + UI audit log

Registro de caçada de bugs (`make run-cpp-asan`) e audit de UI (skill
impeccable, register product). Cada ação executada no app está listada com o
resultado observado.

## Resumo executivo

- 1 bug real encontrado e CORRIGIDO: heap-use-after-free no polish de QMenu
  (upstream qlementine v1.5.2). Reproduz na primeira abertura do menu de
  cenas (botão "…"/chip da barra) e em qualquer QMenu pós-`show()`.
  Fix: `cpp_port/qlementine-menu-uaf.patch` aplicado via `PATCH_COMMAND` no
  `FetchContent_Declare(qlementine)` em `cpp_port/CMakeLists.txt`.
- 0 segfaults/ASan nas demais ações (troca de cena, hot reload, grafo,
  settings, resize de painel).
- Audit de UI: **13/20 — Acceptable**. P0: controles com stretch errado
  (spinbox expande por todo o sidebar); P1: spinboxes QLocale vírgula
  (`0,25`) sem handler de localize; P1: foco/teclado sem ordem de tab;
  P2: cores hardcoded fora dos tokens.

---

## Ações executadas sob ASan (gis_host pid 57971, build-asan)

| # | Ação | Resultado |
|---|------|-----------|
| 1 | Boot + 25s idle (01_hello_pixel) | OK, sem report |
| 2 | Toggle iColorMode checkbox | OK |
| 3 | Cor swatch → QColorDialog → pick → OK | OK |
| 4 | Autorotate toggle + mouse rotate | OK |
| 5 | Gear settings → submenu | **CRASH #1** (ver abaixo) |
| 6 | (pós-fix) Abrir menu de cenas | OK — fix validado |
| 7 | Trocar cena via menu (04_shapes) | OK |
| 8 | Editar `.slang` → hot reload → revert | OK (0 ASan) |
| 9 | Abrir GRAPH, drag de node, drag de link | OK (0 ASan) |
| 10 | Settings gear + theme submenu (3x) | OK (0 ASan) |
| 11 | Drag edge do painel (resize 2x) | OK (0 ASan) |
| 12 | Fechar app (quit limpo) | pendente no re-verify |

## Bugs encontrados

### BUG-1 (CORRIGIDO): heap-use-after-free ao polir QMenu — upstream qlementine 1.5.2

- **Ação que gerou**: clicar no seletor de cena (menu "…"/chip da topbar) com
  o app já aberto. Também qualquer QMenu/QInputDialog após `shell.show()`.
- **Erro** (ASan, crash .ips 2026-10-24-195335 + system log 20:12 e 20:24):

```
==57215==ERROR: AddressSanitizer: heap-use-after-free on address 0x606000683e78
READ of size 8 at 0x606000683e78 thread T0
    #0 QList<QObject*>::emplaceBack<QObject*&>(QObject*&) qlist.h:975
    #1 PolishedWidgetRegistry::addEventFilter(...) PolishedWidgetRegistry.cpp:24
    #2 polishDestructionTracking(...) PolishUtils.cpp:281
    #3 QlementineStyle::polish(QWidget*) QlementineStyle.cpp:4973
```

- **Causa raiz**: `QlementineStyle::polish(QWidget*)` guarda
  `PolishedWidgetRegistry::Entry&`. `polishMenu()` chama
  `QMenu::setWindowFlag()` → reentrância (`unpolish`+`polish` do mesmo menu)
  → o `unpolish` reentrante faz `erase` do node no QMap (a `Entry` fica
  freed) → o `polish` externo continua usando a `Entry&` e os flags
  `eventFiltersInstalled` stale → `push_back` em memória liberada.
- **Fix** (`cpp_port/qlementine-menu-uaf.patch`, gerado de
  `git diff` no `_deps/qlementine-src`): todos os helpers que instalam
  event filter (`polishLineEditIconButton`, `polishExternalFocusFrame`,
  `polishMenu`, `polishMouseWheelBlocker`, `polishTabBar`,
  `polishTextEditors`, `polishLineEditMenus`, `polishDestructionTracking`)
  re-resolvem a entry no ponto de uso (`registry.hasEventFilters(w)` /
  `registry.ensure(w)`) em vez de confiar na ref/flag em cache. Params
  não-usados silenciados com `Q_UNUSED`. Assinatura de
  `polishLineEditIconButton` ganhou `registry&` (header + caller).
- **Wiring**: `PATCH_COMMAND git checkout -- . && git apply
  ${CMAKE_CURRENT_SOURCE_DIR}/qlementine-menu-uaf.patch` no
  `FetchContent_Declare(qlementine)` (cpp_port/CMakeLists.txt).
  Regenerar o patch: editar em `cpp_port/build-asan/_deps/qlementine-src`,
  `git diff > cpp_port/qlementine-menu-uaf.patch`.
- **Nota**: `cpp_port/asan.supp` (`interceptor_via_fun`) NÃO silencia este
  bug — a suppression vale só para reports dentro de interceptors
  (memcpy etc.), não plain-load UAF. O comentário antigo do .supp
  descrevia o mesmo bug como "suprimido", mas nunca foi.
- **Verificação pós-fix**: menu de cenas abriu ~10x sem crash; troca de
  cena, theme submenu, gear menu — 0 reports ASan.

### BUG-2 (UI, P0): widgets de controles "expansos" por todo o sidebar

- **Sintoma**: na aba CONTROLS, `QDoubleSpinBox` do `radius` ocupa a linha
  inteira com o label colado à esquerda; entre seções há buracos enormes —
  `caption()` e widgets recebem stretch `1` no QVBoxLayout
  (`shell.cpp:762/770/809/817`, `shortcuts_panel` linha 1043, export/effects
  idem), então CADA linha tenta distribuir o espaço vertical igualmente e o
  conteúdo se espalha pela altura toda em vez de empacotar no topo.
- **Fix sugerido**: stretch 0 em caption/widgets normais; único
  `addStretch(1)` no fim do painel. (Aguardando decisão do user para
  aplicar — o pedido foi audit + report.)

### BUG-3 (UI, P1): spinbox não aceita entrada teclado com locale pt_BR

- **Sintoma**: spinboxes mostram `0,25` (QLocale do sistema) e o app não
  chama `QLocale::setDefault` nem trata vírgula; digitar `0.55` com Cmd+A
  não commitou valor (o campo reverte). Entrada só confiável via cliques.
- **Fix sugerido**: `QLocale::setDefault(QLocale::c())` no boot ou
  `QLocale().toDouble()` no pipeline de uniforms.

---

## Impeccable audit — cpp_port Shell (register: product)

### Audit Health Score

| # | Dimension | Score | Key finding |
|---|-----------|-------|-------------|
| 1 | Accessibility | 1 | Sem tab order, sem accessibleName, spinboxes 12px font |
| 2 | Performance | 3 | QVariantAnimation em setFixedWidth ok; deleteLater correto |
| 3 | Responsive/Resize | 3 | Drag-resize funciona; painel GRAPH colapsa a 0 |
| 4 | Theming | 2 | 21 stylesheets com hex hardcoded; tokens DESIGN.md ignorados |
| 5 | Anti-Patterns | 2 | Cards invisíveis não; mas "spring accordion" do stretch |
| **Total** | | **13/20** | **Acceptable** (não parece AI-slop; parece protótipo apressado) |

### Anti-Patterns Verdict

PASS com ressalvas. O shell tem identidade real (darkroom, JetBrains Mono,
âmbar como estado, sem gradientes/glass). Não parece "AI made that". Mas
parece NÃO TERMINADO: espaçamento vertical quebrado (BUG-2) denuncia o
stretch-copy-paste, e 21 stylesheets com hex solto (`#1e2026`, `#8c9099`,
`#dfe0e6`, `#4a4d55`) divergem dos tokens do DESIGN.md
(`#191A1F`/`#131418`/`#757A85`/`#DEE0E6`) — o tema quebra se o DESIGN.md
mudar.

### Detailed findings

- **[P0] Controles espalhados por todo o painel** — `controls_panel`
  `shell.cpp:762,770,809,817`; `shortcuts_panel:1043`; `export_panel`
  `981,986,1009`; `effects_panel:1018-1025`. Category: Layout. Impact:
  hierarquia visível destruída, scan-time alto. Fix: stretch 0 +
  addStretch(1) final. Command: `/impeccable layout`.
- **[P1] Spinbox vs locale** — ver BUG-3. Category: A11y/Input. Fix:
  QLocale::setDefault(c) no boot do host. Command: `/impeccable harden`.
- **[P1] Teclado/foco ausente** — 0 `setTabOrder`, 0 accessibleName;
  shortcuts panel lista F1..F5 mas o app é 100% mouse-first. WCAG 2.4.3.
  Command: `/impeccable harden`.
- **[P2] Cores fora do design system** — `shell.cpp` 10 hex distintos
  hardcoded em 21 stylesheets; DESIGN.md define tokens. Category: Theming.
  Fix: constantes `k*` num header (`theme.hpp` já existe). Command:
  `/impeccable colorize` ou extract.
- **[P2] Traffic lights 12px** — alvo de clique < 24px (Product guidance:
  ≥ 28px em controles de janela). Command: `/impeccable harden`.
- **[P3] `QInputDialog::getDouble` cru** para font sizes — sobe diálogo
  genérico com estilo default Qt, fora do darkroom look. Command:
  `/impeccable polish`.

### Patterns & systemic

- Todo painel usa o mesmo template `VBox + caption(stretch 1) + ...` — o
  bug do stretch é sistêmico, não local. Corrigir o template uma vez.
- Stylesheet string por widget em vez de tokens — 3 superfícies duplicam
  paleta (topbar/strip/panel) com hex ligeiramente diferentes.

### Positive findings

- Identidade "darkroom" coerente: âmbar E8A857 reservado a estado
  (checkbox marcado, atalhos), nunca decoração — Safelight Rule respeitada.
- Painel GRAPH colapsa para canvas full-width; decisão de espaço correta.
- Resize por drag do painel persiste em prefs; clamp 220px..85% janela.
- Sem AI-slop: zero gradientes, zero glassmorphism, zero emoji em UI.
- Hot reload não vaza memória (edit + revert = 0 ASan reports).

### Recommended actions

1. **[P0] `/impeccable layout`**: corrigir stretch dos 5 painéis
   (controls/files/learn/export/effects/shortcuts) — mesmo template.
2. **[P1] `/impeccable harden`**: QLocale fix + tab order + accessible
   names nos strip buttons (são só 7 + gear).
3. **[P2] `/impeccable colorize`**: extrair hex para `theme.hpp`.
4. **[P3] `/impeccable polish`**: substituir QInputDialog por mini diálogo
   inline ou stepper nativo.

> Pode pedir para rodar os comandos um a um, todos de uma vez, ou em outra
> ordem. Re-run do audit depois dos fixes mostra o score subir.

## Fixes aplicados (2026-10-24, pós-audit)

1. **P0 stretch** — CORRIGIDO. `controls_panel`, `export_panel`,
   `effects_panel`, `shortcuts_panel`: stretch 0 nas linhas/captions +
   um único `layout->addStretch(1)` no fim. Verificado visualmente:
   controles empacotam no topo (screenshot gis_clear.png), sem buracos.
2. **P1 locale** — CORRIGIDO. `QLocale::setDefault(QLocale::c())` em
   `host_main.mm` logo após `QApplication`. Verificado: spinbox renderiza
   `0.25` com ponto.
3. **BUG-1 (UAF)** — CORRIGIDO (patch qlementine, ver acima). 0 ASan
   reports após ~15 aberturas de menu + trocas de cena.

### Re-verify sob ASan (gis_asan6, pid 70764)

- Boot 04_shapes: OK, sem report.
- Painel CONTROLS: layout corrigido, spinboxes com ponto decimal.
- Radio "mouse rotation" via AXPress: OK.
- Digitação sintética (CGEvent/keystroke) NÃO chega ao Qt dentro da janela
  SDL-hosted (key-grab do NSView hospedeiro); AXIncrement/AX set value
  também não afetam QDoubleSpinBox. Limitação do harness de teste, não do
  app — clique + teclado reais do usuário usam o caminho normal. Valor
  visual confirma locale; round-trip de digitação fica como follow-up
  manual (1 clique + digitar).

### Nota: graph.json da 04_shapes

Os drags de link da caçada deixaram `"links":[]` no graph.json da cena
(não commitado) → "pipeline has no viewport output" no boot seguinte.
Restaurado para o schema canônico
(`"from":"gfx:scenes/04_shapes/04_shapes:frame","to":"show2d:frame"`,
mesmo padrão das cenas 01–03). Lição: drags de link no node editor são
destrutivos e persistem no autosave de 10s — versão futura deveria
confirmar antes de apagar link existente.

### Quit limpo

Fechar pelo traffic light (AXPress): **exit code 0**, zero reports ASan no
shutdown; autosave do graph.json preservado (link restaurado sobreviveu).
`assets/gis.lock` (0 bytes, sem fd) fica no disco após quit — remoção
manual necessária para o próximo boot. Follow-up P3: unlink no
aboutToQuit.

### Cutover: propagando o patch para outros build dirs

Cada build dir (`build/`, `build-asan/`) tem seu próprio
`_deps/qlementine-src`. O `PATCH_COMMAND` roda só no configure; ao trocar o
arquivo de patch depois, rebuilds existentes ficam com a versão antiga
aplicada (build/ pegou a 1ª versão do patch — só polishMenu — e o build
quebrou em -Werror `unused parameter 'entry'` nos outros helpers).
Sincronizar manualmente:

```sh
cd cpp_port/build/_deps/qlementine-src
git checkout -- .
git apply ../../qlementine-menu-uaf.patch   # caminho relativo: 2 níveis
cmake --build cpp_port/build
```

Verificado: build normal compila, `ctest` 1/1 passa (gis_tests).

### BUG-4 (CORRIGIDO): SEGV no quit — frame tick durante teardown

- **Ação**: fechar o app (traffic light) com o hook novo de
  `aboutToQuit` (flush + lock unlink). O frame `QTimer` (16 ms) continuava
  disparando durante a destruição dos objetos Qt/ObjC → SEGV em
  `objc_msgSend` via `QTimer::timerEvent` (ASan, 2/2 quits).
- **Erro**:
  `SEGV on unknown address 0x21758 (objc_msgSend) ← doActivate ← QTimer::timerEvent`
- **Fix** (`host_main.mm`): no `aboutToQuit`, `frame_timer.stop()` ANTES de
  flush/unlink. Quit + lock release agora limpos.
- **Verificação**: 2 ciclos boot→quit (01_hello_pixel, 02_time) — exit 0,
  0 reports ASan, `assets/gis.lock` removido em ambos.

### BUG-5 (CORRIGIDO): GIF export sumia silenciosamente + stage-9 wiring

- **Wiring faltando**: botões do painel EXPORT só mostravam toast
  "stage 9"; `export_flow` (PNG/GIF) existia sem nenhum chamador. Ligado:
  `Shell::png_export_requested` / `gif_export_requested` → host faz o
  readback do `targets.scene` (staging download + QImage → PNG em
  `exports/`; GIF: 1 frame a cada 4 ticks ≈ 17 fps → ffmpeg assemble).
- **BUG-4b no caminho**: readback usava `uploader_flush_blocking` após
  `download_end` — o copy pass já tinha sido fechado/submitado pelo
  `download_end` (owns_pass) → SEGV em `METAL_WaitForFences` (NULL pass).
  Correção: aguardar o fence com spin em `staging_ready` (mesmo padrão do
  `inspect`), nunca re-flush.
- **BUG-5**: `assemble_gif` nunca anexava `out_path` aos args do ffmpeg →
  ffmpeg exit "output file must be specified", `errorOccurred` só fazia
  `deleteLater` — GIF sumia sem erro visível. Fix: `<< out_path` nos args.
- **Verificação**: PNG `exports/01_hello_pixel_*.png` (1150x1200, gradiente
  correto); GIF `exports/02_time.gif` (77 frames, 480px, 11.5MB); ambos 0
  reports ASan.

### Regressão final (2026-10-24, pós-todos os fixes)

Ciclo completo em 1 boot sob ASan (pid 82440): boot 01_hello_pixel →
abrir EXPORT → PNG exportado (`exports/01_hello_pixel_20261024_235307.png`)
→ quit pelo traffic light → **exit 0, lock liberado, 0 reports ASan**.

Plano de migração (etapa 9 parcial): PNG/GIF export funcional no port;
restam no stage 9: 3D orbit + cgltf + LEARN (fora do escopo desta caçada).

### P2 do audit aplicado: tokens de cor (theme.hpp)

4 superfícies com hex inline divergindo entre si → constantes em
`theme.hpp` (`kSurfaceTray/Bench/Panel`, `kTextPrimary/Muted`,
`kSignal*`) consumidas via `.arg()` nos stylesheets de topbar, strip,
panel e scene list. Visual idêntico (screenshot pós-tokenização); fonte
única de verdade = DESIGN.md. Nota: `scene_list_layout_ = new
QVBoxLayout` foi engolido pela edição do stylesheet durante o refactor —
UBSan/ASan pegaram na hora (null deref no boot); restaurado. A lição
valida o harness: a caçada roda em cada rebuild.

### P1 do audit aplicado: a11y (AX names + TabFocus)

- `setAccessibleName` nos 7 strip buttons (nome do modo), nos 3 traffic
  lights ("close"/"minimize"/"zoom", com chaves ES/PT no catálogo i18n —
  `tr()` tem passthrough EN para chaves ausentes) e tooltips já existentes
  nos botões save/pause. Verificado via AX: `description`/`title` populados
  em todos os botões de janela.
- `setFocusPolicy(Qt::TabFocus)` em save/pause/strip/gear (era NoFocus —
  usuário de teclado não chegava a nenhum controle) + `setTabOrder`:
  selector → save → pause → strip na ordem do modo.
- Limite de verificação: keystroke sintético de Tab não move o foco
  visivelmente dentro da janela SDL-hosted (mesma limitação do keyboard
  input já anotada). O código é Qt padrão; verificação manual = Tab real.

### P3 do audit aplicado: font sizes sem QInputDialog

Dois achados num só lugar: (1) `QInputDialog::getDouble` cru para font
sizes — diálogo genérico Qt fora do darkroom look; (2) "ui font" era
persistido mas NUNCA aplicado (app font hardcoded `code_font(12)` em
`apply_palette`) — setting morto. Fix: submenus nativos de tamanhos fixos
(mesmo padrão do theme picker, já testado) e `qApp->setFont(
theme::ui_font(pt))` no pick de ui font; editor font aplica via
`editor_->set_editor_font` existente. `QInputDialog` sobra só no
create-scene (getText, uso legítimo).
- Verificação: menu abre com language/theme/editor font/ui font (screenshot
  gis_gearfont.png); submenu de tamanhos usa o mesmo caminho do theme
  submenu (interação idêntica comprovada); boot→quit limpo (exit 0, 0 ASan).
