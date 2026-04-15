@preconcurrency import AVFoundation
import Foundation
import Security

/// Google Cloud Speech-to-Text v2 (Chirp) client using service account JWT auth.
/// All audio goes through the sync Recognize API — long audio is chunked into
/// ≤55s segments and transcribed in parallel.
final class ChirpClient: Sendable {
    let serviceAccount: ServiceAccount
    let location: String
    let model: String

    init(serviceAccountPath: String, location: String = "us", model: String = "chirp_3") throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: serviceAccountPath))
        self.serviceAccount = try JSONDecoder().decode(ServiceAccount.self, from: data)
        self.location = location
        self.model = model
    }

    /// Main entry point. All audio goes through the sync API — long audio is
    /// chunked into ≤55s segments and transcribed in parallel, avoiding the batch
    /// API's timestamp offset bugs entirely.
    func transcribe(flacURL: URL, durationSeconds: Double, language: String = "en-US") async throws -> TranscriptData {
        let accessToken = try await getAccessToken()

        if durationSeconds <= 55 {
            return try await transcribeSync(flacURL: flacURL, accessToken: accessToken, language: language)
        } else {
            return try await transcribeChunkedSync(
                flacURL: flacURL,
                durationSeconds: durationSeconds,
                accessToken: accessToken,
                language: language
            )
        }
    }

    // MARK: - Chunked Sync Transcription

    private let maxChunkSeconds = 55.0
    private let overlapSeconds = 5.0

    private func transcribeChunkedSync(
        flacURL: URL,
        durationSeconds: Double,
        accessToken: String,
        language: String
    ) async throws -> TranscriptData {
        let chunks = try splitAudio(flacURL: flacURL)
        defer {
            for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) }
        }

        captionLog("[ChirpClient] Split \(String(format: "%.1f", durationSeconds))s audio into \(chunks.count) chunks for parallel sync transcription")

        let results: [(offset: Double, transcript: TranscriptData)] = try await withThrowingTaskGroup(
            of: (index: Int, offset: Double, transcript: TranscriptData).self
        ) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let transcript = try await self.transcribeSync(
                        flacURL: chunk.url, accessToken: accessToken, language: language
                    )
                    return (index: index, offset: chunk.offsetSeconds, transcript: transcript)
                }
            }

            var collected: [(index: Int, offset: Double, transcript: TranscriptData)] = []
            for try await result in group {
                collected.append(result)
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

            // Skip tiny tail (<2s) — already covered by previous chunk's overlap
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

            for word in chunk.transcript.words {
                let absoluteStart = word.startTime + offset
                let absoluteEnd = word.endTime + offset

                // Skip words in overlap region already covered by previous chunk
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

            if let lastWord = chunk.transcript.words.last {
                prevChunkEndTime = lastWord.endTime + offset
            }
        }

        let fullText = allWords.map(\.word).joined(separator: " ")
        let durationSeconds = allWords.last.map { max($0.endTime, $0.startTime) } ?? 0

        return TranscriptData(words: allWords, fullText: fullText, durationSeconds: durationSeconds)
    }

    // MARK: - Sync Recognize (short audio, inline base64)

    private func transcribeSync(flacURL: URL, accessToken: String, language: String) async throws -> TranscriptData {
        let audioData = try Data(contentsOf: flacURL)
        let base64Audio = audioData.base64EncodedString()

        let recognizer = "projects/\(serviceAccount.projectId)/locations/\(location)/recognizers/_"
        let endpoint = "https://\(location)-speech.googleapis.com/v2/\(recognizer):recognize"
        guard let url = URL(string: endpoint) else {
            throw ChirpError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600

        let body: [String: Any] = [
            "config": [
                "languageCodes": [language],
                "model": model,
                "features": [
                    "enableWordTimeOffsets": true,
                    "enableAutomaticPunctuation": true
                ],
                "autoDecodingConfig": [String: Any]()
            ],
            "content": base64Audio
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChirpError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ChirpError.apiError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        return try parseSyncResponse(data: data)
    }

    // MARK: - OAuth2 JWT Auth

    private func getAccessToken() async throws -> String {
        let now = Date()
        let exp = now.addingTimeInterval(3600)

        let header = try base64url(JSONSerialization.data(withJSONObject: [
            "alg": "RS256",
            "typ": "JWT",
            "kid": serviceAccount.privateKeyId
        ]))

        let claims = try base64url(JSONSerialization.data(withJSONObject: [
            "iss": serviceAccount.clientEmail,
            "sub": serviceAccount.clientEmail,
            "aud": serviceAccount.tokenUri,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(exp.timeIntervalSince1970),
            "scope": "https://www.googleapis.com/auth/cloud-platform"
        ] as [String: Any]))

        let signingInput = "\(header).\(claims)"

        let signature = try signRS256(data: Data(signingInput.utf8), pemKey: serviceAccount.privateKey)
        let signatureB64 = base64url(signature)

        let jwt = "\(signingInput).\(signatureB64)"

        guard let tokenURL = URL(string: serviceAccount.tokenUri) else {
            throw ChirpError.invalidEndpoint
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw ChirpError.apiError(statusCode: 0, body: "Token exchange failed: \(body)")
        }

        return token
    }

    // MARK: - Crypto helpers

    private func signRS256(data: Data, pemKey: String) throws -> Data {
        let stripped = pemKey
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard let keyData = Data(base64Encoded: stripped) else {
            throw ChirpError.parseError("Invalid private key encoding")
        }

        let rsaKeyData = stripPKCS8Header(keyData)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: rsaKeyData.count * 8
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(rsaKeyData as CFData, attributes as CFDictionary, &error) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "Unknown"
            throw ChirpError.parseError("Failed to create private key: \(desc)")
        }

        guard let signedData = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "Unknown"
            throw ChirpError.parseError("Signing failed: \(desc)")
        }

        return signedData
    }

    private func stripPKCS8Header(_ keyData: Data) -> Data {
        guard keyData.count > 26 else { return keyData }

        var index = 0
        let bytes = [UInt8](keyData)

        guard bytes[index] == 0x30 else { return keyData }
        index += 1
        index = skipASN1Length(bytes, at: index)

        guard index < bytes.count, bytes[index] == 0x02 else { return keyData }
        index += 1
        let versionLen = Int(bytes[index])
        index += 1 + versionLen

        guard index < bytes.count, bytes[index] == 0x30 else { return keyData }
        index += 1
        let algLen = skipASN1LengthValue(bytes, at: index)
        index = algLen

        guard index < bytes.count, bytes[index] == 0x04 else { return keyData }
        index += 1
        index = skipASN1Length(bytes, at: index)

        return Data(bytes[index...])
    }

    private func skipASN1Length(_ bytes: [UInt8], at index: Int) -> Int {
        guard index < bytes.count else { return index }
        if bytes[index] & 0x80 == 0 {
            return index + 1
        }
        let numBytes = Int(bytes[index] & 0x7F)
        return index + 1 + numBytes
    }

    private func skipASN1LengthValue(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index
        guard i < bytes.count else { return i }
        let length: Int
        if bytes[i] & 0x80 == 0 {
            length = Int(bytes[i])
            i += 1
        } else {
            let numBytes = Int(bytes[i] & 0x7F)
            i += 1
            var len = 0
            for _ in 0..<numBytes {
                guard i < bytes.count else { return i }
                len = (len << 8) | Int(bytes[i])
                i += 1
            }
            length = len
        }
        return i + length
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Response parsing

    /// Parse sync Recognize API response.
    private func parseSyncResponse(data: Data) throws -> TranscriptData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw ChirpError.parseError("No results in response")
        }

        return parseResultsArray(results)
    }

    /// Parse the results array from a sync Recognize response.
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

        // String format: "9.400s"
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "s"))
            return Double(trimmed) ?? 0
        }

        // Object format: {"seconds": 9, "nanos": 400000000}
        if let dict = value as? [String: Any] {
            let seconds = (dict["seconds"] as? Int).map(Double.init)
                ?? (dict["seconds"] as? Double)
                ?? 0
            let nanos = (dict["nanos"] as? Int).map(Double.init)
                ?? (dict["nanos"] as? Double)
                ?? 0
            return seconds + nanos / 1_000_000_000
        }

        // Numeric (unlikely but safe)
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }

        return 0
    }

}

enum ChirpError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid API endpoint"
        case .invalidResponse: "Invalid HTTP response"
        case .apiError(let code, let body): "API error \(code): \(body)"
        case .parseError(let msg): "Parse error: \(msg)"
        }
    }
}
