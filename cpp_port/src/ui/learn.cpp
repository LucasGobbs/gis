// LEARN implementation: minimal markdown renderer for the trail corpus
// (see learn.hpp). Chosen over QTextBrowser/setMarkdown because the trails
// carry CUSTOM schemes — [label](scene:NAME) must emit scene_requested and
// [label](trail:NAME) must navigate — QTextMarkdown's anchorClicked gives
// neither reliably with non-http schemes. Typography mirrors the
// host block, scene chips in Safelight amber.
#include "learn.hpp"
#include "i18n.hpp"

#include <QFile>
#include <QLabel>
#include <QPushButton>
#include <QScrollBar>
#include <QScrollArea>
#include <QVBoxLayout>
#include <QWidget>

#include <algorithm>

namespace learn {

static const char* kTrailDir = "assets/trails";

// One trail doc = title line + prose. Kept hand-rolled: the corpus is 5
// files we ship ourselves; the parser below is the whole contract.
struct Token {
    enum Kind : uint8_t { TEXT, CODE, LINK } kind;
    QString text;
    QString target; // LINK only
};

static QStringList split_lines(const QString& text) {
    return text.split('\n');
}

static Token parse_link(const QString& s, int start, int* end) {
    // s[start] == '['; find "](target)".
    Token t;
    t.kind = Token::LINK;
    int close = s.indexOf("](", start);
    if (close < 0) {
        t.kind = Token::TEXT;
        t.text = s.mid(start, 1);
        *end = start + 1;
        return t;
    }
    int target_end = s.indexOf(')', close + 2);
    if (target_end < 0) {
        t.kind = Token::TEXT;
        t.text = s.mid(start, 1);
        *end = start + 1;
        return t;
    }
    t.text = s.mid(start + 1, close - start - 1);
    t.target = s.mid(close + 2, target_end - close - 2);
    *end = target_end + 1;
    return t;
}

// Splits a line into TEXT / CODE (`backtick`) / LINK ([label](target)) runs.
static std::vector<Token> tokenize(const QString& s) {
    std::vector<Token> out;
    int i = 0;
    while (i < s.size()) {
        if (s[i] == '`') {
            int end = s.indexOf('`', i + 1);
            if (end < 0) {
                out.push_back({Token::TEXT, s.mid(i), {}});
                break;
            }
            out.push_back({Token::CODE, s.mid(i + 1, end - i - 1), {}});
            i = end + 1;
            continue;
        }
        if (s[i] == '[') {
            int end = 0;
            Token t = parse_link(s, i, &end);
            out.push_back(t);
            i = end;
            continue;
        }
        int next = s.indexOf('`', i);
        int next_link = s.indexOf('[', i);
        int stop = s.size();
        if (next >= 0) stop = std::min(stop, next);
        if (next_link >= 0) stop = std::min(stop, next_link);
        out.push_back({Token::TEXT, s.mid(i, stop - i), {}});
        i = stop;
    }
    return out;
}

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

void Trail_View::add_link(const QString& label, const QString& target) {
    // Scene chips are buttons (amber on hover); trail links are flat links.
    if (target.startsWith("scene:")) {
        auto* chip = new QPushButton(label, page_);
        chip->setCursor(Qt::PointingHandCursor);
        chip->setFlat(true);
        chip->setStyleSheet(
            "QPushButton { text-align: left; color: #e8a857;"
            " background: rgba(232,168,87,0.10); border: 1px solid"
            " rgba(232,168,87,0.35); border-radius: 5px; padding: 4px 10px; }"
            "QPushButton:hover { background: rgba(232,168,87,0.22); }");
        connect(chip, &QPushButton::clicked, this, [this, target] {
            follow_link(target);
        });
        page_layout_->addWidget(chip);
        return;
    }
    auto* link = new QPushButton(label, page_);
    link->setCursor(Qt::PointingHandCursor);
    link->setFlat(true);
    link->setStyleSheet(
        "QPushButton { text-align: left; color: #9ec2f2; background:"
        " transparent; border: none; padding: 0; font-weight: 600; }"
        "QPushButton:hover { color: #c9e0f9; }");
    connect(link, &QPushButton::clicked, this, [this, target] {
        follow_link(target);
    });
    page_layout_->addWidget(link);
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
        add_link(i18n::tr("← all trails"), "trail:index");
    }

    bool in_code = false;
    QString code_acc;
    QStringList prose; // paragraph accumulator

    auto flush_paragraph = [&]() {
        if (prose.isEmpty()) return;
        QLabel* p = new QLabel(prose.join(' '));
        p->setWordWrap(true);
        p->setTextFormat(Qt::RichText);
        p->setStyleSheet("color: #d7dae2; font-size: 10pt; line-height: 150%;");
        p->setOpenExternalLinks(false);
        page_layout_->addWidget(p);
        prose.clear();
    };

    const QStringList lines = split_lines(text);
    for (int li = 0; li < lines.size(); ++li) {
        const QString& line = lines[li];
        if (line.startsWith("```")) {
            if (in_code) {
                // Close block: one host panel, every line a mono label.
                QWidget* block = new QWidget();
                block->setStyleSheet(
                    "background: #101116; border-radius: 6px;");
                auto* block_layout = new QVBoxLayout(block);
                block_layout->setContentsMargins(12, 8, 12, 8);
                block_layout->setSpacing(0);
                const QStringList code_lines = code_acc.split('\n');
                for (const QString& cl : code_lines) {
                    QLabel* code = new QLabel(cl.toHtmlEscaped());
                    code->setTextFormat(Qt::RichText);
                    code->setStyleSheet(
                        "color: #c9cdd6; background: transparent;"
                        " font-family: 'JetBrains Mono', monospace;"
                        " font-size: 9pt;");
                    block_layout->addWidget(code);
                }
                page_layout_->addWidget(block);
                code_acc.clear();
                in_code = false;
            } else {
                flush_paragraph();
                in_code = true;
            }
            continue;
        }
        if (in_code) {
            code_acc += (code_acc.isEmpty() ? "" : "\n") + line;
            continue;
        }
        if (line.startsWith('#')) {
            flush_paragraph();
            int level = 0;
            while (level < line.size() && line[level] == '#') ++level;
            QString title = line.mid(level).trimmed();
            QLabel* h = new QLabel(title.toHtmlEscaped());
            h->setWordWrap(true);
            h->setTextFormat(Qt::RichText);
            if (level == 1)
                h->setStyleSheet(
                    "color: #f2f3f7; font-family: 'Sergamon'; font-size: 17pt;"
                    " font-weight: 600; padding: 4px 0;");
            else
                h->setStyleSheet(
                    "color: #d7dae2; font-size: 11pt; font-weight: 600;"
                    " padding: 8px 0 2px 0;");
            page_layout_->addWidget(h);
            continue;
        }
        if (line.startsWith("- ")) {
            flush_paragraph();
            std::vector<Token> toks = tokenize(line.mid(2));
            QString rich = "•  ";
            for (const Token& t : toks) {
                if (t.kind == Token::CODE)
                    rich += "<code style=\"background:#101116; border-radius:3px;"
                            " padding:1px 4px; color:#a9d49e;\">" +
                            t.text.toHtmlEscaped() + "</code>";
                else
                    rich += t.text.toHtmlEscaped();
            }
            QLabel* item = new QLabel(rich);
            item->setWordWrap(true);
            item->setTextFormat(Qt::RichText);
            item->setStyleSheet("color: #d7dae2; font-size: 10pt;");
            item->setContentsMargins(10, 0, 0, 0);
            page_layout_->addWidget(item);
            continue;
        }
        if (line.trimmed().isEmpty()) {
            flush_paragraph();
            continue;
        }
        // Prose line: tokenize into text/code/links; links become widgets
        // BETWEEN word labels so wrapping stays native.
        std::vector<Token> toks = tokenize(line);
        QWidget* row = new QWidget();
        auto* row_layout = new QHBoxLayout(row);
        row_layout->setContentsMargins(0, 0, 0, 0);
        row_layout->setSpacing(4);
        QString acc;
        auto flush_acc = [&]() {
            if (acc.isEmpty()) return;
            QLabel* l = new QLabel(acc);
            l->setWordWrap(true);
            l->setTextFormat(Qt::RichText);
            l->setStyleSheet("color: #d7dae2; font-size: 10pt;");
            row_layout->addWidget(l, 1);
            acc.clear();
        };
        bool has_link = false;
        for (const Token& t : toks) {
            if (t.kind == Token::TEXT) {
                acc += t.text.toHtmlEscaped() + " ";
            } else if (t.kind == Token::CODE) {
                acc += "<code style=\"background:#101116; border-radius:3px;"
                       " padding:1px 4px; color:#a9d49e;\">" +
                       t.text.toHtmlEscaped() + "</code> ";
            } else {
                has_link = true;
                flush_acc();
                add_link(t.text, t.target);
            }
        }
        if (!has_link) {
            prose << acc.trimmed(); // joins the running paragraph
            delete row;
            continue;
        }
        flush_paragraph();
        flush_acc();
        row_layout->addStretch(1);
        page_layout_->addWidget(row);
    }
    flush_paragraph();
    page_layout_->addStretch(1);
}

} // namespace learn
