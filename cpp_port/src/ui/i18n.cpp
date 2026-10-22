// i18n implementation: EN passthrough + ES/PT hash lookups from the
// generated catalog include.
#include "i18n.hpp"

#include <cstdio>
#include <unordered_map>
#include <string>

#include "i18n_data.inc"

namespace i18n {

Language app_language = Language::EN;

static std::unordered_map<std::string, std::string>* es_map = nullptr;
static std::unordered_map<std::string, std::string>* pt_map = nullptr;

static const std::unordered_map<std::string, std::string>& map_for(Language lang) {
    static std::unordered_map<std::string, std::string> es, pt;
    if (!es_map) {
        for (const Entry& e : k_es) es[e.key] = e.value;
        for (const Entry& e : k_pt) pt[e.key] = e.value;
        es_map = &es;
        pt_map = &pt;
    }
    return lang == Language::ES ? *es_map : *pt_map;
}

static const char* LANG_FILE = "assets/i18n.lang";

QString tr(const char* key) {
    if (app_language == Language::EN || !key) return QString::fromUtf8(key);
    const auto& m = map_for(app_language);
    auto it = m.find(key);
    if (it == m.end()) return QString::fromUtf8(key);
    return QString::fromUtf8(it->second.c_str());
}

void set_language(Language lang) {
    app_language = lang;
    FILE* f = std::fopen(LANG_FILE, "wb");
    if (f) {
        char tag = char(int(lang)) + '0';
        std::fwrite(&tag, 1, 1, f);
        std::fclose(f);
    }
}

void init() {
    Language lang = Language::EN;
    if (FILE* f = std::fopen(LANG_FILE, "rb")) {
        char tag = '0';
        if (std::fread(&tag, 1, 1, f) == 1 && tag >= '0' && tag <= '2')
            lang = Language(tag - '0');
        std::fclose(f);
    }
    set_language(lang);
}

} // namespace i18n
