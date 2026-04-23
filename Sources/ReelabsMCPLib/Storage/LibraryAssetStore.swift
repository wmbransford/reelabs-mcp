import Foundation
import GRDB

/// SQLite-backed DAO for the spine's `library_assets` table — the universal
/// source registry for both captured and generated content. Distinct from the
/// project-scoped `AssetStore`, which manages captured files keyed by project.
package struct LibraryAssetStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    @discardableResult
    package func register(
        kind: LibraryAssetKind,
        path: String? = nil,
        externalRef: String? = nil,
        contentHash: String? = nil,
        durationS: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        codec: String? = nil,
        hasAudio: Bool? = nil,
        provenance: [String: String]? = nil,
        sourceMetadata: [String: String]? = nil
    ) throws -> LibraryAssetRecord {
        let now = Timestamp.now()
        let provenanceJSON = try encodeJSON(provenance)
        let metadataJSON = try encodeJSON(sourceMetadata)

        let id = try database.pool.write { conn -> Int64 in
            try conn.execute(
                sql: """
                    INSERT INTO library_assets (
                        kind, path, external_ref, content_hash,
                        duration_s, width, height, fps, codec, has_audio,
                        provenance_json, source_metadata_json,
                        created_at, ingested_at
                    ) VALUES (?,?,?,?, ?,?,?,?,?,?, ?,?, ?,?)
                """,
                arguments: [
                    kind.rawValue, path, externalRef, contentHash,
                    durationS, width, height, fps, codec, hasAudio.map { $0 ? 1 : 0 },
                    provenanceJSON, metadataJSON,
                    now, now
                ]
            )
            return conn.lastInsertedRowID
        }

        return LibraryAssetRecord(
            id: id,
            kind: kind,
            path: path,
            externalRef: externalRef,
            contentHash: contentHash,
            durationS: durationS,
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            hasAudio: hasAudio,
            provenance: provenance,
            sourceMetadata: sourceMetadata,
            createdAt: now,
            ingestedAt: now
        )
    }

    package func getByID(_ id: Int64) throws -> LibraryAssetRecord? {
        try database.pool.read { conn in
            try LibraryAssetRecord.fetchOne(conn, sql: selectColumns + " WHERE id = ?", arguments: [id])
        }
    }

    package func getByContentHash(_ hash: String) throws -> LibraryAssetRecord? {
        try database.pool.read { conn in
            try LibraryAssetRecord.fetchOne(
                conn,
                sql: selectColumns + " WHERE content_hash = ? ORDER BY id ASC LIMIT 1",
                arguments: [hash]
            )
        }
    }

    package func listByKind(_ kind: LibraryAssetKind) throws -> [LibraryAssetRecord] {
        try database.pool.read { conn in
            try LibraryAssetRecord.fetchAll(
                conn,
                sql: selectColumns + " WHERE kind = ? ORDER BY created_at DESC",
                arguments: [kind.rawValue]
            )
        }
    }

    private let selectColumns = """
        SELECT id, kind, path, external_ref, content_hash,
               duration_s, width, height, fps, codec, has_audio,
               provenance_json, source_metadata_json,
               created_at, ingested_at
          FROM library_assets
    """

    private func encodeJSON(_ dict: [String: String]?) throws -> String? {
        guard let dict else { return nil }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - GRDB row decoding

extension LibraryAssetRecord: FetchableRecord {
    package init(row: Row) throws {
        let kindRaw: String = row["kind"]
        guard let kind = LibraryAssetKind(rawValue: kindRaw) else {
            throw NSError(
                domain: "LibraryAssetStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unknown kind: \(kindRaw)"]
            )
        }
        let hasAudioInt: Int? = row["has_audio"]
        let provenanceJSON: String? = row["provenance_json"]
        let metadataJSON: String? = row["source_metadata_json"]

        self.init(
            id: row["id"],
            kind: kind,
            path: row["path"],
            externalRef: row["external_ref"],
            contentHash: row["content_hash"],
            durationS: row["duration_s"],
            width: row["width"],
            height: row["height"],
            fps: row["fps"],
            codec: row["codec"],
            hasAudio: hasAudioInt.map { $0 != 0 },
            provenance: Self.decodeJSON(provenanceJSON),
            sourceMetadata: Self.decodeJSON(metadataJSON),
            createdAt: row["created_at"],
            ingestedAt: row["ingested_at"]
        )
    }

    private static func decodeJSON(_ json: String?) -> [String: String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
