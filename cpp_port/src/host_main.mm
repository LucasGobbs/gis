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

#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#include <algorithm>
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
#include <QImage>
#include "export/export_flow.hpp"
#include "gfx/inspect.hpp"
#include <sys/stat.h>
#include <ctime>
#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#include <algorithm>
#include <cstdio>
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
// resize from that edge; interior -> drag the whole frame. State persists
// in assets/ui.prefs (pip_x/pip_y/pip_w/pip_h) via the lambda-captured
// pointers below.
static NSRect g_pip_rect = NSZeroRect;   // current preview frame (screen)
static bool g_pip_drag = false;          // moving the whole frame
static bool g_pip_resize = false;        // resizing from an edge
static int g_pip_edges = 0;              // bitmask: 1=L 2=R 4=T 8=B
static NSPoint g_pip_last;               // last drag position (screen)
static const CGFloat kPipEdge = 6.0;     // resize band width in points
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
static id g_pip_monitor = nil;

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    // C locale: uniforms are '.'-decimal; the system locale (pt_BR) renders
    // spinboxes as "0,25" and then rejects round-trip typed input.
    QLocale::setDefault(QLocale::c());
    // Qlementine owns the whole UI look: one dark theme JSON + matching icons.
    oclero::qlementine::QlementineStyle* style =
        new oclero::qlementine::QlementineStyle(&app);
    style->setThemeJsonPath(":/qlementine/resources/themes/dark.json");
    app.setStyle(style);
    theme::load_fonts();
    oclero::qlementine::icons::initializeIconTheme();
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
            break;
        }
        if (argv[i][0] != '-') {
            scene_name_arg = argv[i];
            break;
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
    // Native-framed window: the OS owns the title bar (traffic lights, drag,
    // snapping) — the hand-rolled Traffic_Light + drag hacks are gone. The
    // title bar is styled transparent right after the native window exists
    // (Part B styling below) so it melts into the Shell header.
    shell.setWindowFlags(Qt::Window | Qt::WindowTitleHint |
                         Qt::WindowMinMaxButtonsHint | Qt::WindowCloseButtonHint);
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
notify::attach(vp);
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
    // Header camouflage (Part B): the transparent full-size-content title
    // bar over a Bench-colored window reads as one continuous surface with
    // the Shell's own top bar — no visible OS chrome, but native drag, the
    // real traffic lights, and window snapping all work.
    qt_nswin.titlebarAppearsTransparent = YES;
    qt_nswin.styleMask |= NSWindowStyleMaskFullSizeContentView;
    qt_nswin.backgroundColor =
        [NSColor colorWithCalibratedRed:0x1A / 255.0 green:0x1B / 255.0
                                   blue:0x20 / 255.0 alpha:1.0]; // kSurfaceBench
    qt_nswin.movable = YES;

auto sync_child = [&] {
    NSRect r = [qt_nswin convertRectToScreen:[qt_nsview convertRect:[qt_nsview bounds] toView:nil]];
    if (!NSEqualRects(r, [sdl_nswin frame])) [sdl_nswin setFrame:r display:YES];
};
[qt_nswin addChildWindow:sdl_nswin ordered:NSWindowAbove];
sync_child();
SDL_ShowWindow(sdl_win);


gfx::Gfx gfx;
auto vpw = [&] { return shell.viewport()->width(); };
auto vph = [&] { return shell.viewport()->height(); };
    if (!gfx::gfx_create(gfx, sdl_win, vpw(), vph())) {
        std::fprintf(stderr, "gfx create failed: %s\n", SDL_GetError());
        return 1;
    }

    // PiP gesture monitor (see the block above): drags and edge-resizes the
    // preview frame; cursor affordance on hover. The lambda runs on the
    // main thread only (Qt event loop), so the statics need no lock.
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
        __block NSEvent* (^monitor)(NSEvent*) = ^NSEvent*(NSEvent* ev) {
            NSEventType t = ev.type;
            NSPoint p = [NSEvent mouseLocation]; // screen coords (bottom-left)
            NSWindow* w = ev.window;
            if (w != sdl_nswin) return ev; // only the preview window
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
                g_pip_drag = g_pip_edges == 0;
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
                g_pip_drag = g_pip_resize = false;
                pip_save_prefs();
                return ev;
            }
            return ev;
        };
        g_pip_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:g_pip_mask handler:monitor];
    }

    // Offscreen targets + resources; resize updates depth/pass texture refs.
    scene::Render_Targets targets;
    scene::Scene_Resources resources;
    auto resize_targets = [&]() {
        QWidget* vp = shell.viewport();
        int pw = int(vp->width() * vp->devicePixelRatioF());
        int ph = int(vp->height() * vp->devicePixelRatioF());
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
    {   // 1x1 black fallback for unmet sampler inputs (Odin black_texture).
        SDL_GPUTextureCreateInfo btci{};
        btci.type = SDL_GPU_TEXTURETYPE_2D;
        btci.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        btci.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
        btci.width = 1;
        btci.height = 1;
        btci.layer_count_or_depth = 1;
        btci.num_levels = 1;
        resources.black_texture = SDL_CreateGPUTexture(gfx.gpu, &btci);
        resources.black_sampler = preview_sampler;
    }
    // Hot reload: watch the active scene dir.
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
        // Initial scene load; frames are driven by frame_timer below.
        if (!scene::scene_load_into(gfx.gpu, manager.scenes[size_t(idx)],
                                    names[size_t(idx)], scene_roots)) {
            std::fprintf(stderr, "scene %s failed to load: %s\n",
                         names[size_t(idx)].c_str(),
                         manager.scenes[size_t(idx)].pipeline_error.c_str());
            return false;
        }
        resize_targets();
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

    auto tick = [&] {
        ++frames;
        // The SDL child window either fills the viewport (scene view) or
        // shrinks to a floating preview frame (code editor up) — the editor
        // needs the shader visible while editing. sync_child is skipped
        // while the preview frame owns the rect: a per-tick flip-flop
        // between the two rects starves the UI with resizes.
        bool editor_page = shell.ui.mode == shell::Sidebar_Mode::FILES;
        if (!editor_page) sync_child();
        // Apply finished goose-builds: worker writes artifacts, only this
        // pump creates GPU pipelines (must run on the main/GPU thread).
        scene::scene_build_pump(build, manager, gfx.gpu, scene_roots, scene_failed);
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
            // Preview frame: the USER's rect (drag/resize monitor above)
            // once set; the default anchored rect (top-right, 40%×55%)
            // otherwise. The rect comes from the NATIVE viewport NSView
            // with the same convertRectToScreen path as sync_child — the
            // pure-Qt mapping drifted off-window under FramelessWindowHint.
            if (NSIsEmptyRect(g_pip_rect)) {
                // contentLayoutRect excludes the (transparent) title bar:
                // with FullSizeContentView the view's bounds DO include it,
                // and a bounds-based PiP would poke out under the lights.
                NSRect content = [qt_nswin contentLayoutRect];
                CGFloat pw = NSWidth(content) * 0.40;
                CGFloat ph = NSHeight(content) * 0.55;
                NSRect inner = NSMakeRect(NSWidth(content) - pw - 12, 0, pw, ph);
                NSRect in_win = [qt_nsview convertRect:inner toView:nil];
                g_pip_rect = [qt_nswin convertRectToScreen:in_win];
            }
            if (!NSEqualRects(g_pip_rect, [sdl_nswin frame]))
                [sdl_nswin setFrame:g_pip_rect display:YES];
            preview_applied = true;
            if (!sdl_shown) {
                SDL_ShowWindow(sdl_win);
                sdl_shown = true;
            }
        } else {
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
        // SDL now draws into the viewport NSView, so its drawable matches the
        // widget size in device pixels (DPR applies).
        int pw = int(vp->width() * vp->devicePixelRatioF());
        int ph = int(vp->height() * vp->devicePixelRatioF());
        if (pw <= 0 || ph <= 0) return; // layout not settled yet
        if (scene::targets_needs_resize(targets, pw, ph, int(sc.passes.size()))) {
            resize_targets(); // layout settles late; load-time resize is stale
        }
        // Scene submission runs even when the swapchain has no drawable this
        // frame (occluded window): EVERY acquired command buffer must be
        // submitted, or Metal's in-flight semaphore starves and the next
        // SDL_AcquireGPUCommandBuffer blocks forever (one-window freeze).
        QPoint mp = vp->mapFromGlobal(QCursor::pos());
        mp = QPoint(int(mp.x() * vp->devicePixelRatioF()), int(mp.y() * vp->devicePixelRatioF()));
        static bool prev_click = false;
        bool click = QApplication::mouseButtons() & Qt::LeftButton;
        scene::scene_write_uniforms(sc, float(pw), float(ph), t, shell.ui.color,
                                    float(mp.x()), float(mp.y()), click);
        // Pixel provenance (stage 8): a fresh click inside the viewport starts
        // a 1x1 readback of the scene target at the cursor (poll below).
        if (click && !prev_click && mp.x() >= 0 && mp.y() >= 0 &&
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
        resize_targets();
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
    // Qt popups over the viewport lose the mouse race to the SDL child
    // window (NSWindowAbove): make the child mouse-transparent while a
    // popup is up.
    // PNG export: download the scene texture (device px), encode PNG via
    // QImage in exports/. Blocking readback — single frame, same cost
    // class as the pixel inspector.
    QObject::connect(&shell, &shell::Shell::png_export_requested, [&] {
        gfx::Staging st = gfx::uploader_download_texture_region_begin(
            gfx.uploader, targets.scene, 0, 0, uint32_t(targets.w), uint32_t(targets.h));
        // download_end already submitted and fenced the copy (owns_pass);
        // wait by polling the fence, NOT uploader_flush_blocking (the copy
        // pass is closed — flushing again SEGVs in METAL_WaitForFences).
        while (!gfx::staging_ready(gfx.uploader, st)) {}
        const uint8_t* rgba = gfx::staging_read(st);
        QDir().mkpath("exports");
        QString out = QString("exports/%1_%2.png")
                          .arg(manager.scenes[size_t(manager.current)].title.c_str())
                          .arg(QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss"));
        QImage img(rgba, targets.w, targets.h, QImage::Format_RGBA8888);
        bool ok = img.save(out);
        gfx::staging_release(gfx.uploader, st);
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
    QTimer frame_timer;
    QObject::connect(&frame_timer, &QTimer::timeout, [&] {
        SDL_PumpEvents();
        tick();
    });
    frame_timer.start(16);
    // Quit path: stop the frame loop BEFORE anything else — a tick during
    // teardown dereferences half-destroyed ObjC/Qt objects (ASan SEGV in
    // objc_msgSend via QTimer::timerEvent). Then flush the visible graph
    // (Shell also does its own aboutToQuit flush; this covers the SDL-side
    // state) and release the single-instance lock (a leftover lock forces
    // a 60 s stale wait or a manual rm on the next boot).
    QObject::connect(qApp, &QCoreApplication::aboutToQuit, [&] {
        frame_timer.stop();
        shell.flush_graph_layout();
        ::remove("assets/gis.lock");
    });
    return app.exec();
}
