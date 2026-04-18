import AppKit
import AVFoundation
import CoreImage
import CoreText
import Foundation
import QuartzCore

// MARK: - Compositor Caption Overlay

/// Pre-rendered caption data for single-pass compositor rendering.
/// Contains CIImages positioned in bottom-left (CIImage) coordinate space.
struct CaptionOverlay: @unchecked Sendable {
    let groups: [Group]

    struct Group: @unchecked Sendable {
        let startTime: Double   // composition time (seconds)
        let endTime: Double
        let baseWords: [Word]      // all words in base color (visible during group window)
        let highlightWords: [Word] // same words in highlight color (visible during word window)
    }

    struct Word: @unchecked Sendable {
        let startTime: Double
        let endTime: Double
        let image: CIImage     // pre-rendered text at origin (0,0)
        let position: CGPoint  // CIImage bottom-left origin on canvas
        let size: CGSize
    }
}

enum CaptionLayer {
    /// Create a CALayer tree with word-by-word captions using pre-rendered CGImages.
    /// CATextLayer does not render in headless CLI processes (no window server),
    /// so all text is rasterized via Core Graphics and set as CALayer.contents.
    static func createOverlay(
        transcriptData: TranscriptData,
        config: CaptionConfig,
        videoSize: CGSize,
        totalDuration: Double,
        exclusionZones: [ClosedRange<Double>] = []
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
        captionLog("[CaptionLayer] words=\(relevantWords.count), invalid=\(invalidCount), groups=\(groups.count), exclusionZones=\(exclusionZones.count)")

        let maxWidth = videoSize.width * 0.9

        for (groupIdx, group) in groups.enumerated() {
            autoreleasepool {
                guard let firstWord = group.first, let lastWord = group.last else { return }
                let startSec = firstWord.startTime
                // Clamp end to next group's start to prevent visual overlap
                let nextGroupStart = (groupIdx + 1 < groups.count) ? groups[groupIdx + 1].first?.startTime : nil
                let rawEnd = min(lastWord.endTime, totalDuration)
                let endSec = nextGroupStart.map { min(rawEnd, $0) } ?? rawEnd
                guard endSec > startSec else { return }

                // Skip groups that overlap with exclusion zones (e.g. overlay time ranges)
                let overlapsExclusion = exclusionZones.contains { zone in
                    startSec < zone.upperBound && endSec > zone.lowerBound
                }
                if overlapsExclusion { return }

                let groupStartFrac = max(startSec / totalDuration, 0)
                let groupEndFrac = min(max(endSec / totalDuration, groupStartFrac + 0.0001), 1.0)

                let fullText = group.map { formatWord($0.word, allCaps: allCaps, stripPunctuation: stripPunctuation) }.joined(separator: " ")

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
                        let naturalWidth = measureText(wordText, font: font, shadow: shadow, maxWidth: .greatestFiniteMagnitude).width
                        let wordFont = shrinkFontToFit(naturalWidth: naturalWidth, font: font, maxWidth: maxWidth, shadow: shadow)
                        guard let (baseImage, baseSize) = renderTextToImage(
                            text: wordText, font: wordFont, color: textColor, shadow: shadow, maxWidth: maxWidth
                        ) else { continue }
                        let hlImage = renderTextToImage(
                            text: wordText, font: wordFont, color: highlightColor, shadow: shadow, maxWidth: maxWidth
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
                    // Pin the BOTTOM of the text block to `position`. Wrapping
                    // grows upward, so the visible baseline stays put.
                    let baseY = position - totalTextHeight

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

                            // Highlight color layer — visible only during this word's time,
                            // clamped to the group's visibility window
                            if let hlImage = r.hlImage {
                                let hlLayer = CALayer()
                                hlLayer.frame = wordFrame
                                hlLayer.contents = hlImage
                                let wordStart = max(r.wordData.startTime, startSec)
                                let wordEnd = max(min(r.wordData.endTime, endSec), wordStart + 0.01)
                                let wordStartFrac = max(wordStart / totalDuration, groupStartFrac)
                                let wordEndFrac = min(max(wordEnd / totalDuration, wordStartFrac + 0.0001), groupEndFrac)
                                addVisibilityAnimation(to: hlLayer, startFrac: wordStartFrac, endFrac: wordEndFrac, totalDuration: totalDuration)
                                parentLayer.addSublayer(hlLayer)
                            }

                            currentX += r.baseSize.width + spaceWidth
                        }
                    }
                } else {
                    // Simple mode — full group text as one image. Shrink so the
                    // longest single word fits; line-wrapping handles the rest.
                    let maxWordWidth = group.reduce(CGFloat(0)) { acc, w in
                        let formatted = formatWord(w.word, allCaps: allCaps, stripPunctuation: stripPunctuation)
                        return max(acc, measureText(formatted, font: font, shadow: shadow, maxWidth: .greatestFiniteMagnitude).width)
                    }
                    let groupFont = shrinkFontToFit(naturalWidth: maxWordWidth, font: font, maxWidth: maxWidth, shadow: shadow)
                    let groupFullSize = measureText(fullText, font: groupFont, shadow: shadow, maxWidth: maxWidth)
                    guard let (image, imgSize) = renderTextToImage(
                        text: fullText, font: groupFont, color: textColor, shadow: shadow, maxWidth: maxWidth
                    ) else { return }

                    let groupLayerX = (videoSize.width - groupFullSize.width) / 2
                    let groupLayerY = position - groupFullSize.height

                    let textLayer = CALayer()
                    textLayer.frame = CGRect(x: groupLayerX, y: groupLayerY, width: imgSize.width, height: imgSize.height)
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

    // MARK: - Compositor Overlay Builder

    /// Build a CaptionOverlay for the VideoCompositor (single-pass rendering).
    /// Mirrors createOverlay() logic but outputs CIImages with bottom-left coords
    /// instead of CALayers with keyframe animations.
    static func buildCompositorOverlay(
        transcriptData: TranscriptData,
        config: CaptionConfig,
        videoSize: CGSize,
        totalDuration: Double,
        exclusionZones: [ClosedRange<Double>] = []
    ) -> CaptionOverlay? {
        guard totalDuration > 0 else { return nil }

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

        let relevantWords = transcriptData.words.filter { word in
            word.startTime >= 0 && word.endTime > word.startTime && word.startTime < totalDuration
        }
        let groups = groupWords(relevantWords, wordsPerGroup: wordsPerGroup)
        guard !groups.isEmpty else { return nil }

        let maxWidth = videoSize.width * 0.9
        let renderH = videoSize.height

        var captionGroups: [CaptionOverlay.Group] = []

        for (groupIdx, group) in groups.enumerated() {
            autoreleasepool {
                guard let firstWord = group.first, let lastWord = group.last else { return }
                let startSec = firstWord.startTime
                let nextGroupStart = (groupIdx + 1 < groups.count) ? groups[groupIdx + 1].first?.startTime : nil
                let rawEnd = min(lastWord.endTime, totalDuration)
                let endSec = nextGroupStart.map { min(rawEnd, $0) } ?? rawEnd
                guard endSec > startSec else { return }

                let overlapsExclusion = exclusionZones.contains { zone in
                    startSec < zone.upperBound && endSec > zone.lowerBound
                }
                if overlapsExclusion { return }

                var baseWords: [CaptionOverlay.Word] = []
                var highlightWords: [CaptionOverlay.Word] = []

                if hasHighlight {
                    let spaceWidth = measureText(" ", font: font, shadow: shadow, maxWidth: maxWidth).width

                    struct WordRender {
                        let wordData: TranscriptWord
                        let baseImage: CGImage
                        let baseSize: CGSize
                        let hlImage: CGImage?
                    }
                    var renders: [WordRender] = []
                    for wordData in group {
                        let wordText = formatWord(wordData.word, allCaps: allCaps, stripPunctuation: stripPunctuation)
                        let naturalWidth = measureText(wordText, font: font, shadow: shadow, maxWidth: .greatestFiniteMagnitude).width
                        let wordFont = shrinkFontToFit(naturalWidth: naturalWidth, font: font, maxWidth: maxWidth, shadow: shadow)
                        guard let (baseImage, baseSize) = renderTextToImage(
                            text: wordText, font: wordFont, color: textColor, shadow: shadow, maxWidth: maxWidth
                        ) else { continue }
                        let hlImage = renderTextToImage(
                            text: wordText, font: wordFont, color: highlightColor, shadow: shadow, maxWidth: maxWidth
                        )?.0
                        renders.append(WordRender(wordData: wordData, baseImage: baseImage, baseSize: baseSize, hlImage: hlImage))
                    }

                    // Line wrapping (same algorithm as createOverlay)
                    var lines: [[WordRender]] = []
                    var currentLine: [WordRender] = []
                    var lineW: CGFloat = 0
                    for r in renders {
                        let needed = currentLine.isEmpty ? r.baseSize.width : r.baseSize.width + spaceWidth
                        if !currentLine.isEmpty && lineW + needed > maxWidth {
                            lines.append(currentLine)
                            currentLine = [r]
                            lineW = r.baseSize.width
                        } else {
                            currentLine.append(r)
                            lineW += needed
                        }
                    }
                    if !currentLine.isEmpty { lines.append(currentLine) }

                    let lineHeight = renders.first.map { $0.baseSize.height } ?? CGFloat(fontSize)
                    let totalTextHeight = lineHeight * CGFloat(lines.count)
                    // Pin the BOTTOM of the text block to `position`. Wrapping
                    // grows upward so the visible baseline is consistent.
                    let baseTopY = position - totalTextHeight

                    for (lineIdx, line) in lines.enumerated() {
                        let thisLineW = line.enumerated().reduce(CGFloat(0)) { acc, pair in
                            acc + pair.element.baseSize.width + (pair.offset > 0 ? spaceWidth : 0)
                        }
                        let lineX = (videoSize.width - thisLineW) / 2
                        let lineTopY = baseTopY + CGFloat(lineIdx) * lineHeight
                        var currentX: CGFloat = 0

                        for r in line {
                            // Convert top-left coords to CIImage bottom-left origin
                            let ciX = lineX + currentX
                            let ciY = renderH - lineTopY - r.baseSize.height

                            let baseCIImage = CIImage(cgImage: r.baseImage)
                            baseWords.append(CaptionOverlay.Word(
                                startTime: startSec,
                                endTime: endSec,
                                image: baseCIImage,
                                position: CGPoint(x: ciX, y: ciY),
                                size: r.baseSize
                            ))

                            if let hlImg = r.hlImage {
                                let hlCIImage = CIImage(cgImage: hlImg)
                                let wordStart = max(r.wordData.startTime, startSec)
                                let wordEnd = max(min(r.wordData.endTime, endSec), wordStart + 0.01)
                                highlightWords.append(CaptionOverlay.Word(
                                    startTime: wordStart,
                                    endTime: wordEnd,
                                    image: hlCIImage,
                                    position: CGPoint(x: ciX, y: ciY),
                                    size: r.baseSize
                                ))
                            }

                            currentX += r.baseSize.width + spaceWidth
                        }
                    }
                } else {
                    // Simple mode — full group text as one image. Shrink so the
                    // longest single word fits; line-wrapping handles the rest.
                    let fullText = group.map { formatWord($0.word, allCaps: allCaps, stripPunctuation: stripPunctuation) }.joined(separator: " ")
                    let maxWordWidth = group.reduce(CGFloat(0)) { acc, w in
                        let formatted = formatWord(w.word, allCaps: allCaps, stripPunctuation: stripPunctuation)
                        return max(acc, measureText(formatted, font: font, shadow: shadow, maxWidth: .greatestFiniteMagnitude).width)
                    }
                    let groupFont = shrinkFontToFit(naturalWidth: maxWordWidth, font: font, maxWidth: maxWidth, shadow: shadow)
                    let fullSize = measureText(fullText, font: groupFont, shadow: shadow, maxWidth: maxWidth)

                    guard let (image, imgSize) = renderTextToImage(
                        text: fullText, font: groupFont, color: textColor, shadow: shadow, maxWidth: maxWidth
                    ) else { return }

                    let layerX = (videoSize.width - fullSize.width) / 2
                    // Pin the BOTTOM of the text block to `position`.
                    let layerTopY = position - fullSize.height
                    let ciX = layerX
                    let ciY = renderH - layerTopY - imgSize.height

                    let ciImage = CIImage(cgImage: image)
                    baseWords.append(CaptionOverlay.Word(
                        startTime: startSec,
                        endTime: endSec,
                        image: ciImage,
                        position: CGPoint(x: ciX, y: ciY),
                        size: imgSize
                    ))
                }

                captionGroups.append(CaptionOverlay.Group(
                    startTime: startSec,
                    endTime: endSec,
                    baseWords: baseWords,
                    highlightWords: highlightWords
                ))
            }
        }

        guard !captionGroups.isEmpty else { return nil }
        captionLog("[CaptionLayer] Built compositor overlay: \(captionGroups.count) groups")
        return CaptionOverlay(groups: captionGroups)
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

    /// Returns a font scaled down so a piece of text whose natural (unwrapped) width
    /// is `naturalWidth` will produce an image that fits within `maxWidth`. Accounts
    /// for the padding added by `renderTextToImage`. Returns the original font when
    /// it already fits — there is no minimum floor; very long single tokens may
    /// shrink considerably.
    private static func shrinkFontToFit(
        naturalWidth: CGFloat,
        font: CTFont,
        maxWidth: CGFloat,
        shadow: Bool
    ) -> CTFont {
        let padding: CGFloat = shadow ? 12 : 4
        let availableWidth = maxWidth - padding * 2
        guard availableWidth > 0, naturalWidth > availableWidth, naturalWidth > 0 else { return font }
        let scale = availableWidth / naturalWidth
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
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
            // Preserve apostrophes so contractions like "don't", "it's" stay intact.
            result = result.filter { !$0.isPunctuation || $0 == "'" || $0 == "\u{2019}" }
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
