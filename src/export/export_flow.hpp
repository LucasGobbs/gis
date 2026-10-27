// GIF export: ffmpeg assembly of the frames the host dumps.
#pragma once

#include <QString>

namespace export_flow {

// Assembles <frames_dir>/frame_%04d.png into a 480 px wide GIF at 17 fps.
// Fire and forget: the process deletes itself and toasts on failure.
void assemble_gif(const QString& frames_dir, const QString& out_path);

} // namespace export_flow
