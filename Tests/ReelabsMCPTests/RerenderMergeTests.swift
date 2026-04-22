import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("RenderSpec merge helpers")
struct RerenderMergeTests {

    private func decode(_ json: String) throws -> RenderSpec {
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RenderSpec.self, from: data)
    }

    @Test("RenderSpec explicit init produces correct values")
    func explicitInit() {
        let spec = RenderSpec(
            sources: [.init(id: "a", path: "/tmp/a.mp4", transcriptId: nil)],
            segments: [SegmentSpec(sourceId: "a", start: 0, end: 5, speed: nil, transform: nil, keyframes: nil, transition: nil, volume: nil, audioFromPrev: nil)],
            captions: CaptionConfig(preset: "tiktok", transcriptId: nil, fontFamily: nil, fontSize: nil, fontWeight: nil, color: nil, highlightColor: nil, position: nil, allCaps: nil, shadow: nil, wordsPerGroup: nil, punctuation: nil),
            audio: nil,
            quality: QualityConfig(codec: .hevc, bitrate: nil, quality: nil),
            overlays: nil,
            aspectRatio: .portrait,
            resolution: nil,
            fps: 30,
            outputPath: "/tmp/out.mp4"
        )

        #expect(spec.sources.count == 1)
        #expect(spec.captions?.preset == "tiktok")
        #expect(spec.quality?.codec == .hevc)
        #expect(spec.fps == 30)
        #expect(spec.aspectRatio == .portrait)
    }

    @Test("withOutputPath returns copy with different path")
    func withOutputPath() throws {
        let json = """
        {
            "sources": [{"id": "m", "path": "/tmp/t.mp4"}],
            "segments": [{"source_id": "m", "start": 0, "end": 5}],
            "output_path": "/tmp/original.mp4"
        }
        """
        let spec = try decode(json)
        let newSpec = spec.withOutputPath("/tmp/modified.mp4")

        #expect(newSpec.outputPath == "/tmp/modified.mp4")
        #expect(newSpec.sources.count == spec.sources.count)
        #expect(newSpec.segments.count == spec.segments.count)
    }

    @Test("RenderSpec round-trips with new overlay types")
    func roundTripNewOverlayTypes() throws {
        let json = """
        {
            "sources": [{"id": "m", "path": "/tmp/t.mp4"}],
            "segments": [{"source_id": "m", "start": 0, "end": 5}],
            "overlays": [
                {
                    "background_color": "#FF000080",
                    "start": 1.0, "end": 3.0,
                    "x": 0.0, "y": 0.5, "width": 1.0, "height": 0.5,
                    "fade_in": 0.5, "fade_out": 0.5
                },
                {
                    "text": {"title": "Hello", "body": "World"},
                    "background_color": "#000000CC",
                    "start": 2.0, "end": 4.0,
                    "x": 0.1, "y": 0.6, "width": 0.8, "height": 0.3
                }
            ],
            "output_path": "/tmp/o.mp4"
        }
        """
        let original = try decode(json)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(RenderSpec.self, from: encoded)

        let overlays = try #require(decoded.overlays)
        #expect(overlays.count == 2)
        #expect(overlays[0].kind == .color)
        #expect(overlays[0].backgroundColor == "#FF000080")
        #expect(overlays[0].fadeIn == 0.5)
        #expect(overlays[1].kind == .text)
        #expect(overlays[1].text?.title == "Hello")
        #expect(overlays[1].text?.body == "World")
    }

    @Test("SegmentSpec memberwise init")
    func segmentSpecInit() {
        let seg = SegmentSpec(sourceId: "a", start: 1.0, end: 5.0, speed: 2.0, transform: nil, keyframes: nil, transition: nil, volume: 0.8, audioFromPrev: nil)
        #expect(seg.sourceId == "a")
        #expect(seg.speed == 2.0)
        #expect(seg.volume == 0.8)
    }
}
