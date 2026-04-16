import Foundation
import MCP

// MARK: - Layout Presets

/// Position/size for an overlay element, all values 0-1 fractions.
private struct LayoutRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let cornerRadius: Double

    static let hidden = LayoutRect(x: -1, y: -1, width: 0, height: 0, cornerRadius: 0)
    static let fullFrame = LayoutRect(x: 0, y: 0, width: 1, height: 1, cornerRadius: 0)

    var isHidden: Bool { width <= 0 || height <= 0 }
    var isFullFrame: Bool { x == 0 && y == 0 && width == 1 && height == 1 }
}

/// A layout defines where screen and speaker go, and whether a background is needed.
private struct LayoutPreset {
    let screen: LayoutRect
    let speaker: LayoutRect
    let needsBackground: Bool
}

/// All layout presets keyed by name and aspect ratio category.
private enum LayoutPresets {
    // MARK: - 16:9 Landscape

    static let landscape: [String: LayoutPreset] = [
        "pip_small": LayoutPreset(
            screen: .fullFrame,
            speaker: LayoutRect(x: 0.02, y: 0.72, width: 0.22, height: 0.25, cornerRadius: 0.15),
            needsBackground: false
        ),
        "pip_medium": LayoutPreset(
            screen: .fullFrame,
            speaker: LayoutRect(x: 0.02, y: 0.55, width: 0.35, height: 0.40, cornerRadius: 0.12),
            needsBackground: false
        ),
        "split": LayoutPreset(
            screen: LayoutRect(x: 0.38, y: 0.04, width: 0.58, height: 0.92, cornerRadius: 0.04),
            speaker: LayoutRect(x: 0.04, y: 0.15, width: 0.30, height: 0.70, cornerRadius: 0.08),
            needsBackground: true
        ),
        "speaker_focus": LayoutPreset(
            screen: LayoutRect(x: 0.58, y: 0.55, width: 0.38, height: 0.40, cornerRadius: 0.04),
            speaker: LayoutRect(x: 0.10, y: 0.08, width: 0.55, height: 0.84, cornerRadius: 0.06),
            needsBackground: true
        ),
        "screen_only": LayoutPreset(
            screen: .fullFrame,
            speaker: .hidden,
            needsBackground: false
        ),
        "speaker_only": LayoutPreset(
            screen: .hidden,
            speaker: .fullFrame,
            needsBackground: false
        ),
    ]

    // MARK: - 9:16 Portrait

    static let portrait: [String: LayoutPreset] = [
        "pip_small": LayoutPreset(
            screen: .fullFrame,
            speaker: LayoutRect(x: 0.30, y: 0.78, width: 0.40, height: 0.18, cornerRadius: 0.15),
            needsBackground: false
        ),
        "pip_medium": LayoutPreset(
            screen: .fullFrame,
            speaker: LayoutRect(x: 0.20, y: 0.65, width: 0.60, height: 0.30, cornerRadius: 0.12),
            needsBackground: false
        ),
        "split": LayoutPreset(
            screen: LayoutRect(x: 0.04, y: 0.02, width: 0.92, height: 0.52, cornerRadius: 0.04),
            speaker: LayoutRect(x: 0.10, y: 0.58, width: 0.80, height: 0.38, cornerRadius: 0.06),
            needsBackground: true
        ),
        "speaker_focus": LayoutPreset(
            screen: LayoutRect(x: 0.15, y: 0.60, width: 0.70, height: 0.35, cornerRadius: 0.04),
            speaker: LayoutRect(x: 0.05, y: 0.04, width: 0.90, height: 0.52, cornerRadius: 0.04),
            needsBackground: true
        ),
        "screen_only": LayoutPreset(
            screen: .fullFrame,
            speaker: .hidden,
            needsBackground: false
        ),
        "speaker_only": LayoutPreset(
            screen: .hidden,
            speaker: .fullFrame,
            needsBackground: false
        ),
    ]

    // MARK: - Square / 4:5

    static let square: [String: LayoutPreset] = [
        "pip_small": LayoutPreset(
            screen: .fullFrame,
            speaker: LayoutRect(x: 0.02, y: 0.72, width: 0.26, height: 0.26, cornerRadius: 0.15),
            needsBackground: false
        ),
        "pip_medium": LayoutPreset(
            screen: .fullFrame,
            speaker: LayoutRect(x: 0.02, y: 0.55, width: 0.40, height: 0.40, cornerRadius: 0.12),
            needsBackground: false
        ),
        "split": LayoutPreset(
            screen: LayoutRect(x: 0.38, y: 0.04, width: 0.58, height: 0.92, cornerRadius: 0.04),
            speaker: LayoutRect(x: 0.04, y: 0.15, width: 0.30, height: 0.70, cornerRadius: 0.08),
            needsBackground: true
        ),
        "speaker_focus": LayoutPreset(
            screen: LayoutRect(x: 0.58, y: 0.55, width: 0.38, height: 0.40, cornerRadius: 0.04),
            speaker: LayoutRect(x: 0.10, y: 0.08, width: 0.55, height: 0.84, cornerRadius: 0.06),
            needsBackground: true
        ),
        "screen_only": LayoutPreset(
            screen: .fullFrame,
            speaker: .hidden,
            needsBackground: false
        ),
        "speaker_only": LayoutPreset(
            screen: .hidden,
            speaker: .fullFrame,
            needsBackground: false
        ),
    ]

    static func presets(for aspectRatio: String) -> [String: LayoutPreset] {
        switch aspectRatio {
        case "9:16": return portrait
        case "1:1", "4:5": return square
        default: return landscape
        }
    }

    static let validNames: Set<String> = [
        "pip_small", "pip_medium", "split", "speaker_focus", "screen_only", "speaker_only"
    ]
}

// MARK: - Style Config

private struct LayoutStyle {
    let cornerRadius: Double
    let padding: Double
    let speakerCrop: CropRect?
    let background: String
    let transitionDuration: Double

    static let `default` = LayoutStyle(
        cornerRadius: 0.15,
        padding: 0.02,
        speakerCrop: nil,
        background: "#1a1a2e",
        transitionDuration: 0.4
    )

    init(from args: [String: Value]?) {
        let style = args?["style"]?.objectValue
        cornerRadius = extractDouble(style?["cornerRadius"]) ?? Self.default.cornerRadius
        padding = extractDouble(style?["padding"]) ?? Self.default.padding
        background = style?["background"]?.stringValue ?? Self.default.background
        transitionDuration = extractDouble(style?["transitionDuration"]) ?? Self.default.transitionDuration

        if let crop = style?["speakerCrop"]?.objectValue {
            speakerCrop = CropRect(
                x: extractDouble(crop["x"]) ?? 0,
                y: extractDouble(crop["y"]) ?? 0,
                width: extractDouble(crop["width"]) ?? 1,
                height: extractDouble(crop["height"]) ?? 1
            )
        } else {
            speakerCrop = nil
        }
    }

    private init(cornerRadius: Double, padding: Double, speakerCrop: CropRect?, background: String, transitionDuration: Double) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.speakerCrop = speakerCrop
        self.background = background
        self.transitionDuration = transitionDuration
    }
}

// MARK: - Timeline Entry

private struct TimelineEntry {
    let layout: String
    let start: Double
    let end: Double
}

// MARK: - LayoutTool

package enum LayoutTool {
    package static let tool = Tool(
        name: "reelabs_layout",
        description: """
            Generate overlay arrays for screen recording layouts (PiP, split-screen, speaker focus). \
            Takes a screen source, speaker source, and a timeline of layout switches. \
            Returns overlays ready to drop into a RenderSpec.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "screen": .object([
                    "type": .string("string"),
                    "description": .string("Source ID of the screen recording")
                ]),
                "speaker": .object([
                    "type": .string("string"),
                    "description": .string("Source ID of the speaker/facecam")
                ]),
                "aspectRatio": .object([
                    "type": .string("string"),
                    "description": .string("Target aspect ratio: \"16:9\" (default), \"9:16\", \"1:1\", \"4:5\""),
                    "default": .string("16:9")
                ]),
                "timeline": .object([
                    "type": .string("array"),
                    "description": .string("Array of layout sections: [{layout, start, end}, ...]"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "layout": .object([
                                "type": .string("string"),
                                "description": .string("Layout name: pip_small, pip_medium, split, speaker_focus, screen_only, speaker_only")
                            ]),
                            "start": .object([
                                "type": .string("number"),
                                "description": .string("Start time in seconds")
                            ]),
                            "end": .object([
                                "type": .string("number"),
                                "description": .string("End time in seconds")
                            ])
                        ]),
                        "required": .array([.string("layout"), .string("start"), .string("end")])
                    ])
                ]),
                "style": .object([
                    "type": .string("object"),
                    "description": .string("Optional style overrides"),
                    "properties": .object([
                        "cornerRadius": .object([
                            "type": .string("number"),
                            "description": .string("Speaker corner radius 0-1 (default 0.15)")
                        ]),
                        "padding": .object([
                            "type": .string("number"),
                            "description": .string("Edge padding 0-1 (default 0.02)")
                        ]),
                        "speakerCrop": .object([
                            "type": .string("object"),
                            "description": .string("Crop the speaker source: {x, y, width, height} as 0-1 fractions")
                        ]),
                        "background": .object([
                            "type": .string("string"),
                            "description": .string("Background color hex for split/focus layouts (default #1a1a2e)")
                        ]),
                        "transitionDuration": .object([
                            "type": .string("number"),
                            "description": .string("Crossfade duration between layouts in seconds (default 0.4)")
                        ])
                    ])
                ])
            ]),
            "required": .array([.string("screen"), .string("speaker"), .string("timeline")])
        ])
    )

    package static func handle(arguments: [String: Value]?) -> CallTool.Result {
        // Parse required arguments
        guard let screenId = arguments?["screen"]?.stringValue else {
            return error("Missing required argument: screen")
        }
        guard let speakerId = arguments?["speaker"]?.stringValue else {
            return error("Missing required argument: speaker")
        }
        guard let timelineArray = arguments?["timeline"]?.arrayValue, !timelineArray.isEmpty else {
            return error("Missing or empty required argument: timeline")
        }

        let aspectRatio = arguments?["aspectRatio"]?.stringValue ?? "16:9"
        let style = LayoutStyle(from: arguments)
        let presets = LayoutPresets.presets(for: aspectRatio)

        // Parse timeline entries
        var timeline: [TimelineEntry] = []
        for (i, entry) in timelineArray.enumerated() {
            let obj = entry.objectValue
            guard let layout = obj?["layout"]?.stringValue else {
                return error("timeline[\(i)]: missing layout")
            }
            guard LayoutPresets.validNames.contains(layout) else {
                return error("timeline[\(i)]: unknown layout \"\(layout)\". Valid: \(LayoutPresets.validNames.sorted().joined(separator: ", "))")
            }
            guard let start = extractDouble(obj?["start"]) else {
                return error("timeline[\(i)]: missing start")
            }
            guard let end = extractDouble(obj?["end"]) else {
                return error("timeline[\(i)]: missing end")
            }
            guard end > start else {
                return error("timeline[\(i)]: end (\(end)) must be greater than start (\(start))")
            }
            timeline.append(TimelineEntry(layout: layout, start: start, end: end))
        }

        // Sort by start time
        timeline.sort { $0.start < $1.start }

        // Generate overlays
        var overlays: [[String: Any]] = []
        let transitionDur = style.transitionDuration

        for (i, entry) in timeline.enumerated() {
            guard let preset = presets[entry.layout] else { continue }

            let isFirst = i == 0
            let isLast = i == timeline.count - 1

            // Determine transition timing
            let fadeIn = isFirst ? 0.0 : transitionDur
            let fadeOut = isLast ? 0.0 : transitionDur

            // Background overlay (for layouts that need it)
            if preset.needsBackground {
                var bg: [String: Any] = [
                    "backgroundColor": style.background,
                    "start": entry.start,
                    "end": entry.end,
                    "x": 0, "y": 0, "width": 1.0, "height": 1.0,
                    "zIndex": 0,
                ]
                if fadeIn > 0 { bg["fadeIn"] = fadeIn }
                if fadeOut > 0 { bg["fadeOut"] = fadeOut }
                overlays.append(bg)
            }

            // Screen overlay
            if !preset.screen.isHidden {
                var screen: [String: Any] = [
                    "sourceId": screenId,
                    "start": entry.start,
                    "end": entry.end,
                    "sourceStart": entry.start,
                    "x": preset.screen.x,
                    "y": preset.screen.y,
                    "width": preset.screen.width,
                    "height": preset.screen.height,
                    "audio": 0,
                    "zIndex": 1,
                ]
                if preset.screen.cornerRadius > 0 {
                    screen["cornerRadius"] = preset.screen.cornerRadius
                }
                if fadeIn > 0 { screen["fadeIn"] = fadeIn }
                if fadeOut > 0 { screen["fadeOut"] = fadeOut }
                overlays.append(screen)
            }

            // Speaker overlay
            if !preset.speaker.isHidden {
                var speaker: [String: Any] = [
                    "sourceId": speakerId,
                    "start": entry.start,
                    "end": entry.end,
                    "sourceStart": entry.start,
                    "x": preset.speaker.x,
                    "y": preset.speaker.y,
                    "width": preset.speaker.width,
                    "height": preset.speaker.height,
                    "audio": 0,
                    "zIndex": 2,
                ]
                let cr = preset.speaker.cornerRadius > 0 ? preset.speaker.cornerRadius : style.cornerRadius
                if cr > 0 { speaker["cornerRadius"] = cr }
                if let crop = style.speakerCrop {
                    speaker["crop"] = [
                        "x": crop.x, "y": crop.y,
                        "width": crop.width, "height": crop.height
                    ]
                }
                if fadeIn > 0 { speaker["fadeIn"] = fadeIn }
                if fadeOut > 0 { speaker["fadeOut"] = fadeOut }
                overlays.append(speaker)
            }
        }

        // Build response
        let response: [String: Any] = [
            "overlays": overlays,
            "layout_count": timeline.count,
            "notes": buildNotes(timeline: timeline, screenId: screenId, speakerId: speakerId)
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return self.error("JSON serialization failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static func buildNotes(timeline: [TimelineEntry], screenId: String, speakerId: String) -> String {
        let layouts = timeline.map { $0.layout }
        let totalDuration = timeline.map { $0.end - $0.start }.reduce(0, +)
        let uniqueLayouts = Set(layouts).sorted()

        var notes = "\(timeline.count) layout section\(timeline.count == 1 ? "" : "s")"
        notes += " (\(uniqueLayouts.joined(separator: ", ")))"
        notes += ", \(String(format: "%.1f", totalDuration))s total."
        notes += " Screen source \"\(screenId)\" as base segment provides audio."
        notes += " Speaker source \"\(speakerId)\" overlaid."
        return notes
    }

    private static func error(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
