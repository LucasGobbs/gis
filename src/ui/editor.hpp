#pragma once

// Stage 5+6: code editor (QScintilla-based) and the slangd LSP client.
// Editor: tabs follow the scene unit (entry + pass_N modules), dirty
// tracking, save-all on Cmd+S, navigation history, squiggles from build
// diagnostics (cleared on edit, message on hover), Cmd+F find bar,
// Cmd+= / Cmd+- font zoom. LSP: QProcess slangd over stdio JSON-RPC,
// diagnostics with a 280 ms debounce (18 frames at 60 fps), completion,
// hover, goto-def, rename.

#include <map>
#include <QString>
#include <QTabWidget>
#include <QWidget>

class QProcess;

class QsciScintilla;
class QLineEdit;
class QLabel;
class QWidget;

namespace editor {

struct Open_Doc {
    QString rel;      // editor-files name (no .slang): scenes/<scene>/<name>
    QString path;     // absolute file path
    QString text;     // last loaded/saved text
    bool loaded = false;
    bool dirty = false;
    QsciScintilla* widget = nullptr;
};

struct Diagnostic {
    QString uri;
    int line = 0;      // 0-based
    int col = 0;
    int len = 0;
    QString message;
    bool error = false;
};

// Shared with the Shell settings menu; the editor skins follow these.
enum class Editor_Theme { DARK, LIGHT, MONOKAI, SOLARIZED };

class Editor : public QTabWidget {
    Q_OBJECT
public:
    explicit Editor(QWidget* parent = nullptr);

    // Files list (ied_rescan): every .slang under src/shaders + gis_scenes.
    void rescan();
    // Loads the scene unit's entry + modules as tabs; closes other units'
    // clean tabs (dirty tabs survive, matching ied_close_unit).
    void load_unit(const QString& scene_title, const QString& root_dir);
    void load_named(const QString& rel);
    // Code skin for new tabs (DARK = Darkroom palette, MONOKAI etc.); applies
    // to already-open tabs too.
    void set_theme(Editor_Theme theme);
    int save_all();
    int dirty_count() const;
    QString status() const { return status_; }
    // Closes the active tab (Cmd+W / File>Close); dirty tabs survive, same
    // rule as the tab's close button.
    void close_current_tab();

    // Build diagnostics -> squiggles on matching open docs.
    void apply_diagnostics(const std::vector<editor::Diagnostic>& diags);
    // Opens the Cmd+F find bar (find/next in the current tab).
    void open_find();
    // Font zoom: Cmd+= / Cmd+- across all open tabs; persists in prefs.
    void zoom_in();
    void zoom_out();
    // Current skin (LEARN reads it to mirror code-token colors).
    Editor_Theme theme() const { return theme_; }
    void set_editor_font(int pt);
    // Splits the current tab side-by-side (read-only mirror pane).
    void split_current();
    QWidget* editor_dock_host();

    // LSP lifecycle (stage 6): slangd on the active doc.
    void lsp_start(const QString& workspace_root);
    void lsp_stop();
    void lsp_did_open(const QString& uri, const QString& text);
    void lsp_did_change(const QString& uri, const QString& text);
    void lsp_did_save(const QString& uri);
    void lsp_completion(const QString& uri, int line, int col);
    void lsp_hover(const QString& uri, int line, int col);
    void lsp_goto_def(const QString& uri, int line, int col);
    void lsp_rename(const QString& uri, int line, int col, const QString& new_name);
    void send_lsp_notify(const QString& method, const QString& params_json);

signals:
    void status_changed(const QString& status);
    void diagnostics_ready(const std::vector<editor::Diagnostic>& diags);
    void font_changed(int pt);

private slots:
    void on_tab_changed(int index);
    void on_modified(int index);
    void on_lsp_ready_read();
    void on_lsp_finished(int exit_code, int status); // QProcess::ExitStatus as int (keeps the header QProcess-free)

private:
    // Editor viewport event filter: Cmd+click -> definition; Cmd hover ->
    // underline the identifier under the cursor. Per-viewport (load_named).
    bool eventFilter(QObject* watched, QEvent* event) override;
    bool line_col_at(QsciScintilla* edit, const QPoint& vp, int& line, int& col);
    void update_link_underline(QsciScintilla* edit, const QPoint& vp, bool cmd);
    QsciScintilla* current_editor();
    QString file_path_for_rel(const QString& rel) const;
    Open_Doc* find_doc(const QString& rel);
    Open_Doc* doc_for_widget(QWidget* widget);
    void send_lsp(int id, const QString& method, const QString& params_json);
    void handle_lsp_message(const QByteArray& payload);
    QString doc_uri(const QsciScintilla* edit) const;
    QString diag_message_at(const QString& uri, long pos) const;

    std::vector<QString> files_;
    std::vector<Open_Doc> open_docs_;
    QString status_;
    QString unit_prefix_;
    Editor_Theme theme_ = Editor_Theme::DARK;
    // Font size (pt) applied to every doc's lexer + widget.
    int font_size_ = 12;
    void apply_font();
    // Smooth wheel scroll: fractional lines pending between wheel events.
    double scroll_acc_ = 0;
    // LSP state.
    QProcess* lsp_ = nullptr;
    QString lsp_root_;
    QByteArray lsp_buffer_;
    int lsp_next_id_ = 1;
    QMap<int, QString> lsp_pending_; // id -> method
    QMap<QString, int> lsp_versions_; // uri -> didChange version
    QMap<QString, QTimer*> lsp_timers_; // rel -> 280 ms debounce timer
    bool lsp_initialized_ = false;   // initialize/initialized handshake done
    QSet<QString> opened_on_server_; // didOpen sent for this server session
    // goto-def clicked before the handshake finished; replayed on initialize.
    std::tuple<QString, int, int> pending_def_;
    bool has_pending_def_ = false;
    // Diagnostics currently painted, per uri; cleared when that doc's text
    // changes so stale squiggles never outlive the code that produced them.
    std::map<QString, std::vector<Diagnostic>> live_diags_;
    // Find bar: line edit + status docked over the active editor.
    QWidget* find_bar_ = nullptr;
    QLineEdit* find_edit_ = nullptr;
    QLabel* find_status_ = nullptr;
    void find_next();
    void hide_find();
    // Split view: a READ-ONLY clone mirrors the current doc side-by-side.
    QsciScintilla* split_clone_ = nullptr;
};

} // namespace editor
