import Foundation
import MCP

package enum SilenceRemoveTool {
    package static let tool = Tool(
        name: "reelabs_silence_remove",
        description: "Analyze a transcript and return segments that skip silent gaps. Returns ready-to-use RenderSpec segments with padding. Use as a shortcut for silence removal — or build segments manually for more nuanced edits.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "transcript_id": .object([
                    "type": .string("integer"),
                    "description": .string("Transcript to process (from reelabs_transcribe)")
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

    package static func handle(arguments: [String: Value]?, transcriptRepo: TranscriptRepository) -> CallTool.Result {
        guard let transcriptId = extractInt64(arguments?["transcript_id"]) else {
            return .init(content: [.text(text: "Missing required argument: transcript_id", annotations: nil, _meta: nil)], isError: true)
        }

        let gapThreshold = arguments?["gap_threshold"]?.doubleValue ?? 0.4
        let padding = arguments?["padding"]?.doubleValue ?? 0.15

        do {
            guard let transcript = try transcriptRepo.get(id: transcriptId) else {
                return .init(content: [.text(text: "Transcript not found: \(transcriptId)", annotations: nil, _meta: nil)], isError: true)
            }

            guard let jsonData = transcript.compactJson.data(using: .utf8),
                  let compactArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                return .init(content: [.text(text: "Failed to parse transcript compact JSON", annotations: nil, _meta: nil)], isError: true)
            }

            let duration = transcript.durationSeconds ?? Double.greatestFiniteMagnitude

            // Collect utterances and count removed gaps
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

            // Build padded segments and merge overlapping ones
            var segments: [[String: Any]] = []

            for utt in utterances {
                let segStart = max(0, utt.start - padding)
                let segEnd = min(duration, utt.end + padding)

                if let last = segments.last,
                   let lastEnd = last["end"] as? Double,
                   segStart <= lastEnd {
                    // Merge with previous segment
                    segments[segments.count - 1]["end"] = segEnd
                } else {
                    segments.append([
                        "sourceId": "main",
                        "start": round2(segStart),
                        "end": round2(segEnd)
                    ])
                }
            }

            let originalDuration = transcript.durationSeconds ?? 0
            let response: [String: Any] = [
                "source_path": transcript.sourcePath,
                "transcript_id": transcriptId,
                "gap_threshold": gapThreshold,
                "gaps_removed": gapsRemoved,
                "time_saved_seconds": round2(timeSaved),
                "original_duration_seconds": round2(originalDuration),
                "segments": segments
            ]

            let responseData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: responseData, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Silence removal failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
