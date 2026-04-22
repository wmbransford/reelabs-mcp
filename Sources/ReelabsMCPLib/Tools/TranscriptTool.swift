import Foundation
import MCP

/// Manage transcripts — list existing ones, rehydrate a prior transcript's compact view.
/// Closes the gap where agents who lost context would otherwise need to re-run Chirp.
package enum TranscriptTool {
    package static let tool = Tool(
        name: "reelabs_transcript",
        description: "Manage existing transcripts. Actions: list (across all projects), get (rehydrate a prior transcript's compact view), search (FTS5-backed full-text search within a project — returns matching source slugs). IDs are compound \"project/source\" strings (e.g. \"opus-47-video/c0048\").",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("Action: list, get, search"),
                    "enum": .array([.string("list"), .string("get"), .string("search")])
                ]),
                "transcript_id": .object([
                    "type": .string("string"),
                    "description": .string("Compound ID 'project/source' (for get)")
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string("Project slug (filters list; required for search)")
                ]),
                "query": .object([
                    "type": .string("string"),
                    "description": .string("FTS5 query string (for search)")
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        store: TranscriptStore
    ) -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: action", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            switch action {
            case "list":
                let filter = arguments?["project"]?.stringValue
                let all = try store.listAll()
                let results = all.filter { filter == nil || $0.project == filter }.map { entry -> [String: Any] in
                    [
                        "transcript_id": "\(entry.project)/\(entry.source)",
                        "project": entry.project,
                        "source": entry.source,
                        "source_path": entry.record.sourcePath,
                        "duration_seconds": round(entry.record.durationSeconds * 100) / 100,
                        "word_count": entry.record.wordCount,
                        "language": entry.record.language,
                        "created": entry.record.created
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: ["transcripts": results], options: [.prettyPrinted, .sortedKeys])
                return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)

            case "get":
                guard let id = arguments?["transcript_id"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: transcript_id", annotations: nil, _meta: nil)], isError: true)
                }
                guard let parts = DataPaths.splitCompoundId(id) else {
                    return .init(content: [.text(text: "Invalid transcript_id. Expected 'project/source' format.", annotations: nil, _meta: nil)], isError: true)
                }
                guard let record = try store.getRecord(project: parts.project, source: parts.source) else {
                    return .init(content: [.text(text: "Transcript not found: \(id)", annotations: nil, _meta: nil)], isError: true)
                }
                guard let mdFile = try store.getMarkdown(project: parts.project, source: parts.source) else {
                    return .init(content: [.text(text: "Transcript markdown missing: \(id)", annotations: nil, _meta: nil)], isError: true)
                }
                let response: [String: Any] = [
                    "transcript_id": id,
                    "project": parts.project,
                    "source": parts.source,
                    "source_path": record.sourcePath,
                    "duration_seconds": round(record.durationSeconds * 100) / 100,
                    "word_count": record.wordCount,
                    "language": record.language,
                    "mode": record.mode,
                    "transcript_markdown": mdFile.body
                ]
                let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
                return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)

            case "search":
                guard let project = arguments?["project"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: project", annotations: nil, _meta: nil)], isError: true)
                }
                guard let query = arguments?["query"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: query", annotations: nil, _meta: nil)], isError: true)
                }
                let hits = try store.fullTextSearch(project: project, query: query)
                let response: [String: Any] = [
                    "project": project,
                    "query": query,
                    "matches": hits
                ]
                let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
                return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)

            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: list, get, search", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
