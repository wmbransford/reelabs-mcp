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

**overlays** (optional) — overlay tracks composited on top of the main video. Four overlay types:

1. **Video overlay** — `sourceId` present. B-roll, PiP, etc. Source must be in the `sources` array.
2. **Image overlay** — `imagePath` present. Static image from disk (PNG, JPEG, etc.). Use with `reelabs_graphic` output.
3. **Color overlay** — `backgroundColor` present (no `sourceId`, no `imagePath`, no `text`). Solid color rectangle.
4. **Text overlay** — `text` present. Text card with optional background.

Type is inferred from field presence (priority: `sourceId` > `imagePath` > `text` > color). Coordinates use 0.0-1.0 fractions of the render size with top-left origin.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `sourceId` | string | — | required for video overlays, omit for color/text |
| `start` | double | — | composition timeline: when overlay appears (seconds) |
| `end` | double | — | composition timeline: when overlay disappears (seconds) |
| `x` | double | — | 0.0-1.0 fraction from left edge |
| `y` | double | — | 0.0-1.0 fraction from top edge |
| `width` | double | — | 0.0-1.0 fraction of render width |
| `height` | double | — | 0.0-1.0 fraction of render height |
| `opacity` | double | 1.0 | 0.0 (invisible) to 1.0 (fully opaque) |
| `sourceStart` | double | 0 | offset into overlay source file (video overlays only) |
| `zIndex` | int | 0 | stacking order — higher values render on top |
| `audio` | double | 0 | overlay audio volume 0.0-1.0 (video overlays only) |
| `cornerRadius` | double | 0 | 0.0 (sharp) to 1.0 (circle/pill). Maps to `cornerRadius * min(w,h) / 2` pixels |
| `crop` | object | — | sub-region of source: `{x, y, width, height}` as 0-1 fractions (video overlays only) |
| `backgroundColor` | string | — | hex color `#RRGGBB` or `#RRGGBBAA`. Required for color overlays, optional for text |
| `text` | object | — | text card config (see below). Makes this a text overlay |
| `imagePath` | string | — | absolute path to image file (PNG, JPEG). Makes this an image overlay |
| `fadeIn` | double | 0 | seconds for opacity fade-in at overlay start |
| `fadeOut` | double | 0 | seconds for opacity fade-out at overlay end |

**text** object (TextOverlayConfig):

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `title` | string | — | title text (rendered larger, bold) |
| `body` | string | — | body text (rendered smaller, regular) |
| `titleColor` | string | "#FFFFFF" | hex color for title |
| `bodyColor` | string | "#FFFFFF" | hex color for body |
| `titleFontSize` | double | 48 | points |
| `bodyFontSize` | double | 32 | points |
| `titleFontWeight` | string | "bold" | font weight |
| `bodyFontWeight` | string | "regular" | font weight |
| `fontFamily` | string | "Arial" | font family |
| `alignment` | string | "center" | "left", "center", "right" |
| `padding` | double | 0.08 | 0.0-1.0 fraction of overlay size |

Video overlay sources must be declared in the `sources` array. Video overlay duration is auto-clamped to available source media if it exceeds the source length.

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

Example — Color overlay (semi-transparent black lower third):
```json
{
  "overlays": [
    {
      "backgroundColor": "#00000080",
      "start": 2.0, "end": 8.0,
      "x": 0.0, "y": 0.6, "width": 1.0, "height": 0.4
    }
  ]
}
```

Example — Text card with fade in/out:
```json
{
  "overlays": [
    {
      "text": {
        "title": "Key Takeaway",
        "body": "Users prefer simple onboarding flows",
        "titleColor": "#FFD700",
        "alignment": "left"
      },
      "backgroundColor": "#000000CC",
      "start": 5.0, "end": 12.0,
      "x": 0.05, "y": 0.6, "width": 0.9, "height": 0.3,
      "cornerRadius": 0.05,
      "fadeIn": 0.3, "fadeOut": 0.3
    }
  ]
}
```

Example — Image overlay from `reelabs_graphic` (lower third PNG):
```json
{
  "overlays": [
    {
      "imagePath": "/path/to/lower-third.png",
      "start": 2.0, "end": 10.0,
      "x": 0.0, "y": 0.75, "width": 1.0, "height": 0.25,
      "fadeIn": 0.3, "fadeOut": 0.3
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

## Custom Presets

### Caption Preset: `william`

| Field | Value |
|-------|-------|
| `fontFamily` | Poppins |
| `fontWeight` | bold |
| `color` | #FAF9F5 (cream) |
| `highlightColor` | #D97757 (burnt orange) |
| `wordsPerGroup` | 3 |
| `allCaps` | true |
| `shadow` | true |
| `position` | 70 |
| `punctuation` | false |

Karaoke style — the active word highlights in burnt orange, the rest display in cream.

### Keyframe Patterns

#### `engaging` (default)

Alternating segments: slow push in (scale 1.0 → 1.15 over ~4s), then pull back (1.15 → 1.0). Keeps footage alive without being jarring.

```json
// Segment A — push in
"keyframes": [{"time": 0, "scale": 1.0}, {"time": 4, "scale": 1.15}]

// Segment B — pull back
"keyframes": [{"time": 0, "scale": 1.15}, {"time": 4, "scale": 1.0}]
```

#### `hard_cut_emphasis`

Every 7–12 seconds, split the segment and alternate between scale 1.0 (normal) and 1.2 (punched in). No smooth keyframe animation — instant scale jump creates a hard cut feel. Prefer splitting at sentence boundaries from the transcript. The zoom level (default 1.2) is configurable.

```json
// Segment 1 — normal
"transform": {"scale": 1.0}

// Segment 2 — punched in (split at sentence boundary)
"transform": {"scale": 1.2}

// Segment 3 — normal
"transform": {"scale": 1.0}
```

#### `subtle`

Scale 1.0 → 1.05 over 10+ seconds. Barely perceptible drift for calm, reflective moments.

```json
"keyframes": [{"time": 0, "scale": 1.0}, {"time": 12, "scale": 1.05}]
```

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

## Re-render

`reelabs_rerender` loads a previous render's spec, applies partial overrides, and re-renders. Useful for tweaking captions, quality, or overlays without resending the entire spec.

**Inputs:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `render_id` | int | yes | ID of the previous render (from `reelabs_render` response) |
| `overrides` | object | no | Partial RenderSpec — only the fields you want to change |
| `output_path` | string | no | Override output path. Auto-generated if omitted |

**Override examples:**

Change caption preset:
```json
{
  "render_id": 1,
  "overrides": {
    "captions": {"preset": "subtitle", "position": 85}
  }
}
```

Switch to HEVC codec:
```json
{
  "render_id": 1,
  "overrides": {
    "quality": {"codec": "hevc"}
  }
}
```

Overrides are deep-merged: nested objects (captions, audio, quality) merge field-by-field, while arrays (sources, segments, overlays) replace entirely. The original render is preserved — a new render record is created.

## Graphic Render

`reelabs_graphic` renders HTML/CSS to a PNG image. Use it to generate title cards, lower thirds, thumbnails, or any visual graphic that can be expressed as HTML. The output PNG can be used as an overlay source in a RenderSpec.

**Inputs:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `html` | string | yes | — | HTML to render. Inline all CSS — no external stylesheets or images |
| `width` | int | yes | — | Output width in pixels (1–7680) |
| `height` | int | yes | — | Output height in pixels (1–7680) |
| `output_path` | string | no | `./Generated Graphics/{uuid}.png` | Absolute path for the output PNG |
| `timeout` | double | no | 10 | Render timeout in seconds |

**Output:**

```json
{
  "output_path": "/path/to/graphic.png",
  "width": 1920,
  "height": 1080,
  "file_size_bytes": 45230,
  "file_size_kb": 44.2
}
```

**Transparency:** The renderer has a transparent background by default. Set `background-color` in your HTML/CSS to add a background, or leave it transparent for compositing as an overlay.

**Tips:**
- Always use the source video's resolution from your probe results — this ensures pixel-perfect overlays at any resolution (1080p, 4K, etc.). For partial overlays like lower thirds, use the probed width with a custom height.
- All styles must be inline or in `<style>` tags — external URLs are not loaded
- macOS system fonts are available (Arial, Helvetica, SF Pro, etc.)
- Use `viewport` meta tag if needed: `<meta name="viewport" content="width={width}">`
- For 9:16 vertical content, use the probed resolution from a 9:16 source, or explicit width/height if no source video exists

**Example — Title card with gradient background:**
```json
{
  "html": "<div style='width:100%;height:100%;display:flex;align-items:center;justify-content:center;background:linear-gradient(135deg,#667eea,#764ba2);font-family:Arial'><h1 style='color:white;font-size:72px;text-align:center'>My Video Title</h1></div>",
  "width": 1920,
  "height": 1080
}
```

**Example — Transparent lower third:**
```json
{
  "html": "<div style='position:absolute;bottom:0;left:0;right:0;padding:24px 32px;background:linear-gradient(transparent,rgba(0,0,0,0.8))'><div style='font-family:Arial;color:white;font-size:36px;font-weight:bold'>Speaker Name</div><div style='font-family:Arial;color:#ccc;font-size:24px;margin-top:8px'>CEO, Example Corp</div></div>",
  "width": 1920,
  "height": 200
}
```

## Layout Tool

`reelabs_layout` generates overlay arrays for screen recording layouts — PiP, split-screen, speaker focus, etc. It takes a screen source, speaker source, and a timeline of layout switches, and returns overlays ready to drop into a RenderSpec.

**Inputs:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `screen` | string | yes | — | Source ID of the screen recording |
| `speaker` | string | yes | — | Source ID of the speaker/facecam |
| `aspectRatio` | string | no | `"16:9"` | Target aspect ratio: `"16:9"`, `"9:16"`, `"1:1"`, `"4:5"` |
| `timeline` | array | yes | — | Array of `{layout, start, end}` objects |
| `style` | object | no | — | Optional style overrides (see below) |

**timeline** entries:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `layout` | string | yes | Layout name (see table below) |
| `start` | double | yes | Start time in seconds |
| `end` | double | yes | End time in seconds |

**style** fields (all optional):

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cornerRadius` | double | 0.15 | Speaker corner radius 0-1 |
| `padding` | double | 0.02 | Edge padding 0-1 |
| `speakerCrop` | object | — | Crop speaker source: `{x, y, width, height}` as 0-1 fractions |
| `background` | string | `"#1a1a2e"` | Background color hex for split/focus layouts |
| `transitionDuration` | double | 0.4 | Crossfade duration between layouts in seconds |

**Available layouts (16:9 landscape):**

| Layout | Screen | Speaker | Background |
|--------|--------|---------|------------|
| `pip_small` | full frame | bottom-left, small (22%) | none |
| `pip_medium` | full frame | bottom-left, medium (35%) | none |
| `split` | right 58% | left 30% | yes |
| `speaker_focus` | bottom-right 38% | center-left 55% | yes |
| `screen_only` | full frame | hidden | none |
| `speaker_only` | hidden | full frame | none |

For `9:16` portrait, positions auto-adjust: PiP moves to bottom-center, split stacks vertically.

**Output:**

```json
{
  "overlays": [...],
  "layout_count": 3,
  "notes": "3 layout sections (pip_small, split), 90.0s total. Screen source \"screen\" as base segment provides audio."
}
```

The `overlays` array goes directly into a RenderSpec. The screen source should also be the base segment (for audio and timeline). Speaker audio is muted in the overlays.

**Compositing approach:**
- Base segment uses the screen source (provides audio + timeline)
- Screen overlay (same source, `audio: 0`) provides the visual at the right position
- Speaker overlay provides the facecam
- Background color overlay appears for layouts that need it (split, speaker_focus)
- Transitions use `fadeIn`/`fadeOut` on incoming/outgoing layout sections

**Example — Tutorial with PiP intro, split explanation, back to PiP:**

```json
{
  "screen": "screen",
  "speaker": "cam",
  "aspectRatio": "16:9",
  "timeline": [
    {"layout": "pip_small", "start": 0, "end": 30},
    {"layout": "split", "start": 30, "end": 60},
    {"layout": "pip_small", "start": 60, "end": 90}
  ],
  "style": {
    "cornerRadius": 0.15,
    "speakerCrop": {"x": 0.15, "y": 0, "width": 0.7, "height": 1.0},
    "background": "#1a1a2e"
  }
}
```

Use the returned overlays in a render:
```json
{
  "sources": [
    {"id": "screen", "path": "/path/to/screen.mp4"},
    {"id": "cam", "path": "/path/to/camera.mp4"}
  ],
  "segments": [
    {"sourceId": "screen", "start": 0, "end": 90}
  ],
  "overlays": [... from reelabs_layout response ...],
  "outputPath": "/path/to/output.mp4"
}
