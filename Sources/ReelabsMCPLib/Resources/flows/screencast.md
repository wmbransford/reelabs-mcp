---
name: screencast
description: Screen recording plus speaker cam, composed via layout presets (PiP, split, speaker focus). Guided.
captions: screencast_clean
audio: dry
codec: hevc
---

# Screencast

Screen recording plus a speaker camera. This flow composites the two sources using layout sections — PiP for intro moments, split for focused explanation, speaker-only for emphasis. Good for tutorials, product walkthroughs, educational content.

**Sources required:** one screen recording (includes any relevant system audio), one speaker cam with mic. Both time-synced — started and stopped together.

**The essentials:**

Probe both sources. Transcribe the speaker cam for captions. Ask the user to describe the video's structure ("intro, then a deep dive on X, then a wrap") so the flow knows where layout transitions belong; if no structure is given, default to PiP throughout.

Call `reelabs_layout` with the screen and speaker source IDs plus a timeline of layout sections. The tool returns an overlays array — drop it directly into the RenderSpec. The screen source is also the base segment, providing audio and timeline.

**One verification checkpoint.** Before rendering, send the user a single message with:
- The layout timeline (what appears when, and for how long)
- Caption word count and any `flagged_words` from the speaker cam's transcript
- The flow settings and any overrides

Wait for "go." If they tweak layout timings or swap a PiP for a split, apply and render — don't re-verify.

**No framing motion is applied by default** — screen content speaks for itself, and pan/scale animation on a screen recording is distracting. Omit `framing` unless you specifically want camera motion on the speaker cam crop.

**Aspect ratio** defaults to 16:9. Override at invoke time if needed.

**Variants worth knowing about:**
- **Speaker-free explainer** — if there's no facecam, use `flows/narrated_slideshow.md` with the screen recording as the visual.
- **With music bed** — override `audio: podcast_bed`. Use sparingly; music competes with voice clarity in dialogue-heavy content.
- **Vertical tutorial for mobile** — override aspect to 9:16 at invoke time; pick layouts that keep the screen prominent (`pip_small` rather than `split`).
