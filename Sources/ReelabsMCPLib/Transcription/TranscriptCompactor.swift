import Foundation

/// Groups word-level transcript data into utterances separated by silence gaps.
/// Produces a compact JSON array for agent context instead of dumping every word.
enum TranscriptCompactor {
    /// Minimum silence between words (in seconds) to split into a new utterance.
    private static let gapThreshold: Double = 0.4

    /// Groups words into utterances separated by silence gaps >= 400ms.
    /// Returns an array of alternating utterance objects `{"start", "end", "text"}`
    /// and gap objects `{"gap": seconds}`.
    static func compact(words: [TranscriptWord]) -> [[String: Any]] {
        guard !words.isEmpty else { return [] }

        var result: [[String: Any]] = []
        var utteranceStart = words[0].startTime
        var utteranceWords: [String] = [words[0].word]
        var utteranceEnd = words[0].endTime

        for i in 1..<words.count {
            let gap = words[i].startTime - words[i - 1].endTime

            if gap >= gapThreshold {
                // Close current utterance
                result.append([
                    "start": round1(utteranceStart),
                    "end": round1(utteranceEnd),
                    "text": utteranceWords.joined(separator: " ")
                ])
                // Insert gap marker
                result.append(["gap": round1(gap)])
                // Start new utterance
                utteranceStart = words[i].startTime
                utteranceWords = [words[i].word]
            } else {
                utteranceWords.append(words[i].word)
            }
            utteranceEnd = words[i].endTime
        }

        // Close final utterance
        result.append([
            "start": round1(utteranceStart),
            "end": round1(utteranceEnd),
            "text": utteranceWords.joined(separator: " ")
        ])

        return result
    }

    /// Serialize compact array to a JSON string for database storage.
    static func compactJsonString(words: [TranscriptWord]) -> String {
        let compact = compact(words: words)
        guard let data = try? JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Round to 1 decimal place.
    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
