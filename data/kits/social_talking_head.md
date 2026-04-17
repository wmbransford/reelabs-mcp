---
name: social_talking_head
description: Vertical talking-head for TikTok, Reels, Shorts — karaoke captions, gentle zoom
aspectRatio: "9:16"
captionPreset: william
keyframePattern: engaging
codec: hevc
padding: 0.15
musicVolume: 0.0
---

# Social Talking Head

## Format
9:16 vertical. Burnt-orange karaoke captions (`william` preset). Gentle push-in/pull-back zoom alternating across segments for movement without distraction. HEVC for smaller files at the same quality.

## Workflow

1. **Probe** the source — note duration and resolution. Warn if source is landscape (will be center-cropped).
2. **Transcribe** the source.
3. **Cut** — run `reelabs_silence_remove` with `gap_threshold: 0.4, padding: 0.15`. Drop the returned segments into the spec.
4. **Review cuts** — show the user: number of segments, total duration, time saved. Offer to filter any obvious retakes or off-topic tangents.
5. **Verification checkpoint** — flag any suspicious words from the transcript (short, unusual, near long gaps, near-duplicates). Show the segment summary. Wait for user confirmation.
6. **Apply engaging keyframes** — for each segment, alternate between push-in `[{time: 0, scale: 1.0}, {time: segment_duration, scale: 1.15}]` and pull-back `[{time: 0, scale: 1.15}, {time: segment_duration, scale: 1.0}]`. Skip keyframes on segments shorter than 2s.
7. **Render** with `aspectRatio: "9:16"`, `captions: {preset: "william"}`, `quality: {codec: "hevc"}`.

## Variants

- **`no-captions`** — omit the `captions` block. Swap engaging zoom for `hard_cut_emphasis` (split at sentence boundaries, alternate scale 1.0 / 1.2) so the visual stays interesting without text.
- **`with-music`** — add `audio: {musicPath: "...", musicVolume: 0.15}`. Music ducks under dialogue.
- **`pink`** — use `social_karaoke_pink` caption preset instead of `william` for a hot-pink highlight.
- **`white`** — use `social_karaoke_white` caption preset for a monochrome look (white on white outline, no colored highlight).
