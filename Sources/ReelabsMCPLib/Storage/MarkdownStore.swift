import Foundation
import Yams

/// A parsed markdown file with typed YAML front matter.
package struct MarkdownFile<FrontMatter: Codable>: Sendable where FrontMatter: Sendable {
    package let frontMatter: FrontMatter
    package let body: String

    package init(frontMatter: FrontMatter, body: String) {
        self.frontMatter = frontMatter
        self.body = body
    }
}

/// Reads and writes markdown files with YAML front matter. All writes are atomic.
///
/// File layout:
/// ```
/// ---
/// <YAML front matter>
/// ---
///
/// <markdown body>
/// ```
///
/// The front matter is typed: provide any `Codable` struct that mirrors the YAML schema.
/// The body is an opaque string — tools that need structured data within the body (e.g.
/// the utterance list in a transcript) parse it themselves.
package enum MarkdownStore {
    package enum MarkdownError: LocalizedError {
        case missingFrontMatter(URL)
        case malformedFrontMatter(String)
        case missingFile(URL)
        case encodingFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingFrontMatter(let url):
                return "Markdown file has no YAML front matter: \(url.path)"
            case .malformedFrontMatter(let msg):
                return "Front matter parse error: \(msg)"
            case .missingFile(let url):
                return "File not found: \(url.path)"
            case .encodingFailed(let msg):
                return "Encoding failed: \(msg)"
            }
        }
    }

    // MARK: - Read

    /// Read a markdown file and decode its front matter into `T`.
    package static func read<T: Decodable>(at url: URL, as _: T.Type) throws -> MarkdownFile<T> where T: Sendable {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MarkdownError.missingFile(url)
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let (yaml, body) = try splitFrontMatter(contents, fileURL: url)
        let decoder = YAMLDecoder()
        let frontMatter: T
        do {
            frontMatter = try decoder.decode(T.self, from: yaml)
        } catch {
            throw MarkdownError.malformedFrontMatter("\(url.path): \(error)")
        }
        return MarkdownFile(frontMatter: frontMatter, body: body)
    }

    // MARK: - Write

    /// Write a markdown file with front matter atomically.
    package static func write<T: Encodable>(_ file: MarkdownFile<T>, to url: URL) throws where T: Sendable {
        let data = try encode(file)
        try writeAtomic(data, to: url)
    }

    /// Write raw data atomically. Useful for JSON sidecars.
    package static func writeData(_ data: Data, to url: URL) throws {
        try writeAtomic(data, to: url)
    }

    /// Read raw data from a file. Useful for JSON sidecars.
    package static func readData(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MarkdownError.missingFile(url)
        }
        return try Data(contentsOf: url)
    }

    /// Write a paired markdown file + sidecar data with best-effort atomicity.
    ///
    /// Both files are staged to temp paths; both are renamed on success. If either
    /// temp write fails, both temp files are cleaned up and no destination is touched.
    /// If the first rename succeeds but the second fails, the first is already committed —
    /// this weak guarantee is documented in MARKDOWN_MIGRATION.md. In practice the
    /// rename window is a few microseconds on local disk.
    package static func writeAtomicPair<T: Encodable>(
        markdown: (url: URL, file: MarkdownFile<T>),
        sidecar: (url: URL, data: Data)
    ) throws where T: Sendable {
        let mdData = try encode(markdown.file)

        try ensureDirectory(markdown.url.deletingLastPathComponent())
        try ensureDirectory(sidecar.url.deletingLastPathComponent())

        let mdTemp = tempSibling(of: markdown.url)
        let sidecarTemp = tempSibling(of: sidecar.url)

        do {
            try mdData.write(to: mdTemp)
            try sidecar.data.write(to: sidecarTemp)
        } catch {
            try? FileManager.default.removeItem(at: mdTemp)
            try? FileManager.default.removeItem(at: sidecarTemp)
            throw error
        }

        do {
            try replaceOrMove(from: mdTemp, to: markdown.url)
        } catch {
            try? FileManager.default.removeItem(at: mdTemp)
            try? FileManager.default.removeItem(at: sidecarTemp)
            throw error
        }

        do {
            try replaceOrMove(from: sidecarTemp, to: sidecar.url)
        } catch {
            try? FileManager.default.removeItem(at: sidecarTemp)
            throw error
        }
    }

    // MARK: - Helpers (internal for testing)

    static func splitFrontMatter(_ contents: String, fileURL: URL) throws -> (yaml: String, body: String) {
        let lines = contents.components(separatedBy: "\n")
        guard let first = lines.first, first == "---" else {
            throw MarkdownError.missingFrontMatter(fileURL)
        }

        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i] == "---" {
                closingIndex = i
                break
            }
        }
        guard let closing = closingIndex else {
            throw MarkdownError.missingFrontMatter(fileURL)
        }

        let yaml = lines[1..<closing].joined(separator: "\n")

        var bodyStart = closing + 1
        // Eat one optional blank line between front matter and body
        if bodyStart < lines.count && lines[bodyStart].isEmpty {
            bodyStart += 1
        }

        let body: String
        if bodyStart < lines.count {
            body = lines[bodyStart...].joined(separator: "\n")
        } else {
            body = ""
        }
        return (yaml, body)
    }

    private static func encode<T: Encodable>(_ file: MarkdownFile<T>) throws -> Data where T: Sendable {
        let encoder = YAMLEncoder()
        var yaml: String
        do {
            yaml = try encoder.encode(file.frontMatter)
        } catch {
            throw MarkdownError.malformedFrontMatter("encode failed: \(error)")
        }
        if !yaml.hasSuffix("\n") {
            yaml += "\n"
        }
        let bodyWithNewline = file.body.hasSuffix("\n") ? file.body : file.body + "\n"
        let contents = "---\n\(yaml)---\n\n\(bodyWithNewline)"
        guard let data = contents.data(using: .utf8) else {
            throw MarkdownError.encodingFailed("UTF-8 encoding failed")
        }
        return data
    }

    private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func tempSibling(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
    }

    private static func writeAtomic(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        // Foundation's .atomic writes to a temp sibling and renames on success — POSIX atomic.
        try data.write(to: url, options: .atomic)
    }

    private static func replaceOrMove(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }
}
