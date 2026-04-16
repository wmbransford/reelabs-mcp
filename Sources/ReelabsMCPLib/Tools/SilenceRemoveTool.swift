import Foundation
import MCP

package enum SilenceRemoveTool {
    package static let tool = Tool(
        name: "reelabs_silence_remove",
        description: "Analyze a transcript and return segments that skip silent gaps. Returns ready-to-use RenderSpec segments with padding. transcript_id is a compound 'project/source' string.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "transcript_id": .object([
                    "type": .string("string"),
                    "description": .string("Compound 'project/source' ID (from reelabs_transcribe)")
                ]),
                "gap_threshold": .object([
                    "type": .string("number"),
                    "description": .string("Remove gaps >= this many seconds (default: 0.4)")
                ]),
                "padding": .object([
                    "type": .string("number"),
                    "description": .string("Seconds of padding before/after each utterance (default: 0.15)")
                ])
            ]),
            "required": .array([.string("transcript_id")])
        ])
    )

    package static func handle(arguments: [String: Value]?, store: TranscriptStore) -> CallTool.Result {
        guard let id = arguments?["transcript_id"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: transcript_id", annotations: nil, _meta: nil)], isError: true)
        }
        guard let parts = DataPaths.splitCompoundId(id) else {
            return .init(content: [.text(text: "Invalid transcript_id. Expected 'project/source' format.", annotations: nil, _meta: nil)], isError: true)
        }

        let gapThreshold = extractDouble(arguments?["gap_threshold"]) ?? 0.4
        let padding = extractDouble(arguments?["padding"]) ?? 0.15

        do {
            guard let record = try store.getRecord(project: parts.project, source: parts.source) else {
                return .init(content: [.text(text: "Transcript not found: \(id)", annotations: nil, _meta: nil)], isError: true)
            }
            let compactArray = try store.getCompactEntries(project: parts.project, source: parts.source)
            let duration = record.durationSeconds

            var utterances: [(start: Double, end: Double)] = []
            var gapsRemoved = 0
            var timeSaved: Double = 0

            for entry in compactArray {
                if let start = entry["start"] as? Double, let end = entry["end"] as? Double {
                    utterances.append((start: start, end: end))
                } else if let gap = entry["gap"] as? Double {
                    if gap >= gapThreshold {
                        gapsRemoved += 1
                        timeSaved += gap
                    }
                }
            }

            var segments: [[String: Any]] = []
            for utt in utterances {
                let segStart = max(0, utt.start - padding)
                let segEnd = min(duration, utt.end + padding)

                if let last = segments.last,
                   let lastEnd = last["end"] as? Double,
                   segStart <= lastEnd {
                    segments[segments.count - 1]["end"] = segEnd
                } else {
                    segments.append([
                        "sourceId": "main",
                        "start": round2(segStart),
                        "end": round2(segEnd)
                    ])
                }
            }

            let response: [String: Any] = [
                "source_path": record.sourcePath,
                "transcript_id": id,
                "gap_threshold": gapThreshold,
                "gaps_removed": gapsRemoved,
                "time_saved_seconds": round2(timeSaved),
                "original_duration_seconds": round2(duration),
                "segments": segments
            ]

            let responseData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            return .init(content: [.text(text: String(data: responseData, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Silence removal failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
