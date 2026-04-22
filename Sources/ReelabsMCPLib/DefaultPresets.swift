import Foundation

package enum DefaultPresets {
    package static func seed(store: PresetStore) throws {
        // Always upsert defaults to keep presets current

        let tiktok: [String: Any] = [
            "fontFamily": "Arial",
            "fontSize": 5.5,
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
            "fontSize": 7.0,
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
            "fontSize": 5.5,
            "fontWeight": "bold",
            "color": "#FAF9F5",
            "highlightColor": "#D97757",
            "position": 70.0,
            "allCaps": true,
            "shadow": true,
            "wordsPerGroup": 3,
            "punctuation": false
        ]

        let socialKaraokePink: [String: Any] = [
            "fontFamily": "Poppins",
            "fontSize": 5.5,
            "fontWeight": "bold",
            "color": "#FAF9F5",
            "highlightColor": "#FF3EA5",
            "position": 70.0,
            "allCaps": true,
            "shadow": true,
            "wordsPerGroup": 3,
            "punctuation": false
        ]

        let socialKaraokeWhite: [String: Any] = [
            "fontFamily": "Poppins",
            "fontSize": 5.5,
            "fontWeight": "bold",
            "color": "#AAAAAA",
            "highlightColor": "#FFFFFF",
            "position": 70.0,
            "allCaps": true,
            "shadow": true,
            "wordsPerGroup": 3,
            "punctuation": false
        ]

        let interviewAttribution: [String: Any] = [
            "fontFamily": "Helvetica",
            "fontSize": 4.0,
            "fontWeight": "medium",
            "color": "#FFFFFF",
            "position": 90.0,
            "allCaps": false,
            "shadow": true,
            "wordsPerGroup": 8,
            "punctuation": true
        ]

        let podcastBig: [String: Any] = [
            "fontFamily": "Helvetica",
            "fontSize": 10.0,
            "fontWeight": "black",
            "color": "#FFFFFF",
            "highlightColor": "#FFE135",
            "position": 50.0,
            "allCaps": true,
            "shadow": true,
            "wordsPerGroup": 2,
            "punctuation": false
        ]

        let slideshowSerif: [String: Any] = [
            "fontFamily": "Georgia",
            "fontSize": 4.5,
            "fontWeight": "regular",
            "color": "#FFFFFF",
            "position": 88.0,
            "allCaps": false,
            "shadow": true,
            "wordsPerGroup": 7,
            "punctuation": true
        ]

        let screencastClean: [String: Any] = [
            "fontFamily": "Helvetica",
            "fontSize": 4.0,
            "fontWeight": "medium",
            "color": "#FFFFFF",
            "position": 92.0,
            "allCaps": false,
            "shadow": true,
            "wordsPerGroup": 8,
            "punctuation": true
        ]

        let presets: [(String, String, [String: Any], String)] = [
            ("tiktok", "caption", tiktok, "Bold centered captions for TikTok/Reels — yellow highlight, 3 words"),
            ("subtitle", "caption", subtitle, "Professional subtitle style — bottom-aligned, 6 words per group"),
            ("minimal", "caption", minimal, "Understated minimal captions — light font, no shadow"),
            ("bold_center", "caption", boldCenter, "Bold centered captions — green highlight, 2 words per group"),
            ("william", "caption", william, "Poppins bold, cream/burnt orange karaoke — 3 words, no punctuation"),
            ("social_karaoke_pink", "caption", socialKaraokePink, "Pink-highlight karaoke variant of william — Poppins bold, hot pink active word"),
            ("social_karaoke_white", "caption", socialKaraokeWhite, "Monochrome karaoke — white Poppins bold, no colored highlight"),
            ("interview_attribution", "caption", interviewAttribution, "Understated interview captions — bottom, Helvetica medium, 8 words"),
            ("podcast_big", "caption", podcastBig, "Oversized podcast captions — centered black Helvetica, yellow highlight, 2 words"),
            ("slideshow_serif", "caption", slideshowSerif, "Clean serif lower-third — Georgia regular, 7 words per group"),
            ("screencast_clean", "caption", screencastClean, "Low-distraction screencast captions — Helvetica medium at 92% height, 8 words"),
        ]

        for (name, type, config, desc) in presets {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            let json = String(data: data, encoding: .utf8) ?? "{}"
            _ = try store.upsert(name: name, type: type, configJson: json, description: desc)
        }
    }
}
