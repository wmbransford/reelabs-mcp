import Foundation
import Security

/// Generic-password entry in the macOS login keychain holding the ReeLabs API
/// token. The token is opaque (`rl_...`), hashed at rest on the server side,
/// and validated per request by the proxy.
package enum TokenKeychain {
    static let service = "ai.reelabs.mcp"
    static let account = "api-token"

    package enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case encoding

        package var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain error: \(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "unknown"))"
            case .encoding:
                return "Keychain value encoding failed"
            }
        }
    }

    /// Returns the stored API token, or nil if none is set.
    package static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.encoding
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Stores (or replaces) the API token.
    package static func write(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.encoding }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Removes the stored token. No-op if absent.
    package static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
