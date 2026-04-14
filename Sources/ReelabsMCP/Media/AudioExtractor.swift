@preconcurrency import AVFoundation
import Foundation

enum AudioExtractor {
    /// Extract audio from a video file as 16kHz mono FLAC for STT.
    /// Returns a single FLAC file URL. Caller is responsible for cleanup.
    static func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw AudioExtractorError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        return try await extractSegment(asset: asset, start: .zero, duration: duration)
    }

    /// Extract a time-ranged segment of audio to 16kHz mono FLAC.
    private static func extractSegment(asset: AVURLAsset, start: CMTime, duration: CMTime) async throws -> URL {
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioExtractorError.exportSessionFailed
        }

        session.timeRange = CMTimeRange(start: start, duration: duration)

        nonisolated(unsafe) let unsafeSession = session
        let exportTask = Task {
            try await unsafeSession.export(to: m4aURL, as: .m4a)
        }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(180))
            unsafeSession.cancelExport()
        }
        do {
            try await exportTask.value
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            if Task.isCancelled || (error as? CancellationError) != nil {
                throw AudioExtractorError.timedOut
            }
            throw error
        }

        defer { try? FileManager.default.removeItem(at: m4aURL) }

        // Convert M4A → 16kHz mono FLAC
        let flacURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")

        let inputFile = try AVAudioFile(forReading: m4aURL)
        let srcFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioExtractorError.exportSessionFailed
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: outputFormat) else {
            throw AudioExtractorError.exportSessionFailed
        }

        let flacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1
        ]
        let outputFile = try AVAudioFile(forWriting: flacURL, settings: flacSettings)

        let bufferSize: AVAudioFrameCount = 4096
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: bufferSize),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else {
            throw AudioExtractorError.exportSessionFailed
        }

        while true {
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: nil) { inNumPackets, outStatus in
                do {
                    try inputFile.read(into: inputBuffer, frameCount: min(inNumPackets, bufferSize))
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }

            if status == .endOfStream || status == .error {
                break
            }
        }

        return flacURL
    }
}

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case exportSessionFailed
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "No audio track found in video."
        case .exportSessionFailed: "Audio extraction failed."
        case .cancelled: "Audio extraction was cancelled."
        case .timedOut: "Audio extraction timed out (>180s)."
        }
    }
}
