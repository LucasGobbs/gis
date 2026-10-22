// i18n: EN source language, ES/PT catalogs built in code (same entries as
// src/i18n.odin). tr() returns the key unchanged for EN; missing keys fall
// back to English. Only fixed UI vocabulary translates; shader-provided
// names (scenes, params, pins) pass through raw.
#pragma once

#include <QString>

namespace i18n {

enum class Language { EN = 0, ES = 1, PT = 2 };

// Current UI language; set at startup from assets/i18n.lang, changed via
// set_language (which persists the tag byte back to the file).
extern Language app_language;

QString tr(const char* key);

void set_language(Language lang);
void init();

} // namespace i18n
