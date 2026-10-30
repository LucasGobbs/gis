// Graph editor implementation over QtNodes (DataFlowGraphModel): nodes with
// reflection-derived pins, graph.json load/save (atomic), links validated by
// plan_build before accept (invalid keeps the last valid pipeline, matching
// the Odin flow), confirmation modal for producer-replacing edges.
#include "graph_editor.hpp"
#include "gfx/render_graph/refl.hpp"
#include "notify.hpp"
#include <algorithm>
#include "theme.hpp"

#include "QtNodes/internal/NodeGraphicsObject.hpp"
#include "QtNodes/internal/StyleCollection.hpp"
#include "QtNodes/internal/ConnectionGraphicsObject.hpp"
#include "shell.hpp" // reduced_motion()

#include <QGraphicsPathItem>
#include <QTimer>
#include <QVariantAnimation>


#include <QDialogButtonBox>
#include <QFileDialog>
#include <QFileInfo>
#include <QMenu>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QEvent>
#include <QGraphicsTextItem>
#include <QImage>
#include <QLabel>
#include <QMouseEvent>
#include <QVBoxLayout>

#include <fstream>
#include <sstream>

#include <QtNodes/internal/ConnectionIdUtils.hpp>
#include <QtNodes/internal/NodeStyle.hpp>
#include <QtNodes/internal/ConnectionStyle.hpp>

namespace graph_editor {

// ---- Scene_Delegate: kind-tagged node with uniform frame ports ----

Scene_Delegate::Scene_Delegate(QString kind, QString key)
    : kind_(std::move(kind)), key_(std::move(key)) {
    apply_theme();
}

// plan13: the editor skin drives the node look — re-derived on theme
// switch (Node_View::apply_theme re-styles every live delegate).
void Scene_Delegate::apply_theme() {
    // Kind at a GLANCE: boundary + gradient hues per node type from the
    // theme's semantic resource tokens (per-skin; data-defined link colors
    // follow the same hues). params=accent, compute=violet, graphics=blue,
    // output=green, texture/mesh/widget=neutral.
    QtNodes::NodeStyle st = nodeStyle();
    theme::Resource_Kind rk = theme::Resource_Kind::Neutral;
    if (kind_ == "params") rk = theme::Resource_Kind::Params;
    else if (kind_ == "compute") rk = theme::Resource_Kind::Compute;
    else if (kind_ == "graphics") rk = theme::Resource_Kind::Graphics;
    else if (kind_ == "output") rk = theme::Resource_Kind::Output;
    const QColor boundary = theme::resource_rgb(rk);
    const QColor g0 = boundary.darker(190);
    const QColor g1 = boundary.darker(300);
    st.NormalBoundaryColor = boundary;
    st.SelectedBoundaryColor = boundary.lighter(130);
    st.GradientColor0 = g0; st.GradientColor1 = g1;
    st.GradientColor2 = g1; st.GradientColor3 = g0;
    setNodeStyle(st);
}

unsigned int Scene_Delegate::nPorts(QtNodes::PortType type) const {
    if (type == QtNodes::PortType::Out) {
        if (kind_ == "params") return unsigned(uniform_inputs.size());
        if (kind_ == "output") return 0u;
        // Image nodes expose BOTH route pins: the sampled texture and the
        // sampler configured by the node's filter/address fields.
        if (kind_ == "texture") return 2u;
        return 1u;
    }
    if (type == QtNodes::PortType::In) {
        if (kind_ == "output") return 1u;
        return unsigned(tex_inputs.size() + uniform_inputs.size());
    }
    return 0u;
}

QtNodes::NodeDataType Scene_Delegate::dataType(QtNodes::PortType type,
                                               QtNodes::PortIndex index) const {
    if (type == QtNodes::PortType::Out) {
        // id "frame" matches shader texture inputs: DataFlowGraphModel::connectionPossible
        // requires id equality. The name labels the port as texture or sampler.
        if (kind_ == "texture") return index == 1 ? QtNodes::NodeDataType{"frame", "sampler"}
                                                  : QtNodes::NodeDataType{"frame", "texture"};
        if (kind_ == "mesh") return {"vertex", "vertex"};
    }
    if (type == QtNodes::PortType::In && index >= QtNodes::PortIndex(tex_inputs.size())) {
        return {"uniform", "uniform"};
    }
    return {"frame", type == QtNodes::PortType::In ? "in" : "frame"};
}
// Port captions: the Odin labels. Texture inputs show the binding name;
// uniform inputs show "<block> (SceneUniforms)"-style (the block name);
// the params node's outputs show the block each broadcast feeds. Captions
// drive the node width (maxPortsTextAdvance), so titles AND pins fit.
bool Scene_Delegate::portCaptionVisible(QtNodes::PortType, QtNodes::PortIndex) const {
    return true;
}

QString Scene_Delegate::portCaption(QtNodes::PortType type, QtNodes::PortIndex index) const {
    if (type == QtNodes::PortType::In) {
        if (index < QtNodes::PortIndex(tex_inputs.size())) return tex_inputs[index];
        int u = int(index) - int(tex_inputs.size());
        if (u >= 0 && u < uniform_inputs.size())
            return uniform_inputs[u] + " (uniform)";
    } else if (type == QtNodes::PortType::Out && kind_ == "params") {
        if (index < uniform_inputs.size()) return uniform_inputs[index] + " (uniform)";
    } else if (type == QtNodes::PortType::Out && kind_ == "texture") {
        return index == 1 ? "sampler" : "texture";
    } else if (type == QtNodes::PortType::Out && kind_ == "mesh") {
        return "vertex";
    } else if (type == QtNodes::PortType::Out) {
        return "frame";
    }
    return {};
}

Node_View::Node_View(QWidget* parent) : QWidget(parent) {
    // Link colors follow the port type (data-defined): frame links vs the
    // uniform hue — different link styles the legacy app had.
    QtNodes::ConnectionStyle::setConnectionStyle(R"(
    {
        "ConnectionStyle": {
            "UseDataDefinedColors": true,
            "LineWidth": 2.0
        }
    })");
    auto registry = std::make_shared<QtNodes::NodeDelegateModelRegistry>();
    const QStringList kinds = {"params", "graphics", "compute", "output",
                               "texture", "mesh", "widget"};
    for (const QString& kind : kinds) {
        registry->registerModel<Scene_Delegate>(
            [kind] { return std::make_unique<Scene_Delegate>(kind, kind); }, kind);
    }
    model_ = new QtNodes::DataFlowGraphModel(registry);
    scene_ = new QtNodes::DataFlowGraphicsScene(*model_, this);
    view_ = new QtNodes::GraphicsView(this);
    view_->setScene(scene_);
    view_->viewport()->installEventFilter(this); // Alt+click = pixel provenance
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->addWidget(view_);

    // Wireless uniform marks: a 33 ms timer parks the ring items on a
    // ~1.6 s loop (emitter expands, receiver converges — the Odin feed).
    marks_clock_.start();
    marks_timer_ = new QTimer(this);
    marks_timer_->setInterval(33);
    connect(marks_timer_, &QTimer::timeout, this, &Node_View::refresh_wireless_marks);
    marks_timer_->start();

    // Node moved: track positions for save_layout + autosave contract.
    connect(model_, &QtNodes::AbstractGraphModel::nodePositionUpdated, this, [this](QtNodes::NodeId) { dirty_ = true; });
    // Connection lifecycle: validate the resulting graph with plan_build;
    // invalid links are reverted (the last valid pipeline keeps running, the
    // Odin contract). Producer-replacing links ask for confirmation first.
    connect(model_, &QtNodes::AbstractGraphModel::connectionCreated, this,
            [this](QtNodes::ConnectionId id) {
        if (loading_) return; // rebuild_scene's own links; also suppresses the modal
        // Endpoint strings: "<key>:<pin>" using the descriptor input names.
        QString from_key = node_key(id.outNodeId);
        QString to_key = node_key(id.inNodeId);
        if (from_key.isEmpty() || to_key.isEmpty()) {
            model_->deleteConnection(id);
            return;
        }
        // params is wireless: its outputs broadcast by name, never wire.
        if (from_key == "params") {
            model_->deleteConnection(id);
            return;
        }
        QString to_pin = to_key;
        const auto descs = descriptors();
        QString from_pin = from_key;
        for (const auto& desc : descs) {
            if (QString::fromStdString(desc.key) == to_key &&
                id.inPortIndex < desc.input_textures.size()) {
                to_pin = to_key + ":" +
                         QString::fromStdString(desc.input_textures[id.inPortIndex]);
            }
            if (QString::fromStdString(desc.key) == from_key)
                from_pin = from_key + ":" + QString::fromStdString(desc.output_pin);
        }
        // Resource-node outputs name their PLAN route suffix: the texture
        // node's two pins route as "uimg:<path>:texture"/":sampler"; the
        // mesh node's single pin routes as "uobj:<path>:ModelVertex".
        if (from_key.startsWith("uimg:")) {
            const QString path = from_key.section(':', 1, -2);
            from_pin = id.outPortIndex == 1 ? "uimg:" + path + ":sampler"
                                            : "uimg:" + path + ":texture";
        } else if (from_key.startsWith("uobj:")) {
            const QString path = from_key.section(':', 1, -2);
            from_pin = "uobj:" + path + ":ModelVertex";
        }
        // Producer replacement: an input can have one producer. If the target
        // pin already had a link, ask before rewiring (Odin parity).
        QString replaced_from;
        for (long i = long(links_.size()) - 1; i >= 0; --i) {
            if (links_[size_t(i)].to == to_pin) replaced_from = links_[size_t(i)].from;
        }
        if (!replaced_from.isEmpty() && replaced_from != from_pin &&
            !from_key.startsWith("uimg:") && !from_key.startsWith("uobj:")) {
            Confirm_Dialog dlg(
                QString("replace %1 -> %2 with %3 -> %2?")
                    .arg(replaced_from, to_pin, from_pin),
                this);
            if (dlg.exec() == QDialog::Rejected || !dlg.apply()) {
                model_->deleteConnection(id);
                return; // keep the last valid pipeline
            }
        }
        // Drop the replaced link, then validate the candidate graph.
        for (long i = long(links_.size()) - 1; i >= 0; --i) {
            if (links_[size_t(i)].to == to_pin) links_.removeAt(i);
        }
        for (const Graph_Link& existing : links_)
            if (existing.from == from_pin && existing.to == to_pin) return; // dup
        links_.push_back({from_pin, to_pin});
        render_graph::Graph_Json doc;
        doc.version = render_graph::GRAPH_SCHEMA_VERSION;
        doc.scene = scene_title_.toStdString();
        for (const Graph_Node& n : nodes_) {
            render_graph::Node_Json nj;
            nj.key = n.key.toStdString();
            nj.kind = n.kind.toStdString();
            doc.nodes.push_back(nj);
        }
        for (const Graph_Link& l : links_) {
            render_graph::Link_Json lj;
            lj.from = l.from.toStdString();
            lj.to = l.to.toStdString();
            doc.links.push_back(lj);
        }
        std::string err;
        bool ok = false;
        render_graph::Plan plan =
            render_graph::plan_build(descriptors(), doc, err, ok);
        render_graph::plan_destroy(plan);
        if (!ok) {
            model_->deleteConnection(id); // revert: invalid link never lands
            notify::notify(notify::Kind::ERROR_, QString::fromStdString(err));
            return;
        }
        dirty_ = true;
        flash_link(id); // plan10: one-shot halo on the new wire
        emit pipeline_changed();
    });
    connect(model_, &QtNodes::AbstractGraphModel::connectionDeleted, this, [this](QtNodes::ConnectionId id) {
        // Endpoint strings must match links_ format "<key>:<pin>" (same
        // mapping as connectionCreated / save_layout).
        const auto descs = descriptors();
        QString from_key = node_key(id.outNodeId);
        QString to_key = node_key(id.inNodeId);
        QString from_pin = from_key;
        QString to_pin = to_key;
        for (const auto& desc : descs) {
            if (QString::fromStdString(desc.key) == from_key)
                from_pin = from_key + ":" + QString::fromStdString(desc.output_pin);
            if (QString::fromStdString(desc.key) == to_key &&
                id.inPortIndex < desc.input_textures.size())
                to_pin = to_key + ":" +
                         QString::fromStdString(desc.input_textures[id.inPortIndex]);
        }
        if (to_key == "show2d") to_pin = to_key + ":frame";
        for (long i = long(links_.size()) - 1; i >= 0; --i) {
            if (links_[size_t(i)].from == from_pin && links_[size_t(i)].to == to_pin) links_.removeAt(i);
        }
        dirty_ = true;
        emit pipeline_changed();
    });
    // Node context menu: create passes/combines (writes .slang into the
    // scene dir — the watcher rebuilds and the next resync picks the new
    // pass up) and user resources (image/mesh/target) like imgui_nodes.
    view_->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(view_, &QWidget::customContextMenuRequested, this, [this](const QPoint& pos) {
        QMenu menu(this);
        menu.addSection("create pass");
        QAction* gfx_pass = menu.addAction("graphics pass");
        QAction* cmp_pass = menu.addAction("compute pass");
        menu.addSection("create combine");
        QAction* combine_add = menu.addAction("ADD");
        QAction* combine_mul = menu.addAction("MUL");
        QAction* combine_and = menu.addAction("AND");
        QAction* combine_or = menu.addAction("OR");
        QAction* combine_not = menu.addAction("NOT");
        menu.addSection("create resource");
        QAction* image = menu.addAction("image…");
        QAction* skybox = menu.addAction("skybox…");
        QAction* mesh = menu.addAction("mesh…");
        QAction* chosen = menu.exec(view_->mapToGlobal(pos));
        if (!chosen) return;
        if (chosen == gfx_pass || chosen == cmp_pass) {
            create_pass_file(chosen == gfx_pass);
            return;
        }
        if (chosen == combine_add || chosen == combine_mul || chosen == combine_and ||
            chosen == combine_or || chosen == combine_not) {
            QString op = chosen == combine_add ? "ADD"
                       : chosen == combine_mul ? "MUL"
                       : chosen == combine_and ? "AND"
                       : chosen == combine_or  ? "OR" : "NOT";
            create_combine_file(op);
            return;
        }
        if (chosen == image || chosen == skybox || chosen == mesh) {
            // Real asset pick: the node key embeds the path the runtime
            // loads; a fake path would create a dead node (bind-site miss).
            const char* caption = chosen == mesh ? "pick mesh" : "pick image";
            QString filter = chosen == mesh ? "Models (*.glb *.gltf)"
                                            : "Images (*.png *.jpg *.jpeg *.bmp)";
            QString start_dir = chosen == skybox ? "assets/skybox" : "assets";
            QString path =
                QFileDialog::getOpenFileName(this, caption, start_dir, filter);
            if (path.isEmpty()) return;
            QFileInfo info(path);
            Graph_Node node;
            node.kind = chosen == mesh ? "mesh" : "texture";
            node.key = chosen == mesh
                           ? QString("uobj:%1:ModelVertex").arg(info.filePath())
                           : QString("uimg:%1:texture").arg(info.filePath());
            if (chosen == skybox) {
                // Equirect convention check (existing assets/skybox
                // images are 2:1); warn but still create.
                QImage probe(info.filePath());
                if (probe.width() > 0 && probe.width() != 2 * probe.height())
                    notify::notify(notify::Kind::WARN,
                                   "not equirectangular (expected 2:1); sampling "
                                   "will look stretched");
            }
            QPointF spos = view_->mapToScene(pos);
            node.x = float(spos.x());
            node.y = float(spos.y());
            nodes_.push_back(node);
            dirty_ = true;
            rebuild_scene();
            return;
        }
        // "render target": valid without a file (the plan creates it).
        Graph_Node node;
        node.kind = "texture";
        node.key = "uimg:target:new_target:texture";
        QPointF spos = view_->mapToScene(pos);
        node.x = float(spos.x());
        node.y = float(spos.y());
        nodes_.push_back(node);
        dirty_ = true;
        rebuild_scene();
    });
    // plan6 selection sync: clicking a pass node selects it (QtNodes) AND
    // asks the shell to open the matching shader tab. Selection painting is
    // QtNodes-native (amber boundary; no rebuild, no per-frame work).
    connect(scene_, &QtNodes::BasicGraphicsScene::nodeClicked, this,
            [this](QtNodes::NodeId id) {
        const QString key = node_key(id);
        if (key.isEmpty()) return;
        for (const Graph_Node& n : nodes_) {
            if (n.key != key) continue;
            if (n.kind == "graphics" || n.kind == "compute")
                emit node_selected(key, n.kind);
            break;
        }
    });

    // Node context menu (right-click on a NODE): delete for user resource
    // nodes and combine passes (removes the .slang — the watcher resyncs).
    // Derived nodes (params/show2d/reflection passes) are not deletable.
    connect(scene_, &QtNodes::BasicGraphicsScene::nodeContextMenu,
            this, [this](QtNodes::NodeId id, const QPointF&) {
        QString key = node_key(id);
        QMenu menu(this);
        bool user_node = key.startsWith("uimg:") || key.startsWith("uobj:");
        bool combine = key.contains("combine_");
        if (!user_node && !combine) return;
        QAction* del = menu.addAction("delete node");
        QAction* swap = user_node && !key.contains(":target:")
                            ? menu.addAction("swap file…") : nullptr;
        QAction* chosen = menu.exec(QCursor::pos());
        if (!chosen) return;
        if (chosen == swap) {
            const bool mesh = key.startsWith("uobj:");
            QString path = QFileDialog::getOpenFileName(
                this, mesh ? "pick mesh" : "pick image", "assets",
                mesh ? "Models (*.glb *.gltf)" : "Images (*.png *.jpg *.jpeg *.bmp)");
            if (path.isEmpty()) return;
            for (Graph_Node& node : nodes_) {
                if (node.key != key) continue;
                node.key = mesh ? QString("uobj:%1:ModelVertex").arg(path)
                                : QString("uimg:%1:texture").arg(path);
                break;
            }
            dirty_ = true;
            rebuild_scene();
            return;
        }
        if (chosen == del && combine) {
            // Combine nodes own their .slang: delete the file (legacy
            // sg_delete_combine refuses non-combinator files; the marker
            // check happens on the read side).
            QString file = key.section(':', 0, -2);
            file.remove("gfx:");
            QFile(scene_root_ + "/" + file + ".slang").remove();
        }
        for (long i = long(nodes_.size()) - 1; i >= 0; --i) {
            if (nodes_[size_t(i)].key == key) {
                nodes_.removeAt(i);
                break;
            }
        }
        model_->deleteNode(id);
        dirty_ = true;
        rebuild_scene();
    });
}

void Node_View::select_node_for_key(const QString& key) {
    if (!scene_ || key.isEmpty()) return;
    // Exact key match OR comp entry-prefix match ("comp:<rel>:" matches
    // "comp:<rel>:<entry>"). First hit wins; exact matches preferred by
    // iteration order over pass nodes (unique per key anyway).
    for (auto it = id_to_key_.begin(); it != id_to_key_.end(); ++it) {
        const QString& node_key = it.value();
        if (node_key != key && !node_key.startsWith(key)) continue;
        if (auto* ngo = scene_->nodeGraphicsObject(it.key())) {
            scene_->clearSelection();
            ngo->setSelected(true);
            view_->centerOn(ngo); // reveal: bring the node into view
        }
        return;
    }
}

// plan13: the editor skin drives the whole graph look — StyleCollection
// (grid/nodes/wires) + every live Scene_Delegate. Called from the ctor and
// from Shell::apply_chrome_theme on every theme switch. Derived from the
// theme:: tokens (no per-theme literals): surfaces from chrome, text tiers
// from the chrome palette, selection halo = safelight, semantic states
// from the token layer.
void Node_View::apply_theme() {
    // Ctor order: apply_theme runs BEFORE model_/scene_ exist — the
    // StyleCollection pass is safe, the live-delegate loop is not.
    const QColor text = QColor(theme::text_primary());
    const QColor muted = QColor(theme::text_muted());
    const QColor panel = QColor(theme::surface_panel());
    const QColor control = QColor(theme::control_border());
    const QColor accent = theme::safelight_rgb();

    QtNodes::GraphicsViewStyle view_style;
    view_style.BackgroundColor = QColor(theme::surface_workspace());
    // Grid strength follows the surface: dark skins get white dots, light
    // skins get black dots (contrast rule — same alpha, hue flips).
    const bool dark_surface = view_style.BackgroundColor.lightness() < 128;
    const int grid_hue = dark_surface ? 255 : 0;
    view_style.FineGridColor = QColor(grid_hue, grid_hue, grid_hue, 12);
    view_style.CoarseGridColor = QColor(grid_hue, grid_hue, grid_hue, 26);
    QtNodes::StyleCollection::setGraphicsViewStyle(view_style);

    QtNodes::ConnectionStyle conn_style;
    conn_style.loadJsonText(QString(R"(
    {
        "ConnectionStyle": {
            "UseDataDefinedColors": true,
            "LineWidth": 1.5,
            "ConstructionLineWidth": 2.0,
            "PointDiameter": 6.0,
            "SelectedHaloColor": "%1"
        }
    })").arg(accent.name()));
    QtNodes::StyleCollection::setConnectionStyle(conn_style);

    QtNodes::NodeStyle node_style;
    node_style.loadJsonText(QString(R"(
    {
        "NodeStyle": {
            "NormalBoundaryColor": "%2",
            "SelectedBoundaryColor": "%1",
            "GradientColor0": "%3",
            "GradientColor1": "%4",
            "GradientColor2": "%4",
            "GradientColor3": "%5",
            "ShadowColor": "#00000040",
            "FontColor": "%6",
            "FontColorFaded": "%7",
            "ConnectionPointColor": "%7",
            "FilledConnectionPointColor": "%1",
            "WarningColor": "%1",
            "ErrorColor": "%8",
            "PenWidth": 1.0,
            "HoveredPenWidth": 1.5,
            "ConnectionPointDiameter": 8.0,
            "Opacity": 1.0
        }
    })").arg(accent.name(), control.name(),
             panel.lighter(112).name(), panel.name(), panel.darker(112).name(),
             text.name(), muted.name(), theme::error()));
    QtNodes::StyleCollection::setNodeStyle(node_style);
    // Live delegates re-derive their resource boundary from the tokens;
    // nodeUpdated triggers the repaint of every live NodeGraphicsObject.
    // Skipped pre-ctor (model_ null): the ctor loop applies per-delegate
    // styles as nodes are created.
    if (!model_) return;
    for (const auto& id : model_->allNodeIds()) {
        if (auto* d = model_->delegateModel<Scene_Delegate>(id)) d->apply_theme();
        model_->nodeUpdated(id);
    }
}

// plan10 feedback (quietly expressive): a one-shot halo over the new wire
// (success green, 400ms fade) says "the pipeline accepted this" without a
// modal or a toast. Reduced motion: skip the halo — the wire itself is
// the confirmation.
void Node_View::flash_link(QtNodes::ConnectionId id) {
    if (!scene_ || shell::reduced_motion()) return;
    auto* cgo = scene_->connectionGraphicsObject(id);
    if (!cgo) return;
    QPainterPath halo = cgo->shape(); // stroked wire path (qt6: shape)
    if (halo.isEmpty()) return;
    auto* flash = new QGraphicsPathItem(halo);
    QColor c = theme::success_rgb();
    c.setAlpha(160);
    QPen pen(c, 6.0);
    pen.setCapStyle(Qt::RoundCap);
    flash->setPen(pen);
    flash->setZValue(8.0); // over wires (2), under the wireless rings (20)
    scene_->addItem(flash);
    auto* anim = new QVariantAnimation();
    anim->setDuration(400);
    anim->setStartValue(160.0);
    anim->setEndValue(0.0);
    anim->setEasingCurve(QEasingCurve::OutCubic);
    // Plan 05 (same class as flash_pass): a scene rebuild mid-fade deletes
    // the flash item; the QObject guard parented to the SCENE dies with the
    // scene (clear) and disconnects the valueChanged lambda before it could
    // call flash->pen() on freed memory.
    auto* guard = new QObject(scene_);
    QObject::connect(anim, &QVariantAnimation::valueChanged, guard,
            [flash](const QVariant& v) {
                QColor c = flash->pen().color();
                c.setAlpha(int(v.toDouble()));
                QPen p = flash->pen();
                p.setColor(c);
                flash->setPen(p);
            });
    QObject::connect(guard, &QObject::destroyed, anim,
                     &QVariantAnimation::stop);
    QObject::connect(anim, &QVariantAnimation::finished, anim, [this, anim, flash] {
        flash_anims_.erase(std::remove(flash_anims_.begin(),
                                       flash_anims_.end(), anim),
                           flash_anims_.end());
        if (auto* sc = flash->scene()) sc->removeItem(flash);
        delete flash; // scene drop; anim (DeleteWhenStopped) deletes itself
    });
    flash_anims_.push_back(anim);
    anim->start(QAbstractAnimation::DeleteWhenStopped);
}

// Plan 05 test hook: advances every live flash to `elapsed_ms`. setCurrentTime
// is the exact emission path of the reported crash (synchronous valueChanged),
// so the test exercises the callback without an event loop.
int Node_View::debug_step_flashes(int elapsed_ms) {
    int running = 0;
    for (QVariantAnimation* anim : flash_anims_) {
        if (anim->state() != QAbstractAnimation::Running) continue;
        ++running;
        anim->setCurrentTime(elapsed_ms);
    }
    return running;
}

// plan10: a ring around a pass node that fades when the pass output
// CHANGES (not every frame). One per node; a new flash replaces the old.
void Node_View::flash_pass(QtNodes::NodeId id) {
    if (!scene_ || shell::reduced_motion()) return;
    if (auto* old = pass_flash_items_.take(id)) {
        if (auto* sc = old->scene()) sc->removeItem(old);
        delete old;
    }
    auto* ngo = scene_->nodeGraphicsObject(id);
    if (!ngo) return;
    const QRectF bounds = ngo->boundingRect();
    auto* ring = new QGraphicsEllipseItem(bounds.adjusted(-6, -6, 6, 6), ngo);
    QColor c = theme::safelight_rgb();
    c.setAlpha(140);
    ring->setPen(QPen(c, 2.0));
    ring->setBrush(Qt::NoBrush);
    ring->setZValue(6.0); // under the wireless rings, over previews
    pass_flash_items_[id] = ring;
    auto* anim = new QVariantAnimation();
    anim->setDuration(600);
    anim->setStartValue(140.0);
    anim->setEndValue(0.0);
    anim->setEasingCurve(QEasingCurve::OutCubic);
    // Plan 05: the ring can die while the fade runs — load_layout's
    // deleteNode sweep (theme switch → apply_mode → GRAPH reload) destroys
    // the NGO the ring is parented to, and flash_pass itself replaces the
    // ring on every fresh preview. QGraphicsItem is NOT a QObject, so the
    // animation gets a QObject GUARD parented to the NGO instead: the NGO
    // dying destroys the guard, which disconnects the valueChanged lambda
    // before it could call ring->pen() on freed memory (the ASan crash at
    // 0x8). Replacing the ring deletes the guard with it, stopping the old
    // fade cleanly.
    auto* guard = new QObject(ngo);
    QObject::connect(anim, &QVariantAnimation::valueChanged, guard,
            [ring](const QVariant& v) {
                QColor c = ring->pen().color();
                c.setAlpha(int(v.toDouble()));
                QPen p = ring->pen();
                p.setColor(c);
                ring->setPen(p);
            });
    QObject::connect(guard, &QObject::destroyed, anim,
                     &QVariantAnimation::stop);
    connect(anim, &QVariantAnimation::finished, this, [this, id, ring, anim] {
        if (pass_flash_items_.value(id) == ring) pass_flash_items_.remove(id);
        flash_anims_.erase(std::remove(flash_anims_.begin(),
                                       flash_anims_.end(), anim),
                           flash_anims_.end());
        delete ring; // child of the NGO: scene drop is implicit
    });
    connect(anim, &QVariantAnimation::finished, anim, &QObject::deleteLater);
    flash_anims_.push_back(anim);
    anim->start(QAbstractAnimation::DeleteWhenStopped);
}

// Writes a pass template (legacy imgui_nodes SG_TEMPLATE_*) into the
// scene dir as pass_N.slang. The watcher sees the new file, the build
// runs, and the next graph rebuild picks the pass up as a node.
void Node_View::create_pass_file(bool graphics) {
    if (scene_title_.isEmpty()) return;
    QString dir = scene_root_ + "/" + scene_title_;
    QString body;
    if (graphics) {
        body = R"SLANG(// Graphics pass created from the node graph. Fullscreen triangle sampling
// the previous pass's frame (input_tex); replace the passthrough with
// your shading.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    return input_tex.Sample(input_sampler, uv);
}
)SLANG";
    } else {
        body = R"SLANG(// Compute pass created from the node graph. Reads the previous pass's
// frame (input_tex) and writes out_tex; replace the passthrough with
// your effect.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> input_tex;

[[vk::binding(2, 0)]]
SamplerState input_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> out_tex;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 uv = (float2(id.xy) + 0.5) / Uniforms.iResolution.xy;
    out_tex[id.xy] = input_tex.Sample(input_sampler, uv);
}
)SLANG";
    }
    for (int n = 1; n < 100; ++n) {
        QString path = QString("%1/pass_%2.slang").arg(dir).arg(n);
        if (QFileInfo::exists(path)) continue;
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) {
            notify::notify(notify::Kind::ERROR_, "could not write " + path);
            return;
        }
        f.write(body.toUtf8());
        notify::notify(notify::Kind::INFO, "created " + path);
        return;
    }
    notify::notify(notify::Kind::ERROR_, "no free pass_N name (1..99)");
}

// Fragment body per combine op (legacy sg_combine_body; ADD = alpha-over).
static QString combine_body(const QString& op) {
    if (op == "ADD")
        return "float oa = a.a + b.a * (1.0 - a.a); float3 rgb = oa > 1e-6 ? "
               "(a.rgb * a.a + b.rgb * b.a * (1.0 - a.a)) / oa : float3(0.0, 0.0, 0.0); "
               "return float4(rgb, oa);";
    if (op == "MUL") return "return a * b;";
    if (op == "AND") return "return min(a, b);";
    if (op == "OR") return "return max(a, b);";
    return "return float4(1.0 - a.rgb, a.a);"; // NOT
}

// Writes combine_<op>[_N].slang; the first line marks it a combinator
// (legacy marker: // graph-node: combine <OP>).
void Node_View::create_combine_file(const QString& op) {
    if (scene_title_.isEmpty()) return;
    QString dir = scene_root_ + "/" + scene_title_;
    QString body = QString(R"SLANG(// graph-node: combine %1
// Combinator created from the node graph: a %1 of its two inputs.
import "../../common";

[[vk::binding(0, 0)]]
ConstantBuffer<SceneUniforms> Uniforms;

[[vk::binding(1, 0)]]
Texture2D<float4> a_tex;

[[vk::binding(2, 0)]]
SamplerState a_sampler;

[[vk::binding(3, 0)]]
Texture2D<float4> b_tex;

[[vk::binding(4, 0)]]
SamplerState b_sampler;

[shader("vertex")]
VsOut vertMain(uint vertexIndex : SV_VertexID) {
    return fullscreen_vertex(vertexIndex, Uniforms.iResolution.xy);
}

[shader("fragment")]
float4 pixelMain(VsOut input) : SV_Target0 {
    float2 uv = input.gl_FragCoord / Uniforms.iResolution.xy;
    float4 a = a_tex.Sample(a_sampler, uv);
    float4 b = b_tex.Sample(b_sampler, uv);
    %2
}
)SLANG").arg(op, combine_body(op));
    QString base = "combine_" + op.toLower();
    QString path = dir + "/" + base + ".slang";
    for (int n = 1; QFileInfo::exists(path) && n < 100; ++n)
        path = QString("%1/%2_%3.slang").arg(dir, base).arg(n);
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        notify::notify(notify::Kind::ERROR_, "could not write " + path);
        return;
    }
    f.write(body.toUtf8());
    notify::notify(notify::Kind::INFO, "created " + path);
}

std::vector<render_graph::Pass_Descriptor> Node_View::descriptors() const {
    return current_scene_ ? scene::scene_pass_descriptors(*current_scene_)
                          : std::vector<render_graph::Pass_Descriptor>{};
}

QString Node_View::node_key(QtNodes::NodeId id) const {
    return id_to_key_.contains(id) ? id_to_key_[id] : QString();
}

QtNodes::NodeId Node_View::node_id(const QString& key) const {
    for (auto it = id_to_key_.begin(); it != id_to_key_.end(); ++it)
        if (it.value() == key) return it.key();
    return QtNodes::InvalidNodeId;
}

// No links in graph.json (or no file at all): chain the pass nodes in
// reflection order into show2d — the same routing plan_build infers at
// runtime, so the canvas mirrors what actually renders.
void Node_View::derive_default_links() {
    links_.clear();
    const auto descs = descriptors();
    auto find_desc = [&descs](const QString& key)
        -> const render_graph::Pass_Descriptor* {
        for (const auto& d : descs)
            if (QString::fromStdString(d.key) == key) return &d;
        return nullptr;
    };
    // Pass nodes in nodes_ order (the reflection order load_layout uses).
    QList<Graph_Link> chain;
    QString prev_output; // "<key>:<pin>" of the previous pass's frame
    for (const Graph_Node& node : nodes_) {
        if (node.kind == "params" || node.kind == "output" ||
            node.kind == "texture" || node.kind == "mesh" ||
            node.kind == "widget")
            continue;
        const auto* desc = find_desc(node.key);
        if (!desc) continue;
        QString out = node.key + ":" + QString::fromStdString(desc->output_pin);
        if (!prev_output.isEmpty() && !desc->input_textures.empty())
            chain.push_back({prev_output,
                             node.key + ":" +
                                 QString::fromStdString(desc->input_textures[0])});
        prev_output = out;
    }
    // Last pass -> show2d:frame (the viewport endpoint).
    if (!prev_output.isEmpty()) chain.push_back({prev_output, "show2d:frame"});
    links_ = chain;
}

bool Node_View::load_layout(const QString& scene_title, const QString& scene_root,
                            const scene::Runtime_Scene& scene) {
    scene_title_ = scene_title;
    scene_root_ = scene_root;
    current_scene_ = &scene;
    for (const auto& id : model_->allNodeIds()) model_->deleteNode(id);
    // Plan 05: the rings die WITH their NodeGraphicsObjects here — drop the
    // stale pointers so flash_pass's replace path never touches freed items.
    pass_flash_items_.clear();
    id_to_key_.clear();
    links_.clear();
    pipeline_error_.clear();

    QString path = QString::fromStdString(render_graph::graph_path(
        scene_title.toStdString(), scene_root.toStdString()));
    std::ifstream f(path.toStdString());
    if (!f.good()) {
        // Default plan layout: params left, passes in reflection order, output.
        float x = 0;
        nodes_.push_back({"params", "params", x, 40, "", "", "", 0, 0});
        x += 180;
        for (const auto& pass : scene.passes) {
            nodes_.push_back({QString::fromStdString(pass.graph_key),
                              pass.kind == scene::Scene_Kind::COMPUTE ? "compute" : "graphics",
                              x, 40, "", "", "", 0, 0});
            x += 180;
        }
        nodes_.push_back({"show2d", "output", x + 60, 40, "", "", "", 0, 0});
        derive_default_links();
        rebuild_scene();
        dirty_ = true;
        return true;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    render_graph::Graph_Json doc;
    if (!refl::parse_graph_json(doc, ss.str())) {
        pipeline_error_ = "invalid graph.json";
        return false;
    }
    if (doc.version != 0 && doc.version != render_graph::GRAPH_SCHEMA_VERSION) {
        pipeline_error_ = QString("unsupported graph schema version %1").arg(doc.version);
        return false;
    }
    for (const auto& n : doc.nodes) {
        Graph_Node node;
        node.key = QString::fromStdString(n.key);
        node.kind = QString::fromStdString(n.kind);
        node.x = n.x;
        node.y = n.y;
        node.file = QString::fromStdString(n.file);
        node.model = QString::fromStdString(n.model);
        node.filter = QString::fromStdString(n.filter);
        node.address = QString::fromStdString(n.address);
        node.width = n.width;
        node.height = n.height;
        node.value = n.value;
        nodes_.push_back(node);
    }
    for (const auto& l : doc.links) {
        links_.push_back({QString::fromStdString(l.from), QString::fromStdString(l.to)});
    }
    if (links_.empty()) derive_default_links(); // link-less graph.json: default chain
    rebuild_scene();
    return true;
}

void Node_View::set_scene(const scene::Runtime_Scene& scene) { current_scene_ = &scene; }

void Node_View::rebuild_scene() {
    const auto descs = descriptors();
    // (Re)create nodes in the model; QtNodes assigns NodeIds sequentially.
    for (const Graph_Node& node : nodes_) {
        QtNodes::NodeId id = model_->addNode(node.kind);
        if (id == QtNodes::InvalidNodeId) continue;
        id_to_key_[id] = node.key;
        model_->setNodeData(id, QtNodes::NodeRole::Caption, node.key);
        model_->setNodeData(id, QtNodes::NodeRole::Position, QPointF(node.x, node.y));

        // Interface snapshot on the delegate: texture inputs then uniform
        // blocks (the wireless ones), matching the descriptor's order.
        QStringList tex, uniforms;
        for (const auto& desc : descs) {
            if (QString::fromStdString(desc.key) != node.key) continue;
            for (const auto& t : desc.input_textures) tex << QString::fromStdString(t);
            for (const auto& u : desc.uniform_blocks) uniforms << QString::fromStdString(u);
        }
        if (node.kind == "params") {
            // One wireless OUTPUT per unique uniform block across the scene:
            // the app feeds every pass (Odin's Uniforms node).
            uniforms.clear();
            for (const auto& desc : descs)
                for (const auto& u : desc.uniform_blocks) {
                    QString name = QString::fromStdString(u);
                    if (!uniforms.contains(name)) uniforms << name;
                }
        }
        if (auto* delegate = model_->delegateModel<Scene_Delegate>(id)) {
            delegate->set_key(node.key);
            delegate->tex_inputs = tex;
            delegate->uniform_inputs = uniforms;
        }
        // Port counts mirror the delegate (In = tex + uniforms).
        unsigned int in = 0, out = 0;
        if (node.kind == "params") {
            out = unsigned(uniforms.size());
        } else if (node.kind == "output") {
            in = 1;
        } else if (node.kind == "texture") {
            out = 2; // texture + sampler pins
        } else if (node.kind == "mesh") {
            out = 1;
        } else if (node.kind != "widget") {
            in = unsigned(tex.size() + uniforms.size());
            out = 1;
        }
        model_->setNodeData(id, QtNodes::NodeRole::InPortCount, in);
        model_->setNodeData(id, QtNodes::NodeRole::OutPortCount, out);
        // Port captions live on the delegate; the node's size (and the
        // bounding rect the caption clips against) was computed at addNode
        // with 0 ports. Recompute now that the interface is set.
        model_->nodeUpdated(id);
    }
    // Links: resolve "<key>:<pin>" endpoints to node ids + port indices.
    // Mute connectionCreated during addConnection: rebuild_scene is the
    // source of truth here, re-validation would duplicate work (and the
    // producer-replacement modal must not pop during load).
    loading_ = true;
    for (const Graph_Link& link : links_) {
        // FROM keys: resource nodes carry the FULL resource key as their
        // node identity ("uimg:<path>:texture", "uobj:<path>:ModelVertex"),
        // so the serialized link may be node-key + ":sampler" (texture's
        // second pin) or exactly the node key (mesh). Try both.
        QString from_key = link.from;
        if (node_id(from_key) == QtNodes::InvalidNodeId)
            from_key = link.from.section(':', 0, -2);
        // TO keys may contain colons (pass keys "gfx:<path>"): the node key
        // is everything before the LAST ':' (the pin); a key with no pin
        // (show2d) stays whole.
        const int last_colon = link.to.lastIndexOf(':');
        QString to_key = last_colon > 0 && node_id(link.to.left(last_colon)) !=
                                                   QtNodes::InvalidNodeId
                             ? link.to.left(last_colon)
                             : link.to.section(':', 0, 0);
        QtNodes::NodeId from = node_id(from_key);
        QtNodes::NodeId to = node_id(to_key);
        if (from == QtNodes::InvalidNodeId || to == QtNodes::InvalidNodeId) {
            std::fprintf(stderr, "[rebuild] unresolved link: from='%s' to='%s'\n",
                         link.from.toUtf8().constData(), link.to.toUtf8().constData());
            continue;
        }
        uint32_t from_port = 0, to_port = 0;
        bool to_ok = false;
        // Resource links: the FROM pin follows the link suffix —
        // "uimg:<path>:sampler" connects the image node's sampler output
        // (port 1); ":texture"/mesh links use port 0.
        if (link.from.startsWith("uimg:"))
            from_port = link.from.endsWith(":sampler") ? 1 : 0;
        // Port resolution: "<key>:<pin>" — pin is an input name on `to`.
        for (const auto& desc : descs) {
            if (QString::fromStdString(desc.key) == to_key) {
                for (uint32_t i = 0; i < desc.input_textures.size(); ++i) {
                    if (link.to == QString::fromStdString(desc.key) + ":" +
                                        QString::fromStdString(desc.input_textures[i])) {
                        to_port = i;
                        to_ok = true;
                    }
                }
            }
        }
        if (!to_ok && !(link.to == to_key || link.to.startsWith(to_key + ":"))) continue;
        QtNodes::ConnectionId cid{from, from_port, to, to_port};
        bool exists = false;
        for (const auto& conn : model_->allConnectionIds(from)) {
            if (conn == cid) { exists = true; break; }
        }
        if (!exists) model_->addConnection(cid);
    }
    loading_ = false;
    refresh_wireless_marks();
    refresh_previews();
    // Reveal the graph after a rebuild: without this the view keeps the
    // old transform and a loaded layout can sit entirely off-screen.
    // Deferred: on first open the view still has 0x0 geometry (the panel
    // spring is running), so an immediate fit would be a no-op.
    QTimer::singleShot(250, this, [this] { view_->centerScene(); }); // after the panel spring
}

// Pass thumbnails: one pixmap per pass node, parked under the node title
// (Odin draws the preview inside the node body; here it rides on the node
// graphics object). Content = the 128px GPU downscale the submit blits
// every frame; the host hands over QImages on a slow tick.
void Node_View::set_previews(const QVector<QImage>& images) {
    previews_ = images;
    refresh_previews();
}

void Node_View::refresh_previews() {
    if (!scene_) return;
    // (Re)build the item set after structural changes.
    for (auto it = preview_items_.begin(); it != preview_items_.end();) {
        if (!id_to_key_.contains(it.key())) {
            scene_->removeItem(it.value());
            delete it.value();
            it = preview_items_.erase(it);
        } else {
            ++it;
        }
    }
    // Provenance labels die with their node: a stale rgba on a rebuilt node
    // would lie about the current pass output.
    for (auto it = provenance_items_.begin(); it != provenance_items_.end();) {
        if (!preview_items_.contains(it.key())) {
            scene_->removeItem(it.value());
            delete it.value();
            it = provenance_items_.erase(it);
        } else {
            ++it;
        }
    }
    if (!previews_enabled_) {
        for (auto& item : preview_items_) item->setVisible(false);
        return;
    }
    // Pass index by graph key: nodes_ keeps reflection order for pass nodes.
    QMap<QString, int> pass_index;
    int pi = 0;
    for (const Graph_Node& node : nodes_) {
        if (node.kind == "graphics" || node.kind == "compute")
            pass_index[node.key] = pi++;
    }
    for (auto it = id_to_key_.begin(); it != id_to_key_.end(); ++it) {
        int index = pass_index.value(it.value(), -1);
        bool show = index >= 0 && index < previews_.size() &&
                    !previews_[size_t(index)].isNull();
        QGraphicsPixmapItem*& item = preview_items_[it.key()];
        if (!show) {
            if (item) item->setVisible(false);
            continue;
        }
        if (!item) {
            item = new QGraphicsPixmapItem();
            item->setZValue(5.0); // over the node body, under the rings
            scene_->addItem(item);
        }
        item->setVisible(true);
        const QImage& img = previews_[size_t(index)];
        // plan10: flash the node only when its OUTPUT CHANGED (compare
        // against the last shown pixmap — a checksum of the new image).
        const qint64 fresh =
            img.sizeInBytes() * 31 + qint64(img.constBits()[0]) * 7 +
            qint64(img.constBits()[img.sizeInBytes() / 2]);
        if (item->pixmap().isNull() || item->data(0) != fresh) {
            if (!item->pixmap().isNull()) flash_pass(it.key()); // skip first paint
            item->setData(0, fresh);
        }
        item->setPixmap(QPixmap::fromImage(img));
        if (auto* ngo = scene_->nodeGraphicsObject(it.key())) {
            QRectF bounds = ngo->boundingRect();
            // Below the caption bar, full node width (Odin: window-aspect
            // squeeze restored by displaying at window aspect).
            qreal w = bounds.width() - 16;
            qreal h = qMax<qreal>(1.0, w * qreal(previews_[size_t(index)].height()) /
                                         qreal(previews_[size_t(index)].width()));
            item->setPos(-bounds.width() / 2 + 8, -bounds.height() / 2 + 30);
            QTransform t;
            t.scale(w / qreal(previews_[size_t(index)].width()),
                    h / qreal(previews_[size_t(index)].height()));
            item->setTransform(t);
        }
    }
}

// One pin-scene position for a node's port (geometry + node transform).
static QPointF port_scene_pos(QtNodes::BasicGraphicsScene& scene,
                              QtNodes::AbstractGraphModel& model,
                              QtNodes::NodeId id, QtNodes::PortType type,
                              QtNodes::PortIndex index) {
    (void)model; // position comes from the node geometry, not the model
    QTransform t;
    if (auto* ngo = scene.nodeGraphicsObject(id)) t = ngo->sceneTransform();
    return scene.nodeGeometry().portScenePosition(id, type, index, t);
}

// Pixel provenance per node (legacy imgui_nodes parity): Alt+click on a
// pass thumbnail samples that pass's preview QImage at the click point and
// parks a colored "r g b a" label under the thumbnail. Previews are 128px
// GPU-downscaled targets, so the value is approximate (the legacy app read
// full-resolution per pass); the graph panel refreshes them 1x/second.
bool Node_View::eventFilter(QObject* watched, QEvent* event) {
    if (watched == view_->viewport() && event->type() == QEvent::MouseButtonPress) {
        auto* me = static_cast<QMouseEvent*>(event);
        if (me->modifiers() & Qt::AltModifier && me->button() == Qt::LeftButton) {
            const QPointF sp = view_->mapToScene(me->position().toPoint());
            // Hit-test the preview items top-down; the topmost wins.
            QList<QGraphicsItem*> hits = scene_->items(sp);
            for (QGraphicsItem* it : hits) {
                auto* pix = dynamic_cast<QGraphicsPixmapItem*>(it);
                if (!pix) continue;
                QtNodes::NodeId id = preview_items_.key(pix, QtNodes::InvalidNodeId);
                if (id == QtNodes::InvalidNodeId) continue;
                // Node key → pass index (reflection order, like refresh_previews).
                QMap<QString, int> pass_index;
                int pi = 0;
                for (const Graph_Node& node : nodes_)
                    if (node.kind == "graphics" || node.kind == "compute")
                        pass_index[node.key] = pi++;
                int index = pass_index.value(id_to_key_.value(id), -1);
                if (index < 0 || index >= previews_.size()) break;
                const QImage& img = previews_[size_t(index)];
                // Click point in the item's pixmap coords (undo the fit scale).
                QPointF local = pix->mapFromScene(sp);
                int px = int(local.x() / pix->boundingRect().width() * img.width());
                int py = int(local.y() / pix->boundingRect().height() * img.height());
                px = std::clamp(px, 0, img.width() - 1);
                py = std::clamp(py, 0, img.height() - 1);
                QColor c = img.pixelColor(px, py);
                // Label under the thumbnail: values in the pixel's color.
                auto*& label = provenance_items_[id];
                if (!label) {
                    label = new QGraphicsTextItem();
                    label->setZValue(6.0);
                    scene_->addItem(label);
                }
                label->setPlainText(QString("%1  %2  %3  %4")
                                        .arg(c.redF(), 0, 'f', 3)
                                        .arg(c.greenF(), 0, 'f', 3)
                                        .arg(c.blueF(), 0, 'f', 3)
                                        .arg(c.alphaF(), 0, 'f', 3));
                label->setDefaultTextColor(c);
                QFont f = label->font();
                f.setPointSizeF(7.5);
                f.setFamily("JetBrains Mono");
                label->setFont(f);
                if (auto* ngo = scene_->nodeGraphicsObject(id)) {
                    QRectF b = ngo->boundingRect();
                    label->setPos(ngo->scenePos() + QPointF(-b.width() / 2 + 8,
                                                            b.height() / 2 - 14));
                }
                return true; // consumed: no node drag on Alt+click
            }
        }
    }
    return QWidget::eventFilter(watched, event);
}

// Parks the wireless ring items at the current pin positions. Uniform
// feed: the params node's uniform outputs broadcast (ball + expanding
// rings), every pass's uniform input receives (converging rings). Light
// blue, distinct from every node hue: the uniform feed reads as its own
// signal, not a node wire (Odin SG_WIRELESS_COLOR).
void Node_View::refresh_wireless_marks() {
    if (!scene_ || !current_scene_) return;
    // (Re)build the mark set after any structural change; parked each tick.
    QString scene_id = scene_title_ + "#" + QString::number(nodes_.size());
    bool rebuild = wireless_marks_.empty() || last_scene_ != scene_id;
    last_scene_ = scene_id;

    const auto descs = descriptors();
    QColor wireless(0x7a, 0xc8, 0xff); // light blue

    if (rebuild) {
        for (auto& m : wireless_marks_) {
            if (m.ring1) scene_->removeItem(m.ring1);
            if (m.ring2) scene_->removeItem(m.ring2);
            delete m.ring1;
            delete m.ring2;
        }
        wireless_marks_.clear();
        auto add_mark = [&](QtNodes::NodeId id, QtNodes::PortType type,
                            QtNodes::PortIndex idx, bool grow) {
            auto* r1 = new QGraphicsEllipseItem();
            auto* r2 = new QGraphicsEllipseItem();
            for (auto* ring : {r1, r2}) {
                QPen pen(wireless, 1.2);
                ring->setPen(pen);
                ring->setBrush(Qt::NoBrush);
                ring->setZValue(20.0); // over nodes and connections
                scene_->addItem(ring);
            }
            wireless_marks_.push_back({r1, r2, grow});
            // Park immediately at the right position.
            QPointF p = port_scene_pos(*scene_, *model_, id, type, idx);
            auto park = [p](QGraphicsEllipseItem* ring, double r) {
                ring->setRect(QRectF(p.x() - r, p.y() - r, 2 * r, 2 * r));
            };
            park(r1, 4.2);
            park(r2, 4.2);
        };
        for (const Graph_Node& node : nodes_) {
            QtNodes::NodeId id = node_id(node.key);
            if (id == QtNodes::InvalidNodeId) continue;
            if (node.kind == "params") {
                // Broadcast: one mark per uniform output port.
                unsigned int outs_mark = model_->nodeData(id, QtNodes::NodeRole::OutPortCount).value<unsigned int>();
                for (uint32_t i = 0; i < outs_mark; ++i)
                    add_mark(id, QtNodes::PortType::Out, QtNodes::PortIndex(i), true);
            } else {
                // Receive: uniform input ports sit after the texture inputs.
                for (const auto& desc : descs) {
                    if (QString::fromStdString(desc.key) != node.key) continue;
                    uint32_t base = uint32_t(desc.input_textures.size());
                    for (uint32_t i = 0; i < desc.uniform_blocks.size(); ++i)
                        add_mark(id, QtNodes::PortType::In, QtNodes::PortIndex(base + i), false);
                }
            }
        }
    }

    // Animate: two staggered rings per mark on a 1.6 s loop. Emit expands
    // outward and fades; receive converges inward and brightens.
    double now = double(marks_clock_.elapsed()) / 1000.0;
    size_t mark_i = 0;
    for (const Graph_Node& node : nodes_) {
        QtNodes::NodeId id = node_id(node.key);
        if (id == QtNodes::InvalidNodeId) continue;
        auto park_set = [&](QtNodes::PortType type, QtNodes::PortIndex idx, bool grow) {
            if (mark_i >= wireless_marks_.size()) return;
            Wireless_Mark& m = wireless_marks_[mark_i++];
            QPointF p = port_scene_pos(*scene_, *model_, id, type, idx);
            double phase = std::fmod(now * 0.625, 1.0);
            const double base_r = 4.2, span = 9.0;
            for (int k = 0; k < 2; ++k) {
                double t = std::fmod(phase + k * 0.5, 1.0);
                double r = grow ? base_r + span * t : base_r + span - span * t;
                double alpha = grow ? 0.9 * (1.0 - t) : 0.3 + 0.6 * t;
                auto* ring = k == 0 ? m.ring1 : m.ring2;
                QPen pen(wireless, 1.2);
                pen.setColor(QColor(wireless.red(), wireless.green(), wireless.blue(),
                                    int(alpha * 255)));
                ring->setPen(pen);
                ring->setRect(QRectF(p.x() - r, p.y() - r, 2 * r, 2 * r));
                ring->setVisible(true);
            }
        };
        if (node.kind == "params") {
            unsigned int outs = model_->nodeData(id, QtNodes::NodeRole::OutPortCount).value<unsigned int>();
            for (uint32_t i = 0; i < outs; ++i)
                park_set(QtNodes::PortType::Out, QtNodes::PortIndex(i), true);
        } else {
            for (const auto& desc : descs) {
                if (QString::fromStdString(desc.key) != node.key) continue;
                uint32_t base = uint32_t(desc.input_textures.size());
                for (uint32_t i = 0; i < desc.uniform_blocks.size(); ++i)
                    park_set(QtNodes::PortType::In, QtNodes::PortIndex(base + i), false);
            }
        }
    }
}

bool Node_View::save_layout(const QString& scene_title, const QString& scene_root) {
    // Sync node positions from the model into nodes_ (single source for JSON).
    for (Graph_Node& node : nodes_) {
        QtNodes::NodeId id = node_id(node.key);
        if (id == QtNodes::InvalidNodeId) continue;
        QPointF p = model_->nodeData(id, QtNodes::NodeRole::Position).toPointF();
        node.x = float(p.x());
        node.y = float(p.y());
    }
    // Links: rebuild from model connections, mapping ids back to keys with
    // full "<key>:<pin>" endpoints. Pass producers always emit "frame"
    // (graphics) or "out_tex" (compute) — the plan's output pins; consumers
    // use their descriptor input name; show2d keeps ":frame" so plan_build
    // still sees the viewport endpoint after a reload.
    // Resource links keep their authored TO endpoints: the sampler link's
    // ":<sampler_name>" suffix is what plan_build's SAMPLER route matches.
    const QList<Graph_Link> prev_links = links_;
    links_.clear();
    const auto descs = descriptors();
    for (const auto& from_id : model_->allNodeIds())
    for (const auto& cid : model_->allConnectionIds(from_id)) {
        QString from_key = node_key(cid.outNodeId);
        QString to_key = node_key(cid.inNodeId);
        if (from_key.isEmpty() || to_key.isEmpty()) continue;
        QString from_pin = from_key;
        QString to_pin = to_key;
        for (const auto& desc : descs) {
            if (QString::fromStdString(desc.key) == from_key)
                from_pin = from_key + ":" + QString::fromStdString(desc.output_pin);
            if (QString::fromStdString(desc.key) == to_key &&
                cid.inPortIndex < desc.input_textures.size())
                to_pin = to_key + ":" +
                         QString::fromStdString(desc.input_textures[cid.inPortIndex]);
        }
        // Same resource-pin mapping as connectionCreated: texture node's
        // two pins route as :texture/:sampler; mesh pin as :ModelVertex.
        // The SAMPLER link keeps its original ":sampler" TO endpoint (the
        // plan's SAMPLER route matches by SamplerState name, and both
        // resource links share the same visual input pin, so the model
        // roundtrip alone can't distinguish them).
        QString sampler_to;
        for (const Graph_Link& l : prev_links) {
            if (l.from.startsWith("uimg:") && l.from.endsWith(":sampler") &&
                l.from.section(':', 0, -2) == from_key)
                sampler_to = l.to;
        }
        if (from_key.startsWith("uimg:")) {
            const QString path = from_key.section(':', 1, -2);
            from_pin = cid.outPortIndex == 1 ? "uimg:" + path + ":sampler"
                                             : "uimg:" + path + ":texture";
            if (cid.outPortIndex == 1 && !sampler_to.isEmpty()) to_pin = sampler_to;
        } else if (from_key.startsWith("uobj:")) {
            const QString path = from_key.section(':', 1, -2);
            from_pin = "uobj:" + path + ":ModelVertex";
        }
        if (to_key == "show2d") to_pin = to_key + ":frame";
        bool dup = false;
        for (const Graph_Link& existing : links_)
            if (existing.from == from_pin && existing.to == to_pin) { dup = true; break; }
        if (!dup) links_.push_back({from_pin, to_pin});
    }

    QJsonArray nodes_json;
    for (const Graph_Node& node : nodes_) {
        QJsonObject nj{{"key", node.key}, {"kind", node.kind},
                       {"x", node.x}, {"y", node.y}};
        if (!node.file.isEmpty()) nj["file"] = node.file;
        if (!node.model.isEmpty()) nj["model"] = node.model;
        if (!node.filter.isEmpty() && node.filter != "linear") nj["filter"] = node.filter;
        if (!node.address.isEmpty() && node.address != "clamp") nj["address"] = node.address;
        if (node.width > 0) nj["width"] = node.width;
        if (node.height > 0) nj["height"] = node.height;
        if (node.value != 0) nj["value"] = node.value;
        nodes_json.append(nj);
    }
    QJsonArray links_json;
    for (const Graph_Link& link : links_)
        links_json.append(QJsonObject{{"from", link.from}, {"to", link.to}});
    const QJsonDocument out(QJsonObject{
        {"version", render_graph::GRAPH_SCHEMA_VERSION},
        {"scene", scene_title},
        {"nodes", nodes_json},
        {"links", links_json}});
    const QByteArray bytes = out.toJson(QJsonDocument::Indented);

    std::string path = render_graph::graph_path(scene_title.toStdString(),
                                                scene_root.toStdString());
    std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc);
        if (!f.good()) return false;
        f.write(bytes.constData(), bytes.size());
    }
    // Atomic swap: a truncated direct write would poison the scene forever.
    std::remove(path.c_str());
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        std::remove(tmp.c_str());
        return false;
    }
    dirty_ = false;
    return true;
}

Confirm_Dialog::Confirm_Dialog(const QString& message, QWidget* parent) : QDialog(parent) {
    setWindowTitle("confirm");
    auto* layout = new QVBoxLayout(this);
    layout->addWidget(new QLabel(message));
    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    connect(buttons, &QDialogButtonBox::accepted, this, [this] { apply_ = true; accept(); });
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    layout->addWidget(buttons);
}

} // namespace graph_editor
