#pragma once

// Stage 5+6: code editor (QScintilla-based) and the slangd LSP client.
// Editor: tabs follow the scene unit (entry + pass_N modules), dirty
// tracking, save-all on Cmd+S, navigation history, squiggles from LSP
// diagnostics (cleared on edit, message on hover), Cmd+F find bar,
// Cmd+= / Cmd+- font zoom. LSP: QProcess slangd over stdio JSON-RPC,
// diagnostics with a 280 ms debounce (18 frames at 60 fps), completion,
// hover, goto-def.
// Env switches: GIS_NO_LSP (never spawn slangd), GIS_REDUCED_MOTION (steady
// bar caret instead of the pulsing block).

#include <map>
#include <tuple>
#include <vector>
#include <QByteArray>
#include <QMap>
#include <QSet>
#include <QString>
#include <QTabWidget>
#include <QWidget>

class QProcess;
class QJsonObject;
class QJsonValue;
class QTimer;
class QWheelEvent;

class QsciScintilla;
class QLineEdit;
class QLabel;
class QPushButton;
class QWidget;

namespace editor {

struct Open_Doc {
    QString rel;      // editor-files name (no .slang): scenes/<scene>/<name>
    QString path;     // absolute file path
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
    ~Editor() override;

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
    // Closes the active tab (Cmd+W / File>Close); dirty tabs survive, same
    // rule as the tab's close button.
    void close_current_tab();

    // Opens the Cmd+F find bar (find/next in the current tab).
    void open_find();
    // Font zoom: Cmd+= / Cmd+- across all open tabs; persists in prefs.
    void zoom_in();
    void zoom_out();
    void set_editor_font(int pt);
    // Pixel-face toggle for the code text (Sergamon); re-skins open tabs.
    void set_pixel_font(bool on);
    // Toggles the split view: code | SHADER PREVIEW. The host catches
    // split_toggled and shrinks the SDL preview window to the right half.
    void split_current();
    bool split_on() const;

    // LSP lifecycle (stage 6): slangd on the active doc.
    void lsp_start();
    void lsp_did_open(const QString& uri, const QString& text);
    void lsp_did_change(const QString& uri, const QString& text);
    void lsp_did_save(const QString& uri);
    void lsp_completion(const QString& uri, int line, int col);
    void lsp_hover(const QString& uri, int line, int col);
    void lsp_goto_def(const QString& uri, int line, int col);
    void send_lsp_notify(const QString& method, const QString& params_json);

signals:
    void status_changed(const QString& status);
    void font_changed(int pt);
    void split_toggled(bool on);
    // plan6 graph sync: the user activated this file's tab (rel path).
    void tab_activated(const QString& rel);

private slots:
    void on_tab_changed(int index);
    void on_modified(int index);
    void on_lsp_ready_read();
    void on_lsp_finished(int exit_code, int status); // QProcess::ExitStatus as int (keeps the header QProcess-free)

private:
    // ---- construction ----
    void build_empty_state();
    void build_find_bar();
    void build_split_button();
    QsciScintilla* create_edit(const QString& text);
    void wire_doc_signals(QsciScintilla* edit, const QString& path);

    // ---- chrome ----
    QWidget* empty_state_ = nullptr;
    void update_empty_state();
    // Chrome pieces of the editor that follow the code skin (find bar,
    // split button) — restyled from the shared skin table, no literals.
    void set_find_bar_theme();
    void update_split_btn_theme();
    // Tab chrome (Plan 03 §2): per-tab text colors follow active/dirty
    // state; called from set_find_bar_theme, on_tab_changed, on_modified.
    void sync_tab_colors();

    // ---- viewport events ----
    // Editor viewport event filter: Cmd+click -> definition; Cmd hover ->
    // underline the identifier under the cursor. Per-viewport (create_edit).
    bool eventFilter(QObject* watched, QEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    bool line_col_at(QsciScintilla* edit, const QPoint& vp, int& line, int& col);
    void update_link_underline(QsciScintilla* edit, const QPoint& vp, bool cmd);
    void scroll_horizontal(QsciScintilla* edit, const QWheelEvent* wheel);
    void scroll_vertical(QsciScintilla* edit, const QWheelEvent* wheel);

    // ---- docs ----
    // Tabs are movable: docs are always resolved by widget, never by index.
    QsciScintilla* current_editor();
    QString file_path_for_rel(const QString& rel) const;
    Open_Doc* find_doc(const QString& rel);
    Open_Doc* doc_for_widget(QWidget* widget);
    Open_Doc* doc_at(int tab_index);
    Open_Doc* doc_for_uri(const QString& uri);
    // Single close path (tab X, Cmd+W, unit switch): refuses dirty docs.
    bool close_tab(int index);
    QString doc_uri(const QsciScintilla* edit) const;
    QString diag_message_at(const QString& uri, long pos);

    std::vector<QString> files_;
    std::vector<Open_Doc> open_docs_;
    QString status_;
    Editor_Theme theme_ = Editor_Theme::DARK;
    // Font size (pt) applied to every doc's lexer + widget.
    int font_size_ = 12;
    bool pixel_font_ = false; // Sergamon pixel face instead of JetBrains Mono
    // Active code face: JetBrains Mono, or Sergamon when the pixel option is
    // on (set_pixel_font).
    QFont editor_font() const;
    void apply_font();
    // Smooth wheel scroll: fractional lines pending between wheel events.
    double scroll_acc_ = 0;
    // Shift+wheel horizontal scroll: pending character columns.
    double h_scroll_acc_ = 0;
    // True while a Cmd-hover link underline is painted (skip the clear otherwise).
    bool link_underline_on_ = false;

    // ---- LSP ----
    bool write_lsp(const QString& body);
    bool send_lsp(int id, const QString& method, const QString& params_json);
    // Sends a request and registers its id only if the write happened.
    void lsp_request(const QString& method, const QString& params_json);
    // Process gone (exit or failed start): free it and reset the session.
    void drop_lsp();
    void handle_lsp_message(const QByteArray& payload);
    void answer_server_request(const QJsonObject& obj);
    void handle_lsp_response(const QJsonObject& obj);
    void on_lsp_initialized();
    void apply_publish_diagnostics(const QJsonObject& params);
    void apply_diagnostics_for_uri(const QString& uri, const std::vector<Diagnostic>& diags);
    void show_hover(const QJsonValue& result);
    void open_definition(const QJsonValue& result);
    void show_completions(const QJsonValue& result);

    QProcess* lsp_ = nullptr;
    QByteArray lsp_buffer_;
    int lsp_next_id_ = 1;
    QMap<int, QString> lsp_pending_; // id -> method
    QMap<QString, int> lsp_versions_; // uri -> last didOpen/didChange version
    QMap<QString, QTimer*> lsp_timers_; // rel -> 280 ms debounce timer
    bool lsp_initialized_ = false;   // initialize/initialized handshake done
    QSet<QString> opened_on_server_; // didOpen sent for this server session
    // goto-def clicked before the handshake finished; replayed on initialize.
    std::tuple<QString, int, int> pending_def_;
    bool has_pending_def_ = false;
    // Word the last definition request queried (for the local fallback when
    // slangd answers null — it does for declaration lines and cross-module
    // symbols).
    QString last_def_word_;
    // Diagnostics currently painted, per uri; cleared when that doc's text
    // changes so stale squiggles never outlive the code that produced them.
    std::map<QString, std::vector<Diagnostic>> live_diags_;

    // ---- find bar / split ----
    // Find bar: line edit + status docked over the active editor.
    QWidget* find_bar_ = nullptr;
    QLineEdit* find_edit_ = nullptr;
    QLabel* find_status_ = nullptr;
    void find_next();
    void hide_find();
    // Split state: true while the host shows the preview beside the code.
    bool split_on_ = false;
    // Floating split toggle (bottom-right of the tab widget).
    QPushButton* split_btn_ = nullptr;
    void reposition_split_button();
};

} // namespace editor
