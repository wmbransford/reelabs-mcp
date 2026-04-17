---
type: index
---

# Kits

A **kit** bundles all the aesthetic decisions for a specific kind of video into one named recipe: aspect ratio, caption preset, keyframe pattern, codec, segment padding, and a step-by-step workflow. Pick a kit first, then the agent knows what to do.

## Available kits

| Kit | Format | When to use |
|-----|--------|-------------|
| [social_talking_head](social_talking_head.md) | 9:16 vertical | Talking-head content for TikTok, Reels, Shorts, or any vertical feed |
| [screencast_tutorial](screencast_tutorial.md) | 16:9 landscape | Screen recording + speaker cam for tutorials, demos, walkthroughs |
| [interview_cut](interview_cut.md) | 16:9 landscape | Two-person interview, alternating A/B speakers |
| [podcast_clip](podcast_clip.md) | 9:16 vertical | Short podcast highlights with big captions, single or dual camera |
| [narrated_slideshow](narrated_slideshow.md) | 16:9 landscape | Voiceover over images or short clips, Ken Burns zoom |
| [custom](custom.md) | user-picked | Guided multiple-choice walkthrough when no kit fits |

## Kit file format

Each kit is a markdown file with YAML frontmatter defining the defaults, followed by a workflow and optional variants.

```markdown
---
name: kit_name
description: One-line description
aspectRatio: "9:16"
captionPreset: william
keyframePattern: engaging
codec: hevc
padding: 0.15
---

# Kit Name

## Format
Prose describing what this kit produces.

## Workflow
Numbered steps the agent follows.

## Variants
Common adjustments (no captions, with music, etc.)
```

## Why kits

Without kits, the agent has to invent the full RenderSpec from scratch every time — which means the aesthetic depends on how well it improvises. Kits pin the deterministic parts (look, format, codec) so the output is consistent. The agent still owns the editorial parts: which takes to keep, where to cut, what to flag for review.

## How the agent uses kits

1. When footage is added to a project, the agent asks *"What are we making?"* and presents the kit list.
2. The user picks a kit (or picks `custom` for a guided walkthrough).
3. The agent follows that kit's `## Workflow` section, using its frontmatter defaults.
4. Variants are applied if the user requests them (e.g. "add music", "no captions").
