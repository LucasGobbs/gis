// Toast state + widget. The store is plain data (mutex-guarded); the widget
// draws floating cards top-right under the title bar, mirrors notify.odin
#include "notify.hpp"
#include "shell.hpp" // kTopbarH (toast layer clears the top bar)
#include "theme.hpp"

#include <QLabel>
#include <QMouseEvent>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>

#include <chrono>
#include <mutex>
#include <vector>

namespace notify {

struct Notice {
    QString text;
    Kind kind = Kind::INFO;
    double age = 0;
    int hits = 1;
};

static constexpr double kLifetime = 7.0;
static constexpr double kFade = 0.6;
static constexpr double kDedupWindow = 2.0;
static constexpr int kMax = 5;

static std::mutex g_mu;
static std::vector<Notice> g_notices;

void notify(Kind kind, const QString& text) {
    std::lock_guard<std::mutex> lock(g_mu);
    for (Notice& existing : g_notices) {
        if (existing.text == text && existing.age < kDedupWindow) {
            existing.age = 0;
            existing.hits += 1;
            return;
        }
    }
    g_notices.push_back(Notice{text, kind, 0, 1});
    while ((int)g_notices.size() > kMax) g_notices.erase(g_notices.begin());
}

static QString kind_color(const Notice& n) {
    // Semantic palette from the active skin: info = signature blue,
    // warn = safelight amber, error = bake-failure red.
    switch (n.kind) {
    case Kind::WARN: return theme::safelight();
    case Kind::ERROR_: return theme::error();
    case Kind::INFO: return theme::info();
    }
    return theme::text_primary();
}

// Floating overlay widget parenting one QLabel per toast.
class Toast_Layer : public QWidget {
public:
    explicit Toast_Layer(QWidget* parent) : QWidget(parent) {
        // Click-through: the layer covers the whole viewport; a mouse-agnostic
        // widget would swallow every click over the scene (and the editor).
        setAttribute(Qt::WA_TransparentForMouseEvents);
        setAttribute(Qt::WA_TranslucentBackground);
        // Own tooltip-style window: the SDL render surface is a NATIVE child
        // NSWindow kept above Qt widgets, so a plain child widget would hide
        // UNDER it; a Qt::ToolTip window floats above and never takes focus.
        setWindowFlags(Qt::ToolTip | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint);
        auto* layout = new QVBoxLayout(this);
        layout->setContentsMargins(0, shell::kTopbarH + 16, 12, 0);
        layout->setSpacing(6);
        layout->setAlignment(Qt::AlignTop | Qt::AlignRight);
        auto* refresh = new QTimer(this);
        connect(refresh, &QTimer::timeout, this, &Toast_Layer::tick);
        refresh->start(120);
    }

    void tick() {
        std::lock_guard<std::mutex> lock(g_mu);
        double dt = 0.12;
        // Expire + rebuild labels (5 cards max; cheap at this rate).
        for (long i = (long)g_notices.size() - 1; i >= 0; --i) {
            g_notices[size_t(i)].age += dt;
            if (g_notices[size_t(i)].age >= kLifetime) g_notices.erase(g_notices.begin() + i);
        }
        while ((int)cards.size() < (int)g_notices.size()) {
            auto* label = new QLabel(this);
            label->setTextFormat(Qt::PlainText); // toast text may contain <...>
            label->setStyleSheet(
                QString("QLabel { background: %1; border-radius: 6px;"
                        " padding: 8px 12px; color: %2; font-size: 9pt; }")
                    .arg(theme::overlay_scrim(235), theme::text_primary()));
            label->setMaximumWidth(340);
            label->setWordWrap(true);
            label->show();
            cards.append(label);
            layout()->addWidget(label);
        }
        while ((int)cards.size() > (int)g_notices.size()) {
            cards.last()->deleteLater();
            cards.removeLast();
        }
        for (int i = 0; i < (int)g_notices.size(); ++i) {
            const Notice& n = g_notices[size_t(i)];
            QString text = n.text;
            if (n.hits > 1) text += QString(" ×%1").arg(n.hits);
            double alpha = n.age > kLifetime - kFade ? (kLifetime - n.age) / kFade : 1.0;
            cards[i]->setText(text);
            QString color = kind_color(n);
            cards[i]->setStyleSheet(QString(
                "QLabel { background: %1; border-radius: 6px;"
                " padding: 8px 12px; color: %2; font-size: 9pt; }")
                                        .arg(theme::overlay_scrim(int(235 * alpha)))
                                        .arg(color));
        }
    }

    QList<QLabel*> cards;
    // Glue: re-follow host resizes (installEventFilter in attach()).
    bool eventFilter(QObject* watched, QEvent* ev) override {
        if (watched == parentWidget() && ev->type() == QEvent::Resize)
            setGeometry(QRect(parentWidget()->mapToGlobal(QPoint(0, 0)),
                              parentWidget()->size()));
        return QWidget::eventFilter(watched, ev);
    }
};

void attach(QWidget* host) {
    auto* layer = new Toast_Layer(host);
    layer->setObjectName("toast_layer");
    host->installEventFilter(layer);
    // Qt::ToolTip is a top-level window: geometry must be global (host maps
    // into the frameless Shell window, which itself can be moved).
    layer->setGeometry(QRect(host->mapToGlobal(QPoint(0, 0)), host->size()));
    layer->show();
}

} // namespace notify
