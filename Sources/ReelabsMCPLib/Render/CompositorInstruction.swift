import AVFoundation
import CoreImage

/// Resolved overlay keyframe for compositor-side evaluation. All channels
/// are fully filled (forward-fill from prior keyframes, or overlay defaults
/// scale=1, opacity=1, x/y/rotation=0).
struct ResolvedOverlayKeyframe: Sendable {
    /// Seconds from overlay start.
    let time: Double
    let scale: Double
    let opacity: Double
    let x: Double          // render-width fraction
    let y: Double          // render-height fraction
    let rotationRadians: Double
}

/// Per-layer compositing info for the custom VideoCompositor.
struct LayerInfo: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    let preferredTransform: CGAffineTransform
    let naturalSize: CGSize

    // Transform (static, or start/end for linear interpolation over timeRange)
    let transform: CGAffineTransform
    let transformEnd: CGAffineTransform?

    // Opacity (static, or start/end ramp)
    let opacity: Float
    let opacityEnd: Float?

    // Overlay-specific (all nil for main segments)
    let targetRect: CGRect?           // pixel rect, top-left origin
    let cornerRadiusFraction: Double? // 0.0-1.0
    let cropRect: CGRect?             // 0-1 fractions of source

    // Generated overlay (color/text) — pre-rendered CIImage, skip sourceFrame lookup
    let generatedImage: CIImage?

    /// Overlay animated keyframes, resolved into fully-filled channels.
    /// Times are measured from `overlayStartSeconds`. nil = no animation.
    let overlayKeyframes: [ResolvedOverlayKeyframe]?
    /// Composition time (seconds) where the parent overlay begins. Used to
    /// convert the compositor's `currentTime` into an elapsed-from-overlay
    /// value for keyframe interpolation.
    let overlayStartSeconds: Double?
}

/// Custom instruction that carries an ordered list of layers for the compositor.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let layers: [LayerInfo]
    let _renderSize: CGSize

    // AVVideoCompositionInstructionProtocol requirements
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    init(timeRange: CMTimeRange, layers: [LayerInfo], renderSize: CGSize) {
        self.timeRange = timeRange
        self.layers = layers
        self._renderSize = renderSize

        // Build unique track IDs from layers (skip generated overlays with sentinel trackID)
        var trackIDs: [NSValue] = []
        var seen = Set<CMPersistentTrackID>()
        for layer in layers {
            guard layer.generatedImage == nil else { continue }
            if !seen.contains(layer.trackID) {
                seen.insert(layer.trackID)
                trackIDs.append(NSNumber(value: layer.trackID))
            }
        }
        self.requiredSourceTrackIDs = trackIDs

        super.init()
    }
}
