# Plano: MenuBar nativo + Titlebar estilizada (cpp_port)

Estado atual: janela `Qt::FramelessWindowHint` (`host_main.mm:289`), top bar Qt
própria (40px) com semáforo desenhado à mão (`Traffic_Light`, 3 QPushButton).
Problemas relatados: (1) semáforo funciona mal — janela frameless não integra
com o WindowServer (snap, Mission Control, gestos, arrastar pela barra são
 hacks manuais); (2) sem menubar nativo.

## Parte A — Menubar nativo (macOS agora, Windows depois)

### Princípio
No macOS, um `QMenuBar` criado **sem parent** vira a barra do sistema
(altura 0 na janela). Ações nativas (About, Quit, Close, Minimize) recebem
`QAction::MenuRole` e o Qt as remapeia para os menus certos do app menu.

### Novo arquivo `src/ui/menubar.cpp` + `menubar.hpp`
Função única `void build_native_menus(Shell& shell);` chamada de
`host_main.mm` após a criação do shell (antes de `shell.show()`).

**Estrutura (Hick: ≤7 itens por menu):**

| Menu | Itens | wiring |
|---|---|---|
| **gis** (app) | About, Preferences… (Cmd+,), Quit | Preferences abre o menu do gear via novo método `Shell::open_settings_menu()`; Quit → `QApplication::quit()` (o aboutToQuit existente já faz flush + lock release) |
| **File** | New Scene… (Cmd+N), Save All (Cmd+S — o QShortcut existente vira aqui), Export PNG (Cmd+E), Export GIF…, sep., Close (Cmd+W → fecha tab do editor; sem editor, esconde painel) | `Shell::new_scene()`, `save_all_requested`, `png_export_requested`, `gif_export_requested` com spinboxes padrão atuais |
| **Scene** | lista dinâmica de cenas (checkable, exclusiva — `QActionGroup`), sep., Open Scenes Folder | populado por `Shell::sync_scene_menu()` chamado de `refresh_scenes()`; ação → `emit scene_selected(i)` (host já salva grafo + lazy-load) |
| **Edit** | Undo/Redo (QScintilla `SCI_UNDO`/`SCI_REDO` no doc ativo), Find (Cmd+F), sep., Zoom In/Out (Cmd+=/-), sep., Editor Theme submenu (reusa as ações do gear) | `Shell::open_settings_menu()` para temas; editor via acessores `Shell::editor_widget()` |
| **Help** | Shortcuts (abre painel SHORTCUTS), sep., Learn/OpenTrail → painel LEARN | `apply_mode(SHORTCUTS)` / `apply_mode(LEARN)` |

**Regras:**
- Toda label via `i18n::tr()` (chaves novas: EN + ES/PT nos catálogos Odin).
- `QAction::setShortcut` só aqui — os QShortcut de janela (Cmd+S) são
  **removidos** para não duplicar disparo.
- `QAction::MenuRole::AboutRole/PreferencesRole/QuitRole` nos 3 itens do app
  menu (macOS reordena sozinho).
- **Windows (fase 2, sem código agora):** mesmo `build_native_menus`, mas o
  QMenuBar ganha parent no Shell e fica na top bar; `nativeMenuBar=false`
  explicito. MenuBar do Windows herda as cores do QSS existente.
- Semáforo do Windows: nativo (`Qt::WindowMinMaxButtonsHint`), sem
  `FramelessWindowHint` — o frame do OS fornece os botões; a top bar Qt
  permanece como toolbar.

## Parte B — Janela nativa + header "invisível"

### Mudança de flag (`host_main.mm:289`)
```
- shell.setWindowFlags(Qt::Window | Qt::FramelessWindowHint);
+ shell.setWindowFlags(Qt::Window | Qt::CustomizeWindowHint |
+                      Qt::WindowTitleHint | Qt::WindowMinMaxButtonsHint |
+                      Qt::WindowCloseButtonHint);
```
E, logo após criar a janela nativa (antes de `show()`):
```objc
qt_nswin.titlebarAppearsTransparent = YES;
qt_nswin.styleMask |= NSWindowStyleMaskFullSizeContentView;
qt_nswin.backgroundColor = [NSColor colorWithSRGBRed:0x1A/255. green:0x1B/255.
    blue:0x20/255. alpha:1]; // kSurfaceBench
qt_nswin.movable = YES; // arrasto nativo pela titlebar
```
(mesma técnica no Windows depois: `DwmSetWindowAttribute` caption color —
 só registrar como fase 2.)

### O que muda na UI
1. **Semáforo nativo volta**: deletar `Traffic_Light` + group-hover
   (`shell.hpp:76-130`) e os 3 `connect`s (`shell.cpp:502-510`). Botões do
   sistema: hit target, acessibilidade e animação corretos de graça — os 3
   achados do W3 somem.
2. **Top bar Qt** vira header fluido: `kTopbarH` 40 → **28px** (macOS titlebar
   padrão ~28); conteúdo (save, pause) desloca 72px à direita via
   `layout->setContentsMargins(80, 0, 12, 0)` para não colidir com os lights.
3. **Desaparecer na UI**: `titlebarAppearsTransparent` + bg `kSurfaceBench`
   fazem a titlebar mesclar com o `QWidget { background: kSurfaceBench }` da
   top bar — uma superfície contínua, sem linha de separação. **O drag vira
   nativo** pela região vazia do header (remove os hacks `mousePressEvent`
   de drag em `shell.cpp:290-316`).
4. **PiP/preview**: `sync_child` usa `qt_nswin.frame` — com
   FullSizeContentView o frame não muda ( contentView é que inclui a
   titlebar); conferir `qt_nsview.bounds` no cálculo do PiP
   (`host_main.mm:571-577`): usar `contentLayoutRect` em vez de `bounds`
   para o PiP não ficar sob a titlebar.
5. **Scene list overlay**: `kTopbarH` como Y-origem continua correto
   (geometry em coords do widget Shell, que agora começa na contentView).

### Migração / ordem
1. `menubar.{hpp,cpp}` + wiring no host; remover QShortcut duplicado do save.
2. Flags da janela + NSWindow styling; deletar Traffic_Light e hacks de drag.
3. Ajustar `kTopbarH` 40→28 + margem 80px dos botões; `contentLayoutRect` no PiP.
4. Catálogos i18n: ~14 chaves novas (menus) + re-gerar `i18n_data.inc`.
5. `make`/cmake build; smoke: hot reload, salvar cena, PiP no F3, zen F1,
   scene switch pelo menu, Cmd+W no editor.

### Riscos
- **Frameless→framed**: o frame somado à janela muda `frameGeometry`;
  centering (`host_main.mm:295`) deve usar `frameGeometry()` após `show()`
  — ajuste de 1 linha se o offset aparecer.
- **FullSizeContentView no Qt Widgets**: o conteúdo Qt pode desenhar sob a
  titlebar (é o desejado — header fluido); garantir que nada clicável caia
  nos primeiros 28px à esquerda (lights nativos ocupam ~70px).
- **SDL child NSWindowAbove**: child continua acima da titlebar nativa —
  sem conflito porque a viewport começa abaixo de `kTopbarH`.
- Windows: rascunho apenas; DWM caption color requer Windows 11 22000+;
  fallback = barra padrão do OS (aceitável).
