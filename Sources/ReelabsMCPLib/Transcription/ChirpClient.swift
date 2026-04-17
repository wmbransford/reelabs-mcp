@preconcurrency import AVFoundation
import Foundation

/// Calls the ReeLabs proxy (`/transcribe`) which forwards to Chirp v2 sync
/// Recognize. The proxy returns the raw Chirp JSON, so the response parser is
/// unchanged from the direct-Chirp era — only auth changed.
///
/// Long audio is chunked into <=55s segments and transcribed in parallel.
final class ChirpClient: Sendable {
    let proxyURL: URL
    let apiToken: String

    init(proxyURL: URL, apiToken: String) {
        self.proxyURL = proxyURL
        self.apiToken = apiToken
    }

    func transcribe(flacURL: URL, durationSeconds: Double, language: String = "en-US") async throws -> TranscriptData {
        if durationSeconds <= 55 {
            return try await transcribeSync(flacURL: flacURL, durationSeconds: durationSeconds, language: language)
        } else {
            return try await transcribeChunkedSync(flacURL: flacURL, durationSeconds: durationSeconds, language: language)
        }
    }

    // MARK: - Chunked Sync Transcription

    private let maxChunkSeconds = 55.0
    private let overlapSeconds = 5.0
    private let maxConcurrentChunks = 10

    private func transcribeChunkedSync(
        flacURL: URL,
        durationSeconds: Double,
        language: String
    ) async throws -> TranscriptData {
        let chunks = try splitAudio(flacURL: flacURL)
        defer {
            for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) }
        }

        captionLog("[ChirpClient] Split \(String(format: "%.1f", durationSeconds))s audio into \(chunks.count) chunks (max \(maxConcurrentChunks) concurrent)")

        let results: [(offset: Double, transcript: TranscriptData)] = try await withThrowingTaskGroup(
            of: (index: Int, offset: Double, transcript: TranscriptData).self
        ) { group in
            var iterator = chunks.enumerated().makeIterator()

            func addNext() -> Bool {
                guard let (index, chunk) = iterator.next() else { return false }
                group.addTask {
                    let transcript = try await self.transcribeSync(
                        flacURL: chunk.url,
                        durationSeconds: chunk.durationSeconds,
                        language: language
                    )
                    return (index: index, offset: chunk.offsetSeconds, transcript: transcript)
                }
                return true
            }

            for _ in 0..<maxConcurrentChunks {
                if !addNext() { break }
            }

            var collected: [(index: Int, offset: Double, transcript: TranscriptData)] = []
            while let result = try await group.next() {
                collected.append(result)
                _ = addNext()
            }
            return collected.sorted { $0.index < $1.index }
                .map { (offset: $0.offset, transcript: $0.transcript) }
        }

        let merged = stitchTranscripts(chunks: results)
        captionLog("[ChirpClient] Stitched \(chunks.count) chunks -> \(merged.words.count) words")
        return merged
    }

    private struct AudioChunk {
        let url: URL
        let offsetSeconds: Double
        let durationSeconds: Double
    }

    private func splitAudio(flacURL: URL) throws -> [AudioChunk] {
        let inputFile = try AVAudioFile(forReading: flacURL)
        let sampleRate = inputFile.processingFormat.sampleRate
        let totalFrames = inputFile.length

        let maxChunkFrames = AVAudioFramePosition(maxChunkSeconds * sampleRate)
        let overlapFrames = AVAudioFramePosition(overlapSeconds * sampleRate)
        let stepFrames = maxChunkFrames - overlapFrames

        var chunks: [AudioChunk] = []
        var currentFrame: AVAudioFramePosition = 0

        while currentFrame < totalFrames {
            let remainingFrames = totalFrames - currentFrame

            if remainingFrames < AVAudioFramePosition(2.0 * sampleRate) && currentFrame > 0 {
                break
            }

            let chunkFrames = min(maxChunkFrames, remainingFrames)

            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("flac")

            inputFile.framePosition = currentFrame

            let flacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: inputFile.processingFormat.channelCount
            ]
            let outputFile = try AVAudioFile(forWriting: chunkURL, settings: flacSettings)

            let bufferSize: AVAudioFrameCount = 8192
            var framesWritten: AVAudioFramePosition = 0

            while framesWritten < chunkFrames {
                let framesToRead = min(AVAudioFrameCount(chunkFrames - framesWritten), bufferSize)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: inputFile.processingFormat,
                    frameCapacity: framesToRead
                ) else { break }

                do {
                    try inputFile.read(into: buffer, frameCount: framesToRead)
                    try outputFile.write(from: buffer)
                    framesWritten += AVAudioFramePosition(buffer.frameLength)
                } catch {
                    break
                }
            }

            let offsetSeconds = Double(currentFrame) / sampleRate
            let durationSeconds = Double(framesWritten) / sampleRate
            chunks.append(AudioChunk(url: chunkURL, offsetSeconds: offsetSeconds, durationSeconds: durationSeconds))

            currentFrame += stepFrames
        }

        return chunks
    }

    private func stitchTranscripts(chunks: [(offset: Double, transcript: TranscriptData)]) -> TranscriptData {
        guard !chunks.isEmpty else {
            return TranscriptData(words: [], fullText: "", durationSeconds: 0)
        }
        if chunks.count == 1 {
            return chunks[0].transcript
        }

        var allWords: [TranscriptWord] = []
        var prevChunkEndTime: Double = 0

        for (index, chunk) in chunks.enumerated() {
            let offset = chunk.offset
            let chunkDur = chunk.transcript.durationSeconds > 0
                ? chunk.transcript.durationSeconds
                : maxChunkSeconds

            for word in chunk.transcript.words {
                guard word.startTime <= chunkDur + 1.0 else { continue }

                let clampedEnd = min(word.endTime, chunkDur)
                let safeEnd = clampedEnd > word.startTime ? clampedEnd : word.startTime + 0.3

                let absoluteStart = word.startTime + offset
                let absoluteEnd = safeEnd + offset

                if index > 0 && absoluteStart < prevChunkEndTime {
                    continue
                }

                allWords.append(TranscriptWord(
                    word: word.word,
                    startTime: absoluteStart,
                    endTime: absoluteEnd,
                    confidence: word.confidence
                ))
            }

            if let lastAccepted = allWords.last {
                prevChunkEndTime = lastAccepted.endTime
            }
        }

        let fullText = allWords.map(\.word).joined(separator: " ")
        let durationSeconds = allWords.last.map { max($0.endTime, $0.startTime) } ?? 0

        return TranscriptData(words: allWords, fullText: fullText, durationSeconds: durationSeconds)
    }

    // MARK: - Proxy Sync Recognize

    private func transcribeSync(flacURL: URL, durationSeconds: Double, language: String) async throws -> TranscriptData {
        let audioData = try Data(contentsOf: flacURL)

        var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "durationSeconds", value: String(format: "%.3f", durationSeconds)),
        ]
        guard let url = components?.url else {
            throw ChirpError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = audioData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChirpError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseSyncResponse(data: data)
        case 401:
            throw ChirpError.unauthenticated
        case 402:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChirpError.quotaExceeded(body: body)
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ChirpError.apiError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    // MARK: - Response parsing

    private func parseSyncResponse(data: Data) throws -> TranscriptData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw ChirpError.parseError("No results in response")
        }

        return parseResultsArray(results)
    }

    private func parseResultsArray(_ results: [[String: Any]]) -> TranscriptData {
        var words: [TranscriptWord] = []
        var fullTextParts: [String] = []

        for result in results {
            guard let alternatives = result["alternatives"] as? [[String: Any]],
                  let alternative = alternatives.first else { continue }

            if let transcript = alternative["transcript"] as? String {
                fullTextParts.append(transcript)
            }

            guard let wordInfos = alternative["words"] as? [[String: Any]], !wordInfos.isEmpty else { continue }

            for wordInfo in wordInfos {
                let word = wordInfo["word"] as? String ?? ""
                let startTime = parseDurationValue(wordInfo["startOffset"])
                let endTime = parseDurationValue(wordInfo["endOffset"])
                let confidence = wordInfo["confidence"] as? Double
                words.append(TranscriptWord(
                    word: word,
                    startTime: startTime,
                    endTime: endTime,
                    confidence: confidence
                ))
            }
        }

        // Fix invalid endTimes:
        // 1. endTime <= startTime (Chirp omitted endOffset, parsed as 0)
        // 2. endTime unreasonably far past the next word
        for i in 0..<words.count {
            let nextStart = (i + 1 < words.count) ? words[i + 1].startTime : nil

            if words[i].endTime <= words[i].startTime {
                let fallbackEnd = nextStart ?? (words[i].startTime + 0.3)
                words[i] = TranscriptWord(
                    word: words[i].word,
                    startTime: words[i].startTime,
                    endTime: max(fallbackEnd, words[i].startTime + 0.01),
                    confidence: words[i].confidence
                )
            } else if let ns = nextStart, words[i].endTime > ns + 0.5 {
                words[i] = TranscriptWord(
                    word: words[i].word,
                    startTime: words[i].startTime,
                    endTime: ns,
                    confidence: words[i].confidence
                )
            }
        }

        captionLog("[ChirpClient] Final words: \(words.count)")
        for (i, w) in words.prefix(10).enumerated() {
            captionLog("[ChirpClient] word[\(i)]: '\(w.word)' \(round(w.startTime * 1000) / 1000)-\(round(w.endTime * 1000) / 1000)")
        }

        let maxEndTime = words.last.map { max($0.endTime, $0.startTime) } ?? 0

        return TranscriptData(
            words: words,
            fullText: fullTextParts.joined(separator: " "),
            durationSeconds: maxEndTime
        )
    }

    /// Parse a protobuf Duration value from JSON. Google returns these in three forms:
    /// 1. String: "9.400s"
    /// 2. Object: {"seconds": 9, "nanos": 400000000}
    /// 3. nil (field omitted, meaning 0)
    private func parseDurationValue(_ value: Any?) -> Double {
        guard let value else { return 0 }

        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "s"))
            return Double(trimmed) ?? 0
        }

        if let dict = value as? [String: Any] {
            let seconds = (dict["seconds"] as? Int).map(Double.init)
                ?? (dict["seconds"] as? Double)
                ?? 0
            let nanos = (dict["nanos"] as? Int).map(Double.init)
                ?? (dict["nanos"] as? Double)
                ?? 0
            return seconds + nanos / 1_000_000_000
        }

        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }

        return 0
    }

}

enum ChirpError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case unauthenticated
    case quotaExceeded(body: String)
    case apiError(statusCode: Int, body: String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid API endpoint"
        case .invalidResponse: "Invalid HTTP response"
        case .unauthenticated: "Not signed in. Run `reelabs-mcp sign-in` to connect this device."
        case .quotaExceeded(let body): "Quota exceeded: \(body)"
        case .apiError(let code, let body): "API error \(code): \(body)"
        case .parseError(let msg): "Parse error: \(msg)"
        }
    }
}
