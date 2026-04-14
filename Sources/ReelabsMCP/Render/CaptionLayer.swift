import AppKit
import AVFoundation
import CoreText
import Foundation
import QuartzCore

enum CaptionLayer {
    /// Create a CALayer tree with word-by-word color-animated captions.
    /// Each word group appears during its time window. Within each group,
    /// the active word is highlighted in `highlightColor` while others stay
    /// in `color`. This produces the TikTok-style karaoke effect.
    static func createOverlay(
        transcriptData: TranscriptData,
        config: CaptionConfig,
        videoSize: CGSize,
        totalDuration: Double
    ) -> CALayer {
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.contentsScale = scale

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

        // Create font — use descriptor with weight trait when fontWeight is set
        let font = resolveFont(family: config.fontFamily, weight: config.fontWeight, size: fontSize)

        captionLog("[CaptionLayer] Config: fontSize=\(fontSize)px, position=\(position)px, wordsPerGroup=\(wordsPerGroup), hasHighlight=\(hasHighlight), allCaps=\(allCaps), shadow=\(shadow)")
        captionLog("[CaptionLayer] Font: \(CTFontCopyFullName(font) as String? ?? "unknown"), size=\(CTFontGetSize(font))")
        captionLog("[CaptionLayer] videoSize=\(Int(videoSize.width))x\(Int(videoSize.height)), totalDuration=\(totalDuration)s")

        // Filter words: must have valid timestamps and fall within composition
        let relevantWords = transcriptData.words.filter { word in
            word.startTime >= 0 && word.endTime > word.startTime && word.startTime < totalDuration
        }
        let groups = groupWords(relevantWords, wordsPerGroup: wordsPerGroup)

        let invalidCount = transcriptData.words.count - relevantWords.count
        captionLog("[CaptionLayer] Total words=\(transcriptData.words.count), valid=\(relevantWords.count), invalid=\(invalidCount), groups=\(groups.count)")
        if invalidCount > 0 {
            let badWords = transcriptData.words.filter { $0.startTime < 0 || $0.endTime <= $0.startTime }
            for bw in badWords.prefix(5) {
                captionLog("[CaptionLayer] INVALID WORD: '\(bw.word)' start=\(bw.startTime) end=\(bw.endTime)")
            }
        }

        for group in groups {
            autoreleasepool {
            guard let firstWord = group.first, let lastWord = group.last else { return }
            let startSec = firstWord.startTime
            let endSec = min(lastWord.endTime, totalDuration)
            guard endSec > startSec else { return }

            // --- Build the group layer (contains per-word sublayers) ---
            let groupLayer = CALayer()
            groupLayer.frame = CGRect(origin: .zero, size: videoSize)
            groupLayer.contentsScale = scale

            // Base paragraph style
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            // Measure the full group text to position the group
            let fullText = group.map { formatWord($0.word, allCaps: allCaps, stripPunctuation: stripPunctuation) }.joined(separator: " ")
            let maxWidth = videoSize.width * 0.9
            var baseAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(cgColor: textColor) ?? NSColor.white,
                .paragraphStyle: paragraphStyle
            ]

            if shadow {
                let shadowObj = NSShadow()
                shadowObj.shadowOffset = CGSize(width: 0, height: 2)
                shadowObj.shadowBlurRadius = 4
                shadowObj.shadowColor = NSColor(red: 0, green: 0, blue: 0, alpha: 0.8)
                baseAttributes[.shadow] = shadowObj
            }

            let textSize = (fullText as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: baseAttributes
            ).size

            let layerX = (videoSize.width - textSize.width) / 2
            // position is measured from top (e.g. 70% = 70% down from top).
            // The export parent is geometry-flipped but this caption layer is not,
            // so convert to bottom-left origin: y = (height - position) - center offset.
            let layerY = (videoSize.height - position) - textSize.height / 2
            let groupFrame = CGRect(
                x: layerX,
                y: layerY,
                width: textSize.width + 8,
                height: textSize.height + 4
            )

            if hasHighlight {
                // --- Word-by-word highlight mode ---
                // Create one text layer per word, positioned inline.
                // Use attributes WITHOUT .foregroundColor so that the CATextLayer's
                // foregroundColor property (animated via keyframes) controls the color.
                var wordAttributes = baseAttributes
                wordAttributes.removeValue(forKey: .foregroundColor)

                var currentX: CGFloat = 4 // padding offset
                let spaceWidth = (" " as NSString).size(withAttributes: baseAttributes).width

                for (_, wordData) in group.enumerated() {
                    let wordText = formatWord(wordData.word, allCaps: allCaps, stripPunctuation: stripPunctuation)
                    let wordSize = (wordText as NSString).size(withAttributes: baseAttributes)

                    let wordLayer = CATextLayer()
                    wordLayer.contentsScale = scale
                    wordLayer.foregroundColor = textColor
                    wordLayer.frame = CGRect(
                        x: groupFrame.minX + currentX,
                        y: groupFrame.minY,
                        width: wordSize.width + 2,
                        height: groupFrame.height
                    )
                    wordLayer.alignmentMode = .center

                    // Set text without foreground color — the layer property handles it
                    let wordAttrString = NSAttributedString(string: wordText, attributes: wordAttributes)
                    wordLayer.string = wordAttrString

                    // Animate foreground color: base → highlight → base
                    // Clamp all timestamps to valid range [0, totalDuration]
                    let wordStart = max(wordData.startTime, 0)
                    let wordEnd = max(min(wordData.endTime, totalDuration), wordStart + 0.01)

                    let wordStartFrac = max(wordStart / totalDuration, 0)
                    let wordEndFrac = min(max(wordEnd / totalDuration, wordStartFrac + 0.0001), 1.0)
                    let groupStartFrac = max(startSec / totalDuration, 0)
                    let groupEndFrac = min(max(endSec / totalDuration, groupStartFrac + 0.0001), 1.0)
                    let eps = 0.0001

                    // Color animation: switch to highlight during this word's time
                    let colorAnim = CAKeyframeAnimation(keyPath: "foregroundColor")
                    var colorKeyTimes: [NSNumber] = []
                    var colorValues: [CGColor] = []

                    // Before word: base color
                    if wordStartFrac > groupStartFrac + eps {
                        colorKeyTimes.append(NSNumber(value: max(groupStartFrac, 0)))
                        colorValues.append(textColor)
                        colorKeyTimes.append(NSNumber(value: wordStartFrac - eps))
                        colorValues.append(textColor)
                    }
                    // During word: highlight
                    colorKeyTimes.append(NSNumber(value: max(wordStartFrac, 0)))
                    colorValues.append(highlightColor)
                    colorKeyTimes.append(NSNumber(value: min(wordEndFrac, 1.0)))
                    colorValues.append(highlightColor)
                    // After word: base color
                    if wordEndFrac < groupEndFrac - eps {
                        colorKeyTimes.append(NSNumber(value: wordEndFrac + eps))
                        colorValues.append(textColor)
                        colorKeyTimes.append(NSNumber(value: min(groupEndFrac, 1.0)))
                        colorValues.append(textColor)
                    }

                    colorAnim.keyTimes = colorKeyTimes
                    colorAnim.values = colorValues
                    colorAnim.beginTime = AVCoreAnimationBeginTimeAtZero
                    colorAnim.duration = totalDuration
                    colorAnim.fillMode = .both
                    colorAnim.isRemovedOnCompletion = false
                    wordLayer.add(colorAnim, forKey: "wordHighlight")

                    // Opacity: show only during group time
                    addVisibilityAnimation(
                        to: wordLayer,
                        startFrac: groupStartFrac,
                        endFrac: groupEndFrac,
                        totalDuration: totalDuration
                    )

                    groupLayer.addSublayer(wordLayer)
                    currentX += wordSize.width + spaceWidth
                }
            } else {
                // --- Simple mode (no highlight) ---
                let textLayer = CATextLayer()
                textLayer.contentsScale = scale
                textLayer.string = NSAttributedString(string: fullText, attributes: baseAttributes)
                textLayer.frame = groupFrame

                addVisibilityAnimation(
                    to: textLayer,
                    startFrac: startSec / totalDuration,
                    endFrac: endSec / totalDuration,
                    totalDuration: totalDuration
                )

                groupLayer.addSublayer(textLayer)
            }

            parentLayer.addSublayer(groupLayer)
            }
        }

        return parentLayer
    }

    // MARK: - Helpers

    /// Add a keyframe opacity animation that makes the layer visible only during [startFrac, endFrac].
    private static func addVisibilityAnimation(
        to layer: CALayer,
        startFrac: Double,
        endFrac: Double,
        totalDuration: Double
    ) {
        // Clamp to valid range — invalid fractions corrupt the entire animation tree
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

    /// Build a CTFont using a font descriptor with family name + weight trait.
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
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }

        var rgb: UInt64 = 0
        Scanner(string: hexStr).scanHexInt64(&rgb)

        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0

        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
