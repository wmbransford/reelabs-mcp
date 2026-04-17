# Overlays — Reference

Elements composited on top of the main video timeline: images, text cards, picture-in-picture video, color fills. Configured via named presets (`presets/overlays/`) or inline in a RenderSpec.

## How overlays work

- An overlay has a time range (`start` / `end`), a position and size, and content.
- Content is one of: `sourceId` (video overlay — source must be declared in `sources[]`), `imagePath` (static image), `text` (text card), or none (solid color block).
- Positions and sizes are 0–1 fractions of the render, top-left origin.
- Overlays stack by `zIndex` (higher renders on top). Ties preserve array order.
- `fadeIn` / `fadeOut` add opacity ramps at start and end.

## Fields

| Field | Type | Notes |
|-------|------|-------|
| `x` / `y` | number | 0–1, top-left origin |
| `width` / `height` | number | 0–1 fractions of render size |
| `opacity` | number | 0–1 |
| `cornerRadius` | number | 0 (sharp) to 1 (pill/circle) |
| `backgroundColor` | string (hex) | `#RRGGBB` or `#RRGGBBAA` (with alpha) |
| `fadeIn` / `fadeOut` | number | seconds |
| `zIndex` | int | higher renders on top |
| `text` | object | text card: `title`, `body`, colors, font sizes, alignment, padding |
| `imagePath` | string | absolute path — typically from `reelabs_graphic` output |
| `sourceId` | string | video overlay — source must be in `sources[]` |

See `reference/render-spec.md` for the complete overlay field list.

## Preset shapes

Overlay presets fall into two kinds:

**Full overlay** — position, styling, and content type all baked in. User supplies only the variable fields (like `title` / `body`) at use time.

**Styling-only** — just the look (colors, fonts, corner radius). User supplies position and content at use time.

## How to add a new overlay preset

1. Copy the preset closest to what you want.
2. Rename the file and update `name:` in the frontmatter.
3. Tweak positioning, colors, fonts. For text cards, use nested `text:` fields for typography and padding.
4. Document what fields the user supplies at invoke time — usually `title` and `body` for lower thirds, `title` only for name tags, `imagePath` for image overlays.
5. Note the aspect ratio the preset is designed for. A landscape lower third at the same fractions looks cramped on 9:16 vertical — consider a `_vertical` variant when the design doesn't translate.

No code change. Immediately usable.
