import Foundation

/// Markdown-backed preset storage. One file per preset at `data/presets/{name}.md`.
package struct PresetStore: Sendable {
    let paths: DataPaths

    package init(paths: DataPaths) {
        self.paths = paths
    }

    package func save(name: String, type: String, configJson: String, description: String? = nil) throws -> PresetRecord {
        let url = paths.presetFile(name)

        // If the preset exists, preserve created timestamp and update in place.
        var created = Timestamp.now()
        if let existing = try? MarkdownStore.read(at: url, as: PresetRecord.self) {
            created = existing.frontMatter.created
        }

        let record = PresetRecord(
            name: name,
            type: type,
            configJson: configJson,
            description: description,
            created: created,
            updated: Timestamp.now()
        )

        let body = description ?? ""
        let file = MarkdownFile(frontMatter: record, body: body)
        try MarkdownStore.write(file, to: url)
        return record
    }

    package func get(name: String) throws -> PresetRecord? {
        let url = paths.presetFile(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let loaded = try MarkdownStore.read(at: url, as: PresetRecord.self)
        return loaded.frontMatter
    }

    package func list(type: String? = nil) throws -> [PresetRecord] {
        guard FileManager.default.fileExists(atPath: paths.presetsDir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: paths.presetsDir,
            includingPropertiesForKeys: nil
        )
        var out: [PresetRecord] = []
        for entry in entries where entry.pathExtension == "md" {
            if let loaded = try? MarkdownStore.read(at: entry, as: PresetRecord.self) {
                if let type, loaded.frontMatter.type != type { continue }
                out.append(loaded.frontMatter)
            }
        }
        out.sort { $0.name < $1.name }
        return out
    }

    package func delete(name: String) throws -> Bool {
        let url = paths.presetFile(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }
}
