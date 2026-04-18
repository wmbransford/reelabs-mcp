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

package struct FocusPoint: Codable, Equatable, Sendable {
    package let x: Double
    package let y: Double

    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

package struct BoundingBox: Codable, Equatable, Sendable {
    package let x: Double
    package let y: Double
    package let w: Double
    package let h: Double

    package init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

package struct Subject: Codable, Sendable {
    package let id: Int
    package let name: String?
    package let clusterId: Int?
    package let bbox: BoundingBox?
    package let center: FocusPoint?

    package init(
        id: Int,
        name: String? = nil,
        clusterId: Int? = nil,
        bbox: BoundingBox? = nil,
        center: FocusPoint? = nil
    ) {
        self.id = id
        self.name = name
        self.clusterId = clusterId
        self.bbox = bbox
        self.center = center
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bbox, center
        case clusterId = "cluster_id"
    }
}

package struct SceneRecord: Codable, Sendable {
    package var sceneIndex: Int
    package var startTime: Double
    package var endTime: Double
    package var description: String
    package var tags: [String]?
    package var sceneType: String?
    package var focusPoint: FocusPoint?
    package var subjects: [Subject]?

    package init(
        sceneIndex: Int,
        startTime: Double,
        endTime: Double,
        description: String,
        tags: [String]? = nil,
        sceneType: String? = nil,
        focusPoint: FocusPoint? = nil,
        subjects: [Subject]? = nil
    ) {
        self.sceneIndex = sceneIndex
        self.startTime = startTime
        self.endTime = endTime
        self.description = description
        self.tags = tags
        self.sceneType = sceneType
        self.focusPoint = focusPoint
        self.subjects = subjects
    }

    enum CodingKeys: String, CodingKey {
        case sceneIndex = "scene_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case description, tags
        case sceneType = "scene_type"
        case focusPoint = "focus_point"
        case subjects
    }
}

// MARK: - Face detection sidecar (faces.json)

package struct FaceDetection: Codable, Sendable {
    package let bbox: BoundingBox
    package let center: FocusPoint
    package let confidence: Double

    package init(bbox: BoundingBox, center: FocusPoint, confidence: Double) {
        self.bbox = bbox
        self.center = center
        self.confidence = confidence
    }
}

package struct FrameFaceDetection: Codable, Sendable {
    package let time: Double
    package let faces: [FaceDetection]

    package init(time: Double, faces: [FaceDetection]) {
        self.time = time
        self.faces = faces
    }
}

package struct FaceCluster: Codable, Sendable {
    package let id: Int
    package let medianCenter: FocusPoint
    package let medianBbox: BoundingBox
    package let visibility: Double
    package let frameCount: Int

    package init(id: Int, medianCenter: FocusPoint, medianBbox: BoundingBox, visibility: Double, frameCount: Int) {
        self.id = id
        self.medianCenter = medianCenter
        self.medianBbox = medianBbox
        self.visibility = visibility
        self.frameCount = frameCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case medianCenter = "median_center"
        case medianBbox = "median_bbox"
        case visibility
        case frameCount = "frame_count"
    }
}

package struct FaceDetectionResult: Codable, Sendable {
    package let source: String
    package let sampleFps: Double
    package let durationSeconds: Double
    package let frameCount: Int
    package let frames: [FrameFaceDetection]
    package let clusters: [FaceCluster]

    package init(source: String, sampleFps: Double, durationSeconds: Double, frameCount: Int, frames: [FrameFaceDetection], clusters: [FaceCluster]) {
        self.source = source
        self.sampleFps = sampleFps
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.frames = frames
        self.clusters = clusters
    }

    enum CodingKeys: String, CodingKey {
        case source
        case sampleFps = "sample_fps"
        case durationSeconds = "duration_seconds"
        case frameCount = "frame_count"
        case frames, clusters
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
