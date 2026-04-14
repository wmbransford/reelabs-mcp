import Foundation
import MCP
import GRDB

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

// Seed default presets on first run
try DefaultPresets.seed(repo: presetRepo)

// Create MCP server
let server = Server(
    name: "reelabs-mcp",
    version: "2.0.0",
    capabilities: Server.Capabilities(
        tools: .init(listChanged: true)
    )
)

// Register tool listing
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
    ])
}

// Register tool dispatch
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

    default:
        return .init(
            content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

// Start stdio transport
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
