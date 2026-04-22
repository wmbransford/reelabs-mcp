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
    /// Parsed LUT to apply to source pixel buffers during compositing.
    /// nil when the spec has no `lut` field.
    let lut: LUTData?
    /// Strength of the LUT blend (0..1). Ignored if `lut` is nil.
    let lutStrength: Double
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

        // Default export fps to 30 for social/recruiting delivery — overkill at 60.
        // sourceFps is still reported by probe and preserved on the source side
        // (timeRange/insertTimeRange uses source clock); only the export-target
        // frame rate falls to 30 unless explicitly overridden. Users who need
        // 60fps motion output pass "fps": 60.0 in the spec.
        let fps = spec.fps ?? 30.0
        _ = sourceFps  // kept for diagnostic parity

        // --- Pass 1: Insert media onto alternating tracks ---

        struct KeyframeLayout {
            let relativeTime: Double    // seconds relative to segment start
            let transform: CGAffineTransform
        }

        struct SegmentLayout {
            let trackIndex: Int
            let trackID: CMPersistentTrackID
            let compositionStart: CMTime
            let duration: CMTime
            let transitionDur: CMTime   // incoming crossfade duration (video only if bridged)
            let transform: CGAffineTransform
            let preferredTransform: CGAffineTransform
            let naturalSize: CGSize
            let keyframeTransforms: [KeyframeLayout]?
            let volume: Float
            /// True when this segment's audio came from the previous source
            /// via the cross-cut path, not from its own media.
            let audioFromPrev: Bool
            /// True when the incoming crossfade is visually masked by a
            /// cross-cut overlay that spans the whole transition window.
            /// When true, the audio ramp is skipped and audio is inserted
            /// at the natural back-to-back position (not pulled back) — the
            /// video still crossfades behind the broll (invisible, harmless).
            /// Prevents the -6 dB linear-crossfade notch on correlated voice.
            let bridgedByOverlay: Bool
        }

        var layouts: [SegmentLayout] = []
        var insertionTime = CMTime.zero

        // --- Cross-cut semantics (NLE mental model) ---
        //
        // A cross-cut segment (`volume == 0` AND different `sourceId` than its
        // predecessor, OR explicit `audioFromPrev: true`) is a b-roll VISUAL
        // that plays ON TOP of the continuous speaker track — NOT a segment
        // that advances the timeline.
        //
        // It's handled like `spec.overlays`: routed to `overlayLayouts` as a
        // full-screen video overlay. The cross-cut contributes NOTHING to the
        // audio timeline, and it does NOT advance `insertionTime`. Adjacent
        // speaker segments land back-to-back on the A/B tracks with no gap,
        // so the speaker's voice plays continuously end-to-end.
        //
        // Fade-in uses the cross-cut's own `transition` (if crossfade).
        // Fade-out uses the NEXT non-cross-cut segment's `transition` so the
        // broll dissolves out into the returning speaker video.
        //
        // Prior designs tried to stitch bridge audio through the b-roll
        // window, which produced either a mid-word content jump (when bridge
        // gap < broll comp duration) or a silence gap (when bridge gap <
        // broll comp duration, different case). Both were symptoms of
        // treating cross-cut as timeline-advancing. Overlay is the fit.
        func isCrossCutSegment(_ segIdx: Int) -> Bool {
            guard segIdx > 0 else { return false }
            let seg = spec.segments[segIdx]
            if let explicit = seg.audioFromPrev { return explicit }
            let prev = spec.segments[segIdx - 1]
            return (seg.volume ?? 1.0) == 0 && prev.sourceId != seg.sourceId
        }

        // Cross-cut segments become video overlays instead of timeline
        // segments. We collect them here, resolved into OverlayLayouts AFTER
        // the main segment loop (which advances insertionTime for non-cross-
        // cut segments) has computed the compositional placement where each
        // cross-cut should visually land.
        struct PendingCrossCutOverlay {
            let segIdx: Int                   // index in spec.segments
            let visualStart: CMTime           // compTime where broll visual should start
            let sourceStart: CMTime           // source offset inside the cross-cut's source
            let duration: CMTime              // natural segment duration (end - start)
            let fadeIn: Double                // from own transition
            let fadeOutFromNext: Double       // from NEXT non-crosscut segment's transition
        }
        var pendingCrossCuts: [PendingCrossCutOverlay] = []

        // Helper: scan forward from `idx` to find the next segment's incoming
        // transition crossfade duration (if any). Skips further cross-cut
        // segments since they don't drive speaker-video transitions.
        func nextReturnCrossfade(after idx: Int) -> Double {
            var j = idx + 1
            while j < spec.segments.count {
                if isCrossCutSegment(j) { j += 1; continue }
                if let t = spec.segments[j].transition, t.type == .crossfade {
                    return t.duration
                }
                return 0
            }
            return 0
        }

        // trackIdx counter advances only for non-cross-cut segments, since
        // cross-cut segments don't consume an A/B slot. Without this, an
        // intervening cross-cut would flip the A/B alternation incorrectly.
        var speakerSegIdx = 0

        for (index, segment) in spec.segments.enumerated() {
            let startTime = CMTime(seconds: segment.start, preferredTimescale: 600)
            let endTime = CMTime(seconds: segment.end, preferredTimescale: 600)
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

            // ── Cross-cut path: route to video overlay, no timeline advance ──
            if isCrossCutSegment(index) {
                let fadeIn = (segment.transition?.type == .crossfade)
                    ? (segment.transition?.duration ?? 0) : 0
                let fadeOut = nextReturnCrossfade(after: index)
                // Visual start: pull back the overlay by its own fade-in so
                // the broll begins crossfading IN at the moment the speaker
                // video would otherwise continue uninterrupted — the editor
                // sees "broll fades in across insertionTime - fadeIn → +fadeIn"
                // matching the visual language of the non-crosscut transition.
                let pullback = CMTime(seconds: min(fadeIn, CMTimeGetSeconds(outputDuration)), preferredTimescale: 600)
                let visualStart = CMTimeSubtract(insertionTime, pullback)
                pendingCrossCuts.append(PendingCrossCutOverlay(
                    segIdx: index,
                    visualStart: visualStart,
                    sourceStart: startTime,
                    duration: outputDuration,
                    fadeIn: fadeIn,
                    fadeOutFromNext: fadeOut
                ))
                captionLog("[Builder] Cross-cut seg[\(index)] src=\(segment.sourceId) → OVERLAY: visualStart=\(round(CMTimeGetSeconds(visualStart)*100)/100) dur=\(round(CMTimeGetSeconds(outputDuration)*100)/100) fadeIn=\(fadeIn) fadeOut=\(fadeOut) (no timeline advance, no audio)")
                continue
            }

            guard let asset = sourceAssets[segment.sourceId] else {
                throw CompositionError.sourceNotFound(segment.sourceId)
            }

            let srcVideoTracks = try await asset.loadTracks(withMediaType: .video)
            let srcAudioTracks = try await asset.loadTracks(withMediaType: .audio)

            let timeRange = CMTimeRange(start: startTime, end: endTime)

            // Incoming crossfade: pull insertion time back to create overlap.
            // Applies relative to the prior NON-CROSS-CUT segment's natural
            // end — since cross-cut segments no longer advance insertionTime,
            // that end is exactly `insertionTime` at this point in the loop.
            //
            // Bridged-by-overlay detection: if a pending cross-cut overlay
            // fully spans the transition window [insertionTime - dur,
            // insertionTime], the visual crossfade is invisible (broll
            // covers the seam) AND a linear audio crossfade on correlated
            // voice audio produces a -6 dB notch — audible exactly as "the
            // glitch at overlay-end." In that case we skip the crossfade
            // entirely: no video pullback, no audio ramp, no overlap. Video
            // and audio both land at the natural back-to-back position and
            // the broll overlay covers the cut visually.
            let transitionDur: CMTime
            var bridgedByOverlay = false
            if speakerSegIdx > 0, let transition = segment.transition, transition.type == .crossfade {
                let clamped = min(transition.duration, CMTimeGetSeconds(outputDuration))
                let candidateDur = CMTime(seconds: clamped, preferredTimescale: 600)
                let transitionStart = CMTimeSubtract(insertionTime, candidateDur)
                let transitionEnd = insertionTime
                for pending in pendingCrossCuts {
                    let pendingEnd = CMTimeAdd(pending.visualStart, pending.duration)
                    if CMTimeCompare(pending.visualStart, transitionStart) <= 0 &&
                       CMTimeCompare(pendingEnd, transitionEnd) >= 0 {
                        bridgedByOverlay = true
                        break
                    }
                }
                if bridgedByOverlay {
                    transitionDur = .zero   // skip crossfade entirely — broll masks the cut
                    captionLog("[Builder] Crossfade SKIPPED at seg[\(index)] (bridged by cross-cut overlay) — audio plays through uninterrupted at \(round(CMTimeGetSeconds(insertionTime)*100)/100)s; requested dur=\(clamped)s")
                } else {
                    transitionDur = candidateDur
                    insertionTime = CMTimeSubtract(insertionTime, transitionDur)
                }
            } else {
                transitionDur = .zero
            }

            let audioInsertionTime = insertionTime

            // Track assignment:
            // - Normal crossfade (transitionDur > 0) → alternate A/B so the
            //   outgoing and incoming layers coexist during the overlap.
            // - Bridged-by-overlay (transitionDur == 0 AND broll masks the
            //   seam) → REUSE the previous speaker's track so both segments
            //   concatenate on the same AVMutableCompositionTrack with no
            //   track swap. A cross-track hand-off at a sample boundary
            //   between correlated voice clips — even with zero ramp — causes
            //   the audible click we've been chasing (run-6 / run-8 glitch).
            //   Back-to-back inserts on the same track are coalesced by
            //   AVFoundation into a single contiguous segment: a true NLE
            //   hard-cut, no resampling boundary.
            //
            // We still advance `speakerSegIdx` after this segment so that any
            // later normal crossfade continues to alternate correctly.
            let trackIdx: Int
            if bridgedByOverlay, let prevLayout = layouts.last {
                trackIdx = prevLayout.trackIndex
            } else {
                trackIdx = speakerSegIdx % 2
            }
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

            // Insert audio — every non-cross-cut segment contributes its own
            // natural source audio. With cross-cut segments routed to
            // overlays, there's no more bridge extension: speaker segments
            // land contiguously on A/B tracks in composition time, so the
            // speaker's voice plays continuously with no gaps or splices.
            if let srcAT = srcAudioTracks.first, let aTrack {
                let audioTimeRange = CMTimeRange(start: startTime, duration: segmentDuration)
                try aTrack.insertTimeRange(audioTimeRange, of: srcAT, at: audioInsertionTime)

                if speed != 1.0 {
                    aTrack.scaleTimeRange(
                        CMTimeRange(start: audioInsertionTime, duration: segmentDuration),
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
                volume: Float(segment.volume ?? 1.0),
                audioFromPrev: false,
                bridgedByOverlay: bridgedByOverlay
            ))

            captionLog("[Builder] LAYOUT seg[\(index)] src=\(segment.sourceId) trackIdx=\(trackIdx) (\(trackIdx == 0 ? "A" : "B")) insertionTime=\(String(format: "%.4f", CMTimeGetSeconds(insertionTime)))s audioInsertionTime=\(String(format: "%.4f", CMTimeGetSeconds(audioInsertionTime)))s duration=\(String(format: "%.4f", CMTimeGetSeconds(outputDuration)))s transitionDur=\(String(format: "%.4f", CMTimeGetSeconds(transitionDur)))s bridgedByOverlay=\(bridgedByOverlay) speakerSegIdx=\(speakerSegIdx)")

            insertionTime = CMTimeAdd(insertionTime, outputDuration)
            speakerSegIdx += 1
        }

        // --- Bridged-transition layout verification ---
        //
        // For every layout entry with bridgedByOverlay == true, assert at
        // build time that:
        //   1. It lands on the SAME trackIdx as the prior speaker segment.
        //   2. Its compositionStart equals the prior segment's end exactly
        //      (no overlap, no gap). Meaning: transitionDur == 0 AND no
        //      insertionTime pullback occurred.
        // If either fails, the render has the run-6/run-8 regression and we
        // log a loud warning so it's visible in the dump.
        for i in 1..<layouts.count {
            let curr = layouts[i]
            guard curr.bridgedByOverlay else { continue }
            let prev = layouts[i - 1]
            let prevEnd = CMTimeAdd(prev.compositionStart, prev.duration)
            let sameTrack = curr.trackIndex == prev.trackIndex
            let backToBack = CMTimeCompare(curr.compositionStart, prevEnd) == 0
            let zeroTransition = CMTimeGetSeconds(curr.transitionDur) == 0
            if sameTrack && backToBack && zeroTransition {
                captionLog("[Builder] BRIDGE-VERIFY seg[\(i)] OK: same track (\(curr.trackIndex == 0 ? "A" : "B")), back-to-back at \(String(format: "%.4f", CMTimeGetSeconds(curr.compositionStart)))s, zero crossfade — hard-cut on single track")
            } else {
                captionLog("[Builder] BRIDGE-VERIFY seg[\(i)] FAIL: sameTrack=\(sameTrack) (prev=\(prev.trackIndex) curr=\(curr.trackIndex)) backToBack=\(backToBack) (prevEnd=\(String(format: "%.4f", CMTimeGetSeconds(prevEnd))) currStart=\(String(format: "%.4f", CMTimeGetSeconds(curr.compositionStart)))) zeroTransition=\(zeroTransition) (transitionDur=\(String(format: "%.4f", CMTimeGetSeconds(curr.transitionDur))))")
            }
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

            // Audio crossfade on the A/B track pair at the transition overlap.
            // Cross-cut segments never enter `layouts` (they're overlays), so
            // every `layouts` entry is a real speaker segment with its own
            // audio. Bridged-by-overlay segments have transitionDur == 0
            // (set in Pass 1), so `hasIncoming` is false for them and this
            // ramp is correctly skipped — audio plays through uninterrupted.
            if hasIncoming {
                let prev = layouts[index - 1]
                let tRange = CMTimeRange(start: segStart, duration: layout.transitionDur)
                let prevAP = prev.trackIndex == 0 ? audioParamsA : audioParamsB
                let currAP = layout.trackIndex == 0 ? audioParamsA : audioParamsB
                prevAP?.setVolumeRamp(fromStartVolume: prev.volume, toEndVolume: 0, timeRange: tRange)
                currAP?.setVolumeRamp(fromStartVolume: 0, toEndVolume: layout.volume, timeRange: tRange)
            }

            // Custom volume outside of crossfade regions.
            // The audio pass-through region starts where the actual audio
            // was inserted: at segStart+transitionDur for both normal
            // crossfades (post-ramp) and bridged ones (natural back-to-back).
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

                    // Speed: playback-rate multiplier for overlay source content.
                    // 1.0 = realtime, 0.25 = 4x slow-mo, 2.0 = 2x fast-forward.
                    // The overlay's composition window [start, end] is unchanged;
                    // only how much source content gets consumed changes.
                    // Warn on out-of-range and clamp to the documented 0.25-4.0.
                    let rawSpeed = overlay.speed ?? 1.0
                    var overlaySpeed = rawSpeed
                    if overlaySpeed < 0.25 || overlaySpeed > 4.0 {
                        let clamped = min(max(rawSpeed, 0.25), 4.0)
                        captionLog("[Builder] WARNING: video overlay '\(sourceId)' speed=\(rawSpeed)x out of range (0.25-4.0) — clamping to \(clamped)x")
                        overlaySpeed = clamped
                    }

                    // Auto-clamp: if overlay duration exceeds available source media, clamp it.
                    // With speed != 1.0, source content consumed = compositionDuration * speed.
                    var effectiveOverlayDuration = overlayDuration
                    var effectiveOverlayEnd = overlayEnd
                    var sourceConsumedSeconds = CMTimeGetSeconds(overlayDuration) * overlaySpeed
                    if let srcVT = srcVideoTracks.first {
                        let srcDuration = try await srcVT.load(.timeRange).duration
                        let availableDuration = CMTimeSubtract(srcDuration, sourceOffset)
                        let availableSeconds = CMTimeGetSeconds(availableDuration)
                        if sourceConsumedSeconds > availableSeconds {
                            // Reduce both source consumption AND composition window (proportionally via speed)
                            let newCompositionSeconds = availableSeconds / overlaySpeed
                            captionLog("[Builder] Auto-clamping video overlay '\(sourceId)': requested \(round(CMTimeGetSeconds(effectiveOverlayDuration)*1000)/1000)s@\(overlaySpeed)x (= \(round(sourceConsumedSeconds*1000)/1000)s source) but only \(round(availableSeconds*1000)/1000)s available from sourceStart — shortening composition window to \(round(newCompositionSeconds*1000)/1000)s")
                            effectiveOverlayDuration = CMTime(seconds: newCompositionSeconds, preferredTimescale: 600)
                            effectiveOverlayEnd = CMTimeAdd(overlayStart, effectiveOverlayDuration)
                            sourceConsumedSeconds = availableSeconds
                        }
                    }

                    // Insert sourceConsumedSeconds of source, then scaleTimeRange to
                    // stretch (slow) or compress (fast) to the composition window.
                    let sourceConsumedDuration = CMTime(seconds: sourceConsumedSeconds, preferredTimescale: 600)
                    let sourceRange = CMTimeRange(start: sourceOffset, duration: sourceConsumedDuration)

                    if let srcVT = srcVideoTracks.first {
                        guard let ovTrack = composition.addMutableTrack(
                            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                        ) else {
                            throw CompositionError.failedToCreateTrack
                        }
                        try ovTrack.insertTimeRange(sourceRange, of: srcVT, at: overlayStart)
                        if overlaySpeed != 1.0 {
                            ovTrack.scaleTimeRange(
                                CMTimeRange(start: overlayStart, duration: sourceConsumedDuration),
                                toDuration: effectiveOverlayDuration
                            )
                        }

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
                            fadeOut: fadeOut,
                            keyframes: resolveOverlayKeyframes(overlay.keyframes)
                        ))

                        captionLog("[Builder] Overlay track: id=\(ovTrack.trackID) sourceId=\(sourceId) natSize=\(Int(naturalSize.width))x\(Int(naturalSize.height)) target=\(Int(targetRect.width))x\(Int(targetRect.height))@(\(Int(targetRect.origin.x)),\(Int(targetRect.origin.y))) time=\(round(CMTimeGetSeconds(overlayStart)*1000)/1000)..\(round(CMTimeGetSeconds(effectiveOverlayEnd)*1000)/1000) speed=\(overlaySpeed)x srcConsumed=\(round(sourceConsumedSeconds*1000)/1000)s segments=\(ovTrack.segments?.count ?? 0) keyframes=\(overlay.keyframes?.count ?? 0)")
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
                        if overlaySpeed != 1.0 {
                            ovAudioTrack.scaleTimeRange(
                                CMTimeRange(start: overlayStart, duration: sourceConsumedDuration),
                                toDuration: effectiveOverlayDuration
                            )
                        }

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
                        fadeOut: fadeOut,
                        keyframes: resolveOverlayKeyframes(overlay.keyframes)
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
                        fadeOut: fadeOut,
                        keyframes: resolveOverlayKeyframes(overlay.keyframes)
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

                    // Warn if a full-bleed image overlay has transparent edges.
                    // The PNG's alpha perimeter will let the main video bleed
                    // through around the edges — usually an authoring bug
                    // (transparent padding around the card artwork).
                    let isFullBleed = abs(targetRect.origin.x) < 0.5
                        && abs(targetRect.origin.y) < 0.5
                        && abs(targetRect.width - renderSize.width) < 1.0
                        && abs(targetRect.height - renderSize.height) < 1.0
                    if isFullBleed, let edgeBleed = detectTransparentEdge(cgImage: cgImage) {
                        captionLog("[Builder] WARNING: full-bleed image overlay '\(path)' has transparent edge (~\(edgeBleed)px) — main video will bleed through around the perimeter. Paint the PNG edge-to-edge opaque.")
                    }

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
                        fadeOut: fadeOut,
                        keyframes: resolveOverlayKeyframes(overlay.keyframes)
                    ))

                    captionLog("[Builder] Image overlay: path=\(path) source=\(Int(imgW))x\(Int(imgH)) target=\(Int(targetRect.width))x\(Int(targetRect.height))@(\(Int(targetRect.origin.x)),\(Int(targetRect.origin.y))) time=\(round(CMTimeGetSeconds(overlayStart)*1000)/1000)..\(round(CMTimeGetSeconds(overlayEnd)*1000)/1000)")
                }
            }
        }

        // --- Pass 3b: Materialize cross-cut segments as video overlays ---
        //
        // Cross-cut segments were collected during the main segment loop but
        // skipped from A/B track insertion. Now that the speaker timeline is
        // fully laid out, render them as full-frame video overlays layered
        // above the speaker video. Audio is NEVER inserted for these — the
        // speaker's audio plays continuously underneath, uninterrupted.
        for pending in pendingCrossCuts {
            let seg = spec.segments[pending.segIdx]
            guard let asset = sourceAssets[seg.sourceId] else {
                throw CompositionError.sourceNotFound(seg.sourceId)
            }
            let srcVideoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let srcVT = srcVideoTracks.first else { continue }

            // Clamp overlay duration to available source media.
            let srcDuration = try await srcVT.load(.timeRange).duration
            let availableDuration = CMTimeSubtract(srcDuration, pending.sourceStart)
            let effectiveDuration = CMTimeCompare(pending.duration, availableDuration) > 0
                ? availableDuration : pending.duration
            if CMTimeCompare(effectiveDuration, .zero) <= 0 {
                captionLog("[Builder] Cross-cut overlay seg[\(pending.segIdx)]: no source media available, skipping")
                continue
            }

            let sourceRange = CMTimeRange(start: pending.sourceStart, duration: effectiveDuration)
            let overlayEnd = CMTimeAdd(pending.visualStart, effectiveDuration)

            guard let ovTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw CompositionError.failedToCreateTrack
            }
            try ovTrack.insertTimeRange(sourceRange, of: srcVT, at: pending.visualStart)

            let naturalSize = try await srcVT.load(.naturalSize)
            let preferredTransform = try await srcVT.load(.preferredTransform)

            // Full-frame target rect — cross-cut segments cover the whole
            // output. Editors can use true `overlays` entries if they want
            // picture-in-picture or custom positioning.
            let targetRect = CGRect(origin: .zero, size: renderSize)

            overlayLayouts.append(OverlayLayout(
                trackID: ovTrack.trackID,
                overlayStart: pending.visualStart,
                overlayEnd: overlayEnd,
                preferredTransform: preferredTransform,
                naturalSize: naturalSize,
                targetRect: targetRect,
                cornerRadiusFraction: nil,
                cropRect: nil,
                opacity: 1.0,
                generatedImage: nil,
                fadeIn: pending.fadeIn,
                fadeOut: pending.fadeOutFromNext,
                keyframes: nil
            ))

            captionLog("[Builder] Cross-cut overlay materialized seg[\(pending.segIdx)]: trackID=\(ovTrack.trackID) src=\(seg.sourceId) visualTime=\(round(CMTimeGetSeconds(pending.visualStart)*100)/100)..\(round(CMTimeGetSeconds(overlayEnd)*100)/100) fadeIn=\(pending.fadeIn) fadeOut=\(pending.fadeOutFromNext)")
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
                            generatedImage: nil,
                            overlayKeyframes: nil, overlayStartSeconds: nil
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
                            generatedImage: nil,
                            overlayKeyframes: nil, overlayStartSeconds: nil
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
                        // Clamp to pass-through bounds
                        let clampedStart = CMTimeMaximum(kfStart, passStart)
                        let clampedEnd = CMTimeMinimum(kfEnd, passEnd)
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
                                    generatedImage: nil,
                                    overlayKeyframes: nil, overlayStartSeconds: nil
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
                                generatedImage: nil,
                                overlayKeyframes: nil, overlayStartSeconds: nil
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

        // Resolve LUT (optional). Parsing is cached by absolute path.
        var lutData: LUTData? = nil
        if let lutSpec = spec.lut {
            let resolved = resolvePath(lutSpec.path)
            do {
                lutData = try await LUTCache.shared.lut(at: resolved)
            } catch {
                captionLog("[Builder] LUT load failed: \(error.localizedDescription) — continuing without LUT")
                throw error
            }
        }

        return BuildResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            renderSize: renderSize,
            totalDuration: totalDuration,
            fps: fps,
            lut: lutData,
            lutStrength: spec.lut?.resolvedStrength ?? 1.0
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
                generatedImage: ov.generatedImage,
                overlayKeyframes: ov.keyframes,
                overlayStartSeconds: ov.keyframes != nil
                    ? CMTimeGetSeconds(ov.overlayStart) : nil
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

    /// Resolve user-authored `OverlayKeyframe` list into a fully-filled
    /// `ResolvedOverlayKeyframe` list with forward-fill defaults. Per-channel
    /// missing values inherit the prior keyframe's value so authors can set
    /// e.g. scale once and omit it on later opacity-only keyframes. If the
    /// first keyframe omits a channel, the overlay default is used:
    /// scale=1, opacity=1, x/y/rotation=0.
    ///
    /// Returns nil when `keyframes` has fewer than 2 entries — a single
    /// keyframe is indistinguishable from a static transform and the
    /// compositor treats nil as "no animation".
    private func resolveOverlayKeyframes(_ raw: [OverlayKeyframe]?) -> [ResolvedOverlayKeyframe]? {
        guard let raw, raw.count >= 2 else { return nil }
        // Sort by time (defensive — authors may hand-write out of order).
        let sorted = raw.sorted { $0.time < $1.time }
        var resolved: [ResolvedOverlayKeyframe] = []
        var lastScale = 1.0
        var lastOpacity = 1.0
        var lastX = 0.0
        var lastY = 0.0
        var lastRotDeg = 0.0
        for kf in sorted {
            let s = kf.scale ?? lastScale
            let o = kf.opacity ?? lastOpacity
            let x = kf.x ?? lastX
            let y = kf.y ?? lastY
            let r = kf.rotation ?? lastRotDeg
            resolved.append(ResolvedOverlayKeyframe(
                time: kf.time,
                scale: s,
                opacity: o,
                x: x,
                y: y,
                rotationRadians: r * .pi / 180.0
            ))
            lastScale = s
            lastOpacity = o
            lastX = x
            lastY = y
            lastRotDeg = r
        }
        return resolved
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
        /// Resolved keyframes (times relative to `overlayStart`). nil = static.
        let keyframes: [ResolvedOverlayKeyframe]?
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

    /// Scan the 4 edges of a CGImage for fully-transparent pixels.
    /// Returns the thickness (in source pixels) of the transparent border if
    /// the outermost N rows/cols are entirely alpha=0, else nil. Bails out
    /// after N=16 so we don't redraw large opaque images. Used to catch the
    /// "stat-card PNG has an 8px transparent margin" authoring bug at build
    /// time — a full-bleed image overlay with a transparent perimeter lets
    /// the main video bleed through around the edges.
    nonisolated private func detectTransparentEdge(cgImage: CGImage) -> Int? {
        let W = cgImage.width
        let H = cgImage.height
        guard W > 32, H > 32 else { return nil }
        // Only meaningful for images that actually have alpha.
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return nil
        default:
            break
        }
        // Render into a known RGBA8 buffer so we can read alpha bytes directly.
        let bytesPerRow = W * 4
        var buffer = [UInt8](repeating: 0, count: W * H * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            guard let base = raw.baseAddress else { return nil }
            return CGContext(
                data: base, width: W, height: H,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo
            )
        }) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: W, height: H))
        // Probe up to 16 px from each edge. All four edges at a given row/col
        // must be alpha=0 for that thickness to count. Returns the max
        // thickness where all 4 edges are still transparent.
        let maxProbe = min(16, W / 4, H / 4)
        var thickness = 0
        for p in 0..<maxProbe {
            // Check top row p
            var allTransparent = true
            for x in 0..<W {
                let a = buffer[p * bytesPerRow + x * 4 + 3]
                if a != 0 { allTransparent = false; break }
            }
            if !allTransparent { break }
            // Check bottom row (H-1-p)
            for x in 0..<W {
                let a = buffer[(H - 1 - p) * bytesPerRow + x * 4 + 3]
                if a != 0 { allTransparent = false; break }
            }
            if !allTransparent { break }
            // Check left column p
            for y in 0..<H {
                let a = buffer[y * bytesPerRow + p * 4 + 3]
                if a != 0 { allTransparent = false; break }
            }
            if !allTransparent { break }
            // Check right column (W-1-p)
            for y in 0..<H {
                let a = buffer[y * bytesPerRow + (W - 1 - p) * 4 + 3]
                if a != 0 { allTransparent = false; break }
            }
            if !allTransparent { break }
            thickness = p + 1
        }
        return thickness > 0 ? thickness : nil
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
