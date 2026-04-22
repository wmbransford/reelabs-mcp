import AppKit
@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

/// Append a line to ~/Desktop/reelabs-caption-debug.log for debugging
func captionLog(_ message: String) {
    let logPath = NSHomeDirectory() + "/Desktop/reelabs-caption-debug.log"
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    fputs(line, stderr)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        guard let lineData = line.data(using: .utf8) else { return }
        handle.write(lineData)
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
        quality: QualityConfig? = nil,
        captionExclusionZones: [ClosedRange<Double>] = [],
        lut: LUTData? = nil,
        lutStrength: Double = 1.0,
        profiler: RenderProfiler? = nil
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

        // === LUT PIPELINE ===
        // Install the compiled LUT filter globally on VideoCompositor for the
        // duration of this render. Pattern mirrors `VideoCompositor.captionOverlay`.
        // Using a static slot is acceptable because the render queue serializes
        // exports.
        if let lut {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            VideoCompositor.lutFilter = lut.makeFilter(colorSpace: colorSpace)
            VideoCompositor.lutStrength = lutStrength
            captionLog("[LUT] installed: size=\(lut.size) strength=\(lutStrength)")
            diag.append("lut: installed size=\(lut.size) strength=\(lutStrength)")
        } else {
            VideoCompositor.lutFilter = nil
            VideoCompositor.lutStrength = 1.0
        }
        defer {
            VideoCompositor.lutFilter = nil
            VideoCompositor.lutStrength = 1.0
        }

        // === CAPTION PIPELINE ===
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
                let hasCustomCompositor = videoComposition?.customVideoCompositorClass != nil
                captionLog("[ReeLabs Caption] hasCustomCompositor: \(hasCustomCompositor)")

                if hasCustomCompositor {
                    // SINGLE-PASS: render captions directly in the compositor alongside
                    // overlays/transforms/crossfades. Eliminates the two-pass encode.
                    captionLog("[ReeLabs Caption] SINGLE-PASS: captions rendered in compositor")
                    diag.append("captionMode: single-pass (compositor caption rendering)")

                    let totalDuration = CMTimeGetSeconds(composition.duration)
                    let captionBuildStart = CFAbsoluteTimeGetCurrent()
                    let captionOverlay = CaptionLayer.buildCompositorOverlay(
                        transcriptData: transcriptData,
                        config: captionConfig,
                        videoSize: renderSize,
                        totalDuration: totalDuration,
                        exclusionZones: captionExclusionZones
                    )
                    profiler?.record("caption_overlay_build", seconds: CFAbsoluteTimeGetCurrent() - captionBuildStart)

                    if let captionOverlay {
                        captionSublayerCount = captionOverlay.groups.reduce(0) { $0 + $1.baseWords.count + $1.highlightWords.count }
                        captionLog("[ReeLabs Caption] Built compositor caption overlay: \(captionOverlay.groups.count) groups, \(captionSublayerCount) word images")
                        VideoCompositor.captionOverlay = captionOverlay
                    }

                    defer { VideoCompositor.captionOverlay = nil }

                    let encodeStart = CFAbsoluteTimeGetCurrent()
                    try await readerWriterExport(
                        composition: composition,
                        videoComposition: videoComposition!,
                        audioMix: audioMix,
                        outputURL: outputURL,
                        renderSize: renderSize,
                        quality: quality
                    )
                    profiler?.record("export_encode", seconds: CFAbsoluteTimeGetCurrent() - encodeStart)

                    return ExportResult(
                        captionsApplied: captionOverlay != nil,
                        captionSublayerCount: captionSublayerCount
                    )
                }
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
            let encodeStart = CFAbsoluteTimeGetCurrent()
            try await session.export(to: outputURL, as: .mp4)
            profiler?.record("export_encode", seconds: CFAbsoluteTimeGetCurrent() - encodeStart)
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
        return ExportResult(captionsApplied: false, captionSublayerCount: captionSublayerCount)
    }

    // MARK: - Reader/Writer Export

    /// Export a composition with a custom compositor using AVAssetReader + AVAssetWriter.
    /// This bypasses AVAssetExportSession's preset-based validation which rejects
    /// compositions containing mixed-codec tracks (error -11841).
    private func readerWriterExport(
        composition: AVMutableComposition,
        videoComposition: AVVideoComposition,
        audioMix: AVMutableAudioMix?,
        outputURL: URL,
        renderSize: CGSize,
        quality: QualityConfig?
    ) async throws {
        let codec = quality?.codec ?? .h264

        // --- OVERLAY DIAGNOSTICS: log all video tracks and their format descriptions ---
        let videoTracksInComp = composition.tracks(withMediaType: .video)
        captionLog("[ReaderWriter] Video tracks in composition: \(videoTracksInComp.count)")
        for (i, track) in videoTracksInComp.enumerated() {
            let segs = track.segments ?? []
            let segDescs = segs.enumerated().map { (j, seg) -> String in
                let ts = CMTimeGetSeconds(seg.timeMapping.target.start)
                let td = CMTimeGetSeconds(seg.timeMapping.target.duration)
                let ss = CMTimeGetSeconds(seg.timeMapping.source.start)
                let sd = CMTimeGetSeconds(seg.timeMapping.source.duration)
                return "seg[\(j)] target=\(round(ts*1000)/1000)..\(round((ts+td)*1000)/1000) source=\(round(ss*1000)/1000)..\(round((ss+sd)*1000)/1000) empty=\(seg.isEmpty)"
            }
            captionLog("[ReaderWriter]   track[\(i)] id=\(track.trackID) segments=\(segs.count)")
            for desc in segDescs {
                captionLog("[ReaderWriter]     \(desc)")
            }
            // Log format descriptions
            let fmtDescs = track.formatDescriptions as? [CMFormatDescription] ?? []
            for (j, fmt) in fmtDescs.enumerated() {
                let mediaType = CMFormatDescriptionGetMediaType(fmt)
                let mediaSubType = CMFormatDescriptionGetMediaSubType(fmt)
                let fourCC = String(format: "%c%c%c%c",
                    (mediaSubType >> 24) & 0xFF,
                    (mediaSubType >> 16) & 0xFF,
                    (mediaSubType >> 8) & 0xFF,
                    mediaSubType & 0xFF)
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                captionLog("[ReaderWriter]     fmt[\(j)] type=\(mediaType) subType=\(fourCC) dims=\(dims.width)x\(dims.height)")
            }
        }

        captionLog("[ReaderWriter] videoComposition: renderSize=\(Int(videoComposition.renderSize.width))x\(Int(videoComposition.renderSize.height)) frameDuration=\(videoComposition.frameDuration.value)/\(videoComposition.frameDuration.timescale) instructions=\(videoComposition.instructions.count)")
        for (i, instr) in videoComposition.instructions.enumerated() {
            let start = CMTimeGetSeconds(instr.timeRange.start)
            let dur = CMTimeGetSeconds(instr.timeRange.duration)
            if let ci = instr as? CompositorInstruction {
                let layerDescs = ci.layers.map { l -> String in
                    let overlayStr = l.targetRect != nil ? " overlay=\(Int(l.targetRect!.width))x\(Int(l.targetRect!.height))@(\(Int(l.targetRect!.origin.x)),\(Int(l.targetRect!.origin.y)))" : ""
                    return "trackID=\(l.trackID)\(overlayStr)"
                }
                captionLog("[ReaderWriter]   instr[\(i)] t=\(round(start*1000)/1000)..\(round((start+dur)*1000)/1000) layers=[\(layerDescs.joined(separator: ", "))] reqIDs=\(ci.requiredSourceTrackIDs?.map { "\($0)" } ?? [])")
            }
        }

        // Configure reader
        let reader = try AVAssetReader(asset: composition)

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracksInComp,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        guard reader.canAdd(videoOutput) else {
            captionLog("[ReaderWriter] ERROR: Cannot add video output to reader")
            throw ExportError.exportFailed("Reader/Writer export: cannot add video output to reader")
        }
        reader.add(videoOutput)

        // Audio output (mixed down)
        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioTracks = composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let ao = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            if let audioMix { ao.audioMix = audioMix }
            if reader.canAdd(ao) {
                reader.add(ao)
                audioOutput = ao
            }
        }

        // Configure writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoCodec: AVVideoCodecType = codec == .hevc ? .hevc : .h264
        let videoBitrate = quality?.bitrate ?? Self.defaultBitrate(for: renderSize, codec: codec)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: codec == .hevc
                    ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                    : AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.exportFailed("Reader/Writer export: cannot add video input to writer")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) {
                writer.add(ai)
                audioInput = ai
            }
        }

        // Start reading/writing
        captionLog("[ReaderWriter] Starting reader...")
        reader.startReading()
        captionLog("[ReaderWriter] Reader status after start: \(reader.status.rawValue)")
        if reader.status == .failed {
            let err = reader.error as? NSError
            let underlying = err?.userInfo[NSUnderlyingErrorKey] as? NSError
            captionLog("[ReaderWriter] READER FAILED IMMEDIATELY: domain=\(err?.domain ?? "?") code=\(err?.code ?? 0) desc=\(err?.localizedDescription ?? "unknown")")
            if let underlying {
                captionLog("[ReaderWriter]   underlying: domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
            }
            throw ExportError.exportFailed(
                "Reader/Writer export reader failed on start: domain=\(err?.domain ?? "?") code=\(err?.code ?? 0) underlying=\(underlying?.code ?? 0) \(err?.localizedDescription ?? "unknown")"
            )
        }

        captionLog("[ReaderWriter] Starting writer...")
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        captionLog("[ReaderWriter] Writer status after start: \(writer.status.rawValue)")

        // Process video and audio concurrently
        captionLog("[ReaderWriter] Beginning sample transfer...")
        let transferStart = CFAbsoluteTimeGetCurrent()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.transferSamples(from: videoOutput, to: videoInput)
            }
            if let audioOutput, let audioInput {
                group.addTask {
                    await self.transferSamples(from: audioOutput, to: audioInput)
                }
            }
            try await group.waitForAll()
        }
        captionLog("[ReaderWriter] Sample transfer complete (\(round((CFAbsoluteTimeGetCurrent() - transferStart) * 100) / 100)s). Reader status=\(reader.status.rawValue) Writer status=\(writer.status.rawValue)")

        // Finalize
        if reader.status == .failed {
            let err = reader.error as? NSError
            let underlying = err?.userInfo[NSUnderlyingErrorKey] as? NSError
            captionLog("[ReaderWriter] READER FAILED: domain=\(err?.domain ?? "?") code=\(err?.code ?? 0) desc=\(err?.localizedDescription ?? "unknown")")
            if let underlying {
                captionLog("[ReaderWriter]   underlying: domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
            }
            throw ExportError.exportFailed(
                "Reader/Writer export reader failed: domain=\(err?.domain ?? "?") code=\(err?.code ?? 0) underlying=\(underlying?.code ?? 0) \(err?.localizedDescription ?? "unknown")"
            )
        }

        await writer.finishWriting()

        if writer.status == .failed {
            let err = writer.error as? NSError
            let underlying = err?.userInfo[NSUnderlyingErrorKey] as? NSError
            captionLog("[ReaderWriter] WRITER FAILED: domain=\(err?.domain ?? "?") code=\(err?.code ?? 0) desc=\(err?.localizedDescription ?? "unknown")")
            if let underlying {
                captionLog("[ReaderWriter]   underlying: domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
            }
            throw ExportError.exportFailed(
                "Reader/Writer export writer failed: domain=\(err?.domain ?? "?") code=\(err?.code ?? 0) underlying=\(underlying?.code ?? 0) \(err?.localizedDescription ?? "unknown")"
            )
        }

        captionLog("[ReaderWriter] Export complete: reader=\(reader.status.rawValue) writer=\(writer.status.rawValue)")
    }

    /// Transfer sample buffers from a reader output to a writer input.
    private func transferSamples(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput
    ) async {
        await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "com.reelabs.export.\(output.mediaType.rawValue)")) {
                while input.isReadyForMoreMediaData {
                    if let sampleBuffer = output.copyNextSampleBuffer() {
                        input.append(sampleBuffer)
                    } else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    /// Default bitrate based on resolution and codec.
    ///
    /// Updated 2026-04-20: bumped to match the "close-to-Resolve social cut"
    /// quality target for Sony FX6 / 4K-HEVC sources. Rationale — the previous
    /// 8 Mbps HEVC 4K default was visibly compressed on quick-motion talking-
    /// head cuts (Jay's gesture hands pixelated in run #3/#4 reviews).
    ///
    /// Long side thresholds (orientation-agnostic):
    /// - 4K tier kicks in when either dimension ≥ 3840 OR the short side ≥ 2160
    ///   (catches 2160×3840 vertical native just like 3840×2160 landscape).
    ///
    /// | Codec | 4K      | 1080p   |
    /// |-------|---------|---------|
    /// | HEVC  | 50 Mbps | 18 Mbps |
    /// | H.264 | 45 Mbps | 10 Mbps |
    private static func defaultBitrate(for size: CGSize, codec: QualityConfig.Codec) -> Int {
        let longSide = Int(max(size.width, size.height))
        let shortSide = Int(min(size.width, size.height))
        let is4K = longSide >= 3840 || shortSide >= 2160
        let is1080p = longSide >= 1920 || shortSide >= 1080
        switch (codec, is4K, is1080p) {
        case (.hevc, true,  _    ): return 50_000_000
        case (.hevc, false, true ): return 18_000_000
        case (.hevc, false, false): return 6_000_000   // 720p and below
        case (.h264, true,  _    ): return 45_000_000
        case (.h264, false, true ): return 10_000_000
        case (.h264, false, false): return 4_000_000   // 720p and below
        }
    }

    // MARK: - Export Preset

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
