import Foundation
import CryptoKit

package enum ContentHasher {
    /// Streaming SHA-256 of a file. Reads in 1 MiB chunks to avoid loading huge
    /// video files into memory. Returns the lowercase hex digest (64 chars).
    package static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
