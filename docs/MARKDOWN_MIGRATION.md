# Markdown Migration Spec

**Status:** Draft v3 — awaiting sign-off
**Target:** eliminate SQLite + GRDB dependency; store all persistent state as markdown + json sidecars, organized project-first.

---

## Motivation

SQLite + GRDB is overkill for a solo-creator MCP server. It adds:

- A dependency and schema migration surface
- Opaque binary storage (no git diffs, no grep, no eyeballing)
- A bespoke `reelabs_search` tool duplicating ripgrep
- Friction when an agent wants to re-read a transcript it already generated
- A `.db` file that can corrupt, lock, or drift out of sync with the code

Markdown + json sidecars preserve every feature that matters and drop the overhead.

**Non-goals:**
- Integrating with the Obsidian vault (explicit: data stays in the repo folder)
- Changing the JSON RenderSpec input format
- Hand-editing word-level timestamps (those stay machine-only)

---

## Directory Layout

All persistent state lives under `~/Desktop/reelabs-mcp2/data/`. Project-centric and flat — everything related to a project sits in its folder, namespaced by filename.

```
~/Desktop/reelabs-mcp2/
├── Sources/
├── Tests/
└── data/
    ├── projects/
    │   └── {project-slug}/
    │       ├── project.md                 ← project metadata
    │       ├── {source}.asset.md          ← per source video
    │       ├── {source}.transcript.md     ← pretty, agent-readable
    │       ├── {source}.words.json        ← word timestamps for renderer
    │       ├── {source}.analysis.md       ← pretty scene descriptions
    │       ├── {source}.scenes.json       ← per-frame data
    │       └── {reel}.render.md           ← render metadata + spec
    └── presets/
        └── {name}.md                      ← type: caption|render|audio in front matter
```

Render output `.mp4` files stay wherever `outputPath` points (usually next to the source video — unchanged from today). The `.render.md` references the path but doesn't colocate the file.

### Slugs as identifiers

Files use **slugs** (kebab-case) instead of numeric IDs. Examples:
- Project: `opus-47-video`
- Source video: `c0048` (stable: the camera's filename, sans extension, lowercased)
- Render: `trust-me-bro` (from the reel's working title)

Collisions handled by appending a short hash suffix (`c0048-a3f9`).

**Migration compatibility:** dropped. There aren't enough existing rows in the SQLite DB to justify a dual-ID layer. The one-time migration script re-slugs everything at cutover. If you have external references to legacy integer IDs anywhere (saved RenderSpecs, scripts, etc.), the migration report will list all old→new ID mappings so you can find-and-replace manually.

---

## Front Matter Schemas

All markdown files use YAML front matter. Every file includes `schema_version: 1`.

### Project (`{project-slug}/project.md`)

```yaml
---
schema_version: 1
slug: opus-47-video
name: "Opus 4.7 YouTube Video"
status: active              # active | archived | deleted
created: 2026-04-16T10:47:00Z
updated: 2026-04-16T14:30:00Z
description: "Reaction video covering Opus 4.7 launch"
tags: [youtube, ai, review]
---

# Opus 4.7 YouTube Video

<free-form markdown notes>
```

Everything else in the project folder is implicitly part of the project. No explicit `project:` field needed on child files — the folder IS the project.

### Transcript (`{source}.transcript.md` + `{source}.words.json`)

```yaml
---
schema_version: 1
source: c0048
source_path: "/Users/williambransford/Desktop/April 16th Youtube Video/C0048.MP4"
duration_seconds: 997.99
word_count: 2408
language: en-US
mode: "chunked-sync (20 chunks)"
created: 2026-04-16T10:48:00Z
---

# Transcript: C0048.MP4

- [0:08 – 0:11] Opus 4.7, is it just another model or not?
- [0:12 – 0:14] Well, we're going to dive into it and
- [0:15 – 0:16] let's get
...
```

The markdown body is the agent-readable compact transcript — hand-editable (fixing "quad" → "Claude" is just a text edit).

**Sidecar `{source}.words.json`** holds word-level timestamps for the caption renderer:

```json
[
  {"start": 8.0, "end": 8.3, "word": "Opus", "confidence": 0.98},
  {"start": 8.3, "end": 8.5, "word": "4.7", "confidence": 0.95}
]
```

**Sync model:** `words.json` is immutable source of truth for timing. The markdown body is agent-and-human-readable display. When the markdown is edited (e.g., "quad" → "Claude"), the renderer uses the *edited* text at the *original* timestamp — no alignment logic needed, no stale state. The edit is a caption override, not a re-transcription.

Implementation: at render time, the caption layer walks `words.json` in order and replaces each word's text with the corresponding token from the edited markdown, position-by-position. If word counts differ (user added or removed words), the renderer refuses the render and tells the user to run `reelabs_transcript action: "sync_words"` which rebuilds `words.json` from the edited markdown via retranscription of affected regions.

This preserves the invariant that word timings never lie while still letting humans fix mishears as plain-text edits.

### Render (`{reel}.render.md`)

```yaml
---
schema_version: 1
slug: trust-me-bro
render_id: 89
status: completed
created: 2026-04-16T13:40:00Z
duration_seconds: 23.7
output_path: "/Users/williambransford/Desktop/April 16th Youtube Video/Reel_1_TrustMeBro.mp4"
file_size_mb: 34.5
resolution: 1214x2160
aspect_ratio: "9:16"
fps: 23.98
codec: h264
captions_applied: true
caption_word_count: 76
sources: [c0048]
---

# Render: Trust Me Bro Benchmarks

First reel from the Opus 4.7 reaction.

## RenderSpec

```json
{
  "sources": [
    {"id": "main", "path": "/Users/williambransford/Desktop/April 16th Youtube Video/C0048.MP4", "transcriptId": "c0048"}
  ],
  "segments": [
    {"sourceId": "main", "start": 68.75, "end": 92.45}
  ],
  "captions": {"preset": "william"},
  "aspectRatio": "9:16",
  "outputPath": "/Users/williambransford/Desktop/April 16th Youtube Video/Reel_1_TrustMeBro.mp4"
}
```

## Notes

<free-form>
```

`reelabs_rerender` parses the fenced json block to rehydrate the spec, applies overrides, re-renders.

### Asset (`{source}.asset.md`)

```yaml
---
schema_version: 1
slug: c0048
filename: C0048.MP4
file_path: "/Users/williambransford/Desktop/April 16th Youtube Video/C0048.MP4"
file_size_bytes: 12818187961
duration_seconds: 997.99
width: 3840
height: 2160
fps: 23.98
codec: hvc1
has_audio: true
tags: [youtube, interview, opus-47]
created: 2026-04-16T10:47:00Z
---

# C0048.MP4

<free-form notes>
```

### Preset (`presets/{name}.md`)

```yaml
---
schema_version: 1
name: william
type: caption                # caption | render | audio
font_family: Poppins
font_weight: bold
color: "#FAF9F5"
highlight_color: "#D97757"
words_per_group: 3
all_caps: true
shadow: true
position: 70
punctuation: false
---

# Preset: william

Karaoke captions — cream text with burnt orange karaoke highlight. Poppins bold, 3 words per group.
```

### Visual Analysis (`{source}.analysis.md` + `{source}.scenes.json`)

Same hybrid pattern as transcripts: markdown body holds readable scene descriptions, `scenes.json` holds any fine-grained per-frame data.

---

## Tool Behavior Changes

Signatures and return shapes stay the same except where noted. `transcript_id` (and similar ID fields) in responses become slug strings. No dual-form acceptance — legacy integer IDs are dropped at cutover.

- **`reelabs_project`** — operates on `data/projects/*/project.md`
- **`reelabs_asset`** — operates on `data/projects/*/*.asset.md`. Project context inferred from the folder.
- **`reelabs_preset`** — operates on `data/presets/*.md` (type filtered via front matter)
- **`reelabs_transcribe`** — writes `{source}.transcript.md` + `{source}.words.json` to the project folder
- **`reelabs_render`** — reads word timestamps from `{source}.words.json`, writes `{reel}.render.md` with the spec embedded as a fenced json block
- **`reelabs_rerender`** — parses the fenced json block from `{reel}.render.md`
- **`reelabs_silence_remove`** — parses utterances from `{source}.transcript.md`
- **`reelabs_analyze`** — writes `{source}.analysis.md` + `{source}.scenes.json`
- **`reelabs_search`** — **deleted**. CLAUDE.md gets a note pointing agents at their built-in `Grep` tool on `data/**/*.md`.
- **NEW `reelabs_transcript`** — `action: list | get | sync_words`. Closes the rehydration gap (agents re-fetch a prior transcript without burning Chirp credits) and provides the `sync_words` action for rebuilding `words.json` after transcript edits that change word count.

Tools take a `project` argument (slug) when context isn't inferable. `reelabs_transcribe` either takes an explicit `project` slug, or auto-creates one from the parent directory of the source video.

---

## File I/O Conventions

- **Atomic single-file writes**: write to a temp file, then `rename()`. No partial writes on crash.
- **Atomic multi-file writes (`writeAtomicPair`)**: for paired files like `transcript.md` + `words.json`, stage both to temp paths, then rename both on success. On any failure, unlink both temp files and surface a clean error — never leave a half-state on disk.
- **YAML parsing**: Yams library.
- **Fenced json block parsing**: regex to extract the ` ```json ... ``` ` block from render markdown.
- **File locking**: `flock()` on writes. MCP is mostly single-threaded per session, contention is rare.

---

## Migration Phases

Each phase independently shippable.

### Phase 0: Spec sign-off (this doc)

### Phase 1: Infrastructure

New `Sources/ReelabsMCPLib/Storage/`:
- `MarkdownStore` — atomic front-matter read/write, including `writeAtomicPair` for md+json sidecar pairs
- `SlugGenerator` — stable slugs with collision handling
- Unit tests for each

### Phase 2: Presets (lowest risk)

- `PresetRepository` → `MarkdownStore`
- Seed defaults on first run if `data/presets/` is empty
- Drop presets table from DatabaseManager (keep DB file intact)

### Phase 3: Projects

- `ProjectRepository` → `MarkdownStore`
- `reelabs_project` operates on folders under `data/projects/`

### Phase 4: Transcripts (hybrid)

- `TranscriptRepository` → markdown + `words.json` sidecar
- `reelabs_render` reads word timestamps from json sidecar via a new `WordIndex` loader
- `reelabs_silence_remove` parses utterances from markdown body
- Add `reelabs_transcript` management tool

### Phase 5: Assets, analyses, renders

All three follow the same project-nested pattern. Safe to land together.

### Phase 6: Cleanup

- Delete `reelabs_search`
- Delete `DatabaseManager.swift`, `Repositories.swift`
- Remove GRDB from `Package.swift`
- Archive the old DB to `data/.archive/pre-migration.db`
- Update AGENTS.md and CLAUDE.md

### One-time migration script

`Sources/ReelabsMCPLib/Storage/Migration.swift` — reads all SQLite rows, writes equivalent markdown files with freshly-assigned slugs, archives the DB, and emits a **migration report** at `data/.migration-report.md` listing every old→new ID mapping (for manual find-and-replace in any external references). Runs on first launch after upgrade if `data/` is empty and the DB has rows. Idempotent.

---

## Rollback

1. Stop the MCP: `launchctl bootout gui/$(id -u)/com.reelabs.mcp`
2. `mv data data.failed`
3. Restore: `mv data.failed/.archive/pre-migration.db ~/Library/Application\ Support/ReelabsMCP/reelabs.db`
4. Check out the pre-migration commit
5. `./dev.sh`

Reversible because the DB is archived, never deleted, and source videos/outputs are never touched.

---

## Risks

| Risk | Mitigation |
|------|------------|
| YAML parse errors on hand-edited files | Tolerant parser; fall back to template with clear error |
| File locks on high-volume writes | Rare; `flock()` on critical writes |
| Word-count mismatch between edited markdown and `words.json` | Renderer refuses render with clear error; user runs `reelabs_transcript action: "sync_words"` |
| External references to legacy numeric IDs | Migration report at `data/.migration-report.md` lists all old→new ID mappings for find-and-replace |
| Migration corrupts DB | DB archived before any write |
| Partial migration | Each phase independently functional; old + new can coexist |
| Half-written md+json pair on crash | `writeAtomicPair` stages both to temp, renames both on success |

---

## Open Questions

1. **`data/` gitignored or committed?** Proposed: gitignored by default.
2. **Compact format for very large `words.json`?** Proposed: no, keep JSON. Revisit above 10MB.
3. **Preserve ChirpClient dedup cache?** Proposed: yes, keyed by `source_path + mtime + duration` instead of DB row.

---

## Acceptance Criteria

- [ ] `DatabaseManager.swift` and `Repositories.swift` deleted
- [ ] GRDB removed from `Package.swift`
- [ ] All 13 existing MCP tools pass their test suites (minus `reelabs_search`, which is deleted)
- [ ] Full rebuild from clean state (`rm -rf data/`) works — MCP boots, transcribes, renders
- [ ] `AGENTS.md` and `CLAUDE.md` reflect the new storage model
- [ ] Pre-migration DB archived at `data/.archive/pre-migration.db`
