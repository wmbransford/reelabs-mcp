import Foundation
import MCP

package enum PresetTool {
    package static let tool = Tool(
        name: "reelabs_preset",
        description: "Manage reusable presets for captions, render settings, and audio. Actions: save (name, type, config), get (name), list (type?), delete (name).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("Action: save, get, list, delete"),
                    "enum": .array([.string("save"), .string("get"), .string("list"), .string("delete")])
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Preset name (for save, get, delete)")
                ]),
                "type": .object([
                    "type": .string("string"),
                    "description": .string("Preset type: caption, render, audio (for save, list filter)"),
                    "enum": .array([.string("caption"), .string("render"), .string("audio")])
                ]),
                "config": .object([
                    "type": .string("object"),
                    "description": .string("Preset configuration object (for save)")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Preset description (for save)")
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    package static func handle(arguments: [String: Value]?, store: PresetStore) -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: action", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            switch action {
            case "save":
                guard let name = arguments?["name"]?.stringValue,
                      let type = arguments?["type"]?.stringValue,
                      let config = arguments?["config"] else {
                    return .init(content: [.text(text: "Missing required arguments: name, type, config", annotations: nil, _meta: nil)], isError: true)
                }
                let configData = try JSONSerialization.data(withJSONObject: config.toJSONObject(), options: [.sortedKeys])
                let configJson = String(data: configData, encoding: .utf8) ?? "{}"
                let desc = arguments?["description"]?.stringValue
                let preset = try store.upsert(name: name, type: type, configJson: configJson, description: desc)
                return .init(content: [.text(text: encode(preset), annotations: nil, _meta: nil)], isError: false)

            case "get":
                guard let name = arguments?["name"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: name", annotations: nil, _meta: nil)], isError: true)
                }
                if let preset = try store.get(name: name) {
                    return .init(content: [.text(text: encode(preset), annotations: nil, _meta: nil)], isError: false)
                }
                return .init(content: [.text(text: "Preset not found: \(name)", annotations: nil, _meta: nil)], isError: true)

            case "list":
                let type = arguments?["type"]?.stringValue
                let presets = try store.list(type: type)
                return .init(content: [.text(text: encode(presets), annotations: nil, _meta: nil)], isError: false)

            case "delete":
                guard let name = arguments?["name"]?.stringValue else {
                    return .init(content: [.text(text: "Missing required argument: name", annotations: nil, _meta: nil)], isError: true)
                }
                let deleted = try store.delete(name: name)
                return .init(content: [.text(text: deleted ? "Preset '\(name)' deleted" : "Preset not found: \(name)", annotations: nil, _meta: nil)], isError: !deleted)

            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: save, get, list, delete", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
