---
name: multi_speaker_guided
description: Multi-speaker edit with one confirmation before render. Good for interviews and podcasts where specific cut choices matter.
captions: interview_attribution
framing: subtle
audio: dry
transitions: crossfade_short
codec: hevc
---

# Multi-speaker — guided

Two or more synchronized sources — podcast, interview, panel — cut together based on who's actually speaking. This flow verifies the plan with the user once before rendering. Reach for it when specific cut choices matter (correcting a mis-attributed moment, trimming a long stretch, excising crosstalk).

**Sources required:** one per speaker, time-synced, each with its own audio track.

**The essentials:**

Probe and transcribe all sources in parallel. Then run `reelabs_speaker_detect` with all transcripts; its segment output is ground truth — don't eyeball who's speaking.

**One verification checkpoint.** After `reelabs_speaker_detect` returns, send the user a single message with:
- Per-speaker word count and speaking time (from `source_stats`)
- Total speaker switches and total duration
- Any `flagged_words` / `flagged_utterances` from every transcript that fall inside your proposed range
- The flow settings and any overrides being applied

Wait for their "go." If they adjust the segment list (trim a range, drop a speaker during crosstalk), apply and render — don't re-verify after a user edit.

**Abort conditions.** If `reelabs_speaker_detect` returns fewer than two segments, total word count is below 20, or source durations differ by more than 5%, stop and surface the error before the checkpoint. Don't ask the user to confirm a broken plan.

**Aspect ratio** defaults to source and is overridable at invoke time. Overrides allowed at invoke time: caption preset, framing preset, audio preset, transition preset, codec, aspect ratio.

**Variants worth knowing about:**
- **Fire-and-forget batch** — use `flows/multi_speaker_batch.md` instead.
- **With music bed** — override `audio: podcast_bed`.
- **No transitions** — override `transitions: none` for hard cuts throughout.
- **Highlight-moment styling** — override `captions: podcast_big`.
