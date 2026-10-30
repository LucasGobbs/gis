// Graph editor implementation over QtNodes (DataFlowGraphModel): nodes with
// reflection-derived pins, graph.json load/save (atomic), links validated by
// plan_build before accept (invalid keeps the last valid pipeline, matching
// the Odin flow), confirmation modal for producer-replacing edges.
#include "graph_editor.hpp"
#include "gfx/render_graph/refl.hpp"
#include "notify.hpp"
#include <algorithm>
#include <cmath>
#include "theme.hpp"

#include "QtNodes/internal/NodeGraphicsObject.hpp"
#include "QtNodes/internal/StyleCollection.hpp"
#include "QtNodes/internal/DefaultNodePainter.hpp"
#include "QtNodes/internal/BasicGraphicsScene.hpp"
#include "QtNodes/internal/AbstractNodeGeometry.hpp"
#include <QHash>
#include "QtNodes/internal/ConnectionGraphicsObject.hpp"
#include "shell.hpp" // reduced_motion()

#include <QGraphicsProxyWidget>
#include <QPainter>
#include <QPropertyAnimation>
#include <QPushButton>
#include <QSet>
#include <QStyleOptionGraphicsItem>
#include <QTimer>


#include <QDialogButtonBox>
#include <QFileDialog>
#include <QFileInfo>
#include <QMenu>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QEvent>
#include <QtGui/qevent.h>
#include <QScrollBar>
#include <cstdio>
#include <QImage>
#include <QLabel>
#include <QMouseEvent>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QToolButton>

#include <fstream>
#include <sstream>

#include <QtNodes/internal/ConnectionIdUtils.hpp>
#include <QtNodes/internal/NodeStyle.hpp>
#include <QtNodes/internal/ConnectionStyle.hpp>

namespace graph_editor {

// Resource kind and icon per node type. Unknown kinds (widget, anything new)
// fall back to Neutral + sliders icon.
static theme::Resource_Kind resource_kind_for(const QString& kind) {
    if (kind == "settings") return theme::Resource_Kind::Settings;
    if (kind == "compute") return theme::Resource_Kind::Compute;
    if (kind == "graphics") return theme::Resource_Kind::Graphics;
    if (kind == "output") return theme::Resource_Kind::Output;
    if (kind == "texture") return theme::Resource_Kind::Texture;
    if (kind == "mesh") return theme::Resource_Kind::Mesh;
    return theme::Resource_Kind::Neutral;
}

static const char* icon_for(const QString& kind) {
    if (kind == "settings") return ":/qlementine/icons/16/navigation/settings.svg";
    if (kind == "compute") return ":/qlementine/icons/16/hardware/cpu.svg";
    if (kind == "graphics") return ":/qlementine/icons/16/hardware/gpu.svg";
    if (kind == "output") return ":/qlementine/icons/16/hardware/screen.svg";
    if (kind == "texture") return ":/qlementine/icons/16/file/picture.svg";
    if (kind == "mesh") return ":/qlementine/icons/16/shape/cube.svg";
    return ":/qlementine/icons/16/navigation/sliders-horizontal.svg";
}

// Draws the kind icon at the caption's left edge. Pixmaps cached per
// kind+color; the color is part of the key so theme switches repaint.
class Node_Painter : public QtNodes::DefaultNodePainter {
public:
    void paint(QPainter* painter, QtNodes::NodeGraphicsObject& ngo) const override {
        const QSize size = ngo.nodeScene()->nodeGeometry().size(ngo.nodeId());
        const QString kind = ngo.graphModel().nodeData(ngo.nodeId(), QtNodes::NodeRole::Type).toString();
        const QRectF cap = ngo.nodeScene()->nodeGeometry().captionRect(ngo.nodeId());
        const QColor color = theme::resource_rgb(resource_kind_for(kind));
        // Depth: soft drop shadow under the node body.
        painter->setPen(Qt::NoPen);
        painter->setBrush(QColor(0, 0, 0, 70));
        painter->drawRoundedRect(QRectF(2, 4, size.width(), size.height()), 3, 3);
        QtNodes::DefaultNodePainter::paint(painter, ngo);
        // Kind at a glance: colored bar on the left edge.
        painter->setBrush(color);
        painter->drawRoundedRect(QRectF(0, 0, 4, size.height()), 2, 2);
        // Selection glow: outer halo in the kind hue.
        if (ngo.isSelected()) {
            QColor halo = color;
            halo.setAlpha(110);
            painter->setPen(QPen(halo, 4));
            painter->setBrush(Qt::NoBrush);
            painter->drawRoundedRect(QRectF(-2, -2, size.width() + 4, size.height() + 4), 5, 5);
        }
        const QString key = kind + color.name();
        auto it = cache_.find(key);
        if (it == cache_.end())
            it = cache_.insert(key, theme::tinted_icon(icon_for(kind), color, 14).pixmap(14, 14));
        painter->drawPixmap(QPointF(cap.left() + 2, cap.center().y() - 7), it.value());
    }

private:
    mutable QHash<QString, QPixmap> cache_;
};

// In-node pass thumbnail (graphics/compute): the 128px GPU downscale plus an
// rgba readout. Alt+Left samples the pixel under the cursor; any other press
// is ignored so the node still drags.
namespace {
class Preview_Widget : public QWidget {
public:
    Preview_Widget() {
        setFixedSize(144, 160);
        image_ = new QLabel(this);
        image_->setGeometry(0, 0, 144, 144);
        image_->setAlignment(Qt::AlignCenter);
        image_->setStyleSheet("background: black;");
        rgba_ = new QLabel(this);
        rgba_->setGeometry(0, 144, 144, 16);
        QFont f = rgba_->font();
        f.setFamily("JetBrains Mono");
        f.setPointSizeF(7.5);
        rgba_->setFont(f);
    }
    // True iff content changed vs a previous image (drives the flash).
    bool set_image(const QImage& img) {
        const qint64 sum = checksum(img);
        const bool flash = had_image_ && sum != sum_;
        img_ = img;
        sum_ = sum;
        had_image_ = true;
        image_->setPixmap(QPixmap::fromImage(img).scaled(144, 144, Qt::KeepAspectRatio,
                                                         Qt::SmoothTransformation));
        rgba_->clear();
        return flash;
    }

protected:
    void mousePressEvent(QMouseEvent* event) override {
        if (img_.isNull() || event->button() != Qt::LeftButton ||
            !(event->modifiers() & Qt::AltModifier)) {
            event->ignore();
            return;
        }
        // Letterboxed: map the click through the aspect-preserving fit.
        const QPointF p = event->position();
        const double s = std::min(144.0 / img_.width(), 144.0 / img_.height());
        const double ox = (144.0 - img_.width() * s) / 2, oy = (144.0 - img_.height() * s) / 2;
        const int x = std::clamp(int((p.x() - ox) / s), 0, img_.width() - 1);
        const int y = std::clamp(int((p.y() - oy) / s), 0, img_.height() - 1);
        const QColor c = img_.pixelColor(x, y);
        rgba_->setText(QString("%1 %2 %3 %4")
                           .arg(c.redF(), 0, 'f', 3)
                           .arg(c.greenF(), 0, 'f', 3)
                           .arg(c.blueF(), 0, 'f', 3)
                           .arg(c.alphaF(), 0, 'f', 3));
        rgba_->setStyleSheet(QString("color: %1;").arg(c.name()));
        event->accept();
    }

private:
    static qint64 checksum(const QImage& img) {
        if (img.isNull()) return 0;
        const uchar* bits = img.constBits();
        const qint64 n = img.sizeInBytes();
        return n * 31 + qint64(bits[0]) * 7 + qint64(bits[n / 2]);
    }
    QImage img_;
    qint64 sum_ = 0;
    bool had_image_ = false;
    QLabel* image_ = nullptr;
    QLabel* rgba_ = nullptr;
};
} // namespace

namespace {
// One-shot fading outline (link halo, pass ring). The animation is a child of
// the item: whoever deletes the item (replaced flash, node sweep, scene clear)
// also stops the fade, so no external guard is needed.
class Fade_Item : public QGraphicsObject {
public:
    Fade_Item(const QPainterPath& path, const QPen& pen, int duration_ms, QGraphicsItem* parent)
        : QGraphicsObject(parent), path_(path), pen_(pen) {
        anim_ = new QPropertyAnimation(this, "opacity", this);
        anim_->setDuration(duration_ms);
        anim_->setStartValue(1.0);
        anim_->setEndValue(0.0);
        anim_->setEasingCurve(QEasingCurve::OutCubic);
        connect(anim_, &QAbstractAnimation::finished, this, &QObject::deleteLater);
        anim_->start();
    }
    QPropertyAnimation* animation() const { return anim_; }
    QRectF boundingRect() const override {
        const qreal w = pen_.widthF() / 2;
        return path_.boundingRect().adjusted(-w, -w, w, w);
    }
    void paint(QPainter* p, const QStyleOptionGraphicsItem*, QWidget*) override {
        p->setPen(pen_);
        p->setBrush(Qt::NoBrush);
        p->drawPath(path_);
    }

private:
    QPainterPath path_;
    QPen pen_;
    QPropertyAnimation* anim_ = nullptr;
};
} // namespace

// Pass nodes only (output/texture/mesh/settings stay plain). Lazy: created on
// first request, cached in preview_, dropped when QtNodes deletes the node.
QWidget* Scene_Delegate::embeddedWidget() {
    if (widget_) return widget_;
    if ((kind_ == "graphics" || kind_ == "compute") && want_preview_) {
        widget_ = new Preview_Widget();
    } else if ((kind_ == "texture" || kind_ == "mesh") && !key_.startsWith("uimg:target:")) {
        // Swap button: text = file basename, click opens the picker.
        auto* btn = new QPushButton(QFileInfo(key_.section(':', 1, -2)).fileName());
        btn->setToolTip(key_.section(':', 1, -2));
        btn->setFixedWidth(144);
        QObject::connect(btn, &QPushButton::clicked, btn, [this] { if (on_swap) on_swap(); });
        widget_ = btn;
    }
    return widget_;
}

bool Scene_Delegate::set_preview(const QImage& img) {
    auto* w = dynamic_cast<Preview_Widget*>(embeddedWidget());
    return w && w->set_image(img);
}

// ---- Scene_Delegate: kind-tagged node with typed pins ----

Scene_Delegate::Scene_Delegate(QString kind, QString key, bool want_preview)
    : kind_(std::move(kind)), key_(std::move(key)), want_preview_(want_preview) {
    apply_theme();
}

Scene_Delegate::~Scene_Delegate() {
    // Widget never embedded (no proxy took ownership): free it with the delegate.
    if (widget_ && !widget_->parentWidget()) widget_->deleteLater();
}

// plan13: the editor skin drives the node look — re-derived on theme
// switch (Node_View::apply_theme re-styles every live delegate).
void Scene_Delegate::apply_theme() {
    // Kind at a GLANCE: boundary + gradient hues per node type (see resource_kind_for).
    QtNodes::NodeStyle st = nodeStyle();
    const theme::Resource_Kind rk = resource_kind_for(kind_);
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
    const bool out = type == QtNodes::PortType::Out;
    if (kind_ == "settings") return out ? unsigned(uniform_outputs.size()) : 0u;
    if (kind_ == "output") return out ? 0u : 1u;
    if (kind_ == "texture") return out ? 2u : 0u; // texture + sampler
    if (kind_ == "mesh") return out ? 1u : 0u;
    if (kind_ == "graphics" || kind_ == "compute") return out ? 1u : unsigned(inputs.size());
    return 0u;
}

QString Scene_Delegate::uniform_label(const QString& block) {
    return block == "Uniforms" ? QStringLiteral("SceneUniforms") : block;
}

QtNodes::NodeDataType Scene_Delegate::dataType(QtNodes::PortType type,
                                               QtNodes::PortIndex index) const {
    // QtNodes connects only equal ids: this id IS the wire kind.
    if (type == QtNodes::PortType::Out) {
        if (kind_ == "texture")
            return index == 1 ? QtNodes::NodeDataType{"sampler", "sampler"}
                              : QtNodes::NodeDataType{"texture", "texture"};
        if (kind_ == "mesh") return {"model", "vertex"};
        if (kind_ == "settings") return {"uniform", "uniform"};
        return {"texture", "frame"}; // pass output
    }
    if (kind_ == "output") return {"texture", "frame"};
    const int i = int(index);
    if (i < 0 || i >= int(inputs.size())) return {"texture", "frame"};
    const Pin& p = inputs[i];
    switch (p.type) {
    case Pin_Type::Texture: return {"texture", p.name};
    case Pin_Type::Sampler: return {"sampler", p.name};
    case Pin_Type::Model: return {"model", "model"};
    case Pin_Type::Uniform: return {"uniform", "uniform"};
    }
    return {"texture", "frame"};
}

// Port captions drive the node width (maxPortsTextAdvance), so titles and pins fit.
QString Scene_Delegate::portCaption(QtNodes::PortType type, QtNodes::PortIndex index) const {
    const int i = int(index);
    if (type == QtNodes::PortType::In) {
        if (kind_ == "output") return "frame";
        if (i < 0 || i >= int(inputs.size())) return {};
        const Pin& p = inputs[i];
        switch (p.type) {
        case Pin_Type::Texture:
        case Pin_Type::Sampler: return p.name;
        case Pin_Type::Model: return "ModelVertex";
        case Pin_Type::Uniform: return uniform_label(p.name) + " (uniform)";
        }
        return {};
    }
    if (kind_ == "settings")
        return i < int(uniform_outputs.size()) ? uniform_label(uniform_outputs[i]) + " (uniform)"
                                               : QString();
    if (kind_ == "texture") return i == 1 ? "sampler" : "texture";
    if (kind_ == "mesh") return "vertex";
    return "frame";
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
    const QStringList kinds = {"settings", "graphics", "compute", "output",
                               "texture", "mesh", "widget"};
    for (const QString& kind : kinds) {
    registry->registerModel<Scene_Delegate>(
        [this, kind] { return std::make_unique<Scene_Delegate>(kind, pending_key_, pending_preview_); }, kind);
    }
    model_ = new QtNodes::DataFlowGraphModel(registry);
    scene_ = new QtNodes::DataFlowGraphicsScene(*model_, this);
    scene_->setNodePainter(std::make_unique<Node_Painter>());
    view_ = new Graph_View(this);
    view_->setScene(scene_);
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->addLayout(build_toolbar());
    layout->addWidget(view_);

    // Wireless uniform marks: a 33 ms timer parks the ring items on a
    // ~1.6 s loop (emitter expands, receiver converges — the Odin feed).
    marks_clock_.start();
    marks_timer_ = new QTimer(this);
    marks_timer_->setInterval(33);
    connect(marks_timer_, &QTimer::timeout, this, &Node_View::refresh_wireless_marks);
    marks_timer_->start();

    connect_model_signals();
    // Canvas context menu: create passes/combines (writes .slang into the
    // scene dir — the watcher rebuilds and the next resync picks the new
    // pass up) and user resources (image/mesh/target) like imgui_nodes.
    view_->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(view_, &QWidget::customContextMenuRequested, this, &Node_View::show_canvas_menu);
}

// Toolbar: preview toggle and fit on the left, fullscreen on the right.
QHBoxLayout* Node_View::build_toolbar() {
    auto* bar = new QHBoxLayout;
    bar->setContentsMargins(6, 4, 6, 4);
    auto* preview_btn = new QToolButton(this);
    preview_btn->setObjectName("graphPreviewToggle");
    preview_btn->setText(tr("Show preview"));
    preview_btn->setCheckable(true);
    preview_btn->setChecked(previews_enabled_);
    preview_btn->setIcon(theme::tinted_icon(":/qlementine/icons/24/action/eye.svg",
                                            QColor(theme::text_primary()), shell::kToolbarIcon));
    connect(preview_btn, &QToolButton::toggled, this,
            [this](bool on) { set_previews_enabled(on); });
    auto* fit_btn = new QToolButton(this);
    fit_btn->setText(tr("Fit"));
    fit_btn->setIcon(theme::tinted_icon(":/qlementine/icons/24/page/zoom-fit-screen.svg",
                                        QColor(theme::text_primary()), shell::kToolbarIcon));
    connect(fit_btn, &QToolButton::clicked, view_, [this] { view_->fit_all(); });
    bar->addWidget(preview_btn);
    bar->addWidget(fit_btn);
    bar->addStretch();
    auto* fs_btn = new QToolButton(this);
    fs_btn->setObjectName("graphFullscreen");
    fs_btn->setCheckable(true);
    fs_btn->setToolTip(tr("Fullscreen"));
    connect(fs_btn, &QToolButton::toggled, this, [this](bool on) {
        set_fullscreen_state(on);
        emit fullscreen_toggled(on);
        // The panel animates (180 ms): refit once the viewport has its final size.
        QTimer::singleShot(300, this, [this] { view_->fit_all(); });
    });
    bar->addWidget(fs_btn);
    set_fullscreen_state(false);
    return bar;
}

void Node_View::connect_model_signals() {
    // Node moved: track positions for save_layout + autosave contract.
    // Silent while rebuild/load repopulates the model (not a user edit).
    connect(model_, &QtNodes::AbstractGraphModel::nodePositionUpdated, this, [this](QtNodes::NodeId) {
        if (!loading_) dirty_ = true;
    });
    connect(model_, &QtNodes::AbstractGraphModel::connectionCreated, this,
            &Node_View::on_connection_created);
    connect(model_, &QtNodes::AbstractGraphModel::connectionDeleted, this,
            &Node_View::on_connection_deleted);
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
    connect(scene_, &QtNodes::BasicGraphicsScene::nodeContextMenu, this,
            [this](QtNodes::NodeId id, const QPointF&) { show_node_menu(id); });
}

// Validates the candidate graph (links_) with plan_build; err is the reason on failure.
bool Node_View::links_valid(std::string& err) const {
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
    bool ok = false;
    render_graph::Plan plan = render_graph::plan_build(descriptors(), doc, err, ok);
    render_graph::plan_destroy(plan);
    return ok;
}

// Connection lifecycle: validate the resulting graph with plan_build;
// invalid links are reverted (the last valid pipeline keeps running, the
// Odin contract). Producer-replacing links ask for confirmation first.
void Node_View::on_connection_created(QtNodes::ConnectionId id) {
    if (loading_) return; // rebuild_scene's own links; also suppresses the modal
    const QString from_key = node_key(id.outNodeId);
    const QString to_key = node_key(id.inNodeId);
    // settings is wireless: its outputs broadcast by name, never wire.
    if (from_key.isEmpty() || to_key.isEmpty() || from_key == "settings") {
        model_->deleteConnection(id);
        return;
    }
    // Endpoint strings: "<key>:<pin>" using the descriptor input names.
    const QString from_pin = output_endpoint(id.outNodeId, id.outPortIndex);
    const QString to_pin = input_endpoint(id.inNodeId, id.inPortIndex);
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
    links_.push_back({from_pin, to_pin});
    std::string err;
    if (!links_valid(err)) {
        model_->deleteConnection(id); // revert: invalid link never lands
        notify::notify(notify::Kind::ERROR_, QString::fromStdString(err));
        return;
    }
    dirty_ = true;
    flash_link(id); // plan10: one-shot halo on the new wire
    emit pipeline_changed();
}

void Node_View::on_connection_deleted(QtNodes::ConnectionId id) {
    if (loading_) return; // rebuild sweep: links_ stays the source of truth
    // Endpoint strings must match links_ format "<key>:<pin>" (same
    // mapping as on_connection_created / save_layout).
    const QString from_pin = output_endpoint(id.outNodeId, id.outPortIndex);
    const QString to_pin = input_endpoint(id.inNodeId, id.inPortIndex);
    for (long i = long(links_.size()) - 1; i >= 0; --i) {
        if (links_[size_t(i)].from == from_pin && links_[size_t(i)].to == to_pin) links_.removeAt(i);
    }
    dirty_ = true;
    emit pipeline_changed();
}

void Node_View::add_node_at(Graph_Node node, const QPointF& scene_pos) {
    node.x = float(scene_pos.x());
    node.y = float(scene_pos.y());
    nodes_.push_back(node);
    dirty_ = true;
    rebuild_scene();
}

// Real asset pick: the node key embeds the path the runtime loads; a fake
// path would create a dead node (bind-site miss).
void Node_View::add_resource_node(bool mesh, bool skybox, const QPointF& scene_pos) {
    const char* caption = mesh ? "pick mesh" : "pick image";
    const QString filter = mesh ? "Models (*.glb *.gltf)" : "Images (*.png *.jpg *.jpeg *.bmp)";
    const QString start_dir = skybox ? "assets/skybox" : "assets";
    const QString path = QFileDialog::getOpenFileName(this, caption, start_dir, filter);
    if (path.isEmpty()) return;
    const QFileInfo info(path);
    Graph_Node node;
    node.kind = mesh ? "mesh" : "texture";
    node.key = mesh ? QString("uobj:%1:ModelVertex").arg(info.filePath())
                    : QString("uimg:%1:texture").arg(info.filePath());
    if (skybox) {
        // Equirect convention check (existing assets/skybox images are
        // 2:1); warn but still create.
        QImage probe(info.filePath());
        if (probe.width() > 0 && probe.width() != 2 * probe.height())
            notify::notify(notify::Kind::WARN,
                           "not equirectangular (expected 2:1); sampling will look stretched");
    }
    add_node_at(node, scene_pos);
}

void Node_View::show_canvas_menu(const QPoint& pos) {
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
    const QPointF spos = view_->mapToScene(pos);
    if (chosen == image || chosen == skybox || chosen == mesh) {
        add_resource_node(chosen == mesh, chosen == skybox, spos);
        return;
    }
    // "render target": valid without a file (the plan creates it).
    Graph_Node node;
    node.kind = "texture";
    node.key = "uimg:target:new_target:texture";
    add_node_at(node, spos);
}

// Node context menu (right-click on a NODE): delete for user resource
// nodes and combine passes (removes the .slang — the watcher resyncs).
// Derived nodes (settings/show2d/reflection passes) are not deletable.
void Node_View::show_node_menu(QtNodes::NodeId id) {
    const QString key = node_key(id);
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
        swap_resource(key);
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
// (grid/nodes/wires) + every live Scene_Delegate. Called from
// Shell::apply_chrome_theme on every theme switch. Derived from the
// theme:: tokens (no per-theme literals): surfaces from chrome, text tiers
// from the chrome palette, selection halo = safelight, semantic states
// from the token layer.
void Node_View::apply_theme() {
    // The StyleCollection pass is always safe; the live-delegate loop needs model_.
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
    view_style.CoarseGridColor = QColor(accent.red(), accent.green(), accent.blue(), 34);
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
    const QPainterPath halo = cgo->shape(); // stroked wire path (qt6: shape)
    if (halo.isEmpty()) return;
    QColor c = theme::success_rgb();
    c.setAlpha(160);
    QPen pen(c, 6.0);
    pen.setCapStyle(Qt::RoundCap);
    auto* flash = new Fade_Item(halo, pen, 400, nullptr);
    flash->setZValue(8.0); // over wires (2), under the wireless rings (20)
    scene_->addItem(flash); // scene owns it; it deletes itself after the fade
}

// Test hook: advances every live flash to `elapsed_ms` (setCurrentTime emits
// synchronously, so tests need no event loop). Returns how many were running.
int Node_View::debug_step_flashes(int elapsed_ms) {
    int running = 0;
    // items() is a copy: finishing a fade schedules deleteLater, never a sync delete.
    for (QGraphicsItem* item : scene_->items()) {
        auto* fade = dynamic_cast<Fade_Item*>(item);
        if (!fade || fade->animation()->state() != QAbstractAnimation::Running) continue;
        ++running;
        fade->animation()->setCurrentTime(elapsed_ms);
    }
    return running;
}

// Test hook: port captions of the node whose key matches (empty if none).
QStringList Node_View::debug_ports(const QString& key, bool inputs) const {
    QStringList out;
    for (const auto& id : model_->allNodeIds()) {
        auto* d = model_->delegateModel<Scene_Delegate>(id);
        if (!d || d->key() != key) continue;
        const auto type = inputs ? QtNodes::PortType::In : QtNodes::PortType::Out;
        for (unsigned int i = 0; i < d->nPorts(type); ++i) out << d->portCaption(type, i);
        break;
    }
    return out;
}

// plan10: a ring around a pass node that fades when the pass output
// CHANGES (not every frame). One per node; a new flash replaces the old.
void Node_View::flash_pass(QtNodes::NodeId id) {
    if (!scene_ || shell::reduced_motion()) return;
    delete pass_flash_items_.take(id).data(); // the old fade dies with its child animation
    auto* ngo = scene_->nodeGraphicsObject(id);
    if (!ngo) return;
    QPainterPath ring;
    ring.addEllipse(ngo->boundingRect().adjusted(-6, -6, 6, 6));
    QColor c = theme::safelight_rgb();
    c.setAlpha(140);
    auto* fade = new Fade_Item(ring, QPen(c, 2.0), 600, ngo); // NGO child: dies with the node
    fade->setZValue(6.0); // under the wireless rings, over previews
    pass_flash_items_[id] = fade;
}

// Writes a new .slang file and toasts the result.
static void write_new_slang(const QString& path, const QString& body) {
    const QByteArray bytes = body.toUtf8();
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text) || f.write(bytes) != bytes.size()) {
        notify::notify(notify::Kind::ERROR_, "could not write " + path);
        return;
    }
    notify::notify(notify::Kind::INFO, "created " + path);
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
        write_new_slang(path, body);
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
    if (QFileInfo::exists(path)) {
        notify::notify(notify::Kind::ERROR_, "no free combine name for " + base);
        return;
    }
    write_new_slang(path, body);
}

std::vector<render_graph::Pass_Descriptor> Node_View::descriptors() const {
    return current_scene_ ? scene::scene_pass_descriptors(*current_scene_)
                          : std::vector<render_graph::Pass_Descriptor>{};
}

// Descriptor for a node key, or nullptr (not a reflected pass).
static const render_graph::Pass_Descriptor* find_desc(
    const std::vector<render_graph::Pass_Descriptor>& descs, const QString& key) {
    for (const auto& d : descs)
        if (QString::fromStdString(d.key) == key) return &d;
    return nullptr;
}

// Uniform pins follow textures, non-empty samplers and the model pin (pins_for order).
static uint32_t uniform_port_base(const render_graph::Pass_Descriptor& d) {
    uint32_t n = uint32_t(d.input_textures.size());
    for (const auto& s : d.input_samplers)
        if (!s.empty()) ++n;
    if (d.uses_model) ++n;
    return n;
}

QString Node_View::node_key(QtNodes::NodeId id) const {
    return id_to_key_.contains(id) ? id_to_key_[id] : QString();
}

QString Node_View::input_endpoint(QtNodes::NodeId id, QtNodes::PortIndex port) const {
    const QString key = node_key(id);
    if (key == "show2d") return "show2d:frame";
    auto* d = model_->delegateModel<Scene_Delegate>(id);
    if (!d || port >= d->inputs.size()) return {};
    return key + ":" + d->inputs[port].name;
}

QString Node_View::output_endpoint(QtNodes::NodeId id, QtNodes::PortIndex port) const {
    const QString key = node_key(id);
    if (key.startsWith("uimg:")) return key.section(':', 0, -2) + (port == 1 ? ":sampler" : ":texture");
    if (key.startsWith("uobj:")) return key.section(':', 0, -2) + ":ModelVertex";
    auto* d = model_->delegateModel<Scene_Delegate>(id);
    if (!d) return {};
    if (d->name() == "settings") return key + ":" + d->uniform_outputs.value(port);
    if (const auto* desc = find_desc(descriptors(), key))
        return key + ":" + QString::fromStdString(desc->output_pin);
    return {};
}

bool Node_View::resolve_output(const QString& ep, QtNodes::NodeId& id, QtNodes::PortIndex& port) const {
    if (ep.endsWith(":sampler")) {
        id = node_id(ep.chopped(8) + ":texture");
        port = 1;
    } else {
        id = node_id(ep);
        port = 0;
        if (id == QtNodes::InvalidNodeId) {
            const int cut = ep.lastIndexOf(':');
            if (cut <= 0) return false;
            id = node_id(ep.left(cut));
        }
    }
    if (id == QtNodes::InvalidNodeId) return false;
    auto* d = model_->delegateModel<Scene_Delegate>(id);
    if (d && d->name() == "settings") return false;
    const auto count = model_->nodeData(id, QtNodes::NodeRole::OutPortCount).value<unsigned int>();
    return port < count;
}

bool Node_View::resolve_input(const QString& ep, QtNodes::NodeId& id, QtNodes::PortIndex& port) const {
    const int cut = ep.lastIndexOf(':');
    if (cut <= 0) return false;
    const QString pin = ep.mid(cut + 1);
    id = node_id(ep.left(cut));
    if (id == QtNodes::InvalidNodeId) return false;
    if (node_key(id) == "show2d") { port = 0; return pin == "frame"; }
    auto* d = model_->delegateModel<Scene_Delegate>(id);
    if (!d) return false;
    for (int i = 0; i < d->inputs.size(); ++i)
        if (d->inputs[i].type != Scene_Delegate::Pin_Type::Uniform && d->inputs[i].name == pin) {
            port = i;
            return true;
        }
    return false;
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
    // Pass nodes in nodes_ order (the reflection order load_layout uses).
    QList<Graph_Link> chain;
    QString prev_output; // "<key>:<pin>" of the previous pass's frame
    for (const Graph_Node& node : nodes_) {
        if (node.kind == "settings" || node.kind == "output" ||
            node.kind == "texture" || node.kind == "mesh" ||
            node.kind == "widget")
            continue;
        const auto* desc = find_desc(descs, node.key);
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

// Mesh nodes with no outgoing link feed the first model-consuming pass whose
// ModelVertex pin is still free. Lets graph.json omit the link and still draw.
void Node_View::auto_link_models() {
    const auto descs = descriptors();
    for (const Graph_Node& node : nodes_) {
        if (node.kind != "mesh") continue;
        bool linked = false;
        for (const Graph_Link& l : links_) linked = linked || l.from == node.key;
        if (linked) continue;
        for (const auto& desc : descs) {
            if (!desc.uses_model) continue;
            const QString target = QString::fromStdString(desc.key) + ":ModelVertex";
            bool taken = false;
            for (const Graph_Link& l : links_) taken = taken || l.to == target;
            if (taken) continue;
            links_.push_back({node.key, target});
            dirty_ = true;
            break;
        }
    }
}

// No graph.json: settings left, passes in reflection order, output right.
void Node_View::default_layout(const scene::Runtime_Scene& scene) {
    float x = 0;
    nodes_.push_back({"settings", "settings", x, 40, "", "", "", 0, 0});
    x += 180;
    for (const auto& pass : scene.passes) {
        nodes_.push_back({QString::fromStdString(pass.graph_key),
                          pass.kind == scene::Scene_Kind::COMPUTE ? "compute" : "graphics",
                          x, 40, "", "", "", 0, 0});
        x += 180;
    }
    nodes_.push_back({"show2d", "output", x + 60, 40, "", "", "", 0, 0});
    derive_default_links();
}

// Parses graph.json text into nodes_/links_ (first wins on duplicate keys/links:
// a hand-edited or legacy file may repeat them, and duplicates would double-add
// model rows).
bool Node_View::read_graph(const std::string& text) {
    render_graph::Graph_Json doc;
    if (!refl::parse_graph_json(doc, text)) return false;
    if (doc.version != 0 && doc.version != render_graph::GRAPH_SCHEMA_VERSION) return false;
    QSet<QString> seen_keys;
    for (const auto& n : doc.nodes) {
        const QString key = QString::fromStdString(n.key);
        if (seen_keys.contains(key)) continue;
        seen_keys.insert(key);
        Graph_Node node;
        node.key = key;
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
    QSet<QString> seen_links;
    for (const auto& l : doc.links) {
        const QString from = QString::fromStdString(l.from);
        const QString to = QString::fromStdString(l.to);
        if (seen_links.contains(from + "\n" + to)) continue;
        seen_links.insert(from + "\n" + to);
        links_.push_back({from, to});
    }
    return true;
}

bool Node_View::load_layout(const QString& scene_title, const QString& scene_root,
                            const scene::Runtime_Scene& scene) {
    scene_title_ = scene_title;
    fit_pending_ = true;
    scene_root_ = scene_root;
    current_scene_ = &scene;
    clear_model();
    nodes_.clear();
    links_.clear();

    QString path = QString::fromStdString(render_graph::graph_path(
        scene_title.toStdString(), scene_root.toStdString()));
    std::ifstream f(path.toStdString());
    if (!f.good()) {
        default_layout(scene);
        rebuild_scene();
        dirty_ = true;
        return true;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    if (!read_graph(ss.str())) return false;
    if (links_.empty()) derive_default_links(); // link-less graph.json: default chain
    auto_link_models();
    rebuild_scene();
    return true;
}

// Graph_View: bounded zoom, trackpad-aware. See header for why base is replaced.
void graph_editor::Graph_View::zoom_by(double f) {
    const double cur = zoom();
    const double t = std::clamp(cur * f, kMinZoom, kMaxZoom);
    if (t == cur) return;
    scale(t / cur, t / cur);
    Q_EMIT scaleChanged(t);
}

void graph_editor::Graph_View::wheelEvent(QWheelEvent* e) {
    // Trackpads report a scroll phase; mouse wheels report NoScrollPhase even when pixelDelta is set on macOS.
    if (e->phase() != Qt::NoScrollPhase && !(e->modifiers() & Qt::ControlModifier)) {
        horizontalScrollBar()->setValue(horizontalScrollBar()->value() - e->pixelDelta().x());
        verticalScrollBar()->setValue(verticalScrollBar()->value() - e->pixelDelta().y());
        e->accept();
        return;
    }
    const int dy = e->angleDelta().y();
    if (dy == 0) {
        e->ignore();
        return;
    }
    zoom_by(std::pow(1.0015, dy)); // 120 per notch ~ x1.2, matches the old step
    e->accept();
}

bool graph_editor::Graph_View::viewportEvent(QEvent* e) {
    if (e->type() == QEvent::NativeGesture) {
        auto* g = static_cast<QNativeGestureEvent*>(e);
        if (g->gestureType() == Qt::ZoomNativeGesture) {
            zoom_by(1.0 + g->value());
            return true;
        }
    }
    return QtNodes::GraphicsView::viewportEvent(e);
}

void graph_editor::Graph_View::showEvent(QShowEvent* e) {
    // Skip QtNodes' showEvent: it calls centerScene() and wipes the sceneRect and user zoom.
    QGraphicsView::showEvent(e);
    if (!shown_once_) { shown_once_ = true; fit_all(); }
}

void graph_editor::Graph_View::fit_all() {
    if (!scene()) return;
    const QRectF r = scene()->itemsBoundingRect().adjusted(-40, -40, 40, 40);
    if (r.isEmpty()) return;
    fitInView(r, Qt::KeepAspectRatio);
    setupScale(transform().m11()); // clamp to [kMinZoom, kMaxZoom]
    centerOn(r.center());
}

void Node_View::set_scene(const scene::Runtime_Scene& scene) { current_scene_ = &scene; }

void Node_View::sync_positions() {
    for (Graph_Node& node : nodes_) {
        for (auto it = id_to_key_.cbegin(); it != id_to_key_.cend(); ++it) {
            if (it.value() != node.key) continue;
            const QPointF p = model_->nodeData(it.key(), QtNodes::NodeRole::Position).toPointF();
            node.x = float(p.x());
            node.y = float(p.y());
            break;
        }
    }
}

void Node_View::clear_wireless_marks() {
    for (auto& m : wireless_marks_) {
        if (m.ring1) scene_->removeItem(m.ring1);
        if (m.ring2) scene_->removeItem(m.ring2);
        delete m.ring1;
        delete m.ring2;
    }
    wireless_marks_.clear();
}

void Node_View::clear_model() {
    // deleteNode drops each node's connections first; muted so links_ survives the sweep.
    const bool was_loading = loading_;
    loading_ = true;
    for (const auto& id : model_->allNodeIds()) model_->deleteNode(id);
    loading_ = was_loading;
    pass_flash_items_.clear(); // fades died with their NGOs
    id_to_key_.clear();
    clear_wireless_marks();
}

void Node_View::swap_resource(const QString& key) {
    const bool mesh = key.startsWith("uobj:");
    QString path = QFileDialog::getOpenFileName(
        this, mesh ? "pick mesh" : "pick image", "assets",
        mesh ? "Models (*.glb *.gltf)" : "Images (*.png *.jpg *.jpeg *.bmp)");
    if (!path.isEmpty()) replace_resource(key, path);
}

void Node_View::replace_resource(const QString& old_key, const QString& path) {
    const bool mesh = old_key.startsWith("uobj:");
    const QString new_key = mesh ? QString("uobj:%1:ModelVertex").arg(path)
                                 : QString("uimg:%1:texture").arg(path);
    if (new_key == old_key) return;
    for (const Graph_Node& other : nodes_)
        if (other.key == new_key) {
            notify::notify(notify::Kind::WARN, "that file is already in the graph");
            return;
        }
    sync_positions(); // positions are matched by key: sync before the key changes
    // Link ends: mesh = the key; texture = key plus "<base>:sampler"
    // (base = key minus ":texture"). Re-point both or the links dangle.
    const QString old_base = old_key.chopped(8), new_base = new_key.chopped(8);
    auto retarget = [&](QString& end) {
        if (end == old_key) end = new_key;
        else if (!mesh && end == old_base + ":sampler") end = new_base + ":sampler";
    };
    for (Graph_Link& l : links_) {
        retarget(l.from);
        retarget(l.to);
    }
    for (Graph_Node& node : nodes_) {
        if (node.key != old_key) continue;
        node.key = new_key;
        node.file.clear(); // add path never sets these; keep swapped nodes identical
        node.model.clear();
        break;
    }
    dirty_ = true;
    rebuild_scene();
    emit pipeline_changed(); // host flushes graph.json and replans with the new asset
}

// Input pins in port order: textures, samplers, ModelVertex, uniform blocks (wireless).
// Matches input_endpoint/resolve_input and uniform_port_base.
static QList<Scene_Delegate::Pin> pins_for(const render_graph::Pass_Descriptor& desc) {
    QList<Scene_Delegate::Pin> pins;
    for (const auto& t : desc.input_textures)
        pins << Scene_Delegate::Pin{Scene_Delegate::Pin_Type::Texture, QString::fromStdString(t)};
    for (const auto& s : desc.input_samplers)
        if (!s.empty()) pins << Scene_Delegate::Pin{Scene_Delegate::Pin_Type::Sampler, QString::fromStdString(s)};
    if (desc.uses_model)
        pins << Scene_Delegate::Pin{Scene_Delegate::Pin_Type::Model, QStringLiteral("ModelVertex")};
    for (const auto& u : desc.uniform_blocks)
        pins << Scene_Delegate::Pin{Scene_Delegate::Pin_Type::Uniform, QString::fromStdString(u)};
    return pins;
}

// Settings: one wireless OUTPUT per unique uniform block across the scene,
// "Uniforms" always first (the app feeds every pass).
static QStringList settings_blocks(const std::vector<render_graph::Pass_Descriptor>& descs) {
    QStringList blocks{"Uniforms"};
    for (const auto& desc : descs)
        for (const auto& u : desc.uniform_blocks) {
            const QString name = QString::fromStdString(u);
            if (!blocks.contains(name)) blocks << name;
        }
    return blocks;
}

void Node_View::add_model_node(const Graph_Node& node,
                               const std::vector<render_graph::Pass_Descriptor>& descs) {
    pending_key_ = node.key;
    pending_preview_ = node.kind == "graphics" || node.kind == "compute";
    const QtNodes::NodeId id = model_->addNode(node.kind);
    if (id == QtNodes::InvalidNodeId) return;
    id_to_key_[id] = node.key;
    model_->setNodeData(id, QtNodes::NodeRole::Position, QPointF(node.x, node.y));
    if (auto* delegate = model_->delegateModel<Scene_Delegate>(id)) {
        if (const auto* desc = find_desc(descs, node.key)) delegate->inputs = pins_for(*desc);
        if (node.kind == "settings") delegate->uniform_outputs = settings_blocks(descs);
        delegate->on_swap = [this, key = node.key] { swap_resource(key); };
    }
    // Port captions live on the delegate; the node's size was computed at
    // addNode with 0 ports. Recompute now that the interface is set.
    model_->nodeUpdated(id);
    // QtNodes places the embedded widget once, at addNode (0 ports → it
    // sits over the pin captions). Re-place it now that the pins exist.
    if (auto* ngo = scene_->nodeGraphicsObject(id))
        for (auto* child : ngo->childItems())
            if (auto* proxy = qgraphicsitem_cast<QGraphicsProxyWidget*>(child))
                proxy->setPos(scene_->nodeGeometry().widgetPosition(id));
}

// Links: "<key>:<pin>" endpoints resolve through resolve_output/resolve_input.
// Caller holds loading_: rebuild_scene is the source of truth, so the
// producer-replacement modal must not pop during load.
void Node_View::restore_links() {
    for (const Graph_Link& link : links_) {
        QtNodes::NodeId from, to;
        QtNodes::PortIndex from_port = 0, to_port = 0;
        if (!resolve_output(link.from, from, from_port) || !resolve_input(link.to, to, to_port)) {
            std::fprintf(stderr, "[rebuild] unresolved link: from='%s' to='%s'\n",
                         link.from.toUtf8().constData(), link.to.toUtf8().constData());
            continue;
        }
        const QtNodes::ConnectionId cid{from, from_port, to, to_port};
        bool exists = false;
        for (const auto& conn : model_->allConnectionIds(from)) {
            if (conn == cid) { exists = true; break; }
        }
        if (!exists) model_->addConnection(cid);
    }
}

void Node_View::rebuild_scene() {
    sync_positions(); // keep user drags across rebuilds
    clear_model();    // rebuild owns the model; appending stacked duplicate nodes
    const auto descs = descriptors();
    // Repopulating is not a user edit: mutes position/connection handlers
    // (no dirty flag, no replace modal).
    const bool was_loading = loading_;
    loading_ = true;
    for (const Graph_Node& node : nodes_) add_model_node(node, descs); // NodeIds are sequential
    restore_links();
    loading_ = was_loading;
    marks_dirty_ = true;
    refresh_wireless_marks();
    refresh_previews();
    // Fit only after load_layout (fit_pending_); user edits keep their zoom.
    // Deferred: the panel spring is still running, so geometry is not final.
    QTimer::singleShot(250, this, [this] {
        if (fit_pending_) {
            fit_pending_ = false;
            view_->fit_all();
        }
    });
}

// Pass thumbnails: one pixmap per pass node, parked under the node title
// (Odin draws the preview inside the node body; here it rides on the node
// graphics object). Content = the 128px GPU downscale the submit blits
// every frame; the host hands over QImages on a slow tick.
void Node_View::set_previews(const QVector<QImage>& images) {
    previews_ = images;
    refresh_previews();
}

void Node_View::set_previews_enabled(bool on) {
    previews_enabled_ = on;
    refresh_previews();
}

void Node_View::refresh_previews() {
    if (!scene_) return;
    // Pass index by graph key: nodes_ keeps reflection order for pass nodes.
    QMap<QString, int> pass_index;
    int pi = 0;
    for (const Graph_Node& node : nodes_) {
        if (node.kind == "graphics" || node.kind == "compute")
            pass_index[node.key] = pi++;
    }
    for (auto it = id_to_key_.begin(); it != id_to_key_.end(); ++it) {
        const int index = pass_index.value(it.value(), -1);
        if (index < 0) continue; // texture/mesh/settings/output: their widgets are not previews
        auto* d = model_->delegateModel<Scene_Delegate>(it.key());
        QWidget* w = d ? d->embeddedWidget() : nullptr;
        if (!w) continue;
        const bool show = previews_enabled_ && index >= 0 && index < previews_.size() &&
                          !previews_[size_t(index)].isNull();
        w->setVisible(show);
        // Flash only when the pass output changed (checksum inside set_image).
        if (show && d->set_preview(previews_[size_t(index)])) flash_pass(it.key());
    }
}

// One pin-scene position for a node's port (geometry + node transform).
static QPointF port_scene_pos(QtNodes::BasicGraphicsScene& scene,
                              QtNodes::NodeId id, QtNodes::PortType type,
                              QtNodes::PortIndex index) {
    QTransform t;
    if (auto* ngo = scene.nodeGraphicsObject(id)) t = ngo->sceneTransform();
    return scene.nodeGeometry().portScenePosition(id, type, index, t);
}

// Syncs the toolbar toggle and icon to the shell's fullscreen state, silently.
void Node_View::set_fullscreen_state(bool on) {
    auto* btn = findChild<QToolButton*>("graphFullscreen");
    if (!btn) return;
    QSignalBlocker block(btn);
    btn->setChecked(on);
    btn->setIcon(theme::tinted_icon(on ? ":/qlementine/icons/24/action/fullscreen-exit.svg"
                                       : ":/qlementine/icons/24/action/fullscreen.svg",
                                    QColor(theme::text_primary()), shell::kToolbarIcon));
}

// Light blue, distinct from every node hue: the uniform feed reads as its own
// signal, not a node wire (Odin SG_WIRELESS_COLOR).
static const QColor kWirelessColor(0x7a, 0xc8, 0xff);

// Visits every wireless port in a stable order: settings outputs (grow =
// broadcast), then each pass's uniform inputs (receive). Marks are created and
// parked in this same order.
void Node_View::for_each_wireless_port(
    const std::vector<render_graph::Pass_Descriptor>& descs,
    const std::function<void(QtNodes::NodeId, QtNodes::PortType, QtNodes::PortIndex, bool)>& fn) const {
    for (const Graph_Node& node : nodes_) {
        const QtNodes::NodeId id = node_id(node.key);
        if (id == QtNodes::InvalidNodeId) continue;
        if (node.kind == "settings") {
            const unsigned int outs = model_->nodeData(id, QtNodes::NodeRole::OutPortCount).value<unsigned int>();
            for (uint32_t i = 0; i < outs; ++i)
                fn(id, QtNodes::PortType::Out, QtNodes::PortIndex(i), true);
        } else if (const auto* desc = find_desc(descs, node.key)) {
            const uint32_t base = uniform_port_base(*desc);
            for (uint32_t i = 0; i < desc->uniform_blocks.size(); ++i)
                fn(id, QtNodes::PortType::In, QtNodes::PortIndex(base + i), false);
        }
    }
}

void Node_View::rebuild_wireless_marks(const std::vector<render_graph::Pass_Descriptor>& descs) {
    clear_wireless_marks();
    for_each_wireless_port(descs, [this](QtNodes::NodeId id, QtNodes::PortType type,
                                         QtNodes::PortIndex idx, bool grow) {
        auto* r1 = new QGraphicsEllipseItem();
        auto* r2 = new QGraphicsEllipseItem();
        // Park immediately at the right position.
        const QPointF p = port_scene_pos(*scene_, id, type, idx);
        for (auto* ring : {r1, r2}) {
            ring->setPen(QPen(kWirelessColor, 1.2));
            ring->setBrush(Qt::NoBrush);
            ring->setZValue(20.0); // over nodes and connections
            ring->setRect(QRectF(p.x() - 4.2, p.y() - 4.2, 8.4, 8.4));
            scene_->addItem(ring);
        }
        wireless_marks_.push_back({r1, r2, grow});
    });
}

// Two staggered rings per mark on a 1.6 s loop. Emit expands outward and
// fades; receive converges inward and brightens.
void Node_View::park_wireless_marks(const std::vector<render_graph::Pass_Descriptor>& descs) {
    const double now = double(marks_clock_.elapsed()) / 1000.0;
    const double phase = std::fmod(now * 0.625, 1.0);
    const double base_r = 4.2, span = 9.0;
    size_t mark_i = 0;
    for_each_wireless_port(descs, [&](QtNodes::NodeId id, QtNodes::PortType type,
                                      QtNodes::PortIndex idx, bool grow) {
        if (mark_i >= wireless_marks_.size()) return;
        Wireless_Mark& m = wireless_marks_[mark_i++];
        const QPointF p = port_scene_pos(*scene_, id, type, idx);
        for (int k = 0; k < 2; ++k) {
            const double t = std::fmod(phase + k * 0.5, 1.0);
            const double r = grow ? base_r + span * t : base_r + span - span * t;
            const double alpha = grow ? 0.9 * (1.0 - t) : 0.3 + 0.6 * t;
            auto* ring = k == 0 ? m.ring1 : m.ring2;
            QColor c = kWirelessColor;
            c.setAlpha(int(alpha * 255));
            ring->setPen(QPen(c, 1.2));
            ring->setRect(QRectF(p.x() - r, p.y() - r, 2 * r, 2 * r));
            ring->setVisible(true);
        }
    });
}

// Parks the wireless ring items at the current pin positions. Uniform
// feed: the settings node's uniform outputs broadcast (ball + expanding
// rings), every pass's uniform input receives (converging rings).
void Node_View::refresh_wireless_marks() {
    if (!scene_ || !current_scene_) return;
    const auto descs = descriptors();
    // (Re)build the mark set after any structural change; parked each tick.
    if (wireless_marks_.empty() || marks_dirty_) rebuild_wireless_marks(descs);
    marks_dirty_ = false;
    park_wireless_marks(descs);
}

// Links: rebuild from model connections, mapping ids back to keys with
// full "<key>:<pin>" endpoints from output_endpoint/input_endpoint (the one
// port-layout mapper), so e.g. a sampler link keeps its "<pass>:<sampler>"
// TO endpoint across a save.
void Node_View::collect_links_from_model() {
    links_.clear();
    for (const auto& from_id : model_->allNodeIds())
    for (const auto& cid : model_->allConnectionIds(from_id)) {
        if (node_key(cid.outNodeId).isEmpty() || node_key(cid.inNodeId).isEmpty()) continue;
        const QString from_pin = output_endpoint(cid.outNodeId, cid.outPortIndex);
        const QString to_pin = input_endpoint(cid.inNodeId, cid.inPortIndex);
        bool dup = false;
        for (const Graph_Link& existing : links_)
            if (existing.from == from_pin && existing.to == to_pin) { dup = true; break; }
        if (!dup) links_.push_back({from_pin, to_pin});
    }
}

QByteArray Node_View::layout_json(const QString& scene_title) const {
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
    return QJsonDocument(QJsonObject{
        {"version", render_graph::GRAPH_SCHEMA_VERSION},
        {"scene", scene_title},
        {"nodes", nodes_json},
        {"links", links_json}}).toJson(QJsonDocument::Indented);
}

// Atomic swap: a truncated direct write would poison the scene forever.
// rename() replaces the target atomically, so no remove before it.
static bool write_atomic(const std::string& path, const QByteArray& bytes) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc);
        f.write(bytes.constData(), bytes.size());
        f.close();
        if (f.fail()) {
            std::remove(tmp.c_str());
            return false;
        }
    }
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        std::remove(tmp.c_str());
        return false;
    }
    return true;
}

bool Node_View::save_layout(const QString& scene_title, const QString& scene_root) {
    sync_positions(); // nodes_ is the single source for the JSON
    collect_links_from_model();
    const std::string path = render_graph::graph_path(scene_title.toStdString(),
                                                      scene_root.toStdString());
    if (!write_atomic(path, layout_json(scene_title))) return false; // dirty_ stays set
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
