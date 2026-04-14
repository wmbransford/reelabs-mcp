# AGENTS.md — Developer Guide for AI Agents

This file is for agents **developing** this codebase, not for agents using the MCP tools. For tool usage, see `CLAUDE.md` and `SKILL.md`.

## Build & Run

```bash
swift build -c release                    # compile binary
.build/release/ReelabsMCP                 # run directly (needs config.json in cwd)
./setup.sh                                # build + register with Claude Code
```

- **Swift 6.2**, strict concurrency mode, **macOS 26+** minimum
- Two dependencies only: `MCP` (swift-sdk >=0.12.0) and `GRDB` (>=7.4.0)
- Binary runs as stdio MCP server — Claude Code launches it automatically
- `config.json` must be in the working directory or next to the binary
- `service-account.json` is gitignored — required for transcription only
- After any `Package.swift` change: `swift package resolve`

## Architecture

```
Sources/ReelabsMCP/
├── main.swift              ← Entry point: PID management, DB init, tool registration
├── ServerConfig.swift      ← Loads config.json + service account
├── DefaultPresets.swift    ← Seeds 4 caption presets on first run
├── ValueConversion.swift   ← MCP Value → Foundation JSON bridge
├── Database/
│   ├── DatabaseManager.swift   ← GRDB DatabasePool + migrations
│   └── Repositories.swift      ← 5 repository structs (Project, Asset, Transcript, Render, Preset)
├── Models/
│   ├── RenderSpec.swift    ← All render types: RenderSpec, SegmentSpec, CaptionConfig, Overlay, etc.
│   ├── Transcript.swift    ← Transcript, TranscriptWordRecord (DB), TranscriptData/TranscriptWord (in-memory)
│   ├── Project.swift       ← Project model
│   ├── Asset.swift         ← Asset model
│   └── Preset.swift        ← Preset model
├── Tools/
│   ├── ProbeTool.swift         ← reelabs_probe
│   ├── TranscribeTool.swift    ← reelabs_transcribe
│   ├── RenderTool.swift        ← reelabs_render (orchestrates build + export)
│   ├── ValidateTool.swift      ← reelabs_validate
│   ├── SearchTool.swift        ← reelabs_search (FTS5)
│   ├── ProjectTool.swift       ← reelabs_project (CRUD)
│   ├── AssetTool.swift         ← reelabs_asset (CRUD)
│   ├── PresetTool.swift        ← reelabs_preset (CRUD)
│   └── Helpers.swift           ← encode(), extractInt64()
├── Render/
│   ├── CompositionBuilder.swift  ← AVMutableComposition assembly (~600 lines)
│   ├── CaptionLayer.swift        ← Word-by-word karaoke CALayer tree
│   └── ExportService.swift       ← AVAssetExportSession + diagnostics
├── Transcription/
│   ├── ChirpClient.swift           ← Google Chirp v2 API with JWT auth
│   └── TranscriptCompactor.swift   ← Groups words into utterances by silence gaps
└── Media/
    ├── VideoProbe.swift       ← AVFoundation video inspection
    └── AudioExtractor.swift   ← Video → 16kHz mono FLAC extraction
```

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

## Database

SQLite via GRDB. Location: `~/Library/Application Support/ReelabsMCP/reelabs.sqlite`

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

### GRDB Conventions

- All models implement `FetchableRecord`, `MutablePersistableRecord`, `Codable`, `Sendable`
- Use `didInsert(_ inserted: InsertionSuccess)` to capture auto-increment IDs
- Repositories are plain structs holding a `DatabasePool` reference
- Read operations use `dbPool.read { db in }`, writes use `dbPool.write { db in }`
- Timestamps use ISO8601 strings via `Project.timestamp()` (shared across all models)
- Migrations are append-only in `DatabaseManager.registerMigrations` — never modify existing migrations

## Adding a New Tool

1. **Create the tool file** in `Sources/ReelabsMCP/Tools/NewTool.swift`:
```swift
import Foundation
import MCP

enum NewTool {
    static let tool = Tool(
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

    static func handle(arguments: [String: Value]?) -> CallTool.Result {
        // Implementation
        let response: [String: Any] = ["result": "value"]
        let data = try! JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }
}
```

2. **Register in `main.swift`**:
   - Add `NewTool.tool` to the `ListTools` handler array
   - Add a `case "reelabs_newtool":` to the `CallTool` switch

3. **Update SKILL.md** with the new tool's input/output spec (agents using the MCP rely on this)

4. **Rebuild**: `swift build -c release`

### Tool Conventions

- Tool names: `reelabs_` prefix, snake_case
- Each tool is an `enum` with `static let tool` and `static func handle()`
- Handle methods return `CallTool.Result` — set `isError: true` for user-facing errors
- Pass repositories/config as explicit parameters (no globals, no singletons)
- JSON responses use `JSONSerialization` with `.prettyPrinted, .sortedKeys`
- Use `encode()` from Helpers.swift for Codable types, `extractInt64()` for numeric args
- RenderSpec decoding uses `.convertFromSnakeCase` key strategy — field names in JSON are snake_case, Swift models are camelCase

## Concurrency Model

- Swift 6 strict concurrency — everything must be `Sendable`
- All models are `struct` + `Sendable` (value types, no issues)
- `CompositionBuilder` and `ExportService` are `final class: Sendable` (no mutable state)
- `ChirpClient` is `final class: Sendable` (all properties are `let`)
- `DatabaseManager` is `final class: Sendable` (GRDB's `DatabasePool` is thread-safe)
- Repository structs hold a `DatabasePool` and are `Sendable`
- Tool handlers are `static func` — no instance state
- `BuildResult` is `@unchecked Sendable` because AVFoundation types aren't marked Sendable by Apple
- `AudioExtractor` uses `nonisolated(unsafe)` for the export session (AVFoundation limitation)

## Known Issues & Fixed Bugs

### Empty crossfade tracks (FIXED)
CompositionBuilder pre-allocates 2 video + 2 audio tracks for crossfade support. With fewer than 2 segments, the B-tracks stay empty (duration = NaN), causing AVFoundation error -12123. **Fix**: CompositionBuilder removes empty tracks before returning (`composition.tracks where track.segments.isEmpty`).

### Export preset selection (FIXED)
`AVAssetExportPresetHighestQuality` does NOT support `AVVideoComposition`, causing transforms, scaling, and caption overlays to be silently ignored. **Fix**: `ExportService.exportPreset()` selects dimension-specific presets (720p/1080p/4K) based on the larger render dimension.

### Caption timestamp remapping (FIXED)
Transcript word timestamps are relative to the original source video. In multi-segment edits, captions were misaligned because composition time differs from source time. **Fix**: `remapTranscript()` in RenderTool.swift converts source timestamps to composition timeline, accounting for speed changes.

## Things That Will Bite You

- **AVFoundation is not forgiving.** Empty tracks, mismatched timescales, or invalid time ranges crash silently or produce error -12123. The ExportService has extensive diagnostics — read them when exports fail.
- **CoreAnimation timing.** Caption animations use `AVCoreAnimationBeginTimeAtZero` and fractional keyTimes (0.0-1.0 of total duration). Getting this wrong makes captions invisible or stuck.
- **FLAC extraction is two-step.** Video → M4A (via AVAssetExportSession) → FLAC (via AVAudioConverter at 16kHz mono). Direct FLAC export from video isn't supported by AVFoundation.
- **Chirp protobuf Duration parsing.** Google returns duration values in three formats: string `"9.400s"`, object `{"seconds": 9, "nanos": 400000000}`, or omitted (= 0). `ChirpClient.parseDurationValue()` handles all three.
- **RenderSpec JSON uses snake_case.** The decoder uses `.convertFromSnakeCase`, so `outputPath` in Swift maps to `output_path` in JSON. SKILL.md documents the JSON (snake_case) names. RenderSpec.swift documents the Swift (camelCase) names.
- **Overlay coordinates are 0.0-1.0 fractions**, not pixels. Top-left origin. `buildOverlayTransform()` converts to pixel coordinates using renderSize.
- **Caption fontSize is a percentage of video height**, not points. `7.0` means 7% of the output height.
- **The `resolution` field accepts two formats**: a string preset (`"720p"`, `"1080p"`, `"4k"`) or an object (`{"width": 1920, "height": 1080}`). The custom `Resolution` Codable handles both.

## What's Not Here

- **No tests.** `Tests/ReelabsMCPTests/` is empty. The test target exists in Package.swift but has no test files.
- **No CI/CD.** Build and deploy is manual via `setup.sh`.
- **No token caching.** `ChirpClient` requests a new OAuth2 access token for every transcription. Fine for current usage, would need caching under load.
- **No audio normalization.** `AudioConfig` has `normalizeAudio` and `duckingEnabled` fields but they are not implemented — they're decoded but ignored.
