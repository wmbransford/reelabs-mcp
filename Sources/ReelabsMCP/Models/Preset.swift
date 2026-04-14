import Foundation
import GRDB

struct Preset: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var name: String
    var type: String
    var configJson: String
    var description: String?
    var createdAt: String
    var updatedAt: String

    static let databaseTableName = "presets"

    init(name: String, type: String, configJson: String, description: String? = nil) {
        self.name = name
        self.type = type
        self.configJson = configJson
        self.description = description
        let now = Project.timestamp()
        self.createdAt = now
        self.updatedAt = now
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
