import Foundation

/// Markdown-backed project storage. One folder per project under `data/projects/{slug}/`
/// with a `project.md` at its root.
package struct ProjectStore: Sendable {
    let paths: DataPaths

    package init(paths: DataPaths) {
        self.paths = paths
    }

    /// Create a project. Slug is derived from the name.
    /// If a project with that slug already exists, returns the existing record (idempotent).
    package func create(name: String, description: String? = nil, tags: [String]? = nil) throws -> ProjectRecord {
        let baseSlug = SlugGenerator.slugify(name)
        let slug = SlugGenerator.uniqueSlug(base: baseSlug) { candidate in
            FileManager.default.fileExists(atPath: paths.projectDir(candidate).path)
        }
        return try createWithSlug(slug: slug, name: name, description: description, tags: tags)
    }

    /// Create a project with an explicit slug (used by auto-derivation from source paths).
    /// Returns the existing record if the slug already exists.
    package func createWithSlug(slug: String, name: String? = nil, description: String? = nil, tags: [String]? = nil) throws -> ProjectRecord {
        if let existing = try get(slug: slug) {
            return existing
        }
        let record = ProjectRecord(
            slug: slug,
            name: name ?? slug,
            description: description,
            tags: tags
        )
        try FileManager.default.createDirectory(
            at: paths.projectDir(slug),
            withIntermediateDirectories: true
        )
        let file = MarkdownFile(frontMatter: record, body: description ?? "")
        try MarkdownStore.write(file, to: paths.projectFile(slug))
        return record
    }

    package func get(slug: String) throws -> ProjectRecord? {
        let url = paths.projectFile(slug)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try MarkdownStore.read(at: url, as: ProjectRecord.self).frontMatter
    }

    package func list(status: String? = nil) throws -> [ProjectRecord] {
        guard FileManager.default.fileExists(atPath: paths.projectsDir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: paths.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var out: [ProjectRecord] = []
        for entry in entries {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            let projectMd = entry.appendingPathComponent("project.md")
            guard FileManager.default.fileExists(atPath: projectMd.path) else { continue }
            if let record = try? MarkdownStore.read(at: projectMd, as: ProjectRecord.self).frontMatter {
                if let status, record.status != status { continue }
                out.append(record)
            }
        }
        out.sort { $0.created > $1.created }
        return out
    }

    package func archive(slug: String) throws -> ProjectRecord? {
        let url = paths.projectFile(slug)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let loaded = try MarkdownStore.read(at: url, as: ProjectRecord.self)
        var updated = loaded.frontMatter
        updated.status = "archived"
        updated.updated = Timestamp.now()
        let file = MarkdownFile(frontMatter: updated, body: loaded.body)
        try MarkdownStore.write(file, to: url)
        return updated
    }

    package func delete(slug: String) throws -> Bool {
        let dir = paths.projectDir(slug)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        try FileManager.default.removeItem(at: dir)
        return true
    }
}
