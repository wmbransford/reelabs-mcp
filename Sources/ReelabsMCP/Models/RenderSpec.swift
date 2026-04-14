import Foundation

// MARK: - RenderSpec

struct RenderSpec: Codable, Sendable {
    let sources: [Source]
    let segments: [SegmentSpec]
    let captions: CaptionConfig?
    let audio: AudioConfig?
    let quality: QualityConfig?
    let overlays: [Overlay]?
    let aspectRatio: AspectRatio?
    let resolution: Resolution?
    let fps: Double?
    let outputPath: String

    struct Source: Codable, Sendable {
        let id: String
        let path: String
        let transcriptId: Int?
    }
}

// MARK: - Resolution

/// Accepts either a preset string ("720p", "1080p", "4k") or an explicit {width, height} object.
enum Resolution: Codable, Sendable {
    case preset(ResolutionPreset)
    case custom(width: Int, height: Int)

    enum ResolutionPreset: String, Codable, Sendable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct SegmentSpec: Codable, Sendable {
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

struct Keyframe: Codable, Sendable {
    let time: Double
    let scale: Double?
    let panX: Double?
    let panY: Double?
}

// MARK: - Transform

struct TransformSpec: Codable, Sendable {
    let scale: Double?
    let panX: Double?
    let panY: Double?

    var resolvedScale: Double { scale ?? 1.0 }
    var resolvedPanX: Double { panX ?? 0.0 }
    var resolvedPanY: Double { panY ?? 0.0 }
}

// MARK: - Transition

struct Transition: Codable, Sendable {
    let type: TransitionType
    let duration: Double

    enum TransitionType: String, Codable, Sendable {
        case crossfade
    }
}

// MARK: - Caption Config

struct CaptionConfig: Codable, Sendable {
    let preset: String?
    let transcriptId: Int?
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

struct AudioConfig: Codable, Sendable {
    let musicPath: String?
    let musicVolume: Double?
    let normalizeAudio: Bool?
    let duckingEnabled: Bool?
    let duckingLevel: Double?
}

// MARK: - Quality Config

struct QualityConfig: Codable, Sendable {
    let codec: Codec?
    let bitrate: Int?
    let quality: Double?

    enum Codec: String, Codable, Sendable {
        case h264
        case hevc
    }
}

// MARK: - Overlay

struct Overlay: Codable, Sendable {
    let sourceId: String
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
}

// MARK: - Aspect Ratio

enum AspectRatio: String, Codable, Sendable {
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
