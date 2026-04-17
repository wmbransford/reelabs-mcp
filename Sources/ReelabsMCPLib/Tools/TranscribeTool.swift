import AVFoundation
import Foundation
import MCP

package enum TranscribeTool {
    package static let tool = Tool(
        name: "reelabs_transcribe",
        description: "Transcribe a video/audio file using Google Cloud Speech-to-Text (Chirp). Returns word-level timestamps grouped by silence gaps. Writes transcript.md + words.json into the project folder. If `project` is omitted, derives one from the source file's parent directory.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to video or audio file")
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string("Optional project slug. If omitted, derived from the source file's parent directory.")
                ]),
                "language": .object([
                    "type": .string("string"),
                    "description": .string("Language code (default: en-US)")
                ])
            ]),
            "required": .array([.string("path")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        transcriptStore: TranscriptStore,
        projectStore: ProjectStore,
        config: ServerConfig
    ) async -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: path", annotations: nil, _meta: nil)], isError: true)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .init(content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)], isError: true)
        }

        let language = arguments?["language"]?.stringValue ?? "en-US"

        // Resolve project: explicit arg or derive from parent dir
        let projectSlug: String
        if let explicit = arguments?["project"]?.stringValue {
            projectSlug = explicit
        } else {
            projectSlug = DataPaths.deriveProjectSlug(fromSourcePath: path)
        }
        let sourceSlug = DataPaths.deriveSourceSlug(fromSourcePath: path)

        do {
            // Ensure project exists
            _ = try projectStore.createWithSlug(slug: projectSlug)

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
                model: config.chirpModel
            )
            let transcriptData = try await client.transcribe(
                flacURL: flacURL,
                durationSeconds: durationSeconds,
                language: language
            )

            // Build compact transcript for agent context
            let compactArray = TranscriptCompactor.compact(words: transcriptData.words)

            // Build WordEntry sidecar payload
            let wordEntries: [WordEntry] = transcriptData.words.map { w in
                WordEntry(
                    word: w.word,
                    start: w.startTime,
                    end: w.endTime,
                    confidence: w.confidence
                )
            }

            let mode = durationSeconds <= 55 ? "sync" : "chunked-sync (\(Int(ceil(durationSeconds / 50))) chunks)"
            let record = TranscriptRecord(
                slug: sourceSlug,
                sourcePath: path,
                durationSeconds: transcriptData.durationSeconds,
                wordCount: transcriptData.words.count,
                language: language,
                mode: mode
            )

            _ = try transcriptStore.save(
                project: projectSlug,
                source: sourceSlug,
                record: record,
                compactEntries: compactArray,
                words: wordEntries
            )

            // Run the verification flagger over word-level timestamps so the agent can
            // review misheard words and probable retakes before burning captions.
            let flags = TranscriptFlagger.flag(words: wordEntries)

            // Return the markdown utterance view inline — same shape written to disk.
            // Markdown is roughly half the size of the JSON array form and easier to scan.
            let transcriptMarkdown = TranscriptStore.formatBody(record: record, entries: compactArray)
            let transcriptId = "\(projectSlug)/\(sourceSlug)"
            let response: [String: Any] = [
                "transcript_id": transcriptId,
                "project": projectSlug,
                "source": sourceSlug,
                "word_count": transcriptData.words.count,
                "duration_seconds": round(transcriptData.durationSeconds * 100) / 100,
                "transcript_markdown": transcriptMarkdown,
                "source_path": path,
                "mode": mode,
                "flagged_words": flags.flaggedWords,
                "flagged_utterances": flags.flaggedUtterances
            ]
            let responseData = try safeJSONData(from: response)
            let text = String(data: responseData, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Transcription failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
