import Foundation

/// Generates URL-safe, human-readable kebab-case slugs used as identifiers in the
/// markdown-backed data store.
///
/// Rules:
/// - Lowercased
/// - Diacritics stripped (`Café` → `cafe`)
/// - Runs of non-alphanumeric ASCII characters collapsed to a single hyphen
/// - Leading and trailing hyphens trimmed
/// - Empty result falls back to `"untitled"`
package enum SlugGenerator {
    /// Convert an arbitrary string to a kebab-case slug.
    package static func slugify(_ input: String) -> String {
        let normalized = input.folding(options: .diacriticInsensitive, locale: nil).lowercased()

        var result = ""
        var lastWasHyphen = true // treat the start as if we just wrote a hyphen so leading junk is dropped

        for char in normalized {
            if char.isASCII && (char.isLetter || char.isNumber) {
                result.append(char)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }

        while result.hasSuffix("-") {
            result.removeLast()
        }

        return result.isEmpty ? "untitled" : result
    }

    /// Given a base slug and a predicate that reports whether a candidate slug already exists,
    /// return a unique slug.
    ///
    /// Strategy:
    /// 1. Try `base`.
    /// 2. If taken, try `base-2`, `base-3`, …, `base-100`.
    /// 3. If still colliding, append a random 4-char hex suffix (tries 10 candidates).
    /// 4. As a last resort, append 8 chars of a UUID — effectively guaranteed unique.
    package static func uniqueSlug(base: String, exists: (String) throws -> Bool) throws -> String {
        if try !exists(base) { return base }

        for n in 2...100 {
            let candidate = "\(base)-\(n)"
            if try !exists(candidate) { return candidate }
        }

        for _ in 0..<10 {
            let hex = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
            let candidate = "\(base)-\(hex)"
            if try !exists(candidate) { return candidate }
        }

        let uuidSuffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        return "\(base)-\(uuidSuffix)"
    }
}
