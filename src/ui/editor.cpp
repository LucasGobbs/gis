// Editor implementation: QScintilla tabs per open doc, unit loading, save
// all, and the slangd LSP client over stdio JSON-RPC.
#include "editor.hpp"
#include "theme.hpp"
#include "i18n.hpp"
#include "notify.hpp"
#include <QShortcut>
#include <QKeyEvent>
#include <Qsci/qsciscintilla.h>
#include <Qsci/qsciscintillabase.h>
#include <QHBoxLayout>
#include <QLineEdit>
#include <QLabel>
#include <QPushButton>
#include <Qsci/qscilexercpp.h>
#include <QSplitter>
#include <cmath>

#include <QApplication>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QProcess>
#include <cstdlib>

#include <cmath>

namespace editor {

static const char* kShaderDir = "src/shaders";
QString Editor::file_path_for_rel(const QString& rel) const {
    if (rel.startsWith("gis_scenes/")) return rel + ".slang";
    // LSP locations arrive as full rels ("src/shaders/common"); editor rels
    // from rescan omit the prefix. Pass full rels through untouched.
    if (rel.startsWith(QString(kShaderDir) + "/")) return rel + ".slang";
    return QString(kShaderDir) + "/" + rel + ".slang";
}

Editor::Editor(QWidget* parent) : QTabWidget(parent) {
    setTabsClosable(true);
    setMovable(true);
    setDocumentMode(true);
    connect(this, &QTabWidget::currentChanged, this, &Editor::on_tab_changed);
    connect(this, &QTabWidget::tabCloseRequested, this, [this](int index) {
        if (index < 0 || index >= (int)open_docs_.size()) return;
        if (open_docs_[size_t(index)].dirty) return; // unsaved work is never destroyed
        QWidget* w = open_docs_[size_t(index)].widget;
        removeTab(index);
        open_docs_.erase(open_docs_.begin() + index);
        if (w) w->deleteLater();
    });

    // Cmd+F find bar: floats over the active tab (QTabWidget corner widgets
    // only own the tab-row strip, which reads as chrome, not overlay).
    find_bar_ = new QWidget(this);
    find_bar_->setObjectName("findBar");
    find_bar_->setStyleSheet(
        "QWidget#findBar { background: #1e2026; border: 1px solid #3a3d45;"
        " border-radius: 6px; }"
        "QLineEdit { background: transparent; border: none; color: #dfe0e6;"
        " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
        "QLabel { color: #8c9099; font-size: 8pt; }"
        "QPushButton { background: rgba(255,255,255,0.06); border: none;"
        " border-radius: 4px; color: #dfe0e6; padding: 2px 8px; }"
        "QPushButton:hover { background: rgba(255,255,255,0.12); }");
    auto* find_layout = new QHBoxLayout(find_bar_);
    find_layout->setContentsMargins(8, 4, 8, 4);
    find_layout->setSpacing(6);
    auto* prev = new QPushButton("↑", find_bar_);
    auto* next = new QPushButton("↓", find_bar_);
    prev->setToolTip(i18n::tr("find previous"));
    next->setToolTip(i18n::tr("find next"));
    prev->setFocusPolicy(Qt::NoFocus);
    next->setFocusPolicy(Qt::NoFocus);
    find_status_ = new QLabel(find_bar_);
    find_edit_ = new QLineEdit(find_bar_);
    find_edit_->setPlaceholderText(i18n::tr("find in file"));
    find_layout->addWidget(find_edit_, 1);
    find_layout->addWidget(find_status_);
    find_layout->addWidget(prev);
    find_layout->addWidget(next);
    auto* close = new QPushButton("✕", find_bar_);
    close->setFocusPolicy(Qt::NoFocus);
    find_layout->addWidget(close);
    connect(find_edit_, &QLineEdit::returnPressed, this, &Editor::find_next);
    connect(find_edit_, &QLineEdit::textChanged, this, &Editor::find_next);
    connect(next, &QPushButton::clicked, this, &Editor::find_next);
    connect(prev, &QPushButton::clicked, this, [this] {
        QsciScintilla* ed = current_editor();
        if (!ed || find_edit_->text().isEmpty()) return;
        bool found = ed->findFirst(find_edit_->text(), /*re*/ false,
                                   /*cs*/ false, /*wo*/ false, /*wrap*/ true,
                                   /*forward*/ false);
        find_status_->setText(found ? QString() : i18n::tr("no matches"));
    });
    connect(close, &QPushButton::clicked, this, &Editor::hide_find);
    find_bar_->hide();
    auto* find_sc = new QShortcut(QKeySequence::Find, this);
    find_sc->setContext(Qt::WidgetWithChildrenShortcut);
    connect(find_sc, &QShortcut::activated, this, &Editor::open_find);
    auto* find_next_sc = new QShortcut(QKeySequence("Ctrl+G"), this);
    find_next_sc->setContext(Qt::WidgetWithChildrenShortcut);
    connect(find_next_sc, &QShortcut::activated, this, &Editor::find_next);
    auto* esc_sc = new QShortcut(QKeySequence("Escape"), find_bar_);
    esc_sc->setContext(Qt::WidgetWithChildrenShortcut);
    connect(esc_sc, &QShortcut::activated, this, &Editor::hide_find);
    // Split toggle lives OUTSIDE the tab row: a floating button docked at
    // the tab widget's bottom-right. The tab-row corners collide with the
    // PiP preview (top-right) or the first tab (top-left); the bottom
    // strip stays free in every preview mode.
    split_btn_ = new QPushButton("⫿", this);
    split_btn_->setObjectName("splitBtn");
    split_btn_->setToolTip(i18n::tr("split editor"));
    split_btn_->setAccessibleName(i18n::tr("split editor"));
    split_btn_->setFocusPolicy(Qt::NoFocus);
    split_btn_->setFixedSize(26, 22);
    split_btn_->setStyleSheet(
        "QPushButton#splitBtn { background: rgba(255,255,255,0.06);"
        " border: none; border-radius: 4px; color: #8c9099; font-size: 9pt; }"
        "QPushButton#splitBtn:hover { background: rgba(255,255,255,0.14);"
        " color: #DEE0E6; }");
    connect(split_btn_, &QPushButton::clicked, this, &Editor::split_current);
}

void Editor::rescan() {
    files_.clear();
    QDirIterator it("src/shaders", QStringList() << "*.slang", QDir::Files,
                    QDirIterator::Subdirectories);
    // rel is relative to src/shaders (scenes/<scene>/<name>), matching
    // load_unit's prefix and file_path_for_rel.
    while (it.hasNext()) {
        QString rel = it.next();
        if (rel.endsWith(".slang")) rel.chop(6);
        if (rel.startsWith("src/shaders/")) rel.remove(0, 12);
        files_.push_back(rel);
    }
    // gis_scenes units: <unit>/<file>.slang -> rel "gis_scenes/<unit>/<file>"
    QDirIterator user("gis_scenes", QStringList() << "*.slang", QDir::Files,
                      QDirIterator::Subdirectories);
    while (user.hasNext()) {
        QString path = user.next();
        QString rel = path;
        if (rel.endsWith(".slang")) rel.chop(6);
        files_.push_back(rel);
    }
    std::sort(files_.begin(), files_.end());
}

QsciScintilla* Editor::current_editor() {
    QWidget* w = currentWidget();
    if (!w) return nullptr;
    Open_Doc* doc = doc_for_widget(w);
    return doc ? doc->widget : nullptr;
}

Open_Doc* Editor::find_doc(const QString& rel) {
    for (Open_Doc& doc : open_docs_)
        if (doc.rel == rel) return &doc;
    return nullptr;
}

Open_Doc* Editor::doc_for_widget(QWidget* widget) {
    for (Open_Doc& doc : open_docs_)
        if (doc.widget == widget) return &doc;
    return nullptr;
}

// Slang lexer: C++ rules + slang type keywords in keyword set 2 (styled
// distinctly from the base C++ keywords). Without this, float2/RWTexture2D/
// SamplerState render as plain identifiers.
class Slang_Lexer : public QsciLexerCPP {
public:
    explicit Slang_Lexer(QObject* parent = nullptr) : QsciLexerCPP(parent) {}
    const char* keywords(int set) const override {
        if (set == 2)
            return "float float1 float2 float3 float4 int int1 int2 int3 int4 "
                   "uint uint1 uint2 uint3 uint4 bool bool1 bool2 bool3 bool4 "
                   "half half1 half2 half3 half4 double min16float min12int "
                   "min16uint min10int float2x2 float3x3 float4x4 float4x2 "
                   "Texture1D Texture2D Texture3D TextureCube RWTexture1D "
                   "RWTexture2D RWTexture3D SamplerState SamplerComparisonState "
                   "ConstantBuffer StructuredBuffer RWStructuredBuffer "
                   "AppendStructuredBuffer ConsumeStructuredBuffer Buffer "
                   "RWBuffer InputPatch OutputPatch void struct enum class "
                   "public private protected static const uniform groupshared "
                   "cbuffer tbuffer interface in out inout using typedef "
                   "template typename this discard return if else for while "
                   "do switch case default break continue true false nullptr "
                   "namespace operator new delete register row_major "
                   "column_major unorm snorm matrix vector";
        return QsciLexerCPP::keywords(set);
    }
};

// One skin per theme, applied to the widget + its lexer. Every Scintilla
// style gets an explicit color: styles left untouched fall back to the
// lexer's built-in dark-on-white defaults (the "punctuation turned black"
// bug). DARK = Darkroom tokens; MONOKAI/SOLARIZED/LIGHT are the standard
// schemes.
static void apply_skin(QsciScintilla* edit, Editor_Theme theme) {
    struct Skin {
        QColor paper, text, keyword, type, number, comment, string,
               preproc, operator_, margin_bg, margin_fg, caret_line,
               selection_bg, selection_fg;
    };
    Skin s;
    switch (theme) {
    case Editor_Theme::MONOKAI:
        s = {QColor(0x27, 0x28, 0x22), QColor(0xf8, 0xf8, 0xf2),
             QColor(0xf9, 0x26, 0x72), QColor(0xa6, 0xe2, 0x2e),
             QColor(0xae, 0x81, 0xff), QColor(0x75, 0x71, 0x5e),
             QColor(0xe6, 0xdb, 0x74), QColor(0xfd, 0x97, 0x1f),
             QColor(0xf8, 0xf8, 0xf2), QColor(0x1e, 0x1f, 0x1a),
             QColor(0x75, 0x71, 0x5e), QColor(0x32, 0x33, 0x2b),
             QColor(0x49, 0x48, 0x34), QColor(0xf8, 0xf8, 0xf2)};
        break;
    case Editor_Theme::SOLARIZED:
        s = {QColor(0x00, 0x2b, 0x36), QColor(0x93, 0xa1, 0xa1),
             QColor(0x85, 0x99, 0x00), QColor(0xb5, 0x89, 0x00),
             QColor(0x2a, 0xa1, 0x98), QColor(0x58, 0x6e, 0x75),
             QColor(0x2a, 0xa1, 0x98), QColor(0xcb, 0x4b, 0x16),
             QColor(0x93, 0xa1, 0xa1), QColor(0x07, 0x36, 0x42),
             QColor(0x58, 0x6e, 0x75), QColor(0x07, 0x3d, 0x4a),
             QColor(0x27, 0x46, 0x52), QColor(0xee, 0xed, 0xd5)};
        break;
    case Editor_Theme::LIGHT:
        s = {QColor(0xff, 0xff, 0xff), QColor(0x1f, 0x20, 0x24),
             QColor(0x1c, 0x46, 0x9c), QColor(0x78, 0x35, 0x96),
             QColor(0x9c, 0x42, 0x2e), QColor(0x6f, 0x74, 0x7e),
             QColor(0x1d, 0x6b, 0x33), QColor(0x9a, 0x5b, 0x0a),
             QColor(0x2c, 0x30, 0x3a), QColor(0xf2, 0xf3, 0xf5),
             QColor(0x8c, 0x90, 0x99), QColor(0xff, 0xf3, 0xd6),
             QColor(0xd8, 0xe2, 0xf4), QColor(0x1f, 0x20, 0x24)};
        break;
    default: // DARK = Darkroom: quiet proof text, one accent per token class.
        s = {QColor(0x13, 0x14, 0x18), QColor(0xd7, 0xda, 0xe2),
             QColor(0xe8, 0xa8, 0x57),          // keywords: Safelight amber
             QColor(0x9e, 0xc2, 0xf2),          // slang types: soft blue
             QColor(0xf2, 0x8c, 0x7a),          // numbers: muted rose
             QColor(0x78, 0x7d, 0x88),          // comments: Fog Gray
             QColor(0xa9, 0xd4, 0x9e),          // strings: soft green
             QColor(0xc9, 0x9e, 0xf2),          // preprocessor: soft violet
             QColor(0x8c, 0x90, 0x99),          // operators: mid gray
             QColor(0x1a, 0x1b, 0x20), QColor(0x75, 0x7a, 0x85),
             QColor(0xff, 0xff, 0xff, 0x0d), QColor(0x3a, 0x2c, 0x18),
             QColor(0xde, 0xe0, 0xe6)};
        break;
    }
    QColor paper = s.paper;
    QColor margin_bg = s.margin_bg; margin_bg.setAlpha(140);
    // Caret line: derived (paper blended toward the text color) instead of
    // the margin fg — margin grays (#75715e MONOKAI, #586e75 SOLARIZED) at
    // alpha 140 read as a DARKER stripe than the paper (the "line went
    // dark" bug). DARK keeps its authored translucent white.
    QColor caret_line = s.caret_line;
    if (theme != Editor_Theme::DARK)
        caret_line = QColor::fromRgbF(
            s.paper.redF() * 0.92 + s.text.redF() * 0.08,
            s.paper.greenF() * 0.92 + s.text.greenF() * 0.08,
            s.paper.blueF() * 0.92 + s.text.blueF() * 0.08);
    caret_line.setAlpha(140);
    auto* lexer = dynamic_cast<Slang_Lexer*>(edit->lexer());
    if (lexer) {
        auto color = [&s](int style) {
            if (style == QsciLexerCPP::Keyword) return s.keyword;
            if (style == QsciLexerCPP::KeywordSet2 ||
                style == QsciLexerCPP::GlobalClass)
                return s.type;
            if (style == QsciLexerCPP::Comment ||
                style == QsciLexerCPP::CommentLine ||
                style == QsciLexerCPP::CommentLineDoc ||
                style == QsciLexerCPP::CommentDoc ||
                style == QsciLexerCPP::CommentDocKeyword ||
                style == QsciLexerCPP::CommentDocKeywordError)
                return s.comment;
            if (style == QsciLexerCPP::Number || style == QsciLexerCPP::UUID)
                return s.number;
            if (style == QsciLexerCPP::DoubleQuotedString ||
                style == QsciLexerCPP::SingleQuotedString ||
                style == QsciLexerCPP::UnclosedString ||
                style == QsciLexerCPP::VerbatimString ||
                style == QsciLexerCPP::RawString)
                return s.string;
            if (style == QsciLexerCPP::PreProcessor) return s.preproc;
            if (style == QsciLexerCPP::Operator) return s.operator_;
            return s.text;
        };
        lexer->setFont(theme::code_font(12));
        for (int style = 0; style <= QsciLexerCPP::RawString; ++style) {
            lexer->setColor(color(style), style);
            lexer->setPaper(paper, style);
        }
    }
    // STYLE_DEFAULT (style 32) owns every style NOT explicitly set above
    // (blank lines, line ends): without it, lines with no text painted the
    // lexer's light default paper.
    edit->SendScintilla(QsciScintillaBase::SCI_STYLESETBACK, 32, paper);
    edit->setPaper(paper); // widget-level default (QsciScintilla base style)
    edit->setMarginsBackgroundColor(margin_bg);
    edit->setMarginsForegroundColor(s.margin_fg);
    edit->setCaretForegroundColor(s.text);
    edit->setCaretLineVisible(true);
    edit->setCaretLineBackgroundColor(caret_line);
    // Opaque selection: translucent backgrounds left glyphs unreadable.
    edit->setSelectionBackgroundColor(s.selection_bg);
    edit->setSelectionForegroundColor(s.selection_fg);
    edit->setIndentationGuidesBackgroundColor(margin_bg);
    edit->setIndentationGuidesForegroundColor(s.caret_line);
    edit->setMatchedBraceBackgroundColor(caret_line);
    edit->setMatchedBraceForegroundColor(QColor(0xe8, 0xa8, 0x57));
}

void Editor::load_named(const QString& rel) {
    if (Open_Doc* existing = find_doc(rel)) {
        setCurrentIndex(int(existing - open_docs_.data()));
        return;
    }
    QString path = file_path_for_rel(rel);
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        status_ = "could not read " + path;
        emit status_changed(status_);
        return;
    }
    QString text = QString::fromUtf8(f.readAll());

    Open_Doc doc;
    doc.rel = rel;
    doc.path = path;
    doc.text = text;
    doc.loaded = true;

    auto* edit = new QsciScintilla(this);
    auto* lexer = new Slang_Lexer(edit);
    lexer->setFont(theme::code_font(12));
    edit->setLexer(lexer);
    edit->setText(text);
    edit->setMarginWidth(0, 4); // line numbers width set by lexer
    edit->setMarginLineNumbers(1, true);
    edit->setMarginWidth(1, "0000");
    edit->setUtf8(true);
    edit->setFont(theme::code_font(12));
    edit->setTabWidth(4);
    edit->setIndentationsUseTabs(false);
    edit->setAutoCompletionSource(QsciScintilla::AcsDocument); // words already typed in this file
    edit->setAutoCompletionThreshold(2);
    apply_skin(edit, theme_);
    // Cmd+click goto-def + Cmd-hover underline: my filter on the viewport
    // runs before Qsci's own (install order = reverse run order), so the
    // press is interceptable. Mouse tracking keeps Move events flowing while
    // a button is up (needed for hover underline).
    edit->viewport()->installEventFilter(this);
    edit->viewport()->setMouseTracking(true);
    // Link underline style: PlainIndicator = single straight line, Safelight
    // amber (state, per the Safelight Rule). Index 9; 8 = diagnostics.
    edit->indicatorDefine(QsciScintilla::PlainIndicator, 9);
    edit->setIndicatorForegroundColor(QColor(0xe8, 0xa8, 0x57), 9);
    edit->setIndicatorDrawUnder(true, 9);
    // Hover docs: dwell 500 ms over an identifier -> textDocument/hover.
    // Over a diagnostic squiggle the dwell shows the DIAGNOSTIC message
    // instead of a slangd hover card (the local answer wins: it is always
    // current with what is painted).
    edit->SendScintilla(QsciScintillaBase::SCI_SETMOUSEDWELLTIME, 500);
    connect(edit, &QsciScintillaBase::SCN_DWELLSTART, this, [this, edit](int pos) {
        if (pos < 0) return;
        QString uri = doc_uri(edit);
        QString diag = diag_message_at(uri, pos);
        if (!diag.isEmpty()) {
            edit->setToolTip(diag);
            return;
        }
        int line = int(edit->SendScintilla(QsciScintillaBase::SCI_LINEFROMPOSITION, pos));
        int col = int(edit->SendScintilla(QsciScintillaBase::SCI_GETCOLUMN, pos));
        lsp_hover(uri, line, col);
    });
    connect(edit, &QsciScintillaBase::SCN_DWELLEND, edit, [edit] {
        edit->setToolTip(QString()); // clear the hover card when the mouse leaves
    });
    // Any keystroke invalidates the painted diagnostics for THIS doc: the
    // squiggles/markers describe old text, so drop them (the 280 ms
    // debounced didChange brings fresh ones when slangd re-parses).
    connect(edit, &QsciScintilla::textChanged, edit, [edit] {
        edit->SendScintilla(QsciScintillaBase::SCI_SETINDICATORCURRENT, 8);
        edit->SendScintilla(QsciScintillaBase::SCI_INDICATORCLEARRANGE, 0,
                            long(edit->SendScintilla(
                                QsciScintillaBase::SCI_GETLENGTH)));
    });
    connect(edit, &QsciScintilla::modificationChanged, this,
            [this, edit](bool) { on_modified(indexOf(edit)); });
    // Completion on identifier/'.' typing: send fresh text first (the debounced
    // didChange lags 280 ms), then ask slangd. Result is shown in the handler.
    connect(edit, &QsciScintilla::textChanged, this, [this, edit, path] {
        int line = 0, col = 0;
        edit->getCursorPosition(&line, &col);
        QString l = edit->text(line);
        if (col <= 0 || col > l.size()) return;
        QChar c = l[col - 1];
        if (!(c.isLetterOrNumber() || c == '_' || c == '.')) return;
        QString uri = "file://" + QFileInfo(path).absoluteFilePath();
        lsp_did_change(uri, edit->text());
        lsp_completion(uri, line, col);
    });

    doc.widget = edit;
    open_docs_.push_back(doc);
    addTab(edit, rel.section('/', -1));
    setCurrentIndex(int(open_docs_.size()) - 1);

    // did-open for the LSP.
    QString uri = "file://" + QFileInfo(path).absoluteFilePath();
    lsp_did_open(uri, text);
}

QString Editor::doc_uri(const QsciScintilla* edit) const {
    for (const Open_Doc& doc : open_docs_)
        if (doc.widget == edit)
            return "file://" + QFileInfo(doc.path).absoluteFilePath();
    return QString();
}

void Editor::resizeEvent(QResizeEvent* event) {
    QTabWidget::resizeEvent(event);
    reposition_split_button();
}

void Editor::reposition_split_button() {
    if (!split_btn_) return;
    // Split ON: the preview owns the bottom-right, so the toggle flips to
    // the bottom-left (still visible/clickable to turn the split off).
    const int x = split_on_ ? 8 : width() - split_btn_->width() - 8;
    split_btn_->move(x, height() - split_btn_->height() - 8);
    split_btn_->raise();
}

bool Editor::eventFilter(QObject* watched, QEvent* event) {
    // Editor viewport events: Cmd+click -> definition; Cmd held over a word
    // -> underline it (the clickable affordance). Per-viewport filter, so it
    // runs before QsciScintillaBase's own viewport filter.
    auto* edit = qobject_cast<QsciScintilla*>(watched->parent());
    if (!edit || !doc_for_widget(edit)) return QTabWidget::eventFilter(watched, event);

    switch (event->type()) {
    case QEvent::Wheel: {
        // Smooth scroll: QScintilla's wheel path jumps whole lines. Convert
        // the wheel delta into first-visible-line steps through a fractional
        // accumulator (angleDelta: ~7 lines per notch; trackpad pixelDelta
        // drives 1:1 for true pixel smoothness). The sub-line remainder
        // persists between events so slow wheels still move eventually.
        auto* wheel = static_cast<QWheelEvent*>(event);
        double line_h = edit->textHeight(0);
        if (line_h <= 0) line_h = 1;
        double steps = 0;
        if (!wheel->pixelDelta().isNull()) {
            steps = -wheel->pixelDelta().y() / line_h;
        } else {
            steps = -wheel->angleDelta().y() / (8.0 * 120.0) * 7.0;
        }
        scroll_acc_ += steps;
        double whole = 0;
        scroll_acc_ = std::modf(scroll_acc_, &whole);
        if (whole != 0) {
            long first = long(edit->SendScintilla(QsciScintillaBase::SCI_GETFIRSTVISIBLELINE));
            long total = long(edit->SendScintilla(QsciScintillaBase::SCI_GETLINECOUNT));
            long vis = long(edit->SendScintilla(QsciScintillaBase::SCI_LINESONSCREEN));
            long target = std::clamp(first + long(whole), 0L, std::max(0L, total - vis));
            edit->SendScintilla(QsciScintillaBase::SCI_SETFIRSTVISIBLELINE, target);
        }
        return true; // the default wheel handler would double-step
    }
    case QEvent::MouseButtonPress: {
        auto* e = static_cast<QMouseEvent*>(event);
        // Qt maps the macOS Command key to ControlModifier (0x04000000);
        // MetaModifier is the Option-key position on this platform.
        if (e->modifiers() & (Qt::ControlModifier | Qt::MetaModifier)) {
            int line = 0, col = 0;
            if (line_col_at(edit, e->pos(), line, col)) {
                lsp_goto_def(doc_uri(edit), line, col);
                return true; // consume: no caret jump
            }
        }
        break;
    }
    case QEvent::MouseMove: {
        auto* e = static_cast<QMouseEvent*>(event);
        bool cmd = e->modifiers() & (Qt::ControlModifier | Qt::MetaModifier);
        update_link_underline(edit, e->pos(), cmd);
        break;
    }
    case QEvent::KeyPress:
    case QEvent::KeyRelease: {
        auto* e = static_cast<QKeyEvent*>(event);
        if (e->modifiers() & (Qt::ControlModifier | Qt::MetaModifier)) {
            update_link_underline(edit, edit->viewport()->mapFromGlobal(QCursor::pos()),
                                  event->type() == QEvent::KeyPress);
        } else {
            update_link_underline(edit, QPoint(-1, -1), false); // clear
        }
        break;
    }
    case QEvent::Leave:
        update_link_underline(edit, QPoint(-1, -1), false);
        break;
    default:
        break;
    }
    return QTabWidget::eventFilter(watched, event);
}

bool Editor::line_col_at(QsciScintilla* edit, const QPoint& vp, int& line, int& col) {
    // Viewport pos -> doc line/col (0-based, LSP style). Scintilla's point
    // mapping counts the margin area, so add the margins' width back (the
    // event is viewport-relative).
    int margins = edit->marginWidth(0) + edit->marginWidth(1);
    long pos = long(edit->SendScintilla(
        QsciScintillaBase::SCI_POSITIONFROMPOINT,
        (unsigned long)(vp.x() + margins), (unsigned long)(vp.y())));
    if (pos < 0) return false;
    line = int(edit->SendScintilla(QsciScintillaBase::SCI_LINEFROMPOSITION, pos));
    col = int(edit->SendScintilla(QsciScintillaBase::SCI_GETCOLUMN, pos));
    return true;
}

void Editor::update_link_underline(QsciScintilla* edit, const QPoint& vp, bool cmd) {
    // Underline the identifier under the cursor while Cmd is held; clear on
    // release/leave. One custom indicator (kLink), Plain = straight line.
    static const int kLink = 9; // 8 = diagnostics squiggle
    edit->SendScintilla(QsciScintillaBase::SCI_SETINDICATORCURRENT, kLink);
    edit->SendScintilla(QsciScintillaBase::SCI_INDICATORCLEARRANGE, 0,
                        long(edit->SendScintilla(QsciScintillaBase::SCI_GETLENGTH)));
    if (!cmd) {
        edit->viewport()->unsetCursor();
        return;
    }
    int line = 0, col = 0;
    if (!line_col_at(edit, vp, line, col)) return;
    QString text = edit->text(line);
    int s = std::min(col, (int)text.size());
    while (s > 0 && (text[s - 1].isLetterOrNumber() || text[s - 1] == '_')) --s;
    int e = std::min(col, (int)text.size());
    while (e < (int)text.size() &&
           (text[e].isLetterOrNumber() || text[e] == '_'))
        ++e;
    if (e <= s) { // not over a word
        edit->viewport()->unsetCursor();
        return;
    }
    edit->fillIndicatorRange(line, s, line, e, kLink);
    edit->viewport()->setCursor(Qt::PointingHandCursor);
}

void Editor::set_theme(Editor_Theme theme) {
    theme_ = theme;
    for (Open_Doc& doc : open_docs_)
        if (doc.widget) apply_skin(doc.widget, theme);
}

// Applies font_size_ to every open doc (widget + lexer), margins included.
void Editor::apply_font() {
    QFont f = theme::code_font(font_size_);
    for (Open_Doc& doc : open_docs_) {
        if (!doc.widget) continue;
        doc.widget->setFont(f);
        if (auto* lex = dynamic_cast<Slang_Lexer*>(doc.widget->lexer()))
            lex->setFont(f);
        doc.widget->setMarginWidth(1, QString(font_size_ / 2 + 2, '0'));
    }
}

void Editor::set_editor_font(int pt) {
    font_size_ = pt;
    apply_font();
}

void Editor::zoom_in() {
    if (font_size_ >= 28) return;
    font_size_ += 1;
    apply_font();
    emit font_changed(font_size_);
}

void Editor::zoom_out() {
    if (font_size_ <= 8) return;
    font_size_ -= 1;
    apply_font();
    emit font_changed(font_size_);
}

void Editor::load_unit(const QString& scene_title, const QString& root_dir) {
    QString prefix = root_dir == "gis_scenes"
                         ? QString("gis_scenes/%1/").arg(scene_title)
                         : QString("scenes/%1/").arg(scene_title);
    unit_prefix_ = prefix;
    for (long i = long(open_docs_.size()) - 1; i >= 0; --i) {
        if (open_docs_[size_t(i)].dirty) continue;
        if (open_docs_[size_t(i)].rel.startsWith(prefix)) continue;
        QWidget* w = open_docs_[size_t(i)].widget;
        removeTab(i);
        if (w) w->deleteLater();
        open_docs_.erase(open_docs_.begin() + i);
    }
    // Open the unit's own files.
    for (const QString& rel : files_) {
        if (rel.startsWith(prefix)) load_named(rel);
    }
    if (open_docs_.empty()) return;
    // Defer slangd: a QProcess spawn during Shell construction raced
    // MTLCompilerService and the FIRST scene's pipeline creation failed
    // deterministically (scene load after gfx_create is fine). 3 s lands
    // well after GPU init; didOpen still fires on tab activation.
    if (qEnvironmentVariableIsSet("GIS_NO_LSP")) return;
    QTimer::singleShot(3000, this, [this] { lsp_start("."); });
    return;
}

int Editor::dirty_count() const {
    int n = 0;
    for (const Open_Doc& doc : open_docs_) n += doc.dirty ? 1 : 0;
    return n;
}

void Editor::close_current_tab() {
    int index = currentIndex();
    if (index < 0 || index >= (int)open_docs_.size()) return;
    if (open_docs_[size_t(index)].dirty) return; // unsaved work is never destroyed
    QWidget* w = open_docs_[size_t(index)].widget;
    removeTab(index);
    open_docs_.erase(open_docs_.begin() + index);
    if (w) w->deleteLater();
}

int Editor::save_all() {
    int saved = 0;
    for (Open_Doc& doc : open_docs_) {
        if (!doc.loaded || !doc.dirty) continue;
        QFile f(doc.path);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            status_ = "ERROR writing " + doc.path;
            emit status_changed(status_);
            continue;
        }
        doc.text = doc.widget->text();
        const QByteArray bytes = doc.text.toUtf8();
        const qint64 written = f.write(bytes);
        f.close();
        if (written != bytes.size() || f.error() != QFileDevice::NoError) {
            status_ = "ERROR writing " + doc.path;
            emit status_changed(status_);
            continue; // keep dirty: a partial write must not lose the doc
        }
        doc.dirty = false;
        // did-save for the LSP.
        lsp_did_save("file://" + QFileInfo(doc.path).absoluteFilePath());
    }
    status_ = saved > 0 ? QString("saved %1 file(s)").arg(saved) : status_;
    if (saved > 0) emit status_changed(status_);
    return saved;
}

void Editor::on_tab_changed(int index) {
    if (index < 0 || index >= (int)open_docs_.size()) return;
    lsp_did_open("file://" + QFileInfo(open_docs_[size_t(index)].path).absoluteFilePath(),
                 open_docs_[size_t(index)].widget->text());
}

void Editor::on_modified(int index) {
    if (index < 0 || index >= (int)open_docs_.size()) return;
    Open_Doc& doc = open_docs_[size_t(index)];
    doc.dirty = doc.widget->isModified();
    QString label = doc.rel.section('/', -1) + (doc.dirty ? " •" : "");
    setTabText(index, label);
    // Debounced did-change for the LSP (slangd re-parses on content change;
    // the 18-frame debounce lands as a 280 ms timer at 60 fps).
    QMap<QString, QTimer*>& timers = lsp_timers_; // rel -> debounce timer
    if (!timers.contains(doc.rel)) {
        auto* timer = new QTimer(this);
        timer->setSingleShot(true);
        timer->setInterval(280);
        connect(timer, &QTimer::timeout, this, [this, rel = doc.rel] {
            Open_Doc* d = find_doc(rel);
            if (d)
                lsp_did_change("file://" + QFileInfo(d->path).absoluteFilePath(),
                               d->widget->text());
        });
        timers.insert(doc.rel, timer);
    }
    timers[doc.rel]->start();
}

// ---- LSP (stage 6): slangd stdio JSON-RPC ----

void Editor::lsp_start(const QString& workspace_root) {
    if (lsp_) return;
    lsp_root_ = workspace_root;
    lsp_ = new QProcess(this);
    connect(lsp_, &QProcess::readyRead, this, &Editor::on_lsp_ready_read);
    connect(lsp_, &QProcess::finished, this, &Editor::on_lsp_finished);
    QStringList args{"--stdio"}; // the Odin app uses --stdio; --lsp answers null
    // Submodule dist first (one source of truth); system-install fallback.
    // Relative paths: only resolve when cwd is the repo root (make run cds there).
    const QString slangd =
        QFileInfo("vendor/goose/vendor/slang/bin/slangd").exists()
            ? QFileInfo("vendor/goose/vendor/slang/bin/slangd").absoluteFilePath()
            : QFileInfo("vendor/slang/bin/slangd").absoluteFilePath();
    if (!QFileInfo::exists(slangd)) {
        notify::notify(notify::Kind::ERROR_, "slangd not found, LSP disabled: " + slangd);
        lsp_->deleteLater();
        lsp_ = nullptr;
        return;
    }
    // LSP handshake: initialize MUST precede didOpen/didChange, or slangd
    // exits on the protocol violation. QProcess::start is async (state =
    // Starting here, so a direct send would be dropped by send_lsp's
    // Running check): send initialize on the started signal instead.
    connect(lsp_, &QProcess::started, this, [this] {
        // Fresh server session: everything must be re-opened (tabs opened
        // before the spawn were dropped by the send gate).
        opened_on_server_.clear();
        lsp_initialized_ = false;
        // Capabilities mirror src/lsp.odin: slangd gates hover/definition on
        // the client declaring them (an empty {} yields null results).
        QString root_json = QJsonDocument(QJsonObject{
            {"processId", QJsonValue()},
            {"rootUri", "file://" + QDir::currentPath()},
            {"capabilities",
             QJsonObject{{"textDocument",
                          QJsonObject{
                              {"completion",
                               QJsonObject{{"completionItem",
                                            QJsonObject{{"snippetSupport", false}}}}},
                              {"hover", QJsonObject{{"contentFormat",
                                                     QJsonArray{"markdown", "plaintext"}}}},
                              {"definition", QJsonObject{{"linkSupport", false}}},
                              {"publishDiagnostics",
                               QJsonObject{{"relatedInformation", true},
                                           {"versionSupport", true}}}}}}}})
                               .toJson(QJsonDocument::Compact);
        lsp_pending_[lsp_next_id_] = "initialize";
        send_lsp(lsp_next_id_++, "initialize", root_json);
    });
    lsp_->start(slangd, args);
}

void Editor::lsp_stop() {
    if (!lsp_) return;
    lsp_->kill();
    lsp_ = nullptr;
}

void Editor::send_lsp(int id, const QString& method, const QString& params_json) {
    if (!lsp_ || lsp_->state() != QProcess::Running) return;
    // Until the handshake completes, only the initialize request itself may
    // go out: slangd exits on protocol violations.
    if (!lsp_initialized_ && method != "initialize") return;
    QString body = QString("{\"jsonrpc\":\"2.0\",\"id\":%1,\"method\":\"%2\",\"params\":%3}")
                       .arg(id)
                       .arg(method)
                       .arg(params_json);
    QByteArray msg = ("Content-Length: " + QByteArray::number(body.toUtf8().size()) +
                      "\r\n\r\n" + body.toUtf8());
    lsp_->write(msg);
}

void Editor::send_lsp_notify(const QString& method, const QString& params_json) {
    // Notifications carry NO id (a framed id makes slangd treat the
    // `initialized` notification as a request and stall the session).
    if (!lsp_ || lsp_->state() != QProcess::Running || !lsp_initialized_) return;
    QString body = QString("{\"jsonrpc\":\"2.0\",\"method\":\"%1\",\"params\":%2}")
                       .arg(method)
                       .arg(params_json);
    QByteArray msg = ("Content-Length: " + QByteArray::number(body.toUtf8().size()) +
                      "\r\n\r\n" + body.toUtf8());
    lsp_->write(msg);
}

void Editor::lsp_did_open(const QString& uri, const QString& text) {
    // Per-SERVER-lifecycle, not per-process: tabs opened before slangd
    // spawned were dropped (send_lsp gate); the post-initialize flush calls
    // lsp_did_open again, and a static guard would block the re-open.
    if (opened_on_server_.contains(uri)) return;
    opened_on_server_.insert(uri);
    // Odin parity: didOpen carries EMPTY text (slangd 1.8 chokes on a full
    // document here), the real content arrives via didChange right after.
    // The didChange is deferred one event-loop turn: slangd 1.8 drops the
    // content when didOpen+didChange land in the same batch.
    QString text_json = QJsonDocument(QJsonObject{{"textDocument",
        QJsonObject{{"uri", uri},
                    {"languageId", "slang"},
                    {"version", 1},
                    {"text", QString()}}}})
                            .toJson(QJsonDocument::Compact);
    send_lsp_notify("textDocument/didOpen", text_json);
    QTimer::singleShot(120, this, [this, uri, text] { lsp_did_change(uri, text); });
}

void Editor::lsp_did_change(const QString& uri, const QString& text) {
    int v = lsp_versions_[uri] + 1;
    lsp_versions_[uri] = v;
    if (v > 2) { // after the first sync, reset the server's compilation
        QString close_json = QJsonDocument(QJsonObject{
            {"textDocument", QJsonObject{{"uri", uri}}}})
                               .toJson(QJsonDocument::Compact);
        send_lsp_notify("textDocument/didClose", close_json);
        QString open_json = QJsonDocument(QJsonObject{{"textDocument",
            QJsonObject{{"uri", uri}, {"languageId", "slang"},
                        {"version", 1}, {"text", QString()}}}})
                                .toJson(QJsonDocument::Compact);
        send_lsp_notify("textDocument/didOpen", open_json);
    }
    QString json = QJsonDocument(QJsonObject{
        {"textDocument", QJsonObject{{"uri", uri}, {"version", v}}},
        {"contentChanges", QJsonArray{QJsonObject{{"text", text}}}}})
                       .toJson(QJsonDocument::Compact);
    send_lsp_notify("textDocument/didChange", json);
}

void Editor::lsp_did_save(const QString& uri) {
    QString json = QJsonDocument(QJsonObject{{"textDocument", QJsonObject{{"uri", uri}}}})
                       .toJson(QJsonDocument::Compact);
    send_lsp_notify("textDocument/didSave", json);
}

void Editor::lsp_completion(const QString& uri, int line, int col) {
    QString json = QJsonDocument(QJsonObject{
        {"textDocument", QJsonObject{{"uri", uri}}},
        {"position", QJsonObject{{"line", line}, {"character", col}}}})
                       .toJson(QJsonDocument::Compact);
    lsp_pending_[lsp_next_id_] = "completion";
    send_lsp(lsp_next_id_++, "textDocument/completion", json);
}

void Editor::lsp_hover(const QString& uri, int line, int col) {
    QString json = QJsonDocument(QJsonObject{
        {"textDocument", QJsonObject{{"uri", uri}}},
        {"position", QJsonObject{{"line", line}, {"character", col}}}})
                       .toJson(QJsonDocument::Compact);
    lsp_pending_[lsp_next_id_] = "hover";
    send_lsp(lsp_next_id_++, "textDocument/hover", json);
}

void Editor::lsp_goto_def(const QString& uri, int line, int col) {
    // Clicks can land before the initialize handshake finishes (slangd spawn
    // is deferred 3 s): queue the request and replay it once initialized,
    // otherwise the click is silently dropped by the send gate.
    if (!lsp_initialized_) {
        pending_def_ = std::make_tuple(uri, line, col);
        has_pending_def_ = true;
        return;
    }
    QString json = QJsonDocument(QJsonObject{
        {"textDocument", QJsonObject{{"uri", uri}}},
        {"position", QJsonObject{{"line", line}, {"character", col}}}})
                       .toJson(QJsonDocument::Compact);
    lsp_pending_[lsp_next_id_] = "definition";
    send_lsp(lsp_next_id_++, "textDocument/definition", json);
}

void Editor::lsp_rename(const QString& uri, int line, int col, const QString& new_name) {
    QString json = QJsonDocument(QJsonObject{
        {"textDocument", QJsonObject{{"uri", uri}}},
        {"position", QJsonObject{{"line", line}, {"character", col}}},
        {"newName", new_name}})
                       .toJson(QJsonDocument::Compact);
    lsp_pending_[lsp_next_id_] = "rename";
    send_lsp(lsp_next_id_++, "textDocument/rename", json);
}

void Editor::on_lsp_finished(int, int) { lsp_ = nullptr; }

void Editor::handle_lsp_message(const QByteArray& payload) {
    QJsonDocument doc = QJsonDocument::fromJson(payload);
    QJsonObject obj = doc.object();

    // Diagnostics notification.
    if (obj.contains("method") && obj["method"].toString() == "textDocument/publishDiagnostics") {
        std::vector<Diagnostic> diags;
        QJsonObject params = obj["params"].toObject();
        QString uri = params["uri"].toString();
        for (const QJsonValue& v : params["diagnostics"].toArray()) {
            QJsonObject d = v.toObject();
            Diagnostic diag;
            diag.uri = uri;
            diag.line = d["range"].toObject()["start"].toObject()["line"].toInt();
            diag.col = d["range"].toObject()["start"].toObject()["character"].toInt();
            diag.len = d["range"].toObject()["end"].toObject()["character"].toInt() - diag.col;
            diag.message = d["message"].toString();
            diag.error = d["severity"].toInt() == 1;
            diags.push_back(diag);
        }
        apply_diagnostics(diags);
        return;
    }

    // SERVER-initiated requests carry their own id and NO method in pending_:
    // reply to the ones that gate the session, ignore the rest.
    if (obj.contains("method") && obj.contains("id")) {
        QString smethod = obj["method"].toString();
        QJsonValue sid = obj["id"];
        if (smethod == "workspace/configuration") {
            QJsonArray items;
            for (const QJsonValue& item : obj["params"].toObject()["items"].toArray())
                items.append(QJsonObject{});
            QString body = QString("{\"jsonrpc\":\"2.0\",\"id\":%1,\"result\":%2}")
                               .arg(sid.toInt())
                               .arg(QJsonDocument(QJsonArray{QJsonArray{}})
                                        .toJson(QJsonDocument::Compact));
            QByteArray msg = ("Content-Length: " +
                              QByteArray::number(body.toUtf8().size()) + "\r\n\r\n" +
                              body.toUtf8());
            if (lsp_) lsp_->write(msg);
        } else {
            QString body = QString("{\"jsonrpc\":\"2.0\",\"id\":%1,\"result\":null}")
                               .arg(sid.toInt());
            QByteArray msg = ("Content-Length: " +
                              QByteArray::number(body.toUtf8().size()) + "\r\n\r\n" +
                              body.toUtf8());
            if (lsp_) lsp_->write(msg);
        }
        return;
    }

    // Response to a request (id present). Notifications handled above.
    if (!obj.contains("id")) return;
    int id = obj["id"].toInt();
    QString method = lsp_pending_.take(id);
    if (method == "initialize") {
        lsp_initialized_ = true;
        send_lsp_notify("initialized", "{}");
        // Flush didOpen for every open tab (queued while uninitialized);
        // each open defers its didChange, avoiding same-batch drops. The
        // deferred didChanges land AFTER this loop — replay any queued
        // goto-def on a timer, once the content is on the server.
        for (const Open_Doc& open : open_docs_)
            if (open.widget) lsp_did_open(doc_uri(open.widget), open.widget->text());
        if (has_pending_def_) {
            has_pending_def_ = false;
            const QString& def_uri = std::get<0>(pending_def_);
            int def_line = std::get<1>(pending_def_);
            int def_col = std::get<2>(pending_def_);
            QTimer::singleShot(1200, this, [this, def_uri, def_line, def_col] {
                lsp_goto_def(def_uri, def_line, def_col);
            });
        }
        return;
    }
    if (method == "hover") {
        QJsonValue r = obj["result"];
        // contents: MarkupContent{value} | string | array of strings. slangd
        // 1.8 answers null for most positions — show a quiet fallback card
        // instead of silence so hover always gives feedback.
        QString contents;
        if (r.isObject())
            contents = r.toObject()["contents"].toObject()["value"].toString();
        else if (r.isArray())
            contents = QJsonDocument(r.toArray()).toJson(QJsonDocument::Compact);
        else
            contents = r.toString();
        // slangd payloads are markdown: ```sig``` fence + doc paragraphs.
        // QToolTip renders rich text: strip the fence, style the signature.
        if (contents.contains("```")) {
            QString sig, body;
            int fence0 = contents.indexOf("```");
            int fence1 = contents.indexOf("```", fence0 + 3);
            sig = contents.mid(fence0 + 3, fence1 - fence0 - 3).trimmed();
            body = contents.mid(fence1 + 3).trimmed();
            contents = "<b>" + sig.toHtmlEscaped() + "</b>";
            if (!body.isEmpty())
                contents += "<br>" + body.toHtmlEscaped().replace("\n", "<br>");
        } else {
            contents = contents.toHtmlEscaped().replace("\n", "<br>");
        }
        if (contents.isEmpty())
            contents = i18n::tr("no docs for this symbol");
        if (current_editor()) current_editor()->setToolTip(contents);
    } else if (method == "definition") {
        // Result: Location | Location[] | null. First location wins.
        QJsonValue r = obj["result"];
        QJsonObject loc = r.isObject() ? r.toObject()
                                       : (r.isArray() && !r.toArray().isEmpty()
                                              ? r.toArray()[0].toObject()
                                              : QJsonObject());
        if (!loc.isEmpty()) {
            QString def_uri = loc["uri"].toString();
            int def_line = loc["range"].toObject()["start"].toObject()["line"].toInt();
            // URI -> editor rel ("src/shaders/common"): strip file://<cwd>/.
            QString rel = def_uri;
            rel.remove("file://" + QDir::currentPath() + "/");
            if (rel.endsWith(".slang")) rel.chop(6);
            load_named(rel);
            if (current_editor()) {
                current_editor()->setCursorPosition(def_line, 0);
                current_editor()->ensureLineVisible(def_line);
            }
        } else {
            notify::notify(notify::Kind::INFO, i18n::tr("no definition found"));
        }
    } else if (method == "completion") {
        // Result: CompletionItem[] or CompletionList{items}. Filter by the word
        // typed before the caret, since Scintilla's user list does not.
        QJsonValue r = obj["result"];
        QJsonArray items = r.isArray() ? r.toArray() : r.toObject()["items"].toArray();
        QsciScintilla* ed = current_editor();
        if (!ed) return;
        int line = 0, col = 0;
        ed->getCursorPosition(&line, &col);
        QString before = ed->text(line).left(col);
        int s = before.size();
        while (s > 0 && (before[s - 1].isLetterOrNumber() || before[s - 1] == '_')) --s;
        QString prefix = before.mid(s);
        QStringList shown;
        for (const QJsonValue& v : items) {
            QString label = v.toObject()["label"].toString();
            if (label.startsWith(prefix) && label != prefix) shown << label;
        }
        shown.removeDuplicates();
        shown.sort();
        if (!shown.isEmpty()) ed->showUserList(1, shown);
    }
}

void Editor::on_lsp_ready_read() {
    lsp_buffer_ += lsp_->readAll();
    while (true) {
        int header_end = lsp_buffer_.indexOf("\r\n\r\n");
        if (header_end < 0) break;
        QByteArray headers = lsp_buffer_.left(header_end);
        int content_length = 0;
        for (const QByteArray& line : headers.split('\n')) {
            QByteArray trimmed = line.trimmed();
            if (trimmed.startsWith("Content-Length:"))
                content_length = trimmed.mid(15).trimmed().toInt();
        }
        if (content_length <= 0 ||
            lsp_buffer_.size() < header_end + 4 + content_length)
            break;
        QByteArray payload = lsp_buffer_.mid(header_end + 4, content_length);
        lsp_buffer_.remove(0, header_end + 4 + content_length);
        handle_lsp_message(payload);
    }
}

void Editor::apply_diagnostics(const std::vector<Diagnostic>& diags) {
    static const int kSquiggle = 8;  // custom indicator index
    static const int kBadMarker = 2; // error-line marker
    live_diags_.clear();
    for (Open_Doc& doc : open_docs_) {
        if (!doc.widget) continue;
        QString uri = "file://" + QFileInfo(doc.path).absoluteFilePath();
        doc.widget->markerDeleteAll(kBadMarker);
        doc.widget->SendScintilla(QsciScintillaBase::SCI_INDICATORCLEARRANGE, 0,
                                  long(doc.widget->SendScintilla(
                                      QsciScintillaBase::SCI_GETLENGTH)));
        doc.widget->indicatorDefine(QsciScintilla::SquiggleIndicator, kSquiggle);
        doc.widget->setIndicatorForegroundColor(QColor(0xf2, 0x6b, 0x5c), kSquiggle);
        for (const Diagnostic& d : diags) {
            if (d.uri != uri) continue;
            live_diags_[uri].push_back(d);
            int line_len = doc.widget->lineLength(d.line);
            int len = d.len > 0 ? d.len : std::max(1, line_len - d.col - 1);
            doc.widget->fillIndicatorRange(d.line, d.col, d.line, d.col + len, kSquiggle);
            if (d.error) doc.widget->markerAdd(d.line, kBadMarker);
        }
    }
}

// Message of the diagnostic covering a position (hover); "" when none.
// Line match first, then the col..col+len range (0-length = whole line).
QString Editor::diag_message_at(const QString& uri, long pos) const {
    auto it = live_diags_.find(uri);
    if (it == live_diags_.end()) return {};
    const Open_Doc* doc = nullptr;
    for (const Open_Doc& d : open_docs_)
        if ("file://" + QFileInfo(d.path).absoluteFilePath() == uri) doc = &d;
    if (!doc || !doc->widget) return {};
    int line = int(doc->widget->SendScintilla(
        QsciScintillaBase::SCI_LINEFROMPOSITION, pos));
    for (const Diagnostic& d : it->second) {
        if (d.line != line) continue;
        if (d.len == 0) return d.message; // whole-line diagnostic
        int start = int(doc->widget->SendScintilla(
            QsciScintillaBase::SCI_POSITIONFROMLINE, long(d.line))) + d.col;
        if (pos >= start && pos <= start + d.len) return d.message;
    }
    return {};
}

// ---- Find (Cmd+F) ----

void Editor::open_find() {
    QsciScintilla* ed = current_editor();
    if (!ed) return;
    if (!find_bar_->parent()) find_bar_->setParent(currentWidget());
    if (ed->selectedText().isEmpty()) {
        find_edit_->clear();
    } else { // seed with the selection, like every native find bar
        find_edit_->setText(ed->selectedText());
    }
    find_bar_->setGeometry(currentWidget()->width() - 360, 6, 352,
                           find_bar_->sizeHint().height());
    find_bar_->raise();
    find_bar_->show();
    find_edit_->setFocus();
    find_edit_->selectAll();
}

void Editor::find_next() {
    QsciScintilla* ed = current_editor();
    if (!ed || find_edit_->text().isEmpty()) {
        find_status_->clear();
        return;
    }
    bool found = ed->findFirst(find_edit_->text(), /*re*/ false, /*cs*/ false,
                               /*wo*/ false, /*wrap*/ true,
                               /*forward*/ true);
    find_status_->setText(found ? QString() : i18n::tr("no matches"));
}

void Editor::hide_find() {
    find_bar_->hide();
    if (QsciScintilla* ed = current_editor()) {
        ed->cancelFind();
        ed->setFocus();
    }
}


QWidget* Editor::editor_dock_host() {
    // The split pane docks beside the tab widget: parent is the editor's
    // enclosing dock (editor_dock_), which is the QTabWidget's parent.
    QWidget* w = parentWidget();
    return w ? w : this;
}

void Editor::split_current() {
    // Split = code | SHADER PREVIEW. The old code|code read-only clone is
    // gone (it covered the tabs and rendered with a stale font); the
    // host owns the preview: the SDL child window shrinks to the right
    // half while the split is on (Shell::split_toggled -> host).
    split_on_ = !split_on_;
    reposition_split_button(); // flip to the free bottom corner
    emit split_toggled(split_on_);
}

bool Editor::split_on() const { return split_on_; }

} // namespace editor
