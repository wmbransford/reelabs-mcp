import Foundation
import MCP

private func isValidHexColor(_ hex: String) -> Bool {
    var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if str.hasPrefix("#") { str.removeFirst() }
    guard str.count == 6 || str.count == 8 else { return false }
    return str.allSatisfy { $0.isHexDigit }
}

package enum ValidateTool {
    package static let tool = Tool(
        name: "reelabs_validate",
        description: "Pre-flight check on a RenderSpec without rendering. Validates sources exist, segments are within bounds, transitions fit, output directory is writable. Returns issues list.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "spec": .object([
                    "type": .string("object"),
                    "description": .string("The full RenderSpec to validate")
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string("Optional project slug used to resolve bare transcript_ids.")
                ])
            ]),
            "required": .array([.string("spec")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        transcriptStore: TranscriptStore
    ) async -> CallTool.Result {
        guard let specValue = arguments?["spec"] else {
            return .init(content: [.text(text: "Missing required argument: spec", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let specObject = specValue.toJSONObject()
            guard JSONSerialization.isValidJSONObject(specObject) else {
                return .init(content: [.text(text: "Invalid 'spec': must be a JSON object (dictionary), not a string or scalar. Pass the RenderSpec as structured JSON, not a JSON-encoded string.", annotations: nil, _meta: nil)], isError: true)
            }
            let specData = try JSONSerialization.data(withJSONObject: specObject)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let spec = try decoder.decode(RenderSpec.self, from: specData)

            let defaultProject = arguments?["project"]?.stringValue
                ?? (spec.sources.first.map { DataPaths.deriveProjectSlug(fromSourcePath: $0.path) } ?? "")

            var issues: [String] = []

            if spec.segments.isEmpty {
                issues.append("No segments defined — nothing to render.")
            }

            var sourceIds = Set<String>()
            var sourceDurations: [String: Double] = [:]
            for source in spec.sources {
                if sourceIds.contains(source.id) {
                    issues.append("Duplicate source ID: \(source.id)")
                }
                sourceIds.insert(source.id)

                if !FileManager.default.fileExists(atPath: source.path) {
                    issues.append("Source file not found: \(source.path)")
                } else {
                    do {
                        let probe = try await VideoProbe.probe(path: source.path)
                        sourceDurations[source.id] = probe.duration
                    } catch {
                        issues.append("Cannot probe source \(source.id): \(error.localizedDescription)")
                    }
                }
            }

            for (i, segment) in spec.segments.enumerated() {
                if !sourceIds.contains(segment.sourceId) {
                    issues.append("Segment \(i): references unknown source '\(segment.sourceId)'")
                }
                if segment.end <= segment.start {
                    issues.append("Segment \(i): end (\(segment.end)s) must be after start (\(segment.start)s)")
                }
                if let duration = sourceDurations[segment.sourceId] {
                    if segment.start < 0 {
                        issues.append("Segment \(i): start (\(segment.start)s) is negative")
                    }
                    if segment.end > duration + 0.1 {
                        issues.append("Segment \(i): end (\(segment.end)s) exceeds source duration (\(duration)s)")
                    }
                }
                if let speed = segment.speed {
                    if speed < 0.25 || speed > 4.0 {
                        issues.append("Segment \(i): speed \(speed)x out of range (0.25-4.0)")
                    }
                }
                if let transition = segment.transition, let transitionDuration = transition.duration {
                    if transitionDuration <= 0 {
                        issues.append("Segment \(i): transition duration must be positive")
                    }
                    let segDuration = segment.end - segment.start
                    if transitionDuration > segDuration / 2 {
                        issues.append("Segment \(i): transition duration (\(transitionDuration)s) exceeds half segment duration")
                    }
                }
            }

            // Overlays
            if let overlays = spec.overlays {
                var approxDuration = 0.0
                for seg in spec.segments {
                    let speed = seg.speed ?? 1.0
                    approxDuration += (seg.end - seg.start) / speed
                }

                for (i, overlay) in overlays.enumerated() {
                    switch overlay.kind {
                    case .video:
                        if let sourceId = overlay.sourceId, !sourceIds.contains(sourceId) {
                            issues.append("Overlay \(i): references unknown source '\(sourceId)'")
                        }
                    case .color:
                        if let bg = overlay.backgroundColor, !isValidHexColor(bg) {
                            issues.append("Overlay \(i): invalid backgroundColor '\(bg)'")
                        }
                        if overlay.backgroundColor == nil {
                            issues.append("Overlay \(i): color overlay requires backgroundColor")
                        }
                    case .image:
                        if let path = overlay.imagePath, !path.isEmpty {
                            if !FileManager.default.isReadableFile(atPath: path) {
                                issues.append("Overlay \(i): image file not found or not readable: \(path)")
                            }
                        } else {
                            issues.append("Overlay \(i): image overlay requires imagePath")
                        }
                    case .text:
                        let t = overlay.text
                        if (t?.title == nil || t!.title!.isEmpty) && (t?.body == nil || t!.body!.isEmpty) {
                            issues.append("Overlay \(i): text overlay requires at least title or body")
                        }
                    }

                    if overlay.end <= overlay.start {
                        issues.append("Overlay \(i): end must be after start")
                    }
                    if overlay.end > approxDuration + 0.1 {
                        issues.append("Overlay \(i): end (\(overlay.end)s) exceeds composition duration (~\(round(approxDuration * 100) / 100)s)")
                    }
                    if overlay.x < 0 || overlay.x > 1.0 || overlay.y < 0 || overlay.y > 1.0 {
                        issues.append("Overlay \(i): x/y out of range [0, 1]")
                    }
                    if overlay.width <= 0 || overlay.width > 1.0 || overlay.height <= 0 || overlay.height > 1.0 {
                        issues.append("Overlay \(i): width/height out of range (0, 1]")
                    }
                }
            }

            // Transcripts
            let segmentSourceIds = Set(spec.segments.map { $0.sourceId })
            let hasPerSourceTranscripts = spec.sources.contains { $0.transcriptId != nil }
            if hasPerSourceTranscripts {
                for source in spec.sources {
                    if let tid = source.transcriptId {
                        let parts = DataPaths.splitCompoundId(tid) ?? (defaultProject, tid)
                        if try transcriptStore.getRecord(project: parts.0, source: parts.1) == nil {
                            issues.append("Source '\(source.id)': transcript '\(tid)' not found")
                        }
                    } else if spec.captions != nil && segmentSourceIds.contains(source.id) {
                        issues.append("Warning: source '\(source.id)' has no transcriptId — segments from this source won't have captions")
                    }
                }
            } else if let captions = spec.captions, let tid = captions.transcriptId {
                let parts = DataPaths.splitCompoundId(tid) ?? (defaultProject, tid)
                if try transcriptStore.getRecord(project: parts.0, source: parts.1) == nil {
                    issues.append("Caption transcript not found: \(tid)")
                }
            }

            if spec.captions != nil && !hasPerSourceTranscripts && spec.captions?.transcriptId == nil {
                issues.append("Captions requested but no transcriptId specified")
            }

            // Output path
            let outputDir = URL(fileURLWithPath: spec.outputPath).deletingLastPathComponent().path
            if !FileManager.default.isWritableFile(atPath: outputDir) {
                if !FileManager.default.fileExists(atPath: outputDir) {
                    issues.append("Output directory does not exist: \(outputDir)")
                } else {
                    issues.append("Output directory not writable: \(outputDir)")
                }
            }

            if let audio = spec.audio, let musicPath = audio.musicPath {
                if !FileManager.default.fileExists(atPath: musicPath) {
                    issues.append("Music file not found: \(musicPath)")
                }
            }

            let response: [String: Any] = [
                "valid": issues.isEmpty,
                "issues": issues
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)
        } catch let decodingError as DecodingError {
            return .init(content: [.text(text: "Invalid RenderSpec: \(decodingError.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(content: [.text(text: "Validation error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
