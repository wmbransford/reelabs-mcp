import Foundation

package enum DefaultPresets {
    package static func seed(store: PresetStore) throws {
        // Always upsert defaults to keep presets current

        let tiktok: [String: Any] = [
            "fontFamily": "Arial",
            "fontSize": 7.0,
            "fontWeight": "bold",
            "color": "#FFFFFF",
            "highlightColor": "#FFD700",
            "position": 70.0,
            "allCaps": true,
            "shadow": true,
            "wordsPerGroup": 3,
            "punctuation": true
        ]

        let subtitle: [String: Any] = [
            "fontFamily": "Helvetica",
            "fontSize": 4.5,
            "fontWeight": "medium",
            "color": "#FFFFFF",
            "position": 90.0,
            "allCaps": false,
            "shadow": true,
            "wordsPerGroup": 6,
            "punctuation": true
        ]

        let minimal: [String: Any] = [
            "fontFamily": "Helvetica",
            "fontSize": 4.0,
            "fontWeight": "light",
            "color": "#FFFFFF",
            "position": 85.0,
            "allCaps": false,
            "shadow": false,
            "wordsPerGroup": 4,
            "punctuation": true
        ]

        let boldCenter: [String: Any] = [
            "fontFamily": "Arial",
            "fontSize": 8.0,
            "fontWeight": "bold",
            "color": "#FFFFFF",
            "highlightColor": "#00FF88",
            "position": 50.0,
            "allCaps": true,
            "shadow": true,
            "wordsPerGroup": 2,
            "punctuation": true
        ]

        let william: [String: Any] = [
            "fontFamily": "Poppins",
            "fontSize": 7.0,
            "fontWeight": "bold",
            "color": "#FAF9F5",
            "highlightColor": "#D97757",
            "position": 70.0,
            "allCaps": true,
            "shadow": true,
            "wordsPerGroup": 3,
            "punctuation": false
        ]

        let presets: [(String, String, [String: Any], String)] = [
            ("tiktok", "caption", tiktok, "Bold centered captions for TikTok/Reels — yellow highlight, 3 words"),
            ("subtitle", "caption", subtitle, "Professional subtitle style — bottom-aligned, 6 words per group"),
            ("minimal", "caption", minimal, "Understated minimal captions — light font, no shadow"),
            ("bold_center", "caption", boldCenter, "Bold centered captions — green highlight, 2 words per group"),
            ("william", "caption", william, "Poppins bold, cream/burnt orange karaoke — 3 words, no punctuation"),
        ]

        for (name, type, config, desc) in presets {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            let json = String(data: data, encoding: .utf8) ?? "{}"
            _ = try store.save(name: name, type: type, configJson: json, description: desc)
        }
    }
}
