import Foundation
import Logging
import MCP
import GRDB
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
    usleep(100_000) // 100ms for graceful shutdown
}
try "\(ProcessInfo.processInfo.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

// Load configuration
let config = ServerConfig.load()

// Initialize database
let db = try DatabaseManager(path: config.databasePath)

// Create repositories
let projectRepo = ProjectRepository(dbPool: db.dbPool)
let assetRepo = AssetRepository(dbPool: db.dbPool)
let transcriptRepo = TranscriptRepository(dbPool: db.dbPool)
let renderRepo = RenderRepository(dbPool: db.dbPool)
let presetRepo = PresetRepository(dbPool: db.dbPool)
let analysisRepo = VisualAnalysisRepository(dbPool: db.dbPool)

// Seed default presets on first run
try DefaultPresets.seed(repo: presetRepo)

// MARK: - Server Configuration

/// Registers all tools on a Server instance.
func configureServer(_ server: Server) async {
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            ProbeTool.tool,
            TranscribeTool.tool,
            RenderTool.tool,
            ValidateTool.tool,
            SearchTool.tool,
            ProjectTool.tool,
            AssetTool.tool,
            PresetTool.tool,
            SilenceRemoveTool.tool,
            AnalyzeTool.tool,
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "reelabs_probe":
            return await ProbeTool.handle(arguments: params.arguments)

        case "reelabs_transcribe":
            return await TranscribeTool.handle(arguments: params.arguments, transcriptRepo: transcriptRepo, config: config)

        case "reelabs_render":
            return await RenderTool.handle(arguments: params.arguments, renderRepo: renderRepo, transcriptRepo: transcriptRepo, presetRepo: presetRepo)

        case "reelabs_validate":
            return await ValidateTool.handle(arguments: params.arguments, transcriptRepo: transcriptRepo)

        case "reelabs_search":
            return SearchTool.handle(arguments: params.arguments, dbPool: db.dbPool)

        case "reelabs_project":
            return ProjectTool.handle(arguments: params.arguments, repo: projectRepo)

        case "reelabs_asset":
            return await AssetTool.handle(arguments: params.arguments, assetRepo: assetRepo)

        case "reelabs_preset":
            return PresetTool.handle(arguments: params.arguments, presetRepo: presetRepo)

        case "reelabs_silence_remove":
            return SilenceRemoveTool.handle(arguments: params.arguments, transcriptRepo: transcriptRepo)

        case "reelabs_analyze":
            return await AnalyzeTool.handle(arguments: params.arguments, analysisRepo: analysisRepo)

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
