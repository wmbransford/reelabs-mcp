import Foundation
import GRDB

/// SQLite-backed project storage. One row per project in the `projects` table.
package struct ProjectStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// Create a project. Slug is derived from the name and made unique against existing rows.
    /// If the derived slug already exists with the same name, returns the existing row (idempotent by name).
    package func create(name: String, description: String? = nil, tags: [String]? = nil) throws -> ProjectRecord {
        let baseSlug = SlugGenerator.slugify(name)
        if let existing = try get(slug: baseSlug), existing.name == name {
            return existing
        }
        let uniqueSlug = try database.pool.read { conn in
            try SlugGenerator.uniqueSlug(base: baseSlug) { candidate in
                try Int.fetchOne(conn, sql: "SELECT 1 FROM projects WHERE slug = ?", arguments: [candidate]) != nil
            }
        }
        return try createWithSlug(slug: uniqueSlug, name: name, description: description, tags: tags)
    }

    /// Create a project with an explicit slug. Returns the existing row if the slug already exists.
    package func createWithSlug(slug: String, name: String? = nil, description: String? = nil, tags: [String]? = nil) throws -> ProjectRecord {
        if let existing = try get(slug: slug) {
            return existing
        }
        let now = Timestamp.now()
        let record = ProjectRecord(
            slug: slug,
            name: name ?? slug,
            status: "active",
            created: now,
            updated: now,
            description: description,
            tags: tags
        )
        let tagsJSON = try record.tags.map { try JSONSerialization.data(withJSONObject: $0).asUTF8String() }
        try database.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO projects (slug, name, status, description, tags_json, created, updated)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [record.slug, record.name, record.status, record.description, tagsJSON, record.created, record.updated]
            )
        }
        return record
    }

    package func get(slug: String) throws -> ProjectRecord? {
        try database.pool.read { conn in
            try ProjectRecord.fetchOneBySlug(conn, slug: slug)
        }
    }

    package func list(status: String? = nil) throws -> [ProjectRecord] {
        try database.pool.read { conn in
            if let status {
                return try ProjectRecord.fetchAll(conn, sql: """
                    SELECT slug, name, status, description, tags_json, created, updated
                    FROM projects WHERE status = ? ORDER BY created DESC
                """, arguments: [status])
            } else {
                return try ProjectRecord.fetchAll(conn, sql: """
                    SELECT slug, name, status, description, tags_json, created, updated
                    FROM projects ORDER BY created DESC
                """)
            }
        }
    }

    @discardableResult
    package func archive(slug: String) throws -> ProjectRecord? {
        guard try get(slug: slug) != nil else { return nil }
        let now = Timestamp.now()
        try database.pool.write { conn in
            try conn.execute(
                sql: "UPDATE projects SET status = 'archived', updated = ? WHERE slug = ?",
                arguments: [now, slug]
            )
        }
        return try get(slug: slug)
    }

    @discardableResult
    package func delete(slug: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM projects WHERE slug = ?", arguments: [slug])
            return conn.changesCount > 0
        }
    }
}

// MARK: - GRDB row decoding

extension ProjectRecord: FetchableRecord {
    package init(row: Row) throws {
        let tagsJSON: String? = row["tags_json"]
        let tags: [String]?
        if let tagsJSON, let data = tagsJSON.data(using: .utf8) {
            tags = try? JSONSerialization.jsonObject(with: data) as? [String]
        } else {
            tags = nil
        }
        self.init(
            slug: row["slug"],
            name: row["name"],
            status: row["status"],
            created: row["created"],
            updated: row["updated"],
            description: row["description"],
            tags: tags
        )
    }

    static func fetchOneBySlug(_ conn: GRDB.Database, slug: String) throws -> ProjectRecord? {
        try ProjectRecord.fetchOne(conn, sql: """
            SELECT slug, name, status, description, tags_json, created, updated
            FROM projects WHERE slug = ?
        """, arguments: [slug])
    }
}

// small helper
private extension Data {
    func asUTF8String() throws -> String {
        guard let s = String(data: self, encoding: .utf8) else {
            throw NSError(domain: "ProjectStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "tags_json not valid UTF-8"])
        }
        return s
    }
}
