import Foundation
import GRDB

/// One-shot importer that reads pre-SQLite on-disk markdown state and writes it into the DB.
/// Called from `Database.init` *after* migrations. Idempotent — re-running it on a populated
/// DB is a no-op for rows that already exist (via `INSERT OR IGNORE`).
package enum MarkdownImporter {
    package static func runIfNeeded(database: Database) throws {
        // Order matters: assets/transcripts/analyses/renders reference `projects(slug)`
        // via foreign keys, so projects must land first.
        try importProjects(database: database)
        try importPresets(database: database)
        try importAssets(database: database)
        // Later tasks will extend this with transcripts, analyses, renders.
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

    static func importAssets(database: Database) throws {
        let projectsDir = database.paths.projectsDir
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return }

        let projectDirs = try FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let projectSlug = projectDir.lastPathComponent

            let entries = (try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.lastPathComponent.hasSuffix(".asset.md") {
                guard let parsed = try? MarkdownStore.read(at: entry, as: AssetRecord.self).frontMatter else {
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
                            INSERT OR IGNORE INTO assets (
                                project_slug, slug, filename, file_path, file_size_bytes,
                                duration_seconds, width, height, fps, codec,
                                has_audio, tags_json, created
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            projectSlug,
                            parsed.slug,
                            parsed.filename,
                            parsed.filePath,
                            parsed.fileSizeBytes,
                            parsed.durationSeconds,
                            parsed.width,
                            parsed.height,
                            parsed.fps,
                            parsed.codec,
                            parsed.hasAudio ? 1 : 0,
                            tagsJSON,
                            parsed.created,
                        ]
                    )
                }
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
