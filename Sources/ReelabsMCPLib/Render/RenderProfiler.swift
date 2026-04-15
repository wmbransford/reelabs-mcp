import Foundation

/// Lightweight performance profiler for the render pipeline.
/// Tracks elapsed time per phase and aggregates compositor frame stats.
final class RenderProfiler: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, seconds: Double)] = []
    private let wallStart = CFAbsoluteTimeGetCurrent()

    /// Record the elapsed time for a named phase.
    func record(_ name: String, seconds: Double) {
        lock.lock()
        entries.append((name, seconds))
        lock.unlock()
    }

    /// Time an async block and record it under the given name.
    func measure<T: Sendable>(_ name: String, _ work: @Sendable () async throws -> T) async rethrows -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = try await work()
        record(name, seconds: CFAbsoluteTimeGetCurrent() - t0)
        return result
    }

    /// Returns timing data for inclusion in render response JSON.
    func responseTiming() -> [String: Any] {
        let wall = CFAbsoluteTimeGetCurrent() - wallStart
        lock.lock()
        let snapshot = entries
        lock.unlock()

        var dict: [String: Any] = [
            "wall_seconds": r3(wall),
        ]
        for entry in snapshot {
            dict["\(entry.name)_seconds"] = r3(entry.seconds)
        }

        if let fs = FrameStats.shared.summary() {
            dict["compositor_frames"] = fs.count
            dict["compositor_avg_ms"] = r2(fs.avgSeconds * 1000)
            dict["compositor_p50_ms"] = r2(fs.p50Seconds * 1000)
            dict["compositor_p95_ms"] = r2(fs.p95Seconds * 1000)
            dict["compositor_max_ms"] = r2(fs.maxSeconds * 1000)
            dict["compositor_wall_seconds"] = r3(fs.wallSeconds)
            dict["compositor_effective_fps"] = r1(fs.effectiveFPS)
        }

        return dict
    }

    /// Log a human-readable summary to stderr + caption debug log.
    func logSummary() {
        let wall = CFAbsoluteTimeGetCurrent() - wallStart
        lock.lock()
        let snapshot = entries
        lock.unlock()

        var lines = ["\n=== RENDER PERFORMANCE PROFILE ==="]
        lines.append("Total wall time: \(fmtDuration(wall))")
        for entry in snapshot {
            let pct = wall > 0 ? Int(entry.seconds / wall * 100) : 0
            lines.append("  \(entry.name): \(fmtDuration(entry.seconds)) (\(pct)%)")
        }

        if let fs = FrameStats.shared.summary() {
            lines.append("  --- Compositor ---")
            lines.append(
                "  \(fs.count) frames | avg \(r2(fs.avgSeconds * 1000))ms | p95 \(r2(fs.p95Seconds * 1000))ms | max \(r2(fs.maxSeconds * 1000))ms"
            )
            lines.append(
                "  wall \(fmtDuration(fs.wallSeconds)) | effective \(r1(fs.effectiveFPS)) fps"
            )
        }

        lines.append("=================================")
        captionLog(lines.joined(separator: "\n"))
    }

    private func fmtDuration(_ s: Double) -> String {
        if s < 0.001 { return "<1ms" }
        if s < 1 { return "\(Int(s * 1000))ms" }
        if s < 60 { return "\(r2(s))s" }
        let min = Int(s) / 60
        let sec = r2(s - Double(min * 60))
        return "\(min)m \(sec)s"
    }

    private func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// Per-frame timing stats collected by VideoCompositor.
/// Uses a shared static since AVFoundation instantiates the compositor internally.
final class FrameStats: @unchecked Sendable {
    static let shared = FrameStats()

    private let lock = NSLock()
    private var frameTimes: [Double] = []
    private var firstFrameWall: Double = 0
    private var lastFrameWall: Double = 0

    struct Summary {
        let count: Int
        let avgSeconds: Double
        let p50Seconds: Double
        let p95Seconds: Double
        let maxSeconds: Double
        let minSeconds: Double
        let wallSeconds: Double
        let effectiveFPS: Double
    }

    func reset() {
        lock.lock()
        frameTimes.removeAll(keepingCapacity: true)
        firstFrameWall = 0
        lastFrameWall = 0
        lock.unlock()
    }

    func record(elapsed: Double) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if frameTimes.isEmpty { firstFrameWall = now }
        lastFrameWall = now
        frameTimes.append(elapsed)
        lock.unlock()
    }

    func summary() -> Summary? {
        lock.lock()
        let times = frameTimes
        let first = firstFrameWall
        let last = lastFrameWall
        lock.unlock()

        guard !times.isEmpty else { return nil }
        let sorted = times.sorted()
        let avg = times.reduce(0, +) / Double(times.count)
        let wall = last - first

        return Summary(
            count: times.count,
            avgSeconds: avg,
            p50Seconds: sorted[sorted.count / 2],
            p95Seconds: sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)],
            maxSeconds: sorted.last!,
            minSeconds: sorted.first!,
            wallSeconds: wall,
            effectiveFPS: wall > 0 ? Double(times.count) / wall : 0
        )
    }
}
