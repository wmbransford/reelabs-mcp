import Foundation
import GRDB

/// SQLite-backed transcript storage. Each transcript lives in two tables:
///   - `transcripts`: one row per `(project_slug, source_slug)` with metadata + full_text.
///   - `transcript_words`: one row per word, ordered by `word_index`.
///
/// FTS5 index `transcripts_fts` is maintained automatically by triggers declared in
/// `001_init.sql` — touching `transcripts.full_text` keeps it in sync.
package struct TranscriptStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// Insert or update a transcript plus all of its words in a single transaction.
    /// On conflict `(project_slug, source_slug)` the row is updated and every word
    /// is re-inserted (stale rows are deleted first to keep re-saves simple).
    @discardableResult
    package func save(
        project: String,
        source: String,
        sourcePath: String,
        words: [WordEntry],
        fullText: String,
        durationSeconds: Double,
        language: String = "en-US",
        mode: String = "sync"
    ) throws -> TranscriptRecord {
        let now = Timestamp.now()
        let record = TranscriptRecord(
            slug: "\(project)/\(source)",
            sourcePath: sourcePath,
            durationSeconds: durationSeconds,
            wordCount: words.count,
            language: language,
            mode: mode,
            created: now
        )

        try database.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO transcripts (project_slug, source_slug, source_path, duration_seconds,
                    word_count, language, mode, full_text, created)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_slug, source_slug) DO UPDATE SET
                    source_path = excluded.source_path,
                    duration_seconds = excluded.duration_seconds,
                    word_count = excluded.word_count,
                    language = excluded.language,
                    mode = excluded.mode,
                    full_text = excluded.full_text,
                    created = excluded.created
            """, arguments: [
                project, source, sourcePath, durationSeconds,
                words.count, language, mode, fullText, now
            ])

            try conn.execute(
                sql: "DELETE FROM transcript_words WHERE project_slug = ? AND source_slug = ?",
                arguments: [project, source]
            )

            for (i, w) in words.enumerated() {
                try conn.execute(sql: """
                    INSERT INTO transcript_words (project_slug, source_slug, word_index, word, start_time, end_time, confidence)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [project, source, i, w.word, w.start, w.end, w.confidence])
            }
        }
        return record
    }

    package func get(project: String, source: String) throws -> TranscriptRecord? {
        try database.pool.read { conn in
            try TranscriptRecord.fetchOne(conn, sql: """
                SELECT project_slug, source_slug, source_path, duration_seconds,
                       word_count, language, mode, created
                FROM transcripts WHERE project_slug = ? AND source_slug = ?
            """, arguments: [project, source])
        }
    }

    package func getWords(project: String, source: String) throws -> [WordEntry] {
        try database.pool.read { conn in
            try WordEntry.fetchAll(conn, sql: """
                SELECT word, start_time AS start, end_time AS end, confidence
                FROM transcript_words
                WHERE project_slug = ? AND source_slug = ?
                ORDER BY word_index
            """, arguments: [project, source])
        }
    }

    package func list(project: String) throws -> [TranscriptRecord] {
        try database.pool.read { conn in
            try TranscriptRecord.fetchAll(conn, sql: """
                SELECT project_slug, source_slug, source_path, duration_seconds,
                       word_count, language, mode, created
                FROM transcripts WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    /// FTS5 search — returns matching `source_slug` values within the given project,
    /// ordered by BM25 rank (best match first).
    package func fullTextSearch(project: String, query: String) throws -> [String] {
        try database.pool.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT source_slug FROM transcripts_fts
                WHERE transcripts_fts MATCH ? AND project_slug = ?
                ORDER BY rank
            """, arguments: [query, project])
        }
    }

    @discardableResult
    package func delete(project: String, source: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(
                sql: "DELETE FROM transcripts WHERE project_slug = ? AND source_slug = ?",
                arguments: [project, source]
            )
            return conn.changesCount > 0
        }
    }

    // MARK: - Cross-project queries + markdown views (used by Tools)

    /// List across all projects. Returns `(project, source, record)` tuples,
    /// newest first — matches the old markdown-directory-walk behavior.
    package func listAll() throws -> [(project: String, source: String, record: TranscriptRecord)] {
        try database.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT project_slug, source_slug, source_path, duration_seconds,
                       word_count, language, mode, created
                FROM transcripts ORDER BY created DESC
            """)
            return try rows.map { row in
                let record = try TranscriptRecord(row: row)
                return (row["project_slug"] as String, row["source_slug"] as String, record)
            }
        }
    }

    /// "Compact utterance" view — rebuilt on the fly from the word rows so
    /// SilenceRemoveTool / TranscriptTool can operate without the old
    /// `.transcript.md` body on disk.
    package func getCompactEntries(project: String, source: String) throws -> [[String: Any]] {
        let words = try getWords(project: project, source: source)
        let transcriptWords = words.map { w in
            TranscriptWord(word: w.word, startTime: w.start, endTime: w.end, confidence: w.confidence)
        }
        return TranscriptCompactor.compact(words: transcriptWords)
    }

    /// Markdown view — synthesizes a `MarkdownFile<TranscriptRecord>` from DB
    /// contents (front matter from the row, body from the compact view) so
    /// `reelabs_transcript get` can return a human-readable transcript.
    /// Returns nil if the transcript doesn't exist.
    package func getMarkdown(project: String, source: String) throws -> MarkdownFile<TranscriptRecord>? {
        guard let record = try get(project: project, source: source) else { return nil }
        let entries = try getCompactEntries(project: project, source: source)
        let body = Self.formatBody(record: record, entries: entries)
        return MarkdownFile(frontMatter: record, body: body)
    }

    // MARK: - Body format (pure helpers — kept as static for external callers)

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

    /// Parse a formatted markdown body back into compact entries.
    /// Left public for legacy callers that still parse `.transcript.md` files on disk.
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

// MARK: - GRDB row decoding

extension TranscriptRecord: FetchableRecord {
    package init(row: Row) throws {
        // Rows come from queries that SELECT project_slug + source_slug explicitly;
        // combine them into the compound slug the rest of the codebase expects.
        let project: String = row["project_slug"]
        let source: String = row["source_slug"]
        self.init(
            slug: "\(project)/\(source)",
            sourcePath: row["source_path"],
            durationSeconds: row["duration_seconds"],
            wordCount: row["word_count"],
            language: row["language"],
            mode: row["mode"],
            created: row["created"]
        )
    }
}

extension WordEntry: FetchableRecord {
    package init(row: Row) throws {
        self.init(
            word: row["word"],
            start: row["start"],
            end: row["end"],
            confidence: row["confidence"]
        )
    }
}
