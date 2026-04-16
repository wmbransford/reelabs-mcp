import Foundation
import Logging
import MCP
import ReelabsMCPLib

// --- PID file: kill any stale server before starting ---
let pidDir = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
).appendingPathComponent("ReelabsMCP", isDirectory: true)
try FileManager.default.createDirectory(at: pidDir, withIntermediateDirectories: true)
let pidFile = pidDir.appendingPathComponent("reelabs.pid")

if let oldPidString = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
   let oldPid = Int32(oldPidString),
   oldPid != ProcessInfo.processInfo.processIdentifier {
    kill(oldPid, SIGTERM)
    usleep(100_000)
}
try "\(ProcessInfo.processInfo.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

// Load configuration
let loadResult = ServerConfig.load()
let config = loadResult.config

// Initialize markdown data store
let dataRoot = config.resolveDataRoot()
try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
let paths = DataPaths(root: dataRoot)

let projectStore = ProjectStore(paths: paths)
let assetStore = AssetStore(paths: paths)
let transcriptStore = TranscriptStore(paths: paths)
let renderStore = RenderStore(paths: paths)
let presetStore = PresetStore(paths: paths)
let analysisStore = AnalysisStore(paths: paths)

// Seed default presets on first run
try DefaultPresets.seed(store: presetStore)

// MARK: - Startup Validation

do {
    let startupLogger = Logger(label: "reelabs.startup")
    startupLogger.info("ReeLabs MCP v2.0.0 — markdown data store")
    startupLogger.info("Config: \(loadResult.configSource)")
    startupLogger.info("Data root: \(dataRoot.path)")

    if let saPath = config.serviceAccountPath {
        let readable = FileManager.default.isReadableFile(atPath: saPath)
        startupLogger.info("Service account: \(saPath) (readable: \(readable))")
    } else {
        startupLogger.warning("Service account: not configured (transcription disabled)")
    }
}

// MARK: - Server Configuration

func configureServer(_ server: Server) async {
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            ProbeTool.tool,
            TranscribeTool.tool,
            TranscriptTool.tool,
            RenderTool.tool,
            ValidateTool.tool,
            ProjectTool.tool,
            AssetTool.tool,
            PresetTool.tool,
            SilenceRemoveTool.tool,
            AnalyzeTool.tool,
            RerenderTool.tool,
            GraphicTool.tool,
            LayoutTool.tool,
            ExtractAudioTool.tool,
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "reelabs_probe":
            return await ProbeTool.handle(arguments: params.arguments)

        case "reelabs_transcribe":
            return await TranscribeTool.handle(
                arguments: params.arguments,
                transcriptStore: transcriptStore,
                projectStore: projectStore,
                config: config
            )

        case "reelabs_transcript":
            return TranscriptTool.handle(arguments: params.arguments, store: transcriptStore)

        case "reelabs_render":
            return await RenderTool.handle(
                arguments: params.arguments,
                renderStore: renderStore,
                transcriptStore: transcriptStore,
                projectStore: projectStore,
                presetStore: presetStore
            )

        case "reelabs_validate":
            return await ValidateTool.handle(arguments: params.arguments, transcriptStore: transcriptStore)

        case "reelabs_project":
            return ProjectTool.handle(arguments: params.arguments, store: projectStore)

        case "reelabs_asset":
            return await AssetTool.handle(
                arguments: params.arguments,
                assetStore: assetStore,
                projectStore: projectStore
            )

        case "reelabs_preset":
            return PresetTool.handle(arguments: params.arguments, store: presetStore)

        case "reelabs_silence_remove":
            return SilenceRemoveTool.handle(arguments: params.arguments, store: transcriptStore)

        case "reelabs_analyze":
            return await AnalyzeTool.handle(
                arguments: params.arguments,
                analysisStore: analysisStore,
                projectStore: projectStore
            )

        case "reelabs_rerender":
            return await RerenderTool.handle(
                arguments: params.arguments,
                renderStore: renderStore,
                transcriptStore: transcriptStore,
                projectStore: projectStore,
                presetStore: presetStore
            )

        case "reelabs_graphic":
            return await GraphicTool.handle(arguments: params.arguments)

        case "reelabs_layout":
            return LayoutTool.handle(arguments: params.arguments)

        case "reelabs_extract_audio":
            return await ExtractAudioTool.handle(arguments: params.arguments)

        default:
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }
}

// MARK: - CLI Arguments

var port: Int = config.httpPort ?? 52849
if let portIdx = CommandLine.arguments.firstIndex(of: "--port"), portIdx + 1 < CommandLine.arguments.count,
   let p = Int(CommandLine.arguments[portIdx + 1]) {
    port = p
}

let host = config.httpHost ?? "127.0.0.1"

Logger(label: "reelabs.startup").info("Server: \(host):\(port)")

// MARK: - Start HTTP Server

let httpServer = HTTPServer(
    configuration: .init(host: host, port: port),
    serverFactory: { sessionID, transport in
        let server = Server(
            name: "reelabs-mcp",
            version: "2.0.0",
            capabilities: Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )
        await configureServer(server)
        return server
    },
    logger: Logger(label: "reelabs.mcp")
)

try await httpServer.start()
