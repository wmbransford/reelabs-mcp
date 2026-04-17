---
name: custom
description: Guided multiple-choice walkthrough when no named kit fits
aspectRatio: null
captionPreset: null
keyframePattern: null
codec: hevc
padding: 0.15
musicVolume: 0.0
---

# Custom

## Format
A guided walkthrough. Ask four multiple-choice questions, assemble a one-off kit from the answers, then render. Never free-form unless the user says "let me describe it myself."

## The four questions

Ask them **one at a time**, waiting for the user's answer before moving on. Present as numbered options so the user just replies with a number or letter. Don't ask follow-ups unless a choice has a real consequence.

### Question 1 — Where's it going?
```
Where will this video live?
  1. Vertical feed (TikTok, Reels, Shorts) — 9:16
  2. Landscape (YouTube, web) — 16:9
  3. Square (Instagram feed) — 1:1
  4. Portrait post (Instagram) — 4:5
```
Maps to `aspectRatio`.

### Question 2 — Captions?
```
Captions?
  1. Karaoke (bold, word-by-word highlight) — default william style
  2. Clean subtitle (subtle, bottom-aligned)
  3. Big and bold (podcast-style oversized)
  4. None
  5. Let me pick from the full library
```
Maps to `captions.preset`:
- 1 → `william`
- 2 → `subtitle`
- 3 → `podcast_big`
- 4 → omit the `captions` block entirely
- 5 → list all available presets (`tiktok`, `subtitle`, `minimal`, `bold_center`, `william`, `social_karaoke_pink`, `social_karaoke_white`, `screencast_clean`, `interview_attribution`, `podcast_big`, `slideshow_serif`) and let the user pick by name.

### Question 3 — Energy?
```
How should the footage feel?
  1. Calm — barely-there zoom (subtle)
  2. Engaging — gentle push/pull between segments (default)
  3. Punchy — hard cuts with scale jumps at sentence boundaries
  4. Static — no zoom effects
```
Maps to `keyframePattern`:
- 1 → `subtle` — apply `[{time: 0, scale: 1.0}, {time: segment_duration, scale: 1.05}]` to every segment
- 2 → `engaging` — alternate push-in and pull-back across segments
- 3 → `hard_cut_emphasis` — split long segments at sentence boundaries, alternate `transform: {scale: 1.0}` and `transform: {scale: 1.2}`
- 4 → omit keyframes and transforms

### Question 4 — Music?
```
Background music?
  1. None
  2. Soft under dialogue (musicVolume 0.15)
  3. Prominent (musicVolume 0.3) — only recommended for no-dialogue edits
  4. I'll provide the music file
```
Maps to `audio`:
- 1 → omit the `audio` block
- 2 → ask for a music file path, set `musicVolume: 0.15`
- 3 → ask for a music file path, set `musicVolume: 0.3`
- 4 → ask for the path and the volume

## After the four questions

1. Follow the default workflow: probe → transcribe → cut (silence_remove) → propose + verify in one message (segment summary + `flagged_words` / `flagged_utterances` that fall inside your proposed ranges + kit settings) → render.
2. Apply the answers as the RenderSpec settings.
3. Use `hevc` codec and `0.15` padding as defaults unless the user overrides.
4. **Only ask follow-ups if a combination has a real consequence.** Examples where a follow-up is warranted:
   - **Punchy energy + voiceover** → "I'll cut on sentence boundaries for the scale jumps — sound good?"
   - **Prominent music + captions** → "Music at 0.3 may fight with narration volume. Reduce to 0.2?"
   - **4:5 or 1:1 + landscape source** → "Source is 16:9; the sides will be cropped. Want to letterbox instead?"

## Saving the answers

If the user says "make this my default" or "save this as a kit," create a new kit file at `{dataRoot}/kits/{user-chosen-name}.md` with the assembled frontmatter. Otherwise, the custom config is one-off — don't persist it.
