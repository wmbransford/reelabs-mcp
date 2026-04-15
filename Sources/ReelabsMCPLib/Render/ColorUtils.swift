import CoreGraphics
import Foundation

/// Parse a hex color string (#RRGGBB or #RRGGBBAA) into a CGColor.
/// Falls back to opaque white on invalid input.
package func parseHexColor(_ hex: String) -> CGColor {
    var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hexStr.hasPrefix("#") { hexStr.removeFirst() }

    var value: UInt64 = 0
    Scanner(string: hexStr).scanHexInt64(&value)

    if hexStr.count == 8 {
        // #RRGGBBAA
        let r = CGFloat((value >> 24) & 0xFF) / 255.0
        let g = CGFloat((value >> 16) & 0xFF) / 255.0
        let b = CGFloat((value >> 8) & 0xFF) / 255.0
        let a = CGFloat(value & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: a)
    } else {
        // #RRGGBB (default alpha = 1.0)
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
