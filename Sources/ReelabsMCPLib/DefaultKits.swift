import Foundation

package enum DefaultKits {
    /// Copy every bundled kit file into `kitsDir`, overwriting existing copies.
    /// User-created kit files (anything not in the bundle) are left alone.
    package static func seed(kitsDir: URL) throws {
        try FileManager.default.createDirectory(
            at: kitsDir, withIntermediateDirectories: true
        )

        guard let bundleResources = Bundle.module.resourceURL else { return }
        let bundledDir = bundleResources.appendingPathComponent("kits", isDirectory: true)

        guard FileManager.default.fileExists(atPath: bundledDir.path) else { return }

        let bundledFiles = try FileManager.default.contentsOfDirectory(
            at: bundledDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for sourceURL in bundledFiles {
            let target = kitsDir.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: sourceURL, to: target)
        }
    }
}
