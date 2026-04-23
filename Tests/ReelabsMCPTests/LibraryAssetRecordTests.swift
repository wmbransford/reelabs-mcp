import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("LibraryAssetKind + LibraryAssetRecord")
struct LibraryAssetRecordTests {
    @Test("kind raw values match SQL CHECK constraint values")
    func kindRawValues() {
        #expect(LibraryAssetKind.capturedVideo.rawValue == "captured_video")
        #expect(LibraryAssetKind.capturedAudio.rawValue == "captured_audio")
        #expect(LibraryAssetKind.ttsAudio.rawValue == "tts_audio")
        #expect(LibraryAssetKind.aiVideo.rawValue == "ai_video")
        #expect(LibraryAssetKind.aiImage.rawValue == "ai_image")
        #expect(LibraryAssetKind.graphicSpec.rawValue == "graphic_spec")
        #expect(LibraryAssetKind.stockVideo.rawValue == "stock_video")
        #expect(LibraryAssetKind.stockImage.rawValue == "stock_image")
        #expect(LibraryAssetKind.music.rawValue == "music")
        #expect(LibraryAssetKind.screenRecording.rawValue == "screen_recording")
    }

    @Test("kind supportedInPlanOne flags only captured media")
    func planOneSupport() {
        #expect(LibraryAssetKind.capturedVideo.supportedInPlanOne)
        #expect(LibraryAssetKind.capturedAudio.supportedInPlanOne)
        #expect(!LibraryAssetKind.ttsAudio.supportedInPlanOne)
        #expect(!LibraryAssetKind.aiVideo.supportedInPlanOne)
        #expect(!LibraryAssetKind.graphicSpec.supportedInPlanOne)
    }

    @Test("record holds all fields")
    func recordFields() {
        let record = LibraryAssetRecord(
            id: 42,
            kind: .capturedVideo,
            path: "/tmp/clip.mp4",
            externalRef: nil,
            contentHash: "abc123",
            durationS: 12.5,
            width: 1920,
            height: 1080,
            fps: 29.97,
            codec: "h264",
            hasAudio: true,
            provenance: ["shoot_id": "2026-04-22"],
            sourceMetadata: ["bitrate": "15000000"],
            createdAt: "2026-04-22T10:00:00Z",
            ingestedAt: "2026-04-22T10:00:00Z"
        )
        #expect(record.id == 42)
        #expect(record.kind == .capturedVideo)
        #expect(record.path == "/tmp/clip.mp4")
        #expect(record.contentHash == "abc123")
        #expect(record.durationS == 12.5)
        #expect(record.provenance?["shoot_id"] == "2026-04-22")
    }
}
