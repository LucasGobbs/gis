// Toasts: user-facing notices (info/warn/error) with dedupe, mirroring
// src/notify.odin semantics. Qt surfaces them as floating labels under the
// title bar; core code just calls notify().
#pragma once

#include <QString>
class QWidget;

namespace notify {

enum class Kind { INFO, WARN, ERROR_ };

// Thread-safe: dedupes identical texts within the window, folds repeats.
void notify(Kind kind, const QString& text);

// Surface toasts as floating cards over `host`; without it notices are
// stored but never shown.
void attach(QWidget* host);

} // namespace notify
