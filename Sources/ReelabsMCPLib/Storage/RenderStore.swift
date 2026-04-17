import Foundation

/// Markdown-backed render storage. One file per render at
/// `{dataRoot}/projects/{project}/{render}.render.md`.
/// The full RenderSpec is embedded as a fenced ```json block inside the markdown body
/// so `reelabs_rerender` can rehydrate and re-run it.
package struct RenderStore: Sendable {
    let paths: DataPaths

    package init(paths: DataPaths) {
        self.paths = paths
    }

    /// Save a render record with its spec JSON embedded in the body.
    /// Returns the final slug used (handles collisions).
    @discardableResult
    package func save(
        project: String,
        baseSlug: String,
        record: RenderRecord,
        specJson: String,
        notes: String? = nil
    ) throws -> (slug: String, record: RenderRecord) {
        // Ensure project directory exists
        try FileManager.default.createDirectory(
            at: paths.projectDir(project),
            withIntermediateDirectories: true
        )

        let slug = SlugGenerator.uniqueSlug(base: baseSlug) { candidate in
            FileManager.default.fileExists(atPath: paths.renderFile(project: project, render: candidate).path)
        }

        var finalRecord = record
        finalRecord.slug = slug

        let body = Self.formatBody(record: finalRecord, specJson: specJson, notes: notes)
        let file = MarkdownFile(frontMatter: finalRecord, body: body)
        try MarkdownStore.write(file, to: paths.renderFile(project: project, render: slug))
        return (slug, finalRecord)
    }

    package func get(project: String, render: String) throws -> (record: RenderRecord, specJson: String?, body: String)? {
        let url = paths.renderFile(project: project, render: render)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let loaded = try MarkdownStore.read(at: url, as: RenderRecord.self)
        let spec = Self.extractSpecJson(from: loaded.body)
        return (loaded.frontMatter, spec, loaded.body)
    }

    package func list(project: String? = nil, limit: Int = 50) throws -> [(project: String, render: RenderRecord)] {
        guard FileManager.default.fileExists(atPath: paths.projectsDir.path) else { return [] }
        var out: [(String, RenderRecord)] = []
        let projectDirs = try FileManager.default.contentsOfDirectory(
            at: paths.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for pdir in projectDirs {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: pdir.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            let projectSlug = pdir.lastPathComponent
            if let project, projectSlug != project { continue }
            let entries = try FileManager.default.contentsOfDirectory(at: pdir, includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent.hasSuffix(".render.md") {
                if let record = try? MarkdownStore.read(at: entry, as: RenderRecord.self).frontMatter {
                    out.append((projectSlug, record))
                }
            }
        }
        out.sort { $0.1.created > $1.1.created }
        if out.count > limit {
            out = Array(out.prefix(limit))
        }
        return out
    }

    // MARK: - Body rendering

    static func formatBody(record: RenderRecord, specJson: String, notes: String?) -> String {
        var lines: [String] = []
        lines.append("# Render: \(record.slug)")
        lines.append("")
        lines.append("## RenderSpec")
        lines.append("")
        lines.append("```json")
        lines.append(specJson)
        lines.append("```")
        if let notes, !notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Extract the first fenced ```json ... ``` block from the body.
    static func extractSpecJson(from body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var inBlock = false
        var capturing: [String] = []
        for line in lines {
            if !inBlock {
                if line.trimmingCharacters(in: .whitespaces) == "```json" {
                    inBlock = true
                }
            } else {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    return capturing.joined(separator: "\n")
                }
                capturing.append(line)
            }
        }
        return nil
    }
}
