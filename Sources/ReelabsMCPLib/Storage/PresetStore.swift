import Foundation
import Yams

/// Markdown-backed preset storage. Presets live at `{dataRoot}/presets/{category}/{name}.md`,
/// with the preset's config fields flattened into YAML front matter.
///
/// Categories: `captions`, `framing`, `overlays`, `transitions`, `audio` (open-ended — new
/// categories are just new subfolders). Built-in presets are bundled in Resources and
/// seeded on startup; user-created presets live alongside them.
package struct PresetStore: Sendable {
    /// Lightweight summary used by `list` — avoids loading the full YAML when callers
    /// just want to enumerate what exists.
    package struct Summary: Codable, Sendable {
        package let category: String
        package let name: String
        package let description: String?

        package init(category: String, name: String, description: String?) {
            self.category = category
            self.name = name
            self.description = description
        }
    }

    let paths: DataPaths

    package init(paths: DataPaths) {
        self.paths = paths
    }

    // MARK: - Save

    /// Write a preset file at `{category}/{name}.md`. The frontmatter contains `category`,
    /// `name`, optional `description`, plus every key/value from `config`. Body is the
    /// description (or empty if none).
    package func save(
        category: String,
        name: String,
        config: [String: Any],
        description: String? = nil
    ) throws {
        let url = paths.presetCategoryDir(category).appendingPathComponent("\(name).md")

        var frontMatter: [String: Any] = [
            "category": category,
            "name": name
        ]
        if let description {
            frontMatter["description"] = description
        }
        for (k, v) in config {
            frontMatter[k] = v
        }

        let yamlString = try Yams.dump(object: frontMatter)
        let body = description ?? ""
        let bodyWithNewline = body.hasSuffix("\n") ? body : body + "\n"
        let contents = "---\n\(yamlString)---\n\n\(bodyWithNewline)"

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = contents.data(using: .utf8) else {
            throw NSError(
                domain: "PresetStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed for preset '\(category)/\(name)'"]
            )
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Read

    /// Read the raw YAML frontmatter of a preset. Returns nil if the file doesn't exist.
    package func getYAML(category: String, name: String) throws -> String? {
        let url = paths.presetCategoryDir(category).appendingPathComponent("\(name).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let (yaml, _) = try MarkdownStore.splitFrontMatter(contents, fileURL: url)
        return yaml
    }

    /// Read the full file contents (frontmatter + body). Useful when the agent wants to
    /// show a preset's documentation inline.
    package func getRaw(category: String, name: String) throws -> String? {
        let url = paths.presetCategoryDir(category).appendingPathComponent("\(name).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Decode a preset's frontmatter into a typed struct (e.g. `CaptionConfig`).
    /// Returns nil if the file doesn't exist.
    package func get<T: Decodable>(category: String, name: String, as type: T.Type) throws -> T? {
        guard let yaml = try getYAML(category: category, name: name) else { return nil }
        return try YAMLDecoder().decode(T.self, from: yaml)
    }

    // MARK: - List

    /// Enumerate presets in a category. If `category` is nil, enumerate every category.
    package func list(category: String? = nil) throws -> [Summary] {
        var out: [Summary] = []

        if let category {
            let dir = paths.presetCategoryDir(category)
            guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
            out = try readCategory(name: category, dir: dir)
        } else {
            guard FileManager.default.fileExists(atPath: paths.presetsDir.path) else { return [] }
            let entries = try FileManager.default.contentsOfDirectory(
                at: paths.presetsDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            for entry in entries {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                let categoryName = entry.lastPathComponent
                out.append(contentsOf: try readCategory(name: categoryName, dir: entry))
            }
        }

        out.sort { ($0.category, $0.name) < ($1.category, $1.name) }
        return out
    }

    private func readCategory(name: String, dir: URL) throws -> [Summary] {
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var out: [Summary] = []
        for entry in entries where entry.pathExtension == "md" {
            let presetName = entry.deletingPathExtension().lastPathComponent
            let description = (try? readDescription(at: entry)) ?? nil
            out.append(Summary(category: name, name: presetName, description: description))
        }
        return out
    }

    private func readDescription(at url: URL) throws -> String? {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let (yaml, _) = try MarkdownStore.splitFrontMatter(contents, fileURL: url)
        let decoded = try Yams.load(yaml: yaml) as? [String: Any]
        return decoded?["description"] as? String
    }

    // MARK: - Delete

    package func delete(category: String, name: String) throws -> Bool {
        let url = paths.presetCategoryDir(category).appendingPathComponent("\(name).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }
}
