import AVFoundation
import Foundation
import MCP

enum TranscribeTool {
    static let tool = Tool(
        name: "reelabs_transcribe",
        description: "Transcribe a video/audio file using Google Cloud Speech-to-Text (Chirp). Returns word-level timestamps. Stores result in database for caption rendering and search. Short audio (<= 60s) uses sync API; longer audio uploads to GCS and uses batch API.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to video or audio file")
                ]),
                "asset_id": .object([
                    "type": .string("integer"),
                    "description": .string("Optional asset ID to link transcript to")
                ]),
                "language": .object([
                    "type": .string("string"),
                    "description": .string("Language code (default: en-US)")
                ])
            ]),
            "required": .array([.string("path")])
        ])
    )

    static func handle(arguments: [String: Value]?, transcriptRepo: TranscriptRepository, config: ServerConfig) async -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: path", annotations: nil, _meta: nil)], isError: true)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .init(content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)], isError: true)
        }

        let assetId = extractInt64(arguments?["asset_id"])
        let language = arguments?["language"]?.stringValue ?? "en-US"

        do {
            // Get duration to determine sync vs batch
            let videoURL = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: videoURL)
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)

            // Extract audio to FLAC
            let flacURL = try await AudioExtractor.extractAudio(from: videoURL)
            defer { try? FileManager.default.removeItem(at: flacURL) }

            // Transcribe with Chirp
            guard let saPath = config.serviceAccountPath else {
                return .init(content: [.text(text: "Transcription requires service_account_path in config.json", annotations: nil, _meta: nil)], isError: true)
            }
            let client = try ChirpClient(
                serviceAccountPath: saPath,
                location: config.chirpLocation,
                model: config.chirpModel,
                gcsBucket: config.gcsBucket
            )
            let transcriptData = try await client.transcribe(
                flacURL: flacURL,
                durationSeconds: durationSeconds,
                language: language
            )

            // Build compact transcript for agent context
            let compactArray = TranscriptCompactor.compact(words: transcriptData.words)
            let compactJsonString = TranscriptCompactor.compactJsonString(words: transcriptData.words)

            // Store in database — transcript metadata + words as structured rows
            var transcript = Transcript(
                sourcePath: path,
                fullText: transcriptData.fullText,
                compactJson: compactJsonString,
                durationSeconds: transcriptData.durationSeconds,
                wordCount: transcriptData.words.count,
                assetId: assetId
            )
            transcript = try transcriptRepo.createWithWords(transcript, words: transcriptData.words)

            // Return compact transcript — utterances grouped by silence gaps
            let mode = durationSeconds <= 60 ? "sync" : "batch (GCS)"
            let response: [String: Any] = [
                "transcript_id": transcript.id ?? 0,
                "word_count": transcriptData.words.count,
                "duration_seconds": round(transcriptData.durationSeconds * 100) / 100,
                "transcript": compactArray,
                "source_path": path,
                "mode": mode
            ]
            let responseData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: responseData, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Transcription failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
