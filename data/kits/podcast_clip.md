---
name: podcast_clip
description: Short podcast highlight with oversized captions
aspectRatio: "9:16"
captionPreset: podcast_big
keyframePattern: subtle
codec: hevc
padding: 0.15
musicVolume: 0.0
---

# Podcast Clip

## Format
9:16 vertical by default. Oversized bold captions (`podcast_big`) — the text is the main visual since podcast footage is often static or low-motion. Subtle scale drift keeps the frame from feeling frozen. HEVC.

## Sources required
- One or two podcast camera angles, OR a waveform/static video with audio.

## Workflow

1. **Probe source(s)** — note duration and resolution. If the source is 16:9, warn the user it will be center-cropped for 9:16.
2. **Transcribe** the narration source.
3. **Identify the clip** — ask the user for the highlight moment (timestamp range or keyword). Find that range in the transcript.
4. **Tight cut** — use `reelabs_silence_remove` with a tighter threshold (`gap_threshold: 0.3`) since podcast clips benefit from brisk pacing. Keep segments inside the highlight range.
5. **Propose + verify in one message** — show the clip duration and word count, any `flagged_words` / `flagged_utterances` from the transcribe response that fall inside the clip range (podcast transcription is prone to errors on proper nouns and industry jargon), and the kit settings. Wait for the user's "go". Do not re-prompt after they pick.
6. **Render** — `aspectRatio: "9:16"`, `captions: {preset: "podcast_big"}`, subtle keyframes `[{time: 0, scale: 1.0}, {time: segment_duration, scale: 1.03}]`, `quality: {codec: "hevc"}`.

## Variants

- **`square`** — override `aspectRatio` to `"1:1"` for Instagram feed.
- **`landscape`** — override `aspectRatio` to `"16:9"` for YouTube clips or X/Twitter posts.
- **`two-shot`** — if there are two sources (host + guest), follow the `interview_cut` workflow but keep the `podcast_big` caption style. Best for back-and-forth moments.
- **`with-music`** — add quiet transition music (`musicVolume: 0.08`). Typically only for the intro/outro of a clip compilation.
- **`hook-intro`** — prepend a 3s title-card overlay (use `reelabs_graphic` for the card image, then an image overlay 0–3s) with the clip's hook quote. Delays the actual clip start by 3s.
