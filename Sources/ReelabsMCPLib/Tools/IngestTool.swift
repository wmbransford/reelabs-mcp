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

    // Register stage is implemented in Task 12 (below).
    // This stub returns an error so tests of the scaffolding still pass
    // until the full implementation lands.
    static func performRegister(
        kind: LibraryAssetKind,
        url: URL,
        arguments: [String: Value]?,
        store: LibraryAssetStore
    ) async -> CallTool.Result {
        errorResult("register stage not yet implemented — awaiting Task 12")
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

// resolvePath is defined in Tools/Helpers.swift and expands `~`.
