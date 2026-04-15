import Foundation
import GRDB

package final class DatabaseManager: Sendable {
    package let dbPool: DatabasePool

    static var databaseURL: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("ReelabsMCP", isDirectory: true)
            .appendingPathComponent("reelabs.sqlite")
    }

    package init(path: String? = nil) throws {
        let url = path.map { URL(fileURLWithPath: $0) } ?? Self.databaseURL
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbPool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        Self.registerMigrations(&migrator)
        try migrator.migrate(dbPool)
    }

    private static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_schema") { db in
            // Projects
            try db.create(table: "projects") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("createdAt", .text).notNull().defaults(sql: "(datetime('now'))")
                t.column("updatedAt", .text).notNull().defaults(sql: "(datetime('now'))")
            }

            // Assets
            try db.create(table: "assets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("projectId", .integer).notNull()
                    .references("projects", onDelete: .cascade)
                t.column("filePath", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("durationMs", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("fps", .double)
                t.column("codec", .text)
                t.column("hasAudio", .boolean).notNull().defaults(to: true)
                t.column("fileSizeBytes", .integer)
                t.column("tags", .text)
                t.column("createdAt", .text).notNull().defaults(sql: "(datetime('now'))")
            }

            // Transcripts (metadata only — words live in transcript_words)
            try db.create(table: "transcripts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetId", .integer)
                    .references("assets", onDelete: .setNull)
                t.column("sourcePath", .text).notNull()
                t.column("fullText", .text).notNull()
                t.column("compactJson", .text).notNull()
                t.column("durationSeconds", .double)
                t.column("wordCount", .integer)
                t.column("createdAt", .text).notNull().defaults(sql: "(datetime('now'))")
            }

            // Transcript words — one row per word with indexed timestamps
            try db.create(table: "transcript_words") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("transcriptId", .integer).notNull()
                    .references("transcripts", onDelete: .cascade)
                t.column("wordIndex", .integer).notNull()
                t.column("word", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("confidence", .double)
            }
            try db.create(index: "idx_transcript_words_transcriptId",
                          on: "transcript_words", columns: ["transcriptId"])

            // FTS5 for transcripts
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcripts_fts USING fts5(
                    full_text, content=transcripts, content_rowid=id
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER transcripts_ai AFTER INSERT ON transcripts BEGIN
                    INSERT INTO transcripts_fts(rowid, full_text) VALUES (new.id, new.fullText);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER transcripts_ad AFTER DELETE ON transcripts BEGIN
                    INSERT INTO transcripts_fts(transcripts_fts, rowid, full_text) VALUES ('delete', old.id, old.fullText);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER transcripts_au AFTER UPDATE ON transcripts BEGIN
                    INSERT INTO transcripts_fts(transcripts_fts, rowid, full_text) VALUES ('delete', old.id, old.fullText);
                    INSERT INTO transcripts_fts(rowid, full_text) VALUES (new.id, new.fullText);
                END
                """)

            // Renders
            try db.create(table: "renders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("projectId", .integer)
                    .references("projects", onDelete: .setNull)
                t.column("specJson", .text).notNull()
                t.column("outputPath", .text)
                t.column("durationSeconds", .double)
                t.column("fileSizeBytes", .integer)
                t.column("status", .text).notNull().defaults(to: "completed")
                t.column("errorMessage", .text)
                t.column("createdAt", .text).notNull().defaults(sql: "(datetime('now'))")
            }

            // Presets
            try db.create(table: "presets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("type", .text).notNull()
                t.column("configJson", .text).notNull()
                t.column("description", .text)
                t.column("createdAt", .text).notNull().defaults(sql: "(datetime('now'))")
                t.column("updatedAt", .text).notNull().defaults(sql: "(datetime('now'))")
            }
        }

        // v2_add_compactJson removed — column already exists in v1 schema
        migrator.registerMigration("v2_add_compactJson") { _ in }

        migrator.registerMigration("v3_visual_analysis") { db in
            try db.create(table: "visual_analyses") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetId", .integer)
                    .references("assets", onDelete: .setNull)
                t.column("sourcePath", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "extracted")
                t.column("sampleFps", .double).notNull()
                t.column("frameCount", .integer).notNull().defaults(to: 0)
                t.column("sceneCount", .integer).notNull().defaults(to: 0)
                t.column("durationSeconds", .double).notNull().defaults(to: 0)
                t.column("framesDir", .text).notNull().defaults(to: "")
                t.column("createdAt", .text).notNull().defaults(sql: "(datetime('now'))")
            }

            try db.create(table: "visual_scenes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("analysisId", .integer).notNull()
                    .references("visual_analyses", onDelete: .cascade)
                t.column("sceneIndex", .integer).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("description", .text).notNull()
                t.column("tags", .text)
                t.column("sceneType", .text)
                t.column("createdAt", .text).notNull().defaults(sql: "(datetime('now'))")
            }

            try db.create(index: "idx_visual_scenes_analysisId",
                          on: "visual_scenes", columns: ["analysisId"])
        }
    }
}
