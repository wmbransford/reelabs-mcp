---
name: narrated_slideshow
description: Voiceover over still images with slow camera motion per image. Guided.
captions: slideshow_serif
framing: subtle
audio: dry
codec: hevc
---

# Narrated slideshow

A voiceover track over a sequence of still images or screenshots. Each image is held for a defined span of the narration with slow camera motion applied so the frame never feels frozen. Captions come from the voiceover transcript.

**Sources required:** one voiceover audio file (m4a, mp3, wav) and one or more images. Total image time should match the voiceover length.

**The essentials:**

Probe and transcribe the voiceover. For each image, decide which narration timespan it accompanies — either ask the user ("this shot during the intro, that one during the product reveal") or split equally across the voiceover duration if no structure is given.

Build the composition with image overlays timed to the voiceover, over a solid-color base that spans the full duration. Apply the framing preset's keyframes to each image overlay for slow motion during its span. The voiceover is the audio track; there are no video segments in the traditional sense.

**One verification checkpoint.** Before rendering, send the user a single message with:
- The image-to-narration mapping (which image appears during which timespan)
- Caption word count and any `flagged_words` from the voiceover transcript
- The flow settings and any overrides

Wait for "go." If they reorder images or adjust timing, apply and render.

**Aspect ratio** defaults to 16:9 and is overridable at invoke time. Images are cropped cover-fit at the target aspect.

**Variants worth knowing about:**
- **With music bed** — override `audio: vo_over_music`. Common for this style.
- **Hard cuts between images** — override `framing: none` for instant transitions without camera motion.
- **Chapter markers** — add `overlays: lower_third` with title/body supplied per image span.
