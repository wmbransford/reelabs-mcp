import AVFoundation
import CoreGraphics
import Foundation

struct BuildResult: @unchecked Sendable {
    let composition: AVMutableComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVMutableAudioMix?
    let renderSize: CGSize
    let totalDuration: Double
    let fps: Double
}

final class CompositionBuilder: Sendable {

    func build(spec: RenderSpec) async throws -> BuildResult {
        let composition = AVMutableComposition()

        // Two video + audio tracks enable crossfade transitions.
        // Segments alternate between tracks; overlap regions create the blend.
        guard let videoTrackA = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ), let videoTrackB = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompositionError.failedToCreateTrack
        }

        let audioTrackA = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let audioTrackB = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        let videoTracks = [videoTrackA, videoTrackB]
        let audioTracks = [audioTrackA, audioTrackB]

        // Preload source assets (deduplicated)
        var sourceAssets: [String: AVURLAsset] = [:]
        for source in spec.sources {
            sourceAssets[source.id] = AVURLAsset(url: URL(fileURLWithPath: source.path))
        }

        // Detect source resolution and fps from the first segment's source
        var baseSize: CGSize
        let sourceFps: Double
        if let firstSegment = spec.segments.first,
           let firstAsset = sourceAssets[firstSegment.sourceId],
           let firstTrack = try await firstAsset.loadTracks(withMediaType: .video).first {
            let naturalSize = try await firstTrack.load(.naturalSize)
            let preferredTransform = try await firstTrack.load(.preferredTransform)
            let transformed = naturalSize.applying(preferredTransform)
            let detectedWidth = abs(transformed.width)
            let detectedHeight = abs(transformed.height)
            sourceFps = try await Double(firstTrack.load(.nominalFrameRate))

            if let aspectRatio = spec.aspectRatio {
                // Crop source dimensions to the target ratio, preserving resolution.
                // A 4K source with 9:16 produces 2160x3840, not hardcoded 1080x1920.
                let targetRatio = aspectRatio.ratio
                let sourceRatio = detectedWidth / detectedHeight
                if sourceRatio > targetRatio {
                    // Source is wider — constrain width, keep height
                    let w = CGFloat(Int(detectedHeight * targetRatio / 2) * 2)
                    baseSize = CGSize(width: w, height: detectedHeight)
                } else {
                    // Source is taller — constrain height, keep width
                    let h = CGFloat(Int(detectedWidth / targetRatio / 2) * 2)
                    baseSize = CGSize(width: detectedWidth, height: h)
                }
            } else {
                // No aspect ratio specified — match source resolution
                baseSize = CGSize(width: detectedWidth, height: detectedHeight)
            }
        } else {
            // Fallback if no video tracks found
            let aspectRatio = spec.aspectRatio ?? .landscape
            baseSize = aspectRatio.fallbackSize
            sourceFps = 30.0
        }

        // Apply resolution override if specified (scales baseSize to target)
        let renderSize: CGSize
        if let resolution = spec.resolution {
            renderSize = resolution.pixelSize(for: baseSize)
        } else {
            renderSize = baseSize
        }

        // Use explicit fps > source fps > 30 fallback
        let fps = spec.fps ?? (sourceFps > 0 ? sourceFps : 30.0)

        // --- Pass 1: Insert media onto alternating tracks ---

        struct KeyframeLayout {
            let relativeTime: Double    // seconds relative to segment start
            let transform: CGAffineTransform
        }

        struct SegmentLayout {
            let trackIndex: Int
            let compositionStart: CMTime
            let duration: CMTime
            let transitionDur: CMTime   // incoming crossfade duration
            let transform: CGAffineTransform
            let keyframeTransforms: [KeyframeLayout]?
            let volume: Float
        }

        var layouts: [SegmentLayout] = []
        var insertionTime = CMTime.zero

        for (index, segment) in spec.segments.enumerated() {
            guard let asset = sourceAssets[segment.sourceId] else {
                throw CompositionError.sourceNotFound(segment.sourceId)
            }

            let srcVideoTracks = try await asset.loadTracks(withMediaType: .video)
            let srcAudioTracks = try await asset.loadTracks(withMediaType: .audio)

            let startTime = CMTime(seconds: segment.start, preferredTimescale: 600)
            let endTime = CMTime(seconds: segment.end, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, end: endTime)
            let segmentDuration = CMTimeSubtract(endTime, startTime)

            let speed = segment.speed ?? 1.0
            let outputDuration: CMTime
            if speed != 1.0 {
                outputDuration = CMTime(
                    seconds: CMTimeGetSeconds(segmentDuration) / speed,
                    preferredTimescale: 600
                )
            } else {
                outputDuration = segmentDuration
            }

            // Incoming crossfade: pull insertion time back to create overlap
            let transitionDur: CMTime
            if index > 0, let transition = segment.transition, transition.type == .crossfade {
                let clamped = min(transition.duration, CMTimeGetSeconds(outputDuration))
                transitionDur = CMTime(seconds: clamped, preferredTimescale: 600)
                insertionTime = CMTimeSubtract(insertionTime, transitionDur)
            } else {
                transitionDur = .zero
            }

            let trackIdx = index % 2
            let vTrack = videoTracks[trackIdx]
            let aTrack = audioTracks[trackIdx]

            // Insert video
            var transform = CGAffineTransform.identity
            var keyframeTransforms: [KeyframeLayout]? = nil
            if let srcVT = srcVideoTracks.first {
                try vTrack.insertTimeRange(timeRange, of: srcVT, at: insertionTime)
                if speed != 1.0 {
                    vTrack.scaleTimeRange(
                        CMTimeRange(start: insertionTime, duration: segmentDuration),
                        toDuration: outputDuration
                    )
                }
                let naturalSize = try await srcVT.load(.naturalSize)
                let preferredTransform = try await srcVT.load(.preferredTransform)
                transform = buildAffineTransform(
                    segment: segment, naturalSize: naturalSize,
                    preferredTransform: preferredTransform, outputSize: renderSize
                )

                // Build keyframe transforms for animated zoom/pan
                if let keyframes = segment.keyframes, keyframes.count >= 2 {
                    keyframeTransforms = keyframes.map { kf in
                        KeyframeLayout(
                            relativeTime: kf.time,
                            transform: buildAffineTransform(
                                scale: kf.scale ?? 1.0,
                                panX: kf.panX ?? 0.0,
                                panY: kf.panY ?? 0.0,
                                naturalSize: naturalSize,
                                preferredTransform: preferredTransform,
                                outputSize: renderSize
                            )
                        )
                    }
                }
            }

            // Insert audio
            if let srcAT = srcAudioTracks.first, let aTrack {
                try aTrack.insertTimeRange(timeRange, of: srcAT, at: insertionTime)
                if speed != 1.0 {
                    aTrack.scaleTimeRange(
                        CMTimeRange(start: insertionTime, duration: segmentDuration),
                        toDuration: outputDuration
                    )
                }
            }

            layouts.append(SegmentLayout(
                trackIndex: trackIdx,
                compositionStart: insertionTime,
                duration: outputDuration,
                transitionDur: transitionDur,
                transform: transform,
                keyframeTransforms: keyframeTransforms,
                volume: Float(segment.volume ?? 1.0)
            ))

            insertionTime = CMTimeAdd(insertionTime, outputDuration)
        }

        // --- Pass 2: Build video composition instructions and audio mix ---

        // Helper: build a layer instruction config with static or keyframed transforms
        func buildLayerConfig(
            track: AVMutableCompositionTrack,
            layout: SegmentLayout
        ) -> AVVideoCompositionLayerInstruction.Configuration {
            var config = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            if let kfs = layout.keyframeTransforms, kfs.count >= 2 {
                for i in 0..<(kfs.count - 1) {
                    let startTime = CMTimeAdd(
                        layout.compositionStart,
                        CMTime(seconds: kfs[i].relativeTime, preferredTimescale: 600)
                    )
                    let endTime = CMTimeAdd(
                        layout.compositionStart,
                        CMTime(seconds: kfs[i + 1].relativeTime, preferredTimescale: 600)
                    )
                    config.addTransformRamp(.init(
                        timeRange: CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime)),
                        start: kfs[i].transform,
                        end: kfs[i + 1].transform
                    ))
                }
            } else {
                config.setTransform(layout.transform, at: layout.compositionStart)
            }
            return config
        }

        var instructionConfigs: [AVVideoCompositionInstruction.Configuration] = []
        var audioMixParams: [AVMutableAudioMixInputParameters] = []

        // One audio mix params instance per track (Apple requires this)
        var audioParamsA: AVMutableAudioMixInputParameters?
        var audioParamsB: AVMutableAudioMixInputParameters?
        if let audioTrackA { audioParamsA = AVMutableAudioMixInputParameters(track: audioTrackA) }
        if let audioTrackB { audioParamsB = AVMutableAudioMixInputParameters(track: audioTrackB) }
        var needsAudioA = false
        var needsAudioB = false

        for (index, layout) in layouts.enumerated() {
            let segStart = layout.compositionStart
            let segEnd = CMTimeAdd(segStart, layout.duration)
            let hasIncoming = CMTimeGetSeconds(layout.transitionDur) > 0 && index > 0
            let vTrack = videoTracks[layout.trackIndex]

            // How much the NEXT segment's transition eats into this segment's end
            let outgoingDur: CMTime
            if index + 1 < layouts.count {
                outgoingDur = layouts[index + 1].transitionDur
            } else {
                outgoingDur = .zero
            }

            // --- Crossfade transition instruction (overlap region) ---
            if hasIncoming {
                let prev = layouts[index - 1]
                let prevTrack = videoTracks[prev.trackIndex]
                let tRange = CMTimeRange(start: segStart, duration: layout.transitionDur)

                // Outgoing track: fade out
                var outConfig = buildLayerConfig(track: prevTrack, layout: prev)
                outConfig.addOpacityRamp(.init(timeRange: tRange, start: 1.0, end: 0.0))

                // Incoming track: fade in
                var inConfig = buildLayerConfig(track: vTrack, layout: layout)
                inConfig.addOpacityRamp(.init(timeRange: tRange, start: 0.0, end: 1.0))

                instructionConfigs.append(.init(
                    layerInstructions: [
                        AVVideoCompositionLayerInstruction(configuration: outConfig),
                        AVVideoCompositionLayerInstruction(configuration: inConfig)
                    ],
                    timeRange: tRange
                ))

                // Audio crossfade
                let prevAP = prev.trackIndex == 0 ? audioParamsA : audioParamsB
                let currAP = layout.trackIndex == 0 ? audioParamsA : audioParamsB
                prevAP?.setVolumeRamp(fromStartVolume: prev.volume, toEndVolume: 0, timeRange: tRange)
                currAP?.setVolumeRamp(fromStartVolume: 0, toEndVolume: layout.volume, timeRange: tRange)
                if prev.trackIndex == 0 { needsAudioA = true } else { needsAudioB = true }
                if layout.trackIndex == 0 { needsAudioA = true } else { needsAudioB = true }
            }

            // --- Pass-through instruction (non-overlap region) ---
            let passStart = hasIncoming ? CMTimeAdd(segStart, layout.transitionDur) : segStart
            let passEnd = CMTimeSubtract(segEnd, outgoingDur)
            let passDuration = CMTimeSubtract(passEnd, passStart)

            if CMTimeGetSeconds(passDuration) > 0 {
                let layerInstruction: AVVideoCompositionLayerInstruction
                if layout.keyframeTransforms != nil && (layout.keyframeTransforms?.count ?? 0) >= 2 {
                    let config = buildLayerConfig(track: vTrack, layout: layout)
                    layerInstruction = AVVideoCompositionLayerInstruction(configuration: config)
                } else {
                    var config = AVVideoCompositionLayerInstruction.Configuration(assetTrack: vTrack)
                    config.setTransform(layout.transform, at: passStart)
                    layerInstruction = AVVideoCompositionLayerInstruction(configuration: config)
                }
                instructionConfigs.append(.init(
                    layerInstructions: [layerInstruction],
                    timeRange: CMTimeRange(start: passStart, duration: passDuration)
                ))
            }

            // Custom volume outside of crossfade regions
            if layout.volume != 1.0 {
                let ap = layout.trackIndex == 0 ? audioParamsA : audioParamsB
                ap?.setVolume(layout.volume, at: passStart)
                if layout.trackIndex == 0 { needsAudioA = true } else { needsAudioB = true }
            }
        }

        if needsAudioA, let audioParamsA { audioMixParams.append(audioParamsA) }
        if needsAudioB, let audioParamsB { audioMixParams.append(audioParamsB) }

        // --- Background music track ---
        if let audio = spec.audio, let musicPath = audio.musicPath {
            let musicAsset = AVURLAsset(url: URL(fileURLWithPath: musicPath))
            let musicAudioTracks = try await musicAsset.loadTracks(withMediaType: .audio)
            guard let srcMusicTrack = musicAudioTracks.first else {
                throw CompositionError.musicTrackNotFound(musicPath)
            }
            guard let musicCompTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw CompositionError.failedToCreateTrack
            }
            let compositionDuration = insertionTime
            let musicDuration = try await musicAsset.load(.duration)
            let insertDuration = min(musicDuration, compositionDuration)
            let insertRange = CMTimeRange(start: .zero, duration: insertDuration)
            try musicCompTrack.insertTimeRange(insertRange, of: srcMusicTrack, at: .zero)

            let musicParams = AVMutableAudioMixInputParameters(track: musicCompTrack)
            musicParams.setVolume(Float(audio.musicVolume ?? 0.3), at: .zero)
            audioMixParams.append(musicParams)
        }

        // --- Pass 3: Overlay tracks ---

        if let overlays = spec.overlays, !overlays.isEmpty {
            // Sort by ascending zIndex so higher zIndex overlays are processed last
            // and prepended (= rendered on top)
            let sorted = overlays.sorted { ($0.zIndex ?? 0) < ($1.zIndex ?? 0) }

            for overlay in sorted {
                guard let asset = sourceAssets[overlay.sourceId] else {
                    throw CompositionError.overlaySourceNotFound(overlay.sourceId)
                }

                let srcVideoTracks = try await asset.loadTracks(withMediaType: .video)
                let srcAudioTracks = try await asset.loadTracks(withMediaType: .audio)

                let overlayStart = CMTime(seconds: overlay.start, preferredTimescale: 600)
                let overlayEnd = CMTime(seconds: overlay.end, preferredTimescale: 600)
                let overlayDuration = CMTimeSubtract(overlayEnd, overlayStart)
                let sourceOffset = CMTime(seconds: overlay.sourceStart ?? 0, preferredTimescale: 600)
                let sourceRange = CMTimeRange(start: sourceOffset, duration: overlayDuration)

                // 3a. Insert overlay video track
                if let srcVT = srcVideoTracks.first {
                    guard let ovTrack = composition.addMutableTrack(
                        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw CompositionError.failedToCreateTrack
                    }
                    try ovTrack.insertTimeRange(sourceRange, of: srcVT, at: overlayStart)

                    let naturalSize = try await srcVT.load(.naturalSize)
                    let preferredTransform = try await srcVT.load(.preferredTransform)
                    let ovTransform = buildOverlayTransform(
                        overlay: overlay,
                        naturalSize: naturalSize,
                        preferredTransform: preferredTransform,
                        renderSize: renderSize
                    )
                    let ovOpacity = Float(overlay.opacity ?? 1.0)

                    // 3c. Integrate overlay into existing instruction configs
                    // For each instruction whose timeRange overlaps the overlay active period,
                    // prepend a layer instruction for the overlay track.
                    if instructionConfigs.isEmpty {
                        // Edge case: no instructions yet (single segment, no transforms).
                        // Create a full-duration pass-through for each main video track.
                        let totalTime = insertionTime
                        let fullRange = CMTimeRange(start: .zero, duration: totalTime)

                        let layerInstructions = videoTracks.map { vt in
                            AVVideoCompositionLayerInstruction(
                                configuration: .init(assetTrack: vt)
                            )
                        }
                        instructionConfigs.append(.init(
                            layerInstructions: layerInstructions,
                            timeRange: fullRange
                        ))
                    }

                    for (i, instrConfig) in instructionConfigs.enumerated() {
                        let instrRange = instrConfig.timeRange
                        // Check overlap
                        let overlapStart = max(CMTimeGetSeconds(instrRange.start), CMTimeGetSeconds(overlayStart))
                        let overlapEnd = min(
                            CMTimeGetSeconds(CMTimeAdd(instrRange.start, instrRange.duration)),
                            CMTimeGetSeconds(overlayEnd)
                        )
                        guard overlapEnd > overlapStart else { continue }

                        var ovLayerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: ovTrack)
                        ovLayerConfig.setTransform(ovTransform, at: instrRange.start)
                        ovLayerConfig.setOpacity(ovOpacity, at: overlayStart)
                        // Explicit cleanup: hide overlay after its end time
                        ovLayerConfig.setOpacity(0.0, at: overlayEnd)

                        var updatedConfig = instrConfig
                        updatedConfig.layerInstructions.insert(
                            AVVideoCompositionLayerInstruction(configuration: ovLayerConfig),
                            at: 0
                        )
                        instructionConfigs[i] = updatedConfig
                    }
                }

                // 3a continued: Insert overlay audio track if volume > 0
                let overlayAudioVolume = Float(overlay.audio ?? 0)
                if overlayAudioVolume > 0, let srcAT = srcAudioTracks.first {
                    guard let ovAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw CompositionError.failedToCreateTrack
                    }
                    try ovAudioTrack.insertTimeRange(sourceRange, of: srcAT, at: overlayStart)

                    let ovAudioParams = AVMutableAudioMixInputParameters(track: ovAudioTrack)
                    ovAudioParams.setVolume(overlayAudioVolume, at: overlayStart)
                    audioMixParams.append(ovAudioParams)
                }
            }
        }

        // Remove empty tracks to prevent AVFoundation export error -12123.
        // Pre-allocated B-tracks remain empty when fewer than 2 segments use them.
        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }

        // Build video composition via Configuration API
        var videoComposition: AVVideoComposition? = nil
        if !instructionConfigs.isEmpty {
            let instructions = instructionConfigs.map {
                AVVideoCompositionInstruction(configuration: $0)
            }
            let config = AVVideoComposition.Configuration(
                frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                instructions: instructions,
                renderSize: renderSize
            )
            videoComposition = AVVideoComposition(configuration: config)
        }

        // Build audio mix
        var audioMix: AVMutableAudioMix? = nil
        if !audioMixParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioMixParams
            audioMix = mix
        }

        let totalDuration = CMTimeGetSeconds(insertionTime)

        return BuildResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            renderSize: renderSize,
            totalDuration: totalDuration,
            fps: fps
        )
    }

    private func buildAffineTransform(
        scale: Double,
        panX: Double,
        panY: Double,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        outputSize: CGSize
    ) -> CGAffineTransform {
        let transformedSize = naturalSize.applying(preferredTransform)
        let actualWidth = abs(transformedSize.width)
        let actualHeight = abs(transformedSize.height)

        // Cover-fill scale
        let coverScale = max(outputSize.width / actualWidth, outputSize.height / actualHeight)
        let finalScale = coverScale * scale

        let scaledWidth = actualWidth * finalScale
        let scaledHeight = actualHeight * finalScale
        let centerX = (outputSize.width - scaledWidth) / 2
        let centerY = (outputSize.height - scaledHeight) / 2

        let noEdgePanX = max(0, (scaledWidth - outputSize.width) / 2)
        let noEdgePanY = max(0, (scaledHeight - outputSize.height) / 2)
        let panRangeX = noEdgePanX + outputSize.width / 2
        let panRangeY = noEdgePanY + outputSize.height / 2
        let panOffsetX = panX * panRangeX
        let panOffsetY = panY * panRangeY

        var transform = preferredTransform
        transform = transform.concatenating(CGAffineTransform(scaleX: finalScale, y: finalScale))
        transform = transform.concatenating(CGAffineTransform(
            translationX: centerX + panOffsetX,
            y: centerY + panOffsetY
        ))

        return transform
    }

    private func buildAffineTransform(
        segment: SegmentSpec,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        outputSize: CGSize
    ) -> CGAffineTransform {
        buildAffineTransform(
            scale: segment.transform?.resolvedScale ?? 1.0,
            panX: segment.transform?.resolvedPanX ?? 0.0,
            panY: segment.transform?.resolvedPanY ?? 0.0,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            outputSize: outputSize
        )
    }

    /// Build a transform that cover-fills the overlay source into a sub-rectangle of the render.
    /// Coordinates are 0.0-1.0 fractions of renderSize. Top-left origin.
    private func buildOverlayTransform(
        overlay: Overlay,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let transformedSize = naturalSize.applying(preferredTransform)
        let actualWidth = abs(transformedSize.width)
        let actualHeight = abs(transformedSize.height)

        // Target rectangle in pixels
        let targetX = overlay.x * renderSize.width
        let targetY = overlay.y * renderSize.height
        let targetW = overlay.width * renderSize.width
        let targetH = overlay.height * renderSize.height

        // Cover-fill scale to fit within target rect
        let coverScale = max(targetW / actualWidth, targetH / actualHeight)

        let scaledWidth = actualWidth * coverScale
        let scaledHeight = actualHeight * coverScale

        // Center within target rect
        let centerX = targetX + (targetW - scaledWidth) / 2
        let centerY = targetY + (targetH - scaledHeight) / 2

        var transform = preferredTransform
        transform = transform.concatenating(CGAffineTransform(scaleX: coverScale, y: coverScale))
        transform = transform.concatenating(CGAffineTransform(translationX: centerX, y: centerY))

        return transform
    }
}

enum CompositionError: Error, LocalizedError {
    case failedToCreateTrack
    case sourceNotFound(String)
    case musicTrackNotFound(String)
    case overlaySourceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreateTrack: "Failed to create composition track"
        case .sourceNotFound(let id): "Source not found: \(id)"
        case .musicTrackNotFound(let path): "No audio track found in music file: \(path)"
        case .overlaySourceNotFound(let id): "Overlay source not found: \(id)"
        }
    }
}
