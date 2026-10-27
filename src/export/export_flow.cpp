// GIF export: assembles the dumped frames with ffmpeg (fps=17, scale=480:-1).
#include "export_flow.hpp"

#include <QProcess>

#include "ui/notify.hpp"

namespace export_flow {

void assemble_gif(const QString& frames_dir, const QString& out_path) {
    auto* ffmpeg = new QProcess(); // self-deleting: both outcomes below call deleteLater
    QStringList args;
    args << "-y"
         << "-framerate" << "17"
         << "-i" << frames_dir + "/frame_%04d.png"
         << "-vf" << "scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
         << out_path;
    // ffmpeg missing or crashed: `finished` may never fire, so report here too.
    QObject::connect(ffmpeg, &QProcess::errorOccurred, ffmpeg, [ffmpeg](QProcess::ProcessError) {
        notify::notify(notify::Kind::ERROR_, "gif: ffmpeg could not run");
        ffmpeg->deleteLater();
    });
    QObject::connect(ffmpeg, &QProcess::finished, ffmpeg, [ffmpeg](int code, QProcess::ExitStatus st) {
        if (code != 0 || st != QProcess::NormalExit) notify::notify(notify::Kind::ERROR_, "gif: ffmpeg failed");
        ffmpeg->deleteLater();
    });
    ffmpeg->start("ffmpeg", args);
}

} // namespace export_flow
