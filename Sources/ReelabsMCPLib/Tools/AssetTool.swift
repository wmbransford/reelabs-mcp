import Foundation
import MCP

package enum AssetTool {
    package static let tool = Tool(
        name: "reelabs_asset",
        description: "Manage project assets (source video files). Actions: add (project, path — auto-probes metadata), list (project), get (project, source), tag (project, source, tags[]), delete (project, source). Source slugs are derived from the filename (e.g. C0048.MP4 → c0048).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("Action: add, list, get, tag, delete"),
                    "enum": .array([.string("add"), .string("list"), .string("get"), .string("tag"), .string("delete")])
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string("Project slug")
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute file path (for add)")
                ]),
                "source": .object([
                    "type": .string("string"),
                    "description": .string("Source slug (for get, tag, delete)")
                ]),
                "tags": .object([
                    "type": .string("array"),
                    "description": .string("Tags to set (for tag action)"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        assetStore: AssetStore,
        projectStore: ProjectStore
    ) async -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: action", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            switch action {
            case "add":
                guard let project = arguments?["project"]?.stringValue,
                      let path = arguments?["path"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required arguments: project, path", annotations: nil, _meta: nil)], isError: true)
                }

                guard FileManager.default.fileExists(atPath: path) else {
                    return .init(content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)], isError: true)
                }

                // Ensure project exists (auto-create with slug if needed)
                _ = try projectStore.createWithSlug(slug: project)

                let url = URL(fileURLWithPath: path)
                let sourceSlug = DataPaths.deriveSourceSlug(fromSourcePath: path)

                var record = AssetRecord(
                    slug: sourceSlug,
                    filename: url.lastPathComponent,
                    filePath: path
                )

                // Auto-probe metadata
                do {
                    let probe = try await VideoProbe.probe(path: path)
                    record.durationSeconds = Double(probe.durationMs) / 1000.0
                    record.width = probe.width
                    record.height = probe.height
                    record.fps = probe.fps
                    record.codec = probe.codec
                    record.hasAudio = probe.hasAudio
                    record.fileSizeBytes = probe.fileSizeBytes
                } catch {
                    // Still add the asset even if probe fails
                }

                let saved = try assetStore.upsert(project: project, source: sourceSlug, record: record)
                return .init(content: [.text(text: encode(saved), annotations: nil, _meta: nil)], isError: false)

            case "list":
                guard let project = arguments?["project"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: project", annotations: nil, _meta: nil)], isError: true)
                }
                let assets = try assetStore.list(project: project)
                return .init(content: [.text(text: encode(assets), annotations: nil, _meta: nil)], isError: false)

            case "get":
                guard let project = arguments?["project"]?.stringValue,
                      let source = arguments?["source"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required arguments: project, source", annotations: nil, _meta: nil)], isError: true)
                }
                if let asset = try assetStore.get(project: project, source: source) {
                    return .init(content: [.text(text: encode(asset), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Asset not found: \(project)/\(source)", annotations: nil, _meta: nil)], isError: true)

            case "tag":
                guard let project = arguments?["project"]?.stringValue,
                      let source = arguments?["source"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required arguments: project, source", annotations: nil, _meta: nil)], isError: true)
                }
                let tags: [String]
                if let tagArray = arguments?["tags"]?.arrayValue {
                    tags = tagArray.compactMap { $0.stringValue }
                } else {
                    tags = []
                }
                if let asset = try assetStore.updateTags(project: project, source: source, tags: tags) {
                    return .init(content: [.text(text: encode(asset), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Asset not found: \(project)/\(source)", annotations: nil, _meta: nil)], isError: true)

            case "delete":
                guard let project = arguments?["project"]?.stringValue,
                      let source = arguments?["source"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required arguments: project, source", annotations: nil, _meta: nil)], isError: true)
                }
                let deleted = try assetStore.delete(project: project, source: source)
                return .init(content: [.text(text: deleted ? "Asset \(project)/\(source) deleted" : "Asset not found: \(project)/\(source)", annotations: nil, _meta: nil)], isError: !deleted)

            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: add, list, get, tag, delete", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
