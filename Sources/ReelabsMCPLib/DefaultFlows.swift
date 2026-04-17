import Foundation

package enum DefaultFlows {
    /// Copy every bundled flow file into `flowsDir`, overwriting existing copies.
    /// User-created flow files (anything not in the bundle) are left alone.
    package static func seed(flowsDir: URL) throws {
        try FileManager.default.createDirectory(
            at: flowsDir, withIntermediateDirectories: true
        )

        guard let bundleResources = Bundle.module.resourceURL else { return }
        let bundledDir = bundleResources.appendingPathComponent("flows", isDirectory: true)

        guard FileManager.default.fileExists(atPath: bundledDir.path) else { return }

        let bundledFiles = try FileManager.default.contentsOfDirectory(
            at: bundledDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for sourceURL in bundledFiles {
            let target = flowsDir.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: sourceURL, to: target)
        }
    }
}
