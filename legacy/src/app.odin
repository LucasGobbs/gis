// Application architecture, incremental Elm style: everything that can
// happen to the app is a Msg, every Msg is applied in exactly one place
// (update), and the view (ui_build, the main loop) emits messages instead
// of mutating state. Effects that touch the OS, the filesystem, or the
// GPU are described as Cmd values and executed by the interpreter in
// main.odin: widgets and editor code never call SDL/OS directly for
// actions. GPU pipelines, scene runtime, and ImGui are untouched: this
// layer is about data flow, not rendering.
//
// Adding a feature: new Msg variant + one case in update + view code
// emitting it. State changes live only here.
package main

import im "../vendor/odin-imgui"
import "core:fmt"
import "core:os"
import "core:log"
import "core:strings"
import "core:text/i18n"
import sdl "vendor:sdl3"

// Union variants in Odin are types, declared before the union.
SceneSelected   :: int
SetMode         :: SidebarMode
TogglePanel     :: struct {}
ToggleSidebar   :: struct {} // Cmd+B: sidebar only
ToggleTheater   :: struct {} // F4
ToggleMobile    :: struct {} // F5: 9:16 portrait recording mode
SetFxIntensity  :: FxIntensity
ToggleFx        :: FxKind
SaveAll         :: struct {}
ExportRequested :: ExportAction
Quit            :: struct {}
DevelopPreview  :: struct {} // EFFECTS panel preview button

ExportAction :: struct {
	kind: ExportRequest,
	at:   [2]f32, // burst origin (the button's center)
}

CreateScene      :: struct {
	kind: SceneTemplateKind,
	name: [64]u8,
}
RenameScene      :: struct {
	old, new: [64]u8,
}
RenameModule     :: struct {
	scene, old, new: [64]u8,
}
BeginRenameScene :: struct {
	title: [64]u8,
}
BeginRenameModule :: struct {
	scene, file: [64]u8,
}
CancelRename     :: struct {}
TogglePause      :: struct {}
CreateModule     :: struct {
	scene: [64]u8,
}
OpenFile         :: struct {
	rel: [256]u8,
}

Msg :: union {
	SceneSelected,
	SetMode,
	TogglePanel,
	ToggleSidebar,
	ToggleTheater,
	ToggleMobile,
	SetFxIntensity,
	ToggleFx,
	SaveAll,
	ExportRequested,
	Quit,
	DevelopPreview,
	CreateScene,
	RenameScene,
	RenameModule,
	BeginRenameScene,
	BeginRenameModule,
	CancelRename,
	TogglePause,
	OpenFile,
	CreateModule,
}

FxKind :: enum {
	DEVELOP,
	SPRINGS,
	GRAIN,
}

// Effects the interpreter (main.odin) executes. Pure state changes
// happen inside update; anything that touches the OS, files, or GPU is
// one of these.
Cmd :: enum {
	QUIT,
	MOBILE_ENTER,
	MOBILE_EXIT,
	SAVE_ALL,
	EXPORT_PNG,
	EXPORT_GIF,
	DEVELOP,
}
Cmds :: bit_set[Cmd]

// The application state owners. update mutates through these pointers;
// nothing else does for message-shaped flows.
App :: struct {
	ui:  ^Ui,
	sm:  ^SceneManager,
	ed:  ^ImGuiEditor,
	ing: ^NodeGraph,
	win: ^sdl.Window,
}

// Bounded per-frame queue: widgets emit during ui_build, main drains
// right after. 64 messages per frame is far beyond real usage.
MSG_CAP :: 64
msg_buf:   [MSG_CAP]Msg
msg_count: int

emit :: proc(msg: Msg) {
	if msg_count >= MSG_CAP {
		log.errorf("msg buffer full, dropped %v", msg)
		return
	}
	msg_buf[msg_count] = msg
	msg_count += 1
}

// Copies s into a NUL-terminated fixed buffer, truncating to fit. Msg
// payloads never allocate: the buffer is the whole string.
msg_copy :: proc(buf: ^$T/[$N]u8, s: string) {
	n := min(len(s), N - 1)
	copy(buf[:n], s[:n])
	buf[n] = 0
}

// Builds a Msg payload buffer from s (see msg_copy).
msg_set :: proc(buf: ^[$N]u8, s: string) {
	msg_copy(buf, s)
}

// Reads a NUL-terminated payload back as a string (view into the Msg).
msg_get :: proc(buf: ^[$N]u8) -> string {
	n := 0
	for n < N && buf[n] != 0 do n += 1
	return string(buf[:n])
}

// Applies one message. The ONLY place message-shaped state changes.
// Returns the effects for the interpreter to execute.
update :: proc(app: ^App, msg: Msg) -> Cmds {
	cmds: Cmds
	local := msg
	switch &message in local {
	case SceneSelected:
		// A GIF capture holds a pointer into sm.scenes; a switch mid-capture
		// would let scene_ensure_loaded/reload reallocate the slice under it.
		if gif_capture.active {
			notify(.WARN, tr("gif capture running: wait for it to finish"))
		} else if message >= 0 && message < len(app.sm.scenes) {
			app.sm.current = message
			// Clear only on a real switch to the awaited scene: a refused
			// switch (GIF capture) keeps pending so the view retries.
			if app.ui.pending_scene != "" && app.sm.scenes[message].title == app.ui.pending_scene {
				delete(app.ui.pending_scene)
				app.ui.pending_scene = ""
			}
		}
	case SetMode:
		app.ui.mode = message
		app.ui.panel_open = true
	case TogglePanel:
		app.ui.panel_open = !app.ui.panel_open
	case ToggleSidebar:
		app.ui.open = !app.ui.open
	case ToggleTheater:
		ui := app.ui
		if !ui.theater {
			ui.theater = true
			ui.saved_ui_font = ui.font_size
			ui.saved_ed_font = app.ed.font_size
			ui.saved_open = ui.open
			ui.saved_ed_open = app.ed.open
			ui.font_size = 18
			im.GetStyle().FontSizeBase = 18
			app.ed.font_size = 21
			ui.open = false // zen slide hides the sidebar
			app.ed.open = true
			app.ed.moved = false // theater docks the editor again
		} else {
			ui.theater = false
			ui.font_size = ui.saved_ui_font
			im.GetStyle().FontSizeBase = ui.saved_ui_font
			app.ed.font_size = ui.saved_ed_font
			ui.open = ui.saved_open
			app.ed.open = ui.saved_ed_open
		}
	case ToggleMobile:
		// Mobile theater: 9:16 portrait window for vertical recordings
		// (TikTok/Instagram). NOT a mobile app: the window just takes
		// phone dimensions so the capture crops cleanly. Sidebar hides,
		// the editor docks to the bottom half, type grows (like F3).
		ui := app.ui
		if !ui.mobile {
			ui.mobile = true
			mobile_theater = true
			ui.mobile_saved_ui_font = ui.font_size
			ui.mobile_saved_ed_font = app.ed.font_size
			ui.mobile_saved_open = ui.open
			ui.mobile_saved_ed_open = app.ed.open
			ui.font_size = 18
			im.GetStyle().FontSizeBase = 18
			app.ed.font_size = 21
			ui.open = false
			app.ed.open = true
			app.ed.moved = false // the bottom dock wins in this mode
			cmds += {.MOBILE_ENTER}
		} else {
			ui.mobile = false
			mobile_theater = false
			ui.font_size = ui.mobile_saved_ui_font
			im.GetStyle().FontSizeBase = ui.mobile_saved_ui_font
			app.ed.font_size = ui.mobile_saved_ed_font
			ui.open = ui.mobile_saved_open
			app.ed.open = ui.mobile_saved_ed_open
			app.ed.moved = false
			cmds += {.MOBILE_EXIT}
		}
	case SetFxIntensity:
		app.ui.fx.intensity = message
	case ToggleFx:
		switch message {
		case .DEVELOP:
			app.ui.fx.develop = !app.ui.fx.develop
		case .SPRINGS:
			app.ui.fx.springs = !app.ui.fx.springs
		case .GRAIN:
			app.ui.fx.grain = !app.ui.fx.grain
		}
	case SaveAll:
		cmds += {.SAVE_ALL}
	case ExportRequested:
		if message.kind == .GIF {
			cmds += {.EXPORT_GIF}
		} else {
			cmds += {.EXPORT_PNG}
		}
	case CreateScene:
		name := msg_get(&message.name)
		if title, ok := scene_create_named(message.kind, name); ok {
			delete(app.ui.pending_scene)
			app.ui.pending_scene = strings.clone(title)
			notify(.INFO, "created %s", title)
		} else {
			notify(.ERROR, "could not create %s", name)
		}
	case RenameScene:
		old := msg_get(&message.old)
		new := msg_get(&message.new)
		if scene_rename(app.ed, old, new) {
			delete(app.ui.rename_key)
			app.ui.rename_key = ""
			delete(app.ui.pending_scene)
			app.ui.pending_scene = strings.clone(new)
		}
	case RenameModule:
		if scene_file_rename(app.ed, msg_get(&message.scene), msg_get(&message.old), msg_get(&message.new)) {
			delete(app.ui.file_rename_key)
			app.ui.file_rename_key = ""
		}
	case BeginRenameScene:
		delete(app.ui.rename_key)
		app.ui.rename_key = strings.clone(msg_get(&message.title))
	case BeginRenameModule:
		delete(app.ui.file_rename_key)
		app.ui.file_rename_key = strings.clone(msg_get(&message.file))
	case CancelRename:
		delete(app.ui.rename_key)
		app.ui.rename_key = ""
		delete(app.ui.file_rename_key)
		app.ui.file_rename_key = ""
	case TogglePause:
		app.ui.params.paused = !app.ui.params.paused
	case CreateModule:
		// Disk effect inside update (D2): first free mod_N.slang in the
		// scene's real root, seeded with a header, then rescan + open.
		scene := msg_get(&message.scene)
		scene_dir := fmt.tprintf("%s/%s", scene_root_dir(scene), scene)
		base := ""
		for n := 1; ; n += 1 {
			candidate := fmt.tprintf("mod_%d.slang", n)
			if !os.exists(fmt.tprintf("%s/%s", scene_dir, candidate)) {
				base = candidate
				break
			}
		}
		name := base[:len(base) - len(".slang")]
		path := fmt.tprintf("%s/%s", scene_dir, base)
		content := fmt.tprintf("// %s: scene-owned module created from the file explorer.\n", base)
		if write_err := os.write_entire_file(path, transmute([]u8)content); write_err != nil {
			notify(.ERROR, "could not create %s", path)
			break
		}
		ied_rescan(app.ed)
		ied_load_named(app.ed, fmt.tprintf("%s/%s/%s", scene_root_dir(scene), scene, name))
		app.ed.open = true
		notify(.INFO, "created %s", path)
	case OpenFile:
		ied_load_named(app.ed, msg_get(&message.rel))
		app.ed.open = true
	case Quit:
		cmds += {.QUIT}
	case DevelopPreview:
		cmds += {.DEVELOP}
	}
	return cmds
}
