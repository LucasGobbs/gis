// Graph editor implementation over QtNodes (DataFlowGraphModel): nodes with
// reflection-derived pins, graph.json load/save (atomic), links validated by
// plan_build before accept (invalid keeps the last valid pipeline, matching
// the Odin flow), confirmation modal for producer-replacing edges.
#include "graph_editor.hpp"
#include "gfx/render_graph/refl.hpp"
#include "notify.hpp"

#include "QtNodes/internal/NodeGraphicsObject.hpp"


#include <QDialogButtonBox>
#include <QFileDialog>
#include <QFileInfo>
#include <QMenu>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
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
    // Kind at a GLANCE: boundary + gradient hues per node type, so the
    // title only needs the file name (no comp:/gfx: prefix in the way).
    // params=amber (Safelight), compute=violet, graphics=blue, output=
    // green, texture/mesh/widget=gray.
    QtNodes::NodeStyle st = nodeStyle();
    QColor boundary, g0, g1;
    if (kind_ == "params") {
        boundary = QColor(0xE8, 0xA8, 0x57); g0 = QColor(0x8f, 0x62, 0x2b); g1 = QColor(0x5e, 0x40, 0x1c);
    } else if (kind_ == "compute") {
        boundary = QColor(0xc9, 0x9e, 0xf2); g0 = QColor(0x6b, 0x53, 0x8c); g1 = QColor(0x46, 0x37, 0x5e);
    } else if (kind_ == "graphics") {
        boundary = QColor(0x9e, 0xc2, 0xf2); g0 = QColor(0x4a, 0x5e, 0x8c); g1 = QColor(0x31, 0x3f, 0x5e);
    } else if (kind_ == "output") {
        boundary = QColor(0xa9, 0xd4, 0x9e); g0 = QColor(0x4f, 0x74, 0x48); g1 = QColor(0x35, 0x4d, 0x30);
    } else {
        boundary = QColor(0x8c, 0x90, 0x99); g0 = QColor(0x4a, 0x4d, 0x55); g1 = QColor(0x31, 0x33, 0x38);
    }
    st.NormalBoundaryColor = boundary;
    st.SelectedBoundaryColor = boundary.lighter(130);
    st.GradientColor0 = g0; st.GradientColor1 = g1;
    st.GradientColor2 = g1; st.GradientColor3 = g0;
    setNodeStyle(st);
}

unsigned int Scene_Delegate::nPorts(QtNodes::PortType type) const {
    if (type == QtNodes::PortType::Out)
        return (kind_ == "params") ? unsigned(uniform_inputs.size())
             : (kind_ == "output" ? 0u : 1u);
    if (type == QtNodes::PortType::In) {
        if (kind_ == "output") return 1u;
        return unsigned(tex_inputs.size() + uniform_inputs.size());
    }
    return 0u;
}

QtNodes::NodeDataType Scene_Delegate::dataType(QtNodes::PortType type,
                                               QtNodes::PortIndex index) const {
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
        if (to_key == "show2d") to_pin = to_key + ":frame";
        // Producer replacement: an input can have one producer. If the target
        // pin already had a link, ask before rewiring (Odin parity).
        QString replaced_from;
        for (long i = long(links_.size()) - 1; i >= 0; --i) {
            if (links_[size_t(i)].to == to_pin) replaced_from = links_[size_t(i)].from;
        }
        if (!replaced_from.isEmpty() && replaced_from != from_pin) {
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
        QAction* mesh = menu.addAction("mesh…");
        menu.addAction("render target");
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
        if (chosen == image || chosen == mesh) {
            // Real asset pick: the node key embeds the path the runtime
            // loads; a fake path would create a dead node (bind-site miss).
            const char* caption = chosen == image ? "pick image" : "pick mesh";
            const char* filter = chosen == image ? "Images (*.png *.jpg *.jpeg *.bmp)"
                                                 : "Models (*.glb *.gltf)";
            QString path = QFileDialog::getOpenFileName(this, caption, "assets", filter);
            if (path.isEmpty()) return;
            QFileInfo info(path);
            Graph_Node node;
            node.kind = chosen == image ? "texture" : "mesh";
            node.key = chosen == image
                           ? QString("uimg:%1:texture").arg(info.filePath())
                           : QString("uobj:%1:ModelVertex").arg(info.filePath());
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
        QAction* swap = user_node && key.startsWith("uimg:") && !key.contains(":target:")
                            ? menu.addAction("swap file…") : nullptr;
        QAction* chosen = menu.exec(QCursor::pos());
        if (!chosen) return;
        if (chosen == swap) {
            QString path = QFileDialog::getOpenFileName(
                this, "pick image", "assets", "Images (*.png *.jpg *.jpeg *.bmp)");
            if (path.isEmpty()) return;
            for (Graph_Node& node : nodes_) {
                if (node.key != key) continue;
                node.key = QString("uimg:%1:texture").arg(path);
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

bool Node_View::load_layout(const QString& scene_title, const QString& scene_root,
                            const scene::Runtime_Scene& scene) {
    scene_title_ = scene_title;
    scene_root_ = scene_root;
    current_scene_ = &scene;
    for (const auto& id : model_->allNodeIds()) model_->deleteNode(id);
    id_to_key_.clear();
    nodes_.clear();
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
        } else if (node.kind == "texture" || node.kind == "mesh") {
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
        QString from_key = link.from.section(':', 0, -2); // "<key>:<pin>"
        QString to_key = link.to.section(':', 0, 0);
        QtNodes::NodeId from = node_id(from_key);
        QtNodes::NodeId to = node_id(to_key);
        if (from == QtNodes::InvalidNodeId || to == QtNodes::InvalidNodeId) continue;
        uint32_t from_port = 0, to_port = 0;
        bool to_ok = false;
        // Port resolution: "<key>:<pin>" — pin is an input name on `to`;
        // on `from` it's that node's frame output (port 0).
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
        item->setPixmap(QPixmap::fromImage(previews_[size_t(index)]));
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
