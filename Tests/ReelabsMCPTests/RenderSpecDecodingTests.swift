import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("RenderSpec Decoding")
struct RenderSpecDecodingTests {

    private func decode(_ json: String) throws -> RenderSpec {
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RenderSpec.self, from: data)
    }

    @Test("Minimal valid spec decodes")
    func minimalSpec() throws {
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/test.mp4"}],
            "segments": [{"source_id": "main", "start": 0, "end": 5}],
            "output_path": "/tmp/out.mp4"
        }
        """
        let spec = try decode(json)

        #expect(spec.sources.count == 1)
        #expect(spec.sources[0].id == "main")
        #expect(spec.segments.count == 1)
        #expect(spec.segments[0].sourceId == "main")
        #expect(spec.segments[0].start == 0)
        #expect(spec.segments[0].end == 5)
        #expect(spec.outputPath == "/tmp/out.mp4")
        #expect(spec.captions == nil)
        #expect(spec.audio == nil)
        #expect(spec.overlays == nil)
        #expect(spec.aspectRatio == nil)
        #expect(spec.fps == nil)
    }

    @Test("Full spec with all optional fields decodes")
    func fullSpec() throws {
        let json = """
        {
            "sources": [
                {"id": "cam1", "path": "/tmp/cam1.mp4", "transcript_id": "opus-47-video/cam1"}
            ],
            "segments": [
                {
                    "source_id": "cam1",
                    "start": 1.5,
                    "end": 10.0,
                    "speed": 1.5,
                    "volume": 0.8,
                    "transform": {"scale": 1.2, "pan_x": 0.1, "pan_y": -0.05},
                    "transition": {"type": "crossfade", "duration": 0.5}
                }
            ],
            "captions": {
                "preset": "tiktok",
                "font_size": 8.0,
                "color": "#FFFFFF",
                "highlight_color": "#FFD700",
                "position": 70,
                "all_caps": true,
                "shadow": true,
                "words_per_group": 3,
                "punctuation": false
            },
            "audio": {
                "music_path": "/tmp/music.mp3",
                "music_volume": 0.2
            },
            "quality": {
                "codec": "hevc"
            },
            "aspect_ratio": "9:16",
            "fps": 60,
            "output_path": "/tmp/out.mp4"
        }
        """
        let spec = try decode(json)

        #expect(spec.sources[0].transcriptId == "opus-47-video/cam1")
        #expect(spec.segments[0].speed == 1.5)
        #expect(spec.segments[0].volume == 0.8)
        #expect(spec.segments[0].transform?.resolvedScale == 1.2)
        #expect(spec.segments[0].transform?.resolvedPanX == 0.1)
        #expect(spec.segments[0].transition?.type == .crossfade)
        #expect(spec.segments[0].transition?.duration == 0.5)
        #expect(spec.captions?.preset == "tiktok")
        #expect(spec.captions?.highlightColor == "#FFD700")
        #expect(spec.captions?.wordsPerGroup == 3)
        #expect(spec.audio?.musicPath == "/tmp/music.mp3")
        #expect(spec.audio?.musicVolume == 0.2)
        #expect(spec.quality?.codec == .hevc)
        #expect(spec.aspectRatio == .portrait)
        #expect(spec.fps == 60)
    }

    @Test("All aspect ratios decode")
    func aspectRatios() throws {
        let ratios: [(String, AspectRatio)] = [
            ("16:9", .landscape),
            ("9:16", .portrait),
            ("1:1", .square),
            ("4:5", .post),
        ]
        for (raw, expected) in ratios {
            let json = """
            {
                "sources": [{"id": "m", "path": "/tmp/t.mp4"}],
                "segments": [{"source_id": "m", "start": 0, "end": 1}],
                "aspect_ratio": "\(raw)",
                "output_path": "/tmp/o.mp4"
            }
            """
            let spec = try decode(json)
            #expect(spec.aspectRatio == expected)
        }
    }

    @Test("Missing required field throws DecodingError")
    func missingRequiredField() {
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/test.mp4"}],
            "segments": [{"source_id": "main", "start": 0, "end": 5}]
        }
        """
        // missing output_path
        #expect(throws: DecodingError.self) {
            try decode(json)
        }
    }

    @Test("Resolution preset '1080p' decodes")
    func resolutionPreset() throws {
        let json = """
        {
            "sources": [{"id": "m", "path": "/tmp/t.mp4"}],
            "segments": [{"source_id": "m", "start": 0, "end": 1}],
            "resolution": "1080p",
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        if case .preset(let p) = spec.resolution {
            #expect(p == ._1080p)
        } else {
            Issue.record("Expected preset resolution")
        }
    }

    @Test("Resolution custom {width, height} decodes")
    func resolutionCustom() throws {
        let json = """
        {
            "sources": [{"id": "m", "path": "/tmp/t.mp4"}],
            "segments": [{"source_id": "m", "start": 0, "end": 1}],
            "resolution": {"width": 1920, "height": 1080},
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        if case .custom(let w, let h) = spec.resolution {
            #expect(w == 1920)
            #expect(h == 1080)
        } else {
            Issue.record("Expected custom resolution")
        }
    }

    @Test("Overlay with all fields decodes")
    func overlayDecoding() throws {
        let json = """
        {
            "sources": [
                {"id": "main", "path": "/tmp/main.mp4"},
                {"id": "pip", "path": "/tmp/pip.mp4"}
            ],
            "segments": [{"source_id": "main", "start": 0, "end": 10}],
            "overlays": [{
                "source_id": "pip",
                "start": 2.0,
                "end": 8.0,
                "x": 0.05,
                "y": 0.05,
                "width": 0.3,
                "height": 0.3,
                "opacity": 0.9,
                "source_start": 0.0,
                "z_index": 1,
                "audio": 0.5,
                "corner_radius": 0.1,
                "crop": {"x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8}
            }],
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        let overlay = try #require(spec.overlays?.first)

        #expect(overlay.sourceId == "pip")
        #expect(overlay.x == 0.05)
        #expect(overlay.opacity == 0.9)
        #expect(overlay.zIndex == 1)
        #expect(overlay.audio == 0.5)
        #expect(overlay.cornerRadius == 0.1)
        #expect(overlay.crop?.x == 0.1)
        #expect(overlay.crop?.width == 0.8)
        #expect(overlay.kind == .video)
    }

    @Test("Color overlay decodes — no sourceId required")
    func colorOverlayDecoding() throws {
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/main.mp4"}],
            "segments": [{"source_id": "main", "start": 0, "end": 10}],
            "overlays": [{
                "background_color": "#00000080",
                "start": 2.0,
                "end": 8.0,
                "x": 0.0, "y": 0.6, "width": 1.0, "height": 0.4
            }],
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        let overlay = try #require(spec.overlays?.first)

        #expect(overlay.sourceId == nil)
        #expect(overlay.backgroundColor == "#00000080")
        #expect(overlay.kind == .color)
        #expect(overlay.text == nil)
    }

    @Test("Text overlay decodes with all fields")
    func textOverlayDecoding() throws {
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/main.mp4"}],
            "segments": [{"source_id": "main", "start": 0, "end": 10}],
            "overlays": [{
                "text": {
                    "title": "Key Point",
                    "body": "This is the body text",
                    "title_color": "#FFD700",
                    "alignment": "left",
                    "padding": 0.1
                },
                "background_color": "#000000CC",
                "start": 5.0, "end": 12.0,
                "x": 0.05, "y": 0.6, "width": 0.9, "height": 0.3,
                "corner_radius": 0.05,
                "fade_in": 0.3,
                "fade_out": 0.3
            }],
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        let overlay = try #require(spec.overlays?.first)

        #expect(overlay.kind == .text)
        #expect(overlay.text?.title == "Key Point")
        #expect(overlay.text?.body == "This is the body text")
        #expect(overlay.text?.titleColor == "#FFD700")
        #expect(overlay.text?.alignment == "left")
        #expect(overlay.text?.padding == 0.1)
        #expect(overlay.backgroundColor == "#000000CC")
        #expect(overlay.fadeIn == 0.3)
        #expect(overlay.fadeOut == 0.3)
        #expect(overlay.cornerRadius == 0.05)
    }

    @Test("Fade fields default to nil when omitted")
    func fadeFieldsDefaultNil() throws {
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/main.mp4"}],
            "segments": [{"source_id": "main", "start": 0, "end": 10}],
            "overlays": [{
                "source_id": "main",
                "start": 0, "end": 5,
                "x": 0, "y": 0, "width": 1, "height": 1
            }],
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        let overlay = try #require(spec.overlays?.first)

        #expect(overlay.fadeIn == nil)
        #expect(overlay.fadeOut == nil)
        #expect(overlay.backgroundColor == nil)
        #expect(overlay.text == nil)
        #expect(overlay.kind == .video)
    }

    @Test("Kind inference: sourceId always wins as video")
    func kindInferenceSourceIdWins() throws {
        // Even with backgroundColor, sourceId makes it a video overlay
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/main.mp4"}],
            "segments": [{"source_id": "main", "start": 0, "end": 10}],
            "overlays": [{
                "source_id": "main",
                "background_color": "#FF0000",
                "start": 0, "end": 5,
                "x": 0, "y": 0, "width": 1, "height": 1
            }],
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        let overlay = try #require(spec.overlays?.first)
        #expect(overlay.kind == .video)
    }

    @Test("Kind inference: text with backgroundColor is text type")
    func kindInferenceTextWithBg() throws {
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/main.mp4"}],
            "segments": [{"source_id": "main", "start": 0, "end": 10}],
            "overlays": [{
                "text": {"title": "Hello"},
                "background_color": "#000000",
                "start": 0, "end": 5,
                "x": 0, "y": 0, "width": 1, "height": 1
            }],
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        let overlay = try #require(spec.overlays?.first)
        #expect(overlay.kind == .text)
    }

    @Test("Keyframes decode in segment")
    func keyframeDecoding() throws {
        let json = """
        {
            "sources": [{"id": "m", "path": "/tmp/t.mp4"}],
            "segments": [{
                "source_id": "m",
                "start": 0,
                "end": 10,
                "keyframes": [
                    {"time": 0, "scale": 1.0, "pan_x": 0.0, "pan_y": 0.0},
                    {"time": 10, "scale": 1.5, "pan_x": 0.2, "pan_y": -0.1}
                ]
            }],
            "output_path": "/tmp/o.mp4"
        }
        """
        let spec = try decode(json)
        let kfs = try #require(spec.segments[0].keyframes)

        #expect(kfs.count == 2)
        #expect(kfs[0].time == 0)
        #expect(kfs[0].scale == 1.0)
        #expect(kfs[1].time == 10)
        #expect(kfs[1].panX == 0.2)
        #expect(kfs[1].panY == -0.1)
    }

    @Test("Codec h264 and hevc both decode")
    func codecDecoding() throws {
        for codec in ["h264", "hevc"] {
            let json = """
            {
                "sources": [{"id": "m", "path": "/tmp/t.mp4"}],
                "segments": [{"source_id": "m", "start": 0, "end": 1}],
                "quality": {"codec": "\(codec)"},
                "output_path": "/tmp/o.mp4"
            }
            """
            let spec = try decode(json)
            #expect(spec.quality?.codec?.rawValue == codec)
        }
    }

    @Test("RenderSpec round-trips through encode/decode")
    func roundTrip() throws {
        let json = """
        {
            "sources": [{"id": "main", "path": "/tmp/test.mp4"}],
            "segments": [{"source_id": "main", "start": 1.5, "end": 5.5, "speed": 2.0}],
            "aspect_ratio": "9:16",
            "output_path": "/tmp/out.mp4"
        }
        """
        let original = try decode(json)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(RenderSpec.self, from: encoded)

        #expect(decoded.sources[0].id == original.sources[0].id)
        #expect(decoded.segments[0].start == original.segments[0].start)
        #expect(decoded.segments[0].speed == original.segments[0].speed)
        #expect(decoded.aspectRatio == original.aspectRatio)
        #expect(decoded.outputPath == original.outputPath)
    }
}

// MARK: - Resolution.pixelSize

@Suite("Resolution.pixelSize")
struct ResolutionPixelSizeTests {

    @Test("720p on 1920x1080 source scales to 1280x720")
    func preset720pLandscape() {
        let res = Resolution.preset(._720p)
        let size = res.pixelSize(for: CGSize(width: 1920, height: 1080))
        #expect(size.width == 1280)
        #expect(size.height == 720)
    }

    @Test("1080p on 1080x1920 portrait source stays 1080x1920")
    func preset1080pPortrait() {
        let res = Resolution.preset(._1080p)
        let size = res.pixelSize(for: CGSize(width: 1080, height: 1920))
        #expect(size.width == 1080)
        #expect(size.height == 1920)
    }

    @Test("4k on 1920x1080 scales to 3840x2160")
    func preset4kLandscape() {
        let res = Resolution.preset(._4k)
        let size = res.pixelSize(for: CGSize(width: 1920, height: 1080))
        #expect(size.width == 3840)
        #expect(size.height == 2160)
    }

    @Test("Custom resolution returns exact dimensions")
    func customResolution() {
        let res = Resolution.custom(width: 800, height: 600)
        let size = res.pixelSize(for: CGSize(width: 1920, height: 1080))
        #expect(size.width == 800)
        #expect(size.height == 600)
    }

    @Test("Pixel sizes are always even numbers")
    func evenPixelDimensions() {
        // 720p on an odd-ratio source could produce odd pixels without rounding
        let res = Resolution.preset(._720p)
        let size = res.pixelSize(for: CGSize(width: 1000, height: 1000))
        #expect(Int(size.width) % 2 == 0)
        #expect(Int(size.height) % 2 == 0)
    }
}
