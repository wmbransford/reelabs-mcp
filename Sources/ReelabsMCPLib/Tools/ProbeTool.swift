import Foundation
import MCP

package enum ProbeTool {
    package static let tool = Tool(
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

    package static func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard let rawPath = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: path", annotations: nil, _meta: nil)], isError: true)
        }
        let path = resolvePath(rawPath)

        do {
            let result = try await VideoProbe.probe(path: path)
            let aspectPreview = computeAspectPreview(width: result.width, height: result.height)
            let json: [String: Any] = [
                "filename": result.filename,
                "duration": round(result.duration * 1000) / 1000,
                "duration_ms": result.durationMs,
                "width": result.width,
                "height": result.height,
                "aspect_ratio": aspectPreview.sourceLabel,
                "fps": round(result.fps * 100) / 100,
                "codec": result.codec,
                "has_audio": result.hasAudio,
                "file_size_bytes": result.fileSizeBytes,
                "file_size_mb": round(Double(result.fileSizeBytes) / 1_048_576 * 10) / 10,
                "output_resolutions": aspectPreview.outputs
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Probe failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    /// Preview the output dimensions the renderer would produce for each common aspect ratio,
    /// given this source's width/height. Matches the crop-preserving-resolution logic in
    /// CompositionBuilder (see its aspectRatio handling).
    private static func computeAspectPreview(width: Int, height: Int) -> (sourceLabel: String, outputs: [[String: Any]]) {
        let w = Double(width)
        let h = Double(height)
        let sourceRatio = h > 0 ? w / h : 0
        let sourceLabel = labelForRatio(sourceRatio)

        let targets: [(name: String, ratio: Double)] = [
            ("16:9", 16.0 / 9.0),
            ("9:16", 9.0 / 16.0),
            ("1:1", 1.0),
            ("4:5", 4.0 / 5.0)
        ]

        let outputs: [[String: Any]] = targets.map { target in
            let (outW, outH) = cropToAspect(sourceW: w, sourceH: h, targetRatio: target.ratio)
            let cropNote: String
            if abs(sourceRatio - target.ratio) < 0.01 {
                cropNote = "matches source — no crop"
            } else if sourceRatio > target.ratio {
                let pct = Int(round((1.0 - (outW / w)) * 100))
                cropNote = "crops \(pct)% from sides"
            } else {
                let pct = Int(round((1.0 - (outH / h)) * 100))
                cropNote = "crops \(pct)% from top/bottom"
            }
            return [
                "aspect_ratio": target.name,
                "width": Int(outW),
                "height": Int(outH),
                "note": cropNote
            ]
        }

        return (sourceLabel, outputs)
    }

    /// Apply the CompositionBuilder crop formula to preview output dimensions.
    private static func cropToAspect(sourceW: Double, sourceH: Double, targetRatio: Double) -> (Double, Double) {
        let sourceRatio = sourceW / sourceH
        if sourceRatio > targetRatio {
            let newW = Double(Int(sourceH * targetRatio / 2) * 2)
            return (newW, sourceH)
        } else {
            let newH = Double(Int(sourceW / targetRatio / 2) * 2)
            return (sourceW, newH)
        }
    }

    /// Map a raw aspect ratio float to a human-readable label.
    private static func labelForRatio(_ r: Double) -> String {
        let known: [(String, Double)] = [
            ("16:9", 16.0 / 9.0),
            ("9:16", 9.0 / 16.0),
            ("1:1", 1.0),
            ("4:5", 4.0 / 5.0),
            ("4:3", 4.0 / 3.0),
            ("3:4", 3.0 / 4.0),
            ("21:9", 21.0 / 9.0)
        ]
        for (name, ratio) in known where abs(r - ratio) < 0.01 {
            return name
        }
        return String(format: "%.2f:1", r)
    }
}
