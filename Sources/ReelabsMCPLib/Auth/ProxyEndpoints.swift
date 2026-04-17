import Foundation

/// Base URLs for the ReeLabs proxy (Firebase Cloud Functions).
/// Override at runtime by setting `REELABS_PROXY_BASE` in the environment —
/// handy for hitting the Functions emulator during development.
package enum ProxyEndpoints {
    static let defaultBase = "https://us-central1-orbit-ai-d1f41.cloudfunctions.net"

    package static var base: URL {
        let raw = ProcessInfo.processInfo.environment["REELABS_PROXY_BASE"] ?? defaultBase
        return URL(string: raw) ?? URL(string: defaultBase)!
    }

    package static var transcribe: URL { base.appendingPathComponent("transcribe") }
    package static var deviceCode: URL { base.appendingPathComponent("deviceCode") }
    package static var deviceToken: URL { base.appendingPathComponent("deviceToken") }
}
