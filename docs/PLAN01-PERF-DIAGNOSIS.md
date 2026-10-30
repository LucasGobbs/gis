# Plan 01 — Diagnóstico: Stutter no Preview e no Autocomplete

Data: 2026-10-28 · Métodos: instrumentação temporária (`GIS_PERF=1`), sims
sintéticas (`GIS_PERF_SIM=drag|type`), `sample(1)` no thread principal.
Instrumentação: `src/ui/perf_probe.hpp` + probes `perf_log()` marcados
`TEMP-PROF` em `src/ui/shell.cpp`, `src/ui/editor.cpp`, `src/host_main.mm`.
Remover após as correções (compila fora com `-DNO_PERF_PROBE`).

---

## Problema 1 — Travamento ao redimensionar o Preview

### Causa identificada

**Não há gargalo no caminho de resize em si — o custo está no redesenho do
editor QScintilla que muda de largura a cada evento do gutter, mais o custo
estrutural de sincronizar duas janelas nativas (Qt NSWindow + SDL NSWindow
filho) via `setFrame:` a cada tick.** Nada disso é GPU; nada disso recria
shaders ou framebuffers por evento.

O que acontece a cada mouse-move durante o drag do gutter (~120 Hz):

1. `Shell::set_split_gutter()` → `update_preview_overlays()` +
   `update_split_layout()` (`src/ui/shell.cpp:1869-1877`). Custo medido:
   **0.009 ms mediana** — irrelevante.
2. O `editor_dock_` tem `maximumWidth` reescrito → re-layout do QTabWidget →
   **repaint completo do QScintilla visível** (a cada fração de pixel).
3. Em paralelo, o host (tick a 60 Hz) chama
   `[sdl_nswin setFrame:want display:YES]` sempre que `want != frame`
   (`src/host_main.mm:737-739`), e o Qt reconcilia a janela SDL filha
   (NSWindowAbove) — duas janelas nativas se movendo por tick.

### Evidências

| Métrica (drag sim, 200 ms, ~120 Hz) | Valor |
|---|---|
| `gutter-drag-ms` (overlays + clamp) | 0.009 ms mediana, 0.79 max (1ª chamada) |
| `split-layout-ms` | 0.000 ms mediana |
| `split-tick-ms` (host: setFrame + caption + overlays) | 0.35 ms mediana, 0.48 p95 |
| `frame-rect-ms` (Qt overlay do frame) | 0.005 ms mediana |
| Gaps no frame-tick (UI thread) durante drag | **nenhum > 130 ms** |

- O outlier de 4.7 ms no `split-tick` ocorre só no primeiro tick após o boot
  (criação inicial dos overlays), não durante o drag.
- `targets_resize()` (`src/gfx/scene_runtime.cpp:39-82`) roda **1× por
  mudança de tamanho do viewport**, não por evento do gutter (o viewport
  inteiro não muda no drag; só a divisão editor|preview). Nenhuma recriação
  de textura/shader por evento confirmada.
- O stutter **perceptível** não aparece nos timers porque acontece no
  compositor: repaint integral do QScintilla (widget opaco, sem
  `WA_OpaquePaintEvent` ajustado no caminho do split) + `display:YES` em
  `setFrame:` força sincronia com o window server a cada passo.

### Arquivos/funções envolvidos

- `src/ui/shell.cpp` — `set_split_gutter()`, `update_split_layout()`,
  `update_preview_overlays()`, `settle_split_gutter()` (spring 240 ms no
  drop; cada frame do spring repete o par overlay+clamp — 15× por drop).
- `src/host_main.mm:726-747` — branch SPLIT do tick: `setFrame:display:YES`,
  `set_pip_overlay()` (0.25 ms mediana — `setStyleSheet` + `adjustSize` +
  `mapToGlobal` por tick), `set_preview_frame_rect()`.
- `src/gfx/scene_runtime.cpp` — `targets_needs_resize/targets_resize`
  (corretos; não são o problema).

### Correções recomendadas (impacto ↑ primeiro)

1. **Editor com largura congelada durante o drag** (baixo risco): durante
   `gutter_dragging_`, aplicar o clamp só no `settle_split_gutter` (drop);
   durante o drag, o editor fica com a última largura e só o frame/gutter
   acompanham o cursor. Elimina o repaint do QScintilla por mouse-move.
2. **`display:NO` no `setFrame:`** do branch SPLIT/FULL (1 linha):
   `display:YES` força flush síncrono com o window server por tick;
   `display:NO` deixa o compositor agrupar. Risco: nenhum observável
   (o SDL redraw cobre o conteúdo no próximo frame).
3. **`set_pip_overlay` sem `setStyleSheet` quando o texto não muda de
   estado** (`src/ui/shell.cpp:2329`): o estilo só depende do estado
   (error/compiling/paused/normal); cachear a última cor e pular o
   `setStyleSheet`+`adjustSize` quando inalterado. 0.25 ms/tick → ~0.
4. **Spring do drop**: rodar os overlays só no fim do spring (ou
   `reduced_motion()`); mantém o visual e corta 15× o par overlay+layout.

### Testes de confirmação

- Repetir `GIS_PERF=1 GIS_PERF_SIM=drag`: `gutter-drag-ms` deve ficar < 0.05
  ms p95; nenhum gap > 130 ms no frame-tick.
- Métrica nova sugerida: contador de repaints do editor durante o drag
  (deve cair para ≤ 1).
- Smoke manual: drag lento e rápido do gutter; editar código durante o drag
  sem perder o cursor; drop em 0.2/0.8 (clamp) persiste via prefs.

---

## Problema 2 — Travamento com sugestões/autocomplete

### Causa identificada

**Dois mecanismos de autocomplete ativos ao mesmo tempo, e o nativo do
QScintilla é o caro:**

1. **`AcsDocument` do QScintilla** (`src/ui/editor.cpp:470-471`,
   threshold 2): a cada tecla, `SCN_CHARADDED` →
   `startAutoCompletion()` → o popup do Scintilla é **destruído e recriado
   como NSWindow nativo a cada disparo**. `sample(1)` durante a digitação:
   ~96 de 2 000 amostras (2 s, 4 teclas) dentro de
   `SCN_CHARADDED → startAutoCompletion → QWidget::create →
   QCocoaWindow::createNSWindow → NSWindow initWithContentRect →
   SLSWindowIsOrderedIn (mach_msg para o SkyLight)` — **~24 ms de chamada
   síncrona ao window server POR TECLA**.
2. **slangd via LSP** (`src/ui/editor.cpp:553-575`): já está correto —
   debounce 130 ms, `kMaxCompletions` 60, `completion-handle-ms` medido em
   **2.8-4.3 ms** no main thread (JSON parse + filtro + `showUserList`).
   O `showUserList` cria o MESMO tipo de popup nativo (segunda janela).

O caminho de digitação puro (sem popup) é rápido: gaps de frame durante a
digitação ficaram ≤ 20 ms nas sims; o custo só aparece quando o popup
nativo entra em cena — e é GUI-side (SkyLight), não CPU do parser.

### Evidências

| Métrica | Valor |
|---|---|
| `completion-send → completion-reply` (slangd round-trip) | ~200-700 ms 1ª resposta (parse do módulo no servidor), depois ~ms |
| `completion-handle-ms` (main thread, filtro+showUserList) | 2.8 ms (n=1 mediana), 4.3 max |
| `lsp-write-ms` (write no pipe) | 0.011 ms |
| `lsp-read-ms` (readyRead + dispatch) | 0.01-0.5 ms |
| Amostras no `sample` dentro de `createNSWindow` por tecla | 96/2000 (≈24 ms/tecla em mach_msg SkyLight) |
| Gaps de frame durante digitação (popup ativo) | 2× ~150 ms após última tecla (popup nativo + reply) |

Nota: a primeira resposta do slangd demora porque o `didChange` (280 ms
debounce) dispara re-parse completo do módulo no servidor; isso é latência
do slangd, não travamento da UI — a UI segue viva nesse intervalo.

### Arquivos/funções envolvidos

- `src/ui/editor.cpp:470-471` — `setAutoCompletionSource(AcsDocument)` +
  `setAutoCompletionThreshold(2)`: gatilho do popup nativo por tecla.
- `src/ui/editor.cpp:1262-1296` — handler `completion` (ok; `showUserList`
  reusa o popup nativo).
- `src/ui/editor.cpp:973-997` — `send_lsp` gate (correto).
- QScintilla 2.14.1 (`/opt/homebrew/opt/qscintilla2`): `startAutoCompletion`
  destrói/recria o widget popup por disparo.

### Correções recomendadas (impacto ↑ primeiro)

1. **Um só mecanismo**: desligar `AcsDocument` (`AcsNone`) e manter o
   popup slangd (`showUserList`) como único autocomplete — já vem
   filtrado por prefixo, cap 60, e o custo main-thread é 3 ms. Isso remove
   a recriação de NSWindow por tecla. **Não remove autocomplete do
   usuário** (requisito respeitado); só elimina o popup fantasma
   palavra-a-palavra que ninguém pediu. Risco: perder sugestões locais
   quando o slangd está inicializando (3 s) — aceitável; alternativa
   conservadora: `AcsDocument` só nos primeiros 3 s antes do handshake.
2. **Se mantiver AcsDocument**: `SCI_AUTOCSETCANCELATSTART`/reuso do popup
   não é exposto pelo QScintilla 2.14 — não há fix barato dentro da lib;
   a opção 1 é a correta.
3. **didChange incremental** (médio prazo): enviar `rangeLength`/`range`
   em vez de texto cheio (slangd aceita full-text; incremental reduz o
   re-parse da 1ª resposta). Baixa prioridade: não trava a UI.

### Testes de confirmação

- `GIS_PERF=1 GIS_PERF_SIM=type` com `GIS_NO_ACS=1` (já implementado no
  driver TEMP): gaps de frame durante/ após digitação devem desaparecer
  (alvo: nenhum gap > 40 ms com popup do slangd aberto).
- Digitação rápida "float2(" num doc grande: popup abre ≤ 1× por burst
  (130 ms), sem piscadas; aceitar uma sugestão insere e fecha.
- `sample` durante digitação: 0 amostras em `createNSWindow` via
  `SCN_CHARADDED` (só a do reply do slangd, 1× por burst).

---

## Resumo das medições (antes de qualquer otimização)

| Caminho | mediana | p95/max | Veredito |
|---|---|---|---|
| gutter drag (Qt) | 0.009 ms | 0.79 ms (1ª) | OK |
| split-tick host (setFrame+overlays) | 0.35 ms | 0.48 p95 | OK, mas por tick |
| pip-overlay (por tick) | 0.25 ms | 0.86 ms | custo evitável |
| frame-rect (por tick) | 0.005 ms | 0.77 ms | OK |
| targets_resize (GPU) | 1×/resize real | — | OK |
| completion handle (main) | 2.8 ms | 4.3 ms | OK |
| popup QScintilla por tecla | ~24 ms síncrono (SkyLight) | — | **CAUSA** |
| UI gaps no drag | nenhum > 130 ms | — | OK |
| UI gaps na digitação | 2× ~150 ms | — | **CAUSA** (popup) |

## Restrições respeitadas

- Nenhum sistema de renderização reescrito; QScintilla não substituído;
  autocomplete mantido (proposta unifica, não remove).
- Mudanças nesta etapa = instrumentação TEMP-PROF apenas (git diff mostra
  os probes; `perf_probe.hpp` novo; zero mudança de comportamento sem
  `GIS_PERF*`).
- Reprodução + validação: todas as afirmações acima vêm de execuções
  reais (`builds/dev/gis_host`) nesta máquina.
