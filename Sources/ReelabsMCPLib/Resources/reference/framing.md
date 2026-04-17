# Framing — Reference

How the renderer animates each segment's zoom, pan, and scale over time. Configured via a named preset (file in `presets/framing/`) that compiles into `transform` or `keyframes` on each segment of the RenderSpec.

## How framing works

- A segment has either a static `transform` (constant zoom/pan for its full duration) or `keyframes` (an array of `{time, scale, panX, panY}` points interpolated linearly between them).
- `scale: 1.0` = cover-fit. Values >1 zoom in; values <1 are ignored (renderer enforces cover-fit).
- `panX` is inverted from intuition: **positive** panX shows more of the **LEFT** of the source; **negative** shows more of the **RIGHT**.
- `panY` is positive-down: positive panY shows more of the **TOP** of the source.
- Keyframes produce smooth camera motion. Switching static `transform` values between segments produces hard camera cuts (useful for the `hard_cut` pattern).

## Preset shapes

Framing presets come in two kinds:

**Keyframe arc** (animated) — `kind: keyframes`. Emits a pair of keyframes per segment that span its full duration.

**Static transform** — `kind: static`. Emits a constant `transform` on each segment.

## Fields

| Field | Type | Notes |
|-------|------|-------|
| `kind` | `keyframes` or `static` | which compile path to use |
| `startScale` / `endScale` | number | keyframe arc: zoom at start and end |
| `startPanX` / `endPanX` | number | keyframe arc: pan X at start and end (-1 to 1) |
| `startPanY` / `endPanY` | number | keyframe arc: pan Y at start and end (-1 to 1) |
| `scale` | number | static: constant zoom |
| `panX` / `panY` | number | static: constant pan |
| `duration` | `segment` or number | keyframe arc: how long it spans — `segment` = full length |

## How to add a new framing preset

1. Copy `presets/framing/subtle.md` (for animated motion) or the closest `kind: static` preset.
2. Rename the file and update `name:` in the frontmatter.
3. Tweak the fields. A useful calibration: `endScale - startScale < 0.08` feels subtle; `0.1–0.2` feels alive; `>0.25` is aggressive. Long segments with large scale changes feel like slow zooms; short segments with the same change feel punchy.
4. Below the frontmatter, write a paragraph: what the motion feels like, which flows suit it, what to use instead for different moods.

No code change. Immediately usable by any flow or render.
