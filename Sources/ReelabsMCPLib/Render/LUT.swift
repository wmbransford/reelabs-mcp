import CoreImage
import Foundation

/// Parsed `.cube` 3D LUT ready to apply via `CIColorCubeWithColorSpace`.
///
/// Only 3D LUTs are supported (`LUT_3D_SIZE`). 1D LUTs (`LUT_1D_SIZE`) are rejected —
/// those are color grading curves, not color cube transforms, and Core Image's
/// CIColorCube filter requires a 3D cube.
package struct LUTData: Sendable {
    /// Cube edge length (e.g. 33 for a 33×33×33 Resolve LUT). Common sizes: 17, 25, 33, 64.
    package let size: Int

    /// Packed RGBA float data, `size * size * size * 4` elements.
    /// Layout: outer-to-inner is B → G → R, matching `CIColorCubeWithColorSpace`'s
    /// expected ordering (R varies fastest).
    package let data: Data

    /// Parse a Resolve-style `.cube` file.
    ///
    /// Supported:
    /// - `LUT_3D_SIZE N` (17/25/33/64 — 2³ ≤ N³ ≤ ~262k entries)
    /// - `DOMAIN_MIN r g b` / `DOMAIN_MAX r g b` (defaults 0 0 0 / 1 1 1)
    /// - Comment lines starting with `#`
    /// - Title lines (`TITLE "…"`) — ignored
    ///
    /// Rejects 1D LUTs and malformed entries with `LUTError`.
    package static func parseCube(at url: URL) throws -> LUTData {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try parseCube(text: raw, filename: url.lastPathComponent)
    }

    package static func parseCube(text: String, filename: String = "<inline>") throws -> LUTData {
        var size: Int? = nil
        var domainMin: (Float, Float, Float) = (0, 0, 0)
        var domainMax: (Float, Float, Float) = (1, 1, 1)
        var entries: [(Float, Float, Float)] = []
        entries.reserveCapacity(33 * 33 * 33)

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("TITLE") { continue }

            if line.hasPrefix("LUT_1D_SIZE") {
                throw LUTError.unsupportedDimension(filename: filename, kind: "LUT_1D_SIZE")
            }

            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 2, let n = Int(parts[1]) else {
                    throw LUTError.malformedHeader(filename: filename, line: line)
                }
                guard n >= 2 && n <= 256 else {
                    throw LUTError.cubeSizeOutOfRange(filename: filename, size: n)
                }
                size = n
                continue
            }

            if line.hasPrefix("DOMAIN_MIN") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count == 4,
                   let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) {
                    domainMin = (r, g, b)
                }
                continue
            }
            if line.hasPrefix("DOMAIN_MAX") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count == 4,
                   let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) {
                    domainMax = (r, g, b)
                }
                continue
            }

            // Data row: three floats
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 3,
                  let r = Float(parts[0]),
                  let g = Float(parts[1]),
                  let b = Float(parts[2]) else {
                // Tolerate blank lines and random tokens; skip if it doesn't match
                continue
            }
            entries.append((r, g, b))
        }

        guard let size else {
            throw LUTError.missingSize(filename: filename)
        }

        let expected = size * size * size
        guard entries.count == expected else {
            throw LUTError.entryCountMismatch(filename: filename, expected: expected, got: entries.count)
        }

        // Normalize domain to [0,1] if the file specified a custom range.
        // Most Resolve .cube files use the default 0..1 so this is a no-op.
        let rSpan = max(domainMax.0 - domainMin.0, 1e-6)
        let gSpan = max(domainMax.1 - domainMin.1, 1e-6)
        let bSpan = max(domainMax.2 - domainMin.2, 1e-6)
        let needsRescale = rSpan != 1 || gSpan != 1 || bSpan != 1
            || domainMin.0 != 0 || domainMin.1 != 0 || domainMin.2 != 0

        // Pack into RGBA Float32. Premultiplied alpha is irrelevant (alpha = 1);
        // CIColorCubeWithColorSpace expects non-premultiplied data.
        let floatsPerEntry = 4
        var buffer = [Float](repeating: 0, count: expected * floatsPerEntry)
        for i in 0..<expected {
            var r = entries[i].0
            var g = entries[i].1
            var b = entries[i].2
            if needsRescale {
                r = (r - domainMin.0) / rSpan
                g = (g - domainMin.1) / gSpan
                b = (b - domainMin.2) / bSpan
            }
            buffer[i * 4 + 0] = r
            buffer[i * 4 + 1] = g
            buffer[i * 4 + 2] = b
            buffer[i * 4 + 3] = 1.0
        }

        let data = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
        return LUTData(size: size, data: data)
    }

    /// Build a `CIColorCubeWithColorSpace` filter preloaded with this LUT.
    /// Reuse the returned filter across frames — it's thread-safe once configured
    /// (Core Image filters are value-semantics; the expensive part is the cube
    /// upload to Metal which happens on first-frame render).
    package func makeFilter(colorSpace: CGColorSpace) -> CIFilter {
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(colorSpace, forKey: "inputColorSpace")
        return filter
    }
}

/// Process-wide cache of parsed LUTs keyed by absolute path.
/// LUT parsing is ~millisecond-cheap for 33³; the value of caching is avoiding
/// re-reading the file on every render and avoiding rebuilding the `Data` blob.
package actor LUTCache {
    package static let shared = LUTCache()

    private var cache: [String: LUTData] = [:]

    package func lut(at path: String) throws -> LUTData {
        if let hit = cache[path] { return hit }
        let url = URL(fileURLWithPath: path)
        let parsed = try LUTData.parseCube(at: url)
        cache[path] = parsed
        return parsed
    }

    package func clear() {
        cache.removeAll()
    }
}

package enum LUTError: LocalizedError {
    case unsupportedDimension(filename: String, kind: String)
    case malformedHeader(filename: String, line: String)
    case cubeSizeOutOfRange(filename: String, size: Int)
    case missingSize(filename: String)
    case entryCountMismatch(filename: String, expected: Int, got: Int)

    package var errorDescription: String? {
        switch self {
        case .unsupportedDimension(let f, let k):
            return "LUT \(f): \(k) not supported — only 3D LUTs (LUT_3D_SIZE) are accepted"
        case .malformedHeader(let f, let l):
            return "LUT \(f): malformed header: \(l)"
        case .cubeSizeOutOfRange(let f, let s):
            return "LUT \(f): cube size \(s) out of range (2..256)"
        case .missingSize(let f):
            return "LUT \(f): no LUT_3D_SIZE header found"
        case .entryCountMismatch(let f, let e, let g):
            return "LUT \(f): expected \(e) entries, got \(g)"
        }
    }
}
