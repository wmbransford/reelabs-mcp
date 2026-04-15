import AppKit
import AVFoundation
import CoreText
import Foundation
import QuartzCore

enum CaptionLayer {
    /// Create a CALayer tree with word-by-word captions using pre-rendered CGImages.
    /// CATextLayer does not render in headless CLI processes (no window server),
    /// so all text is rasterized via Core Graphics and set as CALayer.contents.
    static func createOverlay(
        transcriptData: TranscriptData,
        config: CaptionConfig,
        videoSize: CGSize,
        totalDuration: Double
    ) -> CALayer {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)

        guard totalDuration > 0 else {
            captionLog("[CaptionLayer] SKIP: totalDuration=0")
            return parentLayer
        }

        let fontSize = (config.fontSize ?? 7.0) / 100.0 * videoSize.height
        let wordsPerGroup = config.wordsPerGroup ?? 3
        let allCaps = config.allCaps ?? true
        let shadow = config.shadow ?? true
        let position = (config.position ?? 70.0) / 100.0 * videoSize.height
        let stripPunctuation = !(config.punctuation ?? true)

        let textColor = parseColor(config.color ?? "#FFFFFF")
        let highlightColor = parseColor(config.highlightColor ?? config.color ?? "#FFFFFF")
        let hasHighlight = config.highlightColor != nil

        let font = resolveFont(family: config.fontFamily, weight: config.fontWeight, size: fontSize)

        captionLog("[CaptionLayer] Config: fontSize=\(fontSize)px, position=\(position)px, wordsPerGroup=\(wordsPerGroup), hasHighlight=\(hasHighlight), allCaps=\(allCaps), shadow=\(shadow)")
        captionLog("[CaptionLayer] Font: \(CTFontCopyFullName(font) as String? ?? "unknown"), size=\(CTFontGetSize(font))")

        // Filter words: must have valid timestamps and fall within composition
        let relevantWords = transcriptData.words.filter { word in
            word.startTime >= 0 && word.endTime > word.startTime && word.startTime < totalDuration
        }
        let groups = groupWords(relevantWords, wordsPerGroup: wordsPerGroup)

        let invalidCount = transcriptData.words.count - relevantWords.count
        captionLog("[CaptionLayer] words=\(relevantWords.count), invalid=\(invalidCount), groups=\(groups.count)")

        let maxWidth = videoSize.width * 0.9

        for group in groups {
            autoreleasepool {
                guard let firstWord = group.first, let lastWord = group.last else { return }
                let startSec = firstWord.startTime
                let endSec = min(lastWord.endTime, totalDuration)
                guard endSec > startSec else { return }

                let groupStartFrac = max(startSec / totalDuration, 0)
                let groupEndFrac = min(max(endSec / totalDuration, groupStartFrac + 0.0001), 1.0)

                // Measure full group text for centering
                let fullText = group.map { formatWord($0.word, allCaps: allCaps, stripPunctuation: stripPunctuation) }.joined(separator: " ")
                let fullSize = measureText(fullText, font: font, shadow: shadow, maxWidth: maxWidth)

                let layerX = (videoSize.width - fullSize.width) / 2
                // position is measured from top (e.g. 70% = 70% down from top).
                // Parent has isGeometryFlipped=true, so Y increases downward.
                let layerY = position - fullSize.height / 2

                if hasHighlight {
                    // Word-by-word highlight with automatic line wrapping
                    let spaceWidth = measureText(" ", font: font, shadow: shadow, maxWidth: maxWidth).width

                    // Pre-render all words so we can measure before placing
                    struct WordRender {
                        let wordData: TranscriptWord
                        let baseImage: CGImage
                        let baseSize: CGSize
                        let hlImage: CGImage?
                    }
                    var renders: [WordRender] = []
                    for wordData in group {
                        let wordText = formatWord(wordData.word, allCaps: allCaps, stripPunctuation: stripPunctuation)
                        guard let (baseImage, baseSize) = renderTextToImage(
                            text: wordText, font: font, color: textColor, shadow: shadow, maxWidth: maxWidth
                        ) else { continue }
                        let hlImage = renderTextToImage(
                            text: wordText, font: font, color: highlightColor, shadow: shadow, maxWidth: maxWidth
                        )?.0
                        renders.append(WordRender(wordData: wordData, baseImage: baseImage, baseSize: baseSize, hlImage: hlImage))
                    }

                    // Break words into lines that fit within maxWidth
                    var lines: [[WordRender]] = []
                    var currentLine: [WordRender] = []
                    var lineW: CGFloat = 0
                    captionLog("[CaptionLayer] Line-wrap: maxWidth=\(maxWidth), spaceWidth=\(spaceWidth), wordCount=\(renders.count)")
                    for r in renders {
                        let needed = currentLine.isEmpty ? r.baseSize.width : r.baseSize.width + spaceWidth
                        captionLog("[CaptionLayer]   word='\(r.wordData.word)' imgW=\(r.baseSize.width) needed=\(needed) lineW=\(lineW) wouldBe=\(lineW + needed)")
                        if !currentLine.isEmpty && lineW + needed > maxWidth {
                            captionLog("[CaptionLayer]   -> LINE BREAK (lineW+needed \(lineW + needed) > maxWidth \(maxWidth))")
                            lines.append(currentLine)
                            currentLine = [r]
                            lineW = r.baseSize.width
                        } else {
                            currentLine.append(r)
                            lineW += needed
                        }
                    }
                    if !currentLine.isEmpty { lines.append(currentLine) }
                    captionLog("[CaptionLayer] Line-wrap result: \(lines.count) lines from \(renders.count) words")

                    let lineHeight = renders.first.map { $0.baseSize.height } ?? CGFloat(fontSize)
                    let totalTextHeight = lineHeight * CGFloat(lines.count)
                    let baseY = position - totalTextHeight / 2

                    for (lineIdx, line) in lines.enumerated() {
                        let thisLineW = line.enumerated().reduce(CGFloat(0)) { acc, pair in
                            acc + pair.element.baseSize.width + (pair.offset > 0 ? spaceWidth : 0)
                        }
                        let lineX = (videoSize.width - thisLineW) / 2
                        let lineY = baseY + CGFloat(lineIdx) * lineHeight
                        var currentX: CGFloat = 0

                        for r in line {
                            let wordFrame = CGRect(x: lineX + currentX, y: lineY, width: r.baseSize.width, height: r.baseSize.height)

                            // Base color layer — visible during entire group time
                            let baseLayer = CALayer()
                            baseLayer.frame = wordFrame
                            baseLayer.contents = r.baseImage
                            addVisibilityAnimation(to: baseLayer, startFrac: groupStartFrac, endFrac: groupEndFrac, totalDuration: totalDuration)
                            parentLayer.addSublayer(baseLayer)

                            // Highlight color layer — visible only during this word's time
                            if let hlImage = r.hlImage {
                                let hlLayer = CALayer()
                                hlLayer.frame = wordFrame
                                hlLayer.contents = hlImage
                                let wordStart = max(r.wordData.startTime, 0)
                                let wordEnd = max(min(r.wordData.endTime, totalDuration), wordStart + 0.01)
                                let wordStartFrac = max(wordStart / totalDuration, 0)
                                let wordEndFrac = min(max(wordEnd / totalDuration, wordStartFrac + 0.0001), 1.0)
                                addVisibilityAnimation(to: hlLayer, startFrac: wordStartFrac, endFrac: wordEndFrac, totalDuration: totalDuration)
                                parentLayer.addSublayer(hlLayer)
                            }

                            currentX += r.baseSize.width + spaceWidth
                        }
                    }
                } else {
                    // Simple mode — full group text as one image
                    guard let (image, imgSize) = renderTextToImage(
                        text: fullText, font: font, color: textColor, shadow: shadow, maxWidth: maxWidth
                    ) else { return }

                    let textLayer = CALayer()
                    textLayer.frame = CGRect(x: layerX, y: layerY, width: imgSize.width, height: imgSize.height)
                    textLayer.contents = image

                    addVisibilityAnimation(
                        to: textLayer,
                        startFrac: startSec / totalDuration,
                        endFrac: endSec / totalDuration,
                        totalDuration: totalDuration
                    )
                    parentLayer.addSublayer(textLayer)
                }
            }
        }

        captionLog("[CaptionLayer] Created \(parentLayer.sublayers?.count ?? 0) sublayers")
        return parentLayer
    }

    // MARK: - CGImage Text Rendering

    /// Render text into a CGImage using Core Graphics. This bypasses CATextLayer
    /// which requires the window server and fails silently in CLI processes.
    private static func renderTextToImage(
        text: String,
        font: CTFont,
        color: CGColor,
        shadow: Bool,
        maxWidth: CGFloat
    ) -> (CGImage, CGSize)? {
        let attributes = textAttributes(font: font, color: color, shadow: shadow)
        let attrStr = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrStr.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).size

        // Extra padding for shadow blur
        let padding: CGFloat = shadow ? 12 : 4
        let width = Int(ceil(textSize.width + padding * 2))
        let height = Int(ceil(textSize.height + padding * 2))
        guard width > 0 && height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        attrStr.draw(at: CGPoint(x: padding, y: padding))
        NSGraphicsContext.current = nil

        guard let cgImage = ctx.makeImage() else { return nil }
        return (cgImage, CGSize(width: CGFloat(width), height: CGFloat(height)))
    }

    private static func measureText(_ text: String, font: CTFont, shadow: Bool, maxWidth: CGFloat) -> CGSize {
        let attributes = textAttributes(font: font, color: CGColor.white, shadow: shadow)
        return (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        ).size
    }

    private static func textAttributes(font: CTFont, color: CGColor, shadow: Bool) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
        ]
        if shadow {
            let shadowObj = NSShadow()
            shadowObj.shadowOffset = CGSize(width: 0, height: 2)
            shadowObj.shadowBlurRadius = 4
            shadowObj.shadowColor = NSColor(red: 0, green: 0, blue: 0, alpha: 0.8)
            attrs[.shadow] = shadowObj
        }
        return attrs
    }

    // MARK: - Animation

    /// Add a keyframe opacity animation that makes the layer visible only during [startFrac, endFrac].
    private static func addVisibilityAnimation(
        to layer: CALayer,
        startFrac: Double,
        endFrac: Double,
        totalDuration: Double
    ) {
        let sf = max(min(startFrac, 1.0), 0)
        let ef = max(min(endFrac, 1.0), sf + 0.0001)
        let eps = 0.0001
        var keyTimes: [NSNumber] = []
        var values: [NSNumber] = []

        if sf > eps {
            keyTimes.append(contentsOf: [0, NSNumber(value: sf - eps)])
            values.append(contentsOf: [0, 0])
        }
        keyTimes.append(NSNumber(value: sf))
        values.append(1)
        keyTimes.append(NSNumber(value: min(ef, 1.0)))
        values.append(1)
        if ef < 1.0 - eps {
            keyTimes.append(contentsOf: [NSNumber(value: ef + eps), 1.0])
            values.append(contentsOf: [0, 0])
        }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.keyTimes = keyTimes
        animation.values = values
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = totalDuration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false

        layer.opacity = 0
        layer.add(animation, forKey: "visibility")
    }

    // MARK: - Helpers

    private static func groupWords(_ words: [TranscriptWord], wordsPerGroup: Int) -> [[TranscriptWord]] {
        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for word in words {
            current.append(word)
            if current.count >= wordsPerGroup {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func resolveFont(family: String?, weight: String?, size: CGFloat) -> CTFont {
        let familyName = family ?? "Arial"
        let weightValue = fontWeightValue(weight ?? "bold")
        let traits: [String: Any] = [kCTFontWeightTrait as String: weightValue]
        let attributes: [String: Any] = [
            kCTFontFamilyNameAttribute as String: familyName,
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

    private static func formatWord(_ word: String, allCaps: Bool, stripPunctuation: Bool) -> String {
        var result = word
        if stripPunctuation {
            result = result.filter { !$0.isPunctuation }
        }
        if allCaps {
            result = result.uppercased()
        }
        return result
    }

    private static func parseColor(_ hex: String) -> CGColor {
        parseHexColor(hex)
    }
}
