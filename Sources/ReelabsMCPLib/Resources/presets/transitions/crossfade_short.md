---
category: transitions
name: crossfade_short
type: crossfade
duration: 0.25
---

# Crossfade Short

Quick 0.25s crossfade between segments. Long enough to soften a hard cut, short enough to still feel like a cut rather than a dissolve.

Applied per-segment at its boundary:

```json
{
  "sourceId": "A",
  "start": 0, "end": 5,
  "transition": {"preset": "crossfade_short"}
}
```

**Reach for this when:** interview A/B cuts on natural pauses, podcast speaker switches, gentle passage-of-time edits.

**Reach for something else when:**
- The cut should land hard for emphasis → no transition, just a cut.
- You want a cinematic dissolve → try `crossfade_long` (0.6s).
- You need a flash/whip effect → try `flash` (not yet available — write your own).
