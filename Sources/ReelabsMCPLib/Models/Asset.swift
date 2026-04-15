import Foundation
import GRDB

package struct Asset: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    package var id: Int64?
    var projectId: Int64
    var filePath: String
    var filename: String
    var durationMs: Int?
    var width: Int?
    var height: Int?
    var fps: Double?
    var codec: String?
    var hasAudio: Bool
    var fileSizeBytes: Int64?
    var tags: String?
    var createdAt: String

    package static let databaseTableName = "assets"

    init(projectId: Int64, filePath: String, filename: String) {
        self.projectId = projectId
        self.filePath = filePath
        self.filename = filename
        self.hasAudio = true
        self.createdAt = Project.timestamp()
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
