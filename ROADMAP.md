# Roadmap

Planned enhancements. Nothing here blocks normal use — items are performance and resilience wins being tracked for future releases.

## Export pipeline

### Audio passthrough
Audio is always decoded to PCM and re-encoded to AAC, even when no mixing, volume ramps, or music are applied. Detecting the zero-audio-effects case and skipping `AVAudioMix` would let `AVAssetExportSession` pass audio through untouched.

**Impact:** ~10–15% speedup on renders without audio effects.

### Passthrough for zero-effects renders
A simple trim (no captions, overlays, or transforms) still goes through full decode/re-encode. Detecting this case and exporting without a `videoComposition` would skip the compositor entirely.

**Impact:** 60–80% speedup on simple cuts.

## Transcription resilience

### Recovery tool for interrupted transcriptions
If the server is interrupted mid-transcription, the Chirp batch job finishes in Google Cloud but the MCP client can't reach its results. The operation name is already persisted to `pending_operation.json` and `ChirpClient.resumePendingOperation()` exists — what's missing is an MCP-exposed entry point (either a dedicated `reelabs_recover_transcription` tool or a recovery flag on `reelabs_transcribe`).

### Configurable GCS retention
On transcription failure, the uploaded GCS audio is preserved for retry/debugging and cleaned up on success. A configurable retention window (e.g. auto-delete failed uploads after 24h) and a server-startup cleanup sweep would keep the bucket tidy without losing recent failures.
