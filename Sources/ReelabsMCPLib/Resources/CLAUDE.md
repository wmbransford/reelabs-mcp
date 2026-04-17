# ReeLabs

AI video editing assistant. Edits happen through the `reelabs_*` MCP tools — ffmpeg, ffprobe, and whisper aren't used here.

## The layout

- `flows/` — end-to-end workflows for different kinds of edit. Each flow is a prose document that names the presets to use, sketches the tool sequence, and describes how much to involve the user. Flows are the natural starting point for any new edit: the user picks one, the agent follows its lead.
- `presets/` — style atoms in five categories: `captions/`, `framing/`, `overlays/`, `transitions/`, `audio/`. Small, self-documenting markdown files. Flows reference presets by name.
- `reference/` — how each subsystem works and how to add a new preset in it. Read the relevant file on demand when extending or when the defaults don't fit.

## What the tools can do

- **Probe** a source to learn its shape (duration, resolution, fps, codec, audio).
- **Transcribe** to word-level timestamps via Chirp.
- **Render** from a declarative RenderSpec (segments, captions, overlays, audio).
- **Detect speakers** across synced sources for multi-person content.
- **Silence-remove** to auto-generate tightly-trimmed segments.
- **Analyze** frames for visual content (delegated to a sub-agent).
- **Graphic** renders HTML/CSS to PNG for overlays and cards.
- **Layout** generates overlay arrays for screen-recording compositions.
- **Rerender, validate, extract-audio, project, asset, preset** — supporting tools.

Full signatures and schemas live in `reference/tools.md` and `reference/render-spec.md`.

## Common practice

- Edits usually begin by probing the source. Transcription follows when there's dialogue or narration.
- Visual analysis tasks (faces, scene content) work better delegated to a sub-agent than run inline — frame-by-frame work is what sub-agents are for.
- RenderSpecs are built from the transcript before rendering; iterating by re-rendering raw footage is slower and noisier than planning once.
- Verification discipline lives in flows — the flow the user picks determines how much the agent confirms along the way.

## Extending

Everything in `presets/` and `flows/` is user-editable markdown. New capabilities arrive by writing files, not editing code.

- New caption style → copy a file in `presets/captions/`, tweak, save.
- New flow → copy a file in `flows/`, change the presets it references, rewrite the prose.
- New preset category → probably unnecessary; ask first.

Each preset file is small and self-documenting. Each reference file ends with a "How to add a new preset" section describing the shape to follow.
