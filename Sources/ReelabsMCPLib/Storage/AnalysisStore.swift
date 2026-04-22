import Foundation
import GRDB

/// SQLite-backed visual-analysis storage.
///   - `analyses`: one row per `(project_slug, source_slug)` with frame metadata + status.
///   - `scenes`: one row per scene, ordered by `scene_index`, with FK cascade from `analyses`.
///
/// Scenes are replaced atomically on `saveScenes` — the whole scene list for a source is
/// deleted and re-inserted in a single transaction, and the parent's `scene_count`,
/// `duration_seconds` (monotonic), and `status` are updated at the same time.
package struct AnalysisStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// Insert (or upsert) the analysis row. Status defaults to `extracted`; `scene_count`
    /// is always reset to 0 here — call `saveScenes` to populate scenes and flip the
    /// status to `analyzed`.
    @discardableResult
    package func save(
        project: String,
        source: String,
        sourcePath: String,
        sampleFps: Double,
        frameCount: Int = 0,
        framesDir: String = "",
        durationSeconds: Double = 0
    ) throws -> AnalysisRecord {
        let now = Timestamp.now()
        let record = AnalysisRecord(
            slug: "\(project)/\(source)",
            sourcePath: sourcePath,
            status: "extracted",
            sampleFps: sampleFps,
            frameCount: frameCount,
            sceneCount: 0,
            durationSeconds: durationSeconds,
            framesDir: framesDir,
            created: now
        )
        try database.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO analyses (project_slug, source_slug, source_path, status, sample_fps,
                    frame_count, scene_count, duration_seconds, frames_dir, created)
                VALUES (?, ?, ?, 'extracted', ?, ?, 0, ?, ?, ?)
                ON CONFLICT(project_slug, source_slug) DO UPDATE SET
                    source_path = excluded.source_path,
                    sample_fps = excluded.sample_fps,
                    frame_count = excluded.frame_count,
                    duration_seconds = excluded.duration_seconds,
                    frames_dir = excluded.frames_dir
            """, arguments: [
                project, source, sourcePath, sampleFps,
                frameCount, durationSeconds, framesDir, now
            ])
        }
        return record
    }

    /// Replace all scenes for `(project, source)` with `scenes`, inside a single
    /// transaction. Also updates the parent analysis row's `scene_count`,
    /// `duration_seconds` (max of existing and computed), and status → `analyzed`.
    package func saveScenes(project: String, source: String, scenes: [SceneRecord]) throws {
        try database.pool.write { conn in
            try conn.execute(
                sql: "DELETE FROM scenes WHERE project_slug = ? AND source_slug = ?",
                arguments: [project, source]
            )
            for s in scenes {
                let tagsJSON: String?
                if let tags = s.tags {
                    let data = try JSONSerialization.data(withJSONObject: tags)
                    tagsJSON = String(data: data, encoding: .utf8)
                } else {
                    tagsJSON = nil
                }
                try conn.execute(sql: """
                    INSERT INTO scenes (project_slug, source_slug, scene_index, start_time, end_time,
                        description, tags_json, scene_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    project, source, s.sceneIndex, s.startTime, s.endTime,
                    s.description, tagsJSON, s.sceneType
                ])
            }
            let duration = scenes.map { $0.endTime }.max() ?? 0
            try conn.execute(sql: """
                UPDATE analyses
                   SET scene_count = ?,
                       duration_seconds = MAX(duration_seconds, ?),
                       status = 'analyzed'
                 WHERE project_slug = ? AND source_slug = ?
            """, arguments: [scenes.count, duration, project, source])
        }
    }

    package func get(project: String, source: String) throws -> AnalysisRecord? {
        try database.pool.read { conn in
            try AnalysisRecord.fetchOne(conn, sql: """
                SELECT project_slug, source_slug, source_path, status, sample_fps,
                       frame_count, scene_count, duration_seconds, frames_dir, created
                FROM analyses WHERE project_slug = ? AND source_slug = ?
            """, arguments: [project, source])
        }
    }

    package func getScenes(project: String, source: String) throws -> [SceneRecord] {
        try database.pool.read { conn in
            try SceneRecord.fetchAll(conn, sql: """
                SELECT scene_index, start_time, end_time, description, tags_json, scene_type
                FROM scenes WHERE project_slug = ? AND source_slug = ? ORDER BY scene_index
            """, arguments: [project, source])
        }
    }

    package func list(project: String) throws -> [AnalysisRecord] {
        try database.pool.read { conn in
            try AnalysisRecord.fetchAll(conn, sql: """
                SELECT project_slug, source_slug, source_path, status, sample_fps,
                       frame_count, scene_count, duration_seconds, frames_dir, created
                FROM analyses WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    @discardableResult
    package func delete(project: String, source: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(
                sql: "DELETE FROM analyses WHERE project_slug = ? AND source_slug = ?",
                arguments: [project, source]
            )
            return conn.changesCount > 0
        }
    }

}

// MARK: - GRDB row decoding

extension AnalysisRecord: FetchableRecord {
    package init(row: Row) throws {
        let project: String = row["project_slug"]
        let source: String = row["source_slug"]
        self.init(
            slug: "\(project)/\(source)",
            sourcePath: row["source_path"],
            status: row["status"],
            sampleFps: row["sample_fps"],
            frameCount: row["frame_count"],
            sceneCount: row["scene_count"],
            durationSeconds: row["duration_seconds"],
            framesDir: row["frames_dir"],
            created: row["created"]
        )
    }
}

extension SceneRecord: FetchableRecord {
    package init(row: Row) throws {
        let tagsJSON: String? = row["tags_json"]
        let tags: [String]? = tagsJSON.flatMap { json -> [String]? in
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return nil }
            return parsed
        }
        self.init(
            sceneIndex: row["scene_index"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            description: row["description"],
            tags: tags,
            sceneType: row["scene_type"]
        )
    }
}
