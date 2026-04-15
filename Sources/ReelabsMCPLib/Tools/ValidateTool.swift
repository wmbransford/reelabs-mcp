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
                ])
            ]),
            "required": .array([.string("spec")])
        ])
    )

    package static func handle(arguments: [String: Value]?, transcriptRepo: TranscriptRepository) async -> CallTool.Result {
        guard let specValue = arguments?["spec"] else {
            return .init(content: [.text(text: "Missing required argument: spec", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let specData = try JSONSerialization.data(withJSONObject: specValue.toJSONObject())
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let spec = try decoder.decode(RenderSpec.self, from: specData)

            var issues: [String] = []

            if spec.segments.isEmpty {
                issues.append("No segments defined — nothing to render.")
            }

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
                    // Type-aware validation
                    switch overlay.kind {
                    case .video:
                        if let sourceId = overlay.sourceId, !sourceIds.contains(sourceId) {
                            issues.append("Overlay \(i): references unknown source '\(sourceId)'")
                        }
                    case .color:
                        if let bg = overlay.backgroundColor, !isValidHexColor(bg) {
                            issues.append("Overlay \(i): invalid backgroundColor '\(bg)' (expected #RRGGBB or #RRGGBBAA)")
                        }
                        if overlay.backgroundColor == nil {
                            issues.append("Overlay \(i): color overlay requires backgroundColor")
                        }
                    case .image:
                        if let path = overlay.imagePath, !path.isEmpty {
                            if !FileManager.default.isReadableFile(atPath: path) {
                                issues.append("Overlay \(i): image file not found or not readable: \(path)")
                            } else {
                                let ext = (path as NSString).pathExtension.lowercased()
                                let supported = ["png", "jpg", "jpeg", "tiff", "bmp", "gif", "webp"]
                                if !supported.contains(ext) {
                                    issues.append("Overlay \(i): unsupported image format '.\(ext)' (supported: \(supported.joined(separator: ", ")))")
                                }
                            }
                        } else {
                            issues.append("Overlay \(i): image overlay requires imagePath")
                        }
                    case .text:
                        let textConfig = overlay.text
                        if (textConfig?.title == nil || textConfig!.title!.isEmpty) && (textConfig?.body == nil || textConfig!.body!.isEmpty) {
                            issues.append("Overlay \(i): text overlay requires at least title or body")
                        }
                        if let bg = overlay.backgroundColor, !isValidHexColor(bg) {
                            issues.append("Overlay \(i): invalid backgroundColor '\(bg)' (expected #RRGGBB or #RRGGBBAA)")
                        }
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

                    // Source duration checks only apply to video overlays
                    if overlay.kind == .video, let sourceId = overlay.sourceId {
                        if let sourceStart = overlay.sourceStart {
                            if sourceStart < 0 {
                                issues.append("Overlay \(i): sourceStart (\(sourceStart)s) is negative")
                            }
                            if let duration = sourceDurations[sourceId] {
                                let neededEnd = sourceStart + (overlay.end - overlay.start)
                                if neededEnd > duration + 0.1 {
                                    issues.append("Overlay \(i): sourceStart + overlay duration (\(round(neededEnd * 100) / 100)s) exceeds source duration (\(duration)s) — will be auto-clamped")
                                }
                            }
                        } else if let duration = sourceDurations[sourceId] {
                            let overlayDuration = overlay.end - overlay.start
                            if overlayDuration > duration + 0.1 {
                                issues.append("Overlay \(i): overlay duration (\(round(overlayDuration * 100) / 100)s) exceeds source duration (\(duration)s) — will be auto-clamped")
                            }
                        }
                    }

                    if let audio = overlay.audio {
                        if audio < 0 || audio > 1.0 {
                            issues.append("Overlay \(i): audio (\(audio)) out of range [0, 1]")
                        }
                    }

                    if let cornerRadius = overlay.cornerRadius {
                        if cornerRadius < 0 || cornerRadius > 1.0 {
                            issues.append("Overlay \(i): cornerRadius (\(cornerRadius)) out of range [0, 1]")
                        }
                    }

                    if let crop = overlay.crop {
                        if crop.x < 0 || crop.x > 1.0 {
                            issues.append("Overlay \(i): crop.x (\(crop.x)) out of range [0, 1]")
                        }
                        if crop.y < 0 || crop.y > 1.0 {
                            issues.append("Overlay \(i): crop.y (\(crop.y)) out of range [0, 1]")
                        }
                        if crop.width <= 0 || crop.width > 1.0 {
                            issues.append("Overlay \(i): crop.width (\(crop.width)) out of range (0, 1]")
                        }
                        if crop.height <= 0 || crop.height > 1.0 {
                            issues.append("Overlay \(i): crop.height (\(crop.height)) out of range (0, 1]")
                        }
                        if crop.x + crop.width > 1.01 {
                            issues.append("Overlay \(i): crop.x + crop.width (\(crop.x + crop.width)) exceeds 1.0")
                        }
                        if crop.y + crop.height > 1.01 {
                            issues.append("Overlay \(i): crop.y + crop.height (\(crop.y + crop.height)) exceeds 1.0")
                        }
                    }

                    if let fadeIn = overlay.fadeIn, fadeIn < 0 {
                        issues.append("Overlay \(i): fadeIn (\(fadeIn)s) must be non-negative")
                    }
                    if let fadeOut = overlay.fadeOut, fadeOut < 0 {
                        issues.append("Overlay \(i): fadeOut (\(fadeOut)s) must be non-negative")
                    }
                }
            }

            // Validate captions transcripts
            // Only warn about missing transcriptId for sources actually used in segments
            let segmentSourceIds = Set(spec.segments.map { $0.sourceId })
            let hasPerSourceTranscripts = spec.sources.contains { $0.transcriptId != nil }
            if hasPerSourceTranscripts {
                // Per-source mode: validate each source's transcriptId
                for source in spec.sources {
                    if let tid = source.transcriptId {
                        if try transcriptRepo.get(id: Int64(tid)) == nil {
                            issues.append("Source '\(source.id)': transcript \(tid) not found in database")
                        }
                    } else if spec.captions != nil && segmentSourceIds.contains(source.id) {
                        // Only warn for sources used in segments, not overlay-only sources
                        issues.append("Warning: source '\(source.id)' has no transcriptId — segments from this source won't have captions")
                    }
                }
            } else if let captions = spec.captions, let transcriptId = captions.transcriptId {
                // Legacy single-transcript mode
                if try transcriptRepo.get(id: Int64(transcriptId)) == nil {
                    issues.append("Caption transcript not found: \(transcriptId)")
                }
            }

            if spec.captions != nil && !hasPerSourceTranscripts && spec.captions?.transcriptId == nil {
                issues.append("Captions requested but no transcriptId specified (set on sources or in captions)")
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
