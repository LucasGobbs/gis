// input.ini loader: `action = [mod+]key` per line, `#` comments, `[sections]`
// ignored, repeated action lines accumulate. Port of src/glove/keymap.odin
// parsing rules; the app-side actions live in ui/shell.cpp (BUG-10: the
// port previously ignored assets/input.ini entirely).
#pragma once

#include <QKeySequence>
#include <QString>
#include <QVector>

namespace input_map {

// Loads assets/input.ini; returns the Qt key sequences bound to each named
// action. Unknown actions are simply absent from the map (the loader moves
// on, matching the glove loader).
QVector<QKeySequence> load(const QString& path, const QString& action);

} // namespace input_map
