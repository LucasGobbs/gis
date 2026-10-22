#pragma once

// LEARN: learning-trail markdown renderer (Qt port of src/ui_learn.odin +
// src/md_learn.odin). Pages live in assets/trails/*.md; "index" is home.
// The parser below covers the trail corpus: headings, paragraphs, bullets,
// fenced code blocks, inline code, [text](scene:NAME) / [text](trail:NAME)
// links and plain URLs. Follows a link only after rendering returns
// (md_learn rule): "scene:NAME" emits scene_requested, "trail:NAME"
// navigates in place.

#include <QString>
#include <QWidget>

class QLabel;
class QScrollArea;
class QVBoxLayout;

namespace learn {

class Trail_View : public QWidget {
    Q_OBJECT
public:
    explicit Trail_View(QWidget* parent = nullptr);
    // Loads assets/trails/<page>.md ("" = index) and renders it.
    void load(const QString& page);

signals:
    // Scene chip clicked in the trail prose.
    void scene_requested(const QString& scene_title);

private:
    bool load_page(const QString& page); // returns false when missing
    void render(const QString& text);
    void follow_link(const QString& target);
    void add_link(const QString& label, const QString& target);

    QScrollArea* scroll_ = nullptr;
    QWidget* page_ = nullptr;
    QVBoxLayout* page_layout_ = nullptr;
    QString current_page_ = "index";
};

} // namespace learn
