import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Interpolated overlay-keyframe values at a given frame time. All channels
/// are absolute (never nil) — the keyframe resolver forward-fills missing
/// channels to prior values, and `identity` holds the no-op defaults.
struct OverlayKeyframeSample {
    let scale: Double
    let opacity: Double
    let x: Double
    let y: Double
    let rotationRadians: Double

    static let identity = OverlayKeyframeSample(
        scale: 1.0, opacity: 1.0, x: 0.0, y: 0.0, rotationRadians: 0.0
    )
}

/// Thread-safe frame counter for log throttling.
private final class FrameCounter: @unchecked Sendable {
    private var _count = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
        return _count
    }
}

/// Custom AVVideoCompositing that composites all layers via CIImage (Metal-backed GPU).
/// Handles main segment transforms, crossfade transitions, overlay positioning,
/// corner radius masking, and source crop — all in one pipeline.
final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    /// Pre-rendered caption overlay for single-pass rendering.
    /// Set before reader.startReading(), cleared after export completes.
    /// Thread-safe: RenderQueue serializes renders.
    nonisolated(unsafe) static var captionOverlay: CaptionOverlay?

    // Pixel buffer attributes for input/output
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    /// LUT filter to apply to each source pixel buffer before compositing.
    /// Set before reader.startReading(), cleared after export completes.
    /// A non-nil value also switches the CIContext's working color space to
    /// linear sRGB so cube interpolation happens in linear light.
    nonisolated(unsafe) static var lutFilter: CIFilter?

    /// Strength of the LUT blend 0..1. 1.0 = fully graded.
    nonisolated(unsafe) static var lutStrength: Double = 1.0

    // CIContext for non-LUT renders (sRGB working space — matches the pre-LUT default).
    private let ciContextSRGB: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        }
        return CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    }()

    // CIContext for LUT renders (linear sRGB working space).
    // Keeping two contexts alive avoids the cost of recreating them per render
    // and lets both code paths take the Metal fast path.
    private let ciContextLinear: CIContext = {
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: linear])
        }
        return CIContext(options: [.workingColorSpace: linear])
    }()

    private var ciContext: CIContext {
        Self.lutFilter != nil ? ciContextLinear : ciContextSRGB
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // No state to update
    }

    // Throttle logging: only log every Nth frame per instruction to avoid flooding
    private static let logEveryNthFrame = 30
    private let frameCounter = FrameCounter()

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            let frameStart = CFAbsoluteTimeGetCurrent()

            guard let instruction = request.videoCompositionInstruction as? CompositorInstruction else {
                captionLog("[Compositor] ERROR: Unknown instruction type (not CompositorInstruction)")
                request.finish(with: NSError(domain: "VideoCompositor", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown instruction type"]))
                return
            }

            let renderSize = instruction._renderSize
            let renderW = renderSize.width
            let renderH = renderSize.height

            // Progress through the instruction's time range for interpolation
            let currentTime = request.compositionTime
            let instrStart = CMTimeGetSeconds(instruction.timeRange.start)
            let instrDur = CMTimeGetSeconds(instruction.timeRange.duration)
            let elapsed = CMTimeGetSeconds(currentTime) - instrStart
            let progress = instrDur > 0 ? Float(min(max(elapsed / instrDur, 0), 1)) : 0

            let frameNum = frameCounter.increment()
            let shouldLog = frameNum <= 3 || frameNum % Self.logEveryNthFrame == 0

            if shouldLog {
                let trackIDs = instruction.layers.map { "\($0.trackID)\($0.targetRect != nil ? "(overlay)" : "")" }
                let reqIDs = (instruction.requiredSourceTrackIDs ?? []).map { "\($0)" }
                captionLog("[Compositor] frame#\(frameNum) time=\(round(CMTimeGetSeconds(currentTime) * 1000) / 1000)s layers=\(instruction.layers.count) trackIDs=[\(trackIDs.joined(separator: ","))] requiredIDs=[\(reqIDs.joined(separator: ","))] renderSize=\(Int(renderW))x\(Int(renderH))")
            }

            // Start with a transparent canvas
            var canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: renderW, height: renderH))

            // Composite layers back-to-front
            for (layerIdx, layer) in instruction.layers.enumerated() {
                // Sample the overlay's keyframe curve once per layer. For
                // non-keyframed overlays (or main segments), the sample is
                // the identity: scale=1, opacity=1, x=y=rotation=0.
                let kfSample = sampleOverlayKeyframes(
                    layer: layer,
                    currentTime: CMTimeGetSeconds(currentTime)
                )

                // --- Generated overlay (color/text) ---
                if let genImage = layer.generatedImage {
                    if shouldLog {
                        captionLog("[Compositor]   layer[\(layerIdx)] GENERATED overlay \(Int(genImage.extent.width))x\(Int(genImage.extent.height))")
                    }
                    var image = genImage
                    let targetRect = layer.targetRect!
                    let targetW = targetRect.width
                    let targetH = targetRect.height
                    let ciTargetY = renderH - targetRect.origin.y - targetH

                    // Corner radius (if not already baked in by TextOverlayRenderer)
                    if let radiusFrac = layer.cornerRadiusFraction, radiusFrac > 0 {
                        let cornerPx = radiusFrac * min(targetW, targetH) / 2
                        let maskImage = roundedRectMask(
                            size: CGSize(width: targetW, height: targetH),
                            cornerRadius: cornerPx
                        )
                        let blendFilter = CIFilter.blendWithMask()
                        blendFilter.inputImage = image
                        blendFilter.backgroundImage = CIImage.clear
                            .cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                        blendFilter.maskImage = maskImage
                        if let masked = blendFilter.outputImage {
                            image = masked
                        }
                    }

                    // Apply keyframe scale + rotation about the overlay center
                    // (image is at origin (0,0), size targetW x targetH). Any
                    // keyframe translation is folded into the final positioning
                    // below as a pixel offset.
                    image = Self.applyOverlayKeyframeTransform(
                        image: image,
                        size: CGSize(width: targetW, height: targetH),
                        sample: kfSample
                    )

                    // Opacity (fade-ramp from timeRange × keyframe multiplier)
                    let baseOpacity = interpolate(start: layer.opacity, end: layer.opacityEnd, progress: progress)
                    let opacity = baseOpacity * Float(kfSample.opacity)
                    if opacity < 1.0 {
                        image = image.applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                        ])
                    }

                    // Translate to final position, including keyframe pixel
                    // offset (x/y are fractions of render size).
                    let kfOffsetX = CGFloat(kfSample.x) * renderW
                    let kfOffsetY = CGFloat(kfSample.y) * renderH
                    image = image.transformed(by: CGAffineTransform(
                        translationX: targetRect.origin.x + kfOffsetX,
                        // y is top-left in spec space → subtract from CIImage y.
                        y: ciTargetY - kfOffsetY))

                    canvas = image.composited(over: canvas)
                    continue
                }

                // --- Source-backed layer (video overlay or main segment) ---
                guard let sourceBuffer = request.sourceFrame(byTrackID: layer.trackID) else {
                    if shouldLog {
                        captionLog("[Compositor]   layer[\(layerIdx)] trackID=\(layer.trackID) sourceFrame=NIL (skipped) isOverlay=\(layer.targetRect != nil)")
                    }
                    continue
                }
                if shouldLog {
                    let bufW = CVPixelBufferGetWidth(sourceBuffer)
                    let bufH = CVPixelBufferGetHeight(sourceBuffer)
                    let fmt = CVPixelBufferGetPixelFormatType(sourceBuffer)
                    captionLog("[Compositor]   layer[\(layerIdx)] trackID=\(layer.trackID) buffer=\(bufW)x\(bufH) fmt=\(fmt) isOverlay=\(layer.targetRect != nil)")
                }

                var image = CIImage(cvPixelBuffer: sourceBuffer)

                // 1. Apply preferredTransform (handles portrait rotation / camera-roll flips).
                //    Conjugate with Y-flips because preferredTransform is defined in
                //    top-left-origin AVFoundation space while CIImage uses bottom-left.
                //    Without this conjugation, 180° rotations (common on Sony vertical-
                //    native HEVC clips) render upside-down (see FUTURE-TODO #10).
                let prefTx = layer.preferredTransform
                if prefTx != .identity {
                    let bufferH = image.extent.height
                    // Target extent after applying prefTx (from top-left reference frame)
                    let rotatedSize = layer.naturalSize.applying(prefTx)
                    let rotatedW = abs(rotatedSize.width)
                    let rotatedH = abs(rotatedSize.height)
                    let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bufferH)
                    let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rotatedH)
                    let ciPrefTx = flipIn.concatenating(prefTx).concatenating(flipOut)
                    image = image.transformed(by: ciPrefTx)
                    // Normalize to origin (0,0) — conjugation should leave it at zero,
                    // but belt-and-suspenders against floating-point drift.
                    let extent = image.extent
                    if extent.origin != .zero {
                        image = image.transformed(by: CGAffineTransform(
                            translationX: -extent.origin.x, y: -extent.origin.y))
                    }
                    _ = rotatedW  // silence unused-warning; kept for future debug
                }

                // 2. Apply LUT (if configured) to the oriented source buffer.
                //    Applies to video overlays and main segments alike; does NOT apply
                //    to generated overlays (color/text/image cards — handled above).
                if let lut = Self.lutFilter {
                    image = Self.applyLUT(filter: lut, strength: Self.lutStrength, to: image)
                }

                let sourceW = image.extent.width
                let sourceH = image.extent.height

                if layer.targetRect != nil {
                    // --- OVERLAY LAYER ---
                    let targetRect = layer.targetRect!
                    let targetW = targetRect.width
                    let targetH = targetRect.height
                    // Top-left Y from spec → CIImage bottom-left Y
                    let ciTargetY = renderH - targetRect.origin.y - targetH

                    // 2. Apply source crop (before scaling)
                    if let cropFrac = layer.cropRect {
                        let cropX = cropFrac.origin.x * sourceW
                        // CIImage Y: flip crop fraction
                        let cropY = (1.0 - cropFrac.origin.y - cropFrac.height) * sourceH
                        let cropW = cropFrac.width * sourceW
                        let cropH = cropFrac.height * sourceH
                        image = image.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
                        // Normalize origin
                        let ext = image.extent
                        if ext.origin != .zero {
                            image = image.transformed(by: CGAffineTransform(
                                translationX: -ext.origin.x, y: -ext.origin.y))
                        }
                    }

                    let croppedW = image.extent.width
                    let croppedH = image.extent.height

                    // 3. Cover-fill into target rect
                    let coverScale = max(targetW / croppedW, targetH / croppedH)
                    image = image.transformed(by: CGAffineTransform(scaleX: coverScale, y: coverScale))
                    // Center within target
                    let scaledW = croppedW * coverScale
                    let scaledH = croppedH * coverScale
                    let offsetX = (targetW - scaledW) / 2
                    let offsetY = (targetH - scaledH) / 2
                    image = image.transformed(by: CGAffineTransform(
                        translationX: offsetX, y: offsetY))

                    // 4. Clip to target rect (at origin, will translate later)
                    image = image.cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))

                    // 5. Apply corner radius mask
                    if let radiusFrac = layer.cornerRadiusFraction, radiusFrac > 0 {
                        let cornerPx = radiusFrac * min(targetW, targetH) / 2
                        let maskImage = roundedRectMask(
                            size: CGSize(width: targetW, height: targetH),
                            cornerRadius: cornerPx
                        )
                        let blendFilter = CIFilter.blendWithMask()
                        blendFilter.inputImage = image
                        blendFilter.backgroundImage = CIImage.clear
                            .cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                        blendFilter.maskImage = maskImage
                        if let masked = blendFilter.outputImage {
                            image = masked
                        }
                    }

                    // 6. Apply keyframe scale + rotation about overlay center.
                    image = Self.applyOverlayKeyframeTransform(
                        image: image,
                        size: CGSize(width: targetW, height: targetH),
                        sample: kfSample
                    )

                    // 7. Apply opacity (fade ramp × keyframe multiplier)
                    let baseOpacity = interpolate(start: layer.opacity, end: layer.opacityEnd, progress: progress)
                    let opacity = baseOpacity * Float(kfSample.opacity)
                    if opacity < 1.0 {
                        image = image.applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                        ])
                    }

                    // 8. Translate to final position, including keyframe pixel
                    // offset (x/y are render-size fractions; y is top-left so
                    // it subtracts from the CIImage bottom-left y).
                    let kfOffsetX = CGFloat(kfSample.x) * renderW
                    let kfOffsetY = CGFloat(kfSample.y) * renderH
                    image = image.transformed(by: CGAffineTransform(
                        translationX: targetRect.origin.x + kfOffsetX,
                        y: ciTargetY - kfOffsetY))

                } else {
                    // --- MAIN SEGMENT LAYER ---

                    // Interpolate transform
                    let tx: CGAffineTransform
                    if let txEnd = layer.transformEnd {
                        tx = interpolateTransform(start: layer.transform, end: txEnd, progress: progress)
                    } else {
                        tx = layer.transform
                    }

                    // The builder's transforms map from source pixels (top-left origin)
                    // to render pixels (top-left origin). CIImage uses bottom-left origin.
                    // Conjugate with Y-flips: source height for the first flip (bottom-left
                    // → top-left), render height for the second (top-left → bottom-left).
                    // Using renderH for both causes a vertical offset when source != render.
                    var rawImage = CIImage(cvPixelBuffer: sourceBuffer)

                    // Apply LUT on the raw source buffer BEFORE any transform/crop/opacity,
                    // matching the segment-path behaviour. The LUT is independent of
                    // geometry and applies to the scene-linear pixel values.
                    if let lut = Self.lutFilter {
                        rawImage = Self.applyLUT(filter: lut, strength: Self.lutStrength, to: rawImage)
                    }

                    let bufferH = rawImage.extent.height
                    let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bufferH)
                    let flipRender = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderH)
                    let ciTransform = flipSource.concatenating(tx).concatenating(flipRender)
                    if shouldLog {
                        captionLog("[Compositor] FLIP-FIX-V2: bufferH=\(bufferH) renderH=\(renderH)")
                    }
                    rawImage = rawImage.transformed(by: ciTransform)

                    // Clip to render bounds
                    rawImage = rawImage.cropped(to: CGRect(x: 0, y: 0, width: renderW, height: renderH))

                    // Apply opacity
                    let opacity = interpolate(start: layer.opacity, end: layer.opacityEnd, progress: progress)
                    if opacity < 1.0 {
                        rawImage = rawImage.applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                        ])
                    }

                    image = rawImage
                }

                // Composite onto canvas (sourceOver)
                canvas = image.composited(over: canvas)
            }

            // Composite captions (single-pass rendering)
            if let captionOverlay = Self.captionOverlay {
                let t = CMTimeGetSeconds(currentTime)
                for group in captionOverlay.groups {
                    guard t >= group.startTime && t < group.endTime else { continue }
                    // Base words (all visible during group window)
                    for word in group.baseWords {
                        let img = word.image.transformed(by: CGAffineTransform(
                            translationX: word.position.x, y: word.position.y))
                        canvas = img.composited(over: canvas)
                    }
                    // Highlight word (visible only during its time window)
                    for word in group.highlightWords {
                        guard t >= word.startTime && t < word.endTime else { continue }
                        let img = word.image.transformed(by: CGAffineTransform(
                            translationX: word.position.x, y: word.position.y))
                        canvas = img.composited(over: canvas)
                    }
                    break  // only one group active at a time
                }
            }

            // Render to output pixel buffer
            guard let outputBuffer = request.renderContext.newPixelBuffer() else {
                captionLog("[Compositor] ERROR: Failed to create output pixel buffer at frame#\(frameNum)")
                request.finish(with: NSError(domain: "VideoCompositor", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create output pixel buffer"]))
                return
            }

            ciContext.render(canvas, to: outputBuffer)
            request.finish(withComposedVideoFrame: outputBuffer)

            FrameStats.shared.record(elapsed: CFAbsoluteTimeGetCurrent() - frameStart)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        captionLog("[Compositor] cancelAllPendingVideoCompositionRequests called")
    }

    // MARK: - Helpers

    private func interpolate(start: Float, end: Float?, progress: Float) -> Float {
        guard let end = end else { return start }
        return start + (end - start) * progress
    }

    private func interpolateTransform(
        start: CGAffineTransform, end: CGAffineTransform, progress: Float
    ) -> CGAffineTransform {
        let p = CGFloat(progress)
        return CGAffineTransform(
            a: start.a + (end.a - start.a) * p,
            b: start.b + (end.b - start.b) * p,
            c: start.c + (end.c - start.c) * p,
            d: start.d + (end.d - start.d) * p,
            tx: start.tx + (end.tx - start.tx) * p,
            ty: start.ty + (end.ty - start.ty) * p
        )
    }

    /// Apply the LUT filter to `image` and blend with the source based on strength.
    /// strength = 1.0 → fully graded
    /// strength = 0.0 → ungraded (LUT ignored)
    /// 0 < strength < 1 → linear blend via CIColorMatrix alpha+composited.
    /// The LUT is applied as a CIFilter configured once; this just swaps the inputImage.
    static func applyLUT(filter: CIFilter, strength: Double, to image: CIImage) -> CIImage {
        filter.setValue(image, forKey: kCIInputImageKey)
        guard let graded = filter.outputImage else { return image }
        if strength >= 0.999 {
            return graded
        }
        if strength <= 0.001 {
            return image
        }
        // Linear blend: graded * strength + source * (1 - strength).
        // Use CISourceOverCompositing with alpha on graded copy.
        let fadedGraded = graded.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(strength))
        ])
        return fadedGraded.composited(over: image)
    }

    /// Evaluate a layer's `overlayKeyframes` at the given composition time.
    /// Returns the identity sample (scale=1, opacity=1, x=y=rotation=0) for
    /// layers without keyframes.
    ///
    /// Linear interpolation between adjacent keyframes. Before the first or
    /// after the last keyframe, hold the endpoint value (clamp).
    private func sampleOverlayKeyframes(
        layer: LayerInfo,
        currentTime: Double
    ) -> OverlayKeyframeSample {
        guard let kfs = layer.overlayKeyframes,
              let startSec = layer.overlayStartSeconds,
              kfs.count >= 2 else {
            return .identity
        }
        let t = currentTime - startSec
        if t <= kfs.first!.time {
            let k = kfs.first!
            return OverlayKeyframeSample(
                scale: k.scale, opacity: k.opacity,
                x: k.x, y: k.y, rotationRadians: k.rotationRadians
            )
        }
        if t >= kfs.last!.time {
            let k = kfs.last!
            return OverlayKeyframeSample(
                scale: k.scale, opacity: k.opacity,
                x: k.x, y: k.y, rotationRadians: k.rotationRadians
            )
        }
        // Find bracket
        for i in 0..<(kfs.count - 1) {
            let a = kfs[i]
            let b = kfs[i + 1]
            if t >= a.time && t <= b.time {
                let span = b.time - a.time
                let p = span > 0 ? (t - a.time) / span : 0
                return OverlayKeyframeSample(
                    scale: a.scale + (b.scale - a.scale) * p,
                    opacity: a.opacity + (b.opacity - a.opacity) * p,
                    x: a.x + (b.x - a.x) * p,
                    y: a.y + (b.y - a.y) * p,
                    rotationRadians: a.rotationRadians + (b.rotationRadians - a.rotationRadians) * p
                )
            }
        }
        // Shouldn't happen — clamp to last
        let k = kfs.last!
        return OverlayKeyframeSample(
            scale: k.scale, opacity: k.opacity,
            x: k.x, y: k.y, rotationRadians: k.rotationRadians
        )
    }

    /// Apply an overlay keyframe's scale + rotation, centered on the overlay's
    /// target rect (which is at origin (0,0) with dimensions `size` at this
    /// point in the pipeline). Returns the transformed image, still anchored
    /// at origin (0,0) — caller handles the final translation to targetRect.
    /// Skips cheap work when scale == 1.0 and rotation == 0.
    static func applyOverlayKeyframeTransform(
        image: CIImage,
        size: CGSize,
        sample: OverlayKeyframeSample
    ) -> CIImage {
        let s = CGFloat(sample.scale)
        let r = CGFloat(sample.rotationRadians)
        if abs(s - 1.0) < 1e-6 && abs(r) < 1e-6 {
            return image
        }
        let cx = size.width / 2
        let cy = size.height / 2
        // Compose: translate center to origin → rotate → scale → translate back.
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: cx, y: cy)
        if abs(r) > 1e-6 {
            t = t.rotated(by: r)
        }
        if abs(s - 1.0) > 1e-6 {
            t = t.scaledBy(x: s, y: s)
        }
        t = t.translatedBy(x: -cx, y: -cy)
        return image.transformed(by: t)
    }

    /// Create a white rounded rect mask image at origin.
    private func roundedRectMask(size: CGSize, cornerRadius: CGFloat) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Render path to a bitmap
        let bitsPerComponent = 8
        let bytesPerRow = Int(size.width) * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.white.cropped(to: rect)
        }

        ctx.setFillColor(CGColor.white)
        ctx.addPath(path)
        ctx.fillPath()

        guard let cgImage = ctx.makeImage() else {
            return CIImage.white.cropped(to: rect)
        }

        return CIImage(cgImage: cgImage)
    }
}
