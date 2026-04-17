# RenderSpec — Reference

The declarative input to `reelabs_render`. Describes the edit: which sources are involved, which slices of them to assemble, which presets to apply, and where to write the result.

## Shape

```json
{
  "sources": [
    {"id": "main", "path": "/absolute/path/to/video.mp4", "transcriptId": "project/source"}
  ],
  "segments": [
    {"sourceId": "main", "start": 0.0, "end": 8.55},
    {"sourceId": "main", "start": 12.0, "end": 25.85}
  ],
  "captions": { "preset": "william" },
  "overlays": [ ... ],
  "audio": { "musicVolume": 0.0 },
  "resolution": "1080p",
  "fps": 30.0,
  "aspectRatio": "9:16",
  "quality": { "codec": "hevc" },
  "outputPath": "/absolute/path/to/output.mp4"
}
```

## Top-level fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `sources` | array | yes | `{id, path, transcriptId?}` — referenced by segments via `sourceId` |
| `segments` | array | yes | ordered slices to assemble (see below) |
| `captions` | object | no | caption config — see `reference/captions.md` |
| `overlays` | array | no | overlay track — see `reference/overlays.md` |
| `audio` | object | no | music + passthrough — see `reference/audio.md` |
| `aspectRatio` | string | no | `"16:9"`, `"9:16"`, `"1:1"`, `"4:5"`. Omit to match source. |
| `resolution` | string or object | no | `"720p"`, `"1080p"`, `"4k"`, or `{width, height}`. Defaults to source. |
| `fps` | number | no | frame rate override. Omit to match source. |
| `quality` | object | no | `{codec}` — `"h264"` or `"hevc"` |
| `outputPath` | string | yes | absolute path for the output file |

## Segment fields

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `sourceId` | string | — | must match a source id |
| `start` | number | — | seconds — use utterance timestamps from transcript |
| `end` | number | — | seconds — use utterance timestamps from transcript |
| `speed` | number | 1.0 | 0.25x – 4.0x |
| `volume` | number | 1.0 | 0.0 – 1.0 |
| `transform` | object | — | static `{scale, panX, panY}` for the whole segment |
| `keyframes` | array | — | animated transform — array of `{time, scale, panX, panY}`. Overrides `transform`. |
| `transition` | object | — | `{type: "crossfade", duration}` — see `reference/transitions.md` |

### panX / panY behavior

- `panX` is **inverted**: positive panX shows more of the **LEFT** of the source; negative shows more of the **RIGHT**.
- `panY` is positive-down: positive panY shows more of the **TOP** of the source.
- Range is -1 to 1 for both.

### scale

`scale: 1.0` is cover-fit. Values greater than 1 zoom in; values below 1 are ignored (renderer enforces cover-fit).

## Multi-source captions

For captions to attribute correctly across multiple sources, set `transcriptId` on each source:

```json
{
  "sources": [
    {"id": "A", "path": "/path/to/speaker-a.mp4", "transcriptId": "pod/mic-a"},
    {"id": "B", "path": "/path/to/speaker-b.mp4", "transcriptId": "pod/mic-b"}
  ],
  "segments": [
    {"sourceId": "A", "start": 0, "end": 8.5},
    {"sourceId": "B", "start": 2.0, "end": 15.0}
  ],
  "captions": {"preset": "interview_attribution"},
  "outputPath": "/path/to/out.mp4"
}
```

## Rendering happens in one pass

No two-pass "build then caption" step — captions, overlays, and keyframe transforms are composited per-frame by `VideoCompositor`. Plan the full spec, then render once.

## Resolution and cropping

Output dimensions are derived from source resolution (renderer preserves source detail by cropping rather than scaling). A 4K source at `aspectRatio: "9:16"` produces roughly 1214×2160, not 1080×1920. Use `reelabs_probe`'s `output_resolutions` field to preview exact dimensions and crop percentages before committing.

## Full response shape

See `reference/tools.md` under `reelabs_render` for the response envelope.
