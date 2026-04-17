import Foundation

package enum DefaultBundledPresets {
    /// Seed bundled preset files into `{presetsDir}/{category}/{name}.md`, overwriting existing copies.
    /// Iterates every category subfolder inside the bundled `presets/` directory.
    /// User-created presets (files not in the bundle) are left alone.
    ///
    /// Note: legacy flat caption presets are seeded by `DefaultPresets` (inline configJson format).
    /// This seeder handles the newer self-documenting YAML format in category subfolders.
    package static func seed(presetsDir: URL) throws {
        try FileManager.default.createDirectory(
            at: presetsDir, withIntermediateDirectories: true
        )

        guard let bundleResources = Bundle.module.resourceURL else { return }
        let bundledDir = bundleResources.appendingPathComponent("presets", isDirectory: true)

        guard FileManager.default.fileExists(atPath: bundledDir.path) else { return }

        let categoryDirs = try FileManager.default.contentsOfDirectory(
            at: bundledDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for categoryDir in categoryDirs {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: categoryDir.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let categoryName = categoryDir.lastPathComponent
            let targetCategoryDir = presetsDir.appendingPathComponent(categoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: targetCategoryDir, withIntermediateDirectories: true)

            let files = try FileManager.default.contentsOfDirectory(
                at: categoryDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for sourceURL in files {
                let target = targetCategoryDir.appendingPathComponent(sourceURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: sourceURL, to: target)
            }
        }
    }
}
