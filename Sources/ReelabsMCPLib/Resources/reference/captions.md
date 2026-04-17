# Captions — Reference

Word-level animated captions burned into the render. Configured via a named preset (file in `presets/captions/`) with optional inline overrides per render.

## How captions work

- Words come from the transcript's word-level timestamps.
- The renderer groups words into "caption groups" of `wordsPerGroup` words.
- Each word appears at its own timestamp. If `highlightColor` is set, the currently-spoken word is styled differently from the others (karaoke effect).
- The whole caption sits at `position` (percent from top of frame).

## Fields

Every preset — and every inline override — sets any subset of these. Unset fields fall back to the preset, then to system defaults.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `fontFamily` | string | "Arial" | macOS-installed font family |
| `fontSize` | number | 7.0 | percent of video height |
| `fontWeight` | string | "bold" | ultralight / thin / light / regular / medium / semibold / bold / heavy / black |
| `color` | string (hex) | "#FFFFFF" | base text color |
| `highlightColor` | string (hex) | — | active-word color. Omit for no karaoke. |
| `position` | number | 70 | percent from top. 50 = center, 70 = lower third, 90 = near bottom. |
| `allCaps` | bool | true | uppercase all caption text |
| `shadow` | bool | true | drop shadow behind text |
| `wordsPerGroup` | number | 3 | words shown per caption group |
| `punctuation` | bool | true | show terminal punctuation (. , ? !). Apostrophes in contractions are always kept. |

## Using a preset

**In a flow's frontmatter** — `captions: william` references `presets/captions/william.md`.

**Inline in a RenderSpec** — `"captions": {"preset": "william"}`. Any field in the captions object overrides the preset for this one render:

```json
{
  "captions": {
    "preset": "william",
    "position": 50,
    "wordsPerGroup": 2
  }
}
```

Use inline overrides for one-offs. If you find yourself using the same override combination repeatedly, promote it to a new preset instead.

## How to add a new caption preset

1. Open `presets/captions/` and copy the preset closest to what you want.
2. Rename the file to your style's name, lowercase snake_case (e.g. `my_pod.md`).
3. Update `name:` in the frontmatter to match the filename (without `.md`). Flows and renders reference the preset by this name.
4. Tweak the frontmatter fields. Omit anything you want to default.
5. Below the frontmatter, write a short paragraph: what it is, when to use, when not to use. Reference related presets.

No code change. No restart. The preset is usable immediately by any flow or render.
