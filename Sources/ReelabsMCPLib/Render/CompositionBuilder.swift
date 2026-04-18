import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
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
        // Segments stay on one track by default; crossfades swap tracks to overlap.
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

        // Preload source assets (deduplicated), resolving Unicode path mismatches
        var sourceAssets: [String: AVURLAsset] = [:]
        for source in spec.sources {
            sourceAssets[source.id] = AVURLAsset(url: URL(fileURLWithPath: resolvePath(source.path)))
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

        // --- Pass 1: Insert media onto tracks ---

        struct KeyframeLayout {
            let relativeTime: Double    // seconds relative to segment start
            let transform: CGAffineTransform
        }

        struct SegmentLayout {
            let trackIndex: Int
            let trackID: CMPersistentTrackID
            let compositionStart: CMTime
            let duration: CMTime
            let transitionDur: CMTime   // incoming crossfade duration
            let transform: CGAffineTransform
            let preferredTransform: CGAffineTransform
            let naturalSize: CGSize
            let keyframeTransforms: [KeyframeLayout]?
            let volume: Float
        }

        var layouts: [SegmentLayout] = []
        var insertionTime = CMTime.zero
        var previousTrackIdx = 0

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
            if index > 0, let transition = segment.transition, transition.type == .crossfade, let transitionDuration = transition.duration {
                let clamped = min(transitionDuration, CMTimeGetSeconds(outputDuration))
                transitionDur = CMTime(seconds: clamped, preferredTimescale: 600)
                insertionTime = CMTimeSubtract(insertionTime, transitionDur)
            } else {
                transitionDur = .zero
            }

            // Hard cuts stay on the same track; crossfades swap so two tracks can overlap.
            let trackIdx: Int
            if index == 0 {
                trackIdx = 0
            } else if CMTimeGetSeconds(transitionDur) > 0 {
                trackIdx = 1 - previousTrackIdx
            } else {
                trackIdx = previousTrackIdx
            }
            previousTrackIdx = trackIdx

            let vTrack = videoTracks[trackIdx]
            let aTrack = audioTracks[trackIdx]

            // Insert video
            var transform = CGAffineTransform.identity
            var segPreferredTransform = CGAffineTransform.identity
            var segNaturalSize = CGSize(width: 1920, height: 1080)
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
                segNaturalSize = naturalSize
                segPreferredTransform = preferredTransform
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
                trackID: vTrack.trackID,
                compositionStart: insertionTime,
                duration: outputDuration,
                transitionDur: transitionDur,
                transform: transform,
                preferredTransform: segPreferredTransform,
                naturalSize: segNaturalSize,
                keyframeTransforms: keyframeTransforms,
                volume: Float(segment.volume ?? 1.0)
            ))

            insertionTime = CMTimeAdd(insertionTime, outputDuration)
        }

        // --- Pass 2: Build audio mix ---

        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        var audioParamsA: AVMutableAudioMixInputParameters?
        var audioParamsB: AVMutableAudioMixInputParameters?
        if let audioTrackA {
            audioParamsA = AVMutableAudioMixInputParameters(track: audioTrackA)
            audioParamsA?.setVolume(1.0, at: .zero)
        }
        if let audioTrackB {
            audioParamsB = AVMutableAudioMixInputParameters(track: audioTrackB)
            audioParamsB?.setVolume(1.0, at: .zero)
        }

        for (index, layout) in layouts.enumerated() {
            let segStart = layout.compositionStart
            let hasIncoming = CMTimeGetSeconds(layout.transitionDur) > 0 && index > 0

            // Audio crossfade
            if hasIncoming {
                let prev = layouts[index - 1]
                let tRange = CMTimeRange(start: segStart, duration: layout.transitionDur)
                let prevAP = prev.trackIndex == 0 ? audioParamsA : audioParamsB
                let currAP = layout.trackIndex == 0 ? audioParamsA : audioParamsB
                prevAP?.setVolumeRamp(fromStartVolume: prev.volume, toEndVolume: 0, timeRange: tRange)
                currAP?.setVolumeRamp(fromStartVolume: 0, toEndVolume: layout.volume, timeRange: tRange)
            }

            // Custom volume outside of crossfade regions
            let passStart = hasIncoming ? CMTimeAdd(segStart, layout.transitionDur) : segStart
            if layout.volume != 1.0 {
                let ap = layout.trackIndex == 0 ? audioParamsA : audioParamsB
                ap?.setVolume(layout.volume, at: passStart)
            }
        }

        // --- Background music track ---
        if let audio = spec.audio, let musicPath = audio.musicPath {
            let musicAsset = AVURLAsset(url: URL(fileURLWithPath: resolvePath(musicPath)))
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

        // --- Pass 3: Insert overlay tracks onto composition ---

        var overlayLayouts: [OverlayLayout] = []

        if let overlays = spec.overlays, !overlays.isEmpty {
            let sorted = overlays.sorted { ($0.zIndex ?? 0) < ($1.zIndex ?? 0) }

            for overlay in sorted {
                let overlayStart = CMTime(seconds: overlay.start, preferredTimescale: 600)
                let overlayEnd = CMTime(seconds: overlay.end, preferredTimescale: 600)
                let overlayDuration = CMTimeSubtract(overlayEnd, overlayStart)

                // Target rectangle in pixels (top-left origin)
                let targetRect = CGRect(
                    x: overlay.x * renderSize.width,
                    y: overlay.y * renderSize.height,
                    width: overlay.width * renderSize.width,
                    height: overlay.height * renderSize.height
                )

                let fadeIn = overlay.fadeIn ?? 0
                let fadeOut = overlay.fadeOut ?? 0

                switch overlay.kind {
                case .video:
                    guard let sourceId = overlay.sourceId else {
                        throw CompositionError.overlaySourceNotFound("<nil>")
                    }
                    guard let asset = sourceAssets[sourceId] else {
                        throw CompositionError.overlaySourceNotFound(sourceId)
                    }

                    let srcVideoTracks = try await asset.loadTracks(withMediaType: .video)
                    let srcAudioTracks = try await asset.loadTracks(withMediaType: .audio)

                    let sourceOffset = CMTime(seconds: overlay.sourceStart ?? 0, preferredTimescale: 600)

                    // Auto-clamp: if overlay duration exceeds available source media, clamp it
                    var effectiveOverlayDuration = overlayDuration
                    var effectiveOverlayEnd = overlayEnd
                    if let srcVT = srcVideoTracks.first {
                        let srcDuration = try await srcVT.load(.timeRange).duration
                        let availableDuration = CMTimeSubtract(srcDuration, sourceOffset)
                        if CMTimeCompare(effectiveOverlayDuration, availableDuration) > 0 {
                            captionLog("[Builder] Auto-clamping video overlay '\(sourceId)': requested \(round(CMTimeGetSeconds(effectiveOverlayDuration)*1000)/1000)s but only \(round(CMTimeGetSeconds(availableDuration)*1000)/1000)s available from sourceStart")
                            effectiveOverlayDuration = availableDuration
                            effectiveOverlayEnd = CMTimeAdd(overlayStart, effectiveOverlayDuration)
                        }
                    }

                    let sourceRange = CMTimeRange(start: sourceOffset, duration: effectiveOverlayDuration)

                    if let srcVT = srcVideoTracks.first {
                        guard let ovTrack = composition.addMutableTrack(
                            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                        ) else {
                            throw CompositionError.failedToCreateTrack
                        }
                        try ovTrack.insertTimeRange(sourceRange, of: srcVT, at: overlayStart)

                        let naturalSize = try await srcVT.load(.naturalSize)
                        let preferredTransform = try await srcVT.load(.preferredTransform)

                        let cropRect: CGRect? = overlay.crop.map {
                            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                        }

                        overlayLayouts.append(OverlayLayout(
                            trackID: ovTrack.trackID,
                            overlayStart: overlayStart,
                            overlayEnd: effectiveOverlayEnd,
                            preferredTransform: preferredTransform,
                            naturalSize: naturalSize,
                            targetRect: targetRect,
                            cornerRadiusFraction: overlay.cornerRadius,
                            cropRect: cropRect,
                            opacity: Float(overlay.opacity ?? 1.0),
                            generatedImage: nil,
                            fadeIn: fadeIn,
                            fadeOut: fadeOut
                        ))

                        captionLog("[Builder] Overlay track: id=\(ovTrack.trackID) sourceId=\(sourceId) natSize=\(Int(naturalSize.width))x\(Int(naturalSize.height)) target=\(Int(targetRect.width))x\(Int(targetRect.height))@(\(Int(targetRect.origin.x)),\(Int(targetRect.origin.y))) time=\(round(CMTimeGetSeconds(overlayStart)*1000)/1000)..\(round(CMTimeGetSeconds(effectiveOverlayEnd)*1000)/1000) segments=\(ovTrack.segments?.count ?? 0)")
                    }

                    // Insert overlay audio if volume > 0
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

                case .color:
                    // Pre-render solid color rectangle as CIImage
                    let bgColor = parseHexColor(overlay.backgroundColor ?? "#000000")
                    let ciColor = CIColor(cgColor: bgColor)
                    let colorImage = CIImage(color: ciColor).cropped(to: CGRect(
                        x: 0, y: 0, width: targetRect.width, height: targetRect.height
                    ))

                    overlayLayouts.append(OverlayLayout(
                        trackID: kCMPersistentTrackID_Invalid,
                        overlayStart: overlayStart,
                        overlayEnd: overlayEnd,
                        preferredTransform: .identity,
                        naturalSize: targetRect.size,
                        targetRect: targetRect,
                        cornerRadiusFraction: overlay.cornerRadius,
                        cropRect: nil,
                        opacity: Float(overlay.opacity ?? 1.0),
                        generatedImage: colorImage,
                        fadeIn: fadeIn,
                        fadeOut: fadeOut
                    ))

                    captionLog("[Builder] Color overlay: bg=\(overlay.backgroundColor ?? "#000000") target=\(Int(targetRect.width))x\(Int(targetRect.height))@(\(Int(targetRect.origin.x)),\(Int(targetRect.origin.y))) time=\(round(CMTimeGetSeconds(overlayStart)*1000)/1000)..\(round(CMTimeGetSeconds(overlayEnd)*1000)/1000)")

                case .text:
                    // Pre-render text card as CIImage
                    let textConfig = overlay.text!
                    let textImage = TextOverlayRenderer.render(
                        config: textConfig,
                        backgroundColor: overlay.backgroundColor,
                        size: targetRect.size,
                        cornerRadius: overlay.cornerRadius
                    )

                    overlayLayouts.append(OverlayLayout(
                        trackID: kCMPersistentTrackID_Invalid,
                        overlayStart: overlayStart,
                        overlayEnd: overlayEnd,
                        preferredTransform: .identity,
                        naturalSize: targetRect.size,
                        targetRect: targetRect,
                        cornerRadiusFraction: nil, // corner radius applied during rendering
                        cropRect: nil,
                        opacity: Float(overlay.opacity ?? 1.0),
                        generatedImage: textImage,
                        fadeIn: fadeIn,
                        fadeOut: fadeOut
                    ))

                    captionLog("[Builder] Text overlay: title=\(textConfig.title ?? "<none>") target=\(Int(targetRect.width))x\(Int(targetRect.height))@(\(Int(targetRect.origin.x)),\(Int(targetRect.origin.y))) time=\(round(CMTimeGetSeconds(overlayStart)*1000)/1000)..\(round(CMTimeGetSeconds(overlayEnd)*1000)/1000)")

                case .image:
                    guard let rawImgPath = overlay.imagePath, !rawImgPath.isEmpty else {
                        throw CompositionError.imageOverlayPathMissing
                    }
                    let path = resolvePath(rawImgPath)
                    guard let nsImage = NSImage(contentsOfFile: path) else {
                        throw CompositionError.imageOverlayLoadFailed(path)
                    }
                    guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw CompositionError.imageOverlayLoadFailed(path)
                    }
                    var ciImage = CIImage(cgImage: cgImage)

                    // Scale to cover-fill the target rect, then crop to exact size
                    let imgW = CGFloat(cgImage.width)
                    let imgH = CGFloat(cgImage.height)
                    let scaleX = targetRect.width / imgW
                    let scaleY = targetRect.height / imgH
                    let coverScale = max(scaleX, scaleY)
                    ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: coverScale, y: coverScale))
                    // Center-crop to target dimensions
                    let scaledW = imgW * coverScale
                    let scaledH = imgH * coverScale
                    let cropX = (scaledW - targetRect.width) / 2
                    let cropY = (scaledH - targetRect.height) / 2
                    ciImage = ciImage.cropped(to: CGRect(x: cropX, y: cropY, width: targetRect.width, height: targetRect.height))
                    // Reset origin to (0,0)
                    ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

                    overlayLayouts.append(OverlayLayout(
                        trackID: kCMPersistentTrackID_Invalid,
                        overlayStart: overlayStart,
                        overlayEnd: overlayEnd,
                        preferredTransform: .identity,
                        naturalSize: targetRect.size,
                        targetRect: targetRect,
                        cornerRadiusFraction: overlay.cornerRadius,
                        cropRect: nil,
                        opacity: Float(overlay.opacity ?? 1.0),
                        generatedImage: ciImage,
                        fadeIn: fadeIn,
                        fadeOut: fadeOut
                    ))

                    captionLog("[Builder] Image overlay: path=\(path) source=\(Int(imgW))x\(Int(imgH)) target=\(Int(targetRect.width))x\(Int(targetRect.height))@(\(Int(targetRect.origin.x)),\(Int(targetRect.origin.y))) time=\(round(CMTimeGetSeconds(overlayStart)*1000)/1000)..\(round(CMTimeGetSeconds(overlayEnd)*1000)/1000)")
                }
            }
        }

        // Remove empty tracks to prevent AVFoundation export error -12123.
        for track in composition.tracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }

        // --- Always explicitly parameterize main audio tracks ---
        // AVFoundation drops audio unpredictably when an audioMix exists
        // (from overlay audio, music, crossfade) but some tracks lack
        // explicit parameters. By always adding params for main tracks,
        // every audio track in the composition is accounted for.
        let remainingTrackIDs = Set(composition.tracks.map { $0.trackID })


        if let audioParamsA, let audioTrackA, remainingTrackIDs.contains(audioTrackA.trackID) {
            audioMixParams.append(audioParamsA)
        }
        if let audioParamsB, let audioTrackB, remainingTrackIDs.contains(audioTrackB.trackID) {
            audioMixParams.append(audioParamsB)
        }

        // --- Pass 4: Build unified CompositorInstructions ---

        var instructions: [CompositorInstruction] = []

        for (index, layout) in layouts.enumerated() {
            let segStart = layout.compositionStart
            let segEnd = CMTimeAdd(segStart, layout.duration)
            let hasIncoming = CMTimeGetSeconds(layout.transitionDur) > 0 && index > 0

            let outgoingDur: CMTime
            if index + 1 < layouts.count {
                outgoingDur = layouts[index + 1].transitionDur
            } else {
                outgoingDur = .zero
            }

            // --- Crossfade instruction (overlap region) ---
            if hasIncoming {
                let prev = layouts[index - 1]
                let tRange = CMTimeRange(start: segStart, duration: layout.transitionDur)
                let subRanges = splitRangeAtOverlayBoundaries(tRange, overlayLayouts: overlayLayouts)
                let fullDur = CMTimeGetSeconds(tRange.duration)

                for subRange in subRanges {
                    let relStart = fullDur > 0 ? Float((CMTimeGetSeconds(subRange.start) - CMTimeGetSeconds(tRange.start)) / fullDur) : 0
                    let relEnd = fullDur > 0 ? relStart + Float(CMTimeGetSeconds(subRange.duration) / fullDur) : 1

                    var layers: [LayerInfo] = [
                        // Outgoing layer (fade out)
                        LayerInfo(
                            trackID: prev.trackID,
                            preferredTransform: prev.preferredTransform,
                            naturalSize: prev.naturalSize,
                            transform: prev.transform,
                            transformEnd: nil,
                            opacity: 1.0 - relStart, opacityEnd: 1.0 - relEnd,
                            targetRect: nil, cornerRadiusFraction: nil, cropRect: nil,
                            generatedImage: nil
                        ),
                        // Incoming layer (fade in)
                        LayerInfo(
                            trackID: layout.trackID,
                            preferredTransform: layout.preferredTransform,
                            naturalSize: layout.naturalSize,
                            transform: layout.transform,
                            transformEnd: nil,
                            opacity: relStart, opacityEnd: relEnd,
                            targetRect: nil, cornerRadiusFraction: nil, cropRect: nil,
                            generatedImage: nil
                        ),
                    ]

                    appendOverlayLayers(to: &layers, overlayLayouts: overlayLayouts, timeRange: subRange)

                    instructions.append(CompositorInstruction(
                        timeRange: subRange, layers: layers, renderSize: renderSize
                    ))
                }
            }

            // --- Pass-through instruction (non-overlap region) ---
            let passStart = hasIncoming ? CMTimeAdd(segStart, layout.transitionDur) : segStart
            let passEnd = CMTimeSubtract(segEnd, outgoingDur)
            let passDuration = CMTimeSubtract(passEnd, passStart)

            if CMTimeGetSeconds(passDuration) > 0 {
                // For keyframed segments, split into per-interval instructions
                if let kfs = layout.keyframeTransforms, kfs.count >= 2 {
                    for i in 0..<(kfs.count - 1) {
                        let kfStart = CMTimeAdd(
                            layout.compositionStart,
                            CMTime(seconds: kfs[i].relativeTime, preferredTimescale: 600)
                        )
                        let kfEnd = CMTimeAdd(
                            layout.compositionStart,
                            CMTime(seconds: kfs[i + 1].relativeTime, preferredTimescale: 600)
                        )
                        // Clamp to pass-through bounds. Pin the first/last
                        // keyframe of each segment exactly to passStart/passEnd
                        // — Double-rounded keyframe times can otherwise sit one
                        // CMTime tick inside the segment boundary, leaving a
                        // sub-millisecond gap between consecutive segments'
                        // instructions that AVFoundation rejects (-11841).
                        let clampedStart = (i == 0)
                            ? passStart
                            : CMTimeMaximum(kfStart, passStart)
                        let clampedEnd = (i + 1 == kfs.count - 1)
                            ? passEnd
                            : CMTimeMinimum(kfEnd, passEnd)
                        let clampedDur = CMTimeSubtract(clampedEnd, clampedStart)
                        guard CMTimeGetSeconds(clampedDur) > 0 else { continue }

                        let kfRange = CMTimeRange(start: clampedStart, duration: clampedDur)
                        let kfSubRanges = splitRangeAtOverlayBoundaries(kfRange, overlayLayouts: overlayLayouts)
                        let kfFullDur = CMTimeGetSeconds(clampedDur)

                        for kfSubRange in kfSubRanges {
                            let relStart = kfFullDur > 0 ? CGFloat((CMTimeGetSeconds(kfSubRange.start) - CMTimeGetSeconds(clampedStart)) / kfFullDur) : 0
                            let relEnd = kfFullDur > 0 ? relStart + CGFloat(CMTimeGetSeconds(kfSubRange.duration) / kfFullDur) : 1

                            let txStart = lerpTransform(kfs[i].transform, kfs[i + 1].transform, relStart)
                            let txEnd = lerpTransform(kfs[i].transform, kfs[i + 1].transform, relEnd)

                            var layers: [LayerInfo] = [
                                LayerInfo(
                                    trackID: layout.trackID,
                                    preferredTransform: layout.preferredTransform,
                                    naturalSize: layout.naturalSize,
                                    transform: txStart,
                                    transformEnd: txEnd,
                                    opacity: 1.0, opacityEnd: nil,
                                    targetRect: nil, cornerRadiusFraction: nil, cropRect: nil,
                                    generatedImage: nil
                                ),
                            ]
                            appendOverlayLayers(to: &layers, overlayLayouts: overlayLayouts, timeRange: kfSubRange)
                            instructions.append(CompositorInstruction(
                                timeRange: kfSubRange, layers: layers, renderSize: renderSize
                            ))
                        }
                    }
                } else {
                    let passRange = CMTimeRange(start: passStart, duration: passDuration)
                    let subRanges = splitRangeAtOverlayBoundaries(passRange, overlayLayouts: overlayLayouts)
                    for subRange in subRanges {
                        var layers: [LayerInfo] = [
                            LayerInfo(
                                trackID: layout.trackID,
                                preferredTransform: layout.preferredTransform,
                                naturalSize: layout.naturalSize,
                                transform: layout.transform,
                                transformEnd: nil,
                                opacity: 1.0, opacityEnd: nil,
                                targetRect: nil, cornerRadiusFraction: nil, cropRect: nil,
                                generatedImage: nil
                            ),
                        ]
                        appendOverlayLayers(to: &layers, overlayLayouts: overlayLayouts, timeRange: subRange)
                        instructions.append(CompositorInstruction(
                            timeRange: subRange, layers: layers, renderSize: renderSize
                        ))
                    }
                }
            }
        }

        // Build video composition with custom compositor
        var videoComposition: AVVideoComposition? = nil
        if !instructions.isEmpty {
            let mutableVC = AVMutableVideoComposition()
            let frameDur = Self.preciseFrameDuration(fps: fps)
            mutableVC.frameDuration = frameDur
            mutableVC.renderSize = renderSize
            mutableVC.instructions = instructions
            mutableVC.customVideoCompositorClass = VideoCompositor.self
            videoComposition = mutableVC

            captionLog("[Builder] VideoComposition: fps=\(fps) frameDuration=\(frameDur.value)/\(frameDur.timescale) renderSize=\(Int(renderSize.width))x\(Int(renderSize.height)) instructions=\(instructions.count) overlays=\(overlayLayouts.count)")
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

    /// Append overlay LayerInfos to a layers array for any overlays that overlap the given time range.
    /// Calculates fade-in/fade-out opacity ramps based on overlay timing.
    private func appendOverlayLayers(
        to layers: inout [LayerInfo],
        overlayLayouts: [OverlayLayout],
        timeRange: CMTimeRange
    ) {
        let spanStart = CMTimeGetSeconds(timeRange.start)
        let spanEnd = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))

        for ov in overlayLayouts {
            let ovStart = CMTimeGetSeconds(ov.overlayStart)
            let ovEnd = CMTimeGetSeconds(ov.overlayEnd)
            guard max(spanStart, ovStart) < min(spanEnd, ovEnd) else { continue }

            let baseOpacity = ov.opacity
            let fadeInEnd = ovStart + ov.fadeIn
            let fadeOutStart = ovEnd - ov.fadeOut

            // Calculate opacity at the start and end of this sub-range
            let opacityAtTime: (Double) -> Float = { t in
                if ov.fadeIn > 0 && t < fadeInEnd {
                    // In fade-in zone
                    let progress = Float((t - ovStart) / ov.fadeIn)
                    return baseOpacity * min(max(progress, 0), 1)
                } else if ov.fadeOut > 0 && t > fadeOutStart {
                    // In fade-out zone
                    let progress = Float((ovEnd - t) / ov.fadeOut)
                    return baseOpacity * min(max(progress, 0), 1)
                }
                return baseOpacity
            }

            let startOpacity = opacityAtTime(spanStart)
            let endOpacity = opacityAtTime(spanEnd)

            // Only use opacityEnd if opacity actually changes across the sub-range
            let needsRamp = abs(startOpacity - endOpacity) > 0.001

            layers.append(LayerInfo(
                trackID: ov.trackID,
                preferredTransform: ov.preferredTransform,
                naturalSize: ov.naturalSize,
                transform: .identity,
                transformEnd: nil,
                opacity: startOpacity,
                opacityEnd: needsRamp ? endOpacity : nil,
                targetRect: ov.targetRect,
                cornerRadiusFraction: ov.cornerRadiusFraction,
                cropRect: ov.cropRect,
                generatedImage: ov.generatedImage
            ))
        }
    }

    /// Split a time range at overlay start/end boundaries so each sub-range
    /// only includes overlays that have media in that span. Prevents AVFoundation
    /// from holding the last overlay frame beyond its end time.
    private func splitRangeAtOverlayBoundaries(
        _ range: CMTimeRange,
        overlayLayouts: [OverlayLayout]
    ) -> [CMTimeRange] {
        guard !overlayLayouts.isEmpty else { return [range] }

        let rangeStart = range.start
        let rangeEnd = CMTimeAdd(range.start, range.duration)

        // Collect split points as CMTime to avoid Double precision loss
        var splitPoints: [CMTime] = [rangeStart, rangeEnd]

        for ov in overlayLayouts {
            if CMTimeCompare(ov.overlayStart, rangeStart) > 0 &&
               CMTimeCompare(ov.overlayStart, rangeEnd) < 0 {
                splitPoints.append(ov.overlayStart)
            }
            if CMTimeCompare(ov.overlayEnd, rangeStart) > 0 &&
               CMTimeCompare(ov.overlayEnd, rangeEnd) < 0 {
                splitPoints.append(ov.overlayEnd)
            }
            // Add fade boundaries as split points for smooth opacity ramps
            if ov.fadeIn > 0 {
                let fadeInEnd = CMTimeAdd(ov.overlayStart, CMTime(seconds: ov.fadeIn, preferredTimescale: 600))
                if CMTimeCompare(fadeInEnd, rangeStart) > 0 &&
                   CMTimeCompare(fadeInEnd, rangeEnd) < 0 {
                    splitPoints.append(fadeInEnd)
                }
            }
            if ov.fadeOut > 0 {
                let fadeOutStart = CMTimeSubtract(ov.overlayEnd, CMTime(seconds: ov.fadeOut, preferredTimescale: 600))
                if CMTimeCompare(fadeOutStart, rangeStart) > 0 &&
                   CMTimeCompare(fadeOutStart, rangeEnd) < 0 {
                    splitPoints.append(fadeOutStart)
                }
            }
        }

        // Sort and deduplicate
        splitPoints.sort { CMTimeCompare($0, $1) < 0 }
        var unique: [CMTime] = [splitPoints[0]]
        for i in 1..<splitPoints.count {
            guard let last = unique.last else { continue }
            if CMTimeCompare(splitPoints[i], last) != 0 {
                unique.append(splitPoints[i])
            }
        }

        var subRanges: [CMTimeRange] = []
        for i in 0..<(unique.count - 1) {
            let dur = CMTimeSubtract(unique[i + 1], unique[i])
            if CMTimeGetSeconds(dur) > 0 {
                subRanges.append(CMTimeRange(start: unique[i], duration: dur))
            }
        }

        return subRanges
    }

    private func lerpTransform(
        _ a: CGAffineTransform, _ b: CGAffineTransform, _ t: CGFloat
    ) -> CGAffineTransform {
        CGAffineTransform(
            a: a.a + (b.a - a.a) * t,
            b: a.b + (b.b - a.b) * t,
            c: a.c + (b.c - a.c) * t,
            d: a.d + (b.d - a.d) * t,
            tx: a.tx + (b.tx - a.tx) * t,
            ty: a.ty + (b.ty - a.ty) * t
        )
    }

    private struct OverlayLayout: @unchecked Sendable {
        let trackID: CMPersistentTrackID
        let overlayStart: CMTime
        let overlayEnd: CMTime
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
        let targetRect: CGRect
        let cornerRadiusFraction: Double?
        let cropRect: CGRect?
        let opacity: Float
        let generatedImage: CIImage?
        let fadeIn: Double   // seconds, 0 = no fade
        let fadeOut: Double   // seconds, 0 = no fade
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

    /// Compute a precise frame duration CMTime for the given fps.
    /// Handles NTSC rates (23.976, 29.97, 59.94) with exact 1001/N timescales
    /// instead of truncating to integer timescale.
    static func preciseFrameDuration(fps: Double) -> CMTime {
        // Common NTSC frame rates use 1001/N fractions
        let ntscRates: [(fps: Double, value: CMTimeValue, timescale: CMTimeScale)] = [
            (23.976, 1001, 24000),
            (29.97,  1001, 30000),
            (59.94,  1001, 60000),
        ]
        for rate in ntscRates {
            if abs(fps - rate.fps) < 0.05 {
                return CMTime(value: rate.value, timescale: rate.timescale)
            }
        }
        // For integer fps values, use simple 1/N
        let rounded = Int32(fps.rounded())
        if abs(fps - Double(rounded)) < 0.01 && rounded > 0 {
            return CMTime(value: 1, timescale: CMTimeScale(rounded))
        }
        // Fallback: use 600 timescale for arbitrary fps
        let frameDurationSeconds = 1.0 / fps
        return CMTime(seconds: frameDurationSeconds, preferredTimescale: 600)
    }

}

enum CompositionError: Error, LocalizedError {
    case failedToCreateTrack
    case sourceNotFound(String)
    case musicTrackNotFound(String)
    case overlaySourceNotFound(String)
    case imageOverlayPathMissing
    case imageOverlayLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreateTrack: "Failed to create composition track"
        case .sourceNotFound(let id): "Source not found: \(id)"
        case .musicTrackNotFound(let path): "No audio track found in music file: \(path)"
        case .overlaySourceNotFound(let id): "Overlay source not found: \(id)"
        case .imageOverlayPathMissing: "Image overlay requires imagePath"
        case .imageOverlayLoadFailed(let path): "Failed to load image overlay: \(path)"
        }
    }
}
