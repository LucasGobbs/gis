# Scene lifecycle: criar com nome, renomear cena, renomear arquivos

## Objetivo

No botão `+ new` da toolbar: escolher template **e nome** na criação; depois,
renomear a cena (o nome aparece no seletor, no título da janela, no FILES) e
renomear os arquivos da cena (entry e módulos), tudo pela UI, sem Odin.

## Estado atual (fatos verificados no código)

- **Criação**: `scene_create(kind)` (`scene_templates.odin:111`) cria
  `gis_scenes/<base>/<base>.slang` a partir de 3 templates
  (`COMPUTE`, `GRAPHICS_2D`, `GRAPHICS_3D`), nome auto-incrementado
  (`compute`, `compute_2`, ...). O menu `+ new` (`ui_chrome.odin:200-220`)
  chama isso direto e marca `ui.pending_scene`; `ui_toolbar`
  (`ui_chrome.odin:47-56`) seleciona a cena quando o watcher descobrir.
- **Catálogo**: `scene_names_on_disk()` (`scene_runtime.odin:913`) escaneia
  `src/shaders/scenes/` + `gis_scenes/`, preenche `scene_roots` (nome → raiz)
  e a lista de títulos. `scene_drop_removed`/`scene_add_new_catalog_entries`
  (`:1327`/`:1360`) sincronizam. Renomear no disco = some + aparece.
- **Caminho da cena**: `scene_entry_path` = `<root>/<name>/<name>.slang`;
  `graph.json` = `<root>/<name>/graph.json` (`pipeline_graph_path`,
  root-aware). `scene_roots` é preenchido pelo scan.
- **Build**: `scenes_build(names)` regenera o manifest
  (`src/generated/scenes/manifest.json`) com nomes de artefato
  `<scene>`/`<scene>__<mod>` e roda goose-build; `scene_request_build`
  coleta requests. Renomear regenera tudo com o nome novo.
- **Lacuna 1 — user scenes não editáveis na UI**: o editor só escaneia
  `src/shaders/` (`ied_scan_scene_dirs`, `imgui_editor.odin:464`). Nada de
  `gis_scenes/` entra em `editor.files`; `ied_file_path` (`:525`) monta
  `src/shaders/<file>.slang`. O FILES panel filtra por `"scenes/<título>/"`
  (`ui_sidebar.odin:567`). Consequência: cena nova criada pelo `+ new` não
  abre no editor, não aparece no FILES, e o grafo (`sg_sync`,
  `imgui_nodes.odin:1545`) não gera nós de pass para ela (mesmo prefixo
  hardcoded `scenes/`). Hoje só dá para editar user scene externamente.
- **Renomear hoje**: só símbolos dentro dos arquivos (`ied_rename`,
  `imgui_editor.odin:1162`). Nada renomeia arquivos/cenas.
- **`ied_rescan` é append-only** (`imgui_editor.odin:517`): arquivos
  removidos/renomeados ficam na lista — precisa tratamento no rename.
- **Referências ao nome da cena**: título da janela (`set_window_title`),
  `sm.scenes[i].title`/`source`, `graph.json` (path), `graph_authoritative`,
  nós `comp:`/`gfx:` em `graph.json` (source_key deriva do caminho,
  `scene_runtime.odin:735`), tabs do editor (`ied_open_scene` fecha a unidade
  antiga pelo prefixo `scenes/<unit>/`), `sg_save`/`sg_load_layout` via
  `graph.scene`.

## Decisões (default; sobrescrever se discordar)

- **Criar com nome**: popup no `+ new` com campo de nome + 3 templates
  (radio/segment). Nome vazio ou inválido (vazio, `/`, começa com `.`)
  → botão desabilitado. Colisão com cena existente → aviso inline e botão
  desabilitado. Ao confirmar, `scene_create_named(kind, name)`.
- **Renomear cena**: menu no FILES (linha da cena) + no seletor de cenas
  (contexto no item do combo). Popup `InputText` com validação igual à
  criação. Só para **user scenes** (`scene_root_dir == USER_SCENES_DIR`);
  built-ins moram no repo e renomeá-las sujaria o checkout.
- **Renomear arquivo**: menu de contexto no FILES (cada arquivo da cena
  ativa), mesmo popup de texto. Módulos (`mod_N`, `pass_N`) e o entry.
  Renomear o entry = renomear a cena (mesma operação) — o entry É o nome.
- **Editor/grafo passam a enxergar user scenes** (fase 0, pré-requisito):
  senão renomeia-se uma cena que não se abre nem se edita na UI.

## Fases

### Fase 0 — user scenes no editor e no grafo (pré-requisito)

1. Editor: novo scanner `ied_scan_user_scenes` que adiciona os arquivos de
   `gis_scenes/<name>/` a `editor.files` com prefixo `gis_scenes/...`.
   `ied_file_path` passa a resolver: prefixo `gis_scenes/` → raiz do repo
   (sem `src/shaders`); senão esquema atual. `ied_scene_rel`,
   `ied_open_scene`, `ied_close_unit` (prefixo `scenes/<unit>/`) ganham o
   caso user (`gis_scenes/<unit>/`).
2. FILES panel (`ui_sidebar.odin:567`): lista os arquivos da cena ativa pelo
   prefixo real (`scenes/<título>/` ou `gis_scenes/<título>/`) — derivar o
   prefixo de `scene_root_dir(active_title)`.
3. Grafo: `sg_sync` (`imgui_nodes.odin:1545`) e `sg_create_pass`/`sg_create_combine`
   usam o caminho real da unidade (entry + módulos via `scene_module_names`
   em vez de `ed.files` com prefixo hardcoded). Node click → `ied_load_named`
   com o rel correto.
4. Aceite: criar cena pelo `+ new` → abrir no editor, editar, salvar,
   hot-reload compila; grafo mostra os passes; FILES lista os arquivos.

### Fase 1 — criar com nome

1. `scene_create_named(kind, name) -> (title, ok)` em `scene_templates.odin`:
   valida nome (`^[A-Za-z0-9_\-]+$`, não vazio, sem colisão em
   `scene_names_on_disk()`), cria `gis_scenes/<name>/<name>.slang` do
   template. `scene_create(kind)` vira wrapper com nome auto (para testes).
2. Popup `##scene_new` (`ui_chrome.odin`): abre ao clicar `+ new` (o combo
   vira botão). Nome + template + botão Create; `Enter` confirma.
3. i18n: chaves novas no catálogo ES/PT (`i18n.odin`).
4. Aceite: nome escolhido vira o título; colisão avisa; `Esc` cancela.

### Fase 2 — renomear cena

1. `scene_rename(old, new) -> bool` (`scene_runtime.odin`):
   1. Guardas: só user scene; nome válido; destino livre.
   2. `ied_save_all` (flush de tabs sujas da cena).
   3. Fechar tabs da unidade antiga (`ied_close_unit`).
   4. `os.rename(gis_scenes/old, gis_scenes/new)`.
   5. Renomear o entry `old.slang` → `new.slang` (o arquivo dentro do dir).
   6. Limpar `scene_roots[old]`; regenerar manifest + rebuild da cena
      (`scene_request_build([new])`); `pipeline_scene_init` do novo título
      quando o watcher descobrir (o mecanismo `pending_scene` reutilizado
      renomeia a seleção corrente).
   7. `sg_save`/`sg_load_layout` não precisam migração: `graph.json` viaja
      com o dir; os endpoints `comp:gis_scenes/old/...`/`gfx:...` DENTRO do
      graph.json referenciam o caminho antigo → reescrever o prefixo
      `gis_scenes/old/` → `gis_scenes/new/` no graph.json após o rename
      (texto simples, chaves `comp:`/`gfx:` e `scenes/old/...` se houver).
2. UI: no FILES, menu de contexto na cena (Rename); no seletor de cenas,
   `Selectable` com clique-direito? (combo do ImGui não tem contexto nativo —
   usar botão de lápis ao lado do combo ou item no próprio combo com ícone).
   Popup `##scene_rename` reutilizando o estilo do popup de renomear nó.
3. Janela: `set_window_title` já roda no scene-change path.
4. Aceite: renomear `compute` → `meu_shader`: seletor mostra `meu_shader`,
   editor abre `gis_scenes/meu_shader/meu_shader.slang`, grafo preserva nós/
   links (keys reescritas), hot-reload compila, `graph.json` sem links
   quebrados.

### Fase 3 — renomear arquivos da cena

1. `scene_file_rename(scene, old_rel, new_name) -> bool`:
   - Módulo (`mod_N`/`pass_N`): `os.rename` do `.slang`; a ordem do chain
     deriva do nome (`pass_1 < pass_2`), renomear reordena — documentado no
     log (`[scenes] module renamed, pass chain order may change`).
   - Entry: delegar para `scene_rename` (é o mesmo ato).
2. UI: menu de contexto nos itens do FILES (Rename / Delete?), popup com
   InputText e validação (mesma regex, sem colisão no dir).
3. Rescan do editor + rebuild da cena.
4. Aceite: renomear `mod_1.slang` → `noise.slang`: FILES atualiza, editor
   reabre no arquivo novo, cena recompila.

### Fase 4 — polimento

- Toasts de sucesso/erro (`notify`), i18n completo, log `[scenes]`.
- Borda: cenas abertas em tabs sujas de OUTRA cena não são afetadas.

## Riscos

- `ied_rescan` append-only: após rename, `editor.files` teria velho+ novo —
  a fase 0/2 precisa de uma pruned rescan (ou remove+append pontual).
- `graph.json` legado com keys `comp:scenes/<old>/...` em user scenes
  criadas antes da fase 0: a reescrita de prefixo deve cobrir também
  `scenes/<old>/` → `gis_scenes/<new>/` quando `scene_root_dir == gis`.
- Dois lugares mandam no catálogo (scan de disco + `sm.scenes`): o rename
  não deve tocar `sm.scenes` direto — deixar o watcher descobrir (padrão do
  `pending_scene`), evitando corrida com `scene_build_pump`.

## Fora de escopo (não pedido)

- Excluir cenas/arquivos (o menu pode ganhar depois; hoje só rename).
- Renomear built-ins (repo).
- Reordenar o chain por drag (a ordem continua lexical).
