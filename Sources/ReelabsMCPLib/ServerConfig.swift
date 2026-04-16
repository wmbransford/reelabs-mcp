import Foundation

package struct ServerConfig: Sendable {
    package let chirpProjectId: String
    package let chirpLocation: String
    package let chirpModel: String
    package let serviceAccountPath: String?
    /// Root folder for the markdown data store. Expanded from `data_path` in config.json.
    package let dataPath: String?
    package let httpPort: Int?
    package let httpHost: String?

    package struct LoadResult: Sendable {
        package let config: ServerConfig
        package let configSource: String
    }

    package static func load() -> LoadResult {
        let configPaths = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("config.json"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("config.json"),
        ]

        for configPath in configPaths {
            if let data = try? Data(contentsOf: configPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                var saPath: String? = nil
                if let relativeSA = json["service_account_path"] as? String {
                    let configDir = configPath.deletingLastPathComponent()
                    let absoluteSA = configDir.appendingPathComponent(relativeSA).path
                    if FileManager.default.fileExists(atPath: absoluteSA) {
                        saPath = absoluteSA
                    } else if FileManager.default.fileExists(atPath: relativeSA) {
                        saPath = relativeSA
                    }
                }

                let config = ServerConfig(
                    chirpProjectId: json["chirp_project_id"] as? String ?? "",
                    chirpLocation: json["chirp_location"] as? String ?? "us",
                    chirpModel: json["chirp_model"] as? String ?? "chirp_3",
                    serviceAccountPath: saPath,
                    dataPath: json["data_path"] as? String,
                    httpPort: json["http_port"] as? Int,
                    httpHost: json["http_host"] as? String
                )
                return LoadResult(config: config, configSource: configPath.path)
            }
        }

        let config = ServerConfig(
            chirpProjectId: "",
            chirpLocation: "us",
            chirpModel: "chirp_3",
            serviceAccountPath: nil,
            dataPath: nil,
            httpPort: nil,
            httpHost: nil
        )
        return LoadResult(config: config, configSource: "defaults")
    }

    /// Resolve the data root URL. Uses `data_path` from config if set, otherwise
    /// defaults to `~/Library/Application Support/ReelabsMCP/data`.
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
        return appSupport
            .appendingPathComponent("ReelabsMCP", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }
}

struct ServiceAccount: Codable, Sendable {
    let projectId: String
    let privateKeyId: String
    let privateKey: String
    let clientEmail: String
    let tokenUri: String

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case privateKeyId = "private_key_id"
        case privateKey = "private_key"
        case clientEmail = "client_email"
        case tokenUri = "token_uri"
    }
}
