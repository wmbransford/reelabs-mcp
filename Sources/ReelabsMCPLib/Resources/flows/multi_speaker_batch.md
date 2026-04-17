---
name: multi_speaker_batch
description: Multi-speaker edit, fire-and-forget. No confirmation checkpoints.
captions: interview_attribution
framing: subtle
audio: dry
transitions: crossfade_short
codec: hevc
---

# Multi-speaker — batch

Two or more synchronized sources (podcast, interview, panel) cut together based on who's actually speaking. This flow drives through without asking the user to confirm anything. Use it when they trust the defaults and want output fast — especially for batch runs like *"cut me 10 reels from these ten conversations."*

**The essentials:**

Probe and transcribe every source in parallel — they're independent. Then run `reelabs_speaker_detect` with all transcripts; trust its segment output, don't override it with intuition. Assemble the RenderSpec using the presets from the frontmatter, render, done.

**Don't ask for confirmation.** The user picked this flow specifically because they don't want to choose. Log everything worth reviewing — flagged words, flagged utterances, per-speaker speaking time, speaker-switch count — into the render's sidecar markdown. They'll read it after.

**Do abort on real brokenness.** If `reelabs_speaker_detect` returns fewer than two segments, total word count is below 20, or source durations differ by more than 5%, stop and surface the error. Don't silently ship a bad edit.

**For batch runs** across many source sets, spawn one sub-agent per set. The flows are independent and should run truly in parallel; don't serialize them in the main loop.

**Aspect ratio** isn't set here — it defaults to source and can be overridden at invoke time ("make these 9:16 for Reels"). **Overrides allowed** at invoke time: caption preset, codec, and aspect ratio. For a guided variant of the same content type, use `flows/multi_speaker_guided.md`.
