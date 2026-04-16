import Foundation
import MCP

package enum GraphicTool {
    package static let tool = Tool(
        name: "reelabs_graphic",
        description: "Render HTML/CSS to a PNG image for use as overlays, thumbnails, or title cards. Supports transparent backgrounds.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "html": .object([
                    "type": .string("string"),
                    "description": .string("HTML string to render. Inline all CSS — no external resources.")
                ]),
                "width": .object([
                    "type": .string("integer"),
                    "description": .string("Output width in pixels (max 7680)")
                ]),
                "height": .object([
                    "type": .string("integer"),
                    "description": .string("Output height in pixels (max 7680)")
                ]),
                "output_path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path for the output PNG. Defaults to ./Generated Graphics/{uuid}.png")
                ]),
                "timeout": .object([
                    "type": .string("number"),
                    "description": .string("Render timeout in seconds (default 10)")
                ])
            ]),
            "required": .array([.string("html"), .string("width"), .string("height")])
        ])
    )

    package static func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard let html = arguments?["html"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: html", annotations: nil, _meta: nil)], isError: true)
        }
        guard let width = arguments?["width"]?.intValue else {
            return .init(content: [.text(text: "Missing required argument: width", annotations: nil, _meta: nil)], isError: true)
        }
        guard let height = arguments?["height"]?.intValue else {
            return .init(content: [.text(text: "Missing required argument: height", annotations: nil, _meta: nil)], isError: true)
        }

        guard width > 0, width <= 7680 else {
            return .init(content: [.text(text: "width must be between 1 and 7680", annotations: nil, _meta: nil)], isError: true)
        }
        guard height > 0, height <= 7680 else {
            return .init(content: [.text(text: "height must be between 1 and 7680", annotations: nil, _meta: nil)], isError: true)
        }

        let timeout = extractDouble(arguments?["timeout"]) ?? 10.0

        let outputPath: String
        if let provided = arguments?["output_path"]?.stringValue {
            outputPath = provided
        } else {
            let dir = FileManager.default.currentDirectoryPath + "/Generated Graphics"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let uuid8 = String(UUID().uuidString.prefix(8))
            outputPath = dir + "/\(uuid8).png"
        }

        let outputURL = URL(fileURLWithPath: outputPath)

        // Ensure parent directory exists
        let parentDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        do {
            let fileSize = try await HTMLRenderer.render(
                html: html, width: width, height: height,
                outputURL: outputURL, timeout: timeout
            )

            let json: [String: Any] = [
                "output_path": outputPath,
                "width": width,
                "height": height,
                "file_size_bytes": fileSize,
                "file_size_kb": round(Double(fileSize) / 1024.0 * 10) / 10
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Graphic render failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
