import Foundation

package struct ServerConfig: Sendable {
    /// Root folder for the markdown data store. Set via `REELABS_DATA_DIR` env var or
    /// `data_path` in config.json next to the binary.
    package let dataPath: String?
    package let httpPort: Int?
    package let httpHost: String?

    package struct LoadResult: Sendable {
        package let config: ServerConfig
        package let configSource: String
    }

    package static func load() -> LoadResult {
        if let envDataDir = ProcessInfo.processInfo.environment["REELABS_DATA_DIR"],
           !envDataDir.isEmpty {
            let config = ServerConfig(dataPath: envDataDir, httpPort: nil, httpHost: nil)
            return LoadResult(config: config, configSource: "REELABS_DATA_DIR env var")
        }

        let binaryConfig = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: binaryConfig),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let config = ServerConfig(
                dataPath: json["data_path"] as? String,
                httpPort: json["http_port"] as? Int,
                httpHost: json["http_host"] as? String
            )
            return LoadResult(config: config, configSource: binaryConfig.path)
        }

        let config = ServerConfig(dataPath: nil, httpPort: nil, httpHost: nil)
        return LoadResult(config: config, configSource: "defaults")
    }

    /// Resolve the data root URL. Uses `dataPath` if set, otherwise defaults to
    /// `~/Library/Application Support/ReelabsMCP/`.
    package func resolveDataRoot() -> URL {
        if let configured = dataPath, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return appSupport.appendingPathComponent("ReelabsMCP", isDirectory: true)
    }
}
