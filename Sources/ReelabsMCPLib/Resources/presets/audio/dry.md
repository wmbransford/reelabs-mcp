---
category: audio
name: dry
musicVolume: 0.0
passthrough: auto
---

# Dry

Clean source audio. No background music. `passthrough: auto` lets the renderer skip audio re-encoding when no other mixing is happening — fastest export path.

**Reach for this when:** podcasts, interviews, talking-head content — anywhere the source audio is the point and any music would distract.

**Reach for something else when:**
- You want a mood bed behind dialogue → try `podcast_bed` (quiet music at 0.1).
- You're layering voiceover over b-roll → try `vo_over_music`.
- You want silence replaced with a tone or ambience → write a custom preset with `musicPath` set.
