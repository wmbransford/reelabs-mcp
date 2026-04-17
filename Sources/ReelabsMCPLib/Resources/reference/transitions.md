# Transitions — Reference

Named visual transitions applied at segment boundaries. Configured via presets (`presets/transitions/`) or inline in a RenderSpec.

## How transitions work

- A transition is set on a segment; it affects the boundary between that segment and the next.
- No transition = hard cut (the default, often the right choice).
- Currently supported: `crossfade` (fade-dissolve between segments).
- `duration` determines how long the transition takes. Too long and dissolves feel like old wedding tapes; too short and they're imperceptible.

## Fields

| Field | Type | Notes |
|-------|------|-------|
| `type` | string | `crossfade` — more types will need compositor code |
| `duration` | number | seconds |

## How to add a new transition preset

1. Copy the closest existing preset (typically `crossfade_short.md`).
2. Rename the file and update `name:` in the frontmatter.
3. Adjust `duration`. Calibration:
   - **0.2–0.4s** — softens a cut without calling attention to itself.
   - **0.5–0.8s** — reads as a deliberate dissolve.
   - **>1s** — editorial and rare; use for passage-of-time or mood shifts.
4. Write a short paragraph: the feeling, when to reach for it, and which adjacent presets suit which moods.

Adding a new `type` (e.g. `whip`, `flash`, `wipe`) requires code changes in the compositor — ask before inventing one.
