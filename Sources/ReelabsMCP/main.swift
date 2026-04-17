import Foundation
import Logging
import MCP
import ReelabsMCPLib

// MARK: - Subcommands (sign-in, sign-out, whoami)

if CommandLine.arguments.count >= 2 {
    let sub = CommandLine.arguments[1]
    switch sub {
    case "sign-in":
        await runSignIn()
        exit(0)
    case "sign-out":
        await runSignOut()
        exit(0)
    case "whoami":
        await runWhoAmI()
        exit(0)
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

let projectStore = ProjectStore(paths: paths)
let assetStore = AssetStore(paths: paths)
let transcriptStore = TranscriptStore(paths: paths)
let renderStore = RenderStore(paths: paths)
let presetStore = PresetStore(paths: paths)
let analysisStore = AnalysisStore(paths: paths)

// Seed bundled resources — built-ins are always upserted, user-created files are left alone
try DefaultBundledPresets.seed(presetsDir: paths.presetsDir)
try DefaultFlows.seed(flowsDir: paths.flowsDir)
try DefaultReference.seed(referenceDir: paths.referenceDir)
try DefaultClaudeMd.seed(dataRoot: dataRoot)

// MARK: - Startup Validation

do {
    let startupLogger = Logger(label: "reelabs.startup")
    startupLogger.info("ReeLabs MCP v2.0.0 — markdown data store")
    startupLogger.info("Config: \(loadResult.configSource)")
    startupLogger.info("Data root: \(dataRoot.path)")

    let tokenPresent = ((try? TokenKeychain.read()) ?? nil)?.isEmpty == false
    if tokenPresent {
        startupLogger.info("API token: present in keychain")
    } else {
        startupLogger.warning("API token: not set (transcription disabled — run `reelabs-mcp sign-in`)")
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
            SpeakerDetectTool.tool,
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

        case "reelabs_speaker_detect":
            return SpeakerDetectTool.handle(arguments: params.arguments, store: transcriptStore)

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
      reelabs-mcp sign-in         Connect this device to your ReeLabs account
      reelabs-mcp sign-out        Remove the stored API token
      reelabs-mcp whoami          Show whether the device is signed in
      reelabs-mcp --port <n>      Run the MCP server on a custom port
      reelabs-mcp --help          Show this message
    """)
}

func runSignIn() async {
    let flow = DeviceCodeFlow()
    let start: DeviceCodeFlow.Start
    do {
        start = try await flow.start()
    } catch {
        print("Failed to start sign-in: \(error.localizedDescription)")
        exit(1)
    }

    print("""

    To connect this device, open the URL below in a browser:

      \(start.verificationUriComplete)

    Confirm the code: \(start.userCode)

    Waiting for sign-in…
    """)

    // Best-effort: open the activation URL in the default browser.
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = [start.verificationUriComplete]
    try? task.run()

    do {
        let activated = try await flow.pollUntilActivated(start: start)
        try TokenKeychain.write(activated.apiToken)
        print("\n✓ Device connected. You're signed in.")
    } catch {
        print("\nSign-in failed: \(error.localizedDescription)")
        exit(1)
    }
}

func runSignOut() async {
    do {
        try TokenKeychain.delete()
        print("Signed out.")
    } catch {
        print("Failed to sign out: \(error.localizedDescription)")
        exit(1)
    }
}

func runWhoAmI() async {
    let token = (try? TokenKeychain.read()) ?? nil
    if let token, !token.isEmpty {
        print("Signed in. Token: \(maskedToken(token))")
    } else {
        print("Not signed in. Run `reelabs-mcp sign-in`.")
    }
}

func maskedToken(_ token: String) -> String {
    guard token.count > 8 else { return "••••" }
    let prefix = token.prefix(5)
    let suffix = token.suffix(3)
    return "\(prefix)…\(suffix)"
}
