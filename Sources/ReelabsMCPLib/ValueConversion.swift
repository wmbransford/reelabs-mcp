import Foundation
import MCP

/// Convert MCP Value to Foundation JSON objects for JSONSerialization.
extension Value {
    func toJSONObject() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .string(let s):
            return s
        case .array(let arr):
            return arr.map { $0.toJSONObject() }
        case .data(_, let data):
            return data.base64EncodedString()
        case .object(let dict):
            var result: [String: Any] = [:]
            for (key, value) in dict {
                result[key] = value.toJSONObject()
            }
            return result
        }
    }
}
