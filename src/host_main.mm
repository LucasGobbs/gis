// gis_host: Qt shell + SDL GPU scene runtime in ONE window: the SDL window is
// a borderless NSWindow ordered as a child of the Qt window, parked over the
// Shell's viewport widget (SDL's setContentView path would orphan the Qt
// chrome). Frames are a 16 ms QTimer under app.exec() (NSApp must run for
// window activation and mouse delivery).
#include <AppKit/AppKit.h> // before Qt: Qt headers #define slots, breaking Foundation

#include "export/export_flow.hpp"
#include "gfx/assets.hpp"
#include "gfx/camera.hpp"
#include "gfx/gfx.hpp"
#include "gfx/inspect.hpp"
#include "gfx/scene_runtime.hpp"
#include "ui/menubar.hpp"
#include "ui/notify.hpp"
#include "ui/shell.hpp"
#include "ui/theme.hpp"

#include <oclero/qlementine/icons/QlementineIcons.hpp>
#include <oclero/qlementine/style/QlementineStyle.hpp>

#include <QApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QGuiApplication>
#include <QIcon>
#include <QImage>
#include <QScreen>
#include <QTimer>

#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#include <CoreGraphics/CoreGraphics.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <sys/time.h>

#include <algorithm>
#include <cerrno>
#include <clocale>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr CGFloat kPipEdge = 8.0;          // resize band width in points (unified with gutter)
constexpr CGFloat kPipMinW = 160.0, kPipMinH = 100.0;
constexpr CGFloat kTabRowH = 48.0;         // editor tab row the preview frame stays below
constexpr qint64 kResizeCoalesceNs = 100LL * 1000 * 1000; // native live-resize: one resize / 100 ms
constexpr int kLockStaleSec = 60;
constexpr int kLockTouchTicks = 600;       // refresh the lock mtime ~every 10 s
constexpr int kPreviewPeriodTicks = 60;    // node-preview readback cadence (~1 s)
constexpr int kRevealMinFrames = 15, kRevealMaxFrames = 180;
constexpr int kProbeSettleFrames = 30;     // frames before --pixel-test / --shot sample (bake settle)
constexpr int kFrameMs = 16;

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

struct Cli_Options {
    const char* scene = "01_hello_pixel";
    // M5 --pixel-test X Y: render N frames, read back one pixel of the scene
    // target, print rgba, quit (legacy parity with selftest.odin).
    bool pixel_test = false;
    int pixel_x = 0, pixel_y = 0;
    const char* shot_path = nullptr; // --shot PATH: save the scene target as PNG and quit
};

// Scene name: bare positional arg ("01_hello_pixel") or "--scene NAME".
// QApplication consumed only Qt-recognized args; ours stay in argv.
Cli_Options parse_cli(int argc, char** argv) {
    Cli_Options o;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--scene") == 0 && i + 1 < argc) {
            o.scene = argv[++i];
        } else if (std::strcmp(argv[i], "--pixel-test") == 0 && i + 2 < argc) {
            o.pixel_test = true;
            o.pixel_x = std::atoi(argv[i + 1]);
            o.pixel_y = std::atoi(argv[i + 2]);
            i += 2;
        } else if (std::strcmp(argv[i], "--shot") == 0 && i + 1 < argc) {
            o.shot_path = argv[++i];
        } else if (argv[i][0] != '-') {
            o.scene = argv[i];
        }
    }
    return o;
}

// ---------------------------------------------------------------------------
// Process setup
// ---------------------------------------------------------------------------

// Walks up from cwd and the executable dir to find the repo root (the dir
// containing src/shaders/scenes) and chdirs there. Covers `make run-cpp` from
// the repo root, CLion (cwd = build dir) and Finder launch.
bool chdir_repo_root() {
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

// Single instance: a second gis_host fighting the first for the Metal device
// / SDL child window raced MTLCompilerService at startup and died with
// std::bad_alloc before any log line. O_EXCL lockfile, removed on every exit
// path by the destructor. The running instance refreshes the mtime (touch) so
// "older than 60 s" only ever means a crashed holder.
class Instance_Lock {
public:
    ~Instance_Lock() {
        if (held_) ::remove(kPath);
    }
    bool acquire() {
        for (int attempt = 0; attempt < 2; ++attempt) {
            if (FILE* f = std::fopen(kPath, "wx")) {
                std::fclose(f); // the lock IS the file's existence
                held_ = true;
                return true;
            }
            struct stat st;
            if (::stat(kPath, &st) != 0) {
                std::fprintf(stderr, "cannot create %s: %s\n", kPath, std::strerror(errno));
                return false;
            }
            if (::time(nullptr) - st.st_mtime <= kLockStaleSec) {
                std::fprintf(stderr,
                             "gis_host is already running (assets/gis.lock held); close it first\n");
                return false;
            }
            ::remove(kPath); // crashed holder: take over, the next attempt re-creates it
        }
        return false;
    }
    void touch() const {
        if (held_) ::utimes(kPath, nullptr);
    }

private:
    static constexpr const char* kPath = "assets/gis.lock";
    bool held_ = false;
};

// SDL assertion failures popping a modal dialog via dispatch_sync would
// deadlock the app: log and ignore.
bool init_sdl() {
    SDL_SetAssertionHandler(
        [](const SDL_AssertData* data, void*) {
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
        return false;
    }
    return true;
}

// Frameless window: the Shell's own top bar IS the title bar. The Qt window
// must be on-screen before the SDL child window is parked over its viewport.
void setup_shell_window(shell::Shell& shell) {
    shell.setWindowFlags(Qt::Window | Qt::FramelessWindowHint);
    shell::build_native_menus(shell); // system menu bar (File/Scene/Edit/Help)
    shell.resize(960, 600 + shell::kTopbarH);
    const QRect avail = QGuiApplication::primaryScreen()->availableGeometry();
    shell.move(avail.x() + (avail.width() - shell.width()) / 2,
               avail.y() + (avail.height() - shell.height()) / 2);
    shell.setWindowOpacity(0.0); // faded in by the tick when startup settles
    shell.showFullScreen();
    shell.raise();
    // CLI-launched: AppKit won't activate the app, so the window appears
    // behind the terminal (or nowhere visible). Force activation.
    void* ns_app = reinterpret_cast<void* (*)(void*, SEL)>(objc_msgSend)(
        (void*)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    using BoolSend = void (*)(void*, SEL, BOOL);
    reinterpret_cast<BoolSend>(objc_msgSend)(
        ns_app, sel_registerName("activateIgnoringOtherApps:"), YES);
}

// ---------------------------------------------------------------------------
// SDL child window over the viewport
// ---------------------------------------------------------------------------

// SDL's COCOA_VIEW_POINTER property calls setContentView on the Qt window and
// replaces its chrome. So SDL owns a borderless NSWindow that is attached as
// a child of the Qt window and kept over the viewport (screen coords,
// re-synced every tick).
struct Preview_Window {
    SDL_Window* sdl = nullptr;
    NSWindow* sdl_ns = nil;
    NSWindow* qt_ns = nil;
    NSView* qt_view = nil;

    // The viewport widget in Cocoa screen coords (bottom-left origin).
    NSRect viewport_screen_rect() const {
        return [qt_ns convertRectToScreen:[qt_view convertRect:[qt_view bounds] toView:nil]];
    }
    void sync_child() const {
        NSRect r = viewport_screen_rect();
        if (!NSEqualRects(r, [sdl_ns frame])) [sdl_ns setFrame:r display:YES];
    }
};

// Cocoa screen rect (bottom-left origin) -> Qt global rect (top-left origin).
QRect qt_rect_from_cocoa(NSRect r) {
    const CGFloat screen_h = [[[NSScreen screens] firstObject] frame].size.height;
    return QRect(int(r.origin.x), int(screen_h - r.origin.y - r.size.height), int(r.size.width),
                 int(r.size.height));
}

// Native preview frame (the "one unit" contract): a 1px border + 6px corner
// radius drawn by a CALayer ON the SDL window — the render content stays
// untouched, but the frame reads as this app's chrome, not a guest window.
void style_preview_frame(NSWindow* sdl_ns) {
    NSView* sdl_view = sdl_ns.contentView;
    sdl_view.wantsLayer = YES;
    sdl_view.layer.masksToBounds = NO;
    sdl_view.layer.cornerRadius = 6.0;
    sdl_view.layer.borderWidth = 1.0;
    sdl_view.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.12].CGColor;
}

// Failures print to stderr: this runs before app.exec(), so toasts never show.
bool attach_sdl_child(shell::Shell& shell, Preview_Window& out) {
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
    out.sdl = SDL_CreateWindowWithProperties(props);
    SDL_DestroyProperties(props);
    if (!out.sdl) {
        std::fprintf(stderr, "SDL attach to viewport failed: %s\n", SDL_GetError());
        return false;
    }
    out.sdl_ns = (__bridge NSWindow*)SDL_GetPointerProperty(
        SDL_GetWindowProperties(out.sdl), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
    out.qt_view = (__bridge NSView*)reinterpret_cast<void*>(vp->winId());
    out.qt_ns = [out.qt_view window];
    if (!out.sdl_ns || !out.qt_ns) {
        std::fprintf(stderr, "SDL attach: missing NSWindow\n");
        SDL_DestroyWindow(out.sdl);
        out.sdl = nullptr;
        return false;
    }
    [out.sdl_ns setAlphaValue:0.0]; // revealed by the tick once the drawable matches the viewport
    [out.qt_ns addChildWindow:out.sdl_ns ordered:NSWindowAbove];
    out.sync_child();
    SDL_ShowWindow(out.sdl);
    style_preview_frame(out.sdl_ns);
    return true;
}

// ---------------------------------------------------------------------------
// PiP drag + resize (editor page) and camera input monitors
// ---------------------------------------------------------------------------
// The preview frame is the SAME SDL child window; in editor mode it floats
// and the user must be able to drag it and resize it from its edges (to park
// it beside a split editor, etc). A borderless NSWindow has no chrome, so a
// local NSEvent monitor implements both gestures: border hit -> resize from
// that edge; interior -> drag the whole frame. While DRAGGING, the cursor
// position is hit-tested against the viewport's snap zones (left/right half
// = dock split there, anywhere else = keep floating); the shell paints the
// zones, the drop applies the mode. Rect persists in assets/ui.prefs
// (pip_x/pip_y/pip_w/pip_h). All monitors run on the main thread only.

NSRect g_pip_rect = NSZeroRect;   // current preview frame (screen)
bool g_pip_drag = false;          // moving the whole frame
bool g_pip_resize = false;        // resizing from an edge
int g_pip_edges = 0;              // bitmask: 1=L 2=R 4=near-origin.y 8=far-origin.y (Cocoa y-up)
NSPoint g_pip_last = NSZeroPoint; // last drag position (screen)
int g_snap_zone = -1;             // live hover: 0=left 1=right -1=none

constexpr const char* kPrefsPath = "assets/ui.prefs";

int pip_edges_at(NSPoint p) {
    int e = 0;
    if (p.x - g_pip_rect.origin.x < kPipEdge) e |= 1;
    if (g_pip_rect.origin.x + g_pip_rect.size.width - p.x < kPipEdge) e |= 2;
    if (p.y - g_pip_rect.origin.y < kPipEdge) e |= 4;
    if (g_pip_rect.origin.y + g_pip_rect.size.height - p.y < kPipEdge) e |= 8;
    return e;
}

// Rewrites only the pip_* lines of the prefs file.
void pip_save_prefs() {
    std::stringstream all;
    {
        std::ifstream in(kPrefsPath);
        all << in.rdbuf();
    }
    std::ofstream out(kPrefsPath, std::ios::trunc);
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

// Loads the persisted rect once; keeps whatever is valid.
void pip_load_prefs() {
    std::ifstream in(kPrefsPath);
    std::map<std::string, int> kv;
    std::string line;
    while (std::getline(in, line)) {
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        kv[line.substr(0, eq)] = std::atoi(line.c_str() + eq + 1);
    }
    if (kv.count("pip_w") && kv["pip_w"] > 120 && kv.count("pip_h") && kv["pip_h"] > 80)
        g_pip_rect = NSMakeRect(kv["pip_x"], kv["pip_y"], kv["pip_w"], kv["pip_h"]);
}

// Snap hit-test in Cocoa screen coords: the viewport rect converts via the
// same path as sync_child.
int snap_zone_at(const Preview_Window& win, NSPoint p) {
    const NSRect vp = win.viewport_screen_rect();
    if (p.x < NSMinX(vp) || p.x > NSMaxX(vp) || p.y < NSMinY(vp) || p.y > NSMaxY(vp)) return -1;
    return (p.x - NSMinX(vp)) > NSWidth(vp) / 2 ? 1 : 0;
}

// Cursor affordance, drag/resize gestures, snap zones. Only active in FLOAT
// mode: in SPLIT/FULL the frame is docked (the gutter drag lives in the shell).
id install_pip_monitor(shell::Shell& shell, const Preview_Window& win_in) {
    pip_load_prefs();
    shell::Shell* sh = &shell; // blocks copy captures as const: use ptr
    const Preview_Window win = win_in;
    return [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged |
                                             NSEventMaskLeftMouseUp | NSEventMaskMouseMoved
        handler:^NSEvent*(NSEvent* ev) {
            NSEventType t = ev.type;
            NSPoint p = [NSEvent mouseLocation]; // screen coords (bottom-left)
            if (ev.window != win.sdl_ns) return ev; // only the preview window
            if (sh->ui.preview != shell::Preview_Mode::FLOAT && !g_pip_drag && !g_pip_resize)
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
                g_pip_drag = g_pip_edges == 0 &&
                             sh->ui.interaction != shell::Interaction_Mode::MOUSE_ROTATE;
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
                    int zone = snap_zone_at(win, p);
                    if (zone != g_snap_zone) {
                        g_snap_zone = zone;
                        sh->set_snap_hover(zone);
                    }
                } else {
                    if (g_pip_edges & 1) { g_pip_rect.origin.x += dx; g_pip_rect.size.width -= dx; }
                    if (g_pip_edges & 2) { g_pip_rect.size.width += dx; }
                    if (g_pip_edges & 8) { g_pip_rect.origin.y += dy; g_pip_rect.size.height -= dy; }
                    if (g_pip_edges & 4) { g_pip_rect.size.height += dy; }
                    if (g_pip_rect.size.width < kPipMinW) g_pip_rect.size.width = kPipMinW;
                    if (g_pip_rect.size.height < kPipMinH) g_pip_rect.size.height = kPipMinH;
                }
                [win.sdl_ns setFrame:g_pip_rect display:YES];
                return ev;
            }
            if (t == NSEventTypeLeftMouseUp && (g_pip_drag || g_pip_resize)) {
                if (g_pip_drag && g_snap_zone >= 0) {
                    // Drop in a zone: dock SPLIT on that side. The split
                    // fraction follows where the frame was when dropped.
                    const NSRect vp = win.viewport_screen_rect();
                    float frac = float((NSMidX(g_pip_rect) - NSMinX(vp)) / NSWidth(vp));
                    sh->settle_split_gutter(g_snap_zone == 0 ? 1.0f - frac : frac);
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
        }];
}

// Camera state: the monitor below writes it, the frame tick reads it (both
// on the main thread).
struct Cam_State {
    float yaw = 0.f, pitch = camera::kDefaultPitch, dist = camera::kDist;
    bool fly_on = false;
    float fly_pos[3] = {0.f, 0.f, 0.f};
    float fly_yaw = 0.f, fly_pitch = 0.f;
    bool keys[6] = {false, false, false, false, false, false}; // W A S D E Q
    bool shift = false;
    double fly_last_t = -1.0;     // tick time of the last flycam step
    float app_time = 0.0f;        // scene clock, updated by the tick
    bool orbiting = false;
    NSPoint orbit_last = NSZeroPoint; // last drag position (screen)
};
Cam_State g_cam;

// CONTROLS / R key: back to the autorotate default (orbit spin resumes; flycam off).
void reset_camera() {
    g_cam.yaw = g_cam.app_time * camera::kAutorotateYawRate;
    g_cam.pitch = camera::kDefaultPitch;
    g_cam.dist = camera::kDist;
    g_cam.fly_on = false;
}

int fly_key_index(const QString& k) {
    static const QString keys = QStringLiteral("wasdeq");
    return k.size() == 1 ? int(keys.indexOf(k[0])) : -1;
}

// Tab toggles the flycam. Inherits the orbit spot (input_bindings.odin
// toggle_flycam contract): same sphere position and yaw/pitch; legacy
// camera_flycam then looks outward.
void toggle_flycam() {
    Cam_State& c = g_cam;
    c.fly_on = !c.fly_on;
    std::fill(c.keys, c.keys + 6, false); // no stale held keys across toggles
    if (!c.fly_on) return;
    const float cp = std::cos(c.pitch), sp = std::sin(c.pitch);
    c.fly_pos[0] = c.dist * cp * std::sin(c.yaw);
    c.fly_pos[1] = c.dist * sp;
    c.fly_pos[2] = c.dist * cp * std::cos(c.yaw);
    c.fly_yaw = c.yaw;
    c.fly_pitch = c.pitch;
}

// Orbit / dolly / flycam on the SDL preview window only. Never hides or
// grabs the cursor — deltas come from absolute event locations (the top-bar
// stuck-cursor bug must not come back through camera code).
id install_camera_monitor(shell::Shell& shell, scene::Scene_Manager& manager,
                          const Preview_Window& win_in) {
    shell::Shell* sh = &shell;
    scene::Scene_Manager* mgr = &manager;
    const Preview_Window win = win_in;
    return [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged |
                                             NSEventMaskLeftMouseUp | NSEventMaskMouseMoved |
                                             NSEventMaskScrollWheel | NSEventMaskKeyDown |
                                             NSEventMaskKeyUp | NSEventMaskFlagsChanged
        handler:^NSEvent*(NSEvent* ev) {
            Cam_State& c = g_cam;
            NSEventType t = ev.type;
            if (ev.window != win.sdl_ns) return ev;    // only the preview surface
            if (g_pip_drag || g_pip_resize) return ev; // PiP gesture wins
            NSPoint p = [NSEvent mouseLocation];
            NSRect wf = [win.sdl_ns frame];
            const bool inside = p.x >= NSMinX(wf) && p.x <= NSMaxX(wf) &&
                                p.y >= NSMinY(wf) && p.y <= NSMaxY(wf);
            if (t == NSEventTypeMouseMoved) {
                if (!inside) [[NSCursor arrowCursor] set];
                return ev;
            }
            // Flycam keys (only while the preview window is key: editor
            // focus unaffected). Handled events are swallowed. WASD/E/Q
            // movement is polled per tick; the monitor only records which are held.
            if (t == NSEventTypeKeyDown && [win.sdl_ns isKeyWindow]) {
                const QString k = QString::fromNSString(ev.charactersIgnoringModifiers).toLower();
                if (ev.keyCode == 48 && !ev.isARepeat) { // Tab: charactersIgnoringModifiers is "\t", not "tab"
                    toggle_flycam();
                    return nil;
                }
                if (ev.keyCode == 53 && c.fly_on) { // Escape
                    c.fly_on = false;
                    std::fill(c.keys, c.keys + 6, false);
                    return nil;
                }
                if (k == "r") {
                    reset_camera();
                    return nil;
                }
                if (int i = fly_key_index(k); i >= 0) { c.keys[i] = true; return nil; }
            }
            if (t == NSEventTypeKeyUp && [win.sdl_ns isKeyWindow]) {
                const QString k = QString::fromNSString(ev.charactersIgnoringModifiers).toLower();
                if (int i = fly_key_index(k); i >= 0) { c.keys[i] = false; return nil; }
            }
            if (t == NSEventTypeFlagsChanged)
                c.shift = (ev.modifierFlags & NSEventModifierFlagShift) != 0;
            if (t == NSEventTypeScrollWheel && inside) {
                // Legacy dolly: dist *= (1 - wheel.y * 0.1), clamp 0.8..8.
                CGFloat dy = ev.scrollingDeltaY;
                if ([ev hasPreciseScrollingDeltas]) dy *= 0.1;
                c.dist = std::clamp(float(c.dist * (1.0f - float(dy) * 0.1f)), 0.8f, 8.0f);
                return ev;
            }
            // Orbit: left-drag in MOUSE_ROTATE on model scenes. AUTOROTATE
            // keeps today's PiP move semantics (this monitor's drag branch
            // never fires there; the PiP monitor owns the gesture).
            if (t == NSEventTypeLeftMouseDown && inside &&
                sh->ui.interaction == shell::Interaction_Mode::MOUSE_ROTATE &&
                (c.fly_on || (!mgr->scenes.empty() &&
                              mgr->scenes[size_t(mgr->current)].uses_model))) {
                c.orbit_last = p;
                c.orbiting = true;
                return ev;
            }
            if (t == NSEventTypeLeftMouseDragged && c.orbiting) {
                CGFloat dx = p.x - c.orbit_last.x, dy = p.y - c.orbit_last.y; // y-up screen
                c.orbit_last = p;
                if (c.fly_on) {
                    // legacy flycam look (glove delta y-down): yaw -= dx, pitch -= dy_down
                    c.fly_yaw -= float(dx) * 0.006f;
                    c.fly_pitch = std::clamp(c.fly_pitch + float(dy) * 0.006f, -1.5f, 1.5f);
                } else {
                    // legacy model orbit: yaw -= dx, pitch += delta.y (y-down)
                    c.yaw -= float(dx) * 0.012f;
                    c.pitch = std::clamp(c.pitch - float(dy) * 0.012f, -1.45f, 1.45f);
                }
                return ev;
            }
            if (t == NSEventTypeLeftMouseUp && c.orbiting) c.orbiting = false;
            return ev;
        }];
}

// Removes both monitors; they hold raw pointers into shell/manager.
struct Event_Monitors {
    id pip = nil;
    id cam = nil;
    void remove() {
        if (pip) [NSEvent removeMonitor:pip];
        if (cam) [NSEvent removeMonitor:cam];
        pip = cam = nil;
    }
    ~Event_Monitors() { remove(); }
};

// AUTOROTATE: legacy spin. Drag in MOUSE_ROTATE overrides yaw/pitch (retained
// after release, like legacy). Flycam: WASD/E/Q/Shift advance the position
// with real dt.
camera::Uniforms advance_camera(float t, shell::Interaction_Mode mode, float aspect) {
    Cam_State& c = g_cam;
    c.app_time = t;
    if (mode == shell::Interaction_Mode::AUTOROTATE) {
        c.yaw = t * camera::kAutorotateYawRate;
        c.pitch = camera::kDefaultPitch;
    }
    if (c.fly_on) {
        if (c.fly_last_t < 0.0) c.fly_last_t = t;
        const float dt = float(std::min(t - c.fly_last_t, 0.25));
        c.fly_last_t = t;
        if (dt > 0.0f) {
            const float speed = 1.2f * (c.shift ? 4.0f : 1.0f) * dt;
            // Legacy dpos (input_bindings.odin): forward_planar*move.y +
            // right*move.x + up*up_axis. Fly forward xz from yaw only:
            // (sin(yaw), 0, cos(yaw)); right = forward x world-up =
            // (cos(yaw), 0, -sin(yaw)).
            const float fxz[3] = {std::sin(c.fly_yaw), 0.0f, std::cos(c.fly_yaw)};
            const float rxz[3] = {std::cos(c.fly_yaw), 0.0f, -std::sin(c.fly_yaw)};
            const float move_f = (c.keys[0] ? 1.f : 0.f) - (c.keys[2] ? 1.f : 0.f);
            const float move_r = (c.keys[3] ? 1.f : 0.f) - (c.keys[1] ? 1.f : 0.f);
            const float move_u = (c.keys[4] ? 1.f : 0.f) - (c.keys[5] ? 1.f : 0.f);
            for (int i = 0; i < 3; ++i) {
                float d = fxz[i] * move_f + rxz[i] * move_r;
                if (i == 1) d += move_u;
                c.fly_pos[i] += d * speed;
            }
        }
    } else {
        c.fly_last_t = -1.0; // re-arm dt on next activation
    }
    return c.fly_on ? camera::flycam(c.fly_pos, c.fly_yaw, c.fly_pitch, aspect)
                    : camera::orbit(c.yaw, c.pitch, c.dist, aspect);
}

// ---------------------------------------------------------------------------
// Presentation pipelines (scene -> preview targets / swapchain blits)
// ---------------------------------------------------------------------------

SDL_GPUShader* load_blit_shader(SDL_GPUDevice* dev, const char* path, const char* entry,
                                SDL_GPUShaderStage stage, Uint32 samplers) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return nullptr;
    std::stringstream ss;
    ss << f.rdbuf();
    const std::string code = ss.str();
    SDL_GPUShaderCreateInfo ci{};
    ci.stage = stage;
    ci.format = SDL_GPU_SHADERFORMAT_MSL;
    ci.code = reinterpret_cast<const Uint8*>(code.data());
    ci.code_size = code.size();
    ci.entrypoint = entry;
    ci.num_samplers = samplers;
    return SDL_CreateGPUShader(dev, &ci);
}

struct Present_Pipes {
    SDL_GPUGraphicsPipeline* preview = nullptr; // R8G8B8A8 preview targets
    SDL_GPUGraphicsPipeline* swap = nullptr;    // swapchain-format twin for the final blit
    SDL_GPUSampler* sampler = nullptr;

    void release(SDL_GPUDevice* gpu) {
        if (preview) SDL_ReleaseGPUGraphicsPipeline(gpu, preview);
        if (swap) SDL_ReleaseGPUGraphicsPipeline(gpu, swap);
        if (sampler) SDL_ReleaseGPUSampler(gpu, sampler);
        preview = swap = nullptr;
        sampler = nullptr;
    }
};

// Loads the baked blit shaders (src/generated/blit.{vert,frag}.msl) and builds
// the two blit pipelines. The shaders are released once the pipelines exist.
bool create_present_pipes(gfx::Gfx& gfx, Present_Pipes& out) {
    SDL_GPUShader* vs = load_blit_shader(gfx.gpu, "src/generated/blit.vert.msl", "vertMain",
                                         SDL_GPU_SHADERSTAGE_VERTEX, 0);
    SDL_GPUShader* fs = load_blit_shader(gfx.gpu, "src/generated/blit.frag.msl", "pixelMain",
                                         SDL_GPU_SHADERSTAGE_FRAGMENT, 1);
    if (!vs || !fs) {
        if (vs) SDL_ReleaseGPUShader(gfx.gpu, vs);
        if (fs) SDL_ReleaseGPUShader(gfx.gpu, fs);
        return false;
    }
    SDL_GPUColorTargetDescription tgt{};
    // Preview targets are R8G8B8A8_UNORM (scene_runtime.cpp); a swapchain-format
    // pipeline here mismatched and Metal aborted the encoder mid-frame
    // ("uncommitted encoder" crash).
    tgt.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    SDL_GPUGraphicsPipelineCreateInfo pci{};
    pci.vertex_shader = vs;
    pci.fragment_shader = fs;
    pci.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    pci.target_info.num_color_targets = 1;
    pci.target_info.color_target_descriptions = &tgt;
    out.preview = SDL_CreateGPUGraphicsPipeline(gfx.gpu, &pci);
    if (!out.preview) std::fprintf(stderr, "preview pipe failed: %s\n", SDL_GetError());
    tgt.format = gfx.swapchain_format;
    out.swap = SDL_CreateGPUGraphicsPipeline(gfx.gpu, &pci);
    if (!out.swap) std::fprintf(stderr, "swap pipe failed: %s\n", SDL_GetError());
    SDL_ReleaseGPUShader(gfx.gpu, vs);
    SDL_ReleaseGPUShader(gfx.gpu, fs);

    SDL_GPUSamplerCreateInfo sci{};
    sci.min_filter = SDL_GPU_FILTER_LINEAR;
    sci.mag_filter = SDL_GPU_FILTER_LINEAR;
    sci.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sci.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sci.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    out.sampler = SDL_CreateGPUSampler(gfx.gpu, &sci);
    return true;
}

// Present: blit scene -> swapchain in its own command buffer, AFTER the scene
// submission (SDL executes submissions in order). One acquire per tick;
// gfx_end_frame submits unconditionally, so the buffer is released even when
// no drawable was available. Returns whether a drawable was drawn into.
bool present_frame(gfx::Gfx& gfx, SDL_Window* window, const scene::Render_Targets& targets,
                   const Present_Pipes& pipes, int pw, int ph) {
    gfx::gfx_begin_frame(gfx, window);
    const bool drawn = gfx.swapchain != nullptr;
    if (drawn) {
        SDL_GPUColorTargetInfo bt{};
        bt.texture = gfx.swapchain;
        bt.load_op = SDL_GPU_LOADOP_CLEAR;
        bt.store_op = SDL_GPU_STOREOP_STORE;
        bt.clear_color = SDL_FColor{0, 0, 0, 1};
        SDL_GPURenderPass* rp = SDL_BeginGPURenderPass(gfx.command_buffer, &bt, 1, nullptr);
        SDL_BindGPUGraphicsPipeline(rp, pipes.swap);
        SDL_GPUTextureSamplerBinding bind{targets.scene, pipes.sampler};
        SDL_BindGPUFragmentSamplers(rp, 0, &bind, 1);
        SDL_GPUViewport viewport{0, 0, float(pw), float(ph), 0.f, 1.f};
        SDL_SetGPUViewport(rp, &viewport);
        SDL_DrawGPUPrimitives(rp, 3, 1, 0, 0);
        SDL_EndGPURenderPass(rp);
    }
    gfx::gfx_end_frame(gfx);
    return drawn;
}

// Pass count the targets are sized for.
int pass_count_of(const scene::Scene_Manager& manager) {
    return int(manager.scenes[size_t(manager.current)].passes.size());
}

// pw/ph = the SDL window's drawable size (the actual preview surface, in
// every mode).
void resize_targets(gfx::Gfx& gfx, const scene::Scene_Manager& manager,
                    scene::Render_Targets& targets, scene::Scene_Resources& resources, int pw,
                    int ph) {
    if (pw <= 0 || ph <= 0) return; // layout not settled yet
    if (!scene::targets_resize(targets, gfx.gpu, pw, ph, pass_count_of(manager)))
        std::fprintf(stderr, "targets_resize %dx%d failed: %s\n", pw, ph, SDL_GetError());
    resources.depth_tex = targets.depth;
    resources.pass_tex = targets.passes;
}

// Coalesces tick-driven resizes: PiP drags animate the frame every frame, so
// resizes are skipped while a gesture is live (the mouse-up branch clears the
// flags and the next tick resizes once) and limited to one per 100 ms.
struct Resize_Throttle {
    QElapsedTimer clock;
    qint64 last_ns = 0;
    Resize_Throttle() { clock.start(); }
    bool take() {
        const qint64 now = clock.nsecsElapsed();
        if (now - last_ns <= kResizeCoalesceNs) return false;
        last_ns = now;
        return true;
    }
};

// Startup reveal: the window comes up invisible (fullscreen transition, stale
// SDL drawable, editor still empty) and fades in once the drawable matches the
// viewport. ~3 s fallback so a mismatch can never hide the app.
void update_startup_reveal(int& reveal_frames, shell::Shell& shell, const Preview_Window& win,
                           const scene::Render_Targets& targets, int pw, int ph, int pass_count) {
    if (reveal_frames < 0 || ++reveal_frames <= kRevealMinFrames) return;
    QWidget* vp = shell.viewport();
    const double dpr = vp->devicePixelRatioF();
    const bool settled = std::abs(pw - int(vp->width() * dpr)) <= 2 &&
                         std::abs(ph - int(vp->height() * dpr)) <= 2 &&
                         !scene::targets_needs_resize(targets, pw, ph, pass_count);
    if (settled || reveal_frames > kRevealMaxFrames) {
        shell.setWindowOpacity(1.0);
        [win.sdl_ns setAlphaValue:1.0];
        reveal_frames = -1;
    }
}

// ---------------------------------------------------------------------------
// Per-frame viewport sync (editor_page / SPLIT / FULL / FLOAT)
// ---------------------------------------------------------------------------

// plan8 viewport header: WHAT is rendering, at WHICH resolution, and the
// render state (compiling / paused / error). One caption, no extra chrome;
// FPS omitted (no reliable per-frame GPU timing in this host — inventing a
// number is worse than none).
QString viewport_caption(const scene::Scene_Manager& mgr, const scene::Render_Targets& tg,
                         bool baking_now, bool paused_now) {
    if (mgr.scenes.empty()) return {};
    const auto& sc = mgr.scenes[size_t(mgr.current)];
    // Output = the pass feeding show2d (plan.output_pass), or the entry pass
    // in the default chain. Black render + valid plan = honest black content,
    // never "uninitialized".
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
        text += QString(" · ERROR: %1").arg(QString::fromStdString(sc.pipeline_error));
    else if (baking_now)
        text += " · compiling";
    else if (paused_now)
        text += " · paused";
    return text;
}

struct Layout_State {
    bool preview_applied = false;
    bool sdl_shown = true;
    // Graph fullscreen hides central_ (the SDL parent rect goes stale): the
    // native window is parked instead of left over the graph.
    bool graph_fs_hidden = false;
};

void set_frame_if_changed(NSWindow* w, NSRect want) {
    if (!NSEqualRects(want, [w frame])) [w setFrame:want display:YES];
}

// The preview lives INSIDE the viewport rect (vp = sdl_host_: excludes
// topbar/strip/side panel), converted to screen — so the panel and the
// editor's tab row stay clickable, and the PiP never covers the files tree.
void layout_split(shell::Shell& shell, const Preview_Window& win, const scene::Scene_Manager& manager,
                  const scene::Render_Targets& targets, bool baking, NSRect vp_win) {
    CGFloat left_w = NSWidth(vp_win) * shell.ui.split_left;
    NSRect want = NSMakeRect(NSMinX(vp_win) + left_w, NSMinY(vp_win), NSWidth(vp_win) - left_w,
                             NSHeight(vp_win));
    set_frame_if_changed(win.sdl_ns, want);
    g_pip_rect = NSZeroRect; // split owns the rect; drag off state
    const QRect qt_frame = qt_rect_from_cocoa(want);
    shell.set_pip_overlay(viewport_caption(manager, targets, baking, shell.ui.paused),
                          qt_frame); // caption anchors ON the preview frame
    shell.set_preview_frame_rect(qt_frame);
}

// FULL dock: the whole editor space (below the tab row).
void layout_full(shell::Shell& shell, const Preview_Window& win, NSRect vp_win) {
    set_frame_if_changed(win.sdl_ns,
                         NSMakeRect(NSMinX(vp_win), NSMinY(vp_win), NSWidth(vp_win),
                                    NSHeight(vp_win) - kTabRowH));
    g_pip_rect = NSZeroRect;
    shell.set_pip_overlay(QString(), QRect());
    shell.set_preview_frame_rect(QRect()); // no frame: it IS the space
}

// FLOAT: the USER's rect (drag/resize monitor) once set — FREE to move
// anywhere, including over the sidebar or partly off-window. Default anchored
// top-right only when never set. While a drag aims at a zone, the shell paints
// the dashed target (set_snap_hover).
void layout_float(shell::Shell& shell, const Preview_Window& win,
                  const scene::Scene_Manager& manager, const scene::Render_Targets& targets,
                  bool baking, NSRect vp_win) {
    if (NSIsEmptyRect(g_pip_rect)) {
        // Anchored to the viewport's top-right, top kTabRowH below the visual
        // top (below the tab row): Cocoa origin.y = vpMaxY - kTabRowH - h.
        CGFloat w = NSWidth(vp_win) * 0.40;
        CGFloat h = NSHeight(vp_win) * 0.55 - kTabRowH;
        g_pip_rect = NSMakeRect(NSMaxX(vp_win) - w - 12, NSMaxY(vp_win) - kTabRowH - h, w, h);
    }
    // Keyboard geometry: consume arrow nudges the shell queued via
    // Cmd+arrows. Qt y is top-down, Cocoa y is bottom-up, so the dy sign flips.
    if (shell.ui.preview_nudge != QPoint(0, 0)) {
        g_pip_rect.origin.x += shell.ui.preview_nudge.x();
        g_pip_rect.origin.y -= shell.ui.preview_nudge.y();
        shell.ui.preview_nudge = QPoint(0, 0);
        pip_save_prefs();
    }
    set_frame_if_changed(win.sdl_ns, g_pip_rect);
    // plan8 caption: anchored to the PiP frame itself (the preview surface),
    // never parked over the file selector.
    const QRect qt_pip = qt_rect_from_cocoa(g_pip_rect);
    shell.set_pip_overlay(viewport_caption(manager, targets, baking, shell.ui.paused), qt_pip);
    shell.set_preview_frame_rect(qt_pip);
}

// The SDL child window either fills the viewport (scene view) or shrinks to a
// floating preview frame (code editor up) — the editor needs the shader
// visible while editing. sync_child is skipped while the preview frame owns
// the rect: a per-tick flip-flop between the two rects starves the UI with
// resizes. The SDL NSWindow is a child window: a stack page switch does not
// hide it, so it is hidden here when the viewport is.
// CORE LAYOUT: the editor is ALWAYS the center page; the scene preview floats
// as the PiP frame over it in every mode.
void sync_viewport_layout(shell::Shell& shell, const Preview_Window& win,
                          const scene::Scene_Manager& manager,
                          const scene::Render_Targets& targets, bool baking, Layout_State& st) {
    const bool editor_page = !shell.ui.fullscreen_view;
    if (const bool gfs = shell.ui.graph_fullscreen &&
                         shell.ui.mode == shell::Sidebar_Mode::GRAPH && shell.ui.panel_open;
        gfs != st.graph_fs_hidden) {
        if (gfs) {
            SDL_HideWindow(win.sdl);
        } else {
            win.sync_child();
            SDL_ShowWindow(win.sdl);
        }
        st.graph_fs_hidden = gfs;
    }
    if (editor_page && !st.graph_fs_hidden) {
        const NSRect vp_win = win.viewport_screen_rect();
        if (shell.ui.preview == shell::Preview_Mode::SPLIT)
            layout_split(shell, win, manager, targets, baking, vp_win);
        else if (shell.ui.preview == shell::Preview_Mode::FULL)
            layout_full(shell, win, vp_win);
        else
            layout_float(shell, win, manager, targets, baking, vp_win);
        st.preview_applied = true;
        return;
    }
    shell.set_pip_overlay(QString(), QRect()); // fullscreen: no PiP label
    shell.set_preview_frame_rect(QRect());     // no docked-frame overlays
    if (st.preview_applied) { // leaving the editor: full viewport again
        st.preview_applied = false;
        win.sync_child();
    }
    if (bool on = shell.viewport()->isVisible(); on != st.sdl_shown) {
        if (on) {
            win.sync_child();
            SDL_ShowWindow(win.sdl);
        } else {
            SDL_HideWindow(win.sdl);
        }
        st.sdl_shown = on;
    } else {
        win.sync_child(); // keep the child glued to the viewport
    }
}

// Mouse in device pixels of the SDL window (the render surface). When the
// pointer leaves the frame, park iMousePos at the last in-frame value (scenes
// like 03_mouse keep sampling, not jumping).
QPoint read_mouse(const Preview_Window& win, QWidget* vp, QPoint& last_mouse) {
    const NSPoint sp = [NSEvent mouseLocation]; // bottom-left origin
    const NSRect wf = [win.sdl_ns frame];
    const CGFloat sx = sp.x - NSMinX(wf), sy = sp.y - NSMinY(wf);
    if (sx >= 0 && sy >= 0 && sx <= NSWidth(wf) && sy <= NSHeight(wf)) {
        const CGFloat dpr = vp->devicePixelRatioF();
        last_mouse = QPoint(int(sx * dpr), int((NSHeight(wf) - sy) * dpr));
    }
    return last_mouse;
}

// ---------------------------------------------------------------------------
// Readbacks: PNG, probes, node previews, GIF
// ---------------------------------------------------------------------------

// Blocking scene-target readback -> PNG. Shared by the export button and the
// --shot CLI flag (identical path, one implementation).
bool save_scene_png(gfx::Gfx& gfx, const scene::Render_Targets& targets, const QString& out) {
    gfx::Staging st = gfx::uploader_download_texture_region_begin(
        gfx.uploader, targets.scene, 0, 0, uint32_t(targets.w), uint32_t(targets.h));
    if (!st.buffer) return false; // transfer buffer allocation failed
    // download_end already submitted and fenced the copy (owns_pass); wait
    // by polling the fence, NOT uploader_flush_blocking (the copy pass is
    // closed — flushing again SEGVs in METAL_WaitForFences).
    while (!gfx::staging_ready(gfx.uploader, st)) {}
    QImage img(gfx::staging_read(st), targets.w, targets.h, QImage::Format_RGBA8888);
    const bool ok = img.save(out);
    gfx::staging_release(gfx.uploader, st);
    return ok;
}

// Pixel provenance (stage 8) + CLI probes. A fresh click inside the VIEWPORT
// starts a 1x1 readback of the scene target (polled on later ticks). The gate
// is the SDL host visibility: on the editor/graph pages the SDL window shrinks
// to the PiP frame (or hides) — clicks there are editor clicks, not scene clicks.
struct Probe_State {
    inspect::Provenance_Readback readback;
    bool pending = false;
    int click_x = 0, click_y = 0;
    bool prev_click = false;
};

// --pixel-test: after the settle frames, sample the CLI-provided pixel (no
// click needed), print to stdout and quit. The click gate does not apply:
// this is headless intent. --shot PATH: after the same settle window, save the
// scene target as PNG (shared export path) and quit — repeatable rendered-output
// evidence for camera/resize regressions. Returns true when it requested quit.
bool run_probes(Probe_State& ps, const Cli_Options& cli, int frames, gfx::Gfx& gfx,
                const scene::Render_Targets& targets, int pw, int ph, QPoint mp, bool click,
                bool scene_visible) {
    if (cli.shot_path && frames == kProbeSettleFrames) {
        QDir().mkpath(QFileInfo(QString::fromUtf8(cli.shot_path)).absolutePath());
        bool ok = save_scene_png(gfx, targets, QString::fromUtf8(cli.shot_path));
        std::printf("shot %s: %s\n", cli.shot_path, ok ? "ok" : "save failed");
        std::fflush(stdout);
        QApplication::quit();
        return true;
    }
    if (cli.pixel_test && frames == kProbeSettleFrames && !ps.pending) {
        if (cli.pixel_x < pw && cli.pixel_y < ph &&
            ps.readback.begin(gfx.uploader, targets.scene, cli.pixel_x, cli.pixel_y)) {
            ps.pending = true;
            ps.click_x = cli.pixel_x;
            ps.click_y = cli.pixel_y;
        }
    }
    if (cli.pixel_test && frames > kProbeSettleFrames + 5 && !ps.pending) {
        // begin() kept failing (probe outside the target): fail loud, nonzero exit for CI.
        std::printf("pixel %d %d: ERROR begin failed\n", cli.pixel_x, cli.pixel_y);
        std::fflush(stdout);
        QApplication::exit(1);
    }
    if (scene_visible && click && !ps.prev_click && mp.x() >= 0 && mp.y() >= 0 && mp.x() < pw &&
        mp.y() < ph && ps.readback.begin(gfx.uploader, targets.scene, mp.x(), mp.y())) {
        ps.click_x = mp.x();
        ps.click_y = mp.y();
        ps.pending = true;
    }
    ps.prev_click = click;

    // Poll the provenance readback (fence submitted on begin; resolves a
    // tick later): toast the sampled rgba at the click point.
    if (!ps.pending) return false;
    inspect::Provenance_Readback::Result r;
    if (!ps.readback.poll(gfx.uploader, r)) return false;
    ps.pending = false;
    if (!r.valid) return false;
    if (cli.pixel_test) {
        // M5: machine-readable stdout for regression diffs.
        std::printf("pixel %d %d: r=%.3f g=%.3f b=%.3f a=%.3f\n", cli.pixel_x, cli.pixel_y,
                    r.rgba[0], r.rgba[1], r.rgba[2], r.rgba[3]);
        std::fflush(stdout);
        QApplication::quit();
        return true;
    }
    notify::notify(notify::Kind::INFO, QString("pixel (%1,%2): r=%3 g=%4 b=%5 a=%6")
                                           .arg(ps.click_x)
                                           .arg(ps.click_y)
                                           .arg(r.rgba[0], 0, 'f', 3)
                                           .arg(r.rgba[1], 0, 'f', 3)
                                           .arg(r.rgba[2], 0, 'f', 3)
                                           .arg(r.rgba[3], 0, 'f', 3));
    return false;
}

// Node previews: 1x/second, read back every 128px target (pass outputs +
// final) into QImages for the graph canvas. The uploader fence from
// download_end resolves next tick (async). The LAST preview image is the
// final frame; its average hue tints the chrome so the UI breathes with the
// shader (live safelight).
struct Preview_Feed {
    int tick_n = 0;
    QVector<QImage> images;
    std::vector<gfx::Staging> readbacks;

    // CPU mean over a 2x-subsampled image (16k pixels at 128px, 1x/second).
    static QColor average_tint(const QImage& img) {
        qint64 r = 0, g = 0, b = 0;
        for (int y = 0; y < img.height(); y += 2) {
            const QRgb* row = reinterpret_cast<const QRgb*>(img.constScanLine(y));
            for (int x = 0; x < img.width(); x += 2) {
                r += qRed(row[x]);
                g += qGreen(row[x]);
                b += qBlue(row[x]);
            }
        }
        const int samples = ((img.width() + 1) / 2) * ((img.height() + 1) / 2);
        if (samples <= 0) return {};
        return QColor(int(r / samples), int(g / samples), int(b / samples));
    }

    // Converts last second's finished batch to images; false while still in flight.
    bool collect(gfx::Gfx& gfx, int pw, int ph) {
        for (auto& st : readbacks)
            if (!gfx::staging_ready(gfx.uploader, st)) return false;
        images.clear();
        for (auto& st : readbacks) {
            QImage img(gfx::staging_read(st), scene::PREVIEW_SIZE, scene::PREVIEW_SIZE,
                       QImage::Format_RGBA8888);
            // PREVIEW_SIZE target is square (GPU downscale squashes the
            // scene): restore the viewport aspect for the UI.
            const double a = double(pw) / double(std::max(ph, 1));
            images.push_back(img.scaled(a >= 1.0 ? scene::PREVIEW_SIZE : int(scene::PREVIEW_SIZE * a),
                                        a >= 1.0 ? int(scene::PREVIEW_SIZE / a) : scene::PREVIEW_SIZE,
                                        Qt::IgnoreAspectRatio, Qt::SmoothTransformation));
            gfx::staging_release(gfx.uploader, st);
        }
        readbacks.clear();
        return true;
    }

    void tick(gfx::Gfx& gfx, const scene::Render_Targets& targets, int pw, int ph,
              shell::Shell& shell) {
        if (++tick_n < kPreviewPeriodTicks) return;
        tick_n = 0;
        if (!readbacks.empty() && collect(gfx, pw, ph)) {
            if (shell.graph_panel_visible()) shell.graph_view_typed()->set_previews(images);
            if (!images.isEmpty()) {
                const QColor tint = average_tint(images.back());
                if (tint.isValid()) shell.set_live_tint(tint);
            }
        }
        if (readbacks.empty()) { // graph canvas + live tint feed
            for (SDL_GPUTexture* tex : targets.previews) {
                readbacks.push_back(gfx::uploader_download_texture_region_begin(
                    gfx.uploader, tex, 0, 0, scene::PREVIEW_SIZE, scene::PREVIEW_SIZE));
                if (!readbacks.back().buffer) readbacks.pop_back(); // allocation failed: skip this target
            }
        }
    }

    void release(gfx::Gfx& gfx) {
        for (auto& st : readbacks) gfx::staging_release(gfx.uploader, st);
        readbacks.clear();
    }
};

// GIF capture (host-driven): one PNG of the scene every 4th tick (~17 fps)
// while active; same blocking readback as PNG export. When the [start,end]
// window elapses, the ffmpeg assembly is kicked off in the background.
struct Gif_Capture {
    bool active = false;
    float end_s = 0.f;
    float started_s = 0.f;
    int frame_n = 0;
    int tick_n = 0;

    // Capture starts now; [start,end] is the Odin semantic.
    void request(float end) {
        active = true;
        end_s = end;
        QDir().mkpath("exports/gif_frames");
        for (const QString& f : QDir("exports/gif_frames").entryList({"frame_*.png"}))
            QFile::remove("exports/gif_frames/" + f);
        frame_n = 0;
    }

    void tick(gfx::Gfx& gfx, const scene::Render_Targets& targets, int pw, int ph, float t,
              const std::string& title) {
        if (!active) return;
        if (frame_n == 0) started_s = t;
        if (++tick_n % 4 != 0) return;
        gfx::Staging st = gfx::uploader_download_texture_region_begin(
            gfx.uploader, targets.scene, 0, 0, uint32_t(pw), uint32_t(ph));
        if (!st.buffer) return; // transfer buffer allocation failed: skip this frame
        // fenced submit in download_end: poll, don't re-flush (SEGV).
        while (!gfx::staging_ready(gfx.uploader, st)) {}
        QImage img(gfx::staging_read(st), pw, ph, QImage::Format_RGBA8888);
        img.save(QString("exports/gif_frames/frame_%1.png").arg(frame_n++, 4, 10, QChar('0')));
        gfx::staging_release(gfx.uploader, st);
        if (t - started_s >= end_s) {
            active = false;
            export_flow::assemble_gif("exports/gif_frames",
                                      QString("exports/%1.gif").arg(title.c_str()));
            notify::notify(notify::Kind::INFO, QString("gif: %1 frames assembling").arg(frame_n));
        }
    }
};

// ---------------------------------------------------------------------------
// Scene -> GPU resource binding (model / skybox / user textures + samplers)
// ---------------------------------------------------------------------------

// Host-owned caches: one GPU object per path, released at shutdown. Models
// are picked per scene; user textures/samplers come from graph-routed uimg
// nodes. Failures report once (toast) and stay absent — the bind falls
// through to black/default.
struct Scene_Binding {
    using Sampler_Spec = std::pair<std::string, std::string>; // filter, address

    struct User_Sampler {
        SDL_GPUSampler* sampler = nullptr; // null = creation failed, keep default
        Sampler_Spec spec;
    };

    gfx::Gfx& gfx;
    scene::Scene_Resources& resources;
    assets::Assets& shared;
    std::map<std::string, assets::Model> uobj_models; // uploaded once per glb path
    std::map<std::string, gfx::Texture_Handle> user_tex_handles;
    std::map<std::string, User_Sampler> user_samplers;
    std::set<std::string> user_tex_reported;
    std::set<std::string> target_read_reported;
    uint32_t debug_watch_size = 0;

    // Plan 07: the active scene's mesh nodes drive geometry. Two sources:
    // 1. uobj routes (scene.pass_model_paths): each MODEL route names a glb —
    //    per-pass buffers (graph inputs decide which model each pass draws).
    // 2. Fallback: scene.model basename or GIS_MODEL -> default buffers.
    void pick_model(const scene::Runtime_Scene& sc) {
        resources.pass_model_vb.clear();
        resources.pass_model_ib.clear();
        resources.pass_model_base_color.clear();
        resources.pass_model_base_sampler.clear();
        resources.pass_model_index_count.clear();
        resources.pass_model_double_sided.clear();
        bind_pass_models(sc);
        bind_default_model(sc);
    }

    void bind_pass_models(const scene::Runtime_Scene& sc) {
        for (const auto& [pass_index, path] : sc.pass_model_paths) {
            auto it = uobj_models.find(path);
            if (it == uobj_models.end()) {
                assets::Model m;
                if (!assets::load_gltf(gfx, path, m)) {
                    notify::notify(notify::Kind::WARN,
                                   QString("asset not found: %1").arg(QString::fromStdString(path)));
                    continue;
                }
                std::fprintf(stderr, "uobj: loaded %s (%u idx)\n", path.c_str(), m.index_count);
                it = uobj_models.emplace(path, std::move(m)).first;
            }
            const assets::Model& m = it->second;
            const size_t pi = size_t(pass_index);
            resources.pass_model_vb[pi] = m.vb;
            resources.pass_model_ib[pi] = m.ib;
            resources.pass_model_index_count[pi] = m.index_count;
            resources.pass_model_base_color[pi] = m.base_color_texture;
            resources.pass_model_base_sampler[pi] = m.texture_sampler;
            resources.pass_model_double_sided[pi] = m.double_sided;
        }
    }

    // scene.model (graph.json "model") picks by basename; GIS_MODEL overrides
    // for screenshots. Default = first entry.
    void bind_default_model(const scene::Runtime_Scene& sc) {
        const QByteArray env = qgetenv("GIS_MODEL");
        const std::string want = !env.isEmpty() ? std::string(env.constData()) : sc.model;
        const assets::Model* picked = shared.models.empty() ? nullptr : &shared.models[0];
        if (!want.empty()) {
            for (const assets::Model& m : shared.models) {
                if (m.name == want) {
                    picked = &m;
                    break;
                }
            }
            if (picked && picked->name != want)
                std::fprintf(stderr, "model '%s' not found, using '%s'\n", want.c_str(),
                             picked->name.c_str());
        }
        if (!picked) return;
        resources.model_vb = picked->vb;
        resources.model_ib = picked->ib;
        resources.model_index_count = picked->index_count;
        resources.model_base_color_texture = picked->base_color_texture;
        resources.model_base_color_sampler = picked->texture_sampler;
        resources.model_double_sided = picked->double_sided;
    }

    // GIS_SKYBOX=<name> picks from assets/skybox by basename ("night" ->
    // skybox-night.png). Unset = null (paper-clear background).
    void pick_skybox() {
        const QByteArray want = qgetenv("GIS_SKYBOX");
        if (want.isEmpty()) return;
        for (size_t i = 0; i < shared.skybox_names.size(); ++i) {
            if (shared.skybox_names[i] != want.constData()) continue;
            resources.skybox_texture = gfx::gfx_texture_get(gfx, shared.skybox_textures[i])->handle;
            std::fprintf(stderr, "skybox: %s\n", shared.skybox_names[i].c_str());
            return;
        }
    }

    // The watch buffer is sized for the scene's pass count: recreate when the
    // size changes (hot rebuild / scene switch), drop it when no watches remain.
    void refresh_debug_watch(const scene::Runtime_Scene& sc) {
        const uint32_t size = scene::scene_has_debug_watches(sc)
                                  ? uint32_t(scene::DEBUG_WATCH_COUNT * 32 * int(sc.passes.size() + 1))
                                  : 0;
        if (size == debug_watch_size) return;
        if (resources.debug_watch_buffer) {
            SDL_ReleaseGPUBuffer(gfx.gpu, resources.debug_watch_buffer);
            resources.debug_watch_buffer = nullptr;
        }
        debug_watch_size = size;
        if (size == 0) return;
        SDL_GPUBufferCreateInfo bci{};
        bci.usage = SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ | SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE;
        bci.size = size;
        resources.debug_watch_buffer = SDL_CreateGPUBuffer(gfx.gpu, &bci);
    }

    void ensure_user_texture(const std::string& path) {
        if (user_tex_handles.count(path)) return;
        bool ok = false;
        gfx::Texture_Handle h = assets::load_texture(gfx, path, ok);
        if (ok) {
            user_tex_handles[path] = h;
            resources.user_textures[path] = gfx::gfx_texture_get(gfx, h)->handle;
        } else if (user_tex_reported.insert(path).second) {
            notify::notify(notify::Kind::WARN,
                           QString("asset not found: %1").arg(QString::fromStdString(path)));
        }
    }

    // Recreated when the owning texture node's filter/address changes.
    void ensure_user_sampler(const std::string& path, const Sampler_Spec& spec) {
        auto it = user_samplers.find(path);
        if (it != user_samplers.end() && it->second.spec == spec) return;
        SDL_GPUSamplerCreateInfo sci{};
        sci.min_filter = sci.mag_filter =
            spec.first == "point" ? SDL_GPU_FILTER_NEAREST : SDL_GPU_FILTER_LINEAR;
        sci.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        SDL_GPUSamplerAddressMode mode = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        if (spec.second == "repeat")
            mode = SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
        else if (spec.second == "mirror")
            mode = SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT;
        sci.address_mode_u = sci.address_mode_v = sci.address_mode_w = mode;
        sci.max_lod = 1000.f; // match load-site samplers
        SDL_GPUSampler* s = SDL_CreateGPUSampler(gfx.gpu, &sci);
        if (it != user_samplers.end() && it->second.sampler)
            SDL_ReleaseGPUSampler(gfx.gpu, it->second.sampler);
        user_samplers[path] = {s, spec};
        resources.user_samplers[path] = s; // null = keep default
    }

    // Graph-routed texture/sampler resources (uimg nodes); cheap per tick
    // (map lookups only, everything cached after first load).
    void apply_resource_routes(const scene::Runtime_Scene& sc) {
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
                ensure_user_texture(r.path);
            } else if (r.kind == render_graph::Resource_Kind::SAMPLER) {
                // The route's path is the image file; the OWNING texture node
                // ("uimg:<path>:texture") carries filter/address.
                Sampler_Spec spec{"linear", "clamp"};
                if (auto it = sc.node_sampler_settings.find("uimg:" + r.path + ":texture");
                    it != sc.node_sampler_settings.end())
                    spec = it->second;
                ensure_user_sampler(r.path, spec);
            }
        }
    }

    void release() {
        for (auto& [path, m] : uobj_models) assets::model_release(gfx, m);
        uobj_models.clear();
        for (auto& [path, h] : user_tex_handles) gfx::gfx_texture_destroy(gfx, h);
        user_tex_handles.clear();
        for (auto& [path, u] : user_samplers)
            if (u.sampler) SDL_ReleaseGPUSampler(gfx.gpu, u.sampler);
        user_samplers.clear();
        if (resources.debug_watch_buffer) SDL_ReleaseGPUBuffer(gfx.gpu, resources.debug_watch_buffer);
        resources.debug_watch_buffer = nullptr;
        debug_watch_size = 0;
    }
};

} // namespace

int main(int argc, char** argv) {
    // C locale for BOTH Qt (QLocale below) and the C runtime: --pixel-test
    // prints '.'-decimal to stdout for diffing; the system locale (pt_BR)
    // would render "0,141" and break numeric comparison.
    std::setlocale(LC_ALL, "C");
    QApplication app(argc, argv);
    // Uniforms are '.'-decimal; the system locale renders spinboxes as "0,25"
    // and then rejects round-trip typed input.
    QLocale::setDefault(QLocale::c());
    // QApplication's ctor calls setlocale(LC_ALL, "") on macOS; re-assert "C"
    // AFTER it, or --pixel-test's stdout is pt_BR "0,141" instead of "0.141".
    std::setlocale(LC_ALL, "C");
    // Qlementine owns the whole UI look: one dark theme JSON + matching icons.
    auto* style = new oclero::qlementine::QlementineStyle(&app);
    style->setThemeJsonPath(":/qlementine/resources/themes/dark.json");
    app.setStyle(style);
    theme::load_fonts();
    theme::apply_palette(app, style); // theme:: owns the runtime-switch handle
    QIcon::setThemeName("qlementine");
    if (!chdir_repo_root()) {
        std::fprintf(stderr, "repo root not found (no src/shaders/scenes up from cwd/app dir)\n");
        return 1;
    }

    Instance_Lock lock;
    if (!lock.acquire()) return 1;
    const Cli_Options cli = parse_cli(argc, argv);
    if (!init_sdl()) return 1;

    // Stub scenes first (lazy load, like the Odin app), then load only the
    // active one once GPU + window exist.
    std::map<std::string, std::string> scene_roots;
    const auto names = scene::scene_names_on_disk(scene_roots);
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
    const auto it = std::find(names.begin(), names.end(), cli.scene);
    if (it == names.end()) {
        std::fprintf(stderr, "scene %s not found. Available:\n", cli.scene);
        for (const auto& n : names) std::fprintf(stderr, "  %s\n", n.c_str());
        return 1;
    }
    manager.current = int(it - names.begin());

    shell::Shell shell(nullptr, manager, scene_roots);
    setup_shell_window(shell);
    Preview_Window win;
    if (!attach_sdl_child(shell, win)) return 1;

    gfx::Gfx gfx;
    if (!gfx::gfx_create(gfx, win.sdl, shell.viewport()->width(), shell.viewport()->height())) {
        std::fprintf(stderr, "gfx create failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(win.sdl);
        return 1;
    }
    Event_Monitors monitors;
    monitors.pip = install_pip_monitor(shell, win);
    monitors.cam = install_camera_monitor(shell, manager, win);

    // Offscreen targets + resources; resize updates depth/pass texture refs.
    // Odin frame.odin re-checks targets every frame: the first pass runs
    // before Qt layout settles, so a load-time resize alone leaves the scene
    // texture at a stale (tiny) size — the gradient renders squeezed into a
    // narrow band.
    scene::Render_Targets targets;
    scene::Scene_Resources resources;
    Present_Pipes pipes;
    if (!create_present_pipes(gfx, pipes)) {
        std::fprintf(stderr, "blit shaders missing (run: make shaders)\n");
        return 1;
    }
    resources.sampler = pipes.sampler;
    // Shared assets: paper/skybox textures, model library, black fallback.
    assets::Assets shared;
    if (!assets::load(shared, gfx)) {
        std::fprintf(stderr, "asset load failed (paper textures/models required)\n");
        return 1;
    }
    resources.paper_texture = gfx::gfx_texture_get(gfx, shared.paper_textures[0])->handle;
    resources.black_texture = gfx::gfx_texture_get(gfx, shared.black_texture)->handle;
    resources.white_texture = gfx::gfx_texture_get(gfx, shared.white_texture)->handle;
    Scene_Binding binding{gfx, resources, shared};
    binding.pick_skybox();

    // Shared by init, scene switch and the hot-rebuild path: everything that
    // depends on the active scene's pass count / model routes.
    auto apply_scene_change = [&](const scene::Runtime_Scene& sc) {
        binding.pick_model(sc);
        int sw = 0, sh = 0;
        SDL_GetWindowSizeInPixels(win.sdl, &sw, &sh);
        resize_targets(gfx, manager, targets, resources, sw, sh);
        binding.refresh_debug_watch(sc);
    };

    scene::Build_State build;
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
        QDirIterator di(dir, {"*.slang", "graph.json"}, QDir::Files);
        while (di.hasNext()) watcher.addPath(di.next());
    };
    auto on_source_change = [&](const QString&) {
        watch_active(); // editors that save via rename drop the watched path
        scene::scene_request_build(build, {manager.scenes[size_t(manager.current)].title});
    };
    QObject::connect(&watcher, &QFileSystemWatcher::directoryChanged, on_source_change);
    QObject::connect(&watcher, &QFileSystemWatcher::fileChanged, on_source_change);

    float t = 0;
    int frames = 0;
    auto init = [&]() -> bool {
        const std::string& title = manager.scenes[size_t(manager.current)].title;
        // Cold-start bake (Odin scene_ensure_loaded parity): scenes_build is
        // idempotent (goose skips fresh artifacts), so this is free when the
        // artifacts exist and compiles them when they don't — the watcher
        // alone never fires on a fresh clone.
        if (!scene::scenes_build({title}, scene_roots))
            std::fprintf(stderr, "scene %s failed to bake\n", title.c_str());
        scene::Runtime_Scene& sc = manager.scenes[size_t(manager.current)];
        if (!scene::scene_load_into(gfx.gpu, sc, title, scene_roots)) {
            std::fprintf(stderr, "scene %s failed to load: %s\n", title.c_str(),
                         sc.pipeline_error.c_str());
            return false;
        }
        apply_scene_change(sc);
        shell.scene_switched();
        return true;
    };

    Layout_State layout;
    Resize_Throttle throttle;
    Probe_State probes;
    Preview_Feed feed;
    Gif_Capture gif;
    int reveal_frames = 0;
    QPoint last_mouse(0, 0);

    auto tick = [&] {
        ++frames;
        if (frames % kLockTouchTicks == 0) lock.touch();
        // Apply finished goose-builds: worker writes artifacts, only this pump
        // creates GPU pipelines (must run on the main/GPU thread). A swapped-in
        // scene may carry new model routes / pass count.
        if (scene::scene_build_pump(build, manager, gfx.gpu, scene_roots))
            apply_scene_change(manager.scenes[size_t(manager.current)]);
        // A swapped-in plan may carry new resource routes.
        binding.apply_resource_routes(manager.scenes[size_t(manager.current)]);
        bool baking;
        {
            std::lock_guard<std::mutex> lock_guard(build.mu);
            baking = build.req || build.running;
        }
        shell.set_baking(baking);
        sync_viewport_layout(shell, win, manager, targets, baking, layout);

        scene::Runtime_Scene& sc = manager.scenes[size_t(manager.current)];
        // Render at the SDL window's drawable size: the child NSWindow IS the
        // preview surface in every mode (FULL page, SPLIT dock, FLOAT PiP), so
        // the final blit maps 1:1 and the camera aspect is always the visible
        // one (viewport-sized targets stretched it).
        int pw = 0, ph = 0;
        SDL_GetWindowSizeInPixels(win.sdl, &pw, &ph);
        if (pw <= 0 || ph <= 0) return; // layout not settled / hidden
        const int pass_count = int(sc.passes.size());
        if (!(g_pip_drag || g_pip_resize) &&
            scene::targets_needs_resize(targets, pw, ph, pass_count) && throttle.take())
            resize_targets(gfx, manager, targets, resources, pw, ph);
        update_startup_reveal(reveal_frames, shell, win, targets, pw, ph, pass_count);

        // Scene submission runs even when the swapchain has no drawable this
        // frame (occluded window): EVERY acquired command buffer must be
        // submitted, or Metal's in-flight semaphore starves and the next
        // SDL_AcquireGPUCommandBuffer blocks forever (one-window freeze).
        const QPoint mp = read_mouse(win, shell.viewport(), last_mouse);
        const bool click = QApplication::mouseButtons() & Qt::LeftButton;
        const camera::Uniforms cam =
            advance_camera(t, shell.ui.interaction, float(pw) / float(ph));
        scene::scene_write_uniforms(sc, float(pw), float(ph), t, shell.ui.color, float(mp.x()),
                                    float(mp.y()), click, cam);
        const bool scene_visible = shell.ui.mode != shell::Sidebar_Mode::FILES &&
                                   shell.ui.mode != shell::Sidebar_Mode::GRAPH;
        if (run_probes(probes, cli, frames, gfx, targets, pw, ph, mp, click, scene_visible))
            return;

        SDL_GPUFence* fence = scene::submit_scene_frame(gfx.gpu, sc, targets.scene, resources, pw,
                                                        ph, pipes.preview, pipes.sampler,
                                                        targets.previews);
        if (fence) SDL_ReleaseGPUFence(gfx.gpu, fence);
        feed.tick(gfx, targets, pw, ph, shell);
        gif.tick(gfx, targets, pw, ph, t, sc.title);
        if (present_frame(gfx, win.sdl, targets, pipes, pw, ph) && !shell.ui.paused)
            t += 1.0f / 60.0f;
    };

    // Scene switch: save the outgoing graph, lazy-load the target, rebuild UI.
    QObject::connect(&shell, &shell::Shell::scene_selected, [&](int i) {
        if (i < 0 || i >= int(manager.scenes.size()) || i == manager.current) return;
        shell.flush_graph_layout(); // save graph of the scene being left
        auto& slot = manager.scenes[size_t(i)];
        if (!slot.loaded && !scene::scene_load_into(gfx.gpu, slot, slot.title, scene_roots)) {
            notify::notify(notify::Kind::ERROR_,
                           QString("scene failed to load: %1").arg(slot.title.c_str()));
            return; // stay on the current scene
        }
        manager.current = i;
        apply_scene_change(slot);
        watch_active();
        shell.scene_switched();
    });
    // LEARN trail chip: switch to the named scene (same path as the selector;
    // the shell rebuilds its panels via scene_switched).
    QObject::connect(&shell, &shell::Shell::scene_open_requested, [&](const QString& title) {
        for (size_t i = 0; i < manager.scenes.size(); ++i) {
            if (manager.scenes[i].title != title.toStdString()) continue;
            emit shell.scene_selected(int(i));
            return;
        }
        notify::notify(notify::Kind::WARN, QString("scene not found: %1").arg(title));
    });
    QObject::connect(&shell, &shell::Shell::save_all_requested, [&] {
        scene::scene_request_build(build, {manager.scenes[size_t(manager.current)].title});
    });
    // Live multipass: a link edit on the graph canvas saves graph.json
    // IMMEDIATELY (the 10 s autosave made edits feel dead); the watcher sees
    // the file change and re-plans the scene this frame.
    if (shell.graph_view_typed()) {
        QObject::connect(shell.graph_view_typed(), &graph_editor::Node_View::pipeline_changed,
                         [&] { shell.flush_graph_layout(); });
    }
    QObject::connect(&shell, &shell::Shell::camera_reset_requested, [] { reset_camera(); });
    // PNG export: download the scene texture (device px), encode PNG via
    // QImage in exports/. Blocking readback — single frame, same cost class
    // as the pixel inspector.
    QObject::connect(&shell, &shell::Shell::png_export_requested, [&] {
        QDir().mkpath("exports");
        QString out = QString("exports/%1_%2.png")
                          .arg(manager.scenes[size_t(manager.current)].title.c_str())
                          .arg(QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss"));
        bool ok = save_scene_png(gfx, targets, out);
        notify::notify(ok ? notify::Kind::INFO : notify::Kind::ERROR_,
                       ok ? QString("png saved: %1").arg(out)
                          : QString("png export failed: %1").arg(out));
    });
    QObject::connect(&shell, &shell::Shell::gif_export_requested,
                     [&](float, float end_s) { gif.request(end_s); });
    // Qt popups over the viewport lose the mouse race to the SDL child window
    // (NSWindowAbove): hide the renderer while a popup is up.
    QObject::connect(&shell, &shell::Shell::popup_mouse_shield, [&](bool on) {
        if (on) SDL_HideWindow(win.sdl);
        else SDL_ShowWindow(win.sdl);
    });

    if (!init()) return 1;
    watch_active(); // scenes loaded now: watch the ACTUAL scene's files

    QTimer frame_timer;
    QObject::connect(&frame_timer, &QTimer::timeout, [&] {
        SDL_PumpEvents();
        tick();
    });
    frame_timer.start(kFrameMs);
    // Quit path: stop the frame loop BEFORE anything else — a tick during
    // teardown dereferences half-destroyed ObjC/Qt objects (ASan SEGV in
    // objc_msgSend via QTimer::timerEvent). Then flush the visible graph
    // (Shell also does its own aboutToQuit flush; this covers the SDL-side
    // state) and release every GPU object with the device idle.
    QObject::connect(qApp, &QCoreApplication::aboutToQuit, [&] {
        frame_timer.stop();
        monitors.remove();
        shell.flush_graph_layout();
        SDL_WaitForGPUIdle(gfx.gpu);
        feed.release(gfx);
        for (scene::Runtime_Scene& sc : manager.scenes) scene::scene_release(gfx.gpu, sc);
        binding.release();
        scene::targets_destroy(gfx.gpu, targets);
        pipes.release(gfx.gpu);
        assets::destroy(gfx, shared);
        SDL_ReleaseWindowFromGPUDevice(gfx.gpu, win.sdl);
        gfx::gfx_destroy(gfx);
        [win.qt_ns removeChildWindow:win.sdl_ns];
        SDL_DestroyWindow(win.sdl);
        win.sdl = nullptr;
    });
    return app.exec();
}
