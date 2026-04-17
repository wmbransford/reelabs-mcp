# Audio — Reference

Background music mixing and audio passthrough behavior. Configured via presets (`presets/audio/`) that set `audio` fields on the RenderSpec.

## How audio works

- Source segments carry their original audio. Per-segment `volume` controls how loud each segment's audio plays.
- Background music is optional — a single `musicPath` mixed under the segment audio at `musicVolume`.
- Music is trimmed to composition length (no looping). If the music file is shorter than the video, it plays then goes silent for the rest.
- `passthrough: auto` lets the renderer skip audio re-encoding entirely when no mixing is active (no volume ramps, no music, no transitions with audio). This is a real speedup — worth keeping as the default.

## Fields

| Field | Type | Notes |
|-------|------|-------|
| `musicPath` | string | absolute path to mp3 / m4a / wav / aac |
| `musicVolume` | number | 0–1, mixed under segment audio |
| `passthrough` | `auto` / `on` / `off` | audio re-encode behavior |

## How to add a new audio preset

1. Copy the preset closest to what you want.
2. Rename the file and update `name:` in the frontmatter.
3. Set `musicPath` to the absolute path if the preset includes music. For no music, omit it or set `musicVolume: 0`.
4. Calibrate `musicVolume` for the content:
   - **0.05–0.1** — dialogue-heavy content (podcast, interview). Music should be barely felt.
   - **0.15–0.25** — montages, b-roll, narrated content. Music is audible but the voice stays clear.
   - **0.3–0.5** — pure music or highly visual content. Music is a co-star.
5. Leave `passthrough: auto` unless you have a specific reason to force re-encoding.

No code change. Immediately usable by any flow or render.
