#include "perf_probe.hpp" // TEMP-PROF: diagnosis instrumentation, remove after Plan 01
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
#include <QTabBar>
#include <QToolTip>
#include <QTimer>
#include <QPointer>
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
#include <cstdio>

#include <cmath>

namespace editor {

static const char* kShaderDir = "src/shaders";
// P2-N5: the empty state teaches the app's model on first run and after the
// last tab closes. The overlay is a child of the QTabWidget, raised above the
// (empty) tab area; hidden the moment any tab exists.
void Editor::update_empty_state() {
    if (!empty_state_) return;
    bool empty = open_docs_.empty();
    empty_state_->setVisible(empty);
    empty_state_->raise();
}

QString Editor::file_path_for_rel(const QString& rel) const {
    if (rel.startsWith("gis_scenes/")) return rel + ".slang";
    // LSP locations arrive as full rels ("src/shaders/common"); editor rels
    // from rescan omit the prefix. Pass full rels through untouched.
    if (rel.startsWith(QString(kShaderDir) + "/")) return rel + ".slang";
    return QString(kShaderDir) + "/" + rel + ".slang";
}

// One skin per theme (the single source the editor chrome, apply_skin and
// the LEARN renderer read — no per-widget hex literals). DARK = Darkroom
// tokens; MONOKAI/SOLARIZED/LIGHT are the standard schemes. Order = the
// Editor_Theme enum.
struct Editor_Skin {
    QColor paper, text, keyword, type, number, comment, string,
           preproc, operator_, margin_bg, margin_fg, caret_line,
           selection_bg, selection_fg;
};
// One table per skin — the single source the editor, the find bar, the
// LEARN renderer and graph chrome read (no per-widget hex literals).
// Order = the Editor_Theme enum (DARK first).
constexpr Editor_Skin kEditorSkins[] = {
    // DARK = Darkroom: quiet proof text, one accent per token class.
    {QColor(0x13, 0x14, 0x18), QColor(0xd7, 0xda, 0xe2),
     QColor(0xe8, 0xa8, 0x57),          // keywords: Safelight amber
     QColor(0x9e, 0xc2, 0xf2),          // slang types: soft blue
     QColor(0xf2, 0x8c, 0x7a),          // numbers: muted rose
     QColor(0x7e, 0x83, 0x8e),          // comments: Fog Gray (4.8:1 AA)
     QColor(0xa9, 0xd4, 0x9e),          // strings: soft green
     QColor(0xc9, 0x9e, 0xf2),          // preprocessor: soft violet
     QColor(0x8c, 0x90, 0x99),          // operators: mid gray
     QColor(0x1a, 0x1b, 0x20), QColor(0x75, 0x7a, 0x85),
     QColor(0xff, 0xff, 0xff, 0x0d), QColor(0x3a, 0x2c, 0x18),
     QColor(0xde, 0xe0, 0xe6)},
    // LIGHT.
    {QColor(0xff, 0xff, 0xff), QColor(0x1f, 0x20, 0x24),
     QColor(0x1c, 0x46, 0x9c), QColor(0x78, 0x35, 0x96),
     QColor(0x9c, 0x42, 0x2e), QColor(0x6f, 0x74, 0x7e),
     QColor(0x1d, 0x6b, 0x33), QColor(0x9a, 0x5b, 0x0a),
     QColor(0x2c, 0x30, 0x3a), QColor(0xf2, 0xf3, 0xf5),
     QColor(0x8c, 0x90, 0x99), QColor(0xff, 0xf3, 0xd6),
     QColor(0xd8, 0xe2, 0xf4), QColor(0x1f, 0x20, 0x24)},
    // MONOKAI.
    {QColor(0x27, 0x28, 0x22), QColor(0xf8, 0xf8, 0xf2),
     QColor(0xf9, 0x26, 0x72), QColor(0xa6, 0xe2, 0x2e),
     QColor(0xae, 0x81, 0xff), QColor(0x75, 0x71, 0x5e),
     QColor(0xe6, 0xdb, 0x74), QColor(0xfd, 0x97, 0x1f),
     QColor(0xf8, 0xf8, 0xf2), QColor(0x1e, 0x1f, 0x1a),
     QColor(0x75, 0x71, 0x5e), QColor(0x32, 0x33, 0x2b),
     QColor(0x49, 0x48, 0x34), QColor(0xf8, 0xf8, 0xf2)},
    // SOLARIZED.
    {QColor(0x00, 0x2b, 0x36), QColor(0x93, 0xa1, 0xa1),
     QColor(0x85, 0x99, 0x00), QColor(0xb5, 0x89, 0x00),
     QColor(0x2a, 0xa1, 0x98), QColor(0x58, 0x6e, 0x75),
     QColor(0x2a, 0xa1, 0x98), QColor(0xcb, 0x4b, 0x16),
     QColor(0x93, 0xa1, 0xa1), QColor(0x07, 0x36, 0x42),
     QColor(0x58, 0x6e, 0x75), QColor(0x07, 0x3d, 0x4a),
     QColor(0x27, 0x46, 0x52), QColor(0xee, 0xed, 0xd5)},
};
static_assert(sizeof(kEditorSkins) / sizeof(kEditorSkins[0]) ==
              int(editor::Editor_Theme::SOLARIZED) + 1, "skin order");

// The skin for the ACTIVE editor theme (Editor_Theme order = table order).
static const Editor_Skin& skin_for(editor::Editor_Theme theme) {
    return kEditorSkins[int(theme)];
}

// plan7: gutter width = digits of the last line number (+1 spare slot).
// The old fixed "000" slot clipped files over 999 lines.
static QString gutter_digits(QsciScintilla* edit) {
    int digits = QString::number(qMax(1, edit->lines())).size() + 1;
    return QString("0").repeated(digits);
}

void Editor::set_find_bar_theme() {
    if (!find_bar_) return;
    const Editor_Skin& es = skin_for(theme_);
    find_bar_->setStyleSheet(
        QString("QWidget#findBar { background: %1; border: 1px solid %2;"
                " border-radius: 6px; }"
                "QLineEdit { background: transparent; border: none; color: %3;"
                " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
                "QLabel { color: %4; font-size: 8pt; }"
                "QPushButton { background: rgba(255,255,255,0.06); border: none;"
                " border-radius: 4px; color: %3; padding: 2px 8px; }"
                "QPushButton:hover { background: rgba(255,255,255,0.12); }")
            .arg(es.margin_bg.name(), es.selection_bg.darker(140).name(),
                 es.text.name(), es.comment.name()));
    // plan7: the tab row IS editor chrome — same skin, one hairline accent
    // under the selected tab. Scoped to the QTabBar (a stylesheet on the
    // QTabWidget would repolish the Scintilla viewport); proved innocent
    // in the plan7 bisect (the white paper was the skin-table order bug).
    // plan7: the tab row IS editor chrome — same skin, one hairline accent
    // under the selected tab. Scoped to the QTabBar (a stylesheet on the
    // QTabWidget would repolish the Scintilla viewport); proved innocent
    // in the plan7 bisect (the white paper was the skin-table order bug).
    // Plan 03 §2: NO `color:` in the ::tab rules — the text color belongs
    // to setTabTextColor (stylesheet color would override it and make the
    // dirty-amber dot impossible). Selected state: amber underline + tinted
    // pill; inactive tabs stay muted (see sync_tab_colors).
    tabBar()->setStyleSheet(
        QString("QTabBar { qproperty-drawBase: 0; background: transparent; }"
                "QTabBar::tab { background: transparent;"
                " padding: 4px 10px; border: none;"
                " border-bottom: 2px solid transparent;"
                " font-family: 'JetBrains Mono', monospace; font-size: 9pt; }"
                "QTabBar::tab:hover { background: rgba(255,255,255,0.04); }"
                "QTabBar::tab:selected {"
                " background: rgba(232,168,87,0.10);"
                " border-bottom: 2px solid %1; }")
            .arg(theme::safelight()));
    sync_tab_colors();
}

// Re-applies per-tab text colors: muted for inactive tabs, full text color
// for the active one, amber when dirty (color + the "•" glyph pair). Runs
// on skin change and on tab/mode state changes. setTabTextColor only works
// because the stylesheet above no longer claims the text color.
void Editor::sync_tab_colors() {
    const Editor_Skin& es = skin_for(theme_);
    for (int i = 0; i < count(); ++i) {
        if (i >= (int)open_docs_.size()) break;
        const bool active = i == currentIndex();
        tabBar()->setTabTextColor(i, open_docs_[size_t(i)].dirty
                                         ? theme::safelight()
                                         : (active ? es.text : es.comment));
    }
}

void Editor::update_split_btn_theme() {
    if (!split_btn_) return;
    const Editor_Skin& es = skin_for(theme_);
    split_btn_->setStyleSheet(
        QString("QPushButton#splitBtn { background: rgba(255,255,255,0.06);"
                " border: none; border-radius: 4px; color: %1; font-size: 9pt; }"
                "QPushButton#splitBtn:hover { background: rgba(255,255,255,0.14);"
                " color: %2; }")
            .arg(es.comment.name(), es.text.name()));
}

Editor::Editor(QWidget* parent) : QTabWidget(parent) {
    setTabsClosable(true);
    setMovable(true);
    setDocumentMode(true);
    // Plan 03 P2 follow-up: full file name — no eliding; overflow scrolls
    // via the built-in tab scroll buttons. Explicit ElideNone: QTabBar's
    // default (ElideRight) would truncate long names otherwise.
    setElideMode(Qt::ElideNone);
    connect(this, &QTabWidget::currentChanged, this, &Editor::on_tab_changed);
    connect(this, &QTabWidget::tabCloseRequested, this, [this](int index) {
        if (index < 0 || index >= (int)open_docs_.size()) return;
        QWidget* w = open_docs_[size_t(index)].widget;
        removeTab(index);
        open_docs_.erase(open_docs_.begin() + index);
        if (w) w->deleteLater();
        update_empty_state();
    });

    // Empty state (P2-N5): teaches the model on first run and after the last
    // tab closes. One line, muted; gone the moment a tab exists.
    empty_state_ = new QWidget(this);
    empty_state_->setStyleSheet("background: transparent;");
    auto* es_layout = new QVBoxLayout(empty_state_);
    es_layout->setAlignment(Qt::AlignCenter);
    auto* es_label = new QLabel(
        i18n::tr("pick a file in the explorer to start editing"),
        empty_state_);
    es_label->setStyleSheet(QString("color: %1; font-size: 10pt; background: transparent;")
                                .arg(skin_for(theme_).text.name()));
    es_label->setAlignment(Qt::AlignCenter);
    es_layout->addWidget(es_label);
    update_empty_state();
    // Cmd+F find bar: floats over the active tab (QTabWidget corner widgets
    // only own the tab-row strip, which reads as chrome, not overlay).
    find_bar_ = new QWidget(this);
    find_bar_->setObjectName("findBar");
    set_find_bar_theme();
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
    update_split_btn_theme();
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


static void apply_skin(QsciScintilla* edit, Editor_Theme theme, const QFont& code_face) {
    const Editor_Skin& s = skin_for(theme);
    QColor paper = s.paper;
    QColor margin_bg = s.margin_bg; margin_bg.setAlpha(140);
    // Caret line: NO background band (user wants the row visually unchanged).
    // The affordance is the line-number margin: caret rows get a brighter
    // number via SCI_SETCARETLINEBACKALPHA 0 below + per-locator styling in
    // on_modified. Keep the derived color for matched-brace/indent guides.
    QColor caret_line = s.caret_line;
    if (theme != Editor_Theme::DARK)
        caret_line = QColor::fromRgbF(
            s.paper.redF() * 0.85 + s.text.redF() * 0.15,
            s.paper.greenF() * 0.85 + s.text.greenF() * 0.15,
            s.paper.blueF() * 0.85 + s.text.blueF() * 0.15);
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
        lexer->setFont(code_face);
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
    // Living caret (delight): a block caret in the theme accent that
    // breathes via a 90ms alpha pulse instead of the stock hard blink.
    // SC_CARETSTYLE_BLOCK = 2; CARETPERIOD 0 disables the stock blink so
    // the pulse owns the rhythm. Reduced motion: steady bar, no timer.
    if (qEnvironmentVariableIsSet("GIS_REDUCED_MOTION")) {
        edit->SendScintilla(QsciScintillaBase::SCI_SETCARETSTYLE, 1ul);
    } else {
        edit->SendScintilla(QsciScintillaBase::SCI_SETCARETSTYLE, 2ul); // block
        edit->SendScintilla(QsciScintillaBase::SCI_SETCARETWIDTH, 3ul);
        edit->SendScintilla(QsciScintillaBase::SCI_SETCARETPERIOD, 0ul);
        auto* pulse = new QTimer(edit);
        pulse->setInterval(90);
        const QColor caret_accent(0xE8, 0xA8, 0x57);
        QPointer<QsciScintilla> guard(edit);
        auto* phase = new double(0.0); // owned by the connection context
        QObject::connect(pulse, &QTimer::timeout, edit, [guard, caret_accent, phase]() {
            if (!guard) return;
            *phase += 0.18;
            if (*phase >= 1.0) *phase = 0.0;
            const double wave =
                0.35 + 0.55 * (0.5 - 0.5 * cos(*phase * 2.0 * M_PI));
            QColor c = caret_accent;
            c.setAlphaF(wave);
            guard->SendScintilla(QsciScintillaBase::SCI_SETCARETFORE,
                                 static_cast<unsigned long>(c.rgba()));
        });
        pulse->start();
    }
    edit->setCaretLineVisible(true);
    edit->setCaretLineBackgroundColor(QColor(0, 0, 0, 0)); // no band: row unchanged
    edit->SendScintilla(QsciScintillaBase::SCI_SETCARETLINEBACKALPHA, 0ul);
    // Selection UNDER the text: the band sits behind the glyphs, so lexer
    // token colors survive inside the selection (an opaque selection bg +
    // flat fg painted every token the same near-white — the "selection loses
    // the theme" bug).
    // SCI_SETSELECTIONLAYER = 2754 (missing from this QScintilla's enum),
    // SC_LAYER_UNDER_TEXT = 1: the band sits behind the glyphs.
    edit->SendScintilla(2754, 1ul);
    QColor sel_bg = s.selection_bg;
    sel_bg.setAlpha(110); // translucent: tokens read through the band
    edit->setSelectionBackgroundColor(sel_bg);
    // NO selection fg override: forcing one fg paints every token the same
    // pale color inside the selection. With the layer under the text, the
    // lexer styles keep full control of the glyph colors.
    edit->resetSelectionForegroundColor();
    edit->setIndentationGuidesBackgroundColor(margin_bg);
    edit->setIndentationGuidesForegroundColor(s.caret_line);
    edit->setMatchedBraceBackgroundColor(caret_line);
    edit->setMatchedBraceForegroundColor(theme::safelight_rgb());
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
    lexer->setFont(editor_font());
    edit->setLexer(lexer);
    edit->setText(text);
    edit->setMarginLineNumbers(1, true);
    edit->setMarginWidth(1, gutter_digits(edit)); // plan7: fits the file
    edit->setFont(editor_font());
    edit->setTabWidth(4);
    // No wrap; kill the phantom horizontal scroll: Scintilla defaults
    // SCROLLWIDTH to 2000px and never shrinks it, so short files scrolled
    // far past their content. Track the widest line exactly (+2 chars
    // slack) on every edit; the h-scrollbar then matches real content.
    edit->setWrapMode(QsciScintilla::WrapNone);
    edit->SendScintilla(QsciScintillaBase::SCI_SETSCROLLWIDTHTRACKING, 1ul);
    edit->SendScintilla(QsciScintillaBase::SCI_SETSCROLLWIDTH, 400ul);
    edit->setIndentationsUseTabs(false);
    // Overscroll: scroll past the last line so code can sit higher on
    // screen (editor convention the user asked for). ENDATLASTLINE 0 adds
    // a screenful of empty scroll below the text.
    edit->SendScintilla(QsciScintillaBase::SCI_SETENDATLASTLINE, 0ul);
    // Plan 04 Task B: ONE autocomplete mechanism — the slangd popup
    // (showUserList, 130 ms debounce, cap 60). QScintilla's own
    // AcsDocument popup tears down and recreates a native NSWindow on
    // EVERY keystroke (~24 ms of synchronous SkyLight work each, measured
    // with sample(1)); that was the typing stutter. slangd coverage makes
    // the word-list popup redundant.
    edit->setAutoCompletionSource(QsciScintilla::AcsNone);
    edit->setAutoCompletionThreshold(2);
    apply_skin(edit, theme_, editor_font());
    // Caret affordance: brighter LINE NUMBER on the caret row (the band is
    // off). Scintilla paints margin numbers with one shared style (33), so a
    // per-row look needs a style offset: margin 1 uses styles 256+line.
    // SCI_SETMARGINSTYLEOFFSET = 2537 (missing from this QScintilla's enum).
    constexpr long kNumStyleBase = 256;
    edit->SendScintilla(2537, 1ul, kNumStyleBase);
    edit->SendScintilla(QsciScintillaBase::SCI_SETCARETLINEVISIBLEALWAYS, 1ul);
    const QColor caret_num = skin_for(theme_).selection_fg; // bright caret-row number
    const quint32 caret_bgr = caret_num.alpha() == 255
                                  ? quint32(caret_num.red()) |
                                        (quint32(caret_num.green()) << 16) |
                                        (quint32(caret_num.blue()) << 8)
                                  : 0x00e6e0deul;
    QObject::connect(edit, &QsciScintillaBase::SCN_UPDATEUI, edit,
                     [edit, base = kNumStyleBase, caret_bgr] {
        // SCI_MARGINSETSTYLEFORE = 2538 (missing from this QScintilla's enum).
        auto paint = [edit, base](int ln, quint32 rgb) {
            if (ln < 0) return;
            edit->SendScintilla(2538, ln + base, rgb);
        };
        // Dim = whatever style 33 (STYLE_LINENUMBER) currently paints. Styles
        // 256+line default to black on the dark paper, so every VISIBLE row's
        // style carries the dim color; the caret row is then repainted bright
        // on top. ~40 SendScintilla calls per update: trivial.
        quint32 dim = quint32(edit->SendScintilla(QsciScintillaBase::SCI_STYLEGETFORE, 33ul));
        long first = long(edit->SendScintilla(QsciScintillaBase::SCI_GETFIRSTVISIBLELINE));
        long vis = long(edit->SendScintilla(QsciScintillaBase::SCI_LINESONSCREEN)) + 1;
        for (long ln = first; ln < first + vis; ++ln) paint(int(ln), dim);
        int line = int(edit->SendScintilla(QsciScintillaBase::SCI_LINEFROMPOSITION,
                                           long(edit->SendScintilla(
                                               QsciScintillaBase::SCI_GETCURRENTPOS))));
        paint(line, caret_bgr); // BGR quint32 of the skin's bright number color
    });
    // Cmd+click goto-def + Cmd-hover underline: my filter on the viewport
    // runs before Qsci's own (install order = reverse run order), so the
    // press is interceptable. Mouse tracking keeps Move events flowing while
    // a button is up (needed for hover underline).
    // Both receivers: the viewport owns mouse events; the Scintilla widget
    // owns Key events (Cmd press/release while the mouse rests — the viewport
    // never sees those, so the underline affordance needs the edit filter too).
    edit->installEventFilter(this);
    edit->viewport()->installEventFilter(this);
    edit->viewport()->setMouseTracking(true);
    // Link underline style: PlainIndicator = single straight line, Safelight
    // amber (state, per the Safelight Rule). Index 9; 8 = diagnostics.
    edit->indicatorDefine(QsciScintilla::PlainIndicator, 9);
    edit->setIndicatorForegroundColor(theme::safelight_rgb(), 9);
    edit->setIndicatorDrawUnder(true, 9);
    // Hover docs: dwell 500 ms over an identifier -> textDocument/hover.
    // Over a diagnostic squiggle the dwell shows the DIAGNOSTIC message
    // instead of a slangd hover card (the local answer wins: it is always
    // current with what is painted).
    edit->SendScintilla(QsciScintillaBase::SCI_SETMOUSEDWELLTIME, 500);
    connect(edit, &QsciScintillaBase::SCN_DWELLSTART, this,
            [this, edit](int pos, int, int) {
        if (pos < 0) return;
        QString uri = doc_uri(edit);
        QString diag = diag_message_at(uri, pos);
        if (!diag.isEmpty()) {
            QToolTip::showText(QCursor::pos(), diag, edit);
            return;
        }
        int line = int(edit->SendScintilla(QsciScintillaBase::SCI_LINEFROMPOSITION, pos));
        int col = int(edit->SendScintilla(QsciScintillaBase::SCI_GETCOLUMN, pos));
        lsp_hover(uri, line, col);
    });
    connect(edit, &QsciScintillaBase::SCN_DWELLEND, edit, [] {
        QToolTip::hideText(); // clear the hover card when the mouse leaves
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
    // Completion on identifier/'.' typing: ask slangd, but DEBOUNCED. The
    // old per-keystroke request fired 5 slangd calls for "float"; every
    // reply carries the module's whole symbol table and the main thread
    // parsed/filters it 5x — a visible typing delay. One 130 ms trailing
    // timer per editor: one request per typing burst. (The 280 ms
    // didChange debounce syncs text separately; see on_modified.
    // Completion on the pre-sync text is fine: the server merges.)
    auto* completion_timer = new QTimer(edit);
    completion_timer->setSingleShot(true);
    completion_timer->setInterval(130);
    connect(completion_timer, &QTimer::timeout, edit, [this, edit, path] {
        if (!open_docs_.empty() && doc_for_widget(edit) == nullptr) return;
        int line = 0, col = 0;
        edit->getCursorPosition(&line, &col);
        QString l = edit->text(line);
        if (col <= 0 || col > l.size()) return;
        QChar c = l[col - 1];
        if (!(c.isLetterOrNumber() || c == '_' || c == '.')) return;
        perf_log("completion-send", -1.0); // temp instrumentation
        QString uri = "file://" + QFileInfo(path).absoluteFilePath();
        lsp_completion(uri, line, col);
    });
    connect(edit, &QsciScintilla::textChanged, edit,
            [completion_timer] { completion_timer->start(); });

    doc.widget = edit;
    open_docs_.push_back(doc);
    addTab(edit, rel.section('/', -1));
    // Long names elide in the tab; the FULL path lives in the tooltip
    // (Plan 03 §2: no information loss when the label truncates).
    tabBar()->setTabToolTip(count() - 1, rel);
    setCurrentIndex(int(open_docs_.size()) - 1);
    sync_tab_colors();
    update_empty_state();
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
    if (empty_state_) empty_state_->setGeometry(0, 0, width(), height());
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
    // Editor events: Cmd+click -> definition; Cmd held over a word ->
    // underline it (the clickable affordance). Two watched objects per doc:
    // the viewport (mouse events) and the Scintilla widget itself (Key events
    // while the mouse rests — the viewport never sees those). For the widget,
    // watched IS the edit; for the viewport, parent() is.
    QsciScintilla* edit = qobject_cast<QsciScintilla*>(watched);
    if (!edit) edit = qobject_cast<QsciScintilla*>(watched->parent());
    if (!edit || !doc_for_widget(edit)) return QTabWidget::eventFilter(watched, event);

    switch (event->type()) {
    case QEvent::Wheel: {
        auto* wheel = static_cast<QWheelEvent*>(event);
        // Shift + wheel = horizontal scroll (standard editor convention):
        // pixels (trackpad) or one character column per 1/8 notch (wheel).
        if (wheel->modifiers() & Qt::ShiftModifier) {
            double dx = !wheel->pixelDelta().isNull()
                            ? double(-wheel->pixelDelta().x())
                            : -wheel->angleDelta().y() / (8.0 * 120.0) * 20.0;
            if (wheel->pixelDelta().isNull() && wheel->angleDelta().x() != 0)
                dx = -wheel->angleDelta().x() / (8.0 * 120.0) * 20.0;
            h_scroll_acc_ += dx;
            double whole = 0;
            h_scroll_acc_ = std::modf(h_scroll_acc_, &whole);
            if (whole != 0) {
                long x = long(edit->SendScintilla(QsciScintillaBase::SCI_GETXOFFSET));
                long max = long(edit->SendScintilla(QsciScintillaBase::SCI_GETSCROLLWIDTH));
                long target = std::clamp(x + long(whole), 0L, std::max(0L, max - 1));
                edit->SendScintilla(QsciScintillaBase::SCI_SETXOFFSET, target);
            }
            return true;
        }
        // Smooth scroll: QScintilla's wheel path jumps whole lines. Convert
        // the wheel delta into first-visible-line steps through a fractional
        // accumulator (angleDelta: ~7 lines per notch; trackpad pixelDelta
        // drives 1:1 for true pixel smoothness). The sub-line remainder
        // persists between events so slow wheels still move eventually.
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
        if (doc.widget) apply_skin(doc.widget, theme, editor_font());
    set_find_bar_theme();     // chrome follows the same skin table
    update_split_btn_theme();
}

// Active code face: JetBrains Mono, or Sergamon when the pixel option is on.
QFont Editor::editor_font() const {
    return pixel_font_ ? theme::pixel_code_font(font_size_)
                       : theme::code_font(font_size_);
}

// Applies font_size_ + face to every open doc (widget + lexer), margins included.
void Editor::apply_font() {
    QFont f = editor_font();
    for (Open_Doc& doc : open_docs_) {
        if (!doc.widget) continue;
        doc.widget->setFont(f);
        if (auto* lex = dynamic_cast<Slang_Lexer*>(doc.widget->lexer()))
            lex->setFont(f);
        // Proportional gutter: recompute the width from the real line
        // count (plan7; the fixed "000" slot clipped 5-digit files).
        doc.widget->setMarginWidth(1, gutter_digits(doc.widget));
        doc.widget->setMarginWidth(0, 8); // spacer lane (see load_named)
    }
}

// Pixel-face toggle for the code text; re-skins open tabs immediately.
void Editor::set_pixel_font(bool on) {
    if (pixel_font_ == on) return;
    pixel_font_ = on;
    apply_font();
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
    update_empty_state();
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
    update_empty_state();
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
        ++saved;
        const int idx = int(&doc - open_docs_.data());
        setTabText(idx, doc.rel.section('/', -1)); // drop the "•" glyph
        // did-save for the LSP.
        lsp_did_save("file://" + QFileInfo(doc.path).absoluteFilePath());
    }
    sync_tab_colors(); // saved tabs return to their normal text color
    status_ = saved > 0 ? QString("saved %1 file(s)").arg(saved) : status_;
    if (saved > 0) emit status_changed(status_);
    return saved;
}

void Editor::on_tab_changed(int index) {
    if (index < 0 || index >= (int)open_docs_.size()) return;
    sync_tab_colors(); // active/inactive text colors follow the switch
    emit tab_activated(open_docs_[size_t(index)].rel);
    lsp_did_open("file://" + QFileInfo(open_docs_[size_t(index)].path).absoluteFilePath(),
                 open_docs_[size_t(index)].widget->text());
}

void Editor::on_modified(int index) {
    if (index < 0 || index >= (int)open_docs_.size()) return;
    Open_Doc& doc = open_docs_[size_t(index)];
    doc.dirty = doc.widget->isModified();
    QString label = doc.rel.section('/', -1) + (doc.dirty ? " •" : "");
    setTabText(index, label);
    // Dirty state pairs color + glyph (never color-only). Amber only while
    // dirty; the active tab keeps its full-text color otherwise.
    sync_tab_colors();
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
    const qint64 t0 = perf_clock()->nsecsElapsed(); // TEMP-PROF
    int v = lsp_versions_[uri] + 1;
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
    perf_log("didchange-json-ms", double(perf_clock()->nsecsElapsed() - t0) / 1e6);
}

void Editor::lsp_did_save(const QString& uri) {
    QString json = QJsonDocument(QJsonObject{{"textDocument", QJsonObject{{"uri", uri}}}})
                       .toJson(QJsonDocument::Compact);
    send_lsp_notify("textDocument/didSave", json);
}

void Editor::lsp_completion(const QString& uri, int line, int col) {
    const qint64 t0w = perf_clock()->nsecsElapsed(); // TEMP-PROF
    QString json = QJsonDocument(QJsonObject{
        {"textDocument", QJsonObject{{"uri", uri}}},
        {"position", QJsonObject{{"line", line}, {"character", col}}}})
                       .toJson(QJsonDocument::Compact);
    lsp_pending_[lsp_next_id_] = "completion";
    send_lsp(lsp_next_id_++, "textDocument/completion", json);
    perf_log("lsp-write-ms", double(perf_clock()->nsecsElapsed() - t0w) / 1e6);
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
    // Remember the queried word: when slangd answers null (declaration lines,
    // cross-module symbols), the response handler falls back to a local
    // top-level-declaration search with it.
    last_def_uri_ = uri;
    last_def_word_.clear();
    QsciScintilla* ed = current_editor();
    if (ed) {
        QString text = ed->text(line);
        int s = std::min(col, (int)text.size());
        while (s > 0 && (text[s - 1].isLetterOrNumber() || text[s - 1] == '_')) --s;
        int e = std::min(col, (int)text.size());
        while (e < (int)text.size() &&
               (text[e].isLetterOrNumber() || text[e] == '_'))
            ++e;
        last_def_word_ = text.mid(s, e - s);
    }
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
        if (current_editor()) QToolTip::showText(QCursor::pos(), contents, current_editor());
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
            // slangd answers null for declaration lines, keywords, attribute
            // names and cross-module symbols (verified with slangd 2026.18.2
            // probes). Fall back to the legacy local search: a top-level line
            // declaring the word ("struct <word>" / "<ret> <word>("), same
            // heuristic as ied_find_definition in the Odin app. Silent when
            // nothing matches (keyword/attribute click).
            if (last_def_word_.isEmpty()) return;
            QsciScintilla* ed = current_editor();
            if (!ed) return;
            QString word = last_def_word_;
            QString struct_needle = "struct " + word;
            QString call_needle = word + "(";
            int lines = int(ed->SendScintilla(QsciScintillaBase::SCI_GETLINECOUNT));
            for (int ln = 0; ln < lines; ++ln) {
                QString text = ed->text(ln);
                if (text.trimmed().startsWith("//")) continue;
                if (text.trimmed().isEmpty() || text[0] == ' ' || text[0] == '\t') continue;
                if (text.contains(struct_needle)) {
                    ed->setCursorPosition(ln, 0);
                    ed->ensureLineVisible(ln);
                    return;
                }
                int paren = text.indexOf(call_needle);
                if (paren > 0 && !text.left(paren).contains('=')) {
                    ed->setCursorPosition(ln, 0);
                    ed->ensureLineVisible(ln);
                    return;
                }
            }
        }
    } else if (method == "completion") {
        const qint64 t0c = perf_clock()->nsecsElapsed(); // TEMP-PROF
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
        // Cap the scan AND the list: slangd returns the module's entire
        // symbol table; filtering 10k labels per reply on the main thread
        // was the other half of the typing delay. 60 rows is plenty for a
        // popup (Scintilla's list scrolls).
        constexpr int kMaxCompletions = 60;
        for (const QJsonValue& v : items) {
            QString label = v.toObject()["label"].toString();
            if (label.startsWith(prefix) && label != prefix) shown << label;
            if (shown.size() >= kMaxCompletions) break;
        }
        if (shown.size() < kMaxCompletions) {
            shown.removeDuplicates();
            shown.sort();
        }
        if (!shown.isEmpty()) ed->showUserList(1, shown);
        perf_log("popup-shown", -1.0); // temp instrumentation
        perf_log("completion-handle-ms", double(perf_clock()->nsecsElapsed() - t0c) / 1e6);
    }
}

void Editor::on_lsp_ready_read() {
    const qint64 t0r = perf_clock()->nsecsElapsed(); // TEMP-PROF
    const qint64 bytes_in = lsp_->bytesAvailable(); // TEMP-PROF
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
    perf_log("lsp-read-ms", double(perf_clock()->nsecsElapsed() - t0r) / 1e6);
    perf_log("lsp-read-kb", double(bytes_in) / 1024.0);
}

void Editor::apply_diagnostics(const std::vector<Diagnostic>& diags) {
    static const int kUnderline = 8; // custom indicator index
    live_diags_.clear();
    for (Open_Doc& doc : open_docs_) {
        if (!doc.widget) continue;
        QString uri = "file://" + QFileInfo(doc.path).absoluteFilePath();
        doc.widget->SendScintilla(QsciScintillaBase::SCI_INDICATORCLEARRANGE, 0,
                                  long(doc.widget->SendScintilla(
                                      QsciScintillaBase::SCI_GETLENGTH)));
        // Error affordance: a straight red UNDERLINE along the reported
        // token range (whole line when slangd gives no length). No margin
        // dots, no tab badges — the underline IS the signal.
        doc.widget->indicatorDefine(QsciScintilla::PlainIndicator, kUnderline);
        doc.widget->setIndicatorForegroundColor(theme::error_rgb(), kUnderline);
        doc.widget->setIndicatorDrawUnder(true, kUnderline);
        // fillIndicatorRange paints the CURRENT indicator: the Cmd-hover
        // handler leaves it at 9 (amber link) on some docs, which swallowed
        // the red underline. Pin it to the diagnostics index first.
        doc.widget->SendScintilla(QsciScintillaBase::SCI_SETINDICATORCURRENT,
                                  kUnderline);
        for (const Diagnostic& d : diags) {
            if (d.uri != uri) continue;
            live_diags_[uri].push_back(d);
            int line_len = doc.widget->lineLength(d.line);
            int len = d.len > 0 ? d.len : std::max(1, line_len - d.col - 1);
            doc.widget->fillIndicatorRange(d.line, d.col, d.line, d.col + len,
                                           kUnderline);
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
    // Split toggle (floating button): cycles the SHELL's preview state.
    // The button only flips SPLIT <-> FLOAT; FULL is a topbar/F3 choice.
    // The shell owns the state; the host reshapes the SDL window per tick.
    split_on_ = !split_on_;
    reposition_split_button(); // flip to the free bottom corner
    emit split_toggled(split_on_);
}

bool Editor::split_on() const { return split_on_; }

} // namespace editor
