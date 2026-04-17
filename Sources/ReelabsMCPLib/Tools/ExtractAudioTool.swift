@preconcurrency import AVFoundation
import Foundation
import MCP

package enum ExtractAudioTool {
    package static let tool = Tool(
        name: "reelabs_extract_audio",
        description: "Extract the audio track from a video file as an M4A (AAC passthrough — no re-encoding, no quality loss). Use when handing audio to an external editor for cleanup, voiceover work, or podcasting.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the input video file")
                ]),
                "output_path": .object([
                    "type": .string("string"),
                    "description": .string("Optional absolute path for the output .m4a. Defaults to the same directory as the input with a .m4a extension.")
                ])
            ]),
            "required": .array([.string("path")])
        ])
    )

    package static func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: path", annotations: nil, _meta: nil)], isError: true)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .init(content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)], isError: true)
        }

        let inputURL = URL(fileURLWithPath: path)

        // Determine output path. Default: next to input, same basename, .m4a extension.
        let outputURL: URL
        if let outputPath = arguments?["output_path"]?.stringValue, !outputPath.isEmpty {
            outputURL = URL(fileURLWithPath: outputPath)
        } else {
            outputURL = inputURL.deletingPathExtension().appendingPathExtension("m4a")
        }

        // Ensure output directory exists.
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            return .init(content: [.text(text: "Failed to create output directory \(outputDir.path): \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let start = Date()
            try await AudioExtractor.exportM4A(from: inputURL, to: outputURL)
            let elapsed = Date().timeIntervalSince(start)

            let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = (attrs[.size] as? Int64) ?? 0

            let asset = AVURLAsset(url: outputURL)
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)

            let response: [String: Any] = [
                "output_path": outputURL.path,
                "duration_seconds": round(durationSeconds * 100) / 100,
                "file_size_bytes": fileSize,
                "file_size_mb": round(Double(fileSize) / 1_048_576 * 10) / 10,
                "format": "m4a",
                "elapsed_seconds": round(elapsed * 100) / 100
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Audio extraction failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
