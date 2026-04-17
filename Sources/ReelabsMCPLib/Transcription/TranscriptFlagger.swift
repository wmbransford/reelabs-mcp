import Foundation

/// Heuristic checks over a transcript to flag words and utterances that the agent
/// should review with the user before burning captions into a render.
///
/// Flags four categories:
///  - Short words (≤2 chars) that aren't common English short words
///  - Words with unusual character patterns (digits, repeated chars, weird symbols)
///  - Words adjacent to long silence gaps (>2s) — often misheard from audio bleed
///  - Near-duplicate utterances — strong signal of a retake the user may want to cut
package enum TranscriptFlagger {

    /// Words ≤2 characters that are safe to leave un-flagged.
    private static let commonShortWords: Set<String> = [
        "i", "a", "an", "is", "it", "be", "to", "in", "of", "on", "at",
        "by", "we", "he", "me", "my", "no", "so", "up", "us", "or", "if",
        "as", "do", "go", "oh", "ok", "hi", "yo", "ah", "um", "uh"
    ]

    /// Gaps larger than this (seconds) around a word raise suspicion of mis-transcription.
    private static let suspiciousGapSeconds: Double = 2.0

    /// Jaccard similarity threshold above which two utterances are flagged as near-duplicates.
    private static let nearDuplicateThreshold: Double = 0.7

    /// Minimum word count an utterance must have to be considered for near-duplicate check.
    private static let nearDuplicateMinWords: Int = 3

    /// Confidence below which a word is flagged.
    private static let lowConfidenceThreshold: Double = 0.5

    /// Result payload — two flat arrays of dictionaries, ready to drop into a JSON response.
    package struct FlaggerResult {
        package let flaggedWords: [[String: Any]]
        package let flaggedUtterances: [[String: Any]]
    }

    /// Run all checks and return the flagger result.
    /// - Parameter words: word-level transcript entries
    package static func flag(words: [WordEntry]) -> FlaggerResult {
        let flaggedWords = flagWords(words: words)
        let flaggedUtterances = flagUtterances(words: words)
        return FlaggerResult(flaggedWords: flaggedWords, flaggedUtterances: flaggedUtterances)
    }

    // MARK: - Word-level flags

    private static func flagWords(words: [WordEntry]) -> [[String: Any]] {
        guard !words.isEmpty else { return [] }
        var result: [[String: Any]] = []

        for (i, w) in words.enumerated() {
            guard let reason = wordReason(word: w, index: i, in: words) else { continue }
            let context = buildContext(around: i, in: words)
            result.append([
                "word": w.word,
                "start": round1(w.start),
                "end": round1(w.end),
                "reason": reason,
                "context": context
            ])
        }
        return result
    }

    private static func wordReason(word w: WordEntry, index i: Int, in words: [WordEntry]) -> String? {
        let lower = w.word.lowercased()

        // Rule 1: short alphabetic word that's not a common short word
        if w.word.count <= 2,
           w.word.range(of: "^[a-zA-Z]+$", options: .regularExpression) != nil,
           !commonShortWords.contains(lower) {
            return "unusually short word"
        }

        // Rule 2: unusual character patterns (letters + optional hyphen + optional apostrophe-suffix only)
        let normalPattern = "^[a-zA-Z]+(-[a-zA-Z]+)*('[a-zA-Z]+)?$"
        if w.word.range(of: normalPattern, options: .regularExpression) == nil {
            return "unusual character pattern"
        }

        // Rule 3: adjacent to long silence
        let gapBefore = i > 0 ? (w.start - words[i - 1].end) : 0
        let gapAfter = i < words.count - 1 ? (words[i + 1].start - w.end) : 0
        if gapBefore > suspiciousGapSeconds || gapAfter > suspiciousGapSeconds {
            return "adjacent to long silence gap"
        }

        // Rule 4: low confidence
        if let c = w.confidence, c < lowConfidenceThreshold {
            return "low confidence (\(Int(c * 100))%)"
        }

        return nil
    }

    private static func buildContext(around i: Int, in words: [WordEntry]) -> String {
        let startIdx = max(0, i - 3)
        let endIdx = min(words.count, i + 4)
        var parts: [String] = []
        for j in startIdx..<endIdx {
            parts.append(j == i ? "[\(words[j].word)]" : words[j].word)
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Utterance-level flags (near-duplicates = likely retakes)

    private static func flagUtterances(words: [WordEntry]) -> [[String: Any]] {
        let utterances = buildUtterances(from: words)
        guard utterances.count >= 2 else { return [] }

        var result: [[String: Any]] = []
        var flaggedIndices: Set<Int> = []

        for i in 0..<utterances.count {
            for j in (i + 1)..<utterances.count {
                if flaggedIndices.contains(j) { continue }
                let a = utterances[i]
                let b = utterances[j]

                if a.words.count < nearDuplicateMinWords || b.words.count < nearDuplicateMinWords {
                    continue
                }
                let lenRatio = Double(min(a.words.count, b.words.count)) / Double(max(a.words.count, b.words.count))
                if lenRatio < 0.5 { continue }

                let similarity = jaccardSimilarity(a.words, b.words)
                if similarity >= nearDuplicateThreshold {
                    result.append([
                        "text": b.text,
                        "start": round1(b.start),
                        "end": round1(b.end),
                        "reason": "near-duplicate of earlier utterance (\(Int(similarity * 100))% match) — possible retake",
                        "duplicate_of": [
                            "text": a.text,
                            "start": round1(a.start),
                            "end": round1(a.end)
                        ]
                    ])
                    flaggedIndices.insert(j)
                    break
                }
            }
        }
        return result
    }

    private struct Utterance {
        let text: String
        let start: Double
        let end: Double
        let words: [String]
    }

    private static func buildUtterances(from words: [WordEntry]) -> [Utterance] {
        guard !words.isEmpty else { return [] }
        var result: [Utterance] = []
        var startTime = words[0].start
        var currentWords: [String] = [words[0].word]
        var endTime = words[0].end

        for i in 1..<words.count {
            let gap = words[i].start - words[i - 1].end
            if gap >= 0.4 {
                result.append(Utterance(
                    text: currentWords.joined(separator: " "),
                    start: startTime,
                    end: endTime,
                    words: currentWords
                ))
                startTime = words[i].start
                currentWords = [words[i].word]
            } else {
                currentWords.append(words[i].word)
            }
            endTime = words[i].end
        }
        result.append(Utterance(
            text: currentWords.joined(separator: " "),
            start: startTime,
            end: endTime,
            words: currentWords
        ))
        return result
    }

    private static func jaccardSimilarity(_ a: [String], _ b: [String]) -> Double {
        let setA = Set(a.map { $0.lowercased() })
        let setB = Set(b.map { $0.lowercased() })
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
