import Foundation
import MCP

package enum RerenderTool {
    package static let tool = Tool(
        name: "reelabs_rerender",
        description: "Re-render a previous render with partial overrides. Loads the stored spec, deep-merges your overrides, and re-renders. render_id is a compound 'project/render' string.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "render_id": .object([
                    "type": .string("string"),
                    "description": .string("Compound 'project/render' ID (from reelabs_render response)")
                ]),
                "overrides": .object([
                    "type": .string("object"),
                    "description": .string("Partial RenderSpec fields to override (captions, quality, overlays, audio, aspectRatio, fps, resolution, outputPath)")
                ]),
                "output_path": .object([
                    "type": .string("string"),
                    "description": .string("Override output path. If omitted, auto-generates based on the original.")
                ])
            ]),
            "required": .array([.string("render_id")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        renderStore: RenderStore,
        transcriptStore: TranscriptStore,
        projectStore: ProjectStore,
        presetStore: PresetStore
    ) async -> CallTool.Result {
        guard let id = arguments?["render_id"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: render_id", annotations: nil, _meta: nil)], isError: true)
        }
        guard let parts = DataPaths.splitCompoundId(id) else {
            return .init(content: [.text(text: "Invalid render_id. Expected 'project/render'.", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            guard let loaded = try renderStore.get(project: parts.project, render: parts.source) else {
                return .init(content: [.text(text: "Render not found: \(id)", annotations: nil, _meta: nil)], isError: true)
            }
            guard let specJson = loaded.specJson else {
                return .init(content: [.text(text: "Render \(id) has no embedded spec", annotations: nil, _meta: nil)], isError: true)
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let specData = specJson.data(using: .utf8) else {
                return .init(content: [.text(text: "Render \(id) spec contains invalid encoding", annotations: nil, _meta: nil)], isError: true)
            }
            var baseSpec = try decoder.decode(RenderSpec.self, from: specData)

            if let overrides = arguments?["overrides"] {
                let overrideData = try JSONSerialization.data(withJSONObject: overrides.toJSONObject())
                let overrideSpec = try decoder.decode(PartialRenderSpec.self, from: overrideData)
                baseSpec = mergeRenderSpec(base: baseSpec, overrides: overrideSpec)
            }

            if let outputPathValue = arguments?["output_path"], let outputPath = outputPathValue.stringValue {
                baseSpec = baseSpec.withOutputPath(outputPath)
            } else if arguments?["overrides"] != nil {
                let originalPath = baseSpec.outputPath
                let url = URL(fileURLWithPath: originalPath)
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                let dir = url.deletingLastPathComponent().path
                let newPath = "\(dir)/\(stem)_rerender.\(ext)"
                baseSpec = baseSpec.withOutputPath(newPath)
            }

            // Re-encode merged spec and delegate to RenderTool
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let mergedData = try encoder.encode(baseSpec)
            let mergedJson = try JSONSerialization.jsonObject(with: mergedData)
            let specValue = Value(mergedJson)

            var args: [String: Value] = [
                "spec": specValue,
                "project": .string(parts.project)
            ]
            // Preserve the original render's slug as the base for the new render
            args["slug"] = .string(loaded.record.slug + "-rerender")

            return await RenderTool.handle(
                arguments: args,
                renderStore: renderStore,
                transcriptStore: transcriptStore,
                projectStore: projectStore,
                presetStore: presetStore
            )
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, _):
                detail = "Missing field: '\(key.stringValue)'"
            case .typeMismatch(let type, let context):
                detail = "Type mismatch for '\(context.codingPath.map(\.stringValue).joined(separator: "."))': expected \(type)"
            default:
                detail = decodingError.localizedDescription
            }
            return .init(content: [.text(text: "Re-render spec error: \(detail)", annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(content: [.text(text: "Re-render failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}

// MARK: - Partial spec for overrides (all fields optional)

private struct PartialRenderSpec: Codable {
    let sources: [RenderSpec.Source]?
    let segments: [SegmentSpec]?
    let captions: CaptionConfig?
    let audio: AudioConfig?
    let quality: QualityConfig?
    let overlays: [Overlay]?
    let aspectRatio: AspectRatio?
    let resolution: Resolution?
    let fps: Double?
    let lut: LUTSpec?
    let outputPath: String?
}

private func mergeRenderSpec(base: RenderSpec, overrides: PartialRenderSpec) -> RenderSpec {
    RenderSpec(
        sources: overrides.sources ?? base.sources,
        segments: overrides.segments ?? base.segments,
        captions: mergeCaptions(base: base.captions, override: overrides.captions),
        audio: mergeAudio(base: base.audio, override: overrides.audio),
        quality: mergeQuality(base: base.quality, override: overrides.quality),
        overlays: overrides.overlays ?? base.overlays,
        aspectRatio: overrides.aspectRatio ?? base.aspectRatio,
        resolution: overrides.resolution ?? base.resolution,
        fps: overrides.fps ?? base.fps,
        lut: overrides.lut ?? base.lut,
        outputPath: overrides.outputPath ?? base.outputPath
    )
}

private func mergeCaptions(base: CaptionConfig?, override: CaptionConfig?) -> CaptionConfig? {
    guard let o = override else { return base }
    guard let b = base else { return o }
    return CaptionConfig(
        preset: o.preset ?? b.preset,
        transcriptId: o.transcriptId ?? b.transcriptId,
        fontFamily: o.fontFamily ?? b.fontFamily,
        fontSize: o.fontSize ?? b.fontSize,
        fontWeight: o.fontWeight ?? b.fontWeight,
        color: o.color ?? b.color,
        highlightColor: o.highlightColor ?? b.highlightColor,
        position: o.position ?? b.position,
        allCaps: o.allCaps ?? b.allCaps,
        shadow: o.shadow ?? b.shadow,
        wordsPerGroup: o.wordsPerGroup ?? b.wordsPerGroup,
        punctuation: o.punctuation ?? b.punctuation
    )
}

private func mergeAudio(base: AudioConfig?, override: AudioConfig?) -> AudioConfig? {
    guard let o = override else { return base }
    guard let b = base else { return o }
    return AudioConfig(
        musicPath: o.musicPath ?? b.musicPath,
        musicVolume: o.musicVolume ?? b.musicVolume,
        normalizeAudio: o.normalizeAudio ?? b.normalizeAudio,
        duckingEnabled: o.duckingEnabled ?? b.duckingEnabled,
        duckingLevel: o.duckingLevel ?? b.duckingLevel
    )
}

private func mergeQuality(base: QualityConfig?, override: QualityConfig?) -> QualityConfig? {
    guard let o = override else { return base }
    guard let b = base else { return o }
    return QualityConfig(
        codec: o.codec ?? b.codec,
        bitrate: o.bitrate ?? b.bitrate,
        quality: o.quality ?? b.quality
    )
}

private extension Value {
    init(_ jsonObject: Any) {
        if let dict = jsonObject as? [String: Any] {
            var obj: [String: Value] = [:]
            for (k, v) in dict {
                obj[k] = Value(v)
            }
            self = .object(obj)
        } else if let arr = jsonObject as? [Any] {
            self = .array(arr.map { Value($0) })
        } else if let str = jsonObject as? String {
            self = .string(str)
        } else if let num = jsonObject as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                self = .bool(num.boolValue)
            } else if num.doubleValue == Double(num.intValue) {
                self = .int(num.intValue)
            } else {
                self = .double(num.doubleValue)
            }
        } else if let bool = jsonObject as? Bool {
            self = .bool(bool)
        } else if jsonObject is NSNull {
            self = .null
        } else {
            self = .null
        }
    }
}
