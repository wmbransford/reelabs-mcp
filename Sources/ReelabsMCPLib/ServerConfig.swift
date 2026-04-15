import Foundation

package struct ServerConfig: Sendable {
    package let chirpProjectId: String
    package let chirpLocation: String
    package let chirpModel: String
    package let serviceAccountPath: String?
    package let databasePath: String?
    package let gcsBucket: String
    package let httpPort: Int?
    package let httpHost: String?

    package struct LoadResult: Sendable {
        package let config: ServerConfig
        package let configSource: String
    }

    package static func load() -> LoadResult {
        // Resolve config.json relative to the binary or current directory
        let configPaths = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("config.json"),
            // Also check next to the binary
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("config.json"),
        ]

        for configPath in configPaths {
            if let data = try? Data(contentsOf: configPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                // Resolve service account path relative to config file location
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
                    databasePath: json["database_path"] as? String,
                    gcsBucket: json["gcs_bucket"] as? String ?? "",
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
            databasePath: nil,
            gcsBucket: "",
            httpPort: nil,
            httpHost: nil
        )
        return LoadResult(config: config, configSource: "defaults")
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
