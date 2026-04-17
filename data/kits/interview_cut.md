---
name: interview_cut
description: Two-person interview with alternating A/B speakers
aspectRatio: "16:9"
captionPreset: interview_attribution
keyframePattern: subtle
codec: hevc
padding: 0.2
musicVolume: 0.0
---

# Interview Cut

## Format
16:9 landscape. Two sources alternating — speaker A and speaker B. Per-source transcription so captions attribute to the correct speaker. Subtle scale drift (1.0 → 1.05 over each segment) to keep the frame feeling alive on long talking heads. HEVC.

## Sources required
- **Speaker A** — one camera angle or recording
- **Speaker B** — a second camera angle or recording
- Both should cover the same conversation. Rough sync isn't required — you cut from each independently.

## Workflow

1. **Probe both sources** — note durations.
2. **Transcribe each source separately** — save both transcript IDs.
3. **Build the A/B cut-list** — look at both transcripts, pick the best version of each answer/moment. Typically:
   - Question or setup → speaker A
   - Answer or reaction → speaker B
   - Laugh / crosstalk → whichever source captures it better
4. **Build segments** from each source's utterance timestamps. Alternate between A and B as the conversation flows. Pad ~0.2s at segment edges (slightly more than default — gives conversational breathing room).
5. **Verification checkpoint** — show the per-speaker word count and segment count. Flag suspicious words from both transcripts. Wait for confirmation.
6. **Render** — both sources in the `sources` array with their respective `transcriptId` set. `aspectRatio: "16:9"`, `captions: {preset: "interview_attribution"}`, `quality: {codec: "hevc"}`. Use `subtle` keyframes on each segment: `[{time: 0, scale: 1.0}, {time: segment_duration, scale: 1.05}]`.

## Variants

- **`with-music`** — add quiet music (`musicVolume: 0.1`) for feeds where silence feels empty.
- **`crossfades`** — add `transition: {type: "crossfade", duration: 0.3}` to each segment for a smoother A/B cut. Only use when cuts are on natural pauses, not mid-word.
- **`vertical`** — override `aspectRatio` to `"9:16"`. Stack the speakers top/bottom instead of alternating? No — for 9:16 interview content, still alternate full-frame; the aspect change just reframes each speaker.
- **`attribution-off`** — use `subtitle` preset instead for a more traditional two-person subtitle style without the attribution tag.
