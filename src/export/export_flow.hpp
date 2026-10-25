// Stage 9: PNG frame export, GIF assembly via ffmpeg (QProcess), and the
// LEARN panel wiring (trail pages render as simple md in the shell panel).
// 3D orbit + cgltf + skybox reuse the existing scene pipeline (uniform
// camera) and are noted in README_GOCPP.md as bundled with the model stage.
#pragma once

#include <QString>
#include <QWidget>

class QProcess;

namespace export_flow {

// PNG: grabs the current frame to exports/<scene>_<t>.png. The frame source
// is the offscreen scene texture read back on the caller's thread (blocking,
// single frame — same cost class as the pixel inspector).
bool export_png(const QString& rgba_path, const QString& out_path);

// GIF: renders [start,end] one frame per app frame (driven by the host),
// dumps numbered PNGs to a temp dir, then assembles with ffmpeg at 17 fps
// into exports/<scene>.gif, 480 px wide. Returns the process (caller keeps
// it alive and tracks finished()).
QProcess* assemble_gif(const QString& frames_dir, int frame_count, const QString& out_path);

} // namespace export_flow
