// Stage 8: per-pass previews (already rendered by submit_scene_frame into
// targets.previews), pixel provenance readbacks, and the eight-slot GPU
// watch console. Port of src/inspect.odin's watch + provenance readbacks.
#pragma once

#include "gfx.hpp"
#include "scene_runtime.hpp"

#include <SDL3/SDL_gpu.h>

#include <array>
#include <string>
#include <vector>

namespace inspect {

constexpr int DEBUG_WATCH_COUNT = 8;
constexpr uint32_t DEBUG_WATCH_RECORD_SIZE = 32; // frameId,type,count,pass + float4
constexpr uint32_t DEBUG_WATCH_RECORD_COUNT = 16; // passes(8) * slots(2)? matches buffer sizing

struct Watch_Sample {
    bool valid = false;
    uint32_t type = 0;   // 1 float, 2 float2, 3 float3, 4 float4
    uint32_t count = 0;
    uint32_t pass = 0;
    float value[4] = {0, 0, 0, 0};
};

// One in-flight watch buffer download.
class Watch_Readback {
public:
    // Starts an async download of the whole watch buffer. Returns false
    // when one is already pending or the buffer is nil.
    bool begin(gfx::Uploader& up, SDL_GPUBuffer* buffer, uint32_t frame_id);
    // Polls; fills samples when the fence completes.
    bool poll(gfx::Uploader& up, std::array<Watch_Sample, 16>& samples);
    void cancel(gfx::Uploader& up);
    bool pending() const { return pending_; }

private:
    gfx::Staging staging_;
    uint32_t frame_id_ = 0;
    bool pending_ = false;
};

// One 1x1 provenance readback for a pass output at (x, y).
class Provenance_Readback {
public:
    struct Result {
        bool valid = false;
        float rgba[4] = {0, 0, 0, 0};
    };
    bool begin(gfx::Uploader& up, SDL_GPUTexture* source, int x, int y);
    bool poll(gfx::Uploader& up, Result& out);
    void cancel(gfx::Uploader& up);
    bool pending() const { return pending_; }

private:
    gfx::Staging staging_;
    bool pending_ = false;
};

// Watch labels parsed from the shader source (debug_watch_* call sites),
// mirroring scene_parse_debug_watch_labels.
std::vector<std::string> parse_watch_labels(const std::string& source);

} // namespace inspect
