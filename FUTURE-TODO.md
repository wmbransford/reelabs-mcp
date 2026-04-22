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

### 5. Delete Orphaned Proxy Code
**Problem:** After stripping distribution auth (2026-04-20), the `functions/` directory (Firebase Cloud Functions proxy) and `web/` directory (activation/install landing pages) are dead code. Keep for history in case the tool is ever redistributed, but they pollute the repo and the Firebase config at the root (`.firebaserc`, `firebase.json`, `firestore.rules`, `firestore.indexes.json`).

**Fix:** Delete `functions/`, `web/`, and the four `.firebase*` / `firestore.*` root files. Verify Package.swift and the build still reference nothing in them first.

**Impact:** Cleaner repo; removes confusion about where auth lives.

### 6. Restore swift test
**Problem:** `swift test` from CLI fails with "no such module 'Testing'" even though Swift 6.3 is installed. Xcode integration works (presumably), but CI/headless runs don't. Blocks adding coverage for new code.

**Fix:** Investigate toolchain config — likely a missing SDK or `--package-path` flag; may need `swift test --enable-experimental-swift-testing` or the Xcode-embedded toolchain instead of the default `/usr/bin/swift`.

**Impact:** Unblocks test-driven development on this repo.

### 7. GCS Audio Retention on Failure
**Current state:** Fixed — GCS audio is now preserved on transcription failure for retry/debugging. Gets cleaned up on success.

**Future:** Add configurable retention period (e.g., keep GCS objects for 24h after failure) and a cleanup sweep on server startup.

## Transcribe Quality

### 9. User-saved presets don't mirror to disk
**Problem:** `reelabs_preset save` correctly persists to the preset store (DB-backed — verified by `reelabs_preset list` returning it), but does NOT write a matching `.md` file to `{dataRoot}/presets/{name}.md`. Only the seed presets (tiktok, william, etc.) have `.md` mirrors; user-saved presets live DB-only.

**Observed:** On 2026-04-20 ran `reelabs_preset save name:flex_power ...`. `list` returns it. `get` returns it. But `~/Library/Application Support/ReelabsMCP/presets/flex_power.md` is absent.

**Why it matters:** The docs (CLAUDE.md) say presets are "seeded from code into `{dataRoot}/presets/` as markdown" — agents may try to read that file directly and miss user-saved ones. Also makes version control + hand-editing of presets impossible for client/custom presets.

**Fix:** In `PresetStore.save()`, after the DB write, also write/update the corresponding `.md` file under `{dataRoot}/presets/{name}.md`. Use the same frontmatter+body format as the seeded presets.

**Impact:** Agents can discover user presets via Grep on `{dataRoot}/presets/*.md` (as docs suggest), not just via `reelabs_preset list`. Enables hand-tuning of client presets in version control.

### ~~10. Video overlay rotation bug on vertically-shot source~~ FIXED (2026-04-20, run #5)

**Root cause:** `VideoCompositor` applied `preferredTransform` to CIImage-space pixels without the Y-flip conjugation that the main-segment path uses. The matrix is defined in AVFoundation top-left-origin space but CIImage uses bottom-left-origin, so a raw `image.transformed(by: prefTx)` introduced a spurious Y-flip on top of the intended rotation — making 180°-rolled Sony vertical clips render upside-down.

**Fix:** `VideoCompositor.startRequest` (around line 155) now conjugates `preferredTransform` the same way the main-segment path does:
```
flipIn(bufferH) · preferredTransform · flipOut(rotatedH)
```
where `rotatedH = abs(naturalSize.applying(prefTx).height)`. Origin is normalized to `(0,0)` defensively against floating-point drift.

**Verification path:** Re-render any run-4 `cross-cut` spec with `overlays: [{sourceId: "broll", ...}]` instead of adding b-roll as a segment; verify the overlay plays right-side up. Run-5 Phase D2 re-rendered r4-07 and r4-08 with true `b_roll_overlay` patterns to confirm.

### 8. Flagger false-positive flood on "unusual character pattern"
**Problem:** Nearly every word that ends with a comma or period gets flagged with reason `"unusual character pattern"`. In Flex-Power dogfood run #2 on 2026-04-20, a 5-min transcript returned ~80 flags, essentially one per comma/period word. This makes `flagged_words` unusable for its stated purpose (surface suspicious words to review before captions).

**Fix:** Punctuation is expected. The flagger should normalize to `[A-Za-z'0-9$]` before the character-pattern heuristic — punctuation, hyphens, dollar signs, and number formatting are legitimate and should not count.

**Impact:** Makes `flagged_words` actually useful. Currently I ignore it because the signal-to-noise ratio is ~0. See `WordFlagger.swift` (or wherever the character-pattern check lives).
