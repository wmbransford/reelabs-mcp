# AGENTS.md — Developer Guide for AI Agents

This file is for agents **developing** this codebase, not for agents using the MCP tools. For tool usage, see `CLAUDE.md` and `SKILL.md`.

## Build & Run

**Always use `./dev.sh`** for the build-restart-verify cycle:

```bash
./dev.sh    # builds release, restarts launchd agent, verifies PID
```

Then tell the user to run `/mcp` to reconnect the client.

**Why not `swift build` or `pkill`?** The server runs from `.build/release/ReelabsMCP`, managed by a launchd agent (`com.reelabs.mcp`) with `KeepAlive`. `swift build` (debug mode) doesn't update the release binary. `pkill` just makes launchd respawn the old binary. `./dev.sh` handles both correctly.

**Run tests:** `swift test` (28 tests across 4 suites)

Other commands:
```bash
swift build -c release            # compile only (no restart)
swift package resolve              # after Package.swift changes
```

- **Swift 6.2**, strict concurrency mode, **macOS 26+** minimum
- Dependencies: `MCP` (swift-sdk >=0.12.0), `GRDB` (>=7.4.0), `swift-nio`, `swift-log`
- `config.json` must be in the working directory or next to the binary
- `service-account.json` is gitignored — required for transcription only

## Package Architecture

The package uses a **library/executable split** for testability:

- **`ReelabsMCPLib`** (`Sources/ReelabsMCPLib/`) — all library code
- **`ReelabsMCP`** (`Sources/ReelabsMCP/`) — thin executable with only `main.swift`, imports `ReelabsMCPLib`
- **`ReelabsMCPTests`** (`Tests/ReelabsMCPTests/`) — tests import `@testable import ReelabsMCPLib`

**Why?** Swift test targets can't import executable targets (top-level code in `main.swift` runs on import). The split isolates the entry point so tests can import the library without triggering server startup.

**Access control rules:**
- Types/functions used by `main.swift` need `package` access (not just `internal`)
- Protocol-required members (`id`, `databaseTableName`, `didInsert`) on `package struct` types must also be `package`
- Structs with `package` stored properties need explicit `package init` (Swift doesn't auto-promote memberwise inits)
- Tests use `@testable import` which makes `internal` symbols visible — only cross-target (main.swift → lib) needs `package`

**New code goes in `Sources/ReelabsMCPLib/`, not `Sources/ReelabsMCP/`.**

## Architecture

```
Sources/
├── ReelabsMCP/
│   └── main.swift                  ← Entry point: imports ReelabsMCPLib, DB init, tool registration
└── ReelabsMCPLib/
    ├── ServerConfig.swift          ← Loads config.json + service account
    ├── DefaultPresets.swift        ← Seeds 4 caption presets on first run
    ├── ValueConversion.swift       ← MCP Value → Foundation JSON bridge
    ├── HTTPServer.swift            ← HTTP transport layer (NIO-based, serves /mcp endpoint)
    ├── Database/
    │   ├── DatabaseManager.swift   ← GRDB DatabasePool + migrations
    │   └── Repositories.swift      ← 6 repository structs (Project, Asset, Transcript, Render, Preset, VisualAnalysis)
    ├── Models/
    │   ├── RenderSpec.swift        ← All render types: RenderSpec, SegmentSpec, CaptionConfig, Overlay, etc.
    │   ├── Transcript.swift        ← Transcript, TranscriptWordRecord (DB), TranscriptData/TranscriptWord (in-memory)
    │   ├── Project.swift           ← Project model
    │   ├── Asset.swift             ← Asset model
    │   ├── Preset.swift            ← Preset model
    │   └── VisualAnalysis.swift    ← VisualAnalysis + VisualScene models
    ├── Tools/
    │   ├── ProbeTool.swift         ← reelabs_probe
    │   ├── TranscribeTool.swift    ← reelabs_transcribe
    │   ├── RenderTool.swift        ← reelabs_render (orchestrates build + export)
    │   ├── ValidateTool.swift      ← reelabs_validate
    │   ├── SearchTool.swift        ← reelabs_search (FTS5)
    │   ├── ProjectTool.swift       ← reelabs_project (CRUD)
    │   ├── AssetTool.swift         ← reelabs_asset (CRUD)
    │   ├── PresetTool.swift        ← reelabs_preset (CRUD)
    │   ├── SilenceRemoveTool.swift ← reelabs_silence_remove
    │   ├── AnalyzeTool.swift       ← reelabs_analyze (frame extraction + scene storage)
    │   └── Helpers.swift           ← encode(), extractInt64()
    ├── Render/
    │   ├── CompositionBuilder.swift    ← AVMutableComposition assembly (~600 lines)
    │   ├── CaptionLayer.swift          ← Word-by-word karaoke CALayer tree
    │   ├── ExportService.swift         ← AVAssetExportSession + reader/writer export + diagnostics
    │   ├── CompositorInstruction.swift ← Custom AVVideoCompositionInstruction for pixel-level compositing
    │   └── VideoCompositor.swift       ← Custom AVVideoCompositing implementation
    ├── Transcription/
    │   ├── ChirpClient.swift           ← Google Chirp v2 API with JWT auth
    │   └── TranscriptCompactor.swift   ← Groups words into utterances by silence gaps
    └── Media/
        ├── VideoProbe.swift        ← AVFoundation video inspection
        ├── FrameExtractor.swift    ← Extracts frames as JPEG for visual analysis
        └── AudioExtractor.swift    ← Video → 16kHz mono FLAC extraction

Tests/ReelabsMCPTests/
├── RemapTests.swift                ← 13 tests: transcript timestamp remapping (single + multi-source)
└── RenderSpecDecodingTests.swift   ← 15 tests: JSON decoding + Resolution.pixelSize
```

## Transport

The server uses **HTTP transport**, not stdio. `HTTPServer.swift` runs a NIO-based HTTP server that exposes a `/mcp` endpoint. The `.mcp.json` configures Claude Code to connect via HTTP:

```json
{"mcpServers": {"reelabs": {"type": "http", "url": "http://127.0.0.1:52849/mcp"}}}
```

The HTTP host/port are configured in `config.json` (`http_host`, `http_port`). The launchd agent keeps the server running persistently.

## How Data Flows

### Rendering Pipeline

```
RenderTool.handle()
  ├── Decode JSON → RenderSpec (via JSONDecoder with .convertFromSnakeCase)
  ├── Resolve captions: load transcript words from DB, resolve preset, merge configs
  ├── Remap transcript timestamps from source-time → composition-time
  ├── CompositionBuilder.build(spec:)
  │     ├── Preload source AVURLAssets (deduplicated by source ID)
  │     ├── Detect base resolution + fps from first segment's source
  │     ├── Apply aspect ratio (crops source dims to target ratio, preserves resolution)
  │     ├── Apply resolution override (scales to 720p/1080p/4k)
  │     ├── Pass 1: Insert segments onto alternating A/B tracks with time mapping
  │     │     └── Handles speed changes, transforms, keyframe animations, crossfades
  │     ├── Pass 2: Build AVVideoComposition instructions + audio mix params
  │     ├── Pass 3: Insert overlay tracks + integrate into existing instructions
  │     └── Remove empty tracks (prevents NaN duration crash)
  └── ExportService.export()
        ├── Select dimension-appropriate export preset (NOT HighestQuality — breaks transforms)
        ├── Burn in captions via AVVideoCompositionCoreAnimationTool (if configured)
        │     └── CaptionLayer creates CALayer tree with per-word color animations
        ├── Export to .mp4 via AVAssetExportSession
        └── Full diagnostic dump on failure (tracks, instructions, error chain)
```

`CompositorInstruction.swift` and `VideoCompositor.swift` provide a custom `AVVideoCompositing` pipeline for pixel-level frame compositing (used by overlays and advanced transforms).

### Transcription Pipeline

```
TranscribeTool.handle()
  ├── AudioExtractor: video → M4A → 16kHz mono FLAC
  ├── ChirpClient.transcribe()
  │     ├── <= 60s: sync Recognize API (inline base64)
  │     └── > 60s: upload to GCS → batch Recognize → poll for completion → cleanup
  ├── TranscriptCompactor: group words into utterances by >=400ms silence gaps
  └── Store in DB: transcript metadata + individual word rows (for caption rendering)
```

### Visual Analysis Pipeline

```
AnalyzeTool.handle(action: "extract")
  ├── FrameExtractor: extract frames at sample_fps as 720px JPEGs
  ├── Store VisualAnalysis record in DB
  └── Return frame paths for vision-capable sub-agent

AnalyzeTool.handle(action: "store")
  └── Persist VisualScene records from sub-agent analysis
```

## Database

SQLite via GRDB. Location: `~/Library/Application Support/ReelabsMCP/reelabs.sqlite`

Note: `reelabs.db` in the project root is a local development artifact, not the production database.

### Schema (migration: `v2_schema`)

| Table | Key Columns | Notes |
|-------|-------------|-------|
| `projects` | id, name, description, status, createdAt, updatedAt | status: "active" or "archived" |
| `assets` | id, projectId (FK→projects), filePath, filename, durationMs, width, height, fps, codec, hasAudio, fileSizeBytes, tags | tags stored as JSON string |
| `transcripts` | id, assetId (FK→assets, nullable), sourcePath, fullText, compactJson, durationSeconds, wordCount | compactJson = utterance array for agent context |
| `transcript_words` | id, transcriptId (FK→transcripts), wordIndex, word, startTime, endTime, confidence | One row per word. Indexed on transcriptId |
| `transcripts_fts` | FTS5 virtual table on fullText | BM25 ranking. Kept in sync via triggers (INSERT/UPDATE/DELETE) |
| `renders` | id, projectId (FK→projects, nullable), specJson, outputPath, durationSeconds, fileSizeBytes, status, errorMessage | Stores full spec for history |
| `presets` | id, name (unique), type, configJson, description | Seeded with tiktok/subtitle/minimal/bold_center |
| `visual_analyses` | id, assetId, sourcePath, status, sampleFps, frameCount, sceneCount, durationSeconds, framesDir | Frame extraction metadata |
| `visual_scenes` | id, analysisId (FK→visual_analyses), sceneIndex, startTime, endTime, description, tags, sceneType | Scene descriptions from visual analysis |

### GRDB Conventions

- All models implement `FetchableRecord`, `MutablePersistableRecord`, `Codable`, `Sendable`
- Use `didInsert(_ inserted: InsertionSuccess)` to capture auto-increment IDs
- Repositories are plain structs holding a `DatabasePool` reference
- Read operations use `dbPool.read { db in }`, writes use `dbPool.write { db in }`
- Timestamps use ISO8601 strings via `Project.timestamp()` (shared across all models)
- Migrations are append-only in `DatabaseManager.registerMigrations` — never modify existing migrations

## Adding a New Tool

1. **Create the tool file** in `Sources/ReelabsMCPLib/Tools/NewTool.swift`:
```swift
import Foundation
import MCP

package enum NewTool {
    package static let tool = Tool(
        name: "reelabs_newtool",
        description: "What it does",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "arg_name": .object([
                    "type": .string("string"),
                    "description": .string("What this arg is")
                ])
            ]),
            "required": .array([.string("arg_name")])
        ])
    )

    package static func handle(arguments: [String: Value]?) -> CallTool.Result {
        // Implementation
        let response: [String: Any] = ["result": "value"]
        let data = try! JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }
}
```

2. **Register in `main.swift`** (`Sources/ReelabsMCP/main.swift`):
   - Add `NewTool.tool` to the `ListTools` handler array
   - Add a `case "reelabs_newtool":` to the `CallTool` switch

3. **Update SKILL.md** with the new tool's input/output spec (agents using the MCP rely on this)

4. **Rebuild**: `./dev.sh`

### Tool Conventions

- Tool names: `reelabs_` prefix, snake_case
- Each tool is a `package enum` with `package static let tool` and `package static func handle()`
- Handle methods return `CallTool.Result` — set `isError: true` for user-facing errors
- Pass repositories/config as explicit parameters (no globals, no singletons)
- JSON responses use `JSONSerialization` with `.prettyPrinted, .sortedKeys`
- Use `encode()` from Helpers.swift for Codable types, `extractInt64()` for numeric args
- RenderSpec decoding uses `.convertFromSnakeCase` key strategy — field names in JSON are snake_case, Swift models are camelCase

## Testing

Tests live in `Tests/ReelabsMCPTests/` and use Swift Testing (`import Testing`, `@Suite`, `@Test`).

Current test suites (28 tests):
- **`remapTranscript`** (9 tests) — single-source transcript timestamp remapping with speed, gaps, clamping
- **`remapMultiSourceTranscript`** (4 tests) — multi-source remapping, missing transcripts, source reuse
- **`RenderSpec Decoding`** (10 tests) — JSON decoding of all spec fields, round-trip encode/decode
- **`Resolution.pixelSize`** (5 tests) — resolution preset scaling, even pixel enforcement

When adding new logic (especially timestamp math, decoding, or composition assembly), add tests. The library split makes any `internal` or `package` symbol testable via `@testable import ReelabsMCPLib`.

## Concurrency Model

- Swift 6 strict concurrency — everything must be `Sendable`
- All models are `struct` + `Sendable` (value types, no issues)
- `CompositionBuilder` and `ExportService` are `final class: Sendable` (no mutable state)
- `ChirpClient` is `final class: Sendable` (all properties are `let`)
- `DatabaseManager` is `final class: Sendable` (GRDB's `DatabasePool` is thread-safe)
- `HTTPServer` is an `actor` (handles concurrent HTTP connections safely)
- Repository structs hold a `DatabasePool` and are `Sendable`
- Tool handlers are `static func` — no instance state
- `BuildResult` is `@unchecked Sendable` because AVFoundation types aren't marked Sendable by Apple
- `AudioExtractor` uses `nonisolated(unsafe)` for the export session (AVFoundation limitation)
- `ExportService` uses `@preconcurrency import AVFoundation` to suppress Sendable warnings in `withThrowingTaskGroup` closures

## Known Issues & Fixed Bugs

### Empty crossfade tracks (FIXED)
CompositionBuilder pre-allocates 2 video + 2 audio tracks for crossfade support. With fewer than 2 segments, the B-tracks stay empty (duration = NaN), causing AVFoundation error -12123. **Fix**: CompositionBuilder removes empty tracks before returning (`composition.tracks where track.segments.isEmpty`).

### Export preset selection (FIXED)
`AVAssetExportPresetHighestQuality` does NOT support `AVVideoComposition`, causing transforms, scaling, and caption overlays to be silently ignored. **Fix**: `ExportService.exportPreset()` selects dimension-specific presets (720p/1080p/4K) based on the larger render dimension.

### Caption timestamp remapping (FIXED)
Transcript word timestamps are relative to the original source video. In multi-segment edits, captions were misaligned because composition time differs from source time. **Fix**: `remapTranscript()` in RenderTool.swift converts source timestamps to composition timeline, accounting for speed changes.

### Caption burn-in silent failure (FIXED)
`animationTool` MUST be passed inside `AVVideoComposition.Configuration(animationTool:...)` initializer. Setting it as a property on `AVMutableVideoComposition` silently drops it — export succeeds but captions are invisible. **Fix**: Create `AVVideoComposition(configuration:)` with `animationTool` in the config.

### Chirp chunk-relative timestamps (FIXED)
Chirp batch API resets word timestamps to 0 mid-stream within a single result block. **Fix**: Word-by-word offset correction in `parseResultsArray()`.

## Things That Will Bite You

- **AVFoundation is not forgiving.** Empty tracks, mismatched timescales, or invalid time ranges crash silently or produce error -12123. The ExportService has extensive diagnostics — read them when exports fail.
- **CoreAnimation timing.** Caption animations use `AVCoreAnimationBeginTimeAtZero` and fractional keyTimes (0.0-1.0 of total duration). Getting this wrong makes captions invisible or stuck.
- **FLAC extraction is two-step.** Video → M4A (via AVAssetExportSession) → FLAC (via AVAudioConverter at 16kHz mono). Direct FLAC export from video isn't supported by AVFoundation.
- **Chirp protobuf Duration parsing.** Google returns duration values in three formats: string `"9.400s"`, object `{"seconds": 9, "nanos": 400000000}`, or omitted (= 0). `ChirpClient.parseDurationValue()` handles all three.
- **RenderSpec JSON uses snake_case.** The decoder uses `.convertFromSnakeCase`, so `outputPath` in Swift maps to `output_path` in JSON. SKILL.md documents the JSON (snake_case) names. RenderSpec.swift documents the Swift (camelCase) names.
- **Overlay coordinates are 0.0-1.0 fractions**, not pixels. Top-left origin. `buildOverlayTransform()` converts to pixel coordinates using renderSize.
- **Caption fontSize is a percentage of video height**, not points. `7.0` means 7% of the output height.
- **The `resolution` field accepts two formats**: a string preset (`"720p"`, `"1080p"`, `"4k"`) or an object (`{"width": 1920, "height": 1080}`). The custom `Resolution` Codable handles both.
- **`dev.sh` silently uses cached binary on compile error.** Verify with `strings .build/release/ReelabsMCP | grep "log message"`.

## What's Not Here

- **No CI/CD.** Build and deploy is manual via `./dev.sh`.
- **No token caching.** `ChirpClient` requests a new OAuth2 access token for every transcription. Fine for current usage, would need caching under load.
- **No audio normalization.** `AudioConfig` has `normalizeAudio` and `duckingEnabled` fields but they are not implemented — they're decoded but ignored.
