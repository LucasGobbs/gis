#pragma once

// LEARN: learning-trail markdown renderer (Qt port of src/ui_learn.odin +
// src/md_learn.odin, driven by the vendored md4c C parser). Pages live in
// assets/trails/*.md; "index" is home. Links never navigate during
// parsing — clicks go through a queued follow: "scene:NAME" emits
// scene_requested, "trail:NAME" navigates in place. Code blocks carry the
// editor theme's token colors and click-to-copy (line / block).

#include <QString>
#include <QWidget>

#include "theme.hpp"

class QScrollArea;
class QVBoxLayout;

namespace learn {

class Trail_View : public QWidget {
    Q_OBJECT
public:
    explicit Trail_View(QWidget* parent = nullptr);
    // Loads assets/trails/<page>.md ("" = index) and renders it.
    void load(const QString& page);
    // Click target for the renderer's link widgets (public: the md4c
    // callbacks construct them).
    void follow_link_public(const QString& target);

signals:
    // Scene chip clicked in the trail prose.
    void scene_requested(const QString& scene_title);

protected:
    void showEvent(QShowEvent* event) override;

private:
    void render(const QString& text);
    void follow_link(const QString& target);

    QScrollArea* scroll_ = nullptr;
    QWidget* page_ = nullptr;
    QVBoxLayout* page_layout_ = nullptr;
    QString current_page_ = "index";
    QString page_text_;                  // last rendered markdown (re-render on skin change)
    theme::App_Theme rendered_theme_ = theme::App_Theme::Dark;
};

} // namespace learn
