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
        try importTranscripts(database: database)
        try importAnalyses(database: database)
        try importRenders(database: database)
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

    static func importTranscripts(database: Database) throws {
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
            for entry in entries where entry.lastPathComponent.hasSuffix(".transcript.md") {
                // Skip malformed legacy data rather than crashing.
                guard let parsed = try? MarkdownStore.read(at: entry, as: TranscriptRecord.self) else {
                    continue
                }
                let sourceSlug = entry.lastPathComponent
                    .replacingOccurrences(of: ".transcript.md", with: "")

                // Words live in the sibling `{source}.words.json`.
                let wordsURL = projectDir.appendingPathComponent("\(sourceSlug).words.json")
                let words: [WordEntry]
                if FileManager.default.fileExists(atPath: wordsURL.path),
                   let data = try? Data(contentsOf: wordsURL),
                   let decoded = try? JSONDecoder().decode([WordEntry].self, from: data) {
                    words = decoded
                } else {
                    words = []
                }

                let record = parsed.frontMatter
                let fullText = parsed.body

                try database.pool.write { conn in
                    try conn.execute(
                        sql: """
                            INSERT OR IGNORE INTO transcripts (
                                project_slug, source_slug, source_path, duration_seconds,
                                word_count, language, mode, full_text, created
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            projectSlug,
                            sourceSlug,
                            record.sourcePath,
                            record.durationSeconds,
                            record.wordCount,
                            record.language,
                            record.mode,
                            fullText,
                            record.created,
                        ]
                    )

                    // Only seed words when the parent transcript row was actually inserted.
                    // If the INSERT OR IGNORE hit the conflict, we leave existing words alone.
                    if conn.changesCount > 0 {
                        for (i, w) in words.enumerated() {
                            try conn.execute(
                                sql: """
                                    INSERT OR IGNORE INTO transcript_words (
                                        project_slug, source_slug, word_index, word,
                                        start_time, end_time, confidence
                                    )
                                    VALUES (?, ?, ?, ?, ?, ?, ?)
                                """,
                                arguments: [projectSlug, sourceSlug, i, w.word, w.start, w.end, w.confidence]
                            )
                        }
                    }
                }
            }
        }
    }

    static func importAnalyses(database: Database) throws {
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
            for entry in entries where entry.lastPathComponent.hasSuffix(".analysis.md") {
                guard let parsed = try? MarkdownStore.read(at: entry, as: AnalysisRecord.self).frontMatter else {
                    continue
                }
                let sourceSlug = entry.lastPathComponent
                    .replacingOccurrences(of: ".analysis.md", with: "")

                // Load sibling `{source}.scenes.json` if present.
                let scenesURL = projectDir.appendingPathComponent("\(sourceSlug).scenes.json")
                let scenes: [SceneRecord]
                if FileManager.default.fileExists(atPath: scenesURL.path),
                   let data = try? Data(contentsOf: scenesURL),
                   let decoded = try? JSONDecoder().decode([SceneRecord].self, from: data) {
                    scenes = decoded
                } else {
                    scenes = []
                }

                try database.pool.write { conn in
                    try conn.execute(
                        sql: """
                            INSERT OR IGNORE INTO analyses (
                                project_slug, source_slug, source_path, status, sample_fps,
                                frame_count, scene_count, duration_seconds, frames_dir, created
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            projectSlug,
                            sourceSlug,
                            parsed.sourcePath,
                            parsed.status,
                            parsed.sampleFps,
                            parsed.frameCount,
                            parsed.sceneCount,
                            parsed.durationSeconds,
                            parsed.framesDir,
                            parsed.created,
                        ]
                    )

                    // Only seed scenes if the parent analysis row was actually inserted.
                    if conn.changesCount > 0 && !scenes.isEmpty {
                        for s in scenes {
                            let tagsJSON: String?
                            if let tags = s.tags {
                                let tagsData = try JSONSerialization.data(withJSONObject: tags)
                                tagsJSON = String(data: tagsData, encoding: .utf8)
                            } else {
                                tagsJSON = nil
                            }
                            try conn.execute(
                                sql: """
                                    INSERT OR IGNORE INTO scenes (
                                        project_slug, source_slug, scene_index, start_time, end_time,
                                        description, tags_json, scene_type
                                    )
                                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                                arguments: [
                                    projectSlug, sourceSlug, s.sceneIndex, s.startTime, s.endTime,
                                    s.description, tagsJSON, s.sceneType
                                ]
                            )
                        }
                    }
                }
            }
        }
    }

    static func importRenders(database: Database) throws {
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
            for entry in entries where entry.lastPathComponent.hasSuffix(".render.md") {
                guard let parsed = try? MarkdownStore.read(at: entry, as: RenderRecord.self) else {
                    continue
                }
                let record = parsed.frontMatter
                let (specJson, notes) = RenderStore.splitBody(parsed.body)

                let sourcesJSON: String?
                if let sources = record.sources {
                    let data = try JSONSerialization.data(withJSONObject: sources)
                    sourcesJSON = String(data: data, encoding: .utf8)
                } else {
                    sourcesJSON = nil
                }

                try database.pool.write { conn in
                    try conn.execute(
                        sql: """
                            INSERT OR IGNORE INTO renders (
                                project_slug, slug, status, duration_seconds, output_path,
                                file_size_bytes, sources_json, spec_json, notes_md, created
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            projectSlug,
                            record.slug,
                            record.status,
                            record.durationSeconds,
                            record.outputPath,
                            record.fileSizeBytes,
                            sourcesJSON,
                            specJson ?? "",
                            notes,
                            record.created,
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
