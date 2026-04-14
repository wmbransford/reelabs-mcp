import Foundation
import MCP

enum ProbeTool {
    static let tool = Tool(
        name: "reelabs_probe",
        description: "Inspect a video file — returns duration, resolution, fps, codecs, audio tracks, file size. Use this before adding assets or building render specs.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the video file")
                ])
            ]),
            "required": .array([.string("path")])
        ])
    )

    static func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: path", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let result = try await VideoProbe.probe(path: path)
            let json: [String: Any] = [
                "filename": result.filename,
                "duration": round(result.duration * 1000) / 1000,
                "duration_ms": result.durationMs,
                "width": result.width,
                "height": result.height,
                "fps": round(result.fps * 100) / 100,
                "codec": result.codec,
                "has_audio": result.hasAudio,
                "file_size_bytes": result.fileSizeBytes,
                "file_size_mb": round(Double(result.fileSizeBytes) / 1_048_576 * 10) / 10
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Probe failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
