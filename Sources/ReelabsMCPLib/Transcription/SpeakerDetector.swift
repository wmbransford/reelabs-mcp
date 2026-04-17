import Foundation

/// Pick the active speaker at each moment across N synchronized sources, using
/// per-source word density as ground truth.
///
/// The inputs are transcripts from separate sources (e.g. one mic per person in
/// a podcast or interview). Time is discretized into fixed windows; whichever
/// source has the most words in a window "wins" that window. Ties are broken by
/// continuity with the previous active speaker, so brief overlaps don't cause
/// cuts. Runs are then collapsed and segments shorter than `minSegmentLength`
/// are absorbed into the preceding segment.
///
/// Deterministic compute — no agent judgment involved. Drop the returned
/// segments straight into a RenderSpec.
package struct SpeakerDetector {
    package struct Segment: Equatable, Sendable {
        package let sourceId: String
        package let start: Double
        package let end: Double

        package init(sourceId: String, start: Double, end: Double) {
            self.sourceId = sourceId
            self.start = start
            self.end = end
        }
    }

    package struct Result: Sendable {
        package let segments: [Segment]
        package let totalDuration: Double

        package init(segments: [Segment], totalDuration: Double) {
            self.segments = segments
            self.totalDuration = totalDuration
        }
    }

    package static func detect(
        sources: [(sourceId: String, words: [WordEntry])],
        minSegmentLength: Double = 1.0,
        windowSize: Double = 0.2
    ) -> Result {
        guard !sources.isEmpty else { return Result(segments: [], totalDuration: 0) }

        let duration = sources.flatMap { $0.words.map { $0.end } }.max() ?? 0
        guard duration > 0 else { return Result(segments: [], totalDuration: 0) }

        let effectiveWindow = max(windowSize, 0.05)
        let windowCount = max(1, Int(ceil(duration / effectiveWindow)))

        var buckets: [[Int]] = Array(
            repeating: Array(repeating: 0, count: windowCount),
            count: sources.count
        )
        for (srcIdx, src) in sources.enumerated() {
            for word in src.words {
                let midpoint = (word.start + word.end) / 2
                let winIdx = min(max(Int(midpoint / effectiveWindow), 0), windowCount - 1)
                buckets[srcIdx][winIdx] += 1
            }
        }

        var active = [Int](repeating: 0, count: windowCount)
        var lastActive = 0
        for w in 0..<windowCount {
            var maxCount = 0
            var winner = -1
            for (i, bucket) in buckets.enumerated() where bucket[w] > maxCount {
                maxCount = bucket[w]
                winner = i
            }
            if maxCount == 0 {
                active[w] = lastActive
            } else if buckets[lastActive][w] == maxCount {
                active[w] = lastActive
            } else {
                active[w] = winner
                lastActive = winner
            }
        }

        var runs: [(idx: Int, start: Double, end: Double)] = []
        var segStart = 0.0
        var currentIdx = active[0]
        for w in 1..<windowCount where active[w] != currentIdx {
            let segEnd = Double(w) * effectiveWindow
            runs.append((currentIdx, segStart, segEnd))
            segStart = segEnd
            currentIdx = active[w]
        }
        runs.append((currentIdx, segStart, duration))

        var absorbed: [(idx: Int, start: Double, end: Double)] = []
        for seg in runs {
            if (seg.end - seg.start) < minSegmentLength, !absorbed.isEmpty {
                absorbed[absorbed.count - 1].end = seg.end
            } else {
                absorbed.append(seg)
            }
        }

        var final: [(idx: Int, start: Double, end: Double)] = []
        for seg in absorbed {
            if let last = final.last, last.idx == seg.idx {
                final[final.count - 1].end = seg.end
            } else {
                final.append(seg)
            }
        }

        let output = final.map {
            Segment(sourceId: sources[$0.idx].sourceId, start: $0.start, end: $0.end)
        }
        return Result(segments: output, totalDuration: duration)
    }
}
