import Foundation
import MCP

/// `reelabs_ingest` — Plan 1 scope: the `register` stage of the ingestion pipeline.
/// Probes captured video/audio, computes a content hash, writes a `library_assets` row.
/// Later plans add subsequent stages (transcribe, segment, features, semantic, embed).
package enum IngestTool {
    package static let tool = Tool(
        name: "reelabs_ingest",
        description: """
            Register a captured video or audio file in the ReeLabs library. \
            Probes the file, computes a content hash for deduplication, and \
            writes a library_assets row with full provenance. Downstream \
            ingestion stages (transcribe, feature extraction, embedding) \
            run in later pipeline steps.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the source file.")
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "description": .string("Asset kind. Plan 1 supports captured_video, captured_audio."),
                    "enum": .array(LibraryAssetKind.allCases.map { .string($0.rawValue) })
                ]),
                "provenance": .object([
                    "type": .string("object"),
                    "description": .string("Optional key/value provenance (e.g., shoot_id, camera, notes).")
                ])
            ]),
            "required": .array([.string("path"), .string("kind")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        store: LibraryAssetStore
    ) async -> CallTool.Result {
        guard let rawPath = arguments?["path"]?.stringValue, !rawPath.isEmpty else {
            return errorResult("Missing required argument: path")
        }
        guard let rawKind = arguments?["kind"]?.stringValue, !rawKind.isEmpty else {
            return errorResult("Missing required argument: kind")
        }
        guard let kind = LibraryAssetKind(rawValue: rawKind) else {
            let supported = LibraryAssetKind.allCases.map(\.rawValue).joined(separator: ", ")
            return errorResult("Unknown kind '\(rawKind)'. Valid kinds: \(supported)")
        }
        guard kind.supportedInPlanOne else {
            return errorResult("""
                Kind '\(kind.rawValue)' is not yet supported by reelabs_ingest. \
                Plan 1 ships captured_video and captured_audio only. Other kinds \
                require their generation/fetch primitives (Breadth phase).
                """)
        }

        let path = resolvePath(rawPath)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return errorResult("File not found: \(path)")
        }

        return await performRegister(kind: kind, url: url, arguments: arguments, store: store)
    }

    static func performRegister(
        kind: LibraryAssetKind,
        url: URL,
        arguments: [String: Value]?,
        store: LibraryAssetStore
    ) async -> CallTool.Result {
        do {
            let contentHash = try ContentHasher.sha256(fileAt: url)

            // Dedup: if we've already registered this hash, return the existing record.
            if let existing = try store.getByContentHash(contentHash) {
                return successResult([
                    "library_asset_id": existing.id,
                    "kind": existing.kind.rawValue,
                    "path": existing.path ?? NSNull(),
                    "content_hash": contentHash,
                    "duration_s": existing.durationS ?? NSNull(),
                    "already_registered": true,
                    "message": "Content hash already registered; returning existing record."
                ])
            }

            // Probe for captured video/audio — VideoProbe handles both.
            let probe = try await VideoProbe.probe(path: url.path)

            let provenance = extractProvenance(arguments)
            let sourceMetadata: [String: String] = [
                "filename": probe.filename,
                "file_size_bytes": String(probe.fileSizeBytes)
            ]

            let record = try store.register(
                kind: kind,
                path: url.path,
                contentHash: contentHash,
                durationS: probe.duration,
                width: probe.width,
                height: probe.height,
                fps: probe.fps,
                codec: probe.codec,
                hasAudio: probe.hasAudio,
                provenance: provenance,
                sourceMetadata: sourceMetadata
            )

            return successResult([
                "library_asset_id": record.id,
                "kind": record.kind.rawValue,
                "path": record.path ?? NSNull(),
                "content_hash": contentHash,
                "duration_s": record.durationS ?? NSNull(),
                "width": record.width ?? NSNull(),
                "height": record.height ?? NSNull(),
                "fps": record.fps ?? NSNull(),
                "codec": record.codec ?? NSNull(),
                "has_audio": record.hasAudio ?? NSNull(),
                "already_registered": false
            ])
        } catch {
            return errorResult("Ingest failed: \(error.localizedDescription)")
        }
    }

    private static func extractProvenance(_ arguments: [String: Value]?) -> [String: String]? {
        guard let prov = arguments?["provenance"] else { return nil }
        guard case .object(let dict) = prov else { return nil }
        var out: [String: String] = [:]
        for (key, value) in dict {
            if let s = value.stringValue { out[key] = s }
        }
        return out.isEmpty ? nil : out
    }

    private static func successResult(_ payload: [String: Any]) -> CallTool.Result {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return errorResult("JSON serialization failed: \(error.localizedDescription)")
        }
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

// resolvePath is defined in Tools/Helpers.swift and expands `~`.
