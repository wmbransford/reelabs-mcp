import Foundation

package enum DefaultReference {
    /// Copy every bundled reference file into `referenceDir`, overwriting existing copies.
    /// User-edited reference files are overwritten on every startup — reference docs are canonical and read-only in practice.
    package static func seed(referenceDir: URL) throws {
        try FileManager.default.createDirectory(
            at: referenceDir, withIntermediateDirectories: true
        )

        guard let bundleResources = Bundle.module.resourceURL else { return }
        let bundledDir = bundleResources.appendingPathComponent("reference", isDirectory: true)

        guard FileManager.default.fileExists(atPath: bundledDir.path) else { return }

        let bundledFiles = try FileManager.default.contentsOfDirectory(
            at: bundledDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for sourceURL in bundledFiles {
            let target = referenceDir.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: sourceURL, to: target)
        }
    }
}
