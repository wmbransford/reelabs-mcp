import Foundation

/// Markdown + JSON sidecar storage for transcripts. For each transcript:
/// - `data/projects/{project}/{source}.transcript.md` — agent-readable utterance view
/// - `data/projects/{project}/{source}.words.json` — immutable word-level timestamps
package struct TranscriptStore: Sendable {
    let paths: DataPaths

    package init(paths: DataPaths) {
        self.paths = paths
    }

    /// Write a transcript (both markdown and words sidecar) atomically.
    ///
    /// `compactEntries` is the utterance-level list (same shape the agent sees in the tool response):
    /// either `{"start": Double, "end": Double, "text": String}` or `{"gap": Double}` objects.
    package func save(
        project: String,
        source: String,
        record: TranscriptRecord,
        compactEntries: [[String: Any]],
        words: [WordEntry]
    ) throws -> TranscriptRecord {
        let mdURL = paths.transcriptMarkdown(project: project, source: source)
        let wordsURL = paths.transcriptWords(project: project, source: source)

        let body = Self.formatBody(record: record, entries: compactEntries)
        let mdFile = MarkdownFile(frontMatter: record, body: body)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let wordsData = try encoder.encode(words)

        try MarkdownStore.writeAtomicPair(
            markdown: (url: mdURL, file: mdFile),
            sidecar: (url: wordsURL, data: wordsData)
        )

        return record
    }

    /// Load just the record metadata (from the markdown front matter).
    package func getRecord(project: String, source: String) throws -> TranscriptRecord? {
        let url = paths.transcriptMarkdown(project: project, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try MarkdownStore.read(at: url, as: TranscriptRecord.self).frontMatter
    }

    /// Load the full markdown body (utterance view) — what agents read.
    package func getMarkdown(project: String, source: String) throws -> MarkdownFile<TranscriptRecord>? {
        let url = paths.transcriptMarkdown(project: project, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try MarkdownStore.read(at: url, as: TranscriptRecord.self)
    }

    /// Load word-level timestamps from the sidecar JSON. The renderer uses this.
    package func getWords(project: String, source: String) throws -> [WordEntry] {
        let url = paths.transcriptWords(project: project, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([WordEntry].self, from: data)
    }

    /// Return the compact utterance list parsed out of the markdown body.
    /// Mirrors the `transcript` array returned by `reelabs_transcribe`.
    package func getCompactEntries(project: String, source: String) throws -> [[String: Any]] {
        let url = paths.transcriptMarkdown(project: project, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let loaded = try MarkdownStore.read(at: url, as: TranscriptRecord.self)
        return Self.parseBody(loaded.body)
    }

    /// List all transcripts across all projects. Returns tuples of (project, source, record).
    package func listAll() throws -> [(project: String, source: String, record: TranscriptRecord)] {
        guard FileManager.default.fileExists(atPath: paths.projectsDir.path) else { return [] }
        var out: [(String, String, TranscriptRecord)] = []
        let projectDirs = try FileManager.default.contentsOfDirectory(
            at: paths.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for pdir in projectDirs {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: pdir.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            let projectSlug = pdir.lastPathComponent
            let entries = try FileManager.default.contentsOfDirectory(at: pdir, includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent.hasSuffix(".transcript.md") {
                if let record = try? MarkdownStore.read(at: entry, as: TranscriptRecord.self).frontMatter {
                    let sourceSlug = entry.lastPathComponent
                        .replacingOccurrences(of: ".transcript.md", with: "")
                    out.append((projectSlug, sourceSlug, record))
                }
            }
        }
        out.sort { $0.2.created > $1.2.created }
        return out
    }

    /// Delete a transcript and its words sidecar.
    package func delete(project: String, source: String) throws -> Bool {
        let mdURL = paths.transcriptMarkdown(project: project, source: source)
        let wordsURL = paths.transcriptWords(project: project, source: source)
        let fm = FileManager.default
        var existed = false
        if fm.fileExists(atPath: mdURL.path) {
            try fm.removeItem(at: mdURL)
            existed = true
        }
        if fm.fileExists(atPath: wordsURL.path) {
            try fm.removeItem(at: wordsURL)
            existed = true
        }
        return existed
    }

    // MARK: - Body format

    /// Render the utterance list as markdown:
    /// ```
    /// # Transcript: {filename}
    ///
    /// - [0:08 – 0:11] Opus 4.7, is it just another model or not?
    /// ```
    static func formatBody(record: TranscriptRecord, entries: [[String: Any]]) -> String {
        let sourceName = URL(fileURLWithPath: record.sourcePath).lastPathComponent
        var lines: [String] = []
        lines.append("# Transcript: \(sourceName)")
        lines.append("")
        for entry in entries {
            if let start = entry["start"] as? Double,
               let end = entry["end"] as? Double,
               let text = entry["text"] as? String {
                lines.append("- [\(fmtTime(start)) – \(fmtTime(end))] \(text)")
            }
            // Gaps are intentionally skipped in the markdown body — they're implicit in the timestamps.
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parse the markdown body back into compact entries.
    /// Only parses utterance lines; gaps are reconstructed from the time deltas.
    static func parseBody(_ body: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var lastEnd: Double? = nil
        let lineRegex = try? NSRegularExpression(
            pattern: #"^-\s*\[(\d+):(\d{1,2}(?:\.\d+)?)\s*[–-]\s*(\d+):(\d{1,2}(?:\.\d+)?)\]\s*(.+)$"#,
            options: []
        )
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let re = lineRegex,
                  let match = re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)),
                  match.numberOfRanges == 6 else {
                continue
            }
            let ns = line as NSString
            let startMin = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let startSec = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let endMin = Double(ns.substring(with: match.range(at: 3))) ?? 0
            let endSec = Double(ns.substring(with: match.range(at: 4))) ?? 0
            let text = ns.substring(with: match.range(at: 5))

            let start = startMin * 60 + startSec
            let end = endMin * 60 + endSec

            if let prev = lastEnd, start - prev >= 0.4 {
                out.append(["gap": round((start - prev) * 10) / 10])
            }
            out.append(["start": start, "end": end, "text": text])
            lastEnd = end
        }
        return out
    }

    private static func fmtTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = seconds - Double(mins * 60)
        return String(format: "%d:%05.2f", mins, secs)
    }
}
