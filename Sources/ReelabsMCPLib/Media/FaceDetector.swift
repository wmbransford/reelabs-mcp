import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Runs Apple Vision face detection directly against a video file.
///
/// Sampling bypasses the JPEG round-trip: `AVAssetImageGenerator` hands us
/// `CGImage`s straight from decoded frames, which feed into
/// `VNDetectFaceRectanglesRequest`. Detections are then greedy-clustered by
/// spatial proximity so the caller gets a stable set of tracked faces.
///
/// Coordinate system: Vision returns bboxes in bottom-left normalized space.
/// We convert to top-left (origin upper-left, y grows downward) so everything
/// downstream — RenderSpec panX, scene focus_point, graphics overlays —
/// uses one convention.
package enum FaceDetector {
    /// Minimum fraction of sampled frames a cluster must appear in to survive
    /// the noise filter. 0.02 drops one-off false positives without killing
    /// real faces that briefly leave frame.
    private static let clusterVisibilityFloor: Double = 0.02

    /// Max center-distance (in normalized image width) for a face to join an
    /// existing cluster. 0.15 ≈ 15% of the frame: loose enough to keep a single
    /// host as one cluster when they lean forward / sit back over a long take,
    /// tight enough to keep two adjacent hosts on a tight two-shot distinct.
    private static let clusterMergeThreshold: Double = 0.15

    package static func detect(
        videoPath: String,
        sampleFps: Double = 2.0
    ) async throws -> FaceDetectionResult {
        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw FaceDetectorError.noVideoTrack
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 960, height: 960)

        let interval = 1.0 / sampleFps
        var times: [CMTime] = []
        var t = 0.0
        while t < durationSeconds {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += interval
        }

        var frames: [FrameFaceDetection] = []
        frames.reserveCapacity(times.count)

        for await result in generator.images(for: times) {
            let timeSeconds = CMTimeGetSeconds(result.requestedTime)
            let cgImage: CGImage
            do {
                cgImage = try result.image
            } catch {
                continue
            }

            let faces = (try? detectFaces(in: cgImage)) ?? []
            frames.append(FrameFaceDetection(
                time: (timeSeconds * 100).rounded() / 100,
                faces: faces
            ))
        }

        let clusters = clusterFaces(frames: frames)
        let source = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent

        return FaceDetectionResult(
            source: source,
            sampleFps: sampleFps,
            durationSeconds: durationSeconds,
            frameCount: frames.count,
            frames: frames,
            clusters: clusters
        )
    }

    private static func detectFaces(in cgImage: CGImage) throws -> [FaceDetection] {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }
        return results.map { obs in
            // Vision: origin bottom-left. Flip to top-left.
            let topLeftY = 1.0 - obs.boundingBox.origin.y - obs.boundingBox.height
            let bbox = BoundingBox(
                x: obs.boundingBox.origin.x,
                y: topLeftY,
                w: obs.boundingBox.width,
                h: obs.boundingBox.height
            )
            let center = FocusPoint(
                x: obs.boundingBox.origin.x + obs.boundingBox.width / 2,
                y: topLeftY + obs.boundingBox.height / 2
            )
            return FaceDetection(
                bbox: bbox,
                center: center,
                confidence: Double(obs.confidence)
            )
        }
    }

    /// Greedy spatial clustering across frames. Each detection joins the
    /// nearest existing cluster within `clusterMergeThreshold`, else starts a
    /// new one. Final clusters are re-sorted left-to-right by median x so
    /// ids are stable across re-runs of identical input.
    private static func clusterFaces(frames: [FrameFaceDetection]) -> [FaceCluster] {
        struct Accumulator {
            var xs: [Double] = []
            var ys: [Double] = []
            var ws: [Double] = []
            var hs: [Double] = []
            var centerXs: [Double] = []
            var centerYs: [Double] = []
        }

        var accumulators: [Accumulator] = []

        for frame in frames {
            for face in frame.faces {
                var bestIdx: Int?
                var bestDist = Double.infinity
                for (i, acc) in accumulators.enumerated() {
                    let mx = median(acc.centerXs)
                    let my = median(acc.centerYs)
                    let dx = face.center.x - mx
                    let dy = face.center.y - my
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < bestDist && d < clusterMergeThreshold {
                        bestDist = d
                        bestIdx = i
                    }
                }

                if let idx = bestIdx {
                    accumulators[idx].xs.append(face.bbox.x)
                    accumulators[idx].ys.append(face.bbox.y)
                    accumulators[idx].ws.append(face.bbox.w)
                    accumulators[idx].hs.append(face.bbox.h)
                    accumulators[idx].centerXs.append(face.center.x)
                    accumulators[idx].centerYs.append(face.center.y)
                } else {
                    var acc = Accumulator()
                    acc.xs.append(face.bbox.x)
                    acc.ys.append(face.bbox.y)
                    acc.ws.append(face.bbox.w)
                    acc.hs.append(face.bbox.h)
                    acc.centerXs.append(face.center.x)
                    acc.centerYs.append(face.center.y)
                    accumulators.append(acc)
                }
            }
        }

        let totalFrames = max(frames.count, 1)
        var clusters: [FaceCluster] = []
        for acc in accumulators {
            let count = acc.xs.count
            let visibility = Double(count) / Double(totalFrames)
            guard visibility >= clusterVisibilityFloor else { continue }
            let bbox = BoundingBox(
                x: median(acc.xs),
                y: median(acc.ys),
                w: median(acc.ws),
                h: median(acc.hs)
            )
            let center = FocusPoint(
                x: median(acc.centerXs),
                y: median(acc.centerYs)
            )
            clusters.append(FaceCluster(
                id: 0,
                medianCenter: center,
                medianBbox: bbox,
                visibility: visibility,
                frameCount: count
            ))
        }

        clusters.sort { $0.medianCenter.x < $1.medianCenter.x }
        return clusters.enumerated().map { idx, c in
            FaceCluster(
                id: idx,
                medianCenter: c.medianCenter,
                medianBbox: c.medianBbox,
                visibility: c.visibility,
                frameCount: c.frameCount
            )
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    enum FaceDetectorError: Error, LocalizedError {
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "No video track found in file"
            }
        }
    }
}
