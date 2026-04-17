---
name: talking_head
description: Single-speaker edit with tight cuts, karaoke captions, and subtle camera energy. Guided — one confirmation before render.
captions: william
framing: engaging
audio: dry
codec: hevc
---

# Talking head

One person on camera — selfie cam, tripod, or a single interview rig. A clip-ready single-speaker edit: silence trimmed, cuts driven by the transcript, aesthetics set by the presets in the frontmatter.

**Sources required:** one video with dialogue. Audio is the point — if the source is silent, pick a different flow.

**The essentials:**

Probe the source, then transcribe it. The transcript is the map: every cut decision comes from utterance timestamps, not raw durations. Run `reelabs_silence_remove` to auto-generate tight segments — that's the starting point, not gospel. Tweak the segment list if the user wants specific moments in or out, or if flagged words need to be cut around.

**One verification checkpoint.** After the segment list is ready, send the user a single message with:
- The candidate clip's total duration and word count
- Any `flagged_words` / `flagged_utterances` from the transcribe response that fall inside the proposed range (skip flags outside it — don't dump the whole list)
- The flow settings and any overrides you're applying

Wait for their "go." If they edit the plan, apply the edit and render; don't re-verify after a user edit.

**Aspect ratio** defaults to source and is overridable at invoke time ("make it 9:16 for Reels"). Overrides allowed at invoke time: caption preset, framing preset, audio preset, codec, aspect ratio.

**Variants worth knowing about:**
- **Add a lower third** — set `overlays: lower_third`.
- **With music bed** — override `audio: podcast_bed`.
- **No captions** — omit the captions field in the RenderSpec. Rare, but valid when the target platform auto-captions or the video will be watched silently.
- **Fire-and-forget batch** — for bulk jobs ("make 10 reels from these 10 clips"), use a batch variant flow that skips the checkpoint and logs review material to the sidecar.
