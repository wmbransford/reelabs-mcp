import Foundation

// MARK: - RenderSpec

package struct RenderSpec: Codable, Sendable {
    let sources: [Source]
    let segments: [SegmentSpec]
    let captions: CaptionConfig?
    let audio: AudioConfig?
    let framing: FramingConfig?
    let quality: QualityConfig?
    let overlays: [Overlay]?
    let aspectRatio: AspectRatio?
    let resolution: Resolution?
    let fps: Double?
    let outputPath: String

    package init(
        sources: [Source], segments: [SegmentSpec],
        captions: CaptionConfig?, audio: AudioConfig?,
        framing: FramingConfig? = nil,
        quality: QualityConfig?, overlays: [Overlay]?,
        aspectRatio: AspectRatio?, resolution: Resolution?,
        fps: Double?, outputPath: String
    ) {
        self.sources = sources
        self.segments = segments
        self.captions = captions
        self.audio = audio
        self.framing = framing
        self.quality = quality
        self.overlays = overlays
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.fps = fps
        self.outputPath = outputPath
    }

    /// Return a copy with a different outputPath.
    func withOutputPath(_ path: String) -> RenderSpec {
        RenderSpec(
            sources: sources, segments: segments,
            captions: captions, audio: audio,
            framing: framing,
            quality: quality, overlays: overlays,
            aspectRatio: aspectRatio, resolution: resolution,
            fps: fps, outputPath: path
        )
    }

    /// Return a copy with new segments, captions, and audio — used by preset resolution in RenderTool.
    func withResolvedConfigs(segments: [SegmentSpec], captions: CaptionConfig?, audio: AudioConfig?, overlays: [Overlay]?) -> RenderSpec {
        RenderSpec(
            sources: sources, segments: segments,
            captions: captions, audio: audio,
            framing: framing,
            quality: quality, overlays: overlays,
            aspectRatio: aspectRatio, resolution: resolution,
            fps: fps, outputPath: outputPath
        )
    }

    package struct Source: Codable, Sendable {
        let id: String
        let path: String
        let transcriptId: String?
    }
}

// MARK: - Resolution

/// Accepts either a preset string ("720p", "1080p", "4k") or an explicit {width, height} object.
package enum Resolution: Codable, Sendable {
    case preset(ResolutionPreset)
    case custom(width: Int, height: Int)

    package enum ResolutionPreset: String, Codable, Sendable {
        case _720p = "720p"
        case _1080p = "1080p"
        case _4k = "4k"
    }

    /// The scale factor relative to the base aspect ratio dimensions.
    /// For example, 720p on a 16:9 base (1920x1080) scales by 720/1080 = 0.667.
    func pixelSize(for aspectRatio: CGSize) -> CGSize {
        switch self {
        case .preset(let p):
            // Scale so the shorter dimension matches the preset's defining height
            let targetShort: CGFloat
            switch p {
            case ._720p: targetShort = 720
            case ._1080p: targetShort = 1080
            case ._4k: targetShort = 2160
            }
            let shortSide = min(aspectRatio.width, aspectRatio.height)
            let scale = targetShort / shortSide
            // Round to even numbers (required by video encoders)
            let w = CGFloat(Int(aspectRatio.width * scale / 2) * 2)
            let h = CGFloat(Int(aspectRatio.height * scale / 2) * 2)
            return CGSize(width: w, height: h)
        case .custom(let width, let height):
            return CGSize(width: width, height: height)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try string preset first
        if let str = try? container.decode(String.self),
           let preset = ResolutionPreset(rawValue: str) {
            self = .preset(preset)
            return
        }
        // Try {width, height} object
        let obj = try CustomResolution.init(from: decoder)
        self = .custom(width: obj.width, height: obj.height)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .preset(let p):
            try container.encode(p.rawValue)
        case .custom(let w, let h):
            try container.encode(CustomResolution(width: w, height: h))
        }
    }

    private struct CustomResolution: Codable {
        let width: Int
        let height: Int
    }
}

// MARK: - Segment

package struct SegmentSpec: Codable, Sendable {
    let sourceId: String
    let start: Double
    let end: Double
    let speed: Double?
    let transform: TransformSpec?
    let keyframes: [Keyframe]?
    let transition: Transition?
    let volume: Double?
}

// MARK: - Keyframe

package struct Keyframe: Codable, Sendable {
    let time: Double
    let scale: Double?
    let panX: Double?
    let panY: Double?
}

// MARK: - Transform

package struct TransformSpec: Codable, Sendable {
    let scale: Double?
    let panX: Double?
    let panY: Double?

    var resolvedScale: Double { scale ?? 1.0 }
    var resolvedPanX: Double { panX ?? 0.0 }
    var resolvedPanY: Double { panY ?? 0.0 }
}

// MARK: - Transition

package struct Transition: Codable, Sendable {
    /// If set, resolved in RenderTool from `presets/transitions/{preset}.md`.
    /// After resolution, `type` and `duration` are populated; callers should unwrap with `??` as a safety net.
    let preset: String?
    let type: TransitionType?
    let duration: Double?

    package init(preset: String? = nil, type: TransitionType? = nil, duration: Double? = nil) {
        self.preset = preset
        self.type = type
        self.duration = duration
    }

    package enum TransitionType: String, Codable, Sendable {
        case crossfade
    }
}

// MARK: - Caption Config

package struct CaptionConfig: Codable, Sendable {
    let preset: String?
    let transcriptId: String?
    let fontFamily: String?
    let fontSize: Double?
    let fontWeight: String?
    let color: String?
    let highlightColor: String?
    let position: Double?
    let allCaps: Bool?
    let shadow: Bool?
    let wordsPerGroup: Int?
    let punctuation: Bool?
}

// MARK: - Audio Config

package struct AudioConfig: Codable, Sendable {
    /// If set, resolved in RenderTool from `presets/audio/{preset}.md`.
    let preset: String?
    let musicPath: String?
    let musicVolume: Double?
    let normalizeAudio: Bool?
    let duckingEnabled: Bool?
    let duckingLevel: Double?

    package init(
        preset: String? = nil,
        musicPath: String? = nil,
        musicVolume: Double? = nil,
        normalizeAudio: Bool? = nil,
        duckingEnabled: Bool? = nil,
        duckingLevel: Double? = nil
    ) {
        self.preset = preset
        self.musicPath = musicPath
        self.musicVolume = musicVolume
        self.normalizeAudio = normalizeAudio
        self.duckingEnabled = duckingEnabled
        self.duckingLevel = duckingLevel
    }
}

// MARK: - Framing Config

/// Spec-level framing — applied to every segment that doesn't already have its own `keyframes` or `transform`.
/// Decoded from `presets/framing/{preset}.md` and compiled into segment-level keyframes in RenderTool.
package struct FramingConfig: Codable, Sendable {
    let preset: String?
    let kind: String?            // "keyframes" or "static"
    let startScale: Double?
    let endScale: Double?
    let startPanX: Double?
    let startPanY: Double?
    let endPanX: Double?
    let endPanY: Double?
    let scale: Double?           // static mode
    let panX: Double?
    let panY: Double?
    let alternation: Bool?       // odd/even segments flip start<->end (e.g. engaging)

    package init(
        preset: String? = nil,
        kind: String? = nil,
        startScale: Double? = nil,
        endScale: Double? = nil,
        startPanX: Double? = nil,
        startPanY: Double? = nil,
        endPanX: Double? = nil,
        endPanY: Double? = nil,
        scale: Double? = nil,
        panX: Double? = nil,
        panY: Double? = nil,
        alternation: Bool? = nil
    ) {
        self.preset = preset
        self.kind = kind
        self.startScale = startScale
        self.endScale = endScale
        self.startPanX = startPanX
        self.startPanY = startPanY
        self.endPanX = endPanX
        self.endPanY = endPanY
        self.scale = scale
        self.panX = panX
        self.panY = panY
        self.alternation = alternation
    }
}

// MARK: - Quality Config

package struct QualityConfig: Codable, Sendable {
    let codec: Codec?
    let bitrate: Int?
    let quality: Double?

    package enum Codec: String, Codable, Sendable {
        case h264
        case hevc
    }
}

// MARK: - Overlay

package struct Overlay: Codable, Sendable {
    let sourceId: String?   // required for video overlays, nil for generated (color/text)
    let start: Double       // composition timeline: when overlay appears
    let end: Double         // composition timeline: when overlay disappears
    let x: Double           // 0.0-1.0 fraction of render width (top-left origin)
    let y: Double           // 0.0-1.0 fraction of render height
    let width: Double       // 0.0-1.0 fraction of render width
    let height: Double      // 0.0-1.0 fraction of render height
    let opacity: Double?    // 0.0-1.0, default 1.0
    let sourceStart: Double? // offset into overlay source file, default 0
    let zIndex: Int?        // stacking order, default 0 (higher = on top)
    let audio: Double?      // overlay audio volume 0.0-1.0, default 0 (muted)
    let cornerRadius: Double? // 0.0 (sharp) to 1.0 (circle/pill)
    let crop: CropRect?     // sub-region of source video (0-1 fractions)
    let backgroundColor: String? // hex color (#RRGGBB or #RRGGBBAA) for color/text overlays
    let text: TextOverlayConfig? // text card content and styling
    let imagePath: String?  // absolute path to image file (PNG, JPEG) for image overlays
    let fadeIn: Double?     // seconds for opacity fade-in at start
    let fadeOut: Double?    // seconds for opacity fade-out at end

    /// Overlay kind inferred from field presence.
    package enum Kind {
        case video       // sourceId present
        case image       // imagePath present (static image from disk)
        case color       // backgroundColor present, no sourceId, no text, no imagePath
        case text        // text present (with optional backgroundColor)
    }

    package var kind: Kind {
        if sourceId != nil { return .video }
        if imagePath != nil { return .image }
        if text != nil { return .text }
        return .color
    }
}

// MARK: - Text Overlay Config

package struct TextOverlayConfig: Codable, Sendable {
    let title: String?
    let body: String?
    let titleColor: String?      // hex, default #FFFFFF
    let bodyColor: String?       // hex, default #FFFFFF
    let titleFontSize: Double?   // points, default 48
    let bodyFontSize: Double?    // points, default 32
    let titleFontWeight: String? // default "bold"
    let bodyFontWeight: String?  // default "regular"
    let fontFamily: String?      // default "Arial"
    let alignment: String?       // "left", "center", "right" — default "center"
    let padding: Double?         // 0.0-1.0 fraction of overlay size, default 0.08
}

// MARK: - Crop Rect

package struct CropRect: Codable, Sendable {
    let x: Double       // 0.0-1.0 fraction of source width
    let y: Double       // 0.0-1.0 fraction of source height
    let width: Double   // 0.0-1.0 fraction of source width
    let height: Double  // 0.0-1.0 fraction of source height
}

// MARK: - Aspect Ratio

package enum AspectRatio: String, Codable, Sendable {
    case landscape = "16:9"
    case portrait = "9:16"
    case square = "1:1"
    case post = "4:5"

    /// Width / height ratio (e.g. 16:9 = 1.778, 9:16 = 0.5625).
    var ratio: CGFloat {
        switch self {
        case .landscape: return 16.0 / 9.0
        case .portrait: return 9.0 / 16.0
        case .square: return 1.0
        case .post: return 4.0 / 5.0
        }
    }

    /// Fallback fixed dimensions when no source video is available.
    var fallbackSize: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .post: return CGSize(width: 1080, height: 1350)
        }
    }
}
