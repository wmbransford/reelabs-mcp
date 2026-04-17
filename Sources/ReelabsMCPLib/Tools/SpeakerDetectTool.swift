import Foundation
import MCP

package enum SpeakerDetectTool {
    package static let tool = Tool(
        name: "reelabs_speaker_detect",
        description: "Given transcripts from multiple synchronized sources (e.g. one mic per person in a podcast or interview), return segments that cut to whoever is speaking. Whichever source has the most words in each time window wins; ties are broken by continuity. Segments shorter than min_segment_length are absorbed into their neighbors to avoid jitter. Output segments are ready to drop into a RenderSpec.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sources": .object([
                    "type": .string("array"),
                    "description": .string("Array of {sourceId, transcriptId}. sourceId is the id used in the RenderSpec; transcriptId is the compound 'project/source' id from reelabs_transcribe. Need at least two sources for detection to be meaningful."),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "sourceId": .object(["type": .string("string")]),
                            "transcriptId": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("sourceId"), .string("transcriptId")])
                    ])
                ]),
                "min_segment_length": .object([
                    "type": .string("number"),
                    "description": .string("Minimum segment length in seconds. Shorter detections get absorbed into the preceding segment. Default: 1.0")
                ])
            ]),
            "required": .array([.string("sources")])
        ])
    )

    package static func handle(arguments: [String: Value]?, store: TranscriptStore) -> CallTool.Result {
        guard let sourcesValue = arguments?["sources"],
              case .array(let sourcesArray) = sourcesValue else {
            return errorResult("Missing or invalid 'sources' argument. Expected array of {sourceId, transcriptId}.")
        }
        if sourcesArray.count < 2 {
            return errorResult("reelabs_speaker_detect requires at least 2 sources.")
        }

        let minSegLen = extractDouble(arguments?["min_segment_length"]) ?? 1.0

        struct SourceInput { let sourceId: String; let transcriptId: String }
        var inputs: [SourceInput] = []
        for value in sourcesArray {
            guard case .object(let obj) = value,
                  let sid = obj["sourceId"]?.stringValue,
                  let tid = obj["transcriptId"]?.stringValue else {
                return errorResult("Each source must be an object with {sourceId, transcriptId} string fields.")
            }
            inputs.append(SourceInput(sourceId: sid, transcriptId: tid))
        }

        var seenSourceIds = Set<String>()
        for input in inputs {
            if !seenSourceIds.insert(input.sourceId).inserted {
                return errorResult("Duplicate sourceId: \(input.sourceId). Each sourceId must be unique.")
            }
        }

        do {
            var sourceDatas: [(sourceId: String, words: [WordEntry])] = []
            for input in inputs {
                guard let parts = DataPaths.splitCompoundId(input.transcriptId) else {
                    return errorResult("Invalid transcriptId '\(input.transcriptId)'. Expected 'project/source' format.")
                }
                let words = try store.getWords(project: parts.project, source: parts.source)
                if words.isEmpty {
                    return errorResult("No words found for transcript '\(input.transcriptId)'. Run reelabs_transcribe first.")
                }
                sourceDatas.append((input.sourceId, words))
            }

            let detection = SpeakerDetector.detect(
                sources: sourceDatas,
                minSegmentLength: minSegLen
            )

            let segmentsJSON: [[String: Any]] = detection.segments.map { seg in
                [
                    "sourceId": seg.sourceId,
                    "start": round2(seg.start),
                    "end": round2(seg.end)
                ]
            }
            let sourceStatsJSON: [[String: Any]] = sourceDatas.map { data in
                let speakingSeconds = data.words.reduce(0.0) { $0 + ($1.end - $1.start) }
                return [
                    "sourceId": data.sourceId,
                    "word_count": data.words.count,
                    "total_speaking_seconds": round2(speakingSeconds)
                ]
            }

            let switches = detection.segments.count > 0 ? detection.segments.count - 1 : 0
            let response: [String: Any] = [
                "sources_processed": inputs.count,
                "total_duration_seconds": round2(detection.totalDuration),
                "speaker_switches": switches,
                "min_segment_length": minSegLen,
                "segments": segmentsJSON,
                "source_stats": sourceStatsJSON
            ]

            let data = try safeJSONData(from: response)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return errorResult("Speaker detection failed: \(error.localizedDescription)")
        }
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
