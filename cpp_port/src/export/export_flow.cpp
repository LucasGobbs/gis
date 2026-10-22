// Export implementation: PNG writes the raw RGBA frame; GIF assembles with
// the ffmpeg filter the Odin app uses (fps=17, scale=480:-1).
#include "export_flow.hpp"

#include <QProcess>

#include <cstdio>

#include "ui/notify.hpp"

namespace export_flow {

bool export_png(const QString& rgba_path, const QString& out_path) {
    // rgba_path: temp file with raw RGBA rows (w*h*4). The caller converts
    // through QImage for PNG encoding.
    QProcess convert;
    convert.start("sips", QStringList{} << "-s" << "format" << "png" << rgba_path
                                        << "--out" << out_path);
    convert.waitForFinished(30000);
    return convert.exitStatus() == QProcess::NormalExit && convert.exitCode() == 0;
}

QProcess* assemble_gif(const QString& frames_dir, int frame_count,
                       const QString& out_path) {
    (void)frame_count; // ffmpeg derives the count from the glob pattern
    auto* ffmpeg = new QProcess();
    QStringList args;
    args << "-y"
         << "-framerate" << "17"
         << "-i" << frames_dir + "/frame_%04d.png"
         << "-vf" << "scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
         << out_path; // BUG-5: the output path was never appended — ffmpeg
                      // exited with "output file must be specified" and the
                      // GIF silently vanished (errorOccurred only
                      // deleteLater'd the process).
    QObject::connect(ffmpeg, &QProcess::errorOccurred, ffmpeg,
                     [ffmpeg](QProcess::ProcessError) { ffmpeg->deleteLater(); });
    QObject::connect(ffmpeg, &QProcess::finished, ffmpeg, [ffmpeg](int code, QProcess::ExitStatus) {
        if (code != 0) notify::notify(notify::Kind::ERROR_, "gif: ffmpeg failed");
        ffmpeg->deleteLater();
    });
    ffmpeg->start("ffmpeg", args);
    return ffmpeg;
}

} // namespace export_flow
