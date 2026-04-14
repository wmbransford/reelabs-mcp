# ReeLabs Technical Reference

## Transcribe Response

`reelabs_transcribe` returns a compact transcript grouped by silence gaps (>= 400ms).

```json
{
  "transcript_id": 1,
  "word_count": 150,
  "duration_seconds": 45.2,
  "source_path": "/path/to/file.mp4",
  "mode": "sync",
  "transcript": [
    {"start": 0.0, "end": 2.5, "text": "This is the opening statement"},
    {"gap": 0.8},
    {"start": 3.3, "end": 5.1, "text": "And here is the response"},
    {"gap": 2.1},
    {"start": 7.6, "end": 12.3, "text": "Actually let me start over"}
  ]
}
```

- **Utterance**: `{"start", "end", "text"}` — words grouped between silence gaps, timestamps in seconds (1 decimal).
- **Gap**: `{"gap": seconds}` — silence >= 400ms between utterances.
- **mode**: `"sync"` for audio <= 60s, `"batch (GCS)"` for longer files.

Word-level timestamps are stored internally in the database and used automatically by the caption renderer. The agent works with utterance-level timestamps for segment selection.

## Silence Remove Response

`reelabs_silence_remove` analyzes a transcript and returns segments that skip silent gaps, ready to drop into a RenderSpec.

**Inputs:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `transcript_id` | int | yes | — | Transcript to process |
| `gap_threshold` | double | no | 0.4 | Remove gaps >= this many seconds |
| `padding` | double | no | 0.15 | Seconds of padding before/after each utterance |

**Output:**

```json
{
  "source_path": "/path/to/source.mp4",
  "transcript_id": 1,
  "gap_threshold": 0.4,
  "gaps_removed": 5,
  "time_saved_seconds": 8.2,
  "original_duration_seconds": 45.2,
  "segments": [
    {"sourceId": "main", "start": 0.0, "end": 2.65},
    {"sourceId": "main", "start": 3.15, "end": 5.25},
    {"sourceId": "main", "start": 7.45, "end": 12.45}
  ]
}
```

- **segments** use `sourceId: "main"` by convention — replace if your source uses a different ID.
- Segments are padded, clamped to `[0, duration]`, and merged when padding causes overlap.
- Drop the `segments` array directly into a RenderSpec, or adjust individual segments before rendering.

## Visual Analysis

`reelabs_analyze` extracts frames from video for visual analysis by a vision-capable sub-agent. Results are stored for later querying.

### Extract Action

Extracts frames at a given sample rate and saves them as 720px JPEGs.

**Inputs:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `action` | string | yes | — | `"extract"` |
| `path` | string | yes | — | Absolute path to video file |
| `sample_fps` | double | no | 1.0 | Frames per second to sample |
| `asset_id` | int | no | — | Optional asset ID to link analysis to |

**Output:**

```json
{
  "analysis_id": 1,
  "duration_seconds": 120.5,
  "frame_count": 121,
  "sample_fps": 1.0,
  "frames_dir": "~/Library/Application Support/ReelabsMCP/frames/1/",
  "frames": [
    {"time": 0.0, "path": "/full/path/to/frame_0000.jpg"},
    {"time": 1.0, "path": "/full/path/to/frame_0001.jpg"}
  ]
}
```

### Store Action

Persists scene analysis from a sub-agent.

**Inputs:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | yes | `"store"` |
| `analysis_id` | int | yes | From extract response |
| `scenes` | array | yes | Array of scene objects |

Each scene object:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `start_time` | double | yes | Scene start in seconds |
| `end_time` | double | yes | Scene end in seconds |
| `description` | string | yes | What happens visually |
| `tags` | string[] | no | Descriptive tags |
| `scene_type` | string | no | Classification (e.g. "talking_head", "demo", "b-roll") |

**Output:**

```json
{
  "analysis_id": 1,
  "scenes_stored": 5,
  "status": "analyzed"
}
```

### Get Action

Retrieves a stored analysis with all scenes.

**Inputs:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | yes | `"get"` |
| `id` | int | yes | Analysis ID |

**Output:**

```json
{
  "analysis_id": 1,
  "source_path": "/path/to/video.mp4",
  "status": "analyzed",
  "sample_fps": 1.0,
  "duration_seconds": 120.5,
  "frame_count": 121,
  "scene_count": 5,
  "frames_dir": "~/Library/Application Support/ReelabsMCP/frames/1/",
  "scenes": [
    {
      "scene_index": 0,
      "start_time": 0.0,
      "end_time": 15.3,
      "description": "Host introduces the topic at desk",
      "tags": ["intro", "talking_head"],
      "scene_type": "talking_head"
    }
  ]
}
```

## RenderSpec Format

```json
{
  "sources": [
    {"id": "main", "path": "/absolute/path/to/video.mp4"}
  ],
  "segments": [
    {"sourceId": "main", "start": 0.0, "end": 8.55},
    {"sourceId": "main", "start": 12.0, "end": 25.85}
  ],
  "captions": {
    "preset": "tiktok",
    "transcriptId": 1
  },
  "aspectRatio": "9:16",
  "outputPath": "/absolute/path/to/output.mp4"
}
```

## Fields

**sources** (required) — array of `{id, path, transcriptId?}`. Referenced by segments via `sourceId`.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `id` | string | yes | unique identifier, referenced by segments |
| `path` | string | yes | absolute path to video file |
| `transcriptId` | int | no | transcript for this source (enables multi-source captions) |

**segments** (required) — ordered array. Multiple segments = multiple cuts joined together.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `sourceId` | string | — | must match a source id |
| `start` | double | — | seconds — use utterance timestamps from transcript |
| `end` | double | — | seconds — use utterance timestamps from transcript |
| `speed` | double | 1.0 | 0.25x – 4.0x |
| `volume` | double | 1.0 | 0.0 – 1.0 |
| `transform` | object | — | `scale`, `panX` (-1 to 1), `panY` (-1 to 1) — static for whole segment |
| `keyframes` | array | — | animated transform — array of `{time, scale, panX, panY}`. Overrides `transform` |
| `transition` | object | — | `type` ("crossfade"), `duration` (seconds) |

**captions** (optional):

Two ways to provide transcript IDs for captions:
1. **Per-source** (recommended for multi-source): set `transcriptId` on each source in the `sources` array. The renderer pulls words from the correct transcript for each segment automatically.
2. **Legacy single-transcript**: set `transcriptId` in the `captions` object. Works for single-source edits.

If any source has `transcriptId`, per-source mode is used. Otherwise, `captions.transcriptId` is used.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `preset` | string | — | "tiktok", "subtitle", "minimal", "bold_center" |
| `transcriptId` | int | — | legacy single-source mode — from `reelabs_transcribe` |
| `fontFamily` | string | "Arial" | font family name, e.g. "Arial", "Helvetica" |
| `fontSize` | double | 7.0 | percentage of video height |
| `fontWeight` | string | "bold" | "ultralight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black" |
| `color` | string | "#FFFFFF" | hex color |
| `highlightColor` | string | — | hex color for active word highlight (enables karaoke effect) |
| `position` | double | 70.0 | percentage from top |
| `allCaps` | bool | true | uppercase all caption text |
| `shadow` | bool | true | drop shadow behind text |
| `wordsPerGroup` | int | 3 | words shown per caption group |
| `punctuation` | bool | true | show punctuation in captions |

Inline fields override preset values. Omitted fields fall back to the preset.

Example — multi-source captions (each source has its own transcript):
```json
{
  "sources": [
    {"id": "A", "path": "/path/to/interview-q.mp4", "transcriptId": 1},
    {"id": "B", "path": "/path/to/interview-a.mp4", "transcriptId": 2}
  ],
  "segments": [
    {"sourceId": "A", "start": 0, "end": 8.5},
    {"sourceId": "B", "start": 2.0, "end": 15.0},
    {"sourceId": "A", "start": 12.0, "end": 20.0}
  ],
  "captions": {"preset": "tiktok"},
  "outputPath": "/path/to/output.mp4"
}
```

**audio** (optional) — background music mixing. Music is trimmed to composition length (no looping). If music is shorter than the video, it plays then silence.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `musicPath` | string | — | absolute path to music file (mp3, m4a, wav, aac) |
| `musicVolume` | double | 0.3 | 0.0 – 1.0, mixed under segment audio |

Example:
```json
{
  "audio": {
    "musicPath": "/path/to/song.mp3",
    "musicVolume": 0.25
  }
}
```

**quality** (optional) — export quality settings. Defaults to H.264 at preset quality matching the render resolution.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `codec` | string | "h264" | "h264" or "hevc" (HEVC = smaller files at same quality) |

Example:
```json
{
  "quality": {
    "codec": "hevc"
  }
}
```

**overlays** (optional) — video overlay tracks (B-roll, facecam PiP, etc.). Each overlay references a source declared in the `sources` array. Coordinates use 0.0-1.0 fractions of the render size with top-left origin.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `sourceId` | string | — | must match a source id |
| `start` | double | — | composition timeline: when overlay appears (seconds) |
| `end` | double | — | composition timeline: when overlay disappears (seconds) |
| `x` | double | — | 0.0-1.0 fraction from left edge |
| `y` | double | — | 0.0-1.0 fraction from top edge |
| `width` | double | — | 0.0-1.0 fraction of render width |
| `height` | double | — | 0.0-1.0 fraction of render height |
| `opacity` | double | 1.0 | 0.0 (invisible) to 1.0 (fully opaque) |
| `sourceStart` | double | 0 | offset into overlay source file (seconds) |
| `zIndex` | int | 0 | stacking order — higher values render on top |
| `audio` | double | 0 | overlay audio volume 0.0-1.0 (0 = muted) |
| `mainAudioVolume` | double | — | main track volume during overlay 0.0-1.0. Omit = unchanged. 0.0 = mute main, 0.3 = duck |
| `cornerRadius` | double | 0 | 0.0 (sharp) to 1.0 (circle/pill). Maps to `cornerRadius * min(w,h) / 2` pixels |
| `crop` | object | — | sub-region of source: `{x, y, width, height}` as 0-1 fractions. Selects region before cover-fill |

Overlay sources must be declared in the `sources` array just like segment sources.

Example — B-roll overlay (muted, center of screen, appears 5-15s):
```json
{
  "sources": [
    {"id": "main", "path": "/path/to/talking-head.mp4"},
    {"id": "broll", "path": "/path/to/broll-clip.mp4"}
  ],
  "segments": [
    {"sourceId": "main", "start": 0, "end": 30}
  ],
  "overlays": [
    {
      "sourceId": "broll",
      "start": 5.0, "end": 15.0,
      "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8,
      "sourceStart": 2.0
    }
  ],
  "outputPath": "/path/to/output.mp4"
}
```

Example — Facecam PiP (bottom-right corner, audio enabled):
```json
{
  "overlays": [
    {
      "sourceId": "facecam",
      "start": 0.0, "end": 25.0,
      "x": 0.72, "y": 0.72, "width": 0.25, "height": 0.25,
      "opacity": 1.0,
      "audio": 0.8,
      "zIndex": 1
    }
  ]
}
```

Example — Circular facecam with cropped source (center 70% of frame):
```json
{
  "overlays": [
    {
      "sourceId": "facecam",
      "start": 0, "end": 25,
      "x": 0.72, "y": 0.72, "width": 0.25, "height": 0.25,
      "cornerRadius": 1.0,
      "crop": {"x": 0.15, "y": 0.0, "width": 0.7, "height": 1.0},
      "audio": 0.8
    }
  ]
}
```

**resolution** (optional) — defaults to source. Accepts:
- Preset string: `"720p"`, `"1080p"`, `"4k"`
- Custom object: `{"width": 1920, "height": 1080}`

**fps** (optional) — defaults to source. Set explicitly to override (e.g. `30.0`, `60.0`).

**aspectRatio** (optional) — `"16:9"`, `"9:16"`, `"1:1"`, `"4:5"`. Omit to match source.

**outputPath** (required) — absolute path for output file.

## Render Response

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
  "music_applied": true,
  "music_volume": 0.25,
  "codec": "hevc",
  "resolution": "1080x1920",
  "fps": 30.0,
  "aspect_ratio": "9:16"
}
```

If `captions_applied` is false when you expected captions, check:
- Did you pass a valid `transcriptId`?
- Did you include `captions` in the spec?
- Invalid transcript IDs and preset names return explicit errors.

## Caption Presets

| Preset | Font | Weight | Color | Highlight | Position | Words | Caps | Punctuation |
|--------|------|--------|-------|-----------|----------|-------|------|-------------|
| `tiktok` | Arial | bold | #FFFFFF | #FFD700 (gold) | 70% | 3 | yes | yes |
| `subtitle` | Helvetica | medium | #FFFFFF | — | 90% | 6 | no | yes |
| `minimal` | Helvetica | light | #FFFFFF | — | 85% | 4 | no | yes |
| `bold_center` | Arial | bold | #FFFFFF | #00FF88 (green) | 50% | 2 | yes | yes |

Presets with `highlightColor` animate word-by-word: the active word lights up in the highlight color while others stay in the base color.

## Aspect Ratios

Output dimensions are derived from the source resolution, not hardcoded. A 4K source with `9:16` produces 2160x3840, not 1080x1920.

| Value | Ratio | Use case |
|-------|-------|----------|
| `16:9` | 1.778 | YouTube, landscape |
| `9:16` | 0.5625 | TikTok, Reels, Shorts |
| `1:1` | 1.0 | Instagram feed |
| `4:5` | 0.8 | Instagram post |

## Keyframes (Animated Transform)

Use `keyframes` on a segment to animate zoom/pan over time instead of a static `transform`. Requires 2+ keyframes. Interpolation is linear between consecutive keyframes.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `time` | double | — | seconds relative to segment start |
| `scale` | double | 1.0 | zoom level (1.0 = cover-fill) |
| `panX` | double | 0.0 | horizontal pan (-1 to 1) |
| `panY` | double | 0.0 | vertical pan (-1 to 1) |

Example — slow zoom in over 10 seconds:
```json
{
  "sourceId": "main", "start": 0, "end": 10,
  "keyframes": [
    {"time": 0, "scale": 1.0, "panX": 0, "panY": 0},
    {"time": 10, "scale": 1.5, "panX": 0.2, "panY": -0.1}
  ]
}
```

To simulate ease-in-out, add intermediate keyframes with closer spacing near the start and end. No code changes needed — just more keyframes in the spec.
