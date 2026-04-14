import AppKit
import AVFoundation
import Foundation

/// Append a line to ~/Desktop/reelabs-caption-debug.log for debugging
func captionLog(_ message: String) {
    let logPath = NSHomeDirectory() + "/Desktop/reelabs-caption-debug.log"
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    fputs(line, stderr)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

final class ExportService: Sendable {

    struct ExportResult {
        let captionsApplied: Bool
        let captionSublayerCount: Int
    }

    @discardableResult
    func export(
        composition: AVMutableComposition,
        videoComposition: AVVideoComposition?,
        audioMix: AVMutableAudioMix?,
        outputURL: URL,
        captionConfig: CaptionConfig? = nil,
        transcriptData: TranscriptData? = nil,
        renderSize: CGSize,
        quality: QualityConfig? = nil
    ) async throws -> ExportResult {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let codec = quality?.codec ?? .h264
        let preset = Self.exportPreset(for: renderSize, codec: codec)

        // --- DIAGNOSTICS: collect composition state before export ---
        var diag: [String] = []
        diag.append("=== EXPORT DIAGNOSTICS ===")
        diag.append("selectedPreset: \(preset)")
        diag.append("renderSize: \(Int(renderSize.width))x\(Int(renderSize.height))")
        diag.append("codec: \(codec.rawValue)")
        diag.append("compositionDuration: \(CMTimeGetSeconds(composition.duration))s")

        // Composition tracks
        let allTracks = composition.tracks
        diag.append("compositionTracks: \(allTracks.count)")
        for (i, track) in allTracks.enumerated() {
            let timeRange = track.timeRange
            let start = CMTimeGetSeconds(timeRange.start)
            let dur = CMTimeGetSeconds(timeRange.duration)
            let hasMedia = dur > 0
            let segments = track.segments.count
            diag.append("  track[\(i)] id=\(track.trackID) type=\(track.mediaType.rawValue) duration=\(round(dur * 1000) / 1000)s hasMedia=\(hasMedia) segments=\(segments)")
            // Format descriptions
            for (j, seg) in track.segments.enumerated() {
                let segStart = CMTimeGetSeconds(seg.timeMapping.target.start)
                let segDur = CMTimeGetSeconds(seg.timeMapping.target.duration)
                let isEmpty = seg.isEmpty
                diag.append("    seg[\(j)] targetStart=\(round(segStart * 1000) / 1000) targetDur=\(round(segDur * 1000) / 1000) empty=\(isEmpty)")
            }
        }

        // Compatible presets
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        let selectedIsCompatible = compatiblePresets.contains(preset)
        diag.append("selectedPresetCompatible: \(selectedIsCompatible)")
        diag.append("compatiblePresets: \(compatiblePresets.sorted().joined(separator: ", "))")

        // Video composition info
        if let vc = videoComposition {
            diag.append("videoComposition: renderSize=\(Int(vc.renderSize.width))x\(Int(vc.renderSize.height)) frameDuration=\(vc.frameDuration.value)/\(vc.frameDuration.timescale) instructions=\(vc.instructions.count)")
            for (i, instr) in vc.instructions.enumerated() {
                let range = instr.timeRange
                let start = CMTimeGetSeconds(range.start)
                let dur = CMTimeGetSeconds(range.duration)
                diag.append("  instruction[\(i)] start=\(round(start * 1000) / 1000) duration=\(round(dur * 1000) / 1000)")
                if let vcInstr = instr as? AVVideoCompositionInstruction {
                    diag.append("    layerInstructions: \(vcInstr.layerInstructions.count)")
                    for (j, li) in vcInstr.layerInstructions.enumerated() {
                        diag.append("      layer[\(j)] trackID=\(li.trackID)")
                    }
                }
            }
        } else {
            diag.append("videoComposition: nil")
        }

        // Audio mix info
        if let am = audioMix {
            diag.append("audioMix: \(am.inputParameters.count) parameters")
            for (i, param) in am.inputParameters.enumerated() {
                diag.append("  param[\(i)] trackID=\(param.trackID)")
            }
        } else {
            diag.append("audioMix: nil")
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: preset
        ) else {
            diag.append("SESSION CREATION FAILED for preset: \(preset)")
            throw ExportError.exportFailed(diag.joined(separator: "\n"))
        }
        diag.append("sessionCreated: true")
        diag.append("supportedFileTypes: \(session.supportedFileTypes.map(\.rawValue))")

        // --- Log audio state for debugging ---
        let audioTracks = composition.tracks(withMediaType: .audio)
        captionLog("[Audio] composition audioTracks: \(audioTracks.count)")
        for (i, at) in audioTracks.enumerated() {
            let segs = at.segments ?? []
            let totalSec = CMTimeGetSeconds(at.timeRange.duration)
            captionLog("[Audio]   track[\(i)] id=\(at.trackID) segments=\(segs.count) duration=\(round(totalSec * 100) / 100)s")
            for (j, seg) in segs.enumerated() {
                let segStart = CMTimeGetSeconds(seg.timeMapping.target.start)
                let segDur = CMTimeGetSeconds(seg.timeMapping.target.duration)
                captionLog("[Audio]     seg[\(j)] start=\(round(segStart * 100) / 100) dur=\(round(segDur * 100) / 100) empty=\(seg.isEmpty)")
            }
        }
        if let am = audioMix {
            captionLog("[Audio] audioMix: \(am.inputParameters.count) params")
            for (i, p) in am.inputParameters.enumerated() {
                captionLog("[Audio]   param[\(i)] trackID=\(p.trackID)")
            }
        } else {
            captionLog("[Audio] audioMix: nil")
        }

        // Apply caption burn-in if configured
        var didApplyCaptions = false
        var captionSublayerCount = 0
        captionLog("[ReeLabs Caption] === CAPTION PIPELINE START ===")
        captionLog("[ReeLabs Caption] captionConfig: \(captionConfig != nil), transcriptData: \(transcriptData != nil)")
        if let captionConfig, let transcriptData {
            captionLog("[ReeLabs Caption] words count: \(transcriptData.words.count)")
            if transcriptData.words.isEmpty {
                captionLog("[ReeLabs Caption] SKIPPED: 0 words in transcript")
                diag.append("captionSkipped: transcript has 0 words")
                if let videoComposition {
                    session.videoComposition = videoComposition
                }
            } else {
                // Log first few words for debugging
                for (i, w) in transcriptData.words.prefix(5).enumerated() {
                    captionLog("[ReeLabs Caption] word[\(i)]: '\(w.word)' start=\(w.startTime) end=\(w.endTime)")
                }

                // Resolve base video composition — create pass-through if nil
                let baseVC: AVVideoComposition
                if let vc = videoComposition {
                    baseVC = vc
                    captionLog("[ReeLabs Caption] Using existing videoComposition from builder")
                } else {
                    let videoTracks = composition.tracks(withMediaType: .video)
                    captionLog("[ReeLabs Caption] Creating pass-through for \(videoTracks.count) video tracks")
                    // Build pass-through using custom compositor
                    let ptLayers = videoTracks.map { track in
                        LayerInfo(
                            trackID: track.trackID,
                            preferredTransform: .identity,
                            naturalSize: renderSize,
                            transform: .identity,
                            transformEnd: nil,
                            opacity: 1.0, opacityEnd: nil,
                            targetRect: nil, cornerRadiusFraction: nil, cropRect: nil
                        )
                    }
                    let ptInstr = CompositorInstruction(
                        timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                        layers: ptLayers,
                        renderSize: renderSize
                    )
                    let ptVC = AVMutableVideoComposition()
                    ptVC.frameDuration = CMTime(value: 1, timescale: 30)
                    ptVC.renderSize = renderSize
                    ptVC.instructions = [ptInstr]
                    ptVC.customVideoCompositorClass = VideoCompositor.self
                    baseVC = ptVC
                    diag.append("videoComposition: created pass-through for captions")
                }

                captionLog("[ReeLabs Caption] baseVC: renderSize=\(Int(baseVC.renderSize.width))x\(Int(baseVC.renderSize.height)), instructions=\(baseVC.instructions.count), frameDuration=\(baseVC.frameDuration.value)/\(baseVC.frameDuration.timescale)")

                let totalDuration = CMTimeGetSeconds(composition.duration)
                captionLog("[ReeLabs Caption] Creating caption layer: videoSize=\(Int(renderSize.width))x\(Int(renderSize.height)), totalDuration=\(totalDuration)s")

                let captionLayer = CaptionLayer.createOverlay(
                    transcriptData: transcriptData,
                    config: captionConfig,
                    videoSize: renderSize,
                    totalDuration: totalDuration
                )
                captionSublayerCount = captionLayer.sublayers?.count ?? 0
                captionLog("[ReeLabs Caption] captionLayer created: sublayers=\(captionSublayerCount), frame=\(captionLayer.frame)")

                // Inspect caption layer tree
                if let subs = captionLayer.sublayers {
                    for (i, sub) in subs.prefix(3).enumerated() {
                        captionLog("[ReeLabs Caption]   group[\(i)]: frame=\(sub.frame), opacity=\(sub.opacity), sublayers=\(sub.sublayers?.count ?? 0)")
                        if let innerSubs = sub.sublayers {
                            for (j, inner) in innerSubs.prefix(3).enumerated() {
                                captionLog("[ReeLabs Caption]     text[\(j)]: frame=\(inner.frame), opacity=\(inner.opacity), animations=\(inner.animationKeys()?.count ?? 0)")
                                if let textLayer = inner as? CATextLayer {
                                    let strDesc = (textLayer.string as? NSAttributedString)?.string ?? String(describing: textLayer.string ?? "nil")
                                    captionLog("[ReeLabs Caption]     text[\(j)]: content='\(strDesc.prefix(30))', fgColor=\(textLayer.foregroundColor?.components ?? [])")
                                }
                            }
                        }
                    }
                } else {
                    captionLog("[ReeLabs Caption] WARNING: captionLayer has NO sublayers!")
                }

                let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                captionLog("[ReeLabs Caption] NSScreen.main: \(NSScreen.main != nil), backingScale: \(scale)")

                let videoLayer = CALayer()
                videoLayer.frame = CGRect(origin: .zero, size: renderSize)
                videoLayer.contentsScale = scale

                let parentLayer = CALayer()
                parentLayer.frame = CGRect(origin: .zero, size: renderSize)
                parentLayer.isGeometryFlipped = true
                parentLayer.contentsScale = scale
                parentLayer.addSublayer(videoLayer)
                parentLayer.addSublayer(captionLayer)



                captionLog("[ReeLabs Caption] Layer hierarchy: parent(\(parentLayer.sublayers?.count ?? 0) sublayers) > video + caption")

                let animToolConfig = AVVideoCompositionCoreAnimationTool.Configuration(
                    postProcessingAsVideoLayer: videoLayer,
                    containingLayer: parentLayer
                )
                let animTool = AVVideoCompositionCoreAnimationTool(configuration: animToolConfig)
                captionLog("[ReeLabs Caption] animTool created: \(type(of: animTool))")

                // Build caption video composition preserving custom compositor.
                // animationTool + customVideoCompositorClass must coexist.
                let captionVC = AVMutableVideoComposition()
                captionVC.animationTool = animTool
                captionVC.frameDuration = baseVC.frameDuration
                captionVC.instructions = baseVC.instructions
                captionVC.renderSize = baseVC.renderSize
                captionVC.customVideoCompositorClass = baseVC.customVideoCompositorClass
                let finalVC: AVVideoComposition = captionVC
                session.videoComposition = finalVC
                didApplyCaptions = true

                // Verify the animation tool survived
                let animToolRetained = finalVC.animationTool != nil
                captionLog("[ReeLabs Caption] finalVC assigned: animTool retained=\(animToolRetained), instructions=\(finalVC.instructions.count), renderSize=\(Int(finalVC.renderSize.width))x\(Int(finalVC.renderSize.height))")
                captionLog("[ReeLabs Caption] session.videoComposition set: \(session.videoComposition != nil)")
                captionLog("[ReeLabs Caption] === CAPTION PIPELINE END (applied=true) ===")

                diag.append("captionAnimationTool: applied via Configuration API (animTool in initializer)")
                diag.append("captionAnimToolRetained: \(animToolRetained)")
                diag.append("captionLayer sublayers: \(captionSublayerCount)")
            }
        } else if let videoComposition {
            session.videoComposition = videoComposition
            diag.append("videoComposition: assigned (no captions)")
            captionLog("[ReeLabs Caption] No captions requested, using base videoComposition")
        } else {
            captionLog("[ReeLabs Caption] No captions and no videoComposition")
        }

        if let audioMix {
            session.audioMix = audioMix
        }

        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            let nsError = error as NSError
            diag.append("=== EXPORT FAILED ===")
            diag.append("domain: \(nsError.domain)")
            diag.append("code: \(nsError.code)")
            diag.append("description: \(nsError.localizedDescription)")
            diag.append("failureReason: \(nsError.localizedFailureReason ?? "nil")")
            diag.append("recoverySuggestion: \(nsError.localizedRecoverySuggestion ?? "nil")")
            // Full userInfo dump
            for (key, value) in nsError.userInfo {
                diag.append("userInfo[\(key)]: \(value)")
            }
            // Underlying error chain
            var underlying: NSError? = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            var depth = 0
            while let ue = underlying {
                depth += 1
                diag.append("underlying[\(depth)]: domain=\(ue.domain) code=\(ue.code) desc=\(ue.localizedDescription)")
                for (key, value) in ue.userInfo {
                    diag.append("  userInfo[\(key)]: \(value)")
                }
                underlying = ue.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            // Session state after failure
            diag.append("sessionStatus: \(session.status.rawValue)")
            if let sessionError = session.error as? NSError {
                diag.append("sessionError: domain=\(sessionError.domain) code=\(sessionError.code)")
            }
            throw ExportError.exportFailed(diag.joined(separator: "\n"))
        }
        return ExportResult(captionsApplied: didApplyCaptions, captionSublayerCount: captionSublayerCount)
    }

    /// Pick a dimension-specific preset that supports AVVideoComposition.
    /// AVAssetExportPresetHighestQuality does NOT support video composition,
    /// causing transforms, scaling, and caption overlays to be silently ignored.
    /// Use the LARGER dimension to find the right preset bucket, matching the
    /// standard frame sizes (720p, 1080p, 4K) regardless of orientation.
    private static func exportPreset(for renderSize: CGSize, codec: QualityConfig.Codec) -> String {
        let maxDim = max(renderSize.width, renderSize.height)
        switch (codec, maxDim) {
        case (.hevc, ...720):  return AVAssetExportPresetHEVC1920x1080  // no HEVC 720p preset
        case (.hevc, ...1920): return AVAssetExportPresetHEVC1920x1080
        case (.hevc, _):       return AVAssetExportPresetHEVC3840x2160
        case (.h264, ...720):  return AVAssetExportPreset1280x720
        case (.h264, ...1920): return AVAssetExportPreset1920x1080
        case (.h264, _):       return AVAssetExportPreset3840x2160
        }
    }
}

enum ExportError: LocalizedError {
    case sessionCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed: "Failed to create export session"
        case .exportFailed(let msg): "Export failed: \(msg)"
        }
    }
}
