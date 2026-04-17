import Foundation

/// Resolves all filesystem paths used by the markdown-backed data store.
///
/// `root` is the data root — either `$REELABS_DATA_DIR` (dev) or
/// `~/Library/Application Support/ReelabsMCP/` (Homebrew install).
/// Passed into every Store at init time so tests can use an isolated directory.
package struct DataPaths: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    /// Resolve a path that may contain `~` into an absolute URL.
    package init(rootPath: String) {
        self.root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath)
    }

    // MARK: - Top-level directories

    package var projectsDir: URL { root.appendingPathComponent("projects", isDirectory: true) }
    package var presetsDir: URL { root.appendingPathComponent("presets", isDirectory: true) }
    package var flowsDir: URL { root.appendingPathComponent("flows", isDirectory: true) }
    package var referenceDir: URL { root.appendingPathComponent("reference", isDirectory: true) }
    package var mediaDir: URL { root.appendingPathComponent("Media", isDirectory: true) }
    package var framesDir: URL { mediaDir.appendingPathComponent("Frames", isDirectory: true) }
    package var graphicsDir: URL { mediaDir.appendingPathComponent("Graphics", isDirectory: true) }

    /// Subfolder for a given preset category (`captions`, `framing`, `overlays`, `transitions`, `audio`).
    /// Legacy flat caption presets still live directly in `presetsDir` — only new categories use subdirs.
    package func presetCategoryDir(_ category: String) -> URL {
        presetsDir.appendingPathComponent(category, isDirectory: true)
    }

    // MARK: - Project-scoped paths

    package func projectDir(_ slug: String) -> URL {
        projectsDir.appendingPathComponent(slug, isDirectory: true)
    }

    package func projectFile(_ slug: String) -> URL {
        projectDir(slug).appendingPathComponent("project.md")
    }

    package func assetFile(project: String, source: String) -> URL {
        projectDir(project).appendingPathComponent("\(source).asset.md")
    }

    package func transcriptMarkdown(project: String, source: String) -> URL {
        projectDir(project).appendingPathComponent("\(source).transcript.md")
    }

    package func transcriptWords(project: String, source: String) -> URL {
        projectDir(project).appendingPathComponent("\(source).words.json")
    }

    package func analysisMarkdown(project: String, source: String) -> URL {
        projectDir(project).appendingPathComponent("\(source).analysis.md")
    }

    package func analysisScenes(project: String, source: String) -> URL {
        projectDir(project).appendingPathComponent("\(source).scenes.json")
    }

    package func renderFile(project: String, render: String) -> URL {
        projectDir(project).appendingPathComponent("\(render).render.md")
    }

    // MARK: - Preset paths

    package func presetFile(_ name: String) -> URL {
        presetsDir.appendingPathComponent("\(name).md")
    }

    // MARK: - Utilities

    /// Derive a project slug from a source-file path: take the parent dir name and slugify.
    /// Example: `/Users/w/Desktop/April 16th Youtube Video/C0048.MP4` → `april-16th-youtube-video`.
    package static func deriveProjectSlug(fromSourcePath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return SlugGenerator.slugify(parentName)
    }

    /// Derive a source slug from a source-file path: strip extension and slugify.
    /// Example: `C0048.MP4` → `c0048`.
    package static func deriveSourceSlug(fromSourcePath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return SlugGenerator.slugify(url.deletingPathExtension().lastPathComponent)
    }

    /// Parse a compound "project/source" identifier into its two parts.
    /// Returns nil if the input has no `/`.
    package static func splitCompoundId(_ id: String) -> (project: String, source: String)? {
        let parts = id.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}
