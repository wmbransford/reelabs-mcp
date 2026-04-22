# AGENTS.md — Developer Guide for AI Agents

This file is for agents **developing** this codebase, not for agents using the MCP tools. For tool usage, see `CLAUDE.md` (workflow + Technical Reference).

## Build & Run

**Always use `./dev.sh`** for the build-restart-verify cycle:

```bash
./dev.sh    # builds release, restarts launchd agent, verifies PID
```

Then tell the user to run `/mcp` to reconnect the client.

**Why not `swift build` or `pkill`?** The server runs from `.build/release/ReelabsMCP`, managed by a launchd agent (`com.reelabs.mcp`) with `KeepAlive`. `swift build` (debug mode) doesn't update the release binary. `pkill` just makes launchd respawn the old binary. `./dev.sh` handles both correctly.

**Run tests:** `./scripts/test` (swift-testing wrapper; sets framework search paths for CommandLineTools-only macOS).

Other commands:
```bash
swift build -c release            # compile only (no restart)
swift package resolve              # after Package.swift changes
./scripts/db tables                # sqlite wrapper — see "Data Store" below
./scripts/db verify-parity         # compare DB rows vs. legacy on-disk markdown
./scripts/sync-migrations          # copy migrations/*.sql → Resources/ after edits
```

- **Swift 6.2**, strict concurrency mode, **macOS 26+** minimum
- Dependencies: `MCP` (swift-sdk >=0.12.0), `Yams` (>=5.0.0), `swift-nio`, `swift-log`
- `config.json` must be in the working directory or next to the binary. Set `data_path` to the `data/` folder location.
- Transcription auth is **service-account-backed**: set `GOOGLE_APPLICATION_CREDENTIALS` to a GCP service-account JSON key with `roles/speech.client` on a project that has Speech-to-Text API enabled. The runtime mints OAuth2 access tokens from the key via `GoogleAuthenticator` (JWT → token endpoint → bearer), caches them in-memory until near expiry, and calls `us-speech.googleapis.com/v2/.../recognizers/_:recognize` directly. No proxy, no keychain, no sign-in subcommand.
- Alternatively, set `gcp_credentials_path` in `config.json` (env var takes precedence).
- The Firebase proxy code in `functions/` and activation pages in `web/` are **orphaned** from the distribution-auth era — kept for history, deletable in a future cleanup pass.

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
│   └── main.swift                  ← Entry point: imports ReelabsMCPLib, store init, tool registration
└── ReelabsMCPLib/
    ├── ServerConfig.swift          ← Loads config.json + resolves data root
    ├── DefaultPresets.swift        ← Seeds caption presets on first run
    ├── ValueConversion.swift       ← MCP Value → Foundation JSON bridge
    ├── HTTPServer.swift            ← HTTP transport layer (NIO-based, serves /mcp endpoint)
    ├── Storage/
    │   ├── Paths.swift             ← DataPaths: resolves projects/, presets/, kits/, Media/, reelabs.db paths from the root URL
    │   ├── Models.swift            ← Codable record types (ProjectRecord, AssetRecord, TranscriptRecord, etc.)
    │   ├── Database.swift          ← Owns the GRDB DatabasePool; applies migrations and one-shot importer on init
    │   ├── SlugGenerator.swift     ← slugify() + uniqueSlug()
    │   ├── ProjectStore.swift      ← CRUD on projects table
    │   ├── AssetStore.swift        ← CRUD on assets table
    │   ├── TranscriptStore.swift   ← CRUD on transcripts + transcript_words; fullTextSearch via transcripts_fts
    │   ├── RenderStore.swift       ← CRUD on renders table (spec_json + notes_md split)
    │   ├── PresetStore.swift       ← CRUD on presets table
    │   ├── AnalysisStore.swift     ← CRUD on analyses + scenes
    │   └── Importer/               ← Legacy read path — one-shot on first DB open
    │       ├── MarkdownStore.swift ← YAML front matter parser (Yams)
    │       └── MarkdownImporter.swift ← Walks on-disk .md/.json, INSERT OR IGNOREs into the DB
    ├── Models/
    │   └── RenderSpec.swift        ← All render types: RenderSpec, SegmentSpec, CaptionConfig, Overlay, etc.
    ├── Tools/
    │   ├── ProbeTool.swift         ← reelabs_probe
    │   ├── TranscribeTool.swift    ← reelabs_transcribe (writes transcript.md + words.json)
    │   ├── TranscriptTool.swift    ← reelabs_transcript (list/get — rehydrate prior transcripts)
    │   ├── RenderTool.swift        ← reelabs_render (orchestrates build + export)
    │   ├── RerenderTool.swift      ← reelabs_rerender (loads stored spec, applies overrides, re-runs)
    │   ├── ValidateTool.swift      ← reelabs_validate
    │   ├── ProjectTool.swift       ← reelabs_project (CRUD)
    │   ├── AssetTool.swift         ← reelabs_asset (CRUD)
    │   ├── PresetTool.swift        ← reelabs_preset (CRUD)
    │   ├── SilenceRemoveTool.swift ← reelabs_silence_remove
    │   ├── AnalyzeTool.swift       ← reelabs_analyze (frame extraction + scene storage)
    │   ├── ExtractAudioTool.swift  ← reelabs_extract_audio
    │   ├── GraphicTool.swift       ← reelabs_graphic
    │   ├── LayoutTool.swift        ← reelabs_layout
    │   └── Helpers.swift           ← encode(), extractInt64()
    ├── Render/
    │   ├── CompositionBuilder.swift    ← AVMutableComposition assembly (~600 lines)
    │   ├── CaptionLayer.swift          ← Word-by-word karaoke CALayer tree
    │   ├── ExportService.swift         ← AVAssetExportSession + reader/writer export + diagnostics
    │   ├── CompositorInstruction.swift ← Custom AVVideoCompositionInstruction for pixel-level compositing
    │   └── VideoCompositor.swift       ← Custom AVVideoCompositing implementation
    ├── Transcription/
    │   ├── ChirpClient.swift           ← Google Chirp v2 (Speech-to-Text) direct API client
    │   ├── GoogleAuthenticator.swift   ← Service-account JWT → OAuth2 access token minting (RS256 via Security.framework)
    │   └── TranscriptCompactor.swift   ← Groups words into utterances by silence gaps
    └── Media/
        ├── VideoProbe.swift        ← AVFoundation video inspection
        ├── FrameExtractor.swift    ← Extracts frames as JPEG for visual analysis
        └── AudioExtractor.swift    ← Video → 16kHz mono FLAC extraction

Tests/ReelabsMCPTests/
├── RemapTests.swift                ← transcript timestamp remapping (single + multi-source)
├── RenderSpecDecodingTests.swift   ← JSON decoding + Resolution.pixelSize
├── ColorUtilsTests.swift           ← hex color parsing
├── RerenderMergeTests.swift        ← deep-merge of partial RenderSpec overrides
├── SlugGeneratorTests.swift        ← slugify() + uniqueSlug() collision behavior
└── MarkdownStoreTests.swift        ← round-trip, atomic pair writes, front matter parsing
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
  └── TranscriptStore.save(): writes {source}.transcript.md + {source}.words.json
```

### Visual Analysis Pipeline

```
AnalyzeTool.handle(action: "extract")
  ├── FrameExtractor: extract frames at sample_fps as 720px JPEGs
  ├── AnalysisStore.save: upserts the analysis row (status='extracted')
  └── Return frame paths for vision-capable sub-agent

AnalyzeTool.handle(action: "store")
  └── AnalysisStore.saveScenes: inserts scenes + flips status to 'analyzed'
```

## Data Store

All persistent runtime state lives in **`{dataRoot}/reelabs.db`** — a single SQLite database managed by GRDB in WAL mode with `PRAGMA foreign_keys = ON`. Legacy on-disk markdown and JSON files are still present but are now just dormant — the markdown importer reads them once at first DB open (idempotent) and SQLite is the source of truth from then on.

### Layout

- **`{dataRoot}/reelabs.db`** (SQLite, WAL, GRDB) — projects, assets, transcripts, transcript_words, analyses, scenes, renders, presets. FTS5 virtual table `transcripts_fts` indexes `transcripts.full_text`, kept in sync by triggers.
- **`{dataRoot}/kits/*.md`** — hand-authored editorial recipes. Intentionally NOT in the DB; read directly by `DefaultKits.seed` + the agents that consume them.
- **`{dataRoot}/Media/Frames/`**, rendered `.mp4`s, generated PNGs, extracted `.m4a` — binary outputs on disk, tracked by DB rows (the paths are stored as columns, the bytes stay on disk).
- **`{dataRoot}/projects/**/*.md`**, **`*.words.json`**, **`*.scenes.json`** — legacy write-once copies kept until the SQLite migration has baked in. Safe to delete once `scripts/db verify-parity` is clean (see below).
- **`migrations/*.sql`** — schema evolution, applied in lexical order by `Database.swift`, recorded in `schema_migrations`. The bundled copy lives at `Sources/ReelabsMCPLib/Resources/migrations/` and must stay byte-identical to the root copy — run `./scripts/sync-migrations` after editing a migration.

### Store Conventions

- Stores hold a `Database` value (not a `DataPaths`) and expose GRDB-backed CRUD. All writes use `database.pool.write`; multi-row writes (e.g. transcripts + their words, analyses + their scenes) go inside a single transaction.
- Primary keys are slugs. Projects are keyed by `slug`. Assets, transcripts, analyses, renders are keyed by `(project_slug, slug)` (or `(project_slug, source_slug)` for analyses/transcripts). Presets are keyed by `name`.
- On conflict, live `save(...)` calls do `ON CONFLICT DO UPDATE` — these are real upserts. The one-shot `MarkdownImporter.runIfNeeded` uses `INSERT OR IGNORE` so re-running against a populated DB is a no-op.
- Foreign keys cascade from `projects(slug)` into every child table — deleting a project removes its assets, transcripts, words, analyses, scenes, and renders.
- RenderSpecs live in `renders.spec_json` (full spec as JSON) separate from `renders.notes_md` (prose half of the old `.render.md` body). `reelabs_rerender` pulls `spec_json` directly; markdown parsing is gone from the live path.
- Legacy markdown reading still exists in `Sources/ReelabsMCPLib/Storage/Importer/`. It's the only caller of `Yams` and runs exactly once — it can be deleted entirely once the on-disk markdown is gone.

### Ad-hoc SQL and Verification

Use the `scripts/db` wrapper instead of invoking `sqlite3` by hand:

```bash
./scripts/db tables                        # list tables
./scripts/db query "SELECT slug, name FROM projects WHERE status='active'"
./scripts/db query-json "SELECT * FROM renders LIMIT 5"
./scripts/db exec  "UPDATE presets SET description='...' WHERE name='william'"
./scripts/db path                          # resolved DB path
```

The wrapper sets `foreign_keys=ON`, `synchronous=NORMAL`, and a 5 s busy timeout. It resolves the DB from `REELABS_DATA_DIR` (dev) or `~/Library/Application Support/ReelabsMCP/` (prod).

### Verifying the SQLite migration

After upgrading — or before deleting any legacy on-disk state — run:

```bash
./scripts/db verify-parity
```

It walks `{dataRoot}/projects` and `{dataRoot}/presets` and compares each markdown/JSON file against the matching SQLite row. Output is one line per row reporting `OK`, `MISSING_IN_DB`, `MISSING_ON_DISK`, or `DIFFER` (with a field-level diff). Exit 0 on all-OK, 1 on any mismatch — usable from scripts.

If the report is all OK, the on-disk `.md`/`.json` files are redundant and can be deleted manually. The legacy importer + Yams stay until that manual cleanup lands.

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

3. **Update CLAUDE.md** — add a row in the Tools table and a new subsection under the Technical Reference with the tool's input/output spec (agents using the MCP rely on this)

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

Current test suites (71 tests across 12 suites):
- **`remapTranscript`** — single-source transcript timestamp remapping with speed, gaps, clamping
- **`remapMultiSourceTranscript`** — multi-source remapping, missing transcripts, source reuse
- **`RenderSpec Decoding`** — JSON decoding of all spec fields, round-trip encode/decode
- **`Resolution.pixelSize`** — resolution preset scaling, even pixel enforcement
- **`parseHexColor`** — 6/8-digit hex parsing with alpha
- **`RenderSpec merge helpers`** — deep-merge of partial overrides for rerender
- **`SlugGenerator.slugify` / `uniqueSlug`** — identifier generation, collision handling
- **`MarkdownStore round-trip` / `writeAtomicPair` / `splitFrontMatter`** — persistence layer

When adding new logic (especially timestamp math, decoding, or composition assembly), add tests. The library split makes any `internal` or `package` symbol testable via `@testable import ReelabsMCPLib`.

## Concurrency Model

- Swift 6 strict concurrency — everything must be `Sendable`
- All models are `struct` + `Sendable` (value types, no issues)
- `CompositionBuilder` and `ExportService` are `final class: Sendable` (no mutable state)
- `ChirpClient` is `final class: Sendable` (all properties are `let`)
- All stores are value-type `struct: Sendable` (markdown I/O is stateless aside from the `DataPaths` value they hold)
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
- **RenderSpec JSON uses snake_case.** The decoder uses `.convertFromSnakeCase`, so `outputPath` in Swift maps to `output_path` in JSON. CLAUDE.md's Technical Reference documents the JSON (snake_case) names. RenderSpec.swift documents the Swift (camelCase) names.
- **Overlay coordinates are 0.0-1.0 fractions**, not pixels. Top-left origin. `buildOverlayTransform()` converts to pixel coordinates using renderSize.
- **Caption fontSize is a percentage of video height**, not points. `7.0` means 7% of the output height.
- **The `resolution` field accepts two formats**: a string preset (`"720p"`, `"1080p"`, `"4k"`) or an object (`{"width": 1920, "height": 1080}`). The custom `Resolution` Codable handles both.
- **`dev.sh` silently uses cached binary on compile error.** Verify with `strings .build/release/ReelabsMCP | grep "log message"`.

## What's Not Here

- **No CI/CD.** Build and deploy is manual via `./dev.sh`.
- **No token caching.** `ChirpClient` requests a new OAuth2 access token for every transcription. Fine for current usage, would need caching under load.
- **No audio normalization.** `AudioConfig` has `normalizeAudio` and `duckingEnabled` fields but they are not implemented — they're decoded but ignored.
