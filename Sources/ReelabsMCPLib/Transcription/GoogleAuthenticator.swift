import Foundation
import Security

/// Mints short-lived OAuth2 access tokens from a Google service account JSON key.
///
/// Flow: parse the SA JSON → build a JWT claim set → sign RS256 with the private key via
/// Security.framework → POST the assertion to Google's token endpoint → cache the access
/// token until it's about to expire (minus a 60s skew buffer).
///
/// Only `cloud-platform` scope is used — it's the smallest scope that covers Speech-to-Text
/// and keeps the client a single code path.
package actor GoogleAuthenticator {
    package struct ServiceAccount: Sendable, Codable {
        let projectId: String
        let privateKey: String
        let clientEmail: String
        let tokenUri: String

        enum CodingKeys: String, CodingKey {
            case projectId = "project_id"
            case privateKey = "private_key"
            case clientEmail = "client_email"
            case tokenUri = "token_uri"
        }
    }

    package enum AuthError: LocalizedError {
        case credentialsNotFound(path: String)
        case credentialsInvalid(String)
        case pemParseFailed
        case privateKeyImportFailed(String)
        case signingFailed(String)
        case tokenExchangeFailed(status: Int, body: String)

        package var errorDescription: String? {
            switch self {
            case .credentialsNotFound(let path):
                return "Service account key not found at \(path). Set GOOGLE_APPLICATION_CREDENTIALS to a valid path."
            case .credentialsInvalid(let detail):
                return "Service account JSON is invalid: \(detail)"
            case .pemParseFailed:
                return "Could not parse PEM private key."
            case .privateKeyImportFailed(let detail):
                return "Could not import RSA private key: \(detail)"
            case .signingFailed(let detail):
                return "JWT signing failed: \(detail)"
            case .tokenExchangeFailed(let status, let body):
                return "OAuth token exchange failed (\(status)): \(body)"
            }
        }
    }

    private let serviceAccount: ServiceAccount
    private var cachedToken: String?
    private var cachedExpiry: Date?
    private let scopes: String

    package init(keyPath: String, scopes: String = "https://www.googleapis.com/auth/cloud-platform") throws {
        let expanded = (keyPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw AuthError.credentialsNotFound(path: expanded)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        } catch {
            throw AuthError.credentialsInvalid("read failed: \(error.localizedDescription)")
        }
        do {
            self.serviceAccount = try JSONDecoder().decode(ServiceAccount.self, from: data)
        } catch {
            throw AuthError.credentialsInvalid("decode failed: \(error.localizedDescription)")
        }
        self.scopes = scopes
    }

    /// Resolve a service account key path from `GOOGLE_APPLICATION_CREDENTIALS`,
    /// or the default ReeLabs location if the env var is unset.
    package static func defaultKeyPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"], !env.isEmpty {
            return env
        }
        return nil
    }

    package var projectId: String { serviceAccount.projectId }

    /// Returns a valid access token, refreshing if cache is empty or stale.
    package func accessToken() async throws -> String {
        if let token = cachedToken, let expiry = cachedExpiry, Date() < expiry.addingTimeInterval(-60) {
            return token
        }
        let (token, expiresIn) = try await mintToken()
        cachedToken = token
        cachedExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        return token
    }

    // MARK: - JWT mint

    private func mintToken() async throws -> (token: String, expiresIn: Int) {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": serviceAccount.clientEmail,
            "scope": scopes,
            "aud": serviceAccount.tokenUri,
            "iat": now,
            "exp": now + 3600,
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let signingInput = "\(headerData.base64URLEncodedString()).\(claimsData.base64URLEncodedString())"

        let signature = try signRS256(message: Data(signingInput.utf8), pem: serviceAccount.privateKey)
        let jwt = "\(signingInput).\(signature.base64URLEncodedString())"

        return try await exchangeAssertion(jwt: jwt)
    }

    private func exchangeAssertion(jwt: String) async throws -> (token: String, expiresIn: Int) {
        guard let url = URL(string: serviceAccount.tokenUri) else {
            throw AuthError.credentialsInvalid("invalid token_uri")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.tokenExchangeFailed(status: -1, body: "no http response")
        }
        guard http.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw AuthError.tokenExchangeFailed(status: http.statusCode, body: "unexpected response shape")
        }
        return (token, expiresIn)
    }

    // MARK: - RS256 signing (via Security.framework)

    private func signRS256(message: Data, pem: String) throws -> Data {
        let pkcs1 = try Self.pkcs1FromPEM(pem)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            let err = error?.takeRetainedValue()
            throw AuthError.privateKeyImportFailed(err.map { CFErrorCopyDescription($0) as String } ?? "unknown")
        }
        var signError: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &signError) as Data? else {
            let err = signError?.takeRetainedValue()
            throw AuthError.signingFailed(err.map { CFErrorCopyDescription($0) as String } ?? "unknown")
        }
        return sig
    }

    /// Convert a PEM-encoded PKCS#8 RSA private key to the raw PKCS#1 DER bytes
    /// that `SecKeyCreateWithData` expects.
    private static func pkcs1FromPEM(_ pem: String) throws -> Data {
        let lines = pem.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64 = lines.joined()
        guard let der = Data(base64Encoded: base64) else {
            throw AuthError.pemParseFailed
        }
        // PKCS#8 wraps PKCS#1 in an OCTET STRING. Walk the ASN.1 to pull it out.
        return try extractPKCS1(fromPKCS8: der)
    }

    /// Minimal ASN.1 walker that pulls the inner PKCS#1 RSA private key bytes out of
    /// a PKCS#8 wrapper. Does NOT handle encrypted PKCS#8 — SA keys are unencrypted.
    ///
    /// PKCS#8 layout:
    ///   SEQUENCE {
    ///     INTEGER 0,                     -- version
    ///     SEQUENCE { OID rsaEncryption, NULL },
    ///     OCTET STRING { ...PKCS#1... }  <-- we want these bytes
    ///   }
    private static func extractPKCS1(fromPKCS8 der: Data) throws -> Data {
        var cursor = 0
        let bytes = [UInt8](der)

        func readTag(_ expected: UInt8) throws {
            guard cursor < bytes.count, bytes[cursor] == expected else {
                throw AuthError.pemParseFailed
            }
            cursor += 1
        }
        func readLength() throws -> Int {
            guard cursor < bytes.count else { throw AuthError.pemParseFailed }
            let first = bytes[cursor]; cursor += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, cursor + count <= bytes.count else { throw AuthError.pemParseFailed }
            var len = 0
            for _ in 0..<count {
                len = (len << 8) | Int(bytes[cursor])
                cursor += 1
            }
            return len
        }
        func skip(_ n: Int) throws {
            guard cursor + n <= bytes.count else { throw AuthError.pemParseFailed }
            cursor += n
        }

        // Outer SEQUENCE
        try readTag(0x30)
        _ = try readLength()
        // version INTEGER
        try readTag(0x02)
        let verLen = try readLength()
        try skip(verLen)
        // algorithm SEQUENCE — skip whole thing
        try readTag(0x30)
        let algLen = try readLength()
        try skip(algLen)
        // OCTET STRING — contents are PKCS#1
        try readTag(0x04)
        let pkcs1Len = try readLength()
        guard cursor + pkcs1Len <= bytes.count else { throw AuthError.pemParseFailed }
        return Data(bytes[cursor..<(cursor + pkcs1Len)])
    }
}

// MARK: - Base64URL

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
