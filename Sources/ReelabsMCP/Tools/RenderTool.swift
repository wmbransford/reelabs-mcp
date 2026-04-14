import Foundation
import MCP

enum RenderTool {
    static let tool = Tool(
        name: "reelabs_render",
        description: "Render a video from a declarative RenderSpec. Handles trimming, speed changes, transitions, captions, audio mixing, aspect ratio, and overlays. Pass the full spec as JSON.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "spec": .object([
                    "type": .string("object"),
                    "description": .string("The full RenderSpec object defining the render")
                ]),
                "project_id": .object([
                    "type": .string("integer"),
                    "description": .string("Optional project ID to associate render with")
                ])
            ]),
            "required": .array([.string("spec")])
        ])
    )

    static func handle(arguments: [String: Value]?, renderRepo: RenderRepository, transcriptRepo: TranscriptRepository, presetRepo: PresetRepository) async -> CallTool.Result {
        guard let specValue = arguments?["spec"] else {
            return .init(content: [.text(text: "Missing required argument: spec", annotations: nil, _meta: nil)], isError: true)
        }

        let projectId = extractInt64(arguments?["project_id"])

        do {
            // Decode spec from Value
            let specData = try JSONSerialization.data(withJSONObject: specValue.toJSONObject())
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let spec = try decoder.decode(RenderSpec.self, from: specData)


            // Encode spec for storage
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let specJson = String(data: try encoder.encode(spec), encoding: .utf8) ?? "{}"

            // Build composition and render
            let builder = CompositionBuilder()
            let exportService = ExportService()

            // Fail loudly if captions requested without transcriptId
            if spec.captions != nil && spec.captions?.transcriptId == nil {
                return .init(content: [.text(text: "Caption error: transcriptId is required when captions are specified.", annotations: nil, _meta: nil)], isError: true)
            }

            // Resolve caption transcript — fail loudly if requested but missing
            var transcriptData: TranscriptData? = nil
            if let captionConfig = spec.captions, let transcriptId = captionConfig.transcriptId {
                guard let transcript = try transcriptRepo.get(id: Int64(transcriptId)) else {
                    return .init(content: [.text(text: "Caption error: transcript_id \(transcriptId) not found in database. Run reelabs_transcribe first.", annotations: nil, _meta: nil)], isError: true)
                }
                let words = try transcriptRepo.getWords(transcriptId: Int64(transcriptId))
                if words.isEmpty {
                    return .init(content: [.text(text: "Caption error: transcript \(transcriptId) has 0 words in database. Re-run reelabs_transcribe.", annotations: nil, _meta: nil)], isError: true)
                }
                transcriptData = TranscriptData(
                    words: words,
                    fullText: transcript.fullText,
                    durationSeconds: transcript.durationSeconds ?? 0
                )
            }

            // Resolve caption preset — fail loudly if requested but missing
            var resolvedCaptionConfig = spec.captions
            if let presetName = spec.captions?.preset {
                guard let preset = try presetRepo.get(name: presetName) else {
                    return .init(content: [.text(text: "Caption error: preset '\(presetName)' not found. Available: tiktok, subtitle, minimal, bold_center.", annotations: nil, _meta: nil)], isError: true)
                }
                let presetConfig = try JSONDecoder().decode(CaptionConfig.self, from: preset.configJson.data(using: .utf8)!)
                resolvedCaptionConfig = mergeCaptionConfig(base: presetConfig, override: spec.captions)
            }

            // Validate music file exists before building
            if let audio = spec.audio, let musicPath = audio.musicPath {
                if !FileManager.default.fileExists(atPath: musicPath) {
                    return .init(content: [.text(text: "Music file not found: \(musicPath)", annotations: nil, _meta: nil)], isError: true)
                }
            }

            let outputURL = URL(fileURLWithPath: spec.outputPath)

            // Ensure output directory exists
            let outputDir = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            // Remap transcript word timestamps from source time to composition time
            let preRemapWordCount = transcriptData?.words.count ?? 0
            if let td = transcriptData {
                transcriptData = remapTranscript(td, segments: spec.segments)
            }
            let postRemapWordCount = transcriptData?.words.count ?? 0

            // Fail loudly if remap dropped all words
            if spec.captions != nil && preRemapWordCount > 0 && postRemapWordCount == 0 {
                return .init(content: [.text(text: "Caption error: no words fall within segment time ranges. Check segment boundaries.", annotations: nil, _meta: nil)], isError: true)
            }

            let result = try await builder.build(spec: spec)
            let exportResult = try await exportService.export(
                composition: result.composition,
                videoComposition: result.videoComposition,
                audioMix: result.audioMix,
                outputURL: outputURL,
                captionConfig: resolvedCaptionConfig,
                transcriptData: transcriptData,
                renderSize: result.renderSize,
                quality: spec.quality
            )

            // Fail loudly if captions were requested but not applied
            if spec.captions != nil && !exportResult.captionsApplied {
                return .init(content: [.text(text: "Caption error: captions were requested but could not be applied.", annotations: nil, _meta: nil)], isError: true)
            }

            // Get output file info
            let fileSize: Int64
            if let attrs = try? FileManager.default.attributesOfItem(atPath: spec.outputPath),
               let size = attrs[.size] as? Int64 {
                fileSize = size
            } else {
                fileSize = 0
            }

            let duration = result.totalDuration

            // Save to database
            let renderId = try renderRepo.create(
                projectId: projectId,
                specJson: specJson,
                outputPath: spec.outputPath,
                durationSeconds: duration,
                fileSizeBytes: fileSize,
                status: "completed"
            )

            // Build detailed response so the agent knows exactly what happened
            let captionsApplied = exportResult.captionsApplied
            let captionWordCount = transcriptData?.words.count ?? 0
            let actualWidth = Int(result.renderSize.width)
            let actualHeight = Int(result.renderSize.height)
            let aspectLabel = spec.aspectRatio?.rawValue ?? "\(actualWidth):\(actualHeight)"
            let musicApplied = spec.audio?.musicPath != nil
            let musicVolume = spec.audio?.musicVolume ?? (musicApplied ? 0.3 : 0.0)
            let codec = (spec.quality?.codec ?? .h264).rawValue

            // Caption diagnostics: segment time ranges for debugging remap
            let segmentRanges = spec.segments.map { ["start": $0.start, "end": $0.end] }
            let firstRemappedWords: [[String: Any]] = (transcriptData?.words.prefix(3) ?? []).map {
                ["word": $0.word, "start": round($0.startTime * 1000) / 1000, "end": round($0.endTime * 1000) / 1000]
            }

            let response: [String: Any] = [
                "render_id": renderId,
                "output_path": spec.outputPath,
                "duration_seconds": round(duration * 100) / 100,
                "file_size_bytes": fileSize,
                "file_size_mb": round(Double(fileSize) / 1_048_576 * 10) / 10,
                "status": "completed",
                "segments_processed": spec.segments.count,
                "overlays_applied": spec.overlays?.count ?? 0,
                "captions_applied": captionsApplied,
                "caption_word_count": captionWordCount,
                "caption_debug": [
                    "words_before_remap": preRemapWordCount,
                    "words_after_remap": postRemapWordCount,
                    "caption_layer_sublayers": exportResult.captionSublayerCount,
                    "composition_duration": round(duration * 1000) / 1000,
                    "segment_ranges": segmentRanges,
                    "first_remapped_words": firstRemappedWords
                ] as [String: Any],
                "music_applied": musicApplied,
                "music_volume": musicVolume,
                "codec": codec,
                "resolution": "\(actualWidth)x\(actualHeight)",
                "fps": result.fps,
                "aspect_ratio": aspectLabel
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
            default:
                detail = decodingError.localizedDescription
            }
            return .init(content: [.text(text: "Invalid RenderSpec: \(detail)", annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(content: [.text(text: "Render failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}

/// Remap transcript word timestamps from source-video time to composition time.
/// Without this, captions are misaligned in multi-segment edits because the
/// transcript stores times relative to the original source, not the cut.
private func remapTranscript(_ data: TranscriptData, segments: [SegmentSpec]) -> TranscriptData {
    var mappings: [(sourceStart: Double, sourceEnd: Double, compositionStart: Double, speed: Double)] = []
    var compositionTime = 0.0
    for seg in segments {
        let speed = seg.speed ?? 1.0
        let duration = (seg.end - seg.start) / speed
        mappings.append((seg.start, seg.end, compositionTime, speed))
        compositionTime += duration
    }

    // Log segment mappings for debugging
    for (i, m) in mappings.enumerated() {
        captionLog("[remapTranscript] seg[\(i)]: source=\(m.sourceStart)-\(m.sourceEnd) → comp=\(m.compositionStart), speed=\(m.speed)")
    }

    var remapped: [TranscriptWord] = []
    for word in data.words {
        for (segIdx, m) in mappings.enumerated() {
            if word.startTime >= m.sourceStart && word.startTime < m.sourceEnd {
                let newStart = m.compositionStart + (word.startTime - m.sourceStart) / m.speed
                let clampedEnd = min(word.endTime, m.sourceEnd)
                let newEnd = m.compositionStart + (clampedEnd - m.sourceStart) / m.speed
                // Drop words with invalid timing (endTime < startTime after remap)
                if newEnd <= newStart {
                    captionLog("[remapTranscript] DROPPED '\(word.word)': src=\(word.startTime)-\(word.endTime) seg[\(segIdx)]=\(m.sourceStart)-\(m.sourceEnd) → comp=\(newStart)-\(newEnd)")
                    break
                }
                remapped.append(TranscriptWord(
                    word: word.word,
                    startTime: newStart,
                    endTime: newEnd,
                    confidence: word.confidence
                ))
                break
            }
        }
    }

    let dropped = data.words.count - remapped.count
    captionLog("[remapTranscript] Result: \(remapped.count)/\(data.words.count) words mapped (\(dropped) dropped), compositionDuration=\(round(compositionTime * 1000) / 1000)s")

    return TranscriptData(
        words: remapped,
        fullText: data.fullText,
        durationSeconds: compositionTime
    )
}

private func mergeCaptionConfig(base: CaptionConfig, override: CaptionConfig?) -> CaptionConfig {
    guard let o = override else { return base }
    return CaptionConfig(
        preset: o.preset ?? base.preset,
        transcriptId: o.transcriptId ?? base.transcriptId,
        fontFamily: o.fontFamily ?? base.fontFamily,
        fontSize: o.fontSize ?? base.fontSize,
        fontWeight: o.fontWeight ?? base.fontWeight,
        color: o.color ?? base.color,
        highlightColor: o.highlightColor ?? base.highlightColor,
        position: o.position ?? base.position,
        allCaps: o.allCaps ?? base.allCaps,
        shadow: o.shadow ?? base.shadow,
        wordsPerGroup: o.wordsPerGroup ?? base.wordsPerGroup,
        punctuation: o.punctuation ?? base.punctuation
    )
}
