// gis_host: Qt shell + SDL GPU scene runtime in ONE window: the SDL window is
// a borderless NSWindow ordered as a child of the Qt window, parked over the
// Shell's viewport widget (SDL's setContentView path would orphan the Qt
// chrome). Render loop = manual pump/processEvents loop; a QTimer under
// app.exec() stalls Metal presents for SDL windows.
//
// KNOWN ISSUE (stage 7): slang's gl_FragCoord varying (TEXCOORD_1) depends on
// a vertex-stage uniform that never arrives on this SDL+Metal path — scenes
// using scene_uv(input.gl_FragCoord, ...) would draw a single flat color.
// FIXED in load_shader_raw (scene_runtime.cpp): the fragment MSL is rewritten
// to derive pixel coords from the interpolated [[position]] (which works).
// If a scene draws flat again, check that the rewrite still matches the
// slang-generated symbol names.
#include "gfx/gfx.hpp"
#include "gfx/scene_runtime.hpp"
#include "gfx/assets.hpp"
#include "ui/notify.hpp"
#include "ui/shell.hpp"
#include "ui/menubar.hpp"

#include <oclero/qlementine/icons/QlementineIcons.hpp>
#include <oclero/qlementine/style/QlementineStyle.hpp>

#include <QApplication>
#include "ui/theme.hpp"
#include <QCursor>
#include <QIcon>
#include <QFileSystemWatcher>
#include <QTimer>

#include "ui/perf_probe.hpp" // TEMP-PROF: Plan 01 diagnosis, remove after
#include <Qsci/qsciscintilla.h> // TEMP-PROF shim: setFocus on the tab
#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#include <algorithm>
#include <clocale>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <AppKit/AppKit.h> // before Qt: Qt headers #define slots, breaking Foundation
#endif

#include "gfx/gfx.hpp"
#include "gfx/scene_runtime.hpp"
#include "ui/notify.hpp"
#include "ui/shell.hpp"

#include <oclero/qlementine/icons/QlementineIcons.hpp>

#include <QApplication>
#include "ui/theme.hpp"
#include <QCursor>
#include <QIcon>
#include <QFileSystemWatcher>
#include <QDir>
#include <QDirIterator>
#include <QDateTime>
#include <QFileInfo>
#include <QImage>
#include "export/export_flow.hpp"
#include "gfx/camera.hpp"
#include "gfx/inspect.hpp"
#include <sys/stat.h>
#include <ctime>
#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#include <algorithm>
#include <cstdio>
#include <set>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/CAMetalLayer.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <QWindow>
#include <QScreen>
#endif

static SDL_GPUShader* blit_vs = nullptr;
static SDL_GPUShader* blit_fs = nullptr;

// Loads the baked blit pipeline (src/generated/blit.{vert,frag}.msl).
static bool load_blit(SDL_GPUDevice* dev) {
    auto load = [&](const char* path, const char* entry, SDL_GPUShaderStage stage,
                    Uint32 ubufs, Uint32 samplers) -> SDL_GPUShader* {
        std::ifstream f(path, std::ios::binary);
        if (!f) return nullptr;
        std::stringstream ss;
        ss << f.rdbuf();
        std::string code = ss.str();
        SDL_GPUShaderCreateInfo ci{};
        ci.stage = stage;
        ci.format = SDL_GPU_SHADERFORMAT_MSL;
        ci.code = reinterpret_cast<const Uint8*>(code.data());
        ci.code_size = code.size();
        ci.entrypoint = entry;
        ci.num_uniform_buffers = ubufs;
        ci.num_samplers = samplers;
        return SDL_CreateGPUShader(dev, &ci);
    };
    blit_vs = load("src/generated/blit.vert.msl", "vertMain", SDL_GPU_SHADERSTAGE_VERTEX, 0, 0);
    blit_fs = load("src/generated/blit.frag.msl", "pixelMain", SDL_GPU_SHADERSTAGE_FRAGMENT, 0, 1);
    return blit_vs && blit_fs;
}

// Walks up from cwd and the executable dir to find the repo root (the dir
// containing src/shaders/scenes) and chdirs there. Covers `make run-cpp` from
// the repo root, CLion (cwd = build dir) and Finder launch.
static bool chdir_repo_root() {
    namespace fs = std::filesystem;
    const fs::path starts[2] = {fs::current_path(),
                                fs::path(QApplication::applicationDirPath().toStdString())};
    for (const auto& s : starts)
        for (fs::path p = s; !p.empty(); p = p.parent_path())
            if (fs::exists(p / "src/shaders/scenes")) {
                fs::current_path(p);
                return true;
            }
    return false;
}

// ---- PiP drag + resize (editor page) ----
// The preview frame is the SAME SDL child window; in editor mode it floats
// and the user must be able to drag it and resize it from its edges (to
// park it beside a split editor, etc). A borderless NSWindow has no chrome,
// so this local NSEvent monitor implements both gestures: border hit ->
// resize from that edge; interior -> drag the whole frame. While DRAGGING,
// the cursor position is hit-tested against the viewport's snap zones
// (left/right half = dock split there, anywhere else = keep floating); the
// shell paints the zones, the drop applies the mode. State persists in
// assets/ui.prefs (pip_x/pip_y/pip_w/pip_h) via the lambda-captured
// pointers below.
static NSRect g_pip_rect = NSZeroRect;   // current preview frame (screen)
static bool g_pip_drag = false;          // moving the whole frame
static bool g_pip_resize = false;        // resizing from an edge
static int g_pip_edges = 0;              // bitmask: 1=L 2=R 4=T 8=B
static NSPoint g_pip_last;               // last drag position (screen)
static int g_snap_zone = -1;             // live hover: 0=left 1=right -1=none
static const CGFloat kPipEdge = 8.0;     // resize band width in points (unified with gutter)
static std::string* g_prefs_path = nullptr;

static int pip_edges_at(NSPoint p) {
    int e = 0;
    if (p.x - g_pip_rect.origin.x < kPipEdge) e |= 1;
    if (g_pip_rect.origin.x + g_pip_rect.size.width - p.x < kPipEdge) e |= 2;
    if (p.y - g_pip_rect.origin.y < kPipEdge) e |= 4;
    if (g_pip_rect.origin.y + g_pip_rect.size.height - p.y < kPipEdge) e |= 8;
    return e;
}

static void pip_save_prefs() {
    if (!g_prefs_path) return;
    std::ofstream f(*g_prefs_path, std::ios::app);
    // rewrite only pip lines: read, filter, write
    std::ifstream in(*g_prefs_path);
    std::stringstream all;
    all << in.rdbuf();
    std::ofstream out(*g_prefs_path, std::ios::trunc);
    std::string line;
    while (std::getline(all, line)) {
        if (line.rfind("pip_", 0) == 0) continue;
        out << line << "\n";
    }
    out << "pip_x=" << (int)g_pip_rect.origin.x << "\n"
        << "pip_y=" << (int)g_pip_rect.origin.y << "\n"
        << "pip_w=" << (int)g_pip_rect.size.width << "\n"
        << "pip_h=" << (int)g_pip_rect.size.height << "\n";
}

// Camera state shared between the NSEvent monitor (writer) and the frame
// tick (reader); both run on the main thread. The monitor block fills the
// pointers at startup; the tick dereferences them.
static float* g_cam_yaw = nullptr;
static float* g_cam_pitch = nullptr;
static float* g_cam_dist = nullptr;
static bool* g_fly_on = nullptr;
static float* g_fly_pos = nullptr;   // float[3]
static float* g_fly_yaw = nullptr;
static float* g_fly_pitch = nullptr;
static bool g_fly_keys[6] = {false, false, false, false, false, false}; // W A S D E Q
static bool g_fly_shift = false;
static double g_fly_last_t = -1.0;   // tick time of the last flycam step
static float g_app_time = 0.0f;      // scene clock, updated by the tick

static NSEventMask g_pip_mask = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged |
                                NSEventMaskLeftMouseUp | NSEventMaskMouseMoved;
// GIF capture state (host-driven): dump one PNG per tick while active.
static volatile bool g_gif_capture = false;
static float g_gif_end_s = 0.f;
static int g_gif_frame_n = 0;
static float g_gif_started_s = 0.f;
// Pixel provenance (stage 8): click → 1x1 readback of the scene target.
static inspect::Provenance_Readback prov_readback;
static bool prov_pending = false;
static int last_click_x = 0;
static int last_click_y = 0;
// M5: --pixel-test X Y — CLI regression probe: render N frames, read back
// one pixel of the scene target, print rgba, quit. Legacy parity
// (selftest.odin), reuses the provenance 1x1 readback path.
static bool pixel_test_on = false;
static int pixel_test_x = 0, pixel_test_y = 0;
static int pixel_test_settle = 30; // frames before sampling (bake settle)
static bool shot_on = false;
static const char* shot_path = nullptr;
static id g_pip_monitor = nil;

int main(int argc, char** argv) {
    // C locale for BOTH Qt (QLocale below) and the C runtime: --pixel-test
    // prints '.'-decimal to stdout for diffing; the system locale (pt_BR)
    // would render "0,141" and break numeric comparison.
    std::setlocale(LC_ALL, "C");
    QApplication app(argc, argv);
    // C locale: uniforms are '.'-decimal; the system locale (pt_BR) renders
    // spinboxes as "0,25" and then rejects round-trip typed input.
    QLocale::setDefault(QLocale::c());
    // QApplication's ctor calls setlocale(LC_ALL, "") on macOS (picks up
    // the user environment); re-assert "C" AFTER it, or --pixel-test's
    // stdout is pt_BR "0,141" instead of "0.141".
    std::setlocale(LC_ALL, "C");
    // Qlementine owns the whole UI look: one dark theme JSON + matching icons.
    oclero::qlementine::QlementineStyle* style =
        new oclero::qlementine::QlementineStyle(&app);
    style->setThemeJsonPath(":/qlementine/resources/themes/dark.json");
    app.setStyle(style);
    theme::load_fonts();
    theme::apply_palette(app, style); // theme:: owns the runtime-switch handle
    QIcon::setThemeName("qlementine");
    if (!chdir_repo_root()) {
        std::fprintf(stderr, "repo root not found (no src/shaders/scenes up from cwd/app dir)\n");
        return 1;
    }

    // Single instance: a second gis_host fighting the first for the Metal
    // device / SDL child window raced MTLCompilerService at startup and
    // died with std::bad_alloc before any log line (observed once). Same
    // O_EXCL lockfile pattern as scenes_build (crash-stale after 60 s).
    {
        std::string lock_path = "assets/gis.lock";
        FILE* f = std::fopen(lock_path.c_str(), "wx");
        if (!f) {
            struct stat st;
            bool stale = false;
            if (::stat(lock_path.c_str(), &st) == 0)
                stale = ::time(nullptr) - st.st_mtime > 60; // crashed holder
            if (!stale) {
                std::fprintf(stderr, "gis_host is already running (assets/gis.lock held); close it first\n");
                return 1;
            }
            ::remove(lock_path.c_str());
        } else {
            std::fclose(f); // the lock IS the file's existence
        }
    }

    // Scene name: bare positional arg ("01_hello_pixel") or "--scene NAME".
    // QApplication consumed only Qt-recognized args; ours stay in argv.
    const char* scene_name_arg = "01_hello_pixel";
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--scene") == 0 && i + 1 < argc) {
            scene_name_arg = argv[i + 1];
            ++i; // value consumed
            continue;
        }
        if (std::strcmp(argv[i], "--pixel-test") == 0 && i + 2 < argc) {
            pixel_test_on = true;
            pixel_test_x = std::atoi(argv[i + 1]);
            pixel_test_y = std::atoi(argv[i + 2]);
            i += 2;
            continue;
        }
        if (std::strcmp(argv[i], "--shot") == 0 && i + 1 < argc) {
            shot_on = true;
            shot_path = argv[i + 1];
            ++i;
            continue;
        }
        if (argv[i][0] != '-') {
            scene_name_arg = argv[i];
            continue;
        }
    }

    // SDL assertion failures popping a modal dialog via dispatch_sync would
    // deadlock the app. Log and ignore.
    SDL_SetAssertionHandler(
        [](const SDL_AssertData* data, void* userdata) {
            (void)userdata;
            std::fprintf(stderr, "[sdl-assert] %s:%d %s\n", data->filename, data->linenum,
                         data->condition);
            return SDL_ASSERTION_IGNORE;
        },
        nullptr);

    // SDL installs a SIGTERM->quit handler but nothing pumps SDL events in
    // this host, so SIGTERM never killed the process (zombie accumulation).
    // Hint must precede SDL_Init.
    SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        std::fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    // Stub scenes first (lazy load, like the Odin app), then load only the
    // active one once GPU + window exist.
    std::map<std::string, std::string> scene_roots;
    auto names = scene::scene_names_on_disk(scene_roots);
    if (names.empty()) {
        std::fprintf(stderr, "no scenes found (run: make shaders)\n");
        return 1;
    }
    scene::Scene_Manager manager;
    for (const auto& n : names) {
        scene::Runtime_Scene st;
        st.title = n;
        st.user_owned = scene::scene_root_dir(scene_roots, n) == scene::USER_SCENES_DIR;
        manager.scenes.push_back(std::move(st));
    }
    auto it = std::find(names.begin(), names.end(), scene_name_arg);
    if (it == names.end()) {
        std::fprintf(stderr, "scene %s not found. Available:\n", scene_name_arg);
        for (const auto& n : names) std::fprintf(stderr, "  %s\n", n.c_str());
        return 1;
    }
    int idx = int(it - names.begin());
    manager.current = idx;
    shell::Shell shell(nullptr, manager, scene_roots);
    // Frameless window: the Shell's own top bar IS the title bar — custom
    // traffic lights (Shell), drag on any empty header region, double-click
    // maximize. No native chrome left to camouflage (Part B styling gone).
    shell.setWindowFlags(Qt::Window | Qt::FramelessWindowHint);
    shell::build_native_menus(shell); // system menu bar (File/Scene/Edit/Help)
    shell.resize(960, 600 + shell::kTopbarH);

    // Center on the primary screen: the Qt window must be on-screen before
    // the SDL child window is parked over its viewport.
    {
        QRect avail = QGuiApplication::primaryScreen()->availableGeometry();
        shell.move(avail.x() + (avail.width() - shell.width()) / 2,
                   avail.y() + (avail.height() - shell.height()) / 2);
    }
    shell.show();
    shell.raise();
#if defined(__APPLE__)
    // CLI-launched: AppKit won't activate the app, so the window appears
    // behind the terminal (or nowhere visible). Force activation.
    {
        void* ns_app = reinterpret_cast<void* (*)(void*, SEL)>(objc_msgSend)(
            (void*)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
        using BoolSend = void (*)(void*, SEL, BOOL);
        reinterpret_cast<BoolSend>(objc_msgSend)(
            ns_app, sel_registerName("activateIgnoringOtherApps:"), YES);
    }
#endif

// SDL's COCOA_VIEW_POINTER property calls setContentView on the Qt window and
// replaces its chrome. So SDL owns a borderless NSWindow that is attached as a
// child of the Qt window and kept over the viewport (screen coords, re-synced
// every tick).
QWidget* vp = shell.viewport();
shell.show(); // layout the chrome so the viewport has its real size
QApplication::processEvents();
    notify::attach(&shell); // toasts span the whole app (right edge), not just the viewport
SDL_PropertiesID props = SDL_CreateProperties();
SDL_SetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_METAL_BOOLEAN, true);
SDL_SetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN, true);
SDL_SetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN, true);
// HIGH_PIXEL_DENSITY: without it the CAMetalLayer drawable is in points, so
// the shader's fragCoord spans points while iResolution is in device pixels
// and the gradient renders squeezed to half width (uv.x only reaches 0).
SDL_SetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true);
SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, std::max(1, vp->width()));
SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, std::max(1, vp->height()));
SDL_Window* sdl_win = SDL_CreateWindowWithProperties(props);
SDL_DestroyProperties(props);
if (!sdl_win) {
    notify::notify(notify::Kind::ERROR_, QString("SDL attach to viewport failed: ") + SDL_GetError());
    return 1;
}
NSWindow* sdl_nswin = (__bridge NSWindow*)SDL_GetPointerProperty(
    SDL_GetWindowProperties(sdl_win), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
NSView* qt_nsview = (__bridge NSView*)reinterpret_cast<void*>(vp->winId());
NSWindow* qt_nswin = [qt_nsview window];
if (!sdl_nswin || !qt_nswin) {
    notify::notify(notify::Kind::ERROR_, QStringLiteral("SDL attach: missing NSWindow"));
    return 1;
}

auto sync_child = [&] {
    NSRect r = [qt_nswin convertRectToScreen:[qt_nsview convertRect:[qt_nsview bounds] toView:nil]];
    if (!NSEqualRects(r, [sdl_nswin frame])) [sdl_nswin setFrame:r display:YES];
};
[qt_nswin addChildWindow:sdl_nswin ordered:NSWindowAbove];
sync_child();
SDL_ShowWindow(sdl_win);

// Native preview frame (the "one unit" contract): a 1px border + 6px
// corner radius drawn by a CALayer ON the SDL window — the render content
// stays untouched, but the frame reads as this app's chrome, not a guest
// window. Theme sync: the shell's update_preview_overlays owns geometry;
// this layer only carries the LOOK (border color set once here; the shell
// paints its own themed overlay above when the mode needs emphasis).
{
    NSView* sdl_view = sdl_nswin.contentView;
    sdl_view.wantsLayer = YES;
    sdl_view.layer.masksToBounds = NO;
    sdl_view.layer.cornerRadius = 6.0;
    sdl_view.layer.borderWidth = 1.0;
    sdl_view.layer.borderColor =
        [NSColor colorWithCalibratedWhite:1.0 alpha:0.12].CGColor;
}


gfx::Gfx gfx;
auto vpw = [&] { return shell.viewport()->width(); };
auto vph = [&] { return shell.viewport()->height(); };
    if (!gfx::gfx_create(gfx, sdl_win, vpw(), vph())) {
        std::fprintf(stderr, "gfx create failed: %s\n", SDL_GetError());
        return 1;
    }

    // PiP gesture monitor (see the block above): drags and edge-resizes the
    // preview frame; cursor affordance on hover; snap zones while dragging
    // (left/right half of the editor space -> dock there; drop elsewhere ->
    // stay floating). The lambda runs on the main thread only (Qt event
    // loop), so the statics need no lock. Only active in FLOAT mode: in
    // SPLIT/FULL the frame is docked (the gutter drag lives in the shell).
    {
        static std::string prefs_path = "assets/ui.prefs";
        g_prefs_path = &prefs_path;
        // Load persisted rect once; keep whatever is valid.
        std::ifstream in("assets/ui.prefs");
        std::map<std::string, int> kv;
        std::string line;
        while (std::getline(in, line)) {
            auto eq = line.find('=');
            if (eq == std::string::npos) continue;
            kv[line.substr(0, eq)] = std::atoi(line.c_str() + eq + 1);
        }
        if (kv.count("pip_w") && kv["pip_w"] > 120 && kv.count("pip_h") && kv["pip_h"] > 80) {
            g_pip_rect = NSMakeRect(kv["pip_x"], kv["pip_y"], kv["pip_w"], kv["pip_h"]);
        }
        // Snap hit-test in Cocoa screen coords (bottom-left origin): the
        // viewport rect converts via the same path as sync_child.
        auto snap_zone_at = [&](NSPoint p) -> int {
            NSRect vp = [qt_nswin convertRectToScreen:
                [qt_nsview convertRect:[qt_nsview bounds] toView:nil]];
            if (p.x < NSMinX(vp) || p.x > NSMaxX(vp) ||
                p.y < NSMinY(vp) || p.y > NSMaxY(vp))
                return -1;
            return (p.x - NSMinX(vp)) > NSWidth(vp) / 2 ? 1 : 0;
        };
        shell::Shell* sh = &shell; // blocks copy captures as const: use ptr
        __block NSEvent* (^monitor)(NSEvent*) = ^NSEvent*(NSEvent* ev) {
            NSEventType t = ev.type;
            NSPoint p = [NSEvent mouseLocation]; // screen coords (bottom-left)
            NSWindow* w = ev.window;
            if (w != sdl_nswin) return ev; // only the preview window
            if (sh->ui.preview != shell::Preview_Mode::FLOAT &&
                !g_pip_drag && !g_pip_resize)
                return ev; // docked modes: no free drag/resize
            if (t == NSEventTypeMouseMoved) {
                int e = pip_edges_at(p);
                NSCursor* c = (e & 3) && !(e & 12) ? [NSCursor resizeLeftRightCursor]
                              : ((e & 12) && !(e & 3) ? [NSCursor resizeUpDownCursor]
                                                      : [NSCursor pointingHandCursor]);
                [c set];
                return ev;
            }
            if (t == NSEventTypeLeftMouseDown) {
                g_pip_last = p;
                g_pip_edges = pip_edges_at(p);
                // MOUSE_ROTATE: left-drag belongs to the camera; PiP move only in other modes (edge resize still works).
                g_pip_drag = g_pip_edges == 0 && sh->ui.interaction != shell::Interaction_Mode::MOUSE_ROTATE;
                g_pip_resize = g_pip_edges != 0;
                return ev;
            }
            if (t == NSEventTypeLeftMouseDragged && (g_pip_drag || g_pip_resize)) {
                CGFloat dx = p.x - g_pip_last.x;
                CGFloat dy = p.y - g_pip_last.y;
                g_pip_last = p;
                if (g_pip_drag) {
                    g_pip_rect.origin.x += dx;
                    g_pip_rect.origin.y += dy;
                    // Snap aiming: shell paints the zones (global Qt rect).
                    int zone = snap_zone_at(p);
                    if (zone != g_snap_zone) {
                        g_snap_zone = zone;
                        sh->set_snap_hover(zone);
                    }
                } else {
                    if (g_pip_edges & 1) { g_pip_rect.origin.x += dx; g_pip_rect.size.width -= dx; }
                    if (g_pip_edges & 2) { g_pip_rect.size.width += dx; }
                    if (g_pip_edges & 8) { g_pip_rect.origin.y += dy; g_pip_rect.size.height -= dy; }
                    if (g_pip_edges & 4) { g_pip_rect.size.height += dy; }
                    if (g_pip_rect.size.width < 160) g_pip_rect.size.width = 160;
                    if (g_pip_rect.size.height < 100) g_pip_rect.size.height = 100;
                }
                [sdl_nswin setFrame:g_pip_rect display:YES];
                return ev;
            }
            if (t == NSEventTypeLeftMouseUp && (g_pip_drag || g_pip_resize)) {
                if (g_pip_drag && g_snap_zone >= 0) {
                    // Drop in a zone: dock SPLIT on that side. The split
                    // fraction follows where the frame was when dropped.
                    NSRect vp = [qt_nswin convertRectToScreen:
                        [qt_nsview convertRect:[qt_nsview bounds] toView:nil]];
                    float frac = float((NSMidX(g_pip_rect) - NSMinX(vp)) / NSWidth(vp));
                    sh->settle_split_gutter(g_snap_zone == 0 ? 1.0f - frac
                                                             : frac);
                    sh->set_preview_mode(shell::Preview_Mode::SPLIT);
                    sh->set_snap_hover(-1);
                    g_snap_zone = -1;
                    g_pip_drag = g_pip_resize = false;
                    return ev;
                }
                sh->set_snap_hover(-1);
                g_snap_zone = -1;
                g_pip_drag = g_pip_resize = false;
                pip_save_prefs();
                return ev;
            }
            return ev;
        };
        g_pip_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:g_pip_mask handler:monitor];
    }

    // Camera input monitor: orbit / dolly / flycam on the SDL preview
    // window only. Never hides or grabs the cursor — deltas come from
    // absolute event locations (the top-bar stuck-cursor bug must not
    // come back through camera code).
    id g_cam_monitor = nil;
    static NSPoint cam_last;      // last drag position (screen)
    static bool cam_orbiting = false;
    {
        shell::Shell* sh = &shell;
        scene::Scene_Manager* mgr = &manager;
        // Mutable camera state, owned HERE (the tick reads it through the
        // pointers; the monitor writes it — both on the main thread).
        static float cam_yaw = 0.f, cam_pitch = camera::kDefaultPitch,
                     cam_dist = camera::kDist;
        static bool fly_on = false;
        static float fly_pos[3] = {0.f, 0.f, 0.f};
        static float fly_yaw = 0.f, fly_pitch = 0.f;
        g_cam_yaw = &cam_yaw;   g_cam_pitch = &cam_pitch; g_cam_dist = &cam_dist;
        g_fly_on = &fly_on;     g_fly_pos = fly_pos;
        g_fly_yaw = &fly_yaw;   g_fly_pitch = &fly_pitch;
        __block NSEvent* (^monitor)(NSEvent*) = ^NSEvent*(NSEvent* ev) {
            NSEventType t = ev.type;
            if (ev.window != sdl_nswin) return ev; // only the preview surface
            if (g_pip_drag || g_pip_resize) return ev; // PiP gesture wins
            NSPoint p = [NSEvent mouseLocation];
            NSRect wf = [sdl_nswin frame];
            const bool inside = p.x >= NSMinX(wf) && p.x <= NSMaxX(wf) &&
                                p.y >= NSMinY(wf) && p.y <= NSMaxY(wf);
            if (t == NSEventTypeMouseMoved) {
                if (!inside) [[NSCursor arrowCursor] set];
                return ev;
            }
            // Flycam keys (only while the preview window is key: editor
            // focus unaffected). Handled events are swallowed.
            if (t == NSEventTypeKeyDown && [sdl_nswin isKeyWindow]) {
                QString chars = QString::fromNSString(ev.charactersIgnoringModifiers);
                const QString k = chars.toLower();
                if (ev.keyCode == 48 && !ev.isARepeat) { // Tab: charactersIgnoringModifiers is "\t", not "tab"
                    fly_on = !fly_on;
                    std::fill(g_fly_keys, g_fly_keys + 6, false); // no stale held keys across toggles
                    if (fly_on) {
                        // Inherit the orbit spot (input_bindings.odin
                        // toggle_flycam contract): same sphere position and
                        // yaw/pitch; legacy camera_flycam then looks outward.
                        const float cp = std::cos(cam_pitch), sp = std::sin(cam_pitch);
                        fly_pos[0] = cam_dist * cp * std::sin(cam_yaw);
                        fly_pos[1] = cam_dist * sp;
                        fly_pos[2] = cam_dist * cp * std::cos(cam_yaw);
                        fly_yaw = cam_yaw;
                        fly_pitch = cam_pitch;
                    }
                    return nil;
                }
                if (ev.keyCode == 53 && fly_on) { // Escape
                    fly_on = false;
                    std::fill(g_fly_keys, g_fly_keys + 6, false);
                    return nil;
                }
                if (k == "r") {
                    cam_yaw = g_app_time * camera::kAutorotateYawRate;
                    cam_pitch = camera::kDefaultPitch;
                    cam_dist = camera::kDist;
                    fly_on = false;
                    return nil;
                }
                // WASD/E/Q movement is polled per tick via g_fly_keys; the
                // monitor only records which are held (smooth motion).
                if (k == "w") { g_fly_keys[0] = true; return nil; }
                if (k == "a") { g_fly_keys[1] = true; return nil; }
                if (k == "s") { g_fly_keys[2] = true; return nil; }
                if (k == "d") { g_fly_keys[3] = true; return nil; }
                if (k == "e") { g_fly_keys[4] = true; return nil; }
                if (k == "q") { g_fly_keys[5] = true; return nil; }
            }
            if (t == NSEventTypeKeyUp && [sdl_nswin isKeyWindow]) {
                const QString k = QString::fromNSString(ev.charactersIgnoringModifiers).toLower();
                if (k == "w") { g_fly_keys[0] = false; return nil; }
                if (k == "a") { g_fly_keys[1] = false; return nil; }
                if (k == "s") { g_fly_keys[2] = false; return nil; }
                if (k == "d") { g_fly_keys[3] = false; return nil; }
                if (k == "e") { g_fly_keys[4] = false; return nil; }
                if (k == "q") { g_fly_keys[5] = false; return nil; }
            }
            if (t == NSEventTypeFlagsChanged)
                g_fly_shift = (ev.modifierFlags & NSEventModifierFlagShift) != 0;
            if (t == NSEventTypeScrollWheel && inside) {
                // Legacy dolly: dist *= (1 - wheel.y * 0.1), clamp 0.8..8.
                CGFloat dy = ev.scrollingDeltaY;
                if ([ev hasPreciseScrollingDeltas]) dy *= 0.1;
                cam_dist = std::clamp(float(cam_dist * (1.0f - float(dy) * 0.1f)),
                                      0.8f, 8.0f);
                return ev;
            }
            // Orbit: left-drag in MOUSE_ROTATE on model scenes. AUTOROTATE
            // keeps today's PiP move semantics (this monitor's drag branch
            // never fires there; the PiP monitor owns the gesture).
            if (t == NSEventTypeLeftMouseDown && inside &&
                sh->ui.interaction == shell::Interaction_Mode::MOUSE_ROTATE &&
                (fly_on || (!mgr->scenes.empty() &&
                            mgr->scenes[size_t(mgr->current)].uses_model))) {
                cam_last = p;
                cam_orbiting = true;
                return ev;
            }
            if (t == NSEventTypeLeftMouseDragged && cam_orbiting) {
                CGFloat dx = p.x - cam_last.x, dy = p.y - cam_last.y; // y-up screen
                cam_last = p;
                if (fly_on) {
                    // legacy flycam look (glove delta y-down): yaw -= dx, pitch -= dy_down
                    fly_yaw -= float(dx) * 0.006f;
                    fly_pitch = std::clamp(fly_pitch + float(dy) * 0.006f, -1.5f, 1.5f);
                } else {
                    // legacy model orbit: yaw -= dx, pitch += delta.y (y-down)
                    cam_yaw -= float(dx) * 0.012f;
                    cam_pitch = std::clamp(cam_pitch - float(dy) * 0.012f, -1.45f, 1.45f);
                }
                return ev;
            }
            if (t == NSEventTypeLeftMouseUp && cam_orbiting) {
                cam_orbiting = false;
                return ev;
            }
            return ev;
        };
        g_cam_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:
            NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged |
            NSEventMaskLeftMouseUp | NSEventMaskMouseMoved |
            NSEventMaskScrollWheel | NSEventMaskKeyDown | NSEventMaskKeyUp |
            NSEventMaskFlagsChanged
            handler:monitor];
    }


    // Offscreen targets + resources; resize updates depth/pass texture refs.
    scene::Render_Targets targets;
    scene::Scene_Resources resources;
    // pw/ph = the SDL window's drawable size (the actual preview surface,
    // in every mode). Kept as parameters: the tick is the only caller that
    // guards/coalesces, so it passes the same values it renders at.
    auto resize_targets = [&](int pw, int ph) {
        if (pw <= 0 || ph <= 0) return; // layout not settled yet

        scene::targets_resize(targets, gfx.gpu, pw, ph,
                              int(manager.scenes[size_t(manager.current)].passes.size()));
        resources.depth_tex = targets.depth;
        resources.pass_tex = targets.passes;
    };
    // Odin frame.odin re-checks targets every frame: the first pass runs
    // before Qt layout settles, so a load-time resize alone leaves the scene
    // texture at a stale (tiny) size — the gradient renders squeezed into a
    // narrow band.

    if (!load_blit(gfx.gpu)) {
        std::fprintf(stderr, "blit shaders missing (run: make shaders)\n");
        return 1;
    }
    SDL_GPUGraphicsPipeline* preview_pipe = nullptr;
    SDL_GPUGraphicsPipeline* swap_pipe = nullptr;
    SDL_GPUSampler* preview_sampler = nullptr;

    {
        SDL_GPUColorTargetDescription tgt{};
        // Preview targets are R8G8B8A8_UNORM (scene_runtime.cpp); the old
        // swapchain-format pipeline here mismatched and Metal aborted the
        // encoder mid-frame ("uncommitted encoder" crash).
        tgt.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        SDL_GPUGraphicsPipelineCreateInfo pci{};
        pci.vertex_shader = blit_vs;
        pci.fragment_shader = blit_fs;
        pci.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        pci.target_info.num_color_targets = 1;
        pci.target_info.color_target_descriptions = &tgt;
        preview_pipe = SDL_CreateGPUGraphicsPipeline(gfx.gpu, &pci);
        if (!preview_pipe) std::fprintf(stderr, "preview pipe failed: %s\n", SDL_GetError());
        // Swapchain-format twin for the final scene->swapchain blit.
        tgt.format = gfx.swapchain_format;
        swap_pipe = SDL_CreateGPUGraphicsPipeline(gfx.gpu, &pci);
        if (!swap_pipe) std::fprintf(stderr, "swap pipe failed: %s\n", SDL_GetError());
        SDL_GPUSamplerCreateInfo sci{};
        sci.min_filter = SDL_GPU_FILTER_LINEAR;
        sci.mag_filter = SDL_GPU_FILTER_LINEAR;
        sci.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sci.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sci.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        preview_sampler = SDL_CreateGPUSampler(gfx.gpu, &sci);
    }
    resources.sampler = preview_sampler;
    // Shared assets: paper/skybox textures, model library, black fallback
    // (assets.{hpp,cpp}; Odin assets.odin + model.odin).
    assets::Assets shared;
    if (!assets::load(shared, gfx)) {
        std::fprintf(stderr, "asset load failed (paper textures/models required)\n");
        return 1;
    }
    resources.paper_texture = gfx::gfx_texture_get(gfx, shared.paper_textures[0])->handle;
    resources.black_texture = gfx::gfx_texture_get(gfx, shared.black_texture)->handle;
    resources.black_sampler = preview_sampler;
    // 3D feeds: the active scene's mesh node picks the model by basename
    // (scene.model, from graph.json "model"); GIS_MODEL overrides for
    // screenshots. Default = first entry. Skybox: GIS_SKYBOX=<name> picks
    // from assets/skybox (a UI picker lands with the UI pass).
    // Model cache: uobj routes upload each glb once; handles live as long
    // as the app (screenshots/testing don't churn scenes enough to leak).
    std::map<std::string, assets::Model> uobj_models;
    // Plan 07: the active scene's mesh nodes drive geometry. Two sources:
    // 1. uobj routes (scene.pass_model_paths): each MODEL route names a glb
    //    — per-pass buffers (graph inputs decide which model each pass draws).
    // 2. Fallback: scene.model basename or GIS_MODEL → default buffers.
    auto pick_model = [&](const scene::Runtime_Scene& sc) {
        resources.pass_model_vb.clear();
        resources.pass_model_ib.clear();
        resources.pass_model_index_count.clear();
        for (const auto& [pass_index, path] : sc.pass_model_paths) {
            auto it = uobj_models.find(path);
            if (it == uobj_models.end()) {
                assets::Model m;
                if (!assets::load_gltf(gfx, path, m)) {
                    notify::notify(notify::Kind::WARN,
                                   QString("asset not found: %1")
                                       .arg(QString::fromStdString(path)));
                    continue;
                }
                std::fprintf(stderr, "uobj: loaded %s (%u idx)\n", path.c_str(),
                             m.index_count);
                it = uobj_models.emplace(path, std::move(m)).first;
            }
            resources.pass_model_vb[size_t(pass_index)] = it->second.vb;
            resources.pass_model_ib[size_t(pass_index)] = it->second.ib;
            resources.pass_model_index_count[size_t(pass_index)] =
                it->second.index_count;
        }
        const QByteArray env = qgetenv("GIS_MODEL");
        std::string want = !env.isEmpty() ? std::string(env.constData())
                                          : sc.model;
        const assets::Model* picked = shared.models.empty()
                                           ? nullptr
                                           : &shared.models[0];
        if (!want.empty()) {
            for (const assets::Model& m : shared.models) {
                if (m.name == want) {
                    picked = &m;
                    break;
                }
            }
            if (picked && picked->name != want)
                std::fprintf(stderr, "model '%s' not found, using '%s'\n",
                             want.c_str(), picked->name.c_str());
        }
        if (picked) {
            resources.model_vb = picked->vb;
            resources.model_ib = picked->ib;
            resources.model_index_count = picked->index_count;
            gfx::Texture* tex_res = gfx::gfx_texture_get(gfx, picked->base_color_texture);
            resources.model_base_color_texture = tex_res ? tex_res->handle : nullptr;
            resources.model_base_color_sampler = picked->texture_sampler;
            std::fprintf(stderr, "scene: picked model '%s', texture=%p sampler=%p\n",
                         picked->name.c_str(), resources.model_base_color_texture, picked->texture_sampler);
        }
    };
    // Skybox: GIS_SKYBOX=<name> picks from assets/skybox by basename
    // ("night" → skybox-night.png). Unset = null (paper-clear background).
    {
        const QByteArray want = qgetenv("GIS_SKYBOX");
        if (!want.isEmpty()) {
            for (size_t i = 0; i < shared.skybox_names.size(); ++i) {
                if (shared.skybox_names[i] == want.constData()) {
                    resources.skybox_texture = gfx::gfx_texture_get(gfx, shared.skybox_textures[i])->handle;
                    std::fprintf(stderr, "skybox: %s\n",
                                 shared.skybox_names[i].c_str());
                    break;
                }
            }
        }
    }
    // Graph-routed texture/sampler resources (uimg nodes): host caches,
    // app lifetime. Failures report once (toast) and stay absent — the
    // bind falls through to black/default (the user decision).
    std::map<std::string, gfx::Texture_Handle> user_tex_handles;
    std::set<std::string> user_tex_reported;
    std::map<std::string, std::pair<std::string, std::string>> sampler_specs;
    std::map<std::string, SDL_GPUSampler*> sampler_objs;
    std::set<std::string> target_read_reported;
    auto apply_resource_routes = [&](const scene::Runtime_Scene& sc) {
        for (const auto& r : sc.pipeline.resources) {
            if (r.source != render_graph::Resource_Source::FILE) {
                // TARGET_READ routes: legacy never had a bind site either;
                // one-time toast is the honest signal.
                if (target_read_reported.insert("t:" + r.path).second)
                    notify::notify(notify::Kind::WARN,
                                   "render target read routes render as paper "
                                   "(ping-pong not implemented)");
                continue;
            }
            if (r.kind == render_graph::Resource_Kind::TEXTURE) {
                if (!user_tex_handles.count(r.path)) {
                    bool ok = false;
                    gfx::Texture_Handle h = assets::load_texture(gfx, r.path, ok);
                    if (ok) {
                        user_tex_handles[r.path] = h;
                        resources.user_textures[r.path] =
                            gfx::gfx_texture_get(gfx, h)->handle;
                    } else if (user_tex_reported.insert(r.path).second) {
                        notify::notify(notify::Kind::WARN,
                                       QString("asset not found: %1")
                                           .arg(QString::fromStdString(r.path)));
                    }
                }
            } else if (r.kind == render_graph::Resource_Kind::SAMPLER) {
                // The route's path is the image file; the OWNING texture
                // node ("uimg:<path>:texture") carries filter/address.
                const std::string node_key = "uimg:" + r.path + ":texture";
                std::pair<std::string, std::string> spec{"linear", "clamp"};
                if (auto it = sc.node_sampler_settings.find(node_key);
                    it != sc.node_sampler_settings.end())
                    spec = it->second;
                sampler_specs[r.path] = spec;
                if (!sampler_objs.count(r.path)) {
                    SDL_GPUSamplerCreateInfo sci{};
                    sci.min_filter = sci.mag_filter =
                        spec.first == "point" ? SDL_GPU_FILTER_NEAREST
                                              : SDL_GPU_FILTER_LINEAR;
                    sci.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
                    SDL_GPUSamplerAddressMode mode =
                        SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
                    if (spec.second == "repeat")
                        mode = SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
                    else if (spec.second == "mirror")
                        mode = SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT;
                    sci.address_mode_u = sci.address_mode_v = sci.address_mode_w = mode;
                    sci.max_lod = 1000.f; // match load-site samplers
                    SDL_GPUSampler* s = SDL_CreateGPUSampler(gfx.gpu, &sci);
                    if (s) sampler_objs[r.path] = s;
                    resources.user_samplers[r.path] = s; // null = keep default
                }
            }
        }
    };
    scene::Build_State build;
    std::map<std::string, uint64_t> scene_failed;
    QFileSystemWatcher watcher;
    // Watch the dir (new/removed files) AND each .slang: an in-place save of an
    // existing file fires fileChanged only, not directoryChanged.
    auto watch_active = [&]() {
        if (!watcher.files().empty()) watcher.removePaths(watcher.files());
        if (!watcher.directories().empty()) watcher.removePaths(watcher.directories());
        const std::string& title = manager.scenes[size_t(manager.current)].title;
        QString dir = QString("%1/%2")
                          .arg(scene::scene_root_dir(scene_roots, title).c_str())
                          .arg(title.c_str());
        watcher.addPath(dir);
        QDirIterator it(dir, {"*.slang", "graph.json"}, QDir::Files);
        while (it.hasNext()) watcher.addPath(it.next());
    };
    watch_active();
    auto on_source_change = [&](const QString&) {
        watch_active(); // editors that save via rename drop the watched path
        scene::scene_request_build(build, {manager.scenes[size_t(manager.current)].title});
    };
    QObject::connect(&watcher, &QFileSystemWatcher::directoryChanged, on_source_change);
    QObject::connect(&watcher, &QFileSystemWatcher::fileChanged, on_source_change);

    // Render on a QTimer in the main thread: SDL draws into the sdl_host_ NSView,
    // so Qt and SDL share one native window and one event loop.
    float t = 0;
    int frames = 0;
    auto init = [&]() -> bool {
        // Cold-start bake (Odin scene_ensure_loaded parity): scenes_build
        // is idempotent (goose skips fresh artifacts), so this is free
        // when the artifacts exist and compiles them when they don't —
        // the watcher alone never fires on a fresh clone.
        if (!scene::scenes_build({names[size_t(idx)]}, scene_roots)) {
            std::fprintf(stderr, "scene %s failed to bake\n", names[size_t(idx)].c_str());
        }
        // Initial scene load; frames are driven by frame_timer below.
        if (!scene::scene_load_into(gfx.gpu, manager.scenes[size_t(idx)],
                                    names[size_t(idx)], scene_roots)) {
            std::fprintf(stderr, "scene %s failed to load: %s\n",
                         names[size_t(idx)].c_str(),
                         manager.scenes[size_t(idx)].pipeline_error.c_str());
            return false;
        }
        pick_model(manager.scenes[size_t(manager.current)]);
        {
            int sw = 0, sh = 0;
            SDL_GetWindowSizeInPixels(sdl_win, &sw, &sh);
            resize_targets(sw, sh);
        }
        if (scene::scene_has_debug_watches(manager.scenes[size_t(manager.current)])) {
            SDL_GPUBufferCreateInfo bci{};
            bci.usage = SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ |
                        SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE;
            bci.size = scene::DEBUG_WATCH_COUNT * 32 *
                       int(manager.scenes[size_t(manager.current)].passes.size() + 1);
            resources.debug_watch_buffer = SDL_CreateGPUBuffer(gfx.gpu, &bci);
        }
        shell.scene_switched();
        return true;
    };


    // plan8 viewport header: WHAT is rendering, at WHICH resolution, and
    // the render state (compiling / paused / error). One caption, no extra
    // chrome; FPS omitted (no reliable per-frame GPU timing in this host —
    // inventing a number is worse than none).
    auto viewport_caption = [&](const scene::Scene_Manager& mgr,
                                const scene::Render_Targets& tg,
                                bool baking_now, bool paused_now) -> QString {
        if (mgr.scenes.empty()) return {};
        const auto& sc = mgr.scenes[size_t(mgr.current)];
        // Output = the pass feeding show2d (plan.output_pass), or the entry
        // pass in the default chain. Black render + valid plan = honest
        // black content, never "uninitialized".
        int out = sc.pipeline.output_pass;
        QString pass = out >= 0 && out < int(sc.passes.size())
                           ? QString::fromStdString(sc.passes[size_t(out)].name)
                           : QString("entry");
        QString text = QString("%1 · %2×%3 · %4")
                           .arg(QString::fromStdString(sc.title))
                           .arg(int(tg.w))
                           .arg(int(tg.h))
                           .arg(pass);
        if (!sc.pipeline_error.empty())
            text += QString(" · ERROR: %1")
                        .arg(QString::fromStdString(sc.pipeline_error));
        else if (baking_now)
            text += " · compiling";
        else if (paused_now)
            text += " · paused";
        return text;
    };
    // Blocking scene-target readback -> PNG. Shared by the export button
    // and the --shot CLI flag (identical path, one implementation).
    auto save_scene_png = [&](const QString& out) {
        gfx::Staging st = gfx::uploader_download_texture_region_begin(
            gfx.uploader, targets.scene, 0, 0, uint32_t(targets.w), uint32_t(targets.h));
        // download_end already submitted and fenced the copy (owns_pass);
        // wait by polling the fence, NOT uploader_flush_blocking (the copy
        // pass is closed — flushing again SEGVs in METAL_WaitForFences).
        while (!gfx::staging_ready(gfx.uploader, st)) {}
        const uint8_t* rgba = gfx::staging_read(st);
        QImage img(rgba, targets.w, targets.h, QImage::Format_RGBA8888);
        bool ok = img.save(out);
        gfx::staging_release(gfx.uploader, st);
        return ok;
    };
    auto tick = [&] {
        ++frames;
        // The SDL child window either fills the viewport (scene view) or
        // shrinks to a floating preview frame (code editor up) — the editor
        // needs the shader visible while editing. sync_child is skipped
        // while the preview frame owns the rect: a per-tick flip-flop
        // between the two rects starves the UI with resizes.
        // CORE LAYOUT: the editor is ALWAYS the center page; the scene
        // preview floats as the PiP frame over it in every mode. The old
        // FILES-only gate (fullscreen viewport for other modes) is gone.
        bool editor_page = !shell.ui.fullscreen_view;
        // Apply finished goose-builds: worker writes artifacts, only this
        // pump creates GPU pipelines (must run on the main/GPU thread).
        scene::scene_build_pump(build, manager, gfx.gpu, scene_roots, scene_failed);
        // A swapped-in plan may carry new resource routes; apply is cheap
        // (map lookups only, everything cached after first load).
        apply_resource_routes(manager.scenes[size_t(manager.current)]);
        bool baking;
        {
            std::lock_guard<std::mutex> lock(build.mu);
            baking = build.req || build.running;
        }
        shell.set_baking(baking);
        // The SDL NSWindow is a child window: a stack page switch does not hide
        // it, so it kept covering the editor (FILES) until hidden here.
        // PREVIEW mode (editor page up): the SDL window shrinks to a floating
        // picture-in-picture frame at the top-right so the shader stays
        // visible while editing. Back to the scene view: full viewport again.
        // (QScintilla fills its text area opaque — true per-pixel
        // see-through is not possible with this widget.)
        static bool preview_applied = false;
        static bool sdl_shown = true;
        if (editor_page) {
            // The preview lives INSIDE the viewport rect (vp = sdl_host_:
            // excludes topbar/strip/side panel), converted to screen — so
            // the panel and the editor's tab row stay clickable, and the
            // PiP never covers the files tree. Same convertRectToScreen
            // path as sync_child (pure-Qt mapping drifted off-window).
            NSRect vp_win = [qt_nswin convertRectToScreen:
                [qt_nsview convertRect:[qt_nsview bounds] toView:nil]];
            CGFloat vp_w = NSWidth(vp_win), vp_h = NSHeight(vp_win);
            if (shell.ui.preview == shell::Preview_Mode::SPLIT) {
                const qint64 t0 = perf_clock()->nsecsElapsed(); // TEMP-PROF
                CGFloat left_w = NSWidth(vp_win) * shell.ui.split_left;
                NSRect want = NSMakeRect(NSMinX(vp_win) + left_w,
                                         NSMinY(vp_win),
                                         NSWidth(vp_win) - left_w,
                                         vp_h);
                if (!NSEqualRects(want, [sdl_nswin frame]))
                    [sdl_nswin setFrame:want display:YES];
                g_pip_rect = NSZeroRect; // split owns the rect; drag off state
                CGFloat screen_h = [[[NSScreen screens] firstObject] frame].size.height;
                QRect qt_frame(int(want.origin.x),
                               int(screen_h - want.origin.y - want.size.height),
                               int(want.size.width), int(want.size.height));
                shell.set_pip_overlay(
                    viewport_caption(manager, targets, baking, shell.ui.paused),
                    qt_frame); // caption anchors ON the preview frame
                shell.set_preview_frame_rect(qt_frame);
                perf_log("split-tick-ms", double(perf_clock()->nsecsElapsed() - t0) / 1e6);
            } else if (shell.ui.preview == shell::Preview_Mode::FULL) {
                // FULL dock: the whole editor space (below the tab row).
                NSRect want = NSMakeRect(NSMinX(vp_win), NSMinY(vp_win),
                                         vp_w, vp_h - 48);
                if (!NSEqualRects(want, [sdl_nswin frame]))
                    [sdl_nswin setFrame:want display:YES];
                g_pip_rect = NSZeroRect;
                shell.set_pip_overlay(QString(), QRect());
                shell.set_preview_frame_rect(QRect()); // no frame: it IS the space
            } else {
                // FLOAT: the USER's rect (drag/resize monitor above) once
                // set — FREE to move anywhere, including over the sidebar
                // or partly off-window. Default anchored top-right only
                // when never set. While a drag aims at a zone, the shell
                // paints the dashed target (set_snap_hover).
                if (NSIsEmptyRect(g_pip_rect)) {
                    CGFloat pw = vp_w * 0.40;
                    // PiP ancorado ao topo-direito do viewport, topo 48px
                    // abaixo do topo visual (abaixo da tab row): fundo
                    // (origin Cocoa) = vpMaxY - 48 - ph.
                    CGFloat ph = vp_h * 0.55 - 48;
                    g_pip_rect = NSMakeRect(NSMaxX(vp_win) - pw - 12,
                                            NSMaxY(vp_win) - 48 - ph, pw, ph);
                }
                // Keyboard geometry (critique P2): consume arrow nudges the
                // shell queued via Cmd+arrows. Qt y is top-down, Cocoa y is
                // bottom-up, so the dy sign flips.
                if (shell.ui.preview_nudge != QPoint(0, 0)) {
                    g_pip_rect.origin.x += shell.ui.preview_nudge.x();
                    g_pip_rect.origin.y -= shell.ui.preview_nudge.y();
                    shell.ui.preview_nudge = QPoint(0, 0);
                    pip_save_prefs();
                }
                if (!NSEqualRects(g_pip_rect, [sdl_nswin frame]))
                    [sdl_nswin setFrame:g_pip_rect display:YES];
                // plan8 caption: anchored to the PiP frame itself (the
                // preview surface), never parked over the file selector.
                CGFloat screen_h = [[[NSScreen screens] firstObject] frame].size.height;
                QRect qt_pip(int(g_pip_rect.origin.x),
                             int(screen_h - g_pip_rect.origin.y - g_pip_rect.size.height),
                             int(g_pip_rect.size.width), int(g_pip_rect.size.height));
                shell.set_pip_overlay(
                    viewport_caption(manager, targets, baking, shell.ui.paused),
                    qt_pip);
                shell.set_preview_frame_rect(qt_pip);
            }
            preview_applied = true;
        } else {
            shell.set_pip_overlay(QString(), QRect()); // fullscreen: no PiP label
            shell.set_preview_frame_rect(QRect()); // no docked-frame overlays
            if (preview_applied) { // leaving the editor: full viewport again
                preview_applied = false;
                sync_child();
            }
            if (bool on = vp->isVisible(); on != sdl_shown) {
                if (on) {
                    sync_child();
                    SDL_ShowWindow(sdl_win);
                } else {
                    SDL_HideWindow(sdl_win);
                }
                sdl_shown = on;
            } else {
                sync_child(); // keep the child glued to the viewport
            }
        }
        scene::Runtime_Scene& sc = manager.scenes[size_t(manager.current)];
        // Render at the SDL window's drawable size: the child NSWindow IS
        // the preview surface in every mode (FULL page, SPLIT dock, FLOAT
        // PiP), so the final blit maps 1:1 and the camera aspect is always
        // the visible one (viewport-sized targets stretched it).
        int pw = 0, ph = 0;
        SDL_GetWindowSizeInPixels(sdl_win, &pw, &ph);
        if (pw <= 0 || ph <= 0) return; // layout not settled / hidden
        // Churn guard (the failure of the previous SDL-sizing attempt):
        // PiP drags animate the frame every frame — skip resizes while a
        // gesture is live; the mouse-up branch clears the flags and the
        // next tick resizes once. Native live-resize: coalesce to one
        // resize per 100 ms instead of one per frame.
        static qint64 last_resize_ns = 0;
        const qint64 now_ns = perf_clock()->nsecsElapsed();
        const bool pip_live = g_pip_drag || g_pip_resize;
        if (!pip_live &&
            scene::targets_needs_resize(targets, pw, ph, int(sc.passes.size())) &&
            now_ns - last_resize_ns > 100 * 1000 * 1000) {
            resize_targets(pw, ph);
            last_resize_ns = now_ns;
        }
        // Scene submission runs even when the swapchain has no drawable this
        // frame (occluded window): EVERY acquired command buffer must be
        // submitted, or Metal's in-flight semaphore starves and the next
        // SDL_AcquireGPUCommandBuffer blocks forever (one-window freeze).
        // Mouse in device pixels of the SDL window (the render surface).
        // When the pointer leaves the frame, park iMousePos at the last
        // in-frame value (scenes like 03_mouse keep sampling, not jumping).
        static QPoint last_mouse(0, 0);
        {
            const NSPoint sp = [NSEvent mouseLocation]; // bottom-left origin
            const NSRect wf = [sdl_nswin frame];
            const CGFloat sx = sp.x - NSMinX(wf), sy = sp.y - NSMinY(wf);
            if (sx >= 0 && sy >= 0 && sx <= NSWidth(wf) && sy <= NSHeight(wf)) {
                const CGFloat dpr = vp->devicePixelRatioF();
                last_mouse = QPoint(int(sx * dpr), int((NSHeight(wf) - sy) * dpr));
            }
        }
        QPoint mp = last_mouse;
        static bool prev_click = false;
        bool click = QApplication::mouseButtons() & Qt::LeftButton;
        // Camera state lives at file scope (g_cam_*): the NSEvent monitor
        // writes it, this tick reads it. AUTOROTATE: legacy spin. Drag in
        // MOUSE_ROTATE overrides yaw/pitch (retained after release, like
        // legacy). Flycam: WASD/E/Q/Shift advance the position with real dt.
        g_app_time = t;
        if (shell.ui.interaction == shell::Interaction_Mode::AUTOROTATE) {
            *g_cam_yaw = t * camera::kAutorotateYawRate;
            *g_cam_pitch = camera::kDefaultPitch;
        }
        if (*g_fly_on) {
            if (g_fly_last_t < 0.0) g_fly_last_t = t;
            const float dt = float(std::min(t - g_fly_last_t, 0.25));
            g_fly_last_t = t;
            if (dt > 0.0f) {
                const float speed = 1.2f * (g_fly_shift ? 4.0f : 1.0f) * dt;
                // Legacy dpos (input_bindings.odin): forward_planar*move.y +
                // right*move.x + up*up_axis. Fly forward xz from yaw only:
                // (sin(yaw), 0, cos(yaw)); right = forward x world-up =
                // (cos(yaw), 0, -sin(yaw)).
                const float fxz[3] = {std::sin(*g_fly_yaw), 0.0f, std::cos(*g_fly_yaw)};
                const float rxz[3] = {std::cos(*g_fly_yaw), 0.0f, -std::sin(*g_fly_yaw)};
                float dpos[3] = {0.f, 0.f, 0.f};
                const float move_f = (g_fly_keys[0] ? 1.f : 0.f) - (g_fly_keys[2] ? 1.f : 0.f);
                const float move_r = (g_fly_keys[3] ? 1.f : 0.f) - (g_fly_keys[1] ? 1.f : 0.f);
                const float move_u = (g_fly_keys[4] ? 1.f : 0.f) - (g_fly_keys[5] ? 1.f : 0.f);
                for (int i = 0; i < 3; ++i)
                    dpos[i] = fxz[i] * move_f + rxz[i] * move_r;
                dpos[1] += move_u;
                for (int i = 0; i < 3; ++i) g_fly_pos[i] += dpos[i] * speed;
            }
        } else {
            g_fly_last_t = -1.0; // re-arm dt on next activation
        }
        const float cam_aspect = float(pw) / float(ph);
        camera::Uniforms cam = *g_fly_on
                                   ? camera::flycam(g_fly_pos, *g_fly_yaw, *g_fly_pitch, cam_aspect)
                                   : camera::orbit(*g_cam_yaw, *g_cam_pitch, *g_cam_dist, cam_aspect);
        scene::scene_write_uniforms(sc, float(pw), float(ph), t, shell.ui.color,
                                    float(mp.x()), float(mp.y()), click, cam);
        // Pixel provenance (stage 8): a fresh click inside the VIEWPORT
        // starts a 1x1 readback of the scene target (poll below). The gate
        // is the SDL host visibility: on the editor/graph pages the SDL
        // window shrinks to the PiP frame (or hides) — clicks there are
        // editor clicks, not scene clicks (the toast fired over the code
        // editor because the hidden page kept its geometry).
        bool scene_visible = shell.ui.mode != shell::Sidebar_Mode::FILES &&
                             shell.ui.mode != shell::Sidebar_Mode::GRAPH;
        // M5 --pixel-test: after the settle frames, sample the CLI-provided
        // pixel (no click needed), print to stdout and quit. The provenance
        // gate (scene_visible/click) does not apply: this is headless intent.
        // --shot PATH: after the same settle window as --pixel-test, save
        // the scene target as PNG (shared export path) and quit — repeatable
        // rendered-output evidence for camera/resize regressions.
        if (shot_on && frames == pixel_test_settle) {
            QDir().mkpath(QFileInfo(QString::fromUtf8(shot_path)).absolutePath());
            bool ok = save_scene_png(QString::fromUtf8(shot_path));
            std::printf("shot %s: %s\n", shot_path, ok ? "ok" : "save failed");
            std::fflush(stdout);
            QApplication::quit();
            return;
        }
        if (pixel_test_on && frames == pixel_test_settle && !prov_pending) {
            if (pixel_test_x < pw && pixel_test_y < ph &&
                prov_readback.begin(gfx.uploader, targets.scene, pixel_test_x, pixel_test_y)) {
                prov_pending = true;
                last_click_x = pixel_test_x;
                last_click_y = pixel_test_y;
            }
        }
        if (pixel_test_on && frames > pixel_test_settle + 5 && !prov_pending) {
            // begin() kept failing (probe outside the target): fail loud,
            // nonzero exit for CI.
            std::printf("pixel %d %d: ERROR begin failed\n", pixel_test_x, pixel_test_y);
            std::fflush(stdout);
            QApplication::exit(1);
        }
        if (scene_visible && click && !prev_click && mp.x() >= 0 && mp.y() >= 0 &&
            mp.x() < pw && mp.y() < ph &&
            prov_readback.begin(gfx.uploader, targets.scene, mp.x(), mp.y())) {
            last_click_x = mp.x();
            last_click_y = mp.y();
            prov_pending = true;
        }
        prev_click = click;

        // Poll the provenance readback (fence submitted on begin; resolves a
        // tick later): toast the sampled rgba at the click point.
        if (prov_pending) {
            inspect::Provenance_Readback::Result r;
            if (prov_readback.poll(gfx.uploader, r)) {
                prov_pending = false;
                if (r.valid) {
                    if (pixel_test_on) {
                        // M5: machine-readable stdout for regression diffs.
                        std::printf("pixel %d %d: r=%.3f g=%.3f b=%.3f a=%.3f\n",
                                    pixel_test_x, pixel_test_y, r.rgba[0], r.rgba[1],
                                    r.rgba[2], r.rgba[3]);
                        std::fflush(stdout);
                        QApplication::quit();
                        return;
                    }
                    notify::notify(notify::Kind::INFO,
                                   QString("pixel (%1,%2): r=%3 g=%4 b=%5 a=%6")
                                       .arg(last_click_x)
                                       .arg(last_click_y)
                                       .arg(r.rgba[0], 0, 'f', 3)
                                       .arg(r.rgba[1], 0, 'f', 3)
                                       .arg(r.rgba[2], 0, 'f', 3)
                                       .arg(r.rgba[3], 0, 'f', 3));
                }
            }
        }

        SDL_GPUFence* fence =
            scene::submit_scene_frame(gfx.gpu, sc, targets.scene, resources,
                                      pw, ph, preview_pipe, swap_pipe, preview_sampler,
                                      preview_sampler, targets.previews);
        if (fence) SDL_ReleaseGPUFence(gfx.gpu, fence);
        // GIF capture: one PNG of the scene every 4th tick (~17 fps) while
        // active; same blocking readback as PNG export. When the [start,end]
        // window elapses, kick the ffmpeg assembly in the background.
        // Node previews: 1x/second, read back every 128px target
        // (pass outputs + final) into QImages for the graph canvas. The
        // uploader fence from download_end resolves next tick (async).
        static int preview_tick = 0;
        static QVector<QImage> preview_images;
        static std::vector<gfx::Staging> preview_readbacks;
        if (++preview_tick >= 60) {
            preview_tick = 0;
            if (!preview_readbacks.empty()) { // poll last second's batch
                bool all = true;
                for (auto& st : preview_readbacks)
                    if (!gfx::staging_ready(gfx.uploader, st)) { all = false; break; }
                if (all) {
                    preview_images.clear();
                    for (auto& st : preview_readbacks) {
                        QImage img(gfx::staging_read(st), scene::PREVIEW_SIZE,
                                   scene::PREVIEW_SIZE, QImage::Format_RGBA8888);
                        preview_images.push_back(img.copy());
                        gfx::staging_release(gfx.uploader, st);
                    }
                    preview_readbacks.clear();
                    if (shell.graph_panel_visible())
                        shell.graph_view_typed()->set_previews(preview_images);
                    // Live safelight (overdrive): the LAST preview image is
                    // the final frame at 128px; its average hue tints the
                    // chrome so the UI breathes with the shader. CPU mean
                    // over 16k pixels, 1x/second: negligible.
                    if (!preview_images.isEmpty()) {
                        const QImage& last = preview_images.back();
                        qint64 r = 0, g = 0, b = 0;
                        const int n = last.width() * last.height();
                        for (int y = 0; y < last.height(); y += 2) {
                            const QRgb* row =
                                reinterpret_cast<const QRgb*>(last.constScanLine(y));
                            for (int x = 0; x < last.width(); x += 2) {
                                r += qRed(row[x]);
                                g += qGreen(row[x]);
                                b += qBlue(row[x]);
                            }
                        }
                        const int samples = ((last.width() + 1) / 2) *
                                            ((last.height() + 1) / 2);
                        if (samples > 0)
                            shell.set_live_tint(QColor(int(r / samples),
                                                       int(g / samples),
                                                       int(b / samples)));
                    }
                }
            }
            if (preview_readbacks.empty()) { // graph canvas + live tint feed
                for (SDL_GPUTexture* tex : targets.previews) {
                    preview_readbacks.push_back(
                        gfx::uploader_download_texture_region_begin(
                            gfx.uploader, tex, 0, 0, scene::PREVIEW_SIZE,
                            scene::PREVIEW_SIZE));
                }
            }
        }
        // GIF capture: one PNG of the scene every 4th tick (~17 fps) while
        // active; same blocking readback as PNG export. When the [start,end]
        // window elapses, kick the ffmpeg assembly in the background.
        if (g_gif_capture) {
            if (g_gif_frame_n == 0) g_gif_started_s = t;
            static int gif_tick = 0;
            if (++gif_tick % 4 == 0) {
                gfx::Staging st = gfx::uploader_download_texture_region_begin(
                    gfx.uploader, targets.scene, 0, 0, uint32_t(pw), uint32_t(ph));
                // fenced submit in download_end: poll, don't re-flush (SEGV).
                while (!gfx::staging_ready(gfx.uploader, st)) {}
                QImage img(gfx::staging_read(st), pw, ph, QImage::Format_RGBA8888);
                img.save(QString("exports/gif_frames/frame_%1.png")
                             .arg(g_gif_frame_n++, 4, 10, QChar('0')));
                gfx::staging_release(gfx.uploader, st);
                if (t - g_gif_started_s >= g_gif_end_s) {
                    g_gif_capture = false;
                    export_flow::assemble_gif(
                        "exports/gif_frames", g_gif_frame_n,
                        QString("exports/%1.gif").arg(
                            manager.scenes[size_t(manager.current)].title.c_str()));
                    notify::notify(notify::Kind::INFO,
                                   QString("gif: %1 frames assembling").arg(g_gif_frame_n));
                }
            }
        }
        // Present: blit scene -> swapchain in its own command buffer, AFTER
        // the scene submission (SDL executes submissions in order). One
        // acquire per tick; gfx_end_frame submits unconditionally, so the
        // buffer is released even when no drawable was available.
        gfx::gfx_begin_frame(gfx, sdl_win);
        if (gfx.swapchain) {
            if (!shell.ui.paused) t += 1.0f / 60.0f;
            SDL_GPUColorTargetInfo bt{};
            bt.texture = gfx.swapchain;
            bt.load_op = SDL_GPU_LOADOP_CLEAR;
            bt.store_op = SDL_GPU_STOREOP_STORE;
            bt.clear_color = SDL_FColor{0, 0, 0, 1};
            SDL_GPURenderPass* rp = SDL_BeginGPURenderPass(gfx.command_buffer, &bt, 1, nullptr);
            SDL_BindGPUGraphicsPipeline(rp, swap_pipe);
            SDL_GPUTextureSamplerBinding bind{targets.scene, preview_sampler};
            SDL_BindGPUFragmentSamplers(rp, 0, &bind, 1);
            SDL_GPUViewport vp2{0, 0, float(pw), float(ph), 0.f, 1.f};
            SDL_SetGPUViewport(rp, &vp2);
            SDL_DrawGPUPrimitives(rp, 3, 1, 0, 0);
            SDL_EndGPURenderPass(rp);
        }
        gfx::gfx_end_frame(gfx);
    };
    // Scene switch: save the outgoing graph, lazy-load the target, rebuild UI.
    QObject::connect(&shell, &shell::Shell::scene_selected, [&](int i) {
        if (i < 0 || i >= int(manager.scenes.size()) || i == manager.current) return;
        shell.flush_graph_layout(); // save graph of the scene being left
        auto& slot = manager.scenes[size_t(i)];
        if (!slot.loaded &&
            !scene::scene_load_into(gfx.gpu, slot, slot.title, scene_roots)) {
            notify::notify(notify::Kind::ERROR_,
                           QString("scene failed to load: %1").arg(slot.title.c_str()));
            return; // stay on the current scene
        }
        manager.current = i;
        pick_model(slot);
        {
            int sw = 0, sh = 0;
            SDL_GetWindowSizeInPixels(sdl_win, &sw, &sh);
            resize_targets(sw, sh);
        }
        watch_active();
        shell.scene_switched();
    });
    // LEARN trail chip: switch to the named scene (same path as the
    // selector; the shell rebuilds its panels via scene_switched).
    QObject::connect(&shell, &shell::Shell::scene_open_requested,
                     [&](const QString& title) {
                         for (size_t i = 0; i < manager.scenes.size(); ++i) {
                             if (manager.scenes[i].title != title.toStdString())
                                 continue;
                             emit shell.scene_selected(int(i));
                             return;
                         }
                         notify::notify(notify::Kind::WARN,
                                        QString("scene not found: %1").arg(title));
                     });
    QObject::connect(&shell, &shell::Shell::save_all_requested, [&] {
        scene::scene_request_build(build, {manager.scenes[size_t(manager.current)].title});
    });
    // Live multipass: a link edit on the graph canvas saves graph.json
    // IMMEDIATELY (the 10 s autosave made edits feel dead); the watcher
    // sees the file change and re-plans the scene this frame.
    if (shell.graph_view_typed()) {
        QObject::connect(shell.graph_view_typed(),
                         &graph_editor::Node_View::pipeline_changed, [&] {
            shell.flush_graph_layout();
        });
    }
    // CONTROLS: reset camera to the autorotate default (orbit spin resumes;
    // flycam off). The monitor's R key does the same via the state pointers.
    QObject::connect(&shell, &shell::Shell::camera_reset_requested, [&] {
        if (!g_cam_yaw) return;
        *g_cam_yaw = g_app_time * camera::kAutorotateYawRate;
        *g_cam_pitch = camera::kDefaultPitch;
        *g_cam_dist = camera::kDist;
        *g_fly_on = false;
    });
    // PNG export: download the scene texture (device px), encode PNG via
    // QImage in exports/. Blocking readback — single frame, same cost
    // class as the pixel inspector.
    QObject::connect(&shell, &shell::Shell::png_export_requested, [&] {
        QDir().mkpath("exports");
        QString out = QString("exports/%1_%2.png")
                          .arg(manager.scenes[size_t(manager.current)].title.c_str())
                          .arg(QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss"));
        bool ok = save_scene_png(out);
        notify::notify(ok ? notify::Kind::INFO : notify::Kind::ERROR_,
                       ok ? QString("png saved: %1").arg(out)
                          : QString("png export failed: %1").arg(out));
    });
    // GIF capture: on request, dump frames for [start,end]s of wall time,
    // then assemble with ffmpeg (17 fps, 480px) in the background.
    QObject::connect(&shell, &shell::Shell::gif_export_requested,
                     [&](float start_s, float end_s) {
                         g_gif_capture = true;
                         g_gif_end_s = end_s;
                         (void)start_s; // capture starts now; [start,end] is the Odin semantic
                         QDir().mkpath("exports/gif_frames");
                         for (const QString& f :
                              QDir("exports/gif_frames").entryList({"frame_*.png"}))
                             QFile::remove("exports/gif_frames/" + f);
                         g_gif_frame_n = 0;
                     });
    // Qt popups over the viewport lose the mouse race to the SDL child
    // window (NSWindowAbove): hide the renderer while a popup is up.
    QObject::connect(&shell, &shell::Shell::popup_mouse_shield, [&](bool on) {
        if (on) SDL_HideWindow(sdl_win);
        else SDL_ShowWindow(sdl_win);
    });

    if (!init()) return 1;
    watch_active(); // scenes loaded now: watch the ACTUAL scene's files.
                    // The startup call ran on an empty scene list and
                    // registered nothing — saves never rebuilt.
    // Qt owns the run loop (NSApp must run for window activation and mouse
    // delivery). Frames are a 16 ms QTimer on the same thread.
    QTimer frame_timer; // TEMP-PROF probes below (perf_probe.hpp at top)
    QObject::connect(&frame_timer, &QTimer::timeout, [&] {
        SDL_PumpEvents();
        perf_log("frame-tick", -1.0); // TEMP-PROF: frames pumped
        tick();
    });
    frame_timer.start(16);
    // TEMP-PROF SIM: GIS_PERF_SIM=drag replays a gutter drag (200 ms),
    // then quits. GIS_PERF_SIM=type sends synthetic typing into the editor
    // (260 ms), then quits. Zero effect unless the env var is set. Remove
    // with the rest of the Plan 01 instrumentation.
    if (const QByteArray sim = qgetenv("GIS_PERF_SIM"); !sim.isEmpty()) {
        QTimer::singleShot(7000, [sim, &shell] { // AFTER slangd spawn (3 s) + handshake
            if (sim == "drag") {
                // Production realism: SPLIT mode, and a mouse-move at
                // ~120 Hz (each one a set_split_gutter) — not a zero-gap loop.
                shell.ui.preview = shell::Preview_Mode::SPLIT;
                shell.ui.fullscreen_view = false;
                QApplication::processEvents();
                QElapsedTimer drag; drag.start();
                int n = 0;
                while (drag.elapsed() < 200) {
                    float f = 0.42f + 0.1f * float(drag.elapsed()) / 200.0f;
                    shell.set_split_gutter(f);
                    QApplication::processEvents();
                    ++n;
                    QElapsedTimer gap; gap.start();
                    while (gap.elapsed() < 8) QApplication::processEvents(); // ~120 Hz
                }
                std::fprintf(stderr, "[perf] sim: drag done, %d gutter updates in 200 ms\n", n);
                QApplication::quit();
            } else if (sim == "type") {
                // Synthetic typing: post key events to the focused editor.
                // Opens the first scene's entry tab first.
                shell.editor_open_first_tab_for_test(); // TEMP shim in shell.cpp
                if (auto* ed = shell.editor_current_for_test()) {
                    if (!qEnvironmentVariableIsEmpty("GIS_NO_ACS")) // A/B test
                        ed->setAutoCompletionSource(QsciScintilla::AcsNone);
                    ed->setFocus(); // key events land only on a focused editor
                }
                QApplication::processEvents();
                QElapsedTimer typing; typing.start();
                const QString word = "float2(1.0, 0.0, 0.0, 1.0); // typing probe";
                int i = 0;
                while (typing.elapsed() < 260 && i < word.size()) {
                    const QString s(word[i]);
                    for (QKeyEvent* press : { new QKeyEvent(QEvent::KeyPress, Qt::Key_A,
                                                 Qt::NoModifier, s),
                                              new QKeyEvent(QEvent::KeyRelease, Qt::Key_A,
                                                 Qt::NoModifier, s) }) {
                        QCoreApplication::postEvent(QApplication::focusWidget(), press);
                    }
                    QApplication::processEvents();
                    ++i;
                    // ~50 keystrokes/s: faster than any human, stresses bursts.
                    { QElapsedTimer gap; gap.start();
                      while (gap.elapsed() < 20) QApplication::processEvents(); }
                }
                std::fprintf(stderr, "[perf] sim: typed %d chars in %lld ms\n",
                             i, typing.elapsed());
                QTimer::singleShot(2500, [] { std::_Exit(0); });
                // wait: completion debounce 130 ms + slangd roundtrip, then quit
            }
        });
        QTimer::singleShot(11000, [] { std::_Exit(0); }); // sim safety net
    }
    // Quit path: stop the frame loop BEFORE anything else — a tick during
    // teardown dereferences half-destroyed ObjC/Qt objects (ASan SEGV in
    // objc_msgSend via QTimer::timerEvent). Then flush the visible graph
    // (Shell also does its own aboutToQuit flush; this covers the SDL-side
    // state) and release the single-instance lock (a leftover lock forces
    // a 60 s stale wait or a manual rm on the next boot).
    QObject::connect(qApp, &QCoreApplication::aboutToQuit, [&] {
        frame_timer.stop();
        shell.flush_graph_layout();
        assets::destroy(gfx, shared);
        ::remove("assets/gis.lock");
    });
    return app.exec();
}
