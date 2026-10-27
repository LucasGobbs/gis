// Pixel provenance readbacks over the gfx uploader, and the watch-label
// source parser.
#pragma once

#include "gfx.hpp"

#include <SDL3/SDL_gpu.h>

#include <string>
#include <vector>

namespace inspect {

constexpr int DEBUG_WATCH_COUNT = 8;

// One 1x1 provenance readback for a pass output at (x, y).
class Provenance_Readback {
public:
    struct Result {
        bool valid = false;
        float rgba[4] = {0, 0, 0, 0};
    };
    bool begin(gfx::Uploader& up, SDL_GPUTexture* source, int x, int y);
    bool poll(gfx::Uploader& up, Result& out);

private:
    gfx::Staging staging_;
    bool pending_ = false;
};

// Watch labels parsed from the shader source (debug_watch_* call sites),
// mirroring scene_parse_debug_watch_labels.
std::vector<std::string> parse_watch_labels(const std::string& source);

} // namespace inspect
