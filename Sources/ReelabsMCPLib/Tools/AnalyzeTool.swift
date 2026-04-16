import Foundation
import MCP
import AVFoundation

package enum AnalyzeTool {
    package static let tool = Tool(
        name: "reelabs_analyze",
        description: "Analyze video visually. Actions: extract (path, sample_fps? — extracts frames to disk), store (analysis_id, scenes[] — persist sub-agent scene analysis), get (id — retrieve analysis + scenes).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("Action to perform: extract, store, get"),
                    "enum": .array([.string("extract"), .string("store"), .string("get")])
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to video file (for extract)")
                ]),
                "sample_fps": .object([
                    "type": .string("number"),
                    "description": .string("Frames per second to sample (default: 1.0)")
                ]),
                "asset_id": .object([
                    "type": .string("integer"),
                    "description": .string("Optional asset ID to link analysis to (for extract)")
                ]),
                "analysis_id": .object([
                    "type": .string("integer"),
                    "description": .string("Analysis ID (for store, get)")
                ]),
                "id": .object([
                    "type": .string("integer"),
                    "description": .string("Analysis ID (alias for analysis_id, for get)")
                ]),
                "scenes": .object([
                    "type": .string("array"),
                    "description": .string("Array of scene objects from sub-agent analysis (for store)"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "start_time": .object(["type": .string("number")]),
                            "end_time": .object(["type": .string("number")]),
                            "description": .object(["type": .string("string")]),
                            "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                            "scene_type": .object(["type": .string("string")])
                        ])
                    ])
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    package static func handle(arguments: [String: Value]?, analysisRepo: VisualAnalysisRepository) async -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: action", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            switch action {
            case "extract":
                return try await handleExtract(arguments: arguments, repo: analysisRepo)
            case "store":
                return try handleStore(arguments: arguments, repo: analysisRepo)
            case "get":
                return try handleGet(arguments: arguments, repo: analysisRepo)
            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: extract, store, get", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleExtract(arguments: [String: Value]?, repo: VisualAnalysisRepository) async throws -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: path", annotations: nil, _meta: nil)], isError: true)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .init(content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)], isError: true)
        }

        let sampleFps = extractDouble(arguments?["sample_fps"]) ?? 1.0
        let assetId = extractInt64(arguments?["asset_id"])

        // Get duration
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Create DB record
        var analysis = VisualAnalysis(sourcePath: path, sampleFps: sampleFps, assetId: assetId)
        analysis.durationSeconds = durationSeconds
        analysis = try repo.create(analysis)

        let analysisId = analysis.id!

        // Create frames directory in the working directory (visible and user-deletable)
        let framesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Extracted Frames", isDirectory: true)
            .appendingPathComponent("\(analysisId)", isDirectory: true)

        // Extract frames
        let frames = try await FrameExtractor.extractFrames(
            videoPath: path,
            sampleFps: sampleFps,
            outputDir: framesDir
        )

        // Update record
        try repo.update(id: analysisId, frameCount: frames.count, framesDir: framesDir.path, status: "extracted")

        // Build response
        let framesJson = frames.map { frame in
            ["time": frame.time, "path": frame.path] as [String: Any]
        }

        let instructions = """
        VISUAL ANALYSIS INSTRUCTIONS

        These are sequential frames extracted from a video at \(sampleFps) fps (\(String(format: "%.1f", (durationSeconds * 10).rounded() / 10))s total). \
        They are a temporal sequence — not independent images. Analyze them as a video.

        HOW TO ANALYZE:
        1. Scan all frames in order. Identify where the visual content meaningfully changes — \
        these are your scene boundaries. Consecutive frames showing the same setup, \
        speaker position, and background are ONE scene, not separate observations.
        2. For each scene, describe what is visually happening using the FIRST frame where \
        it appears. Do not repeat the same description across multiple scenes.
        3. Note transitions: what changed from the previous scene? New speaker position, \
        cut to screen recording, camera angle change, new location, graphic overlay, etc.

        WHAT TO OUTPUT:
        Call reelabs_analyze with action "store" and analysis_id \(analysisId). Provide a scenes array where each scene has:
        - start_time: timestamp of the first frame in the scene
        - end_time: timestamp of the last frame in the scene (or start of next scene)
        - description: what is visually happening (1-2 sentences max). Focus on content \
        useful for editing decisions — who/what is on screen, framing, on-screen text, \
        visual quality issues (overexposed, blurry, etc.)
        - scene_type: one of "talking_head", "b_roll", "screen_recording", "title_card", \
        "transition", "demo", "interview", "other"
        - tags: short descriptive tags for searchability (e.g. ["wide_shot", "outdoors", "product_demo"])

        EFFICIENCY RULES:
        - A 2-minute talking head with the same framing is ONE scene, not 120 frames described individually.
        - Only create a new scene when something visually changes on screen.
        - Typical videos have 3-15 scenes, not one per frame.
        - If the entire video is a single static setup, that is 1 scene. That's fine.
        """

        let response: [String: Any] = [
            "analysis_id": analysisId,
            "duration_seconds": (durationSeconds * 10).rounded() / 10,
            "frame_count": frames.count,
            "sample_fps": sampleFps,
            "frames_dir": framesDir.path,
            "frames": framesJson,
            "instructions": instructions
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        return .init(content: [.text(text: jsonString, annotations: nil, _meta: nil)], isError: false)
    }

    private static func handleStore(arguments: [String: Value]?, repo: VisualAnalysisRepository) throws -> CallTool.Result {
        guard let analysisId = extractInt64(arguments?["analysis_id"]) else {
            return .init(content: [.text(text: "Missing required argument: analysis_id", annotations: nil, _meta: nil)], isError: true)
        }

        guard let scenesValue = arguments?["scenes"]?.arrayValue else {
            return .init(content: [.text(text: "Missing required argument: scenes", annotations: nil, _meta: nil)], isError: true)
        }

        guard try repo.get(id: analysisId) != nil else {
            return .init(content: [.text(text: "Analysis not found: \(analysisId)", annotations: nil, _meta: nil)], isError: true)
        }

        var scenes: [VisualScene] = []
        for (index, sceneValue) in scenesValue.enumerated() {
            guard let startTime = extractDouble(sceneValue.objectValue?["start_time"]),
                  let endTime = extractDouble(sceneValue.objectValue?["end_time"]),
                  let description = sceneValue.objectValue?["description"]?.stringValue else {
                return .init(content: [.text(text: "Scene \(index) missing required fields: start_time, end_time, description", annotations: nil, _meta: nil)], isError: true)
            }

            var tagsJson: String? = nil
            if let tagsArray = sceneValue.objectValue?["tags"]?.arrayValue {
                let tags = tagsArray.compactMap { $0.stringValue }
                if let data = try? JSONEncoder().encode(tags) {
                    tagsJson = String(data: data, encoding: .utf8)
                }
            }

            let sceneType = sceneValue.objectValue?["scene_type"]?.stringValue

            scenes.append(VisualScene(
                analysisId: analysisId,
                sceneIndex: index,
                startTime: startTime,
                endTime: endTime,
                description: description,
                tags: tagsJson,
                sceneType: sceneType
            ))
        }

        try repo.storeScenes(analysisId: analysisId, scenes: scenes)

        let response: [String: Any] = [
            "analysis_id": analysisId,
            "scenes_stored": scenes.count,
            "status": "analyzed"
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        return .init(content: [.text(text: jsonString, annotations: nil, _meta: nil)], isError: false)
    }

    private static func handleGet(arguments: [String: Value]?, repo: VisualAnalysisRepository) throws -> CallTool.Result {
        let analysisId = extractInt64(arguments?["id"]) ?? extractInt64(arguments?["analysis_id"])
        guard let analysisId else {
            return .init(content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)], isError: true)
        }

        guard let analysis = try repo.get(id: analysisId) else {
            return .init(content: [.text(text: "Analysis not found: \(analysisId)", annotations: nil, _meta: nil)], isError: true)
        }

        let scenes = try repo.getScenes(analysisId: analysisId)

        let scenesJson: [[String: Any]] = scenes.map { scene in
            var dict: [String: Any] = [
                "scene_index": scene.sceneIndex,
                "start_time": scene.startTime,
                "end_time": scene.endTime,
                "description": scene.description
            ]
            if let tags = scene.tags,
               let data = tags.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                dict["tags"] = parsed
            }
            if let sceneType = scene.sceneType {
                dict["scene_type"] = sceneType
            }
            return dict
        }

        let response: [String: Any] = [
            "analysis_id": analysis.id!,
            "source_path": analysis.sourcePath,
            "status": analysis.status,
            "sample_fps": analysis.sampleFps,
            "duration_seconds": analysis.durationSeconds,
            "frame_count": analysis.frameCount,
            "scene_count": analysis.sceneCount,
            "frames_dir": analysis.framesDir,
            "scenes": scenesJson
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        return .init(content: [.text(text: jsonString, annotations: nil, _meta: nil)], isError: false)
    }
}
