import Foundation
import MCP
import GRDB

package enum SearchTool {
    package static let tool = Tool(
        name: "reelabs_search",
        description: "Full-text search across projects, assets, transcripts, and renders. Uses FTS5 for transcript search with BM25 ranking.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query text")
                ]),
                "scope": .object([
                    "type": .string("string"),
                    "description": .string("Search scope: all, transcripts, projects, assets, renders (default: all)"),
                    "enum": .array([.string("all"), .string("transcripts"), .string("projects"), .string("assets"), .string("renders")])
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max results per category (default: 20)")
                ])
            ]),
            "required": .array([.string("query")])
        ])
    )

    /// Sanitize a query for FTS5 MATCH by quoting each word.
    /// Strips characters that FTS5 treats as syntax and wraps terms in double quotes.
    private static func sanitizeFTS5Query(_ query: String) -> String {
        let words = query.components(separatedBy: .whitespacesAndNewlines)
            .map { word in
                // Remove FTS5 special chars
                let cleaned = word.filter { c in
                    c.isLetter || c.isNumber
                }
                return cleaned
            }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "\"\"" }
        // Quote each word so FTS5 treats them as literals
        return words.map { "\"\($0)\"" }.joined(separator: " ")
    }

    package static func handle(arguments: [String: Value]?, dbPool: DatabasePool) -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return .init(content: [.text(text: "Missing required argument: query", annotations: nil, _meta: nil)], isError: true)
        }

        let scope = arguments?["scope"]?.stringValue ?? "all"
        let limit = arguments?["limit"]?.intValue ?? 20

        do {
            var results: [String: Any] = [:]
            let likePattern = "%\(query)%"
            let ftsQuery = sanitizeFTS5Query(query)

            try dbPool.read { db in
                // Search transcripts (FTS5)
                if scope == "all" || scope == "transcripts" {
                    let transcriptRows = try Row.fetchAll(db, sql: """
                        SELECT t.id, t.sourcePath, t.fullText, t.wordCount, t.durationSeconds, t.createdAt
                        FROM transcripts t
                        JOIN transcripts_fts fts ON fts.rowid = t.id
                        WHERE transcripts_fts MATCH ?
                        ORDER BY bm25(transcripts_fts)
                        LIMIT ?
                        """, arguments: [ftsQuery, limit])
                    results["transcripts"] = transcriptRows.map { row -> [String: Any] in
                        [
                            "id": row["id"] as Int64? ?? 0,
                            "source_path": row["sourcePath"] as String? ?? "",
                            "text_preview": String((row["fullText"] as String? ?? "").prefix(200)),
                            "word_count": row["wordCount"] as Int? ?? 0,
                            "duration_seconds": row["durationSeconds"] as Double? ?? 0
                        ]
                    }
                }

                // Search projects
                if scope == "all" || scope == "projects" {
                    let projectRows = try Row.fetchAll(db, sql: """
                        SELECT * FROM projects WHERE name LIKE ? OR description LIKE ? LIMIT ?
                        """, arguments: [likePattern, likePattern, limit])
                    results["projects"] = projectRows.map { row -> [String: Any] in
                        [
                            "id": row["id"] as Int64? ?? 0,
                            "name": row["name"] as String? ?? "",
                            "description": row["description"] as String? ?? "",
                            "status": row["status"] as String? ?? ""
                        ]
                    }
                }

                // Search assets
                if scope == "all" || scope == "assets" {
                    let assetRows = try Row.fetchAll(db, sql: """
                        SELECT * FROM assets WHERE filename LIKE ? OR tags LIKE ? LIMIT ?
                        """, arguments: [likePattern, likePattern, limit])
                    results["assets"] = assetRows.map { row -> [String: Any] in
                        [
                            "id": row["id"] as Int64? ?? 0,
                            "project_id": row["projectId"] as Int64? ?? 0,
                            "filename": row["filename"] as String? ?? "",
                            "file_path": row["filePath"] as String? ?? ""
                        ]
                    }
                }

                // Search renders
                if scope == "all" || scope == "renders" {
                    let renderRows = try Row.fetchAll(db, sql: """
                        SELECT * FROM renders WHERE specJson LIKE ? OR outputPath LIKE ? ORDER BY createdAt DESC LIMIT ?
                        """, arguments: [likePattern, likePattern, limit])
                    results["renders"] = renderRows.map { row -> [String: Any] in
                        [
                            "id": row["id"] as Int64? ?? 0,
                            "output_path": row["outputPath"] as String? ?? "",
                            "status": row["status"] as String? ?? "",
                            "duration_seconds": row["durationSeconds"] as Double? ?? 0,
                            "created_at": row["createdAt"] as String? ?? ""
                        ]
                    }
                }
            }

            let responseData = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: responseData, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Search error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
