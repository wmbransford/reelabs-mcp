import AVFoundation
import Foundation
import MCP

package enum AnalyzeTool {
    package static let tool = Tool(
        name: "reelabs_analyze",
        description: "Analyze video visually. Actions: extract (path, sample_fps?, face_backend?, face_sample_fps? — extracts frames to disk and optionally runs Apple Vision face detection), store (analysis_id, scenes[] — persist sub-agent scene analysis), get (analysis_id — retrieve analysis + scenes + face positions). analysis_id is a compound 'project/source' string.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "description": .string("Action: extract, store, get"),
                    "enum": .array([.string("extract"), .string("store"), .string("get")])
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to video file (for extract)")
                ]),
                "sample_fps": .object([
                    "type": .string("number"),
                    "description": .string("Frames per second to sample for JPEG extraction (default: 1.0). This is the agent-readable sample rate.")
                ]),
                "face_backend": .object([
                    "type": .string("string"),
                    "description": .string("Face detection backend: 'vision' (Apple Vision, default — deterministic, fast, runs straight from the video) or 'claude' (agent-only, legacy)."),
                    "enum": .array([.string("vision"), .string("claude")])
                ]),
                "face_sample_fps": .object([
                    "type": .string("number"),
                    "description": .string("Sample rate (fps) for Apple Vision face detection, independent of JPEG sample_fps (default: 2.0). Denser = tighter gesture tracking at render time.")
                ]),
                "project": .object([
                    "type": .string("string"),
                    "description": .string("Optional project slug for extract. Derived from parent dir if omitted.")
                ]),
                "analysis_id": .object([
                    "type": .string("string"),
                    "description": .string("Compound 'project/source' ID (for store, get)")
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
                            "scene_type": .object(["type": .string("string")]),
                            "focus_point": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "x": .object(["type": .string("number")]),
                                    "y": .object(["type": .string("number")])
                                ])
                            ]),
                        ])
                    ])
                ])
            ]),
            "required": .array([.string("action")])
        ])
    )

    package static func handle(
        arguments: [String: Value]?,
        paths: DataPaths,
        analysisStore: AnalysisStore,
        projectStore: ProjectStore
    ) async -> CallTool.Result {
        guard let action = arguments?["action"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: action", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            switch action {
            case "extract":
                return try await handleExtract(arguments: arguments, paths: paths, analysisStore: analysisStore, projectStore: projectStore)
            case "store":
                return try handleStore(arguments: arguments, store: analysisStore)
            case "get":
                return try handleGet(arguments: arguments, store: analysisStore)
            default:
                return .init(content: [.text(text: "Unknown action: \(action). Use: extract, store, get", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleExtract(
        arguments: [String: Value]?,
        paths: DataPaths,
        analysisStore: AnalysisStore,
        projectStore: ProjectStore
    ) async throws -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: path", annotations: nil, _meta: nil)], isError: true)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .init(content: [.text(text: "File not found: \(path)", annotations: nil, _meta: nil)], isError: true)
        }

        let sampleFps = extractDouble(arguments?["sample_fps"]) ?? 1.0
        let faceBackend = arguments?["face_backend"]?.stringValue ?? "vision"
        let faceSampleFps = extractDouble(arguments?["face_sample_fps"]) ?? 2.0
        let projectSlug = arguments?["project"]?.stringValue ?? DataPaths.deriveProjectSlug(fromSourcePath: path)
        let sourceSlug = DataPaths.deriveSourceSlug(fromSourcePath: path)

        _ = try projectStore.createWithSlug(slug: projectSlug)

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        let framesDir = paths.framesDir
            .appendingPathComponent("\(projectSlug)-\(sourceSlug)", isDirectory: true)

        let frames = try await FrameExtractor.extractFrames(
            videoPath: path,
            sampleFps: sampleFps,
            outputDir: framesDir
        )

        var faceResult: FaceDetectionResult?
        if faceBackend == "vision" {
            faceResult = try await FaceDetector.detect(videoPath: path, sampleFps: faceSampleFps)
            if let result = faceResult {
                try analysisStore.storeFaces(project: projectSlug, source: sourceSlug, result: result)
            }
        }

        var record = AnalysisRecord(
            slug: sourceSlug,
            sourcePath: path,
            status: "extracted",
            sampleFps: sampleFps,
            frameCount: frames.count,
            sceneCount: 0,
            durationSeconds: durationSeconds,
            framesDir: framesDir.path
        )
        record = try analysisStore.saveRecord(project: projectSlug, source: sourceSlug, record: record)

        let analysisId = "\(projectSlug)/\(sourceSlug)"
        let framesJson = frames.map { frame in
            ["time": frame.time, "path": frame.path] as [String: Any]
        }

        let instructions = buildInstructions(
            analysisId: analysisId,
            sampleFps: sampleFps,
            durationSeconds: durationSeconds,
            faceResult: faceResult
        )

        var response: [String: Any] = [
            "analysis_id": analysisId,
            "project": projectSlug,
            "source": sourceSlug,
            "duration_seconds": (durationSeconds * 10).rounded() / 10,
            "frame_count": frames.count,
            "sample_fps": sampleFps,
            "face_backend": faceBackend,
            "frames_dir": framesDir.path,
            "frames": framesJson,
            "instructions": instructions
        ]

        if let result = faceResult {
            response["face_sample_fps"] = result.sampleFps
            response["face_frame_count"] = result.frameCount
            response["face_clusters"] = result.clusters.map { cluster -> [String: Any] in
                [
                    "id": cluster.id,
                    "median_center": ["x": cluster.medianCenter.x, "y": cluster.medianCenter.y],
                    "median_bbox": [
                        "x": cluster.medianBbox.x,
                        "y": cluster.medianBbox.y,
                        "w": cluster.medianBbox.w,
                        "h": cluster.medianBbox.h
                    ],
                    "visibility": cluster.visibility,
                    "frame_count": cluster.frameCount
                ]
            }
        }

        let jsonData = try safeJSONData(from: response)
        return .init(content: [.text(text: String(data: jsonData, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)
    }

    private static func buildInstructions(
        analysisId: String,
        sampleFps: Double,
        durationSeconds: Double,
        faceResult: FaceDetectionResult?
    ) -> String {
        let durationStr = String(format: "%.1f", (durationSeconds * 10).rounded() / 10)

        if let result = faceResult, !result.clusters.isEmpty {
            let positionsSummary = result.clusters.map { cluster -> String in
                let x = String(format: "%.2f", cluster.medianCenter.x)
                let y = String(format: "%.2f", cluster.medianCenter.y)
                let vis = String(format: "%.0f", cluster.visibility * 100)
                return "  - face position (\(x), \(y)) — seen in \(vis)% of sampled frames"
            }.joined(separator: "\n")

            return """
            VISUAL ANALYSIS INSTRUCTIONS (Vision-assisted)

            Apple Vision pre-detected these distinct face positions across the video (sampled at \(result.sampleFps) fps). These positions are ground truth — do not re-estimate face coordinates:

            \(positionsSummary)

            JPEG frames for your semantic review were extracted at \(sampleFps) fps (\(durationStr)s total). They are a temporal sequence — analyze them as video.

            YOUR JOB:
            1. Scan the extracted JPEG frames in order. Identify where visual content meaningfully changes — these are scene boundaries. Consecutive frames with the same composition = ONE scene.
            2. For each scene, describe it briefly (1–2 sentences) and classify scene_type.
            3. For each scene with a human subject, pick the face position from the list above that is the subject of that scene (the speaker, the one in motion, the dominant face). Copy its (x, y) into `focus_point`. For b-roll, title cards, or scenes with no face subject, omit `focus_point`.

            WHAT TO OUTPUT:
            Call reelabs_analyze with action "store" and analysis_id "\(analysisId)". Each scene has:
            - start_time, end_time: scene boundaries in seconds
            - description: 1–2 sentences
            - scene_type: one of "talking_head", "b_roll", "screen_recording", "title_card", "transition", "demo", "interview", "other"
            - tags: short descriptive tags
            - focus_point: optional {x, y} — the face position from the list above that is the subject of this scene. Omit for scenes with no face subject.

            Coords are top-left normalized 0–1 (0,0 = top-left corner). Do NOT output names, cluster IDs, or per-subject arrays — just the focus_point.
            """
        }

        return """
        VISUAL ANALYSIS INSTRUCTIONS

        These are sequential frames extracted from a video at \(sampleFps) fps (\(durationStr)s total). \
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
        Call reelabs_analyze with action "store" and analysis_id "\(analysisId)". Provide a scenes array where each scene has:
        - start_time: timestamp of the first frame in the scene
        - end_time: timestamp of the last frame in the scene (or start of next scene)
        - description: what is visually happening (1-2 sentences max).
        - scene_type: one of "talking_head", "b_roll", "screen_recording", "title_card", \
        "transition", "demo", "interview", "other"
        - tags: short descriptive tags for searchability
        - focus_point: optional {x, y} in normalized 0-1 coordinates (0,0 = top-left) marking \
        the primary visual subject in the scene's first frame. If the primary subject is a \
        person, the focus point is their FACE — not their torso, shoulders, or the center of \
        their body. For scenes with multiple people, pick the active speaker or the most \
        prominent face. For b-roll, title cards, or scenes with no clear subject, omit the \
        field (or set to {0.5, 0.5} for dead center).
        """
    }

    private static func handleStore(arguments: [String: Value]?, store: AnalysisStore) throws -> CallTool.Result {
        guard let id = arguments?["analysis_id"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: analysis_id", annotations: nil, _meta: nil)], isError: true)
        }
        guard let parts = DataPaths.splitCompoundId(id) else {
            return .init(content: [.text(text: "Invalid analysis_id. Expected 'project/source'.", annotations: nil, _meta: nil)], isError: true)
        }
        guard let scenesValue = arguments?["scenes"]?.arrayValue else {
            return .init(content: [.text(text: "Missing required argument: scenes", annotations: nil, _meta: nil)], isError: true)
        }

        guard try store.getRecord(project: parts.project, source: parts.source) != nil else {
            return .init(content: [.text(text: "Analysis not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }

        var scenes: [SceneRecord] = []
        for (index, sceneValue) in scenesValue.enumerated() {
            guard let startTime = extractDouble(sceneValue.objectValue?["start_time"]),
                  let endTime = extractDouble(sceneValue.objectValue?["end_time"]),
                  let description = sceneValue.objectValue?["description"]?.stringValue else {
                return .init(content: [.text(text: "Scene \(index) missing required fields: start_time, end_time, description", annotations: nil, _meta: nil)], isError: true)
            }
            let tags: [String]?
            if let tagsArray = sceneValue.objectValue?["tags"]?.arrayValue {
                tags = tagsArray.compactMap { $0.stringValue }
            } else {
                tags = nil
            }
            let sceneType = sceneValue.objectValue?["scene_type"]?.stringValue
            let focusPoint: FocusPoint?
            if let fp = sceneValue.objectValue?["focus_point"]?.objectValue,
               let fx = extractDouble(fp["x"]),
               let fy = extractDouble(fp["y"]) {
                focusPoint = FocusPoint(x: fx, y: fy)
            } else {
                focusPoint = nil
            }
            scenes.append(SceneRecord(
                sceneIndex: index,
                startTime: startTime,
                endTime: endTime,
                description: description,
                tags: tags,
                sceneType: sceneType,
                focusPoint: focusPoint
            ))
        }

        try store.storeScenes(project: parts.project, source: parts.source, scenes: scenes)

        let response: [String: Any] = [
            "analysis_id": id,
            "scenes_stored": scenes.count,
            "status": "analyzed"
        ]
        let data = try safeJSONData(from: response)
        return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)
    }

    private static func handleGet(arguments: [String: Value]?, store: AnalysisStore) throws -> CallTool.Result {
        guard let id = arguments?["analysis_id"]?.stringValue else {
            return .init(content: [.text(text: "Missing required argument: analysis_id", annotations: nil, _meta: nil)], isError: true)
        }
        guard let parts = DataPaths.splitCompoundId(id) else {
            return .init(content: [.text(text: "Invalid analysis_id. Expected 'project/source'.", annotations: nil, _meta: nil)], isError: true)
        }
        guard let analysis = try store.getRecord(project: parts.project, source: parts.source) else {
            return .init(content: [.text(text: "Analysis not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        let scenes = try store.getScenes(project: parts.project, source: parts.source)

        let scenesJson: [[String: Any]] = scenes.map { scene in
            var dict: [String: Any] = [
                "scene_index": scene.sceneIndex,
                "start_time": scene.startTime,
                "end_time": scene.endTime,
                "description": scene.description
            ]
            if let tags = scene.tags { dict["tags"] = tags }
            if let sceneType = scene.sceneType { dict["scene_type"] = sceneType }
            if let fp = scene.focusPoint {
                dict["focus_point"] = ["x": fp.x, "y": fp.y]
            }
            return dict
        }

        var response: [String: Any] = [
            "analysis_id": id,
            "project": parts.project,
            "source": parts.source,
            "source_path": analysis.sourcePath,
            "status": analysis.status,
            "sample_fps": analysis.sampleFps,
            "duration_seconds": analysis.durationSeconds,
            "frame_count": analysis.frameCount,
            "scene_count": analysis.sceneCount,
            "frames_dir": analysis.framesDir,
            "scenes": scenesJson
        ]

        if let faces = try store.getFaces(project: parts.project, source: parts.source) {
            response["face_sample_fps"] = faces.sampleFps
            response["face_frame_count"] = faces.frameCount
            response["face_clusters"] = faces.clusters.map { cluster -> [String: Any] in
                [
                    "id": cluster.id,
                    "median_center": ["x": cluster.medianCenter.x, "y": cluster.medianCenter.y],
                    "median_bbox": [
                        "x": cluster.medianBbox.x,
                        "y": cluster.medianBbox.y,
                        "w": cluster.medianBbox.w,
                        "h": cluster.medianBbox.h
                    ],
                    "visibility": cluster.visibility,
                    "frame_count": cluster.frameCount
                ]
            }
        }

        let data = try safeJSONData(from: response)
        return .init(content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)], isError: false)
    }

}
