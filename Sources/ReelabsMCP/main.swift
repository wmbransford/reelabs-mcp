import Foundation
import Logging
import MCP
import ReelabsMCPLib

// MARK: - Subcommands (--help only — no more auth handshake)

if CommandLine.arguments.count >= 2 {
    let sub = CommandLine.arguments[1]
    switch sub {
    case "--help", "-h", "help":
        printUsage()
        exit(0)
    default:
        // Fall through — unknown flags like --port are handled below.
        break
    }
}

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

// Shared SQLite database (ProjectStore uses this; other stores still use paths during migration).
let database = try Database(root: dataRoot)

let projectStore = ProjectStore(database: database)
let assetStore = AssetStore(database: database)
let transcriptStore = TranscriptStore(database: database)
let renderStore = RenderStore(database: database)
let presetStore = PresetStore(database: database)
let analysisStore = AnalysisStore(database: database)

// Seed default presets on first run
try DefaultPresets.seed(store: presetStore)

// Seed bundled kits — built-ins are always upserted, user-created kits are left alone
try DefaultKits.seed(kitsDir: paths.kitsDir)

// MARK: - GCP authenticator (service-account-backed, single instance for token caching)

let authenticator: GoogleAuthenticator? = {
    guard let credentialsPath = config.gcpCredentialsPath, !credentialsPath.isEmpty else {
        return nil
    }
    do {
        return try GoogleAuthenticator(keyPath: credentialsPath)
    } catch {
        Logger(label: "reelabs.startup").error("Failed to load GCP credentials: \(error.localizedDescription)")
        return nil
    }
}()

// MARK: - Startup Validation

do {
    let startupLogger = Logger(label: "reelabs.startup")
    startupLogger.info("ReeLabs MCP v2.0.0 — markdown data store")
    startupLogger.info("Config: \(loadResult.configSource)")
    startupLogger.info("Data root: \(dataRoot.path)")

    if authenticator != nil, let path = config.gcpCredentialsPath {
        startupLogger.info("GCP credentials: \(path)")
    } else {
        startupLogger.warning("GCP credentials: not set (transcription disabled — set GOOGLE_APPLICATION_CREDENTIALS or gcp_credentials_path in config.json)")
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
                config: config,
                authenticator: authenticator
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
                paths: paths,
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
            return await GraphicTool.handle(arguments: params.arguments, paths: paths)

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

// MARK: - Subcommand implementations

func printUsage() {
    print("""
    reelabs-mcp — native video editing for Claude.

    Usage:
      reelabs-mcp                 Run the MCP server (default)
      reelabs-mcp --port <n>      Run the MCP server on a custom port
      reelabs-mcp --help          Show this message

    Transcription auth: set GOOGLE_APPLICATION_CREDENTIALS to a GCP service-account
    key with Speech-to-Text access, or add `gcp_credentials_path` to config.json.
    """)
}
