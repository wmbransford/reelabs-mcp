import Foundation
import MCP

package enum ProjectTool {
    package static let tool = Tool(
        name: "reelabs_project",
        description: "Manage projects. Actions: create (name, description?), list (status?), get (slug), archive (slug), delete (slug). Projects are folders under data/projects/ identified by slugs derived from the project name.",
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
                "slug": .object([
                    "type": .string("string"),
                    "description": .string("Project slug (for get, archive, delete)")
                ]),
                "status": .object([
                    "type": .string("string"),
                    "description": .string("Filter by status: active, archived (for list)")
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    package static func handle(arguments: [String: Value]?, store: ProjectStore) -> CallTool.Result {
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
                let project = try store.create(name: name, description: desc)
                return .init(content: [.text(text: encode(project), annotations: nil, _meta: nil)], isError: false)

            case "list":
                let status = arguments?["status"]?.stringValue
                let projects = try store.list(status: status)
                return .init(content: [.text(text: encode(projects), annotations: nil, _meta: nil)], isError: false)

            case "get":
                guard let slug = arguments?["slug"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: slug", annotations: nil, _meta: nil)], isError: true)
                }
                if let project = try store.get(slug: slug) {
                    return .init(content: [.text(text: encode(project), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Project not found: \(slug)", annotations: nil, _meta: nil)], isError: true)

            case "archive":
                guard let slug = arguments?["slug"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: slug", annotations: nil, _meta: nil)], isError: true)
                }
                if let project = try store.archive(slug: slug) {
                    return .init(content: [.text(text: encode(project), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Project not found: \(slug)", annotations: nil, _meta: nil)], isError: true)

            case "delete":
                guard let slug = arguments?["slug"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: slug", annotations: nil, _meta: nil)], isError: true)
                }
                let deleted = try store.delete(slug: slug)
                return .init(content: [.text(text: deleted ? "Project '\(slug)' deleted" : "Project not found: \(slug)", annotations: nil, _meta: nil)], isError: !deleted)

            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: create, list, get, archive, delete", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
