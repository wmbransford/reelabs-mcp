import Foundation
import MCP

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
