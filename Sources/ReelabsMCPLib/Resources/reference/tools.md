# Tools — Reference

The complete catalog of `reelabs_*` MCP tools. Each entry lists inputs, outputs, and what the tool is really for.

## Catalog

| Tool | Purpose |
|------|---------|
| `reelabs_probe` | Inspect a video file (duration, resolution, fps, codecs, audio, size) |
| `reelabs_transcribe` | Speech-to-text with word-level timestamps (Chirp) |
| `reelabs_transcript` | Manage existing transcripts (list, get) |
| `reelabs_render` | Render video from a declarative RenderSpec |
| `reelabs_validate` | Pre-flight check on a RenderSpec |
| `reelabs_project` | Manage projects (create, list, get, archive, delete) |
| `reelabs_asset` | Manage project assets (add, list, get, tag, delete) |
| `reelabs_preset` | Manage reusable presets (save, get, list, delete) |
| `reelabs_silence_remove` | Auto-generate segments that skip silent gaps |
| `reelabs_speaker_detect` | Pick the active speaker across N synced sources and return segments |
| `reelabs_analyze` | Extract frames for visual analysis, store/retrieve scene descriptions |
| `reelabs_rerender` | Re-render a previous render with partial overrides |
| `reelabs_graphic` | Render HTML/CSS to a PNG for overlays or thumbnails |
| `reelabs_layout` | Generate overlay arrays for screen-recording layouts (PiP, split, focus) |
| `reelabs_extract_audio` | Extract the audio track as an M4A (AAC passthrough) |

## `reelabs_probe`

Inspect a video file. Always probe before building a RenderSpec — duration and source resolution drive everything downstream.

**Inputs:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | absolute path to the video file |

**Output:**

```json
{
  "filename": "C0048.MP4",
  "duration": 45.234,
  "duration_ms": 45234,
  "width": 3840, "height": 2160,
  "aspect_ratio": "16:9",
  "fps": 29.97,
  "codec": "h264",
  "has_audio": true,
  "file_size_bytes": 120123456,
  "file_size_mb": 114.6,
  "output_resolutions": [
    {"aspect_ratio": "16:9", "width": 3840, "height": 2160, "note": "matches source — no crop"},
    {"aspect_ratio": "9:16", "width": 1214, "height": 2160, "note": "crops 68% from sides"}
  ]
}
```

Use `output_resolutions` to warn the user before applying an aspect ratio that heavily crops content.

## `reelabs_transcribe`

Chirp speech-to-text with word-level timestamps. Writes `{source}.transcript.md` and `{source}.words.json` to the project folder.

**Inputs:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | absolute path to video or audio |
| `project` | string | no | project slug; derived from path's parent dir if omitted |

**Output:**

Returns the compact markdown transcript inline plus `flagged_words` and `flagged_utterances` (heuristic flags for pre-render review).

```json
{
  "transcript_id": "project/source",
  "word_count": 150,
  "duration_seconds": 45.2,
  "mode": "sync",
  "transcript_markdown": "# Transcript: file.mp4\n\n- [0:00.00 – 0:02.50] ...",
  "flagged_words": [...],
  "flagged_utterances": [...]
}
```

`mode` is `"sync"` for audio ≤55s, `"chunked-sync (N chunks)"` for longer files.

## `reelabs_transcript`

Rehydrate or list transcripts. Pair with a compound `project/source` id.

**Actions:** `list`, `get`.

## `reelabs_render`

Render a video from a RenderSpec. See `reference/render-spec.md` for the spec shape.

**Output:**

```json
{
  "render_id": 1,
  "output_path": "/path/to/output.mp4",
  "duration_seconds": 25.4,
  "file_size_bytes": 52428800,
  "file_size_mb": 50.0,
  "status": "completed",
  "segments_processed": 3,
  "captions_applied": true,
  "caption_word_count": 120,
  "codec": "hevc",
  "resolution": "1080x1920",
  "fps": 30.0,
  "aspect_ratio": "9:16"
}
```

## `reelabs_validate`

Pre-flight check on a RenderSpec. Verifies sources exist, segments are in range, overlays reference valid sources, output path is writable.

## `reelabs_silence_remove`

Given a transcript, emit segments that skip silent gaps. Ready to drop into a RenderSpec.

**Inputs:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `transcript_id` | string | yes | — | `project/source` |
| `gap_threshold` | number | no | 0.4 | gaps ≥ this many seconds get skipped |
| `padding` | number | no | 0.15 | seconds of pad before/after each utterance |

**Output:** `{segments, gaps_removed, time_saved_seconds, original_duration_seconds}`.

## `reelabs_speaker_detect`

Multi-mic multi-speaker detection. Given transcripts from N synchronized sources, returns segments cutting to whoever is speaking. Deterministic — trust its output over eyeballed cuts.

**Inputs:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `sources` | array | yes | — | `[{sourceId, transcriptId}]` — at least 2 |
| `min_segment_length` | number | no | 1.0 | absorb-threshold for short detections |

**Output:**

```json
{
  "sources_processed": 2,
  "total_duration_seconds": 120.5,
  "speaker_switches": 14,
  "segments": [{"sourceId": "A", "start": 0.0, "end": 12.3}, ...],
  "source_stats": [
    {"sourceId": "A", "word_count": 420, "total_speaking_seconds": 82.3}
  ]
}
```

## `reelabs_analyze`

Extract frames for visual analysis. Delegate the actual scene interpretation to a sub-agent — don't do frame-by-frame work inline.

**Actions:** `extract`, `store`, `get`.

**`extract`:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `action` | `"extract"` | yes | — | |
| `path` | string | yes | — | |
| `sample_fps` | number | no | 1.0 | |

Returns `{analysis_id, frame_count, frames_dir, frames}`.

**`store`:**

Persist a sub-agent's scene descriptions. Each scene has `{start_time, end_time, description, tags?, scene_type?}`.

**`get`:**

Retrieve a stored analysis with scenes.

## `reelabs_rerender`

Apply partial overrides to a previous render's spec and re-render. Use for tweaking captions, quality, or overlays without resending the full spec.

**Inputs:** `render_id` (required), `overrides` (optional partial RenderSpec), `output_path` (optional).

## `reelabs_graphic`

Render HTML/CSS to a PNG. Use for title cards, lower thirds, thumbnails. Output is typically used as an `imagePath` in an overlay.

**Inputs:** `html` (required), `width`, `height` (required), `output_path` (optional), `timeout` (optional).

## `reelabs_layout`

Generate overlay arrays for screen-recording compositions (PiP, split, speaker-focus). Takes a screen + speaker source and a layout timeline, returns overlays ready to drop into a RenderSpec.

**Layouts:** `pip_small`, `pip_medium`, `split`, `speaker_focus`, `screen_only`, `speaker_only`.

**Inputs:** `screen`, `speaker` (source IDs), `aspectRatio`, `timeline` (array of `{layout, start, end}`), `style` (optional overrides).

## `reelabs_extract_audio`

Extract a video's audio as M4A (AAC passthrough — no re-encoding). Useful when handing off to an external audio editor.

**Inputs:** `path` (required), `output_path` (optional).

## `reelabs_project`, `reelabs_asset`, `reelabs_preset`

Organizational CRUD tools. See each tool's action list for the available verbs. All persistent state is plain markdown files under `{dataRoot}/`.
