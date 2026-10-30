// Stage 7: node graph editor over the render_graph model. QtNodes
// (paceholder/nodeeditor 3.0.9) canvas: nodes with reflection-derived pins,
// links validated by plan_build before accept (invalid keeps the last valid
// pipeline, the Odin contract), layout persisted to graph.json (atomic
// write), autosave on scene switch + a 600-frame tick, confirmation modal on
// producer-replacing edges.
#pragma once

#include <QDialog>
#include <QElapsedTimer>
#include <QGraphicsEllipseItem>
#include <QHash>
#include <QImage>
#include <QMap>
#include <QString>
#include <QToolButton>
#include <QPointer>
#include <QWidget>
#include <functional>
#include "QtNodes/internal/DataFlowGraphModel.hpp"
#include "QtNodes/internal/DataFlowGraphicsScene.hpp"
#include "QtNodes/internal/GraphicsView.hpp"
#include "QtNodes/internal/NodeDelegateModel.hpp"

#include <QGraphicsObject>
#include <cstring>

#include "gfx/scene_runtime.hpp"

class QHBoxLayout;
class QMenu;

namespace graph_editor {

// One node on the canvas: a pass (from reflection), settings, output (show2d),
// or a user resource. key matches graph.json semantics.
struct Graph_Node {
    QString key;
    QString kind; // settings|graphics|compute|output|texture|mesh|widget
    float x = 0, y = 0;
    // User-resource extras.
    QString file;
    QString model; // mesh nodes: assets/models basename ("stanford_dragon")
    QString filter; // point|linear
    QString address; // clamp|repeat|mirror
    int width = 0, height = 0;
    float value = 0;
};

struct Graph_Link {
    QString from; // "<key>:<pin>"
    QString to;
};

// Delegate node: kind-tagged node. Inputs are typed pins; uniform pins are
// wireless (never linked, marked by the animated rings). Validation happens
// in plan_build, not the type system (Odin parity).
class Scene_Delegate : public QtNodes::NodeDelegateModel {
public:
    enum class Pin_Type { Texture, Sampler, Model, Uniform };
    struct Pin {
        Pin_Type type;
        QString name; // Model pin name is always "ModelVertex"
    };

    Scene_Delegate(QString kind, QString key, bool want_preview);
    ~Scene_Delegate() override;
    // Caption = FILE NAME only: the comp:/gfx:<path> key stays as the
    // identity, the title shows just <file>.slang (the trailing part).
    QString caption() const override {
        QString file = key_;
        file.remove("comp:");
        file.remove("gfx:");
        // Resource nodes carry a pin suffix ("uimg:<path>:texture") — show
        // just the file basename.
        for (const char* suffix : {":texture", ":sampler", ":ModelVertex"})
            if (file.endsWith(QLatin1String(suffix)))
                file.chop(int(std::strlen(suffix)));
        return QString(u"\u2003\u2003") + file.section('/', -1); // room for the kind icon
    }
    QString name() const override { return kind_; }
    unsigned int nPorts(QtNodes::PortType type) const override;
    QtNodes::NodeDataType dataType(QtNodes::PortType type,
                                   QtNodes::PortIndex index) const override;
    void setInData(std::shared_ptr<QtNodes::NodeData>, QtNodes::PortIndex const) override {}
    std::shared_ptr<QtNodes::NodeData> outData(QtNodes::PortIndex) override { return nullptr; }
    QWidget* embeddedWidget() override; // lazy: created on first request, cached
    // Pass nodes embed a preview; returns true iff the content changed.
    bool set_preview(const QImage& img);
    const QString& key() const { return key_; }
    bool portCaptionVisible(QtNodes::PortType, QtNodes::PortIndex) const override { return true; }
    QString portCaption(QtNodes::PortType type, QtNodes::PortIndex index) const override;
    // Pin model: passes only, order Texture*, Sampler*, Model?, Uniform*.
    QList<Pin> inputs;
    QStringList uniform_outputs; // settings only; first entry always "Uniforms"
    std::function<void()> on_swap; // texture/mesh nodes: set by Node_View after addNode
    // "Uniforms" -> "SceneUniforms", other block names unchanged.
    static QString uniform_label(const QString& block);
    // plan13: re-derive the node style from the active editor skin
    // (called by Node_View::apply_theme on every theme switch).
    void apply_theme();

private:
    QPointer<QWidget> widget_;
    QString kind_;
    QString key_;
    bool want_preview_ = false;
};

// Canvas view with bounded zoom: trackpad pinch and mouse wheel zoom within
// [kMinZoom, kMaxZoom]; trackpad two-finger scroll (has a pixel delta) pans.
// Base GraphicsView zooms a fixed x1.2 per wheel event and centerScene()s on show.
class Graph_View : public QtNodes::GraphicsView {
public:
    static constexpr double kMinZoom = 0.25;
    static constexpr double kMaxZoom = 2.5;
    explicit Graph_View(QWidget* parent = nullptr) : QtNodes::GraphicsView(parent) {
        setScaleRange(kMinZoom, kMaxZoom);
    }
    void zoom_by(double f);
    void fit_all(); // frame every node; never resets the sceneRect
    double zoom() const { return transform().m11(); }

protected:
    void wheelEvent(QWheelEvent* e) override;
    void showEvent(QShowEvent* e) override; // skips base centerScene (resets zoom)
    bool viewportEvent(QEvent* e) override;

private:
    bool shown_once_ = false;
};

class Node_View : public QWidget {
    Q_OBJECT
public:
    Node_View(QWidget* parent = nullptr);

    // Loads layout from the scene's graph.json (missing file = default
    // plan layout: left-to-right chain). Returns false on invalid JSON.
    bool load_layout(const QString& scene_title, const QString& scene_root,
                     const scene::Runtime_Scene& scene);
    // Serializes nodes + links and writes graph.json atomically (tmp+rename).
    bool save_layout(const QString& scene_title, const QString& scene_root);
    void set_scene(const scene::Runtime_Scene& scene);
    // Pass output previews (128px targets, GPU-downscaled every frame by
    // the submit). Index = pass order; empty images skip. The final entry
    // (size = passes+1) is the viewport output and is ignored here.
    void set_previews(const QVector<QImage>& images);
    void set_previews_enabled(bool on);

    // (graph.json read errors are not surfaced; load_layout returns false)
    // Create-node actions (context menu): writes template .slang files
    // into the scene dir; the watcher rebuild picks the new pass up.
    void create_pass_file(bool graphics);
    void create_combine_file(const QString& op);
    void clear_dirty() { dirty_ = false; }
    bool dirty_layout() const { return dirty_; }

    // Test hook: fades need a running event loop to tick; tests drive them
    // synchronously instead. Advances every running flash fade to `elapsed_ms`
    // (setCurrentTime, the exact stack of the reported crash). Returns the
    // number of fades that were running.
    int debug_step_flashes(int elapsed_ms);
    int debug_node_count() const { return int(model_->allNodeIds().size()); }
    double debug_zoom() const { return view_->zoom(); }
    QStringList debug_ports(const QString& key, bool inputs) const;

private:
    const scene::Runtime_Scene* current_scene_ = nullptr;
    bool fit_pending_ = false; // next deferred rebuild frames the whole graph (load_layout)
    // Wireless uniform feed: every uniform input port of a pass gets a
    // converging ring mark (receive); every settings output gets a ball +
    // expanding rings (broadcast). Parked per tick on a ~1.6 s loop.
    struct Wireless_Mark {
        QGraphicsEllipseItem* ring1 = nullptr;
        QGraphicsEllipseItem* ring2 = nullptr;
        bool grow = false; // emit expands, receive converges
    };
    void refresh_wireless_marks();
    void rebuild_wireless_marks(const std::vector<render_graph::Pass_Descriptor>& descs);
    void park_wireless_marks(const std::vector<render_graph::Pass_Descriptor>& descs);
    void clear_wireless_marks();
    void for_each_wireless_port(
        const std::vector<render_graph::Pass_Descriptor>& descs,
        const std::function<void(QtNodes::NodeId, QtNodes::PortType, QtNodes::PortIndex, bool)>& fn) const;
    // Construction + model signal handlers.
    QHBoxLayout* build_toolbar();
    void connect_model_signals();
    void on_connection_created(QtNodes::ConnectionId id);
    void on_connection_deleted(QtNodes::ConnectionId id);
    bool links_valid(std::string& err) const; // plan_build over links_
    void show_canvas_menu(const QPoint& pos);
    void show_node_menu(QtNodes::NodeId id);
    void add_node_at(Graph_Node node, const QPointF& scene_pos);
    void add_resource_node(bool mesh, bool skybox, const QPointF& scene_pos);
    // Load/save pieces.
    void default_layout(const scene::Runtime_Scene& scene);
    bool read_graph(const std::string& text);
    void collect_links_from_model();
    QByteArray layout_json(const QString& scene_title) const;
    // Rebuild pieces.
    void add_model_node(const Graph_Node& node,
                        const std::vector<render_graph::Pass_Descriptor>& descs);
    void restore_links();
    // No links in graph.json (or no file): chain passes in reflection order
    // into show2d — the same routing plan_build infers at runtime.
    void derive_default_links();
    void auto_link_models();
    // Pass previews: keyed by node id (pass nodes only); pushed into the
    // embedded Preview_Widget of each pass node.
    void refresh_previews();
    void rebuild_scene();
    void sync_positions();   // copy model node positions into nodes_
    void clear_model();      // delete every model node/connection and overlays
    void swap_resource(const QString& key);
    void replace_resource(const QString& old_key, const QString& path);
    std::vector<render_graph::Pass_Descriptor> descriptors() const;
    QString node_key(QtNodes::NodeId id) const;
    QtNodes::NodeId node_id(const QString& key) const;
    // Link endpoints: "<key>:<pin>" (see the plan's pin model).
    QString input_endpoint(QtNodes::NodeId id, QtNodes::PortIndex port) const;
    QString output_endpoint(QtNodes::NodeId id, QtNodes::PortIndex port) const;
    bool resolve_output(const QString& ep, QtNodes::NodeId& id, QtNodes::PortIndex& port) const;
    bool resolve_input(const QString& ep, QtNodes::NodeId& id, QtNodes::PortIndex& port) const;

    QtNodes::DataFlowGraphModel* model_ = nullptr;
    QtNodes::DataFlowGraphicsScene* scene_ = nullptr;
    Graph_View* view_ = nullptr;
    // Read by the registry factory: set right before model_->addNode(kind).
    QString pending_key_;
    bool pending_preview_ = false;
    QMap<QtNodes::NodeId, QString> id_to_key_;
    QList<Graph_Node> nodes_;
    QList<Graph_Link> links_;
    QString scene_title_;
    QString scene_root_;
    bool dirty_ = false;
    bool marks_dirty_ = true; // rebuild wireless_marks_ on the next tick
    std::vector<Wireless_Mark> wireless_marks_;
    QTimer* marks_timer_ = nullptr;
    bool loading_ = false; // rebuild/load is repopulating the model; mute handlers
    QElapsedTimer marks_clock_;
    QVector<QImage> previews_;
    bool previews_enabled_ = true;
    // plan10 feedback: one-shot halo fades. A pass node keeps one ring; a new
    // flash replaces the old. The fade is a child of its item (see Fade_Item).
    QHash<QtNodes::NodeId, QPointer<QGraphicsObject>> pass_flash_items_;
    void flash_link(QtNodes::ConnectionId id);   // new wire accepted
    void flash_pass(QtNodes::NodeId id);         // pass output changed

signals:
    // Links changed; the host flushes graph.json now (immediate save).
    void pipeline_changed();
    // plan6 selection sync: a pass node was clicked; the shell opens the
    // matching shader tab (pass nodes only; settings/output are silent).
    void node_selected(const QString& key, const QString& kind);
    // Toolbar fullscreen toggle; the shell swaps its layout on this.
    void fullscreen_toggled(bool on);

public:
    // Inverse sync: the editor activated a shader tab; select (and reveal)
    // the matching pass node. No-op when no node carries the key.
    void select_node_for_key(const QString& key);
    void set_fullscreen_state(bool on);
    // plan13: the editor skin drives the whole graph look — re-applies
    // StyleCollection (grid/nodes/wires) and every live Scene_Delegate.
    // Called by Shell::apply_chrome_theme on every theme switch.
    void apply_theme();
};

// Confirmation modal ("replaces %s", apply/cancel) mirroring the Odin flow.
class Confirm_Dialog : public QDialog {
    Q_OBJECT
public:
    Confirm_Dialog(const QString& message, QWidget* parent = nullptr);
    bool apply() const { return apply_; }

private:
    bool apply_ = false;
};

} // namespace graph_editor
