import Foundation
import MCP

// MARK: - Path resolution

/// Resolve a file path, handling Unicode whitespace mismatches.
/// macOS screen recordings use U+202F (narrow no-break space) between time and AM/PM,
/// which looks identical to a regular space but has different bytes.
/// This tries the path as-is first, then falls back to fuzzy whitespace matching
/// in the parent directory.
func resolvePath(_ path: String) -> String {
    if FileManager.default.fileExists(atPath: path) { return path }

    // Try NFD normalization (APFS uses NFD for filenames)
    let nfd = path.decomposedStringWithCanonicalMapping
    if nfd != path && FileManager.default.fileExists(atPath: nfd) { return nfd }

    // Fuzzy whitespace match: normalize all Unicode whitespace to regular space,
    // then compare against actual directory entries
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    let target = collapseWhitespace(url.lastPathComponent)

    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
        return path
    }
    for entry in entries where collapseWhitespace(entry) == target {
        return (dir as NSString).appendingPathComponent(entry)
    }
    return path
}

/// Replace all Unicode whitespace (U+00A0, U+202F, U+2007, etc.) with regular space.
private func collapseWhitespace(_ s: String) -> String {
    String(s.unicodeScalars.map { CharacterSet.whitespaces.contains($0) ? " " : Character($0) })
}

// MARK: - Shared tool helpers

func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value),
          let json = String(data: data, encoding: .utf8) else {
        fputs("[ReeLabs] Warning: failed to encode \(T.self) to JSON, returning {}\n", stderr)
        return "{}"
    }
    return json
}

func extractDouble(_ value: Value?) -> Double? {
    guard let value else { return nil }
    if let d = value.doubleValue {
        return d
    }
    if let i = value.intValue {
        return Double(i)
    }
    if let s = value.stringValue, let d = Double(s) {
        return d
    }
    return nil
}

func extractInt64(_ value: Value?) -> Int64? {
    guard let value else { return nil }
    if let i = value.intValue {
        return Int64(i)
    }
    if let d = value.doubleValue {
        return Int64(d)
    }
    if let s = value.stringValue, let i = Int64(s) {
        return i
    }
    return nil
}

// MARK: - JSON response safety

/// Recursively replace non-finite Doubles/Floats (NaN, Infinity) with 0.
/// `JSONSerialization` throws an Obj-C `NSInvalidArgumentException` on non-finite numbers,
/// which Swift's `try/catch` cannot intercept — the process dies. Sanitize before serializing.
func sanitizeForJSON(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict { out[k] = sanitizeForJSON(v) }
        return out
    }
    if let arr = value as? [Any] {
        return arr.map { sanitizeForJSON($0) }
    }
    if let d = value as? Double {
        return d.isFinite ? d : 0
    }
    if let f = value as? Float {
        return f.isFinite ? Double(f) : 0
    }
    return value
}

/// Serialize a response dict to JSON data, sanitizing non-finite numbers first.
/// Use this at every MCP response boundary in place of `JSONSerialization.data(withJSONObject:options:)`.
func safeJSONData(from object: Any, options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]) throws -> Data {
    let sanitized = sanitizeForJSON(object)
    return try JSONSerialization.data(withJSONObject: sanitized, options: options)
}
