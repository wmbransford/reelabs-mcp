import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

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

    // CIContext created once with Metal, reused across all frames
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        }
        return CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // No state to update
    }

    // Throttle logging: only log every Nth frame per instruction to avoid flooding
    private static let logEveryNthFrame = 30
    private let frameCounter = FrameCounter()

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
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

                    // Opacity
                    let opacity = interpolate(start: layer.opacity, end: layer.opacityEnd, progress: progress)
                    if opacity < 1.0 {
                        image = image.applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                        ])
                    }

                    // Translate to final position
                    image = image.transformed(by: CGAffineTransform(
                        translationX: targetRect.origin.x, y: ciTargetY))

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

                // 1. Apply preferredTransform (handles portrait rotation)
                let prefTx = layer.preferredTransform
                if prefTx != .identity {
                    image = image.transformed(by: prefTx)
                    // Normalize origin to (0,0) after rotation
                    let extent = image.extent
                    if extent.origin != .zero {
                        image = image.transformed(by: CGAffineTransform(
                            translationX: -extent.origin.x, y: -extent.origin.y))
                    }
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

                    // 6. Apply opacity
                    let opacity = interpolate(start: layer.opacity, end: layer.opacityEnd, progress: progress)
                    if opacity < 1.0 {
                        image = image.applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                        ])
                    }

                    // 7. Translate to final position
                    image = image.transformed(by: CGAffineTransform(
                        translationX: targetRect.origin.x, y: ciTargetY))

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

            // Render to output pixel buffer
            guard let outputBuffer = request.renderContext.newPixelBuffer() else {
                captionLog("[Compositor] ERROR: Failed to create output pixel buffer at frame#\(frameNum)")
                request.finish(with: NSError(domain: "VideoCompositor", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create output pixel buffer"]))
                return
            }

            ciContext.render(canvas, to: outputBuffer)
            request.finish(withComposedVideoFrame: outputBuffer)
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
