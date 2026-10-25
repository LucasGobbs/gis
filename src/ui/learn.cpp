// LEARN implementation: md4c parser (vendor/md4c, the same C library the
// Odin app links) driving a Qt widget renderer. Replaces the hand-rolled
// line parser: the block/span handler model mirrors src/md_learn.odin
// (mekhontsev/imgui_md structure). Links never navigate during parsing —
// clicks go through queued follow_link ("scene:NAME" emits scene_requested,
// "trail:NAME" navigates). Code blocks get the editor theme's token colors
// and click-to-copy (line on click, block on double-click), like md_learn.
#include "learn.hpp"
#include "i18n.hpp"
#include "editor.hpp"

#include <QApplication>
#include <QClipboard>
#include <QFile>
#include <QMouseEvent>
#include <QLabel>
#include <QMenu>
#include <QPushButton>
#include <QScrollBar>
#include <QScrollArea>
#include <QVBoxLayout>
#include <QWidget>

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#include <md4c.h>
namespace learn {

static const char* kTrailDir = "assets/trails";


// ---- Editor-theme code colors (md_learn md_code_colors parity) ----

struct Code_Colors {
    QColor text, keyword, declaration, number, known_identifier, comment, chip_bg, code_bg;
};

static Code_Colors code_colors(editor::Editor_Theme theme) {
    switch (theme) {
    case editor::Editor_Theme::MONOKAI:
        return {QColor(0xf8, 0xf8, 0xf2), QColor(0xf9, 0x26, 0x72),
                QColor(0xa6, 0xe2, 0x2e), QColor(0xae, 0x81, 0xff),
                QColor(0x66, 0xd9, 0xef), QColor(0x75, 0x71, 0x5e),
                QColor(0x1e, 0x1f, 0x1a), QColor(0x27, 0x28, 0x22)};
    case editor::Editor_Theme::SOLARIZED:
        return {QColor(0x93, 0xa1, 0xa1), QColor(0x85, 0x99, 0x00),
                QColor(0x26, 0x8b, 0xd2), QColor(0xd3, 0x36, 0x82),
                QColor(0x2a, 0xa1, 0x98), QColor(0x58, 0x6e, 0x75),
                QColor(0x07, 0x36, 0x42), QColor(0x00, 0x2b, 0x36)};
    case editor::Editor_Theme::LIGHT:
        return {QColor(0x1f, 0x20, 0x24), QColor(0x1c, 0x46, 0x9c),
                QColor(0x78, 0x35, 0x96), QColor(0x9c, 0x42, 0x2e),
                QColor(0x1d, 0x6b, 0x33), QColor(0x6f, 0x74, 0x7e),
                QColor(0xf2, 0xf3, 0xf5), QColor(0xe8, 0xea, 0xef)};
    default: // DARK = Darkroom (editor.cpp apply_skin tokens).
        return {QColor(0xd7, 0xda, 0xe2), QColor(0xe8, 0xa8, 0x57),
                QColor(0x9e, 0xc2, 0xf2), QColor(0xf2, 0x8c, 0x7a),
                QColor(0xc9, 0x9e, 0xf2), QColor(0x78, 0x7d, 0x88),
                QColor(0x10, 0x11, 0x16), QColor(0x10, 0x11, 0x16)};
    }
}

// Keyword lists mirrored from src/ui_learn.odin.
static const char* const kKeywords[] = {
    "float", "float2", "float3", "float4", "int", "int2", "uint", "bool",
    "return", "if", "else", "for", "while", "struct", "public", "import",
    "namespace", "uniform", "const", "void", "in", "out", "inout",
    "switch", "case", "break", "continue", "true", "false",
};
static const char* const kNamespaces[] = {"Space", "Camera", "Noise", "Sdf"};
static const char* const kHostIdents[] = {"Uniforms", "Params", "input"};

// One highlighted code line -> rich text (md_learn token classes).
static QString highlight_code_line(const QString& line, const Code_Colors& c) {
    static const QSet<QString> keywords = [] {
        QSet<QString> s;
        for (const char* k : kKeywords) s.insert(QString::fromLatin1(k));
        return s;
    }();
    static const QSet<QString> namespaces = [] {
        QSet<QString> s;
        for (const char* k : kNamespaces) s.insert(QString::fromLatin1(k));
        return s;
    }();
    static const QSet<QString> host = [] {
        QSet<QString> s;
        for (const char* k : kHostIdents) s.insert(QString::fromLatin1(k));
        return s;
    }();

    auto span = [](const QColor& color, const QString& text) {
        return QString("<span style=\"color:%1\">%2</span>")
            .arg(color.name(), text.toHtmlEscaped());
    };
    QString out;
    // Tokenize: identifiers/words vs everything else; comments win.
    int i = 0;
    while (i < line.size()) {
        if (line[i] == '/' && i + 1 < line.size() && line[i + 1] == '/') {
            out += span(c.comment, line.mid(i));
            break;
        }
        QChar ch = line[i];
        if (ch.isLetterOrNumber() || ch == '_') {
            int j = i;
            while (j < line.size() &&
                   (line[j].isLetterOrNumber() || line[j] == '_'))
                ++j;
            QString word = line.mid(i, j - i);
            if (keywords.contains(word)) out += span(c.keyword, word);
            else if (namespaces.contains(word)) out += span(c.known_identifier, word);
            else if (host.contains(word)) out += span(c.known_identifier, word);
            else if (word[0].isDigit()) out += span(c.number, word);
            else out += span(c.text, word);
            i = j;
            continue;
        }
        if (ch.isDigit()) {
            int j = i;
            while (j < line.size() && (line[j].isDigit() || line[j] == '.'))
                ++j;
            out += span(c.number, line.mid(i, j - i));
            i = j;
            continue;
        }
        // Punctuation run.
        int j = i;
        while (j < line.size() && !line[j].isLetterOrNumber() && line[j] != '_' &&
               !(line[j] == '/' && j + 1 < line.size() && line[j + 1] == '/'))
            ++j;
        out += span(c.declaration, line.mid(i, j - i));
        i = j;
    }
    return out;
}

// Code block widget: one dark panel, mono labels, click copies the line,
// double-click copies the whole block (md_learn contract).
class Code_Block : public QWidget {
public:
    Code_Block(const QStringList& lines, const Code_Colors& c, QWidget* parent)
        : QWidget(parent) {
        setStyleSheet(QString("background: %1; border-radius: 6px;")
                          .arg(c.code_bg.name()));
        auto* layout = new QVBoxLayout(this);
        layout->setContentsMargins(12, 8, 12, 8);
        layout->setSpacing(0);
        for (const QString& cl : lines) {
            auto* label = new QLabel(highlight_code_line(cl, c));
            label->setTextFormat(Qt::RichText);
            label->setTextInteractionFlags(Qt::TextSelectableByMouse);
            label->setStyleSheet(QString("color: %1; background: transparent;"
                                         " font-family: 'JetBrains Mono', monospace;"
                                         " font-size: 9pt;")
                                     .arg(c.text.name()));
            layout->addWidget(label);
        }
    }

protected:
    void mousePressEvent(QMouseEvent* event) override {
        if (event->button() == Qt::LeftButton) copy_line_at(event->pos());
        QWidget::mousePressEvent(event);
    }
    void mouseDoubleClickEvent(QMouseEvent* event) override {
        if (event->button() == Qt::LeftButton) copy_block();
        QWidget::mouseDoubleClickEvent(event);
    }

private:
    void copy_line_at(const QPoint& pos) {
        const auto* layout_c = layout();
        for (int i = 0; i < layout_c->count(); ++i) {
            auto* item = layout_c->itemAt(i);
            if (!item->widget()) continue;
            QRect r = item->geometry();
            if (pos.y() >= r.top() && pos.y() < r.bottom()) {
                QApplication::clipboard()->setText(item->widget()->toolTip().isEmpty()
                                                       ? static_cast<QLabel*>(item->widget())->text()
                                                       : item->widget()->toolTip());
                break;
            }
        }
    }
    void copy_block() {
        QString all;
        const auto* layout_c = layout();
        for (int i = 0; i < layout_c->count(); ++i) {
            if (auto* label = qobject_cast<QLabel*>(layout_c->itemAt(i)->widget()))
                all += label->text() + "\n";
        }
        QApplication::clipboard()->setText(all.trimmed());
    }
};

// ---- md4c renderer (block/span callbacks into widget emission) ----

struct Render_Ctx {
    Trail_View* view = nullptr;
    QVBoxLayout* layout = nullptr;
    Code_Colors colors;
    QStringList prose;      // paragraph accumulator
    QStringList code_lines; // fenced block accumulator
    bool in_code = false;
    bool in_list_item = false;
    bool in_span_code = false;
    QString item_text;      // list item rich text
    QString link_label;     // [label] accumulation
    QString link_href;
    QString heading_text;   // pending heading text
    QString span_code_text; // inline-code accumulation
    int pending_heading = 0;

    void flush_paragraph();
    void add_link(const QString& label, const QString& target);
};


void Render_Ctx::flush_paragraph() {
    if (prose.isEmpty()) return;
    auto* p = new QLabel(prose.join(' '));
    p->setWordWrap(true);
    p->setTextFormat(Qt::RichText);
    p->setStyleSheet("color: #d7dae2; font-size: 10pt; line-height: 150%;");
    p->setOpenExternalLinks(false);
    layout->addWidget(p);
    prose.clear();
}

void Render_Ctx::add_link(const QString& label, const QString& target) {
    flush_paragraph();
    // Scene chips are buttons (amber on hover); trail links are flat links.
    if (target.startsWith("scene:")) {
        auto* chip = new QPushButton(label, layout->parentWidget());
        chip->setCursor(Qt::PointingHandCursor);
        chip->setFlat(true);
        chip->setStyleSheet(
            "QPushButton { text-align: left; color: #e8a857;"
            " background: rgba(232,168,87,0.10); border: 1px solid"
            " rgba(232,168,87,0.35); border-radius: 5px; padding: 4px 10px; }"
            "QPushButton:hover { background: rgba(232,168,87,0.22); }");
        QObject::connect(chip, &QPushButton::clicked, view, [view = view, target] {
            view->follow_link_public(target);
        });
        layout->addWidget(chip);
        return;
    }
    auto* link = new QPushButton(label, layout->parentWidget());
    link->setCursor(Qt::PointingHandCursor);
    link->setFlat(true);
    link->setStyleSheet(
        "QPushButton { text-align: left; color: #9ec2f2; background:"
        " transparent; border: none; padding: 0; font-weight: 600; }"
        "QPushButton:hover { color: #c9e0f9; }");
    QObject::connect(link, &QPushButton::clicked, view, [view = view, target] {
        view->follow_link_public(target);
    });
    layout->addWidget(link);
}


// ---- md4c callbacks ----

static int cb_enter_block(MD_BLOCKTYPE type, void* detail, void* ud) {
    auto* ctx = static_cast<Render_Ctx*>(ud);
    switch (type) {
    case MD_BLOCK_H: {
        ctx->flush_paragraph();
        auto* h = static_cast<MD_BLOCK_H_DETAIL*>(detail);
        ctx->pending_heading = int(h->level);
        ctx->heading_text.clear();
        break;
    }
    case MD_BLOCK_CODE:
        ctx->flush_paragraph();
        ctx->in_code = true;
        ctx->code_lines.clear();
        break;
    case MD_BLOCK_LI:
        ctx->flush_paragraph();
        ctx->in_list_item = true;
        ctx->item_text.clear();
        break;
    default:
        (void)detail;
        break;
    }
    return 0;
}

static int cb_leave_block(MD_BLOCKTYPE type, void* detail, void* ud) {
    (void)detail;
    auto* ctx = static_cast<Render_Ctx*>(ud);
    switch (type) {
    case MD_BLOCK_DOC:
        ctx->flush_paragraph();
        break;
    case MD_BLOCK_CODE: {
        ctx->in_code = false;
        auto* block = new Code_Block(ctx->code_lines, ctx->colors,
                                     ctx->layout->parentWidget());
        ctx->layout->addWidget(block);
        ctx->code_lines.clear();
        break;
    }
    case MD_BLOCK_H: {
        int level = ctx->pending_heading;
        ctx->pending_heading = 0;
        QString title = ctx->heading_text.trimmed();
        ctx->heading_text.clear();
        auto* h = new QLabel(title.toHtmlEscaped());
        h->setWordWrap(true);
        h->setTextFormat(Qt::RichText);
        if (level == 1)
            h->setStyleSheet("color: #f2f3f7; font-family: 'Sergamon'; font-size: 17pt;"
                             " font-weight: 600; padding: 4px 0;");
        else
            h->setStyleSheet("color: #d7dae2; font-size: 11pt; font-weight: 600;"
                             " padding: 8px 0 2px 0;");
        ctx->layout->addWidget(h);
        break;
    }
    case MD_BLOCK_LI: {
        ctx->in_list_item = false;
        QString rich = "•  " + ctx->item_text.trimmed();
        ctx->item_text.clear();
        auto* item = new QLabel(rich);
        item->setWordWrap(true);
        item->setTextFormat(Qt::RichText);
        item->setStyleSheet("color: #d7dae2; font-size: 10pt;");
        item->setContentsMargins(10, 0, 0, 0);
        ctx->layout->addWidget(item);
        break;
    }
    case MD_BLOCK_P:
        ctx->flush_paragraph();
        break;
    default:
        break;
    }
    return 0;
}

static int cb_enter_span(MD_SPANTYPE type, void* detail, void* ud) {
    auto* ctx = static_cast<Render_Ctx*>(ud);
    switch (type) {
    case MD_SPAN_A: {
        auto* a = static_cast<MD_SPAN_A_DETAIL*>(detail);
        ctx->link_href = QString::fromUtf8(a->href.text, int(a->href.size));
        ctx->link_label.clear();
        break;
    }
    case MD_SPAN_CODE:
        ctx->in_span_code = true;
        ctx->span_code_text.clear();
        break;
    default:
        (void)detail;
        break;
    }
    return 0;
}

static int cb_leave_span(MD_SPANTYPE type, void* detail, void* ud) {
    (void)detail;
    auto* ctx = static_cast<Render_Ctx*>(ud);
    switch (type) {
    case MD_SPAN_A: {
        QString href = ctx->link_href;
        QString label = ctx->link_label;
        ctx->link_href.clear();
        ctx->link_label.clear();
        // Links terminate the current paragraph flush like the widgets do.
        ctx->flush_paragraph();
        ctx->add_link(label, href);
        break;
    }
    case MD_SPAN_CODE: {
        ctx->in_span_code = false;
        QString code = ctx->span_code_text;
        ctx->span_code_text.clear();
        QString chip = QString("<code style=\"background:%1;"
                               " border-radius:3px; padding:1px 4px;"
                               " color:%2;\">%3</code>")
                           .arg(ctx->colors.chip_bg.name(),
                                QColor(0xa9, 0xd4, 0x9e).name(),
                                code.toHtmlEscaped());
        if (ctx->in_list_item) ctx->item_text += chip;
        else ctx->prose << chip;
        break;
    }
    default:
        break;
    }
    return 0;
}

static int cb_text(MD_TEXTTYPE type, const MD_CHAR* data, MD_SIZE size, void* ud) {
    auto* ctx = static_cast<Render_Ctx*>(ud);
    QString text = QString::fromUtf8(data, int(size));
    switch (type) {
    case MD_TEXT_BR:
        if (ctx->in_list_item) ctx->item_text += "<br>";
        else ctx->prose << "<br>";
        break;
    case MD_TEXT_SOFTBR:
        if (ctx->in_list_item) ctx->item_text += ' ';
        else if (!ctx->prose.isEmpty()) ctx->prose << ""; // word join
        break;
    case MD_TEXT_ENTITY: {
        // Decode the few entities the corpus can carry (md4c reports them raw).
        static const std::vector<std::pair<const char*, QString>> entities = {
            {"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"},
            {"&quot;", "\""}, {"&#39;", "'"},
        };
        for (const auto& e : entities)
            if (text == e.first) { text = e.second; break; }
        // fallthrough: treat as normal text
        [[fallthrough]];
    }
    case MD_TEXT_NORMAL:
    case MD_TEXT_NULLCHAR:
        if (ctx->in_code) ctx->code_lines << text;
        else if (ctx->in_span_code) ctx->span_code_text += text;
        else if (!ctx->link_href.isEmpty()) ctx->link_label += text;
        else if (ctx->pending_heading > 0) ctx->heading_text += text;
        else if (ctx->in_list_item) ctx->item_text += text.toHtmlEscaped();
        else ctx->prose << text.toHtmlEscaped();
        break;
    case MD_TEXT_CODE:
        if (ctx->in_code) ctx->code_lines << text;
        else ctx->span_code_text += text; // MD_SPAN_CODE body
        break;
    default:
        break;
    }
    return 0;
}

// ---- Trail_View ----

Trail_View::Trail_View(QWidget* parent) : QWidget(parent) {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    scroll_ = new QScrollArea(this);
    scroll_->setWidgetResizable(true);
    scroll_->setFrameShape(QFrame::NoFrame);
    page_ = new QWidget();
    page_layout_ = new QVBoxLayout(page_);
    page_layout_->setContentsMargins(18, 14, 18, 18);
    page_layout_->setSpacing(8);
    page_->setLayout(page_layout_);
    scroll_->setWidget(page_);
    layout->addWidget(scroll_);
    load("index");
}

void Trail_View::load(const QString& page) {
    if (!load_page(page)) return;
}

bool Trail_View::load_page(const QString& page) {
    QFile f(QString("%1/%2.md").arg(kTrailDir, page));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return false;
    current_page_ = page.isEmpty() ? "index" : page;
    render(QString::fromUtf8(f.readAll()));
    scroll_->verticalScrollBar()->setValue(0);
    return true;
}

void Trail_View::follow_link_public(const QString& target) {
    follow_link(target);
}

void Trail_View::follow_link(const QString& target) {
    // Never during parsing: render() builds the widget tree first, clicks
    // happen after — but a scene switch can delete this panel mid-signal,
    // so navigation goes through the event queue (learn_load rule).
    if (target.startsWith("scene:")) {
        QString scene = target.mid(6);
        QMetaObject::invokeMethod(this, [this, scene] {
            emit scene_requested(scene);
        }, Qt::QueuedConnection);
        return;
    }
    if (target.startsWith("trail:")) {
        QString page = target.mid(6);
        load(page);
    }
}

void Trail_View::render(const QString& text) {
    // Reset the page (widgets owned by the layout die with deleteLater).
    while (page_layout_->count() > 0) {
        QLayoutItem* item = page_layout_->takeAt(0);
        if (item->widget()) item->widget()->deleteLater();
        delete item;
    }

    // Home link only when not on home.
    if (current_page_ != "index") {
        Render_Ctx home;
        home.view = this;
        home.layout = page_layout_;
        home.add_link(i18n::tr("← all trails"), "trail:index");
    }

    Render_Ctx ctx;
    ctx.view = this;
    ctx.layout = page_layout_;
    ctx.colors = code_colors(editor_theme_);

    MD_PARSER parser = {};
    parser.abi_version = 0;
    parser.flags = MD_DIALECT_GITHUB;
    parser.enter_block = cb_enter_block;
    parser.leave_block = cb_leave_block;
    parser.enter_span = cb_enter_span;
    parser.leave_span = cb_leave_span;
    parser.text = cb_text;
    parser.debug_log = nullptr;
    parser.syntax = nullptr;

    std::string utf8 = text.toStdString();
    md_parse(utf8.data(), MD_SIZE(utf8.size()), &parser, &ctx);
    ctx.flush_paragraph();
    page_layout_->addStretch(1);
}

} // namespace learn
