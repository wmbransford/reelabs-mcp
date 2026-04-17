---
category: audio
name: podcast_bed
musicVolume: 0.1
passthrough: auto
---

# Podcast Bed

A quiet music bed under dialogue-heavy content. Volume at 0.1 — audible but the voice stays clear. Supply `musicPath` at invoke time; the preset doesn't ship with a track.

**Reach for this when:** podcast intros/outros, interview clips where silence feels empty, reel compilations that need pacing.

**Reach for something else when:**
- Pure source audio, no music → use `dry`.
- Music as a co-star (music videos, mood pieces) → write a louder preset at `musicVolume: 0.3+`.
- Heavy dialogue where any music would distract → `dry`.
