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

// MARK: - Overlay source remapping

@Suite("remapOverlaySources")
struct RemapOverlaySourcesTests {

    private func word(_ text: String, start: Double, end: Double) -> TranscriptWord {
        TranscriptWord(word: text, startTime: start, endTime: end, confidence: 1.0)
    }

    private func overlay(sourceId: String, start: Double, end: Double, sourceStart: Double? = nil) -> Overlay {
        Overlay(
            sourceId: sourceId, start: start, end: end,
            x: 0, y: 0, width: 0.25, height: 0.25,
            opacity: 1, sourceStart: sourceStart, zIndex: 2, audio: 0,
            cornerRadius: nil, crop: nil, backgroundColor: nil,
            text: nil, imagePath: nil, fadeIn: nil, fadeOut: nil
        )
    }

    @Test("Overlay source words remapped to composition time")
    func basicOverlayRemap() {
        let camWords = [
            word("hello", start: 5.0, end: 5.5),
            word("world", start: 5.5, end: 6.0),
        ]
        let transcripts = ["cam": camWords]
        let overlays = [overlay(sourceId: "cam", start: 0.0, end: 10.0, sourceStart: 0.0)]

        let result = remapOverlaySources(
            sourceTranscripts: transcripts,
            overlays: overlays,
            excludeSourceIds: ["screen"]
        )

        #expect(result.count == 2)
        #expect(result[0].word == "hello")
        #expect(result[0].startTime == 5.0)
        #expect(result[1].word == "world")
        #expect(result[1].startTime == 5.5)
    }

    @Test("sourceStart offsets words into composition time correctly")
    func sourceStartOffset() {
        // Cam has speech at second 20. Overlay plays cam[16:24] during comp[16:24].
        let camWords = [
            word("late", start: 20.0, end: 20.5),
        ]
        let transcripts = ["cam": camWords]
        let overlays = [overlay(sourceId: "cam", start: 16.0, end: 24.0, sourceStart: 16.0)]

        let result = remapOverlaySources(
            sourceTranscripts: transcripts,
            overlays: overlays,
            excludeSourceIds: ["screen"]
        )

        #expect(result.count == 1)
        #expect(result[0].word == "late")
        // newStart = overlay.start + (20.0 - 16.0) = 16.0 + 4.0 = 20.0
        #expect(result[0].startTime == 20.0)
        #expect(result[0].endTime == 20.5)
    }

    @Test("Multiple overlay sections produce continuous word timeline")
    func multipleOverlaySections() {
        let camWords = [
            word("a", start: 2.0, end: 2.5),
            word("b", start: 10.0, end: 10.5),
            word("c", start: 20.0, end: 20.5),
        ]
        let transcripts = ["cam": camWords]
        let overlays = [
            overlay(sourceId: "cam", start: 0.0, end: 8.0, sourceStart: 0.0),
            overlay(sourceId: "cam", start: 8.0, end: 16.0, sourceStart: 8.0),
            overlay(sourceId: "cam", start: 16.0, end: 24.0, sourceStart: 16.0),
        ]

        let result = remapOverlaySources(
            sourceTranscripts: transcripts,
            overlays: overlays,
            excludeSourceIds: ["screen"]
        )

        #expect(result.count == 3)
        #expect(result[0].word == "a")
        #expect(result[0].startTime == 2.0)   // overlay[0]: 0 + (2 - 0) = 2
        #expect(result[1].word == "b")
        #expect(result[1].startTime == 10.0)  // overlay[1]: 8 + (10 - 8) = 10
        #expect(result[2].word == "c")
        #expect(result[2].startTime == 20.0)  // overlay[2]: 16 + (20 - 16) = 20
    }

    @Test("Words outside overlay source window are dropped")
    func wordsOutsideWindow() {
        let camWords = [
            word("before", start: 1.0, end: 1.5),  // before sourceStart
            word("inside", start: 5.0, end: 5.5),
            word("after", start: 12.0, end: 12.5),  // after source window
        ]
        let transcripts = ["cam": camWords]
        let overlays = [overlay(sourceId: "cam", start: 0.0, end: 8.0, sourceStart: 3.0)]
        // source window: [3.0, 11.0)

        let result = remapOverlaySources(
            sourceTranscripts: transcripts,
            overlays: overlays,
            excludeSourceIds: []
        )

        #expect(result.count == 1)
        #expect(result[0].word == "inside")
        // newStart = 0.0 + (5.0 - 3.0) = 2.0
        #expect(result[0].startTime == 2.0)
    }

    @Test("Sources already in segments are excluded")
    func excludeSegmentSources() {
        let screenWords = [word("screen", start: 0.0, end: 0.5)]
        let camWords = [word("cam", start: 0.0, end: 0.5)]
        let transcripts = ["screen": screenWords, "cam": camWords]
        let overlays = [
            overlay(sourceId: "screen", start: 0.0, end: 10.0),
            overlay(sourceId: "cam", start: 0.0, end: 10.0),
        ]

        let result = remapOverlaySources(
            sourceTranscripts: transcripts,
            overlays: overlays,
            excludeSourceIds: ["screen"]  // screen is in segments
        )

        #expect(result.count == 1)
        #expect(result[0].word == "cam")
    }

    @Test("Word endTime clamped to overlay source window")
    func endTimeClamped() {
        let camWords = [
            word("spans", start: 7.0, end: 9.0),  // endTime exceeds source window
        ]
        let transcripts = ["cam": camWords]
        let overlays = [overlay(sourceId: "cam", start: 0.0, end: 8.0, sourceStart: 0.0)]
        // source window: [0, 8), so endTime 9.0 should clamp to 8.0

        let result = remapOverlaySources(
            sourceTranscripts: transcripts,
            overlays: overlays,
            excludeSourceIds: []
        )

        #expect(result.count == 1)
        #expect(result[0].startTime == 7.0)
        #expect(result[0].endTime == 8.0)  // clamped from 9.0
    }
}
