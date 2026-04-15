import Foundation
import GRDB

package struct Project: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    package var id: Int64?
    var name: String
    var description: String?
    var status: String
    var createdAt: String
    var updatedAt: String

    package static let databaseTableName = "projects"

    init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
        self.status = "active"
        let now = Self.timestamp()
        self.createdAt = now
        self.updatedAt = now
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    package static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
