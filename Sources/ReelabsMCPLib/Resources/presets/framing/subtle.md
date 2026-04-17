---
category: framing
name: subtle
kind: keyframes
# Applied as keyframes on each segment; `duration: segment` means spans the whole segment.
startScale: 1.0
endScale: 1.05
startPanX: 0.0
startPanY: 0.0
endPanX: 0.0
endPanY: 0.0
duration: segment
---

# Subtle

Barely-perceptible scale drift — 1.0 → 1.05 over the full length of each segment. Keeps long talking heads from feeling frozen without being distracting.

Rendered as two keyframes per segment: `[{time: 0, scale: 1.0}, {time: segment_duration, scale: 1.05}]`.

**Reach for this when:** interviews, podcasts, narrated content, anywhere motion is unwelcome but total stillness feels wrong.

**Reach for something else when:**
- Content is fast-paced and needs energy → try `engaging` (alternating push-in / pull-back).
- You want cuts, not drift → try `hard_cut` (instant 1.0 ↔ 1.2 switches at sentence boundaries).
- The subject is static product or slides → no framing preset at all; leave scale at 1.0.
