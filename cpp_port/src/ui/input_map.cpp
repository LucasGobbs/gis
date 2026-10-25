// input.ini parsing. Key names mirror the glove Key enum lowercased without
// the leading '_' ("escape", "f1", "1", "lgui"); mouse buttons are not
// representable as QKeySequence so they are skipped; modifiers are
// shift|ctrl|alt|gui (gui = Cmd on macOS).
#include "input_map.hpp"

#include <QFile>
#include <QTextStream>

#include <map>

namespace input_map {

static QString mod_key_to_qt(const QString& mods, const QString& key);

// Maps one key token onto the Qt key (glove names == SDL keycodes minus '_').
static int key_to_qt(const QString& raw) {
    const std::map<QString, int> named = {
        {"escape", Qt::Key_Escape},     {"tab", Qt::Key_Tab},
        {"space", Qt::Key_Space},       {"return", Qt::Key_Return},
        {"enter", Qt::Key_Return},      {"backspace", Qt::Key_Backspace},
        {"delete", Qt::Key_Delete},     {"minus", Qt::Key_Minus},
        {"equal", Qt::Key_Equal},       {"left", Qt::Key_Left},
        {"right", Qt::Key_Right},       {"up", Qt::Key_Up},
        {"down", Qt::Key_Down},         {"home", Qt::Key_Home},
        {"end", Qt::Key_End},           {"pageup", Qt::Key_PageUp},
        {"pagedown", Qt::Key_PageDown},
    };
    if (raw.size() == 1) return raw[0].toUpper().unicode();
    if (auto it = named.find(raw); it != named.end()) return it->second;
    // Function keys f1..f24.
    if (raw.size() >= 2 && raw[0] == 'f') {
        bool ok = false;
        int n = raw.mid(1).toInt(&ok);
        if (ok && n >= 1 && n <= 24) return Qt::Key_F1 + n - 1;
    }
    return 0;
}

static QString mod_key_to_qt(const QString& mods, const QString& key) {
    if (key.startsWith("mouse_")) return {}; // mouse buttons: not QKeySequence
    int k = key_to_qt(key);
    if (!k) return {};
    int qmods = Qt::NoModifier;
    for (const QString& mod : mods.split('+', Qt::SkipEmptyParts)) {
        if (mod == "shift") qmods |= Qt::ShiftModifier;
        else if (mod == "ctrl") qmods |= Qt::ControlModifier;
        else if (mod == "alt") qmods |= Qt::AltModifier;
        else if (mod == "gui" || mod == "lgui" || mod == "rgui") qmods |= Qt::MetaModifier;
        else return {};
    }
    return QKeySequence(int(qmods) | k).toString(QKeySequence::NativeText);
}

QVector<QKeySequence> load(const QString& path, const QString& action) {
    QVector<QKeySequence> out;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return out;
    QTextStream in(&f);
    while (!in.atEnd()) {
        QString line = in.readLine();
        int comment = line.indexOf('#');
        if (comment >= 0) line = line.left(comment);
        line = line.trimmed();
        if (line.isEmpty() || line.startsWith('[')) continue;
        int eq = line.indexOf('=');
        if (eq <= 0) continue;
        if (line.left(eq).trimmed() != action) continue;
        QString value = line.mid(eq + 1).trimmed();
        // Split "gui+s" into mods "gui" + key "s".
        QString key = value, mods;
        int last_plus = value.lastIndexOf('+');
        if (last_plus > 0) {
            mods = value.left(last_plus);
            key = value.mid(last_plus + 1);
        }
        QString seq = mod_key_to_qt(mods, key);
        if (!seq.isEmpty() && !out.contains(seq)) out.push_back(seq);
    }
    return out;
}

} // namespace input_map
