import Foundation
import GRDB

package struct Transcript: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    package var id: Int64?
    var assetId: Int64?
    var sourcePath: String
    var fullText: String
    var compactJson: String
    var durationSeconds: Double?
    var wordCount: Int?
    var createdAt: String

    package static let databaseTableName = "transcripts"

    init(sourcePath: String, fullText: String, compactJson: String = "[]", durationSeconds: Double? = nil, wordCount: Int? = nil, assetId: Int64? = nil) {
        self.sourcePath = sourcePath
        self.fullText = fullText
        self.compactJson = compactJson
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.assetId = assetId
        self.createdAt = Project.timestamp()
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Word record (stored in transcript_words table)

package struct TranscriptWordRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var transcriptId: Int64
    var wordIndex: Int
    var word: String
    var startTime: Double
    var endTime: Double
    var confidence: Double?

    package static let databaseTableName = "transcript_words"

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - In-memory structures (used by rendering pipeline and agent responses)

package struct TranscriptData: Codable, Sendable {
    let words: [TranscriptWord]
    let fullText: String
    let durationSeconds: Double
}

package struct TranscriptWord: Codable, Sendable {
    let word: String
    let startTime: Double
    let endTime: Double
    let confidence: Double?
}
