import Foundation
import MCP

package enum RenderTool {
    package static let tool = Tool(
        name: "reelabs_render",
        description: "Render a video from a declarative RenderSpec. Handles trimming, speed changes, transitions, captions, audio mixing, aspect ratio, and overlays (video, color, text). Pass the full spec as JSON. transcriptId in the spec is either a compound 'project/source' string or just 'source' (resolved within the render's project).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "spec": .object([
                    "type": .string("object"),
                    "description": .string("The full RenderSpec object defining the render")
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string("Optional project slug. If omitted, derived from the first source file's parent directory.")
                ]),
                "slug": .object([
                    "type": .string("string"),
                    "description": .string("Optional base slug for this render (e.g. 'trust-me-bro'). Defaults to the output filename.")
                ])
            ]),
            "required": .array([.string("spec")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        renderStore: RenderStore,
        transcriptStore: TranscriptStore,
        projectStore: ProjectStore,
        presetStore: PresetStore
    ) async -> CallTool.Result {
        guard let specValue = arguments?["spec"] else {
            return .init(content: [.text(text: "Missing required argument: spec", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let specData = try JSONSerialization.data(withJSONObject: specValue.toJSONObject())
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let spec = try decoder.decode(RenderSpec.self, from: specData)

            // Resolve the project for this render
            let projectSlug: String
            if let explicit = arguments?["project"]?.stringValue {
                projectSlug = explicit
            } else if let firstSource = spec.sources.first {
                projectSlug = DataPaths.deriveProjectSlug(fromSourcePath: firstSource.path)
            } else {
                return .init(content: [.text(text: "No project arg and no sources to derive one from.", annotations: nil, _meta: nil)], isError: true)
            }
            _ = try projectStore.createWithSlug(slug: projectSlug)

            // Encode spec for storage
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let specJson = String(data: try encoder.encode(spec), encoding: .utf8) ?? "{}"

            // Determine caption mode: per-source, legacy single-transcript, or error
            let hasPerSourceTranscripts = spec.sources.contains { $0.transcriptId != nil }
            let hasLegacyTranscriptId = spec.captions?.transcriptId != nil

            if spec.captions != nil && !hasPerSourceTranscripts && !hasLegacyTranscriptId {
                return .init(content: [.text(text: "Caption error: transcriptId is required when captions are specified. Set it on each source or in captions.", annotations: nil, _meta: nil)], isError: true)
            }

            // Resolve transcripts
            var transcriptData: TranscriptData? = nil
            if spec.captions != nil && hasPerSourceTranscripts {
                var sourceTranscripts: [String: [TranscriptWord]] = [:]
                for source in spec.sources {
                    guard let tid = source.transcriptId else { continue }
                    let words = try Self.loadWords(
                        transcriptId: tid,
                        defaultProject: projectSlug,
                        store: transcriptStore
                    )
                    if words.isEmpty {
                        return .init(content: [.text(text: "Caption error: transcript '\(tid)' (source '\(source.id)') not found or has 0 words. Run reelabs_transcribe first.", annotations: nil, _meta: nil)], isError: true)
                    }
                    sourceTranscripts[source.id] = words
                }
                transcriptData = remapMultiSourceTranscript(sourceTranscripts: sourceTranscripts, segments: spec.segments)

                // Overlay sources not in segments
                if let overlays = spec.overlays {
                    let segmentSourceIds = Set(spec.segments.map { $0.sourceId })
                    let overlayWords = remapOverlaySources(
                        sourceTranscripts: sourceTranscripts,
                        overlays: overlays,
                        excludeSourceIds: segmentSourceIds
                    )
                    if !overlayWords.isEmpty, let td = transcriptData {
                        var allWords = td.words + overlayWords
                        allWords.sort { $0.startTime < $1.startTime }
                        let overlayText = overlayWords.map { $0.word }.joined(separator: " ")
                        let fullText = td.fullText.isEmpty ? overlayText : td.fullText + " " + overlayText
                        transcriptData = TranscriptData(
                            words: allWords,
                            fullText: fullText,
                            durationSeconds: td.durationSeconds
                        )
                    }
                }
            } else if let captionConfig = spec.captions, let tid = captionConfig.transcriptId {
                let words = try Self.loadWords(
                    transcriptId: tid,
                    defaultProject: projectSlug,
                    store: transcriptStore
                )
                if words.isEmpty {
                    return .init(content: [.text(text: "Caption error: transcript '\(tid)' not found or has 0 words. Run reelabs_transcribe first.", annotations: nil, _meta: nil)], isError: true)
                }
                let parts = DataPaths.splitCompoundId(tid) ?? (projectSlug, tid)
                let record = try transcriptStore.getRecord(project: parts.0, source: parts.1)
                let fullText = words.map { $0.word }.joined(separator: " ")
                transcriptData = TranscriptData(
                    words: words,
                    fullText: fullText,
                    durationSeconds: record?.durationSeconds ?? 0
                )
            }

            // Resolve caption preset
            var resolvedCaptionConfig = spec.captions
            if let presetName = spec.captions?.preset {
                guard let preset = try presetStore.get(name: presetName) else {
                    return .init(content: [.text(text: "Caption error: preset '\(presetName)' not found. Available: tiktok, subtitle, minimal, bold_center, william.", annotations: nil, _meta: nil)], isError: true)
                }
                guard let presetData = preset.configJson.data(using: .utf8) else {
                    return .init(content: [.text(text: "Caption error: preset '\(presetName)' contains invalid encoding", annotations: nil, _meta: nil)], isError: true)
                }
                let presetConfig = try JSONDecoder().decode(CaptionConfig.self, from: presetData)
                resolvedCaptionConfig = mergeCaptionConfig(base: presetConfig, override: spec.captions)
            }

            if spec.segments.isEmpty {
                return .init(content: [.text(text: "No segments defined — nothing to render.", annotations: nil, _meta: nil)], isError: true)
            }

            if let audio = spec.audio, let musicPath = audio.musicPath {
                if !FileManager.default.fileExists(atPath: musicPath) {
                    return .init(content: [.text(text: "Music file not found: \(musicPath)", annotations: nil, _meta: nil)], isError: true)
                }
            }

            let outputURL = URL(fileURLWithPath: spec.outputPath)
            let outputDir = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            // Remap transcript word timestamps from source time to composition time
            let preRemapWordCount = transcriptData?.words.count ?? 0
            if let td = transcriptData, !hasPerSourceTranscripts {
                transcriptData = remapTranscript(td, segments: spec.segments)
            }
            let postRemapWordCount = transcriptData?.words.count ?? 0

            if spec.captions != nil && preRemapWordCount > 0 && postRemapWordCount == 0 {
                return .init(content: [.text(text: "Caption error: no words fall within segment time ranges. Check segment boundaries.", annotations: nil, _meta: nil)], isError: true)
            }

            let captionExclusionZones: [ClosedRange<Double>] = (spec.overlays ?? [])
                .filter { $0.sourceId == nil && ($0.text != nil || $0.imagePath != nil) }
                .map { $0.start...$0.end }

            let builder = CompositionBuilder()
            let exportService = ExportService()
            let profiler = RenderProfiler()
            FrameStats.shared.reset()

            let captionConfigForRender = resolvedCaptionConfig
            let transcriptDataForRender = transcriptData
            let (result, exportResult) = try await RenderQueue.shared.enqueue {
                let result = try await profiler.measure("composition_build") {
                    try await builder.build(spec: spec)
                }
                let exportResult = try await profiler.measure("export_total") {
                    try await exportService.export(
                        composition: result.composition,
                        videoComposition: result.videoComposition,
                        audioMix: result.audioMix,
                        outputURL: outputURL,
                        captionConfig: captionConfigForRender,
                        transcriptData: transcriptDataForRender,
                        renderSize: result.renderSize,
                        quality: spec.quality,
                        captionExclusionZones: captionExclusionZones,
                        lut: result.lut,
                        lutStrength: result.lutStrength,
                        profiler: profiler
                    )
                }
                return (result, exportResult)
            }
            profiler.logSummary()

            if spec.captions != nil && !exportResult.captionsApplied {
                return .init(content: [.text(text: "Caption error: captions were requested but could not be applied.", annotations: nil, _meta: nil)], isError: true)
            }

            let fileSize: Int64
            if let attrs = try? FileManager.default.attributesOfItem(atPath: spec.outputPath),
               let size = attrs[.size] as? Int64 {
                fileSize = size
            } else {
                fileSize = 0
            }
            let duration = result.totalDuration

            // Build render record
            let baseSlug: String
            if let s = arguments?["slug"]?.stringValue, !s.isEmpty {
                baseSlug = SlugGenerator.slugify(s)
            } else {
                baseSlug = SlugGenerator.slugify(outputURL.deletingPathExtension().lastPathComponent)
            }

            let record = RenderRecord(
                slug: baseSlug,
                status: "completed",
                durationSeconds: duration,
                outputPath: spec.outputPath,
                fileSizeBytes: fileSize,
                sources: spec.sources.map { $0.id }
            )

            let saved = try renderStore.save(
                project: projectSlug,
                baseSlug: baseSlug,
                record: record,
                specJson: specJson,
                notes: nil
            )

            // Build response
            let captionsApplied = exportResult.captionsApplied
            let captionWordCount = transcriptData?.words.count ?? 0
            let actualWidth = Int(result.renderSize.width)
            let actualHeight = Int(result.renderSize.height)
            let aspectLabel = spec.aspectRatio?.rawValue ?? "\(actualWidth):\(actualHeight)"
            let musicApplied = spec.audio?.musicPath != nil
            let musicVolume = spec.audio?.musicVolume ?? (musicApplied ? 0.3 : 0.0)
            let codec = (spec.quality?.codec ?? .h264).rawValue

            let segmentRanges = spec.segments.map { ["start": $0.start, "end": $0.end] }
            let firstRemappedWords: [[String: Any]] = (transcriptData?.words.prefix(3) ?? []).map {
                ["word": $0.word, "start": round($0.startTime * 1000) / 1000, "end": round($0.endTime * 1000) / 1000]
            }

            let response: [String: Any] = [
                "render_id": "\(projectSlug)/\(saved.slug)",
                "project": projectSlug,
                "slug": saved.slug,
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
                "aspect_ratio": aspectLabel,
                "timing": profiler.responseTiming()
            ]
            let responseData = try safeJSONData(from: response)

            // Fire-and-forget telemetry to the analytics warehouse. No-ops when
            // REELABS_WAREHOUSE_URL / REELABS_WAREHOUSE_SECRET env vars are unset.
            WarehouseTelemetry.postRender([
                "render_id": "\(projectSlug)/\(saved.slug)",
                "project": projectSlug,
                "slug": saved.slug,
                "status": "completed",
                "finished_at": ISO8601DateFormatter().string(from: Date()),
                "timing": profiler.responseTiming(),
                "output_duration_seconds": round(duration * 100) / 100,
                "file_size_bytes": fileSize,
                "resolution": "\(actualWidth)x\(actualHeight)",
                "codec": codec,
                "fps": result.fps,
                "source_count": spec.sources.count,
                "segment_count": spec.segments.count,
                "captions_applied": captionsApplied,
                "raw": response,
            ])

            return .init(content: [.text(text: String(data: responseData, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)
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

    /// Load word timestamps for a transcript reference. Accepts either "project/source" or bare "source".
    /// Bare source is resolved within `defaultProject`.
    static func loadWords(
        transcriptId: String,
        defaultProject: String,
        store: TranscriptStore
    ) throws -> [TranscriptWord] {
        let project: String
        let source: String
        if let parts = DataPaths.splitCompoundId(transcriptId) {
            project = parts.project
            source = parts.source
        } else {
            project = defaultProject
            source = transcriptId
        }
        let entries = try store.getWords(project: project, source: source)
        return entries.map { entry in
            TranscriptWord(
                word: entry.word,
                startTime: entry.start,
                endTime: entry.end,
                confidence: entry.confidence
            )
        }
    }
}

// MARK: - Remapping helpers (unchanged from prior implementation)

/// Remap transcript word timestamps from source-video time to composition time.
func remapTranscript(_ data: TranscriptData, segments: [SegmentSpec]) -> TranscriptData {
    var mappings: [(sourceStart: Double, sourceEnd: Double, compositionStart: Double, speed: Double)] = []
    var compositionTime = 0.0
    for (index, seg) in segments.enumerated() {
        let speed = seg.speed ?? 1.0
        let duration = (seg.end - seg.start) / speed

        if index > 0, let transition = seg.transition, transition.type == .crossfade {
            let clamped = min(transition.duration, duration)
            compositionTime -= clamped
        }

        mappings.append((seg.start, seg.end, compositionTime, speed))
        compositionTime += duration
    }

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

func remapMultiSourceTranscript(sourceTranscripts: [String: [TranscriptWord]], segments: [SegmentSpec]) -> TranscriptData {
    var compositionTime = 0.0
    var remapped: [TranscriptWord] = []
    var fullTextParts: [String] = []

    // Helper to decide whether a segment is a cross-cut (b-roll visual
    // overlay, not a timeline-advancing segment). Mirrors the logic in
    // CompositionBuilder.swift.
    func isCrossCut(_ segIdx: Int) -> Bool {
        guard segIdx > 0 else { return false }
        let seg = segments[segIdx]
        if let explicit = seg.audioFromPrev { return explicit }
        let prev = segments[segIdx - 1]
        return (seg.volume ?? 1.0) == 0 && prev.sourceId != seg.sourceId
    }

    // Track whether we've seen at least one non-cross-cut segment so the
    // crossfade pullback behaves identically to CompositionBuilder's
    // `speakerSegIdx > 0` guard. Cross-cut segments don't cause a pullback
    // because they don't advance the timeline.
    var speakerSegCount = 0

    for (segIdx, seg) in segments.enumerated() {
        // ── Cross-cut: visual overlay only, no timeline advance, no words.
        // The speaker's own audio plays continuously underneath on the A/B
        // track; captions come only from the speaker segments themselves,
        // not from any source window the editor chose to skip.
        if isCrossCut(segIdx) {
            captionLog("[remapMultiSource] seg[\(segIdx)] CROSS-CUT source='\(seg.sourceId)' → no timeline advance, no bridge words (overlay model)")
            continue
        }

        let speed = seg.speed ?? 1.0
        let segDuration = (seg.end - seg.start) / speed

        if speakerSegCount > 0, let transition = seg.transition, transition.type == .crossfade {
            let clamped = min(transition.duration, segDuration)
            compositionTime -= clamped
        }

        guard let words = sourceTranscripts[seg.sourceId] else {
            captionLog("[remapMultiSource] seg[\(segIdx)]: no transcript for source '\(seg.sourceId)', skipping")
            compositionTime += segDuration
            speakerSegCount += 1
            continue
        }

        var segWords: [String] = []
        for word in words {
            if word.startTime >= seg.start && word.startTime < seg.end {
                let newStart = compositionTime + (word.startTime - seg.start) / speed
                let clampedEnd = min(word.endTime, seg.end)
                let newEnd = compositionTime + (clampedEnd - seg.start) / speed
                if newEnd <= newStart { continue }
                remapped.append(TranscriptWord(
                    word: word.word,
                    startTime: newStart,
                    endTime: newEnd,
                    confidence: word.confidence
                ))
                segWords.append(word.word)
            }
        }

        captionLog("[remapMultiSource] seg[\(segIdx)] source='\(seg.sourceId)' \(seg.start)-\(seg.end) → comp=\(round(compositionTime*1000)/1000): \(segWords.count) words")
        if !segWords.isEmpty {
            fullTextParts.append(segWords.joined(separator: " "))
        }
        compositionTime += segDuration
        speakerSegCount += 1
    }

    captionLog("[remapMultiSource] Total: \(remapped.count) words, compositionDuration=\(round(compositionTime * 1000) / 1000)s")

    return TranscriptData(
        words: remapped,
        fullText: fullTextParts.joined(separator: " "),
        durationSeconds: compositionTime
    )
}

func remapOverlaySources(
    sourceTranscripts: [String: [TranscriptWord]],
    overlays: [Overlay],
    excludeSourceIds: Set<String>
) -> [TranscriptWord] {
    var result: [TranscriptWord] = []
    for overlay in overlays {
        guard let overlaySourceId = overlay.sourceId,
              !excludeSourceIds.contains(overlaySourceId),
              let words = sourceTranscripts[overlaySourceId] else { continue }
        let srcStart = overlay.sourceStart ?? 0
        let overlayDuration = overlay.end - overlay.start
        let srcEnd = srcStart + overlayDuration
        for word in words {
            if word.startTime >= srcStart && word.startTime < srcEnd {
                let newStart = overlay.start + (word.startTime - srcStart)
                let clampedEnd = min(word.endTime, srcEnd)
                let newEnd = overlay.start + (clampedEnd - srcStart)
                if newEnd <= newStart { continue }
                result.append(TranscriptWord(
                    word: word.word,
                    startTime: newStart,
                    endTime: newEnd,
                    confidence: word.confidence
                ))
            }
        }
    }
    captionLog("[remapOverlaySources] Remapped \(result.count) words from overlay sources (excluded: \(excludeSourceIds.sorted()))")
    return result
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
