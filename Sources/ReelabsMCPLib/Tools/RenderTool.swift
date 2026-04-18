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
            let specObject = specValue.toJSONObject()
            guard JSONSerialization.isValidJSONObject(specObject) else {
                return .init(content: [.text(text: "Invalid 'spec': must be a JSON object (dictionary), not a string or scalar. Pass the RenderSpec as structured JSON, not a JSON-encoded string.", annotations: nil, _meta: nil)], isError: true)
            }
            let specData = try JSONSerialization.data(withJSONObject: specObject)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let inputSpec = try decoder.decode(RenderSpec.self, from: specData)

            // Resolve the project for this render
            let projectSlug: String
            if let explicit = arguments?["project"]?.stringValue {
                projectSlug = explicit
            } else if let firstSource = inputSpec.sources.first {
                projectSlug = DataPaths.deriveProjectSlug(fromSourcePath: firstSource.path)
            } else {
                return .init(content: [.text(text: "No project arg and no sources to derive one from.", annotations: nil, _meta: nil)], isError: true)
            }
            _ = try projectStore.createWithSlug(slug: projectSlug)

            // Encode the original (unresolved) spec for storage so rerenders re-pick up preset values.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let specJson = String(data: try encoder.encode(inputSpec), encoding: .utf8) ?? "{}"

            // --- Preset resolution ---
            // Merge preset values into each config; inline overrides from inputSpec win over preset defaults.
            // `spec` below is the resolved form and is used for everything downstream.

            var resolvedCaptionConfig = inputSpec.captions
            if let presetName = inputSpec.captions?.preset {
                guard let presetConfig = try presetStore.get(category: "captions", name: presetName, as: CaptionConfig.self) else {
                    return .init(content: [.text(text: "Caption error: preset '\(presetName)' not found in presets/captions/.", annotations: nil, _meta: nil)], isError: true)
                }
                resolvedCaptionConfig = mergeCaptionConfig(base: presetConfig, override: inputSpec.captions)
            }

            var resolvedAudioConfig = inputSpec.audio
            if let presetName = inputSpec.audio?.preset {
                guard let presetConfig = try presetStore.get(category: "audio", name: presetName, as: AudioConfig.self) else {
                    return .init(content: [.text(text: "Audio error: preset '\(presetName)' not found in presets/audio/.", annotations: nil, _meta: nil)], isError: true)
                }
                resolvedAudioConfig = mergeAudioConfig(base: presetConfig, override: inputSpec.audio)
            }

            var resolvedFramingConfig = inputSpec.framing
            if let presetName = inputSpec.framing?.preset {
                guard let presetConfig = try presetStore.get(category: "framing", name: presetName, as: FramingConfig.self) else {
                    return .init(content: [.text(text: "Framing error: preset '\(presetName)' not found in presets/framing/.", annotations: nil, _meta: nil)], isError: true)
                }
                resolvedFramingConfig = mergeFramingConfig(base: presetConfig, override: inputSpec.framing)
            }

            let resolvedSegments: [SegmentSpec] = try inputSpec.segments.enumerated().map { (idx, seg) -> SegmentSpec in
                var resolvedTransition = seg.transition
                if let transitionPresetName = seg.transition?.preset {
                    guard let presetTransition = try presetStore.get(category: "transitions", name: transitionPresetName, as: Transition.self) else {
                        throw NSError(
                            domain: "RenderTool", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Transition error: preset '\(transitionPresetName)' not found in presets/transitions/."]
                        )
                    }
                    resolvedTransition = mergeTransition(base: presetTransition, override: seg.transition)
                }

                var resolvedTransform = seg.transform
                var resolvedKeyframes = seg.keyframes
                if let framing = resolvedFramingConfig, seg.transform == nil, seg.keyframes == nil {
                    let segDuration = (seg.end - seg.start) / (seg.speed ?? 1.0)
                    let compiled = compileFramingForSegment(framing, segmentIndex: idx, segmentDuration: segDuration)
                    resolvedTransform = compiled.transform
                    resolvedKeyframes = compiled.keyframes
                }

                return SegmentSpec(
                    sourceId: seg.sourceId,
                    start: seg.start,
                    end: seg.end,
                    speed: seg.speed,
                    transform: resolvedTransform,
                    keyframes: resolvedKeyframes,
                    transition: resolvedTransition,
                    volume: seg.volume
                )
            }

            let spec = inputSpec.withResolvedConfigs(
                segments: resolvedSegments,
                captions: resolvedCaptionConfig,
                audio: resolvedAudioConfig,
                overlays: inputSpec.overlays
            )
            // --- End preset resolution ---

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

        if index > 0, let transition = seg.transition, transition.type == .crossfade, let transitionDuration = transition.duration {
            let clamped = min(transitionDuration, duration)
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

    for (segIdx, seg) in segments.enumerated() {
        let speed = seg.speed ?? 1.0
        let segDuration = (seg.end - seg.start) / speed

        if segIdx > 0, let transition = seg.transition, transition.type == .crossfade, let transitionDuration = transition.duration {
            let clamped = min(transitionDuration, segDuration)
            compositionTime -= clamped
        }

        guard let words = sourceTranscripts[seg.sourceId] else {
            captionLog("[remapMultiSource] seg[\(segIdx)]: no transcript for source '\(seg.sourceId)', skipping")
            compositionTime += segDuration
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

        captionLog("[remapMultiSource] seg[\(segIdx)] source='\(seg.sourceId)' \(seg.start)-\(seg.end) → comp=\(compositionTime): \(segWords.count) words")
        if !segWords.isEmpty {
            fullTextParts.append(segWords.joined(separator: " "))
        }
        compositionTime += segDuration
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

private func mergeAudioConfig(base: AudioConfig, override: AudioConfig?) -> AudioConfig {
    guard let o = override else { return base }
    return AudioConfig(
        preset: o.preset ?? base.preset,
        musicPath: o.musicPath ?? base.musicPath,
        musicVolume: o.musicVolume ?? base.musicVolume,
        normalizeAudio: o.normalizeAudio ?? base.normalizeAudio,
        duckingEnabled: o.duckingEnabled ?? base.duckingEnabled,
        duckingLevel: o.duckingLevel ?? base.duckingLevel
    )
}

private func mergeFramingConfig(base: FramingConfig, override: FramingConfig?) -> FramingConfig {
    guard let o = override else { return base }
    return FramingConfig(
        preset: o.preset ?? base.preset,
        kind: o.kind ?? base.kind,
        startScale: o.startScale ?? base.startScale,
        endScale: o.endScale ?? base.endScale,
        startPanX: o.startPanX ?? base.startPanX,
        startPanY: o.startPanY ?? base.startPanY,
        endPanX: o.endPanX ?? base.endPanX,
        endPanY: o.endPanY ?? base.endPanY,
        scale: o.scale ?? base.scale,
        panX: o.panX ?? base.panX,
        panY: o.panY ?? base.panY,
        alternation: o.alternation ?? base.alternation
    )
}

private func mergeTransition(base: Transition, override: Transition?) -> Transition {
    guard let o = override else { return base }
    return Transition(
        preset: o.preset ?? base.preset,
        type: o.type ?? base.type,
        duration: o.duration ?? base.duration
    )
}

/// Compile a FramingConfig into per-segment framing (transform for static, keyframes for animated).
/// Returns nil values when the framing preset doesn't require that representation.
private func compileFramingForSegment(
    _ framing: FramingConfig,
    segmentIndex: Int,
    segmentDuration: Double
) -> (transform: TransformSpec?, keyframes: [Keyframe]?) {
    let kind = framing.kind ?? "keyframes"

    if kind == "static" {
        let transform = TransformSpec(
            scale: framing.scale,
            panX: framing.panX,
            panY: framing.panY
        )
        return (transform, nil)
    }

    // Animated keyframes. If alternation is on, odd segments swap start/end endpoints.
    let alternated = (framing.alternation ?? false) && (segmentIndex % 2 == 1)

    let startScale = alternated ? (framing.endScale ?? 1.0) : (framing.startScale ?? 1.0)
    let endScale = alternated ? (framing.startScale ?? 1.0) : (framing.endScale ?? 1.0)
    let startPanX = alternated ? (framing.endPanX ?? 0) : (framing.startPanX ?? 0)
    let startPanY = alternated ? (framing.endPanY ?? 0) : (framing.startPanY ?? 0)
    let endPanX = alternated ? (framing.startPanX ?? 0) : (framing.endPanX ?? 0)
    let endPanY = alternated ? (framing.startPanY ?? 0) : (framing.endPanY ?? 0)

    let keyframes = [
        Keyframe(time: 0, scale: startScale, panX: startPanX, panY: startPanY),
        Keyframe(time: segmentDuration, scale: endScale, panX: endPanX, panY: endPanY)
    ]
    return (nil, keyframes)
}
