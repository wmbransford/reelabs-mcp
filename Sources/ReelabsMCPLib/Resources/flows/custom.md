---
name: custom
description: Guided multiple-choice walkthrough when no other flow fits.
---

# Custom

For content that doesn't match any of the named flows — unusual source layouts, hybrid formats, experimental edits. This flow is interactive: the agent asks narrow questions to assemble the plan, then runs it.

**Sources required:** whatever the user has.

**The essentials:**

Start by probing all sources. Then ask the user, in order, the questions needed to pick presets and sequence:

1. **Output format** — 16:9, 9:16, 1:1, 4:5. Affects which caption and overlay presets make sense.
2. **Content type** — talking-head, multi-speaker conversation, screen recording, voiceover with visuals, something else.
3. **Caption style** — list 3–4 relevant presets from `presets/captions/` with one-line descriptions; user picks or says "none."
4. **Camera motion** — list the relevant framing presets; user picks or says "none."
5. **Music** — dry by default; user can pick an audio preset for a bed.

If the answers match an existing named flow, pivot to that flow and exit custom. Custom is slower than a named flow; don't linger in it when a named flow would work.

Use the answers to build the RenderSpec. Transcribe any source with dialogue. Pick the right tool for segment construction — `reelabs_silence_remove` for single-speaker talking-head, `reelabs_speaker_detect` for multi-source conversations, manual segment list for deliberate cuts.

**One verification checkpoint** after the plan is assembled, same shape as other flows: clip duration, word count, flags in range, applied presets, overrides. Wait for "go" before rendering.

**When to reach for custom:** the user has a setup you've never seen before, or they explicitly ask for "something custom."

**When not to reach for custom:** any named flow fits. Custom's extra question-asking is only worth it when a named flow genuinely doesn't cover the case.
