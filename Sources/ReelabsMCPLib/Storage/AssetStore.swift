import Foundation

/// Markdown-backed asset storage. One file per asset at
/// `{dataRoot}/projects/{project}/{source}.asset.md`.
package struct AssetStore: Sendable {
    let paths: DataPaths

    package init(paths: DataPaths) {
        self.paths = paths
    }

    package func upsert(project: String, source: String, record: AssetRecord) throws -> AssetRecord {
        let url = paths.assetFile(project: project, source: source)
        // Preserve created timestamp on update
        var toWrite = record
        if let existing = try? MarkdownStore.read(at: url, as: AssetRecord.self) {
            toWrite.created = existing.frontMatter.created
        }
        let file = MarkdownFile(frontMatter: toWrite, body: "")
        try MarkdownStore.write(file, to: url)
        return toWrite
    }

    package func get(project: String, source: String) throws -> AssetRecord? {
        let url = paths.assetFile(project: project, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try MarkdownStore.read(at: url, as: AssetRecord.self).frontMatter
    }

    package func list(project: String) throws -> [AssetRecord] {
        let dir = paths.projectDir(project)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var out: [AssetRecord] = []
        for entry in entries where entry.lastPathComponent.hasSuffix(".asset.md") {
            if let record = try? MarkdownStore.read(at: entry, as: AssetRecord.self).frontMatter {
                out.append(record)
            }
        }
        out.sort { $0.created > $1.created }
        return out
    }

    package func updateTags(project: String, source: String, tags: [String]) throws -> AssetRecord? {
        guard var record = try get(project: project, source: source) else { return nil }
        record.tags = tags.isEmpty ? nil : tags
        let file = MarkdownFile(frontMatter: record, body: "")
        try MarkdownStore.write(file, to: paths.assetFile(project: project, source: source))
        return record
    }

    package func delete(project: String, source: String) throws -> Bool {
        let url = paths.assetFile(project: project, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }
}
