import Foundation

// MARK: - ISO8601 timestamp helper

package enum Timestamp {
    package static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - Project

package struct ProjectRecord: Codable, Sendable {
    package var schemaVersion: Int
    package var slug: String
    package var name: String
    package var status: String
    package var created: String
    package var updated: String
    package var description: String?
    package var tags: [String]?

    package init(
        slug: String,
        name: String,
        status: String = "active",
        created: String = Timestamp.now(),
        updated: String? = nil,
        description: String? = nil,
        tags: [String]? = nil
    ) {
        self.schemaVersion = 1
        self.slug = slug
        self.name = name
        self.status = status
        self.created = created
        self.updated = updated ?? created
        self.description = description
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case slug, name, status, created, updated, description, tags
    }
}

// MARK: - Asset

package struct AssetRecord: Codable, Sendable {
    package var schemaVersion: Int
    package var slug: String
    package var filename: String
    package var filePath: String
    package var fileSizeBytes: Int64?
    package var durationSeconds: Double?
    package var width: Int?
    package var height: Int?
    package var fps: Double?
    package var codec: String?
    package var hasAudio: Bool
    package var tags: [String]?
    package var created: String

    package init(
        slug: String,
        filename: String,
        filePath: String,
        fileSizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        codec: String? = nil,
        hasAudio: Bool = true,
        tags: [String]? = nil,
        created: String = Timestamp.now()
    ) {
        self.schemaVersion = 1
        self.slug = slug
        self.filename = filename
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.hasAudio = hasAudio
        self.tags = tags
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case slug, filename
        case filePath = "file_path"
        case fileSizeBytes = "file_size_bytes"
        case durationSeconds = "duration_seconds"
        case width, height, fps, codec
        case hasAudio = "has_audio"
        case tags, created
    }
}

// MARK: - Transcript

package struct TranscriptRecord: Codable, Sendable {
    package var schemaVersion: Int
    package var slug: String
    package var sourcePath: String
    package var durationSeconds: Double
    package var wordCount: Int
    package var language: String
    package var mode: String
    package var created: String

    package init(
        slug: String,
        sourcePath: String,
        durationSeconds: Double,
        wordCount: Int,
        language: String = "en-US",
        mode: String = "sync",
        created: String = Timestamp.now()
    ) {
        self.schemaVersion = 1
        self.slug = slug
        self.sourcePath = sourcePath
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.language = language
        self.mode = mode
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case slug
        case sourcePath = "source_path"
        case durationSeconds = "duration_seconds"
        case wordCount = "word_count"
        case language, mode, created
    }
}

// MARK: - Render

package struct RenderRecord: Codable, Sendable {
    package var schemaVersion: Int
    package var slug: String
    package var status: String
    package var created: String
    package var durationSeconds: Double?
    package var outputPath: String
    package var fileSizeBytes: Int64?
    package var sources: [String]? // source slugs referenced by this render

    package init(
        slug: String,
        status: String = "completed",
        created: String = Timestamp.now(),
        durationSeconds: Double? = nil,
        outputPath: String,
        fileSizeBytes: Int64? = nil,
        sources: [String]? = nil
    ) {
        self.schemaVersion = 1
        self.slug = slug
        self.status = status
        self.created = created
        self.durationSeconds = durationSeconds
        self.outputPath = outputPath
        self.fileSizeBytes = fileSizeBytes
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case slug, status, created
        case durationSeconds = "duration_seconds"
        case outputPath = "output_path"
        case fileSizeBytes = "file_size_bytes"
        case sources
    }
}

// MARK: - Preset

package struct PresetRecord: Codable, Sendable {
    package var schemaVersion: Int
    package var name: String
    package var type: String
    package var description: String?
    package var created: String
    package var updated: String
    /// The preset's configuration as arbitrary key-value pairs, flattened into the front matter.
    /// Stored as a JSON-serialized string for simple round-tripping; not part of the Codable
    /// front matter struct (kept separate to keep the schema flexible).
    package var configJson: String

    package init(
        name: String,
        type: String,
        configJson: String,
        description: String? = nil,
        created: String = Timestamp.now(),
        updated: String? = nil
    ) {
        self.schemaVersion = 1
        self.name = name
        self.type = type
        self.configJson = configJson
        self.description = description
        self.created = created
        self.updated = updated ?? created
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name, type, description, created, updated
        case configJson = "config_json"
    }
}

// MARK: - Visual Analysis

package struct AnalysisRecord: Codable, Sendable {
    package var schemaVersion: Int
    package var slug: String
    package var sourcePath: String
    package var status: String
    package var sampleFps: Double
    package var frameCount: Int
    package var sceneCount: Int
    package var durationSeconds: Double
    package var framesDir: String
    package var created: String

    package init(
        slug: String,
        sourcePath: String,
        status: String = "extracted",
        sampleFps: Double,
        frameCount: Int = 0,
        sceneCount: Int = 0,
        durationSeconds: Double = 0,
        framesDir: String = "",
        created: String = Timestamp.now()
    ) {
        self.schemaVersion = 1
        self.slug = slug
        self.sourcePath = sourcePath
        self.status = status
        self.sampleFps = sampleFps
        self.frameCount = frameCount
        self.sceneCount = sceneCount
        self.durationSeconds = durationSeconds
        self.framesDir = framesDir
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case slug
        case sourcePath = "source_path"
        case status
        case sampleFps = "sample_fps"
        case frameCount = "frame_count"
        case sceneCount = "scene_count"
        case durationSeconds = "duration_seconds"
        case framesDir = "frames_dir"
        case created
    }
}

package struct SceneRecord: Codable, Sendable {
    package var sceneIndex: Int
    package var startTime: Double
    package var endTime: Double
    package var description: String
    package var tags: [String]?
    package var sceneType: String?

    package init(
        sceneIndex: Int,
        startTime: Double,
        endTime: Double,
        description: String,
        tags: [String]? = nil,
        sceneType: String? = nil
    ) {
        self.sceneIndex = sceneIndex
        self.startTime = startTime
        self.endTime = endTime
        self.description = description
        self.tags = tags
        self.sceneType = sceneType
    }

    enum CodingKeys: String, CodingKey {
        case sceneIndex = "scene_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case description, tags
        case sceneType = "scene_type"
    }
}

// MARK: - Transcript word (sidecar JSON)

package struct WordEntry: Codable, Sendable {
    package let word: String
    package let start: Double
    package let end: Double
    package let confidence: Double?

    package init(word: String, start: Double, end: Double, confidence: Double?) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

// MARK: - In-memory transcript shapes (used by rendering pipeline)

package struct TranscriptData: Codable, Sendable {
    package let words: [TranscriptWord]
    package let fullText: String
    package let durationSeconds: Double

    package init(words: [TranscriptWord], fullText: String, durationSeconds: Double) {
        self.words = words
        self.fullText = fullText
        self.durationSeconds = durationSeconds
    }
}

package struct TranscriptWord: Codable, Sendable {
    package let word: String
    package let startTime: Double
    package let endTime: Double
    package let confidence: Double?

    package init(word: String, startTime: Double, endTime: Double, confidence: Double?) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

// MARK: - LibraryAsset (video spine universal source registry)

package enum LibraryAssetKind: String, Codable, Sendable, CaseIterable {
    case capturedVideo = "captured_video"
    case capturedAudio = "captured_audio"
    case ttsAudio = "tts_audio"
    case aiVideo = "ai_video"
    case aiImage = "ai_image"
    case graphicSpec = "graphic_spec"
    case stockVideo = "stock_video"
    case stockImage = "stock_image"
    case music
    case screenRecording = "screen_recording"

    /// Kinds accepted by the Plan 1 ingest tool. Other kinds require their
    /// own generation/fetch primitives (Breadth phase) before ingest is meaningful.
    package var supportedInPlanOne: Bool {
        switch self {
        case .capturedVideo, .capturedAudio: return true
        default: return false
        }
    }
}

package struct LibraryAssetRecord: Codable, Sendable {
    package var id: Int64
    package var kind: LibraryAssetKind
    package var path: String?
    package var externalRef: String?
    package var contentHash: String?
    package var durationS: Double?
    package var width: Int?
    package var height: Int?
    package var fps: Double?
    package var codec: String?
    package var hasAudio: Bool?
    package var provenance: [String: String]?
    package var sourceMetadata: [String: String]?
    package var createdAt: String
    package var ingestedAt: String

    package init(
        id: Int64,
        kind: LibraryAssetKind,
        path: String? = nil,
        externalRef: String? = nil,
        contentHash: String? = nil,
        durationS: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        codec: String? = nil,
        hasAudio: Bool? = nil,
        provenance: [String: String]? = nil,
        sourceMetadata: [String: String]? = nil,
        createdAt: String,
        ingestedAt: String
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.externalRef = externalRef
        self.contentHash = contentHash
        self.durationS = durationS
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.hasAudio = hasAudio
        self.provenance = provenance
        self.sourceMetadata = sourceMetadata
        self.createdAt = createdAt
        self.ingestedAt = ingestedAt
    }
}
