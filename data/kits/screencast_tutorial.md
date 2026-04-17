---
name: screencast_tutorial
description: Screen recording + speaker cam for tutorials and demos
aspectRatio: "16:9"
captionPreset: screencast_clean
keyframePattern: none
codec: h264
padding: 0.2
musicVolume: 0.0
---

# Screencast Tutorial

## Format
16:9 landscape. Screen recording as the base (provides the timeline and audio). Speaker cam as a PiP overlay or split-screen section. Clean low-distraction captions at the bottom (`screencast_clean`). H.264 for broad compatibility.

## Sources required
- A **screen** recording (the base — must contain the narration audio)
- A **speaker** cam (facecam, optional — kit also works with screen-only)

## Workflow

1. **Probe both sources** — note durations. They should roughly match. If durations diverge significantly, ask which one to use for the timeline.
2. **Transcribe** the source that has clean narration audio (usually the screen recording, since it's what you'll cut from).
3. **Plan the layout timeline** — ask the user where they want PiP vs. split vs. speaker-only vs. screen-only. Default is PiP for intro/outro, screen-only for the demo middle.
4. **Generate overlays** with `reelabs_layout`, passing the screen and speaker source IDs and the timeline.
5. **Build segments** from the screen source — one segment spanning the full narration, or multiple segments if cutting dead air (use `reelabs_silence_remove` on the screen transcript if there's enough silence to matter).
6. **Verification checkpoint** — flag suspicious transcript words, show the layout timeline in plain English ("0–15s: PiP, 15–90s: screen only, 90–105s: PiP"), wait for confirmation.
7. **Render** — screen source as base segment, layout overlays from step 4, `aspectRatio: "16:9"`, `captions: {preset: "screencast_clean"}`, `quality: {codec: "h264"}`.

## Variants

- **`screen-only`** — skip the speaker source entirely. Useful when there's no facecam. Still captions the narration.
- **`speaker-focus-intro`** — open with `speaker_only` layout for 5–10s, then switch to `pip_small` for the demo. Feels more personal.
- **`vertical`** — override `aspectRatio` to `"9:16"`. Layout tool auto-adjusts (PiP moves to bottom-center, split stacks vertically). Useful for mobile-first tutorials.

## Key points

- The **screen source is always the base segment** — it provides audio and the timeline.
- If the screen recording doesn't have the speaker's audio, use the speaker source as the base instead and put the screen as an overlay.
- Use `speakerCrop: {x: 0.15, y: 0, width: 0.7, height: 1.0}` in the layout style to crop empty space around a webcam subject.
