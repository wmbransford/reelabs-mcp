import Foundation

/// OAuth 2.0 Device Authorization Grant (RFC 8628) client against the ReeLabs
/// proxy. Call `start()` to get a user code + verification URL, then
/// `pollUntilActivated()` to block until the user finishes sign-in in their
/// browser. The returned `apiToken` is an opaque `rl_...` string that should
/// be written to the Keychain and sent as a Bearer token to `/transcribe`.
package struct DeviceCodeFlow: Sendable {
    package struct Start: Sendable {
        package let deviceCode: String
        package let userCode: String
        package let verificationUri: String
        package let verificationUriComplete: String
        package let expiresInSeconds: Int
        package let intervalSeconds: Int
    }

    package struct Activated: Sendable {
        package let apiToken: String
        package let uid: String
    }

    package enum FlowError: LocalizedError {
        case httpError(statusCode: Int, body: String)
        case invalidResponse
        case expired
        case cancelled

        package var errorDescription: String? {
            switch self {
            case .httpError(let code, let body): "Proxy error \(code): \(body)"
            case .invalidResponse: "Invalid proxy response"
            case .expired: "Device code expired. Run sign-in again."
            case .cancelled: "Sign-in cancelled."
            }
        }
    }

    package init() {}

    /// Request a fresh device code + user code from the proxy.
    package func start() async throws -> Start {
        var request = URLRequest(url: ProxyEndpoints.deviceCode)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FlowError.invalidResponse }
        guard http.statusCode == 200 else {
            throw FlowError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["deviceCode"] as? String,
              let userCode = json["userCode"] as? String,
              let verificationUri = json["verificationUri"] as? String,
              let verificationUriComplete = json["verificationUriComplete"] as? String,
              let expiresIn = json["expiresInSeconds"] as? Int,
              let interval = json["intervalSeconds"] as? Int else {
            throw FlowError.invalidResponse
        }

        return Start(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verificationUri,
            verificationUriComplete: verificationUriComplete,
            expiresInSeconds: expiresIn,
            intervalSeconds: interval
        )
    }

    /// Poll `/deviceToken` every `intervalSeconds` until the user activates the
    /// device (200), the code expires (410), or it's invalidated (404).
    package func pollUntilActivated(start: Start) async throws -> Activated {
        let deadline = Date().addingTimeInterval(TimeInterval(start.expiresInSeconds))

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(start.intervalSeconds) * 1_000_000_000)

            var request = URLRequest(url: ProxyEndpoints.deviceToken)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = ["deviceCode": start.deviceCode]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FlowError.invalidResponse }

            switch http.statusCode {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["apiToken"] as? String,
                      let uid = json["uid"] as? String else {
                    throw FlowError.invalidResponse
                }
                return Activated(apiToken: token, uid: uid)
            case 202:
                continue
            case 410, 404:
                throw FlowError.expired
            default:
                throw FlowError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
            }
        }

        throw FlowError.expired
    }
}
