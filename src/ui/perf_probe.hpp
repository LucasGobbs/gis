// TEMP-PROF: Plan 01 diagnosis instrumentation. Timestamped, env-gated
// (GIS_PERF=1) probes on the hot paths under investigation: split-gutter
// drag, per-tick shell writes, bake toggling, completion round-trip.
// Compile-time kill switch: -DNO_PERF_PROBE removes every probe (zero cost).
// REMOVE THIS FILE + all perf_log() calls after Plan 01 lands.
#pragma once

#ifndef NO_PERF_PROBE

#include <QElapsedTimer>
#include <QHash>
#include <cstdlib>
#include <cstdio>

// One process-wide monotonic clock for every probe.
inline QElapsedTimer* perf_clock() {
    static QElapsedTimer clock = [] {
        QElapsedTimer t;
        t.start();
        return t;
    }();
    return &clock;
}

// GIS_PERF=1 enables stderr emission; also enforces one line per 100 ms
// per tag so per-frame paths cannot flood the log. Burst counters: a
// negative ms logs one line every 50 hits instead of every hit.
inline void perf_log(const char* tag, double ms) {
    static thread_local bool enabled = qEnvironmentVariableIsEmpty("GIS_PERF") == false;
    if (!enabled) return;
    struct Entry { qint64 last_ms = -1000; int burst = 0; };
    static QHash<QByteArray, Entry>* entries = [] {
        auto* h = new QHash<QByteArray, Entry>();
        atexit([] { delete entries; });
        return h;
    }();
    Entry& e = (*entries)[tag];
    ++e.burst;
    const qint64 now = perf_clock()->elapsed();
    const bool time_up = now - e.last_ms >= 100;
    const bool burst_full = e.burst >= 50;
    if (ms >= 0.0) {
        if (!time_up && !burst_full) return;
        std::fprintf(stderr, "[perf] %9lld ms  %-18s %.3f ms  (x%d suppressed)\n",
                     now, tag, ms, e.burst - 1);
    } else {
        if (!time_up && !burst_full) return;
        std::fprintf(stderr, "[perf] %9lld ms  %-18s hit x%d\n",
                     now, tag, e.burst);
    }
    e.last_ms = now;
    e.burst = 0;
}

#else

inline void perf_log(const char*, double) {}

#endif // NO_PERF_PROBE
