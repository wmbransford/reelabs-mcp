import Foundation

package struct ServerConfig: Sendable {
    /// Root folder for the markdown data store. Set via `REELABS_DATA_DIR` env var or
    /// `data_path` in config.json next to the binary.
    package let dataPath: String?
    package let httpPort: Int?
    package let httpHost: String?
    /// Absolute path to the GCP service-account JSON key used for Speech-to-Text auth.
    /// Resolved from `GOOGLE_APPLICATION_CREDENTIALS` env var or `gcp_credentials_path`
    /// in config.json. Nil means transcription is disabled until one is configured.
    package let gcpCredentialsPath: String?

    package struct LoadResult: Sendable {
        package let config: ServerConfig
        package let configSource: String
    }

    package static func load() -> LoadResult {
        let envDataDir = ProcessInfo.processInfo.environment["REELABS_DATA_DIR"]
        let envCredentials = ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"]

        // Try to load config.json next to the binary (for non-env fields).
        let binaryConfig = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("config.json")
        let json: [String: Any]? = {
            guard let data = try? Data(contentsOf: binaryConfig) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }()

        let dataPath = envDataDir?.nonEmpty ?? (json?["data_path"] as? String)
        let gcpPath = envCredentials?.nonEmpty ?? (json?["gcp_credentials_path"] as? String)
        let httpPort = json?["http_port"] as? Int
        let httpHost = json?["http_host"] as? String

        let config = ServerConfig(
            dataPath: dataPath,
            httpPort: httpPort,
            httpHost: httpHost,
            gcpCredentialsPath: gcpPath
        )
        let source: String
        if envDataDir?.nonEmpty != nil || envCredentials?.nonEmpty != nil {
            source = "env + \(json == nil ? "defaults" : binaryConfig.path)"
        } else if json != nil {
            source = binaryConfig.path
        } else {
            source = "defaults"
        }
        return LoadResult(config: config, configSource: source)
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
