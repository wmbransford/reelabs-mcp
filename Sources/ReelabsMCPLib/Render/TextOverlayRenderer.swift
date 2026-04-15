import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Renders text overlay cards (title + body) as CIImages for compositing.
/// Uses Core Graphics directly — no CATextLayer — so it works in headless CLI.
enum TextOverlayRenderer {

    /// Render a text card with optional background color and corner radius.
    /// Returns a CIImage at the exact target size.
    static func render(
        config: TextOverlayConfig,
        backgroundColor: String?,
        size: CGSize,
        cornerRadius: Double?
    ) -> CIImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0 && height > 0 else {
            return CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        // Draw background with optional corner radius
        if let bgHex = backgroundColor {
            let bgColor = parseHexColor(bgHex)
            ctx.setFillColor(bgColor)
            if let cr = cornerRadius, cr > 0 {
                let cornerPx = cr * Double(min(width, height)) / 2
                let path = CGPath(
                    roundedRect: fullRect,
                    cornerWidth: cornerPx,
                    cornerHeight: cornerPx,
                    transform: nil
                )
                ctx.addPath(path)
                ctx.fillPath()
            } else {
                ctx.fill(fullRect)
            }
        }

        // Calculate padding
        let paddingFrac = config.padding ?? 0.08
        let padX = CGFloat(paddingFrac) * size.width
        let padY = CGFloat(paddingFrac) * size.height
        let contentRect = fullRect.insetBy(dx: padX, dy: padY)
        guard contentRect.width > 0 && contentRect.height > 0 else {
            return finalize(ctx: ctx, size: size)
        }

        // Resolve fonts
        let fontFamily = config.fontFamily ?? "Arial"
        let titleFontSize = CGFloat(config.titleFontSize ?? 48)
        let bodyFontSize = CGFloat(config.bodyFontSize ?? 32)
        let titleFont = resolveFont(family: fontFamily, weight: config.titleFontWeight ?? "bold", size: titleFontSize)
        let bodyFont = resolveFont(family: fontFamily, weight: config.bodyFontWeight ?? "regular", size: bodyFontSize)

        let titleColor = parseHexColor(config.titleColor ?? "#FFFFFF")
        let bodyColor = parseHexColor(config.bodyColor ?? "#FFFFFF")

        let alignment = resolveAlignment(config.alignment)

        // Measure text blocks
        var textBlocks: [(attrStr: NSAttributedString, height: CGFloat)] = []
        let maxTextWidth = contentRect.width

        if let title = config.title, !title.isEmpty {
            let attrStr = makeAttributedString(text: title, font: titleFont, color: titleColor, alignment: alignment)
            let h = measureHeight(attrStr, maxWidth: maxTextWidth)
            textBlocks.append((attrStr, h))
        }

        if let body = config.body, !body.isEmpty {
            let attrStr = makeAttributedString(text: body, font: bodyFont, color: bodyColor, alignment: alignment)
            let h = measureHeight(attrStr, maxWidth: maxTextWidth)
            textBlocks.append((attrStr, h))
        }

        guard !textBlocks.isEmpty else {
            return finalize(ctx: ctx, size: size)
        }

        let lineSpacing: CGFloat = titleFontSize * 0.4
        let totalTextHeight = textBlocks.reduce(CGFloat(0)) { $0 + $1.height } + lineSpacing * CGFloat(textBlocks.count - 1)

        // Vertical centering within content rect
        // CGContext has bottom-left origin, so we work upward
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        // Start Y: center text block vertically (in flipped=false, higher Y = higher on screen)
        var drawY = contentRect.midY + totalTextHeight / 2

        for (i, block) in textBlocks.enumerated() {
            drawY -= block.height
            block.attrStr.draw(with: CGRect(x: contentRect.origin.x, y: drawY, width: maxTextWidth, height: block.height),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
            if i < textBlocks.count - 1 {
                drawY -= lineSpacing
            }
        }

        NSGraphicsContext.current = nil

        return finalize(ctx: ctx, size: size)
    }

    // MARK: - Helpers

    private static func finalize(ctx: CGContext, size: CGSize) -> CIImage {
        guard let cgImage = ctx.makeImage() else {
            return CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        }
        return CIImage(cgImage: cgImage)
    }

    private static func resolveFont(family: String, weight: String, size: CGFloat) -> CTFont {
        let weightValue = fontWeightValue(weight)
        let traits: [String: Any] = [kCTFontWeightTrait as String: weightValue]
        let attributes: [String: Any] = [
            kCTFontFamilyNameAttribute as String: family,
            kCTFontTraitsAttribute as String: traits
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func fontWeightValue(_ weight: String) -> CGFloat {
        switch weight.lowercased() {
        case "ultralight": return -0.8
        case "thin": return -0.6
        case "light": return -0.4
        case "regular": return 0.0
        case "medium": return 0.23
        case "semibold": return 0.3
        case "bold": return 0.4
        case "heavy": return 0.56
        case "black": return 0.62
        default: return 0.0
        }
    }

    private static func resolveAlignment(_ raw: String?) -> NSTextAlignment {
        switch raw?.lowercased() {
        case "left": return .left
        case "right": return .right
        default: return .center
        }
    }

    private static func makeAttributedString(text: String, font: CTFont, color: CGColor, alignment: NSTextAlignment) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static func measureHeight(_ attrStr: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
        let rect = attrStr.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }
}
