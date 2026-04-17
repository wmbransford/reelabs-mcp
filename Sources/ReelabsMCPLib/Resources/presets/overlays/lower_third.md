---
category: overlays
name: lower_third
kind: text_overlay
# Maps to overlay fields in a RenderSpec. Position values are 0-1 fractions of the render size.
x: 0.05
y: 0.75
width: 0.6
height: 0.18
backgroundColor: "#000000CC"
cornerRadius: 0.05
fadeIn: 0.3
fadeOut: 0.3
text:
  titleFontSize: 42
  bodyFontSize: 26
  titleFontWeight: bold
  bodyFontWeight: regular
  fontFamily: Poppins
  titleColor: "#FAF9F5"
  bodyColor: "#D0CFCB"
  alignment: left
  padding: 0.08
---

# Lower Third

Classic name-and-title lower third — semi-transparent black card in the bottom-left, Poppins typography, 0.3s fade in/out. Spans 60% of the width by 18% of the height.

Supply `title` and `body` at use time:

```json
{
  "overlayPreset": "lower_third",
  "start": 3.0,
  "end": 8.0,
  "text": {"title": "Alex Chen", "body": "Host, The Weekly"}
}
```

**Reach for this when:** introducing a speaker, tagging a location, adding on-screen attribution.

**Reach for something else when:**
- You need a full-frame intro card → use a `title_card` preset.
- The video is 9:16 vertical and 60% width looks cramped → try `lower_third_vertical` (full-width, centered).
- You want only the name with no title line → use `name_tag` (single-line variant).
