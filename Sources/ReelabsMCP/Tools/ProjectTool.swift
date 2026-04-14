import Foundation
import MCP

enum ProjectTool {
    static let tool = Tool(
        name: "reelabs_project",
        description: "Manage projects. Actions: create (name, description?), list (status?), get (id), archive (id), delete (id).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("Action to perform: create, list, get, archive, delete"),
                    "enum": .array([.string("create"), .string("list"), .string("get"), .string("archive"), .string("delete")])
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Project name (for create)")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Project description (for create)")
                ]),
                "id": .object([
                    "type": .string("integer"),
                    "description": .string("Project ID (for get, archive, delete)")
                ]),
                "status": .object([
                    "type": .string("string"),
                    "description": .string("Filter by status: active, archived (for list)")
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    static func handle(arguments: [String: Value]?, repo: ProjectRepository) -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: action", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            switch action {
            case "create":
                guard let name = arguments?["name"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: name", annotations: nil, _meta: nil)], isError: true)
                }
                let desc = arguments?["description"]?.stringValue
                let project = try repo.create(name: name, description: desc)
                return .init(content: [.text(text: encode(project), annotations: nil, _meta: nil)], isError: false)

            case "list":
                let status = arguments?["status"]?.stringValue
                let projects = try repo.list(status: status)
                return .init(content: [.text(text: encode(projects), annotations: nil, _meta: nil)], isError: false)

            case "get":
                guard let id = extractInt64(arguments?["id"]) else {
                    return .init(content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)], isError: true)
                }
                if let project = try repo.get(id: id) {
                    return .init(content: [.text(text: encode(project), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Project not found: \(id)", annotations: nil, _meta: nil)], isError: true)

            case "archive":
                guard let id = extractInt64(arguments?["id"]) else {
                    return .init(content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)], isError: true)
                }
                if let project = try repo.archive(id: id) {
                    return .init(content: [.text(text: encode(project), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Project not found: \(id)", annotations: nil, _meta: nil)], isError: true)

            case "delete":
                guard let id = extractInt64(arguments?["id"]) else {
                    return .init(content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)], isError: true)
                }
                let deleted = try repo.delete(id: id)
                return .init(content: [.text(text: deleted ? "Project \(id) deleted" : "Project not found: \(id)", annotations: nil, _meta: nil)], isError: !deleted)

            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: create, list, get, archive, delete", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
