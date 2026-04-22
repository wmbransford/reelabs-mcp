import Foundation
import GRDB

/// One-shot importer that reads pre-SQLite on-disk markdown state and writes it into the DB.
/// Called from `Database.init` *after* migrations. Idempotent — re-running it on a populated
/// DB is a no-op for rows that already exist (via `INSERT OR IGNORE`).
package enum MarkdownImporter {
    package static func runIfNeeded(database: Database) throws {
        try importProjects(database: database)
        try importPresets(database: database)
        // Later tasks will extend this with assets, transcripts, analyses, renders.
    }

    static func importProjects(database: Database) throws {
        let projectsDir = database.paths.projectsDir
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return }

        let entries = try FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for entry in entries {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let projectMd = entry.appendingPathComponent("project.md")
            guard FileManager.default.fileExists(atPath: projectMd.path) else { continue }

            // Skip malformed legacy data rather than crashing.
            guard let parsed = try? MarkdownStore.read(at: projectMd, as: ProjectRecord.self).frontMatter else {
                continue
            }

            let tagsJSON: String?
            if let tags = parsed.tags {
                let data = try JSONSerialization.data(withJSONObject: tags)
                tagsJSON = String(data: data, encoding: .utf8)
            } else {
                tagsJSON = nil
            }

            try database.pool.write { conn in
                try conn.execute(
                    sql: """
                        INSERT OR IGNORE INTO projects (slug, name, status, description, tags_json, created, updated)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        parsed.slug,
                        parsed.name,
                        parsed.status,
                        parsed.description,
                        tagsJSON,
                        parsed.created,
                        parsed.updated,
                    ]
                )
            }
        }
    }

    static func importPresets(database: Database) throws {
        let dir = database.paths.presetsDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "md" }

        for file in files {
            // Skip malformed legacy data rather than crashing.
            guard let parsed = try? MarkdownStore.read(at: file, as: PresetRecord.self).frontMatter else {
                continue
            }
            try database.pool.write { conn in
                try conn.execute(
                    sql: """
                        INSERT OR IGNORE INTO presets (name, type, description, config_json, created, updated)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        parsed.name,
                        parsed.type,
                        parsed.description,
                        parsed.configJson,
                        parsed.created,
                        parsed.updated,
                    ]
                )
            }
        }
    }
}
