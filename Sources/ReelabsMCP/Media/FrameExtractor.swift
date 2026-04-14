import AVFoundation
import CoreGraphics
import ImageIO
import Foundation

enum FrameExtractor {
    struct ExtractedFrame: Codable, Sendable {
        let time: Double
        let filename: String
        let path: String
    }

    static func extractFrames(videoPath: String, sampleFps: Double, outputDir: URL) async throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        let interval = 1.0 / sampleFps
        var times: [CMTime] = []
        var t = 0.0
        while t < durationSeconds {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += interval
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var frames: [ExtractedFrame] = []

        for await result in generator.images(for: times) {
            let (requestedTime, cgImage, _) = result
            let timeSeconds = CMTimeGetSeconds(requestedTime)
            let index = frames.count
            let filename = String(format: "frame_%04d.jpg", index)
            let filePath = outputDir.appendingPathComponent(filename)

            try saveJPEG(cgImage, to: filePath, quality: 0.7)

            frames.append(ExtractedFrame(
                time: (timeSeconds * 10).rounded() / 10,
                filename: filename,
                path: filePath.path
            ))
        }

        return frames
    }

    private static func saveJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw FrameExtractorError.cannotCreateDestination
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FrameExtractorError.cannotFinalize
        }
    }

    enum FrameExtractorError: Error, LocalizedError {
        case cannotCreateDestination
        case cannotFinalize

        var errorDescription: String? {
            switch self {
            case .cannotCreateDestination: return "Failed to create JPEG image destination"
            case .cannotFinalize: return "Failed to finalize JPEG image"
            }
        }
    }
}
