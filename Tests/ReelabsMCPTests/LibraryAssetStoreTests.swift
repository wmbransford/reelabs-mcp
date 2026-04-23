import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("LibraryAssetStore")
struct LibraryAssetStoreTests {
    private func makeStore() throws -> (LibraryAssetStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try ReelabsMCPLib.Database(root: tmp)
        return (LibraryAssetStore(database: database), tmp)
    }

    @Test("register inserts and returns a record with id")
    func registerInserts() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let record = try store.register(
            kind: .capturedVideo,
            path: "/tmp/clip.mp4",
            contentHash: "abc123",
            durationS: 30.0,
            width: 1920,
            height: 1080,
            fps: 29.97,
            codec: "h264",
            hasAudio: true,
            provenance: ["shoot_id": "2026-04-22"],
            sourceMetadata: ["bitrate": "15000000"]
        )
        #expect(record.id > 0)
        #expect(record.kind == .capturedVideo)
        #expect(record.path == "/tmp/clip.mp4")
        #expect(record.contentHash == "abc123")
    }

    @Test("getByID returns previously registered record")
    func getByIDRoundtrips() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inserted = try store.register(
            kind: .capturedAudio,
            path: "/tmp/vo.wav",
            contentHash: "def456",
            durationS: 10.0,
            hasAudio: true
        )
        let fetched = try store.getByID(inserted.id)
        #expect(fetched?.id == inserted.id)
        #expect(fetched?.kind == .capturedAudio)
        #expect(fetched?.path == "/tmp/vo.wav")
    }

    @Test("getByContentHash returns existing registration")
    func getByHashReturnsExisting() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inserted = try store.register(
            kind: .capturedVideo,
            path: "/tmp/a.mp4",
            contentHash: "hash-xyz",
            durationS: 1.0
        )
        let byHash = try store.getByContentHash("hash-xyz")
        #expect(byHash?.id == inserted.id)
        #expect(try store.getByContentHash("does-not-exist") == nil)
    }

    @Test("listByKind filters by kind")
    func listByKindFilters() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.register(kind: .capturedVideo, path: "/tmp/v1.mp4", contentHash: "v1", durationS: 1.0)
        _ = try store.register(kind: .capturedVideo, path: "/tmp/v2.mp4", contentHash: "v2", durationS: 1.0)
        _ = try store.register(kind: .capturedAudio, path: "/tmp/a1.wav", contentHash: "a1", durationS: 1.0)

        let videos = try store.listByKind(.capturedVideo)
        let audios = try store.listByKind(.capturedAudio)
        #expect(videos.count == 2)
        #expect(audios.count == 1)
    }

    @Test("provenance round-trips as JSON")
    func provenanceRoundtrips() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inserted = try store.register(
            kind: .capturedVideo,
            path: "/tmp/c.mp4",
            contentHash: "c",
            durationS: 1.0,
            provenance: ["shoot_id": "s1", "camera": "sony-fx3"]
        )
        let fetched = try store.getByID(inserted.id)
        #expect(fetched?.provenance?["shoot_id"] == "s1")
        #expect(fetched?.provenance?["camera"] == "sony-fx3")
    }
}
