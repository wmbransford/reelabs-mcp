# ReeLabs MCP

**AI video editing inside Claude. Seriously.**

For creators, marketers, and anyone drowning in footage: drop a clip into Claude and say *"cut me a 30-second highlight with captions"* — and it actually does it. On your Mac, on your real footage, in minutes. No uploads, no templates, no "AI-generated" B-roll.

```bash
brew install wmbransford/tap/reelabs-mcp && brew services start reelabs-mcp
reelabs-mcp sign-in
claude mcp add reelabs reelabs-mcp
```

---

## What it is

ReeLabs is a [Model Context Protocol](https://modelcontextprotocol.io/) server that plugs into Claude Code, Claude Desktop, or Cursor and gives the agent native video-editing tools. Probe, transcribe, analyze, render — all local, all native, all through Claude.

Video editing sucks. Timelines. Render queues. Plugin hell. ReeLabs skips the app entirely: you talk, the agent edits.

## What it can do

Each of these is a tool the agent calls on your behalf. You don't touch them directly.

- **`reelabs_probe`** — Inspect any video in under a second. Duration, resolution, fps, codec, audio channels. Replaces `ffprobe`.
- **`reelabs_transcribe`** — Word-level timestamps via Google Chirp. Accurate enough to cut on. Replaces Whisper.
- **`reelabs_render`** — Native AVFoundation render from a declarative RenderSpec. H.264, HEVC, ProRes. Replaces `ffmpeg`.
- **`reelabs_analyze`** — Hand frames to a sub-agent and ask what's on screen. Faces, products, slides, scene changes.
- **`reelabs_graphic`** — Ship HTML/CSS, get back a PNG overlay. Lower thirds, title cards, pricing tables, whatever.
- **`reelabs_layout`** — Compose screen recordings with a speaker bubble and zoom pans, automatically.
- **`reelabs_silence_remove`** — Auto-trim dead air from long takes. Turns a rambling 20-minute monologue into a tight 6.
- **`reelabs_speaker_detect`** — Multi-source speaker diarization for podcasts, interviews, and panels.
- **Supporting tools** — `reelabs_validate`, `reelabs_project`, `reelabs_asset`, `reelabs_preset`, `reelabs_extract_audio`, `reelabs_rerender`, `reelabs_transcript`.

Full signatures and the RenderSpec schema live in [`reference/`](reference/).

## Why it's different

ReeLabs isn't a video generator and it isn't a timeline editor. It's a third thing: an agent that edits your real footage, autonomously.

- **Local file access.** Your footage never leaves your Mac. Renders are fast because there's no upload. Your raw files stay yours.
- **Gimmick free.** No AI avatars. No synthetic voices. No "generate a video from a prompt." ReeLabs edits *your* clips, with *your* voice, on *your* timeline.
- **Cutting-edge understanding.** Chirp-grade transcription and frame-level visual analysis mean the agent actually knows what's in your footage before it cuts.

Remotion, HeyGen, and Sora generate video. Premiere and Final Cut let you edit video. ReeLabs edits video *for you*.

## Try it

After installing, open Claude Code (or Desktop / Cursor) in a folder with a video file and try:

> Cut a 30-second highlight from this podcast. Add captions in the "william" preset.

> Remove the silences from `interview.mov` and render a 9:16 version with burned-in subtitles.

> Analyze this screen recording, find the three moments I demo the new feature, and stitch them together with a title card between each.

The agent picks a flow, probes the source, transcribes, plans the edit, and renders. You approve the plan; it ships the file.

## Requirements

- macOS 14 or newer (ReeLabs uses native AVFoundation — this is Mac-only, on purpose)
- An MCP-compatible client: [Claude Code](https://claude.ai/code), [Claude Desktop](https://claude.ai/desktop), or [Cursor](https://cursor.com)
- A ReeLabs account for transcription credits (free tier: 90 minutes/month)

## Uninstall

```bash
brew services stop reelabs-mcp
brew uninstall reelabs-mcp
claude mcp remove reelabs
```

Your projects and assets are preserved under `~/Library/Application Support/ReelabsMCP/`. Delete that folder to wipe everything.

## Configuration

Presets and flows are plain markdown files under `~/Library/Application Support/ReelabsMCP/`:

- `presets/` — caption styles, framing, overlays, transitions, audio chains
- `flows/` — end-to-end workflows (podcast_clip, social_talking_head, screencast_tutorial, etc.)
- `reference/` — schemas and "how to add a preset" guides

Copy a file, tweak it, save. No recompile.

## Links

- **Website** — [reelabs.ai](https://reelabs.ai)
- **Issues** — [github.com/wmbransford/reelabs-mcp/issues](https://github.com/wmbransford/reelabs-mcp/issues)
- **Discussions** — [github.com/wmbransford/reelabs-mcp/discussions](https://github.com/wmbransford/reelabs-mcp/discussions)
- **License** — [MIT](LICENSE)
