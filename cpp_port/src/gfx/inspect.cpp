// Inspect implementation: watch buffer + provenance readbacks over the gfx
// uploader, and the watch-label source parser.
#include "inspect.hpp"

#include <cstring>
#include <fstream>
#include <sstream>

namespace inspect {

bool Watch_Readback::begin(gfx::Uploader& up, SDL_GPUBuffer* buffer, uint32_t frame_id) {
    if (pending_ || !buffer) return false;
    staging_ = gfx::uploader_download_buffer_begin(up, buffer,
                                                   DEBUG_WATCH_RECORD_SIZE * DEBUG_WATCH_COUNT);
    frame_id_ = frame_id;
    pending_ = true;
    return true;
}

bool Watch_Readback::poll(gfx::Uploader& up, std::array<Watch_Sample, 16>& samples) {
    if (!pending_ || !gfx::staging_ready(up, staging_)) return false;
    const uint8_t* base = gfx::staging_read(staging_);
    for (int i = 0; i < DEBUG_WATCH_COUNT; ++i) {
        const uint8_t* record = base + size_t(i) * DEBUG_WATCH_RECORD_SIZE;
        uint32_t record_frame = 0;
        std::memcpy(&record_frame, record, 4);
        if (record_frame != frame_id_) continue;
        Watch_Sample& s = samples[size_t(i)];
        s.valid = true;
        std::memcpy(&s.type, record + 4, 4);
        std::memcpy(&s.count, record + 8, 4);
        std::memcpy(&s.pass, record + 12, 4);
        for (int c = 0; c < 4; ++c) std::memcpy(&s.value[c], record + 16 + c * 4, 4);
    }
    gfx::staging_release(up, staging_);
    pending_ = false;
    return true;
}

void Watch_Readback::cancel(gfx::Uploader& up) {
    if (!pending_) return;
    while (!gfx::staging_ready(up, staging_)) {}
    gfx::staging_release(up, staging_);
    pending_ = false;
}

bool Provenance_Readback::begin(gfx::Uploader& up, SDL_GPUTexture* source, int x, int y) {
    if (pending_ || !source) return false;
    staging_ = gfx::uploader_download_texture_region_begin(up, source, x, y, 1, 1);
    pending_ = true;
    return true;
}

bool Provenance_Readback::poll(gfx::Uploader& up, Result& out) {
    if (!pending_ || !gfx::staging_ready(up, staging_)) return false;
    const uint8_t* base = gfx::staging_read(staging_);
    out.valid = true;
    for (int c = 0; c < 4; ++c) {
        uint8_t b = base[c];
        out.rgba[c] = float(b) / 255.0f;
    }
    gfx::staging_release(up, staging_);
    pending_ = false;
    return true;
}

void Provenance_Readback::cancel(gfx::Uploader& up) {
    if (!pending_) return;
    while (!gfx::staging_ready(up, staging_)) {}
    gfx::staging_release(up, staging_);
    pending_ = false;
}

std::vector<std::string> parse_watch_labels(const std::string& source) {
    // debug_watch_* (slot, LABEL, ...): the value expression becomes the
    // label. Commented-out calls are skipped (line prefix "//").
    std::vector<std::string> labels(DEBUG_WATCH_COUNT);
    for (const char* marker : {"debug_watch_fragment(", "debug_watch_compute("}) {
        size_t cursor = 0;
        while (true) {
            size_t at = source.find(marker, cursor);
            if (at == std::string::npos) break;
            size_t args_start = at + std::strlen(marker);
            // Skip commented lines.
            size_t line_start = source.rfind('\n', at);
            line_start = line_start == std::string::npos ? 0 : line_start + 1;
            if (source.find("//", line_start) != std::string::npos &&
                source.find("//", line_start) < at) {
                cursor = args_start;
                continue;
            }
            // First arg: slot (integer).
            size_t comma1 = source.find(',', args_start);
            if (comma1 == std::string::npos) break;
            size_t comma2 = source.find(',', comma1 + 1);
            if (comma2 == std::string::npos) break;
            std::string slot_text = source.substr(args_start, comma1 - args_start);
            int slot = std::atoi(slot_text.c_str());
            std::string label = source.substr(comma1 + 1, comma2 - comma1 - 1);
            // Trim.
            auto trim = [](std::string& s) {
                size_t b = s.find_first_not_of(" \t");
                size_t e = s.find_last_not_of(" \t");
                s = (b == std::string::npos) ? "" : s.substr(b, e - b + 1);
            };
            trim(label);
            cursor = comma2 + 1;
            if (slot < 0 || slot >= DEBUG_WATCH_COUNT) continue;
            if (label.empty() || !labels[size_t(slot)].empty()) continue;
            if (label.size() > 48) label = label.substr(0, 48);
            labels[size_t(slot)] = label;
        }
    }
    return labels;
}

} // namespace inspect
