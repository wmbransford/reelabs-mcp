import Testing
@testable import ReelabsMCPLib

@Suite("SpeakerDetector")
struct SpeakerDetectorTests {
    private func w(_ start: Double, _ end: Double) -> WordEntry {
        WordEntry(word: "x", start: start, end: end, confidence: 1.0)
    }

    private func denseWords(from: Double, to: Double) -> [WordEntry] {
        var out: [WordEntry] = []
        var t = from
        while t + 0.15 <= to {
            out.append(w(t, t + 0.15))
            t += 0.2
        }
        return out
    }

    @Test("Solo source produces one segment covering full duration")
    func soloSource() {
        let a = [w(0, 0.3), w(0.5, 0.8), w(1.0, 1.3)]
        let result = SpeakerDetector.detect(
            sources: [("A", a), ("B", [])],
            minSegmentLength: 0.5
        )
        #expect(result.segments.count == 1)
        #expect(result.segments[0].sourceId == "A")
        #expect(result.segments[0].start == 0)
    }

    @Test("Alternating speakers produce two segments with transition near the handoff")
    func simpleAlternation() {
        let a = denseWords(from: 0, to: 5)
        let b = denseWords(from: 5, to: 10)
        let result = SpeakerDetector.detect(
            sources: [("A", a), ("B", b)],
            minSegmentLength: 1.0
        )
        #expect(result.segments.count == 2)
        #expect(result.segments[0].sourceId == "A")
        #expect(result.segments[1].sourceId == "B")
        #expect(abs(result.segments[0].end - 5.0) < 0.3)
        #expect(abs(result.segments[1].end - 10.0) < 0.3)
    }

    @Test("Short interjection gets absorbed into surrounding speaker's segment")
    func shortInterjectionAbsorbed() {
        var a = denseWords(from: 0, to: 2)
        a += denseWords(from: 2.8, to: 5)
        let b = [w(2.0, 2.2), w(2.3, 2.5)]
        let result = SpeakerDetector.detect(
            sources: [("A", a), ("B", b)],
            minSegmentLength: 1.0
        )
        #expect(result.segments.count == 1)
        #expect(result.segments[0].sourceId == "A")
    }

    @Test("Continuity breaks ties — previous speaker wins")
    func continuityOnTie() {
        let a = [w(0, 0.5), w(2.0, 2.1)]
        let b = [w(2.0, 2.1)]
        let result = SpeakerDetector.detect(
            sources: [("A", a), ("B", b)],
            minSegmentLength: 0.5
        )
        #expect(result.segments.count == 1)
        #expect(result.segments[0].sourceId == "A")
    }

    @Test("Empty sources produce empty result")
    func emptySources() {
        let result = SpeakerDetector.detect(
            sources: [("A", []), ("B", [])],
            minSegmentLength: 1.0
        )
        #expect(result.segments.isEmpty)
        #expect(result.totalDuration == 0)
    }

    @Test("Three sources — active speaker tracks through all of them")
    func threeSources() {
        let a = denseWords(from: 0, to: 3)
        let b = denseWords(from: 3, to: 6)
        let c = denseWords(from: 6, to: 9)
        let result = SpeakerDetector.detect(
            sources: [("A", a), ("B", b), ("C", c)],
            minSegmentLength: 1.0
        )
        #expect(result.segments.count == 3)
        #expect(result.segments[0].sourceId == "A")
        #expect(result.segments[1].sourceId == "B")
        #expect(result.segments[2].sourceId == "C")
    }

    @Test("Segments are contiguous — no gaps between them")
    func contiguousSegments() {
        let a = denseWords(from: 0, to: 4)
        let b = denseWords(from: 4, to: 8)
        let result = SpeakerDetector.detect(
            sources: [("A", a), ("B", b)],
            minSegmentLength: 1.0
        )
        for i in 1..<result.segments.count {
            #expect(result.segments[i].start == result.segments[i - 1].end)
        }
    }

    @Test("Silence between utterances keeps the previous speaker active")
    func silenceExtendsPreviousSpeaker() {
        let a = denseWords(from: 0, to: 2)
        let b = denseWords(from: 5, to: 7)
        let result = SpeakerDetector.detect(
            sources: [("A", a), ("B", b)],
            minSegmentLength: 1.0
        )
        #expect(result.segments.count == 2)
        #expect(result.segments[0].sourceId == "A")
        #expect(result.segments[1].sourceId == "B")
        #expect(result.segments[0].end > 2.0)
    }
}
