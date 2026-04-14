import Foundation
import Security

/// Google Cloud Speech-to-Text v2 (Chirp) client using service account JWT auth.
/// Routes short audio (<= 60s) through the sync Recognize API and longer audio
/// through GCS upload + BatchRecognize.
final class ChirpClient: Sendable {
    let serviceAccount: ServiceAccount
    let location: String
    let model: String
    let gcsBucket: String

    init(serviceAccountPath: String, location: String = "us", model: String = "chirp_3", gcsBucket: String = "") throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: serviceAccountPath))
        self.serviceAccount = try JSONDecoder().decode(ServiceAccount.self, from: data)
        self.location = location
        self.model = model
        self.gcsBucket = gcsBucket
    }

    /// Main entry point. Routes to sync or batch based on duration.
    func transcribe(flacURL: URL, durationSeconds: Double, language: String = "en-US") async throws -> TranscriptData {
        let accessToken = try await getAccessToken()

        if durationSeconds <= 60 {
            return try await transcribeSync(flacURL: flacURL, accessToken: accessToken, language: language)
        } else {
            guard !gcsBucket.isEmpty else {
                throw ChirpError.parseError("Audio is over 1 minute. Set gcs_bucket in config.json for long audio transcription.")
            }
            let objectName = "transcription/\(UUID().uuidString).flac"
            let gcsURI = try await uploadToGCS(flacURL: flacURL, objectName: objectName, accessToken: accessToken)
            defer {
                Task { [gcsBucket, accessToken] in
                    try? await ChirpClient.deleteFromGCS(bucket: gcsBucket, objectName: objectName, accessToken: accessToken)
                }
            }
            return try await transcribeBatch(gcsURI: gcsURI, accessToken: accessToken, language: language)
        }
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
                    "enableWordTimeOffsets": true
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

    // MARK: - GCS Upload / Delete

    private func uploadToGCS(flacURL: URL, objectName: String, accessToken: String) async throws -> String {
        let audioData = try Data(contentsOf: flacURL)

        let encodedName = objectName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectName
        let endpoint = "https://storage.googleapis.com/upload/storage/v1/b/\(gcsBucket)/o?uploadType=media&name=\(encodedName)"
        guard let url = URL(string: endpoint) else {
            throw ChirpError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/flac", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("\(audioData.count)", forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 600
        request.httpBody = audioData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChirpError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ChirpError.apiError(statusCode: httpResponse.statusCode, body: "GCS upload failed (\(httpResponse.statusCode)): \(errorBody)")
        }

        return "gs://\(gcsBucket)/\(objectName)"
    }

    private static func deleteFromGCS(bucket: String, objectName: String, accessToken: String) async throws {
        let encodedName = objectName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectName
        let endpoint = "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encodedName)"
        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Batch Recognize (long audio via GCS)

    private func transcribeBatch(gcsURI: String, accessToken: String, language: String) async throws -> TranscriptData {
        let recognizer = "projects/\(serviceAccount.projectId)/locations/\(location)/recognizers/_"
        let endpoint = "https://\(location)-speech.googleapis.com/v2/\(recognizer):batchRecognize"
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
                    "enableWordTimeOffsets": true
                ],
                "autoDecodingConfig": [String: Any]()
            ],
            "files": [
                ["uri": gcsURI]
            ],
            "recognitionOutputConfig": [
                "inlineResponseConfig": [String: Any]()
            ]
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

        // Parse the operation response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operationName = json["name"] as? String else {
            throw ChirpError.parseError("No operation name in batch response")
        }

        // If already done (unlikely for batch), parse immediately
        if json["done"] as? Bool == true {
            return try parseBatchOperationResult(json, gcsURI: gcsURI)
        }

        // Poll for completion
        return try await pollOperation(name: operationName, accessToken: accessToken, gcsURI: gcsURI)
    }

    private func pollOperation(name: String, accessToken: String, gcsURI: String) async throws -> TranscriptData {
        let endpoint = "https://\(location)-speech.googleapis.com/v2/\(name)"
        guard let url = URL(string: endpoint) else {
            throw ChirpError.invalidEndpoint
        }

        var delay: Duration = .seconds(5)
        let maxAttempts = 120 // 10 minutes max with backoff

        for _ in 0..<maxAttempts {
            try await Task.sleep(for: delay)

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                throw ChirpError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: "Poll failed: \(errorBody)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChirpError.parseError("Invalid poll response")
            }

            if json["done"] as? Bool == true {
                // Check for error
                if let error = json["error"] as? [String: Any] {
                    let code = error["code"] as? Int ?? 0
                    let message = error["message"] as? String ?? "Unknown error"
                    throw ChirpError.apiError(statusCode: code, body: "Batch transcription failed: \(message)")
                }
                return try parseBatchOperationResult(json, gcsURI: gcsURI)
            }

            // Exponential backoff, cap at 15 seconds
            let nextDelay = Duration.seconds(delay.components.seconds * 3 / 2)
            delay = nextDelay < .seconds(15) ? nextDelay : .seconds(15)
        }

        throw ChirpError.parseError("Batch transcription timed out after polling")
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

    /// Parse a completed BatchRecognize operation result.
    private func parseBatchOperationResult(_ json: [String: Any], gcsURI: String) throws -> TranscriptData {
        guard let responseObj = json["response"] as? [String: Any],
              let resultsMap = responseObj["results"] as? [String: Any] else {
            throw ChirpError.parseError("No results in batch response")
        }

        // The results are keyed by the input GCS URI
        guard let fileResult = resultsMap[gcsURI] as? [String: Any],
              let transcript = fileResult["transcript"] as? [String: Any],
              let results = transcript["results"] as? [[String: Any]] else {
            // Try first key if exact URI match fails
            if let firstValue = resultsMap.values.first as? [String: Any],
               let transcript = firstValue["transcript"] as? [String: Any],
               let results = transcript["results"] as? [[String: Any]] {
                return parseResultsArray(results)
            }
            throw ChirpError.parseError("No transcript in batch results for \(gcsURI)")
        }

        return parseResultsArray(results)
    }

    /// Shared parser for the results array (same structure in both sync and batch).
    ///
    /// Chirp batch API splits long audio into chunks and may return result blocks
    /// with chunk-relative timestamps (resetting to 0) instead of absolute offsets.
    /// We detect this by checking if a block's first word startTime jumps backward
    /// relative to the running maximum startTime, and apply a cumulative offset.
    /// We track startTime (not endTime) because Chirp sometimes omits endOffset.
    private func parseResultsArray(_ results: [[String: Any]]) -> TranscriptData {
        var words: [TranscriptWord] = []
        var fullTextParts: [String] = []
        // Track the highest absolute startTime seen — more reliable than endTime
        // because Chirp sometimes omits endOffset or returns incorrect endTimes.
        var runningMaxStart: Double = 0

        for (blockIdx, result) in results.enumerated() {
            guard let alternatives = result["alternatives"] as? [[String: Any]],
                  let alternative = alternatives.first else { continue }

            if let transcript = alternative["transcript"] as? String {
                fullTextParts.append(transcript)
            }

            guard let wordInfos = alternative["words"] as? [[String: Any]], !wordInfos.isEmpty else { continue }

            // Parse raw timestamps for this block
            var blockWords: [(word: String, start: Double, end: Double, confidence: Double?)] = []
            for wordInfo in wordInfos {
                let word = wordInfo["word"] as? String ?? ""
                let startTime = parseDurationValue(wordInfo["startOffset"])
                let endTime = parseDurationValue(wordInfo["endOffset"])
                let confidence = wordInfo["confidence"] as? Double
                blockWords.append((word, startTime, endTime, confidence))
            }

            // Detect chunk-relative offsets: if the first word in this block starts
            // significantly before the running max startTime, this block's timestamps
            // are relative to a chunk boundary rather than absolute audio time.
            let blockFirstStart = blockWords[0].start
            var offset: Double = 0
            if blockIdx > 0 && blockFirstStart < runningMaxStart - 0.5 {
                offset = runningMaxStart
                captionLog("[ChirpClient] Block \(blockIdx): chunk-relative detected (firstStart=\(blockFirstStart), runningMaxStart=\(runningMaxStart)), applying offset=\(offset)")
            }

            for bw in blockWords {
                let adjustedStart = bw.start + offset
                let adjustedEnd = bw.end + offset
                words.append(TranscriptWord(
                    word: bw.word,
                    startTime: adjustedStart,
                    endTime: adjustedEnd,
                    confidence: bw.confidence
                ))
                if adjustedStart > runningMaxStart {
                    runningMaxStart = adjustedStart
                }
            }
        }

        // Fix invalid timestamps:
        // 1. endTime <= startTime (Chirp omitted endOffset, parsed as 0)
        // 2. endTime unreasonably far from startTime (chunk boundary artifacts)
        // Use next word's startTime as a natural boundary.
        for i in 0..<words.count {
            let nextStart = (i + 1 < words.count) ? words[i + 1].startTime : nil

            if words[i].endTime <= words[i].startTime {
                // Missing or zero endOffset — estimate from next word
                let fallbackEnd = nextStart ?? (words[i].startTime + 0.3)
                words[i] = TranscriptWord(
                    word: words[i].word,
                    startTime: words[i].startTime,
                    endTime: max(fallbackEnd, words[i].startTime + 0.01),
                    confidence: words[i].confidence
                )
            } else if let ns = nextStart, words[i].endTime > ns + 0.5 {
                // endTime extends well past the next word — clamp it
                words[i] = TranscriptWord(
                    word: words[i].word,
                    startTime: words[i].startTime,
                    endTime: ns,
                    confidence: words[i].confidence
                )
            }
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
