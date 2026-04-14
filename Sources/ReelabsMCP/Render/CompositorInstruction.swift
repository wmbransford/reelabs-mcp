import AVFoundation
import CoreImage

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

        // Build unique track IDs from layers
        var trackIDs: [NSValue] = []
        var seen = Set<CMPersistentTrackID>()
        for layer in layers {
            if !seen.contains(layer.trackID) {
                seen.insert(layer.trackID)
                trackIDs.append(NSNumber(value: layer.trackID))
            }
        }
        self.requiredSourceTrackIDs = trackIDs

        super.init()
    }
}
