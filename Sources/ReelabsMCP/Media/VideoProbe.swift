import AVFoundation
import Foundation

struct ProbeResult: Sendable {
    let duration: Double
    let durationMs: Int
    let width: Int
    let height: Int
    let fps: Double
    let codec: String
    let hasAudio: Bool
    let fileSizeBytes: Int64
    let filename: String
}

enum VideoProbe {
    static func probe(path: String) async throws -> ProbeResult {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw ProbeError.fileNotFound(path)
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var width = 0
        var height = 0
        var fps: Double = 0
        var codec = "unknown"

        if let videoTrack = videoTracks.first {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

            let transformedSize = naturalSize.applying(preferredTransform)
            width = Int(abs(transformedSize.width))
            height = Int(abs(transformedSize.height))
            fps = Double(nominalFrameRate)

            let descriptions = try await videoTrack.load(.formatDescriptions)
            if let desc = descriptions.first {
                let fourCC = CMFormatDescriptionGetMediaSubType(desc)
                codec = fourCCToString(fourCC)
            }
        }

        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        return ProbeResult(
            duration: durationSeconds,
            durationMs: Int(durationSeconds * 1000),
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            hasAudio: !audioTracks.isEmpty,
            fileSizeBytes: fileSize,
            filename: url.lastPathComponent
        )
    }

    private static func fourCCToString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum ProbeError: Error, LocalizedError {
    case fileNotFound(String)
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): "File not found: \(path)"
        case .noVideoTrack: "No video track found"
        }
    }
}
