# Future To-Do

## Export Pipeline Optimizations

### ~~1. Smart Compositor Bypass~~ DONE (2026-04-15)
Solved differently: captions are now pre-rendered as CIImages and composited per-frame inside `VideoCompositor`, eliminating the two-pass export entirely. Result: ~5x speedup (3min → 34s on 4K). See `CaptionOverlay` struct in `CaptionLayer.swift`.

### 2. Audio Passthrough
**Problem:** Audio is always decoded to PCM and re-encoded to AAC, even when no mixing/volume changes are applied.

**Fix:** Detect when no audio modifications exist (no volume ramps, no transitions, no music) and skip `AVAudioMix` creation. Let `AVAssetExportSession` pass audio through without re-encoding.

**Impact:** ~10-15% speedup for renders without audio effects.

### 3. Passthrough for Zero-Effects Renders
**Problem:** Even a simple trim (no captions, no overlays, no transforms) goes through full decode/re-encode.

**Fix:** Detect zero-effects renders and use `AVAssetExportSession` without any `videoComposition`. Skips compositor entirely.

**Impact:** 60-80% speedup for simple cuts (rare use case but nearly instant when applicable).

## Transcription Resilience

### 4. Operation Recovery Tool
**Problem:** If the server crashes mid-transcription, the Chirp batch job completes in Google Cloud but the results are unreachable (operation name lost).

**Current state:** Operation name is now persisted to `~/Library/Application Support/ReelabsMCP/pending_operation.json` and `resumePendingOperation()` exists on `ChirpClient`. But there's no MCP tool to trigger recovery.

**Fix:** Add a `reelabs_recover_transcription` tool (or flag on `reelabs_transcribe`) that checks for pending operations and resumes polling.

### 5. GCS Audio Retention on Failure
**Current state:** Fixed — GCS audio is now preserved on transcription failure for retry/debugging. Gets cleaned up on success.

**Future:** Add configurable retention period (e.g., keep GCS objects for 24h after failure) and a cleanup sweep on server startup.
