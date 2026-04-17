---
name: narrated_slideshow
description: Voiceover over images or short clips with Ken Burns zoom
aspectRatio: "16:9"
captionPreset: slideshow_serif
keyframePattern: ken_burns
codec: hevc
padding: 0.1
musicVolume: 0.2
---

# Narrated Slideshow

## Format
16:9 landscape. Voiceover narration over a sequence of images or short clips. Ken Burns zoom (slow scale + pan) on each segment to turn stills into moving shots. Clean serif lower-third captions (`slideshow_serif`). Soft background music under the narration. HEVC.

## Sources required
- One **narration** source (audio or video with voiceover)
- One or more **visual** sources (images converted to video, or short clips)

## Workflow

1. **Probe all sources** — note narration duration (this is the timeline length) and the visual source durations.
2. **Transcribe** the narration source.
3. **Plan the visual timeline** — map each sentence or idea in the narration to a visual. Ask the user to confirm the mapping if ambiguous. Each visual should cover 3–8 seconds of narration.
4. **Build segments** — the narration source provides audio, but visuals are shown as overlays covering the full frame. Structure:
   - Base segment = narration source (full duration, `volume: 1.0`)
   - Each visual = full-frame overlay (`x: 0, y: 0, width: 1, height: 1`) with its time range on the composition timeline
   - Use `crossfade` transitions between visuals (`fadeIn: 0.4, fadeOut: 0.4`)
5. **Apply Ken Burns keyframes** to each visual overlay — slow scale from 1.0 to 1.1 over the overlay duration, with a slight pan. Alternate pan direction per visual (`panX: 0.05` then `panX: -0.05`) to avoid monotony.
6. **Verification checkpoint** — flag suspicious words in the narration. Show the visual-to-narration mapping (e.g. "0–5s: image_01.jpg, 5–12s: image_02.jpg"). Wait for confirmation.
7. **Render** — `aspectRatio: "16:9"`, `captions: {preset: "slideshow_serif"}`, `audio: {musicPath: "...", musicVolume: 0.2}`, `quality: {codec: "hevc"}`.

## Variants

- **`no-music`** — set `musicVolume: 0` or omit the audio block.
- **`no-captions`** — omit the captions block entirely (narration is clear enough on its own).
- **`vertical`** — override `aspectRatio` to `"9:16"`. Visuals may need to be re-cropped or re-selected since landscape images center-crop awkwardly for vertical.
- **`fast-cut`** — shorten visual durations to 1.5–3s each with snappier crossfades (`fadeIn: 0.15, fadeOut: 0.15`). Good for montage-style slideshows.

## Key points

- **Visuals are overlays, not segments.** The narration is the only segment (since it owns the audio/timeline). This differs from most other kits.
- For static images, add the image as a source via `reelabs_asset` first, then reference it as an `imagePath` overlay. No need to convert images to video.
