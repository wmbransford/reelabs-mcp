import Testing
@testable import ReelabsMCPLib

// MARK: - Single-source remapTranscript

@Suite("remapTranscript")
struct RemapTranscriptTests {

    // Helper to build words quickly
    private func word(_ text: String, start: Double, end: Double) -> TranscriptWord {
        TranscriptWord(word: text, startTime: start, endTime: end, confidence: 1.0)
    }

    private func segment(_ sourceId: String = "main", start: Double, end: Double, speed: Double? = nil) -> SegmentSpec {
        SegmentSpec(sourceId: sourceId, start: start, end: end, speed: speed, transform: nil, keyframes: nil, transition: nil, volume: nil)
    }

    @Test("Single segment — words pass through with zero offset")
    func singleSegmentPassthrough() {
        let words = [
            word("Hello", start: 0.0, end: 0.5),
            word("world", start: 0.5, end: 1.0),
        ]
        let data = TranscriptData(words: words, fullText: "Hello world", durationSeconds: 1.0)
        let segments = [segment(start: 0.0, end: 1.0)]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 2)
        #expect(result.words[0].word == "Hello")
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[1].startTime == 0.5)
    }

    @Test("Single segment with offset — words shift to zero")
    func singleSegmentWithOffset() {
        let words = [
            word("Hello", start: 5.0, end: 5.5),
            word("world", start: 5.5, end: 6.0),
        ]
        let data = TranscriptData(words: words, fullText: "Hello world", durationSeconds: 10.0)
        let segments = [segment(start: 5.0, end: 6.0)]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 2)
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[0].endTime == 0.5)
        #expect(result.words[1].startTime == 0.5)
        #expect(result.words[1].endTime == 1.0)
    }

    @Test("Two segments — second segment words offset by first segment duration")
    func twoSegmentsOffset() {
        let words = [
            word("first", start: 0.0, end: 0.5),
            word("second", start: 3.0, end: 3.5),
        ]
        let data = TranscriptData(words: words, fullText: "first second", durationSeconds: 4.0)
        let segments = [
            segment(start: 0.0, end: 1.0),
            segment(start: 3.0, end: 4.0),
        ]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 2)
        #expect(result.words[0].word == "first")
        #expect(result.words[0].startTime == 0.0)
        // Second word: compositionTime = 1.0 (first seg duration) + (3.0 - 3.0) = 1.0
        #expect(result.words[1].word == "second")
        #expect(result.words[1].startTime == 1.0)
    }

    @Test("Words outside all segments are dropped")
    func wordsOutsideSegmentsDropped() {
        let words = [
            word("keep", start: 0.0, end: 0.5),
            word("drop", start: 1.5, end: 2.0),  // gap between segments
            word("keep2", start: 3.0, end: 3.5),
        ]
        let data = TranscriptData(words: words, fullText: "keep drop keep2", durationSeconds: 4.0)
        let segments = [
            segment(start: 0.0, end: 1.0),
            segment(start: 3.0, end: 4.0),
        ]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 2)
        #expect(result.words[0].word == "keep")
        #expect(result.words[1].word == "keep2")
    }

    @Test("Speed 2x halves word timestamps in composition time")
    func speedDouble() {
        let words = [
            word("fast", start: 0.0, end: 1.0),
            word("talk", start: 1.0, end: 2.0),
        ]
        let data = TranscriptData(words: words, fullText: "fast talk", durationSeconds: 2.0)
        let segments = [segment(start: 0.0, end: 2.0, speed: 2.0)]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 2)
        // At 2x speed: newStart = 0 + (0.0 - 0.0) / 2.0 = 0.0
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[0].endTime == 0.5)
        // newStart = 0 + (1.0 - 0.0) / 2.0 = 0.5
        #expect(result.words[1].startTime == 0.5)
        #expect(result.words[1].endTime == 1.0)
    }

    @Test("Speed 0.5x doubles word timestamps in composition time")
    func speedHalf() {
        let words = [
            word("slow", start: 0.0, end: 0.5),
        ]
        let data = TranscriptData(words: words, fullText: "slow", durationSeconds: 1.0)
        let segments = [segment(start: 0.0, end: 1.0, speed: 0.5)]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 1)
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[0].endTime == 1.0)  // 0.5 / 0.5 = 1.0
        #expect(result.durationSeconds == 2.0)     // 1.0 / 0.5 = 2.0
    }

    @Test("Word endTime clamped to segment boundary")
    func wordEndClampedToSegmentEnd() {
        let words = [
            word("spans", start: 0.8, end: 1.5),  // endTime exceeds segment end of 1.0
        ]
        let data = TranscriptData(words: words, fullText: "spans", durationSeconds: 2.0)
        let segments = [segment(start: 0.0, end: 1.0)]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 1)
        #expect(result.words[0].startTime == 0.8)
        #expect(result.words[0].endTime == 1.0)  // clamped from 1.5 to 1.0
    }

    @Test("Empty words array produces empty result")
    func emptyWords() {
        let data = TranscriptData(words: [], fullText: "", durationSeconds: 1.0)
        let segments = [segment(start: 0.0, end: 1.0)]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.isEmpty)
    }

    @Test("Three segments with gap — composition time is contiguous")
    func threeSegmentsContiguous() {
        let words = [
            word("a", start: 0.0, end: 0.5),
            word("b", start: 5.0, end: 5.5),
            word("c", start: 10.0, end: 10.5),
        ]
        let data = TranscriptData(words: words, fullText: "a b c", durationSeconds: 11.0)
        let segments = [
            segment(start: 0.0, end: 1.0),   // comp 0-1
            segment(start: 5.0, end: 6.0),   // comp 1-2
            segment(start: 10.0, end: 11.0), // comp 2-3
        ]

        let result = remapTranscript(data, segments: segments)

        #expect(result.words.count == 3)
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[1].startTime == 1.0)
        #expect(result.words[2].startTime == 2.0)
        #expect(result.durationSeconds == 3.0)
    }
}

// MARK: - Multi-source remapMultiSourceTranscript

@Suite("remapMultiSourceTranscript")
struct RemapMultiSourceTests {

    private func word(_ text: String, start: Double, end: Double) -> TranscriptWord {
        TranscriptWord(word: text, startTime: start, endTime: end, confidence: 1.0)
    }

    private func segment(_ sourceId: String, start: Double, end: Double, speed: Double? = nil) -> SegmentSpec {
        SegmentSpec(sourceId: sourceId, start: start, end: end, speed: speed, transform: nil, keyframes: nil, transition: nil, volume: nil)
    }

    @Test("Two sources interleaved — words mapped to correct composition times")
    func twoSourcesInterleaved() {
        let sourceA = [
            word("cam1", start: 0.0, end: 0.5),
        ]
        let sourceB = [
            word("cam2", start: 0.0, end: 0.5),
        ]
        let transcripts = ["a": sourceA, "b": sourceB]
        let segments = [
            segment("a", start: 0.0, end: 1.0),
            segment("b", start: 0.0, end: 1.0),
        ]

        let result = remapMultiSourceTranscript(sourceTranscripts: transcripts, segments: segments)

        #expect(result.words.count == 2)
        #expect(result.words[0].word == "cam1")
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[1].word == "cam2")
        #expect(result.words[1].startTime == 1.0)  // after first segment
    }

    @Test("Segment references source with no transcript — skipped gracefully")
    func missingSourceTranscript() {
        let transcripts: [String: [TranscriptWord]] = ["a": [word("hello", start: 0.0, end: 0.5)]]
        let segments = [
            segment("a", start: 0.0, end: 1.0),
            segment("b", start: 0.0, end: 1.0),  // no transcript for "b"
        ]

        let result = remapMultiSourceTranscript(sourceTranscripts: transcripts, segments: segments)

        #expect(result.words.count == 1)
        #expect(result.words[0].word == "hello")
        // Duration should still include both segments
        #expect(result.durationSeconds == 2.0)
    }

    @Test("Same source used in two segments — words appear at both composition times")
    func sameSourceTwice() {
        let sourceA = [
            word("hello", start: 0.0, end: 0.5),
            word("world", start: 2.0, end: 2.5),
        ]
        let transcripts = ["a": sourceA]
        let segments = [
            segment("a", start: 0.0, end: 1.0),   // picks up "hello"
            segment("a", start: 2.0, end: 3.0),   // picks up "world"
        ]

        let result = remapMultiSourceTranscript(sourceTranscripts: transcripts, segments: segments)

        #expect(result.words.count == 2)
        #expect(result.words[0].word == "hello")
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[1].word == "world")
        #expect(result.words[1].startTime == 1.0)
    }

    @Test("Speed applied per segment in multi-source")
    func speedPerSegment() {
        let sourceA = [word("fast", start: 0.0, end: 1.0)]
        let transcripts = ["a": sourceA]
        let segments = [segment("a", start: 0.0, end: 2.0, speed: 2.0)]

        let result = remapMultiSourceTranscript(sourceTranscripts: transcripts, segments: segments)

        #expect(result.words.count == 1)
        #expect(result.words[0].startTime == 0.0)
        #expect(result.words[0].endTime == 0.5)  // 1.0 / 2.0
        #expect(result.durationSeconds == 1.0)     // 2.0 / 2.0
    }
}
