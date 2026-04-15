# Future To-Do

## Export Pipeline Optimizations

### 1. Smart Compositor Bypass (High Impact, Low Risk)
**Problem:** `CompositionBuilder` always sets `customVideoCompositorClass`, even for simple segment concatenation. This forces a two-pass export when captions are present — the compositor runs on every frame just to copy it unchanged, then a second pass applies captions.

**Fix:** After building instructions, check if any actually need the custom compositor (crossfades, overlays, keyframes, transforms). If not, generate standard `AVMutableVideoCompositionLayerInstruction` objects instead. ExportService's single-pass path already handles this (lines 178-238) — it's just currently unreachable.

**Impact:** ~40-50% speedup for captions-only renders (eliminates second decode/encode cycle + temp file).

**Files:** `CompositionBuilder.swift` (line 640-648)

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
