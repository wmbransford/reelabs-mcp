import Foundation
import GRDB

// MARK: - Project Repository

package struct ProjectRepository: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) { self.dbPool = dbPool }

    package func create(name: String, description: String? = nil) throws -> Project {
        try dbPool.write { db in
            var project = Project(name: name, description: description)
            try project.insert(db)
            return project
        }
    }

    package func list(status: String? = nil) throws -> [Project] {
        try dbPool.read { db in
            if let status {
                return try Project.filter(Column("status") == status).fetchAll(db)
            }
            return try Project.fetchAll(db)
        }
    }

    package func get(id: Int64) throws -> Project? {
        try dbPool.read { db in
            try Project.fetchOne(db, key: id)
        }
    }

    package func archive(id: Int64) throws -> Project? {
        try dbPool.write { db in
            guard var project = try Project.fetchOne(db, key: id) else { return nil }
            project.status = "archived"
            project.updatedAt = Project.timestamp()
            try project.update(db)
            return project
        }
    }

    package func delete(id: Int64) throws -> Bool {
        try dbPool.write { db in
            try Project.deleteOne(db, key: id)
        }
    }
}

// MARK: - Asset Repository

package struct AssetRepository: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) { self.dbPool = dbPool }

    package func create(_ asset: Asset) throws -> Asset {
        try dbPool.write { db in
            var a = asset
            try a.insert(db)
            return a
        }
    }

    package func list(projectId: Int64) throws -> [Asset] {
        try dbPool.read { db in
            try Asset.filter(Column("projectId") == projectId).fetchAll(db)
        }
    }

    package func get(id: Int64) throws -> Asset? {
        try dbPool.read { db in
            try Asset.fetchOne(db, key: id)
        }
    }

    package func updateMetadata(id: Int64, durationMs: Int?, width: Int?, height: Int?, fps: Double?, codec: String?, hasAudio: Bool, fileSizeBytes: Int64?) throws {
        try dbPool.write { db in
            guard var asset = try Asset.fetchOne(db, key: id) else { return }
            asset.durationMs = durationMs
            asset.width = width
            asset.height = height
            asset.fps = fps
            asset.codec = codec
            asset.hasAudio = hasAudio
            asset.fileSizeBytes = fileSizeBytes
            try asset.update(db)
        }
    }

    package func updateTags(id: Int64, tags: [String]) throws {
        try dbPool.write { db in
            guard var asset = try Asset.fetchOne(db, key: id) else { return }
            let data = try JSONEncoder().encode(tags)
            asset.tags = String(data: data, encoding: .utf8)
            try asset.update(db)
        }
    }

    package func delete(id: Int64) throws -> Bool {
        try dbPool.write { db in
            try Asset.deleteOne(db, key: id)
        }
    }
}

// MARK: - Transcript Repository

package struct TranscriptRepository: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) { self.dbPool = dbPool }

    /// Insert transcript metadata + all words in a single transaction.
    package func createWithWords(_ transcript: Transcript, words: [TranscriptWord]) throws -> Transcript {
        try dbPool.write { db in
            var t = transcript
            try t.insert(db)
            let transcriptId = t.id!

            for (index, word) in words.enumerated() {
                var record = TranscriptWordRecord(
                    transcriptId: transcriptId,
                    wordIndex: index,
                    word: word.word,
                    startTime: word.startTime,
                    endTime: word.endTime,
                    confidence: word.confidence
                )
                try record.insert(db)
            }

            return t
        }
    }

    /// Get all words for a transcript, ordered by position.
    package func getWords(transcriptId: Int64) throws -> [TranscriptWord] {
        try dbPool.read { db in
            let records = try TranscriptWordRecord
                .filter(Column("transcriptId") == transcriptId)
                .order(Column("wordIndex"))
                .fetchAll(db)
            return records.map { r in
                TranscriptWord(
                    word: r.word,
                    startTime: r.startTime,
                    endTime: r.endTime,
                    confidence: r.confidence
                )
            }
        }
    }

    package func get(id: Int64) throws -> Transcript? {
        try dbPool.read { db in
            try Transcript.fetchOne(db, key: id)
        }
    }

    package func getByAsset(assetId: Int64) throws -> Transcript? {
        try dbPool.read { db in
            try Transcript
                .filter(Column("assetId") == assetId)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    package func getBySource(path: String) throws -> Transcript? {
        try dbPool.read { db in
            try Transcript
                .filter(Column("sourcePath") == path)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    package func search(query: String, limit: Int = 20) throws -> [Transcript] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.* FROM transcripts t
                JOIN transcripts_fts fts ON fts.rowid = t.id
                WHERE transcripts_fts MATCH ?
                ORDER BY bm25(transcripts_fts)
                LIMIT ?
                """, arguments: [query, limit])
            return try rows.map { row in
                try Transcript(row: row)
            }
        }
    }
}

// MARK: - Render Repository

package struct RenderRepository: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) { self.dbPool = dbPool }

    package func create(projectId: Int64?, specJson: String, outputPath: String?, durationSeconds: Double?, fileSizeBytes: Int64?, status: String = "completed", errorMessage: String? = nil) throws -> Int64 {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO renders (projectId, specJson, outputPath, durationSeconds, fileSizeBytes, status, errorMessage)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [projectId, specJson, outputPath, durationSeconds, fileSizeBytes, status, errorMessage])
            return db.lastInsertedRowID
        }
    }

    package func list(projectId: Int64? = nil, limit: Int = 50) throws -> [Row] {
        try dbPool.read { db in
            if let projectId {
                return try Row.fetchAll(db, sql: "SELECT * FROM renders WHERE projectId = ? ORDER BY createdAt DESC LIMIT ?", arguments: [projectId, limit])
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM renders ORDER BY createdAt DESC LIMIT ?", arguments: [limit])
        }
    }
}

// MARK: - Preset Repository

package struct PresetRepository: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) { self.dbPool = dbPool }

    package func save(name: String, type: String, configJson: String, description: String? = nil) throws -> Preset {
        try dbPool.write { db in
            // Upsert: if name exists, update it
            if var existing = try Preset.filter(Column("name") == name).fetchOne(db) {
                existing.type = type
                existing.configJson = configJson
                existing.description = description ?? existing.description
                existing.updatedAt = Project.timestamp()
                try existing.update(db)
                return existing
            }
            var preset = Preset(name: name, type: type, configJson: configJson, description: description)
            try preset.insert(db)
            return preset
        }
    }

    package func get(name: String) throws -> Preset? {
        try dbPool.read { db in
            try Preset.filter(Column("name") == name).fetchOne(db)
        }
    }

    package func list(type: String? = nil) throws -> [Preset] {
        try dbPool.read { db in
            if let type {
                return try Preset.filter(Column("type") == type).fetchAll(db)
            }
            return try Preset.fetchAll(db)
        }
    }

    package func delete(name: String) throws -> Bool {
        try dbPool.write { db in
            try Preset.filter(Column("name") == name).deleteAll(db) > 0
        }
    }
}

// MARK: - Visual Analysis Repository

package struct VisualAnalysisRepository: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) { self.dbPool = dbPool }

    package func create(_ analysis: VisualAnalysis) throws -> VisualAnalysis {
        try dbPool.write { db in
            var a = analysis
            try a.insert(db)
            return a
        }
    }

    package func update(id: Int64, frameCount: Int? = nil, framesDir: String? = nil, status: String? = nil, sceneCount: Int? = nil) throws {
        try dbPool.write { db in
            guard var analysis = try VisualAnalysis.fetchOne(db, key: id) else { return }
            if let frameCount { analysis.frameCount = frameCount }
            if let framesDir { analysis.framesDir = framesDir }
            if let status { analysis.status = status }
            if let sceneCount { analysis.sceneCount = sceneCount }
            try analysis.update(db)
        }
    }

    package func get(id: Int64) throws -> VisualAnalysis? {
        try dbPool.read { db in
            try VisualAnalysis.fetchOne(db, key: id)
        }
    }

    package func getScenes(analysisId: Int64) throws -> [VisualScene] {
        try dbPool.read { db in
            try VisualScene
                .filter(Column("analysisId") == analysisId)
                .order(Column("sceneIndex"))
                .fetchAll(db)
        }
    }

    package func storeScenes(analysisId: Int64, scenes: [VisualScene]) throws {
        try dbPool.write { db in
            for var scene in scenes {
                try scene.insert(db)
            }
            guard var analysis = try VisualAnalysis.fetchOne(db, key: analysisId) else { return }
            analysis.status = "analyzed"
            analysis.sceneCount = scenes.count
            try analysis.update(db)
        }
    }
}
