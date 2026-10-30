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
#include <QImage>
#include <QGraphicsPixmapItem>
#include <QMap>
#include <QVariantAnimation>
#include <QString>
#include <QWidget>
#include "QtNodes/internal/DataFlowGraphModel.hpp"
#include "QtNodes/internal/DataFlowGraphicsScene.hpp"
#include "QtNodes/internal/GraphicsView.hpp"
#include "QtNodes/internal/NodeDelegateModel.hpp"

#include <QGraphicsObject>
#include <cstring>

#include "gfx/scene_runtime.hpp"

class QMenu;

namespace graph_editor {

// One node on the canvas: a pass (from reflection), params, output (show2d),
// or a user resource. key matches graph.json semantics.
struct Graph_Node {
    QString key;
    QString kind;      // params|graphics|compute|output|texture|mesh|widget
    float x = 0, y = 0;
    // User-resource extras.
    QString file;
    QString model;     // mesh nodes: assets/models basename ("stanford_dragon")
    QString filter;    // point|linear
    QString address;   // clamp|repeat|mirror
    int width = 0, height = 0;
    float value = 0;
};

struct Graph_Link {
    QString from; // "<key>:<pin>"
    QString to;
};

// Delegate node: kind-tagged node. Ports: one frame output for producers,
// one input per texture binding, one input per uniform block (wireless:
// never linked, marked by the animated broadcast/receive rings). Validation
// happens in plan_build, not the type system (Odin parity).
class Scene_Delegate : public QtNodes::NodeDelegateModel {
public:
    explicit Scene_Delegate(QString kind, QString key);
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
        return file.section('/', -1);
    }
    QString name() const override { return kind_; }
    unsigned int nPorts(QtNodes::PortType type) const override;
    QtNodes::NodeDataType dataType(QtNodes::PortType type,
                                   QtNodes::PortIndex index) const override;
    void setInData(std::shared_ptr<QtNodes::NodeData>, QtNodes::PortIndex const) override {}
    std::shared_ptr<QtNodes::NodeData> outData(QtNodes::PortIndex) override { return nullptr; }
    QWidget* embeddedWidget() override { return nullptr; }
    void set_key(const QString& key) { key_ = key; }
    // Port captions: binding names (texture) and "<block> (uniform)";
    // they drive the node width so titles AND pins always fit.
    bool portCaptionVisible(QtNodes::PortType, QtNodes::PortIndex) const override;
    QString portCaption(QtNodes::PortType, QtNodes::PortIndex) const override;
    // Per-node interface snapshot: texture inputs then uniform blocks, so
    // the port index -> name mapping matches the descriptor. Set before the
    // model's port counts are applied.
    QStringList tex_inputs;
    QStringList uniform_inputs;
    // plan13: re-derive the node style from the active editor skin
    // (called by Node_View::apply_theme on every theme switch).
    void apply_theme();

private:
    QString kind_;
    QString key_;
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
    // Pass output thumbnails (128px targets, GPU-downscaled every frame by
    // the submit). Index = pass order; empty images skip. The final entry
    // (size = passes+1) is the viewport output.
    void set_previews(const QVector<QImage>& images);
    void set_previews_enabled(bool on) { previews_enabled_ = on; refresh_previews(); }

    QString pipeline_error() const { return pipeline_error_; }
    // Create-node actions (context menu): writes template .slang files
    // into the scene dir; the watcher rebuild picks the new pass up.
    void create_pass_file(bool graphics);
    void create_combine_file(const QString& op);
    void clear_dirty() { dirty_ = false; }
    bool dirty_layout() const { return dirty_; }

    // Plan 05 test hook: QVariantAnimation needs a running event loop to
    // tick; tests drive the fade synchronously instead. Advances every
    // running flash animation to `elapsed_ms` (setCurrentTime = the exact
    // stack of the reported crash). Returns animations still running.
    int debug_step_flashes(int elapsed_ms);

private:
    const scene::Runtime_Scene* current_scene_ = nullptr;
    // Wireless uniform feed: every uniform input port gets a converging
    // ring mark (the signal arriving); the params node's uniform outputs
    // get a ball + expanding rings (broadcast). QGraphicsEllipseItems over
    // the scene, parked per tick on a ~1.6 s loop (Odin sg_draw_wireless_rings).
    struct Wireless_Mark {
        QGraphicsEllipseItem* ring1 = nullptr;
        QGraphicsEllipseItem* ring2 = nullptr;
        bool grow = false; // emit expands, receive converges
    };
    void refresh_wireless_marks();
    // No links in graph.json (or no file): chain passes in reflection order
    // into show2d — the same routing plan_build infers at runtime.
    void derive_default_links();
    // Pass thumbnails: keyed by node id (pass nodes only); rebuilt on
    // rebuild_scene, parked on set_previews.
    void refresh_previews();
    // Pixel provenance per node (legacy parity): Alt+click a pass thumbnail
    // samples that QImage at the click point and parks a colored
    // "r g b a" label under the preview. Cleared on rebuild/preview change.
    bool eventFilter(QObject* watched, QEvent* event) override;
    std::vector<Wireless_Mark> wireless_marks_;
    QTimer* marks_timer_ = nullptr;
    bool loading_ = false; // rebuild_scene is repopulating links; mute handlers
    QElapsedTimer marks_clock_;
    QVector<QImage> previews_;
    bool previews_enabled_ = true;
    QMap<QtNodes::NodeId, QGraphicsPixmapItem*> preview_items_;
    QMap<QtNodes::NodeId, QGraphicsTextItem*> provenance_items_;
    // plan10 feedback: one-shot halo flashes (self-removing after the
    // fade). Keyed by node id; a new flash replaces the old one.
    QMap<QtNodes::NodeId, QGraphicsPathItem*> link_flash_items_;
    QMap<QtNodes::NodeId, QGraphicsEllipseItem*> pass_flash_items_;
    std::vector<QVariantAnimation*> flash_anims_; // live fades (Plan 05 hook)
    void flash_link(QtNodes::ConnectionId id);   // new wire accepted
    void flash_pass(QtNodes::NodeId id);         // pass output changed

signals:
    // Links changed; the host flushes graph.json now (immediate save).
    void pipeline_changed();
    // plan6 selection sync: a pass node was clicked; the shell opens the
    // matching shader tab (pass nodes only; params/output are silent).
    void node_selected(const QString& key, const QString& kind);

public:
    // Inverse sync: the editor activated a shader tab; select (and reveal)
    // the matching pass node. No-op when no node carries the key.
    void select_node_for_key(const QString& key);
    // plan13: the editor skin drives the whole graph look — re-applies
    // StyleCollection (grid/nodes/wires) and every live Scene_Delegate.
    // Called by Shell::apply_chrome_theme on every theme switch.
    void apply_theme();

private:
    void rebuild_scene();
    std::vector<render_graph::Pass_Descriptor> descriptors() const;
    QString node_key(QtNodes::NodeId id) const;
    QtNodes::NodeId node_id(const QString& key) const;

    QtNodes::DataFlowGraphModel* model_ = nullptr;
    QtNodes::DataFlowGraphicsScene* scene_ = nullptr;
    QtNodes::GraphicsView* view_ = nullptr;
    QMap<QtNodes::NodeId, QString> id_to_key_;
    QList<Graph_Node> nodes_;
    QList<Graph_Link> links_;
    QString scene_title_;
    QString last_scene_;
    QString scene_root_;
    bool dirty_ = false;
    QString pipeline_error_;
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
