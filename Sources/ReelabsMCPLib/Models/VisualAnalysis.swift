import Foundation
import GRDB

package struct VisualAnalysis: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    package var id: Int64?
    var assetId: Int64?
    var sourcePath: String
    var status: String
    var sampleFps: Double
    var frameCount: Int
    var sceneCount: Int
    var durationSeconds: Double
    var framesDir: String
    var createdAt: String

    package static let databaseTableName = "visual_analyses"

    init(sourcePath: String, sampleFps: Double, assetId: Int64? = nil) {
        self.sourcePath = sourcePath
        self.sampleFps = sampleFps
        self.assetId = assetId
        self.status = "extracted"
        self.frameCount = 0
        self.sceneCount = 0
        self.durationSeconds = 0
        self.framesDir = ""
        self.createdAt = Project.timestamp()
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

package struct VisualScene: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    package var id: Int64?
    var analysisId: Int64
    var sceneIndex: Int
    var startTime: Double
    var endTime: Double
    var description: String
    var tags: String?
    var sceneType: String?
    var createdAt: String

    package static let databaseTableName = "visual_scenes"

    init(analysisId: Int64, sceneIndex: Int, startTime: Double, endTime: Double, description: String, tags: String? = nil, sceneType: String? = nil) {
        self.analysisId = analysisId
        self.sceneIndex = sceneIndex
        self.startTime = startTime
        self.endTime = endTime
        self.description = description
        self.tags = tags
        self.sceneType = sceneType
        self.createdAt = Project.timestamp()
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
