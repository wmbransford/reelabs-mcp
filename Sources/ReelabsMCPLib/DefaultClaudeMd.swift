import Foundation

package enum DefaultClaudeMd {
    /// Copy the bundled slim CLAUDE.md index to `{dataRoot}/CLAUDE.md`, overwriting any existing copy.
    /// The copy at the data root lets end-user agents find it via Grep without needing to load the repo's CLAUDE.md.
    package static func seed(dataRoot: URL) throws {
        guard let bundleResources = Bundle.module.resourceURL else { return }
        let source = bundleResources.appendingPathComponent("CLAUDE.md")
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let target = dataRoot.appendingPathComponent("CLAUDE.md")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }
}
