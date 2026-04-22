import Foundation
import GRDB

/// SQLite-backed render storage. One row per render in the `renders` table,
/// keyed by `(project_slug, slug)`. The full RenderSpec lives in `spec_json`
/// and the prose half of the old `.render.md` body lives in `notes_md` — the
/// two halves are stored separately so `reelabs_rerender` can rehydrate the
/// spec without re-parsing markdown.
package struct RenderStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// Insert or upsert a render row. On conflict `(project_slug, slug)`, all
    /// fields except the primary key are overwritten; `created` is preserved
    /// because we don't touch it in the UPDATE.
    @discardableResult
    package func save(
        project: String,
        slug: String,
        specJSON: String,
        outputPath: String,
        status: String = "completed",
        durationSeconds: Double? = nil,
        fileSizeBytes: Int64? = nil,
        sources: [String]? = nil,
        notesMd: String = ""
    ) throws -> RenderRecord {
        let now = Timestamp.now()
        let sourcesJSON: String?
        if let sources {
            let data = try JSONSerialization.data(withJSONObject: sources)
            sourcesJSON = String(data: data, encoding: .utf8)
        } else {
            sourcesJSON = nil
        }

        try database.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO renders (project_slug, slug, status, duration_seconds, output_path,
                    file_size_bytes, sources_json, spec_json, notes_md, created)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_slug, slug) DO UPDATE SET
                    status = excluded.status,
                    duration_seconds = excluded.duration_seconds,
                    output_path = excluded.output_path,
                    file_size_bytes = excluded.file_size_bytes,
                    sources_json = excluded.sources_json,
                    spec_json = excluded.spec_json,
                    notes_md = excluded.notes_md
            """, arguments: [
                project, slug, status, durationSeconds, outputPath,
                fileSizeBytes, sourcesJSON, specJSON, notesMd, now
            ])
        }

        return RenderRecord(
            slug: slug,
            status: status,
            created: now,
            durationSeconds: durationSeconds,
            outputPath: outputPath,
            fileSizeBytes: fileSizeBytes,
            sources: sources
        )
    }

    package func get(project: String, slug: String) throws -> RenderRecord? {
        try database.pool.read { conn in
            try RenderRecord.fetchOne(conn, sql: """
                SELECT project_slug, slug, status, duration_seconds, output_path,
                       file_size_bytes, sources_json, created
                FROM renders WHERE project_slug = ? AND slug = ?
            """, arguments: [project, slug])
        }
    }

    package func getSpec(project: String, slug: String) throws -> String? {
        try database.pool.read { conn in
            try String.fetchOne(
                conn,
                sql: "SELECT spec_json FROM renders WHERE project_slug = ? AND slug = ?",
                arguments: [project, slug]
            )
        }
    }

    package func getNotes(project: String, slug: String) throws -> String? {
        try database.pool.read { conn in
            try String.fetchOne(
                conn,
                sql: "SELECT notes_md FROM renders WHERE project_slug = ? AND slug = ?",
                arguments: [project, slug]
            )
        }
    }

    package func list(project: String? = nil, limit: Int = 50) throws -> [(project: String, render: RenderRecord)] {
        try database.pool.read { conn in
            let rows: [Row]
            if let project {
                rows = try Row.fetchAll(conn, sql: """
                    SELECT project_slug, slug, status, duration_seconds, output_path,
                           file_size_bytes, sources_json, created
                    FROM renders WHERE project_slug = ? ORDER BY created DESC LIMIT ?
                """, arguments: [project, limit])
            } else {
                rows = try Row.fetchAll(conn, sql: """
                    SELECT project_slug, slug, status, duration_seconds, output_path,
                           file_size_bytes, sources_json, created
                    FROM renders ORDER BY created DESC LIMIT ?
                """, arguments: [limit])
            }
            return try rows.map { row in
                let record = try RenderRecord(row: row)
                return (row["project_slug"] as String, record)
            }
        }
    }

    /// Convenience: list a specific project's renders, newest first.
    package func list(project: String) throws -> [RenderRecord] {
        try database.pool.read { conn in
            try RenderRecord.fetchAll(conn, sql: """
                SELECT project_slug, slug, status, duration_seconds, output_path,
                       file_size_bytes, sources_json, created
                FROM renders WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    @discardableResult
    package func delete(project: String, slug: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(
                sql: "DELETE FROM renders WHERE project_slug = ? AND slug = ?",
                arguments: [project, slug]
            )
            return conn.changesCount > 0
        }
    }

    // MARK: - Body rendering (static helpers — used by the markdown importer)

    static func formatBody(record: RenderRecord, specJson: String, notes: String?) -> String {
        var lines: [String] = []
        lines.append("# Render: \(record.slug)")
        lines.append("")
        lines.append("## RenderSpec")
        lines.append("")
        lines.append("```json")
        lines.append(specJson)
        lines.append("```")
        if let notes, !notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Extract the first fenced ```json ... ``` block from a markdown body — used by
    /// the markdown importer to split an old `.render.md` body into `spec_json` +
    /// `notes_md`.
    static func extractSpecJson(from body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var inBlock = false
        var capturing: [String] = []
        for line in lines {
            if !inBlock {
                if line.trimmingCharacters(in: .whitespaces) == "```json" {
                    inBlock = true
                }
            } else {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    return capturing.joined(separator: "\n")
                }
                capturing.append(line)
            }
        }
        return nil
    }

    /// Given a markdown body, return `(spec_json, notes_md)`. If the body starts with
    /// a fenced `json` block (ignoring a title + blank-line preamble), that block's
    /// contents become `spec_json` and everything after the closing fence becomes
    /// `notes_md` (trimmed). Otherwise returns `(nil, full body)`.
    static func splitBody(_ body: String) -> (specJson: String?, notes: String) {
        let lines = body.components(separatedBy: "\n")
        var specLines: [String] = []
        var noteLines: [String] = []
        var sawFenceOpen = false
        var sawFenceClose = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !sawFenceOpen {
                if trimmed == "```json" {
                    sawFenceOpen = true
                }
                // Everything before the fence (title, blank line, RenderSpec heading)
                // is intentionally dropped — it's the boilerplate formatBody writes.
            } else if !sawFenceClose {
                if trimmed == "```" {
                    sawFenceClose = true
                } else {
                    specLines.append(line)
                }
            } else {
                noteLines.append(line)
            }
            i += 1
        }
        let specJson = sawFenceOpen && sawFenceClose ? specLines.joined(separator: "\n") : nil
        var notes = noteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if specJson == nil {
            // No json block at all — treat the full body as notes.
            notes = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip a leading "## Notes" heading if present — it's boilerplate from formatBody.
        let notesLines = notes.components(separatedBy: "\n")
        if let first = notesLines.first, first.trimmingCharacters(in: .whitespaces) == "## Notes" {
            notes = notesLines.dropFirst()
                .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (specJson, notes)
    }
}

// MARK: - GRDB row decoding

extension RenderRecord: FetchableRecord {
    package init(row: Row) throws {
        let sourcesJSON: String? = row["sources_json"]
        let sources: [String]? = sourcesJSON.flatMap { json -> [String]? in
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return nil }
            return parsed
        }
        self.init(
            slug: row["slug"],
            status: row["status"],
            created: row["created"],
            durationSeconds: row["duration_seconds"],
            outputPath: row["output_path"],
            fileSizeBytes: row["file_size_bytes"],
            sources: sources
        )
    }
}
