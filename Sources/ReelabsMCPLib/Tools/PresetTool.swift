import Foundation
import MCP

package enum PresetTool {
    package static let tool = Tool(
        name: "reelabs_preset",
        description: "Manage reusable presets. Actions: save (category, name, config, description?), get (category, name), list (category?), delete (category, name). Built-in categories: captions, framing, overlays, transitions, audio. See reference/{category}.md for each category's field shape.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("save, get, list, delete"),
                    "enum": .array([.string("save"), .string("get"), .string("list"), .string("delete")])
                ]),
                "category": .object([
                    "type": .string("string"),
                    "description": .string("Preset category: captions, framing, overlays, transitions, audio. Required for save, get, delete. Optional for list (omit to list all).")
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Preset name (required for save, get, delete)")
                ]),
                "config": .object([
                    "type": .string("object"),
                    "description": .string("Flat key/value object with the preset's config fields (required for save). See reference/{category}.md for the valid field set.")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("One-line description (optional, for save)")
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    package static func handle(arguments: [String: Value]?, store: PresetStore) -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return errorResult("Missing required argument: action.")
        }

        do {
            switch action {
            case "save":
                guard let category = arguments?["category"]?.stringValue else {
                    return errorResult("save requires 'category'.")
                }
                guard let name = arguments?["name"]?.stringValue else {
                    return errorResult("save requires 'name'.")
                }
                guard let configValue = arguments?["config"] else {
                    return errorResult("save requires 'config' (flat key/value object).")
                }
                let configDict = try valueToDictionary(configValue)
                let description = arguments?["description"]?.stringValue
                try store.save(category: category, name: name, config: configDict, description: description)
                let response: [String: Any] = [
                    "status": "saved",
                    "category": category,
                    "name": name,
                    "path": "presets/\(category)/\(name).md"
                ]
                let data = try safeJSONData(from: response)
                return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)

            case "get":
                guard let category = arguments?["category"]?.stringValue else {
                    return errorResult("get requires 'category'.")
                }
                guard let name = arguments?["name"]?.stringValue else {
                    return errorResult("get requires 'name'.")
                }
                guard let raw = try store.getRaw(category: category, name: name) else {
                    return errorResult("Preset not found: \(category)/\(name).")
                }
                return .init(content: [.text(text: raw, annotations: nil, _meta: nil)], isError: false)

            case "list":
                let category = arguments?["category"]?.stringValue
                let summaries = try store.list(category: category)
                let summariesJSON: [[String: Any]] = summaries.map { s in
                    var dict: [String: Any] = ["category": s.category, "name": s.name]
                    if let d = s.description { dict["description"] = d }
                    return dict
                }
                let response: [String: Any] = [
                    "count": summaries.count,
                    "presets": summariesJSON
                ]
                let data = try safeJSONData(from: response)
                return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)

            case "delete":
                guard let category = arguments?["category"]?.stringValue else {
                    return errorResult("delete requires 'category'.")
                }
                guard let name = arguments?["name"]?.stringValue else {
                    return errorResult("delete requires 'name'.")
                }
                let deleted = try store.delete(category: category, name: name)
                if deleted {
                    return .init(content: [.text(text: "Deleted preset \(category)/\(name).", annotations: nil, _meta: nil)], isError: false)
                }
                return errorResult("Preset not found: \(category)/\(name).")

            default:
                return errorResult("Unknown action: \(action). Use save, get, list, delete.")
            }
        } catch {
            return errorResult("Preset error: \(error.localizedDescription)")
        }
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    /// Convert an MCP `Value` (expected to be an object) into a `[String: Any]` dict
    /// suitable for YAML serialization. Bubbles up an error if the value isn't an object.
    private static func valueToDictionary(_ value: Value) throws -> [String: Any] {
        let json = value.toJSONObject()
        guard let dict = json as? [String: Any] else {
            throw NSError(
                domain: "PresetTool", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "'config' must be an object (flat key/value pairs)"]
            )
        }
        return dict
    }
}
