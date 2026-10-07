# imnodes-odin

**Porte em Odin da biblioteca [imnodes](https://github.com/Nelarius/imnodes) (C++).**

imnodes é uma biblioteca de node editor para [Dear ImGui](https://github.com/ocornut/imgui)
escrita por Nelarius (Johannes Hircheis) e licenciada sob MIT. Este diretório contém uma
migração manual do código C++ (`vendor/imnodes/imnodes.cpp`, `imnodes.h`,
`imnodes_internal.h`) para Odin idiomático — não é um binding: todo o estado e a lógica
vivem em Odin, chamando a Dear ImGui através do binding `vendor/odin-imgui`.

O código C++ original permanece em `vendor/imnodes/` como referência. A licença MIT
original é preservada (ver `vendor/imnodes/LICENSE.md`).

## Decisões de migração (C++ → Odin)

| C++ | Odin |
|---|---|
| `namespace ImNodes` | `package imnodes` |
| `ImVector<T>` | `[dynamic]T` |
| `ImGuiStorage` (id → idx) | `map[i32]i32` |
| `ImObjectPool<T>` (template) | `Object_Pool($T)` (struct paramétrico) |
| `ImOptionalIndex` (sentinela -1) | `Maybe(int)` |
| `ImRect` / `ImVec2` + math operators | `Rect` local + helpers `v2_*`/`rect_*` sobre `imgui.Vec2` |
| Construtores com defaults | valores default nos campos + `*_init()` |
| Out-params (`int* node_id`) | múltiplos retornos `(bool, i32)` |
| `enum` de flags (`1 << n`) | `bit_set` |
| `ImGuiTextBuffer` + `appendf` | `strings.Builder` |
| `sscanf` (parse INI) | `core:strings` + `core:strconv` |
| `IM_ASSERT` | `assert` |
| `IM_COL32` | `im_col32()` |

## Alocadores

- **Estado persistente** (pools de nós/pins/links, seleções, mapas): `context.allocator`
  capturado no momento de `create_context()`.
- **Scratch por frame** (buffers transientes, strings INI, arrays temporários em
  interações): `context.temp_allocator` — liberado implicitamente a cada frame, sem
  custo de free individual.
- Arrays per-frame reutilizados todos os frames (`node_indices_overlapping_with_mouse`,
  `occluded_pin_indices`) ficam como `[dynamic]` persistentes e são apenas `clear()`ados,
  evitando realocação — mesma estratégia do `ImVector` original.

`save_editor_state_to_ini_string()` retorna uma string alocada no **temp allocator**:
copie-a (`strings.clone`) se precisar retê-la além do frame.

## Uso

```odin
import imnodes "vendor/imnodes-odin"
import im "vendor/odin-imgui"

ctx := imnodes.create_context()

imnodes.begin_node_editor()
imnodes.begin_node(1)
imnodes.begin_node_title_bar()
im.TextUnformatted("meu nó")
imnodes.end_node_title_bar()
imnodes.begin_input_attribute(2)
imnodes.end_input_attribute()
imnodes.begin_output_attribute(3)
imnodes.end_output_attribute()
imnodes.end_node()
imnodes.link(4, 2, 3)
imnodes.end_node_editor()

if ok, start, end := imnodes.is_link_created(); ok { /* ... */ }
```

## Extensões vs. C++

- `get_canvas_origin_screen_space()` — expõe a origem do canvas (o C++ a mantém em
  `GImNodes->CanvasOriginScreenSpace`, interno); útil para conversão screen→grid
  fora da biblioteca, como fazia o wrapper `ine`.
- **Zoom** (não existe no upstream C++): `editor_context_set_zoom(zoom, pivot)` /
  `editor_context_get_zoom()`, limitado a `[ZOOM_MIN, ZOOM_MAX]` (0.25–3.0).
  Modelo: o grid space continua sendo o espaço canônico não escalado
  (`editor = grid * zoom + panning`), então posições de nós, snapping e o
  arquivo INI são invariantes ao zoom. Escalados com o zoom: texto dos nós
  (`PushFontFloat`, já que a lib imgui vendada não exporta
  `SetWindowFontScale`), padding/borda/rounding, pin shapes e seus hover
  radii, espessura e hover distance dos links, e o grid. O minimap mostra o
  conteúdo inteiro e não é afetado. O estado INI ganha uma linha `zoom=` na
  seção `[editor]` (o parser upstream ignora linhas desconhecidas).
  Em `zoom == 1.0` todos os caminhos são bit-idênticos ao upstream.

## Diferenças conhecidas vs. C++

- `get_io()`/`get_style()` retornam ponteiros (`^IO`, `^Style`) no lugar de referências.
- Queries com out-param retornam tuplas: `is_link_created()` → `(created: bool, started_at: i32, ended_at: i32, from_snap: bool)`.
- `ImGui::ItemAdd` (símbolo interno da Dear ImGui) é vinculado pelo nome mangled Itanium
  em macOS/Linux; no Windows o registro do title bar como item é pulado
  (efeito: `imgui.IsItemHovered()` logo após `end_node_title_bar()` não reporta o title bar).
- A API usa `i32` onde o C++ usa `int`.
- Violações de invariantes internas (escopo begin/end desbalanceado, id de nó
  inexistente, stacks de push/pop desencontrados) logam via `core:log`
  (`imnodes: ...`) e entram em `panic` em todos os builds — o `assert` do Odin
  é compilado fora no release (`-disable-assert`), o que transformaria essas
  falhas em leitura fora dos limites/UB silencioso.
- Verificações ainda como `assert` (baixo risco, guardam chamadas de biblioteca
  entre si, não dados do usuário): limites de canais do splitter, validação de
  formato do INI e o Tamanho de estimativa do buffer de serialização.
- Problemas herdados do upstream C++ (documentados como TODO no código):
  hover de pin usa o raio global do estilo em vez do valor no momento do
  `begin_*_attribute`; `draw_list_sort_channels_by_depth` é O(N²).
