import Foundation
import GRDB

/// SQLite-backed preset storage. One row per preset in the `presets` table.
package struct PresetStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// Insert or update a preset. Preserves the `created` timestamp of an existing row; bumps `updated`.
    @discardableResult
    package func upsert(name: String, type: String, configJson: String, description: String? = nil) throws -> PresetRecord {
        let now = Timestamp.now()
        let existing = try get(name: name)
        let created = existing?.created ?? now
        let record = PresetRecord(
            name: name,
            type: type,
            configJson: configJson,
            description: description,
            created: created,
            updated: now
        )

        try database.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO presets (name, type, description, config_json, created, updated)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        type = excluded.type,
                        description = excluded.description,
                        config_json = excluded.config_json,
                        updated = excluded.updated
                """,
                arguments: [record.name, record.type, record.description, record.configJson, record.created, record.updated]
            )
        }
        return record
    }

    package func get(name: String) throws -> PresetRecord? {
        try database.pool.read { conn in
            try PresetRecord.fetchOne(conn, sql: """
                SELECT name, type, description, config_json, created, updated
                FROM presets WHERE name = ?
            """, arguments: [name])
        }
    }

    package func list(type: String? = nil) throws -> [PresetRecord] {
        try database.pool.read { conn in
            if let type {
                return try PresetRecord.fetchAll(conn, sql: """
                    SELECT name, type, description, config_json, created, updated
                    FROM presets WHERE type = ? ORDER BY name
                """, arguments: [type])
            } else {
                return try PresetRecord.fetchAll(conn, sql: """
                    SELECT name, type, description, config_json, created, updated
                    FROM presets ORDER BY name
                """)
            }
        }
    }

    @discardableResult
    package func delete(name: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM presets WHERE name = ?", arguments: [name])
            return conn.changesCount > 0
        }
    }
}

// MARK: - GRDB row decoding

extension PresetRecord: FetchableRecord {
    package init(row: Row) throws {
        self.init(
            name: row["name"],
            type: row["type"],
            configJson: row["config_json"],
            description: row["description"],
            created: row["created"],
            updated: row["updated"]
        )
    }
}
