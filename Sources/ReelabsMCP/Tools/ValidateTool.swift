import Foundation
import MCP

enum ValidateTool {
    static let tool = Tool(
        name: "reelabs_validate",
        description: "Pre-flight check on a RenderSpec without rendering. Validates sources exist, segments are within bounds, transitions fit, output directory is writable. Returns issues list.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "spec": .object([
                    "type": .string("object"),
                    "description": .string("The full RenderSpec to validate")
                ])
            ]),
            "required": .array([.string("spec")])
        ])
    )

    static func handle(arguments: [String: Value]?, transcriptRepo: TranscriptRepository) async -> CallTool.Result {
        guard let specValue = arguments?["spec"] else {
            return .init(content: [.text(text: "Missing required argument: spec", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let specData = try JSONSerialization.data(withJSONObject: specValue.toJSONObject())
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let spec = try decoder.decode(RenderSpec.self, from: specData)

            var issues: [String] = []

            // Validate sources exist
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
                    // Probe for duration
                    do {
                        let probe = try await VideoProbe.probe(path: source.path)
                        sourceDurations[source.id] = probe.duration
                    } catch {
                        issues.append("Cannot probe source \(source.id): \(error.localizedDescription)")
                    }
                }
            }

            // Validate segments
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

                if let transition = segment.transition {
                    if transition.duration <= 0 {
                        issues.append("Segment \(i): transition duration must be positive")
                    }
                    let segDuration = segment.end - segment.start
                    if transition.duration > segDuration / 2 {
                        issues.append("Segment \(i): transition duration (\(transition.duration)s) exceeds half segment duration")
                    }
                }
            }

            // Validate overlays
            if let overlays = spec.overlays {
                // Approximate composition duration for bounds checking
                var approxDuration = 0.0
                for seg in spec.segments {
                    let speed = seg.speed ?? 1.0
                    approxDuration += (seg.end - seg.start) / speed
                }

                for (i, overlay) in overlays.enumerated() {
                    if !sourceIds.contains(overlay.sourceId) {
                        issues.append("Overlay \(i): references unknown source '\(overlay.sourceId)'")
                    }

                    if overlay.start < 0 {
                        issues.append("Overlay \(i): start (\(overlay.start)s) is negative")
                    }
                    if overlay.end <= overlay.start {
                        issues.append("Overlay \(i): end (\(overlay.end)s) must be after start (\(overlay.start)s)")
                    }
                    if overlay.end > approxDuration + 0.1 {
                        issues.append("Overlay \(i): end (\(overlay.end)s) exceeds composition duration (~\(round(approxDuration * 100) / 100)s)")
                    }

                    if overlay.x < 0 || overlay.x > 1.0 {
                        issues.append("Overlay \(i): x (\(overlay.x)) out of range [0, 1]")
                    }
                    if overlay.y < 0 || overlay.y > 1.0 {
                        issues.append("Overlay \(i): y (\(overlay.y)) out of range [0, 1]")
                    }
                    if overlay.width <= 0 || overlay.width > 1.0 {
                        issues.append("Overlay \(i): width (\(overlay.width)) out of range (0, 1]")
                    }
                    if overlay.height <= 0 || overlay.height > 1.0 {
                        issues.append("Overlay \(i): height (\(overlay.height)) out of range (0, 1]")
                    }
                    if overlay.x + overlay.width > 1.01 {
                        issues.append("Overlay \(i): x + width (\(overlay.x + overlay.width)) exceeds 1.0")
                    }
                    if overlay.y + overlay.height > 1.01 {
                        issues.append("Overlay \(i): y + height (\(overlay.y + overlay.height)) exceeds 1.0")
                    }

                    if let opacity = overlay.opacity {
                        if opacity < 0 || opacity > 1.0 {
                            issues.append("Overlay \(i): opacity (\(opacity)) out of range [0, 1]")
                        }
                    }

                    if let sourceStart = overlay.sourceStart {
                        if sourceStart < 0 {
                            issues.append("Overlay \(i): sourceStart (\(sourceStart)s) is negative")
                        }
                        if let duration = sourceDurations[overlay.sourceId] {
                            let neededEnd = sourceStart + (overlay.end - overlay.start)
                            if neededEnd > duration + 0.1 {
                                issues.append("Overlay \(i): sourceStart + overlay duration (\(round(neededEnd * 100) / 100)s) exceeds source duration (\(duration)s)")
                            }
                        }
                    } else if let duration = sourceDurations[overlay.sourceId] {
                        let overlayDuration = overlay.end - overlay.start
                        if overlayDuration > duration + 0.1 {
                            issues.append("Overlay \(i): overlay duration (\(round(overlayDuration * 100) / 100)s) exceeds source duration (\(duration)s)")
                        }
                    }

                    if let audio = overlay.audio {
                        if audio < 0 || audio > 1.0 {
                            issues.append("Overlay \(i): audio (\(audio)) out of range [0, 1]")
                        }
                    }
                }
            }

            // Validate captions transcript
            if let captions = spec.captions, let transcriptId = captions.transcriptId {
                if try transcriptRepo.get(id: Int64(transcriptId)) == nil {
                    issues.append("Caption transcript not found: \(transcriptId)")
                }
            }

            // Validate output path
            let outputDir = URL(fileURLWithPath: spec.outputPath).deletingLastPathComponent().path
            if !FileManager.default.isWritableFile(atPath: outputDir) {
                if !FileManager.default.fileExists(atPath: outputDir) {
                    issues.append("Output directory does not exist: \(outputDir)")
                } else {
                    issues.append("Output directory not writable: \(outputDir)")
                }
            }

            // Validate audio
            if let audio = spec.audio, let musicPath = audio.musicPath {
                if !FileManager.default.fileExists(atPath: musicPath) {
                    issues.append("Music file not found: \(musicPath)")
                }
            }

            let valid = issues.isEmpty
            let response: [String: Any] = [
                "valid": valid,
                "issues": issues
            ]
            let responseData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: responseData, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, _):
                detail = "Missing required field: '\(key.stringValue)'. RenderSpec requires: sources (array), segments (array), outputPath (string)."
            case .typeMismatch(let type, let context):
                detail = "Type mismatch for '\(context.codingPath.map(\.stringValue).joined(separator: "."))': expected \(type)."
            case .valueNotFound(let type, let context):
                detail = "Null value for '\(context.codingPath.map(\.stringValue).joined(separator: "."))': expected \(type)."
            default:
                detail = decodingError.localizedDescription
            }
            return .init(content: [.text(text: "Invalid RenderSpec: \(detail)", annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(content: [.text(text: "Validation error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
