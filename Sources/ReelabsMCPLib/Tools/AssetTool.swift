import Foundation
import MCP

package enum AssetTool {
    package static let tool = Tool(
        name: "reelabs_asset",
        description: "Manage project assets. Actions: add (project_id, path — auto-probes metadata), list (project_id), get (id), tag (id, tags[]), delete (id).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("Action: add, list, get, tag, delete"),
                    "enum": .array([.string("add"), .string("list"), .string("get"), .string("tag"), .string("delete")])
                ]),
                "project_id": .object([
                    "type": .string("integer"),
                    "description": .string("Project ID (for add, list)")
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute file path (for add)")
                ]),
                "id": .object([
                    "type": .string("integer"),
                    "description": .string("Asset ID (for get, tag, delete)")
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

    package static func handle(arguments: [String: Value]?, assetRepo: AssetRepository) async -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: action", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            switch action {
            case "add":
                guard let projectId = extractInt64(arguments?["project_id"]),
                      let path = arguments?["path"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required arguments: project_id, path", annotations: nil, _meta: nil)], isError: true)
                }

                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else {
                    return .init(content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)], isError: true)
                }

                var asset = Asset(projectId: projectId, filePath: path, filename: url.lastPathComponent)

                // Auto-probe metadata
                do {
                    let probe = try await VideoProbe.probe(path: path)
                    asset.durationMs = probe.durationMs
                    asset.width = probe.width
                    asset.height = probe.height
                    asset.fps = probe.fps
                    asset.codec = probe.codec
                    asset.hasAudio = probe.hasAudio
                    asset.fileSizeBytes = probe.fileSizeBytes
                } catch {
                    // Still add the asset even if probe fails
                }

                let saved = try assetRepo.create(asset)
                return .init(content: [.text(text: encode(saved), annotations: nil, _meta: nil)], isError: false)

            case "list":
                guard let projectId = extractInt64(arguments?["project_id"]) else {
                    return .init(content: [.text(text: "Missing required argument: project_id", annotations: nil, _meta: nil)], isError: true)
                }
                let assets = try assetRepo.list(projectId: projectId)
                return .init(content: [.text(text: encode(assets), annotations: nil, _meta: nil)], isError: false)

            case "get":
                guard let id = extractInt64(arguments?["id"]) else {
                    return .init(content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)], isError: true)
                }
                if let asset = try assetRepo.get(id: id) {
                    return .init(content: [.text(text: encode(asset), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Asset not found: \(id)", annotations: nil, _meta: nil)], isError: true)

            case "tag":
                guard let id = extractInt64(arguments?["id"]) else {
                    return .init(content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)], isError: true)
                }
                let tags: [String]
                if let tagArray = arguments?["tags"]?.arrayValue {
                    tags = tagArray.compactMap { $0.stringValue }
                } else {
                    tags = []
                }
                try assetRepo.updateTags(id: id, tags: tags)
                if let asset = try assetRepo.get(id: id) {
                    return .init(content: [.text(text: encode(asset), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Asset not found: \(id)", annotations: nil, _meta: nil)], isError: true)

            case "delete":
                guard let id = extractInt64(arguments?["id"]) else {
                    return .init(content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)], isError: true)
                }
                let deleted = try assetRepo.delete(id: id)
                return .init(content: [.text(text: deleted ? "Asset \(id) deleted" : "Asset not found: \(id)", annotations: nil, _meta: nil)], isError: !deleted)

            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: add, list, get, tag, delete", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
