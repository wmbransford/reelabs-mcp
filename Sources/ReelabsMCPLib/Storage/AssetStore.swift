import Foundation
import GRDB

/// SQLite-backed asset storage. One row per asset in the `assets` table,
/// keyed by `(project_slug, slug)`. Rows cascade-delete with their parent project.
package struct AssetStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// Insert or update an asset. On conflict `(project_slug, slug)`, all fields
    /// except the primary key are overwritten; `created` is preserved.
    @discardableResult
    package func add(
        project: String,
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
        tags: [String]? = nil
    ) throws -> AssetRecord {
        let now = Timestamp.now()
        let record = AssetRecord(
            slug: slug,
            filename: filename,
            filePath: filePath,
            fileSizeBytes: fileSizeBytes,
            durationSeconds: durationSeconds,
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            hasAudio: hasAudio,
            tags: tags,
            created: now
        )

        let tagsJSON: String?
        if let tags {
            let data = try JSONSerialization.data(withJSONObject: tags)
            tagsJSON = String(data: data, encoding: .utf8)
        } else {
            tagsJSON = nil
        }

        try database.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO assets (project_slug, slug, filename, file_path, file_size_bytes,
                        duration_seconds, width, height, fps, codec, has_audio, tags_json, created)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(project_slug, slug) DO UPDATE SET
                        filename = excluded.filename,
                        file_path = excluded.file_path,
                        file_size_bytes = excluded.file_size_bytes,
                        duration_seconds = excluded.duration_seconds,
                        width = excluded.width,
                        height = excluded.height,
                        fps = excluded.fps,
                        codec = excluded.codec,
                        has_audio = excluded.has_audio,
                        tags_json = excluded.tags_json
                """,
                arguments: [
                    project, slug, filename, filePath, fileSizeBytes,
                    durationSeconds, width, height, fps, codec,
                    hasAudio ? 1 : 0, tagsJSON, now,
                ]
            )
        }
        return record
    }

    package func get(project: String, slug: String) throws -> AssetRecord? {
        try database.pool.read { conn in
            try AssetRecord.fetchOne(conn, sql: """
                SELECT slug, filename, file_path, file_size_bytes, duration_seconds,
                       width, height, fps, codec, has_audio, tags_json, created
                FROM assets WHERE project_slug = ? AND slug = ?
            """, arguments: [project, slug])
        }
    }

    package func list(project: String) throws -> [AssetRecord] {
        try database.pool.read { conn in
            try AssetRecord.fetchAll(conn, sql: """
                SELECT slug, filename, file_path, file_size_bytes, duration_seconds,
                       width, height, fps, codec, has_audio, tags_json, created
                FROM assets WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    package func tag(project: String, slug: String, tags: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: tags)
        let json = String(data: data, encoding: .utf8)
        try database.pool.write { conn in
            try conn.execute(
                sql: "UPDATE assets SET tags_json = ? WHERE project_slug = ? AND slug = ?",
                arguments: [json, project, slug]
            )
        }
    }

    @discardableResult
    package func delete(project: String, slug: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(
                sql: "DELETE FROM assets WHERE project_slug = ? AND slug = ?",
                arguments: [project, slug]
            )
            return conn.changesCount > 0
        }
    }
}

// MARK: - GRDB row decoding

extension AssetRecord: FetchableRecord {
    package init(row: Row) throws {
        let tagsJSON: String? = row["tags_json"]
        let tags: [String]? = tagsJSON.flatMap { json -> [String]? in
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return nil }
            return parsed
        }
        let hasAudioInt: Int? = row["has_audio"]
        self.init(
            slug: row["slug"],
            filename: row["filename"],
            filePath: row["file_path"],
            fileSizeBytes: row["file_size_bytes"],
            durationSeconds: row["duration_seconds"],
            width: row["width"],
            height: row["height"],
            fps: row["fps"],
            codec: row["codec"],
            hasAudio: (hasAudioInt ?? 1) != 0,
            tags: tags,
            created: row["created"]
        )
    }
}
