import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("AssetStore")
struct AssetStoreTests {
    private func makeStores() throws -> (ProjectStore, AssetStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try Database(root: tmp)
        return (ProjectStore(database: database), AssetStore(database: database), tmp)
    }

    @Test("add inserts new asset with all fields")
    func addInsertsNewAsset() throws {
        let (projects, assets, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        let record = try assets.add(
            project: "proj",
            slug: "c0048",
            filename: "C0048.MP4",
            filePath: "/tmp/C0048.MP4",
            fileSizeBytes: 123_456_789,
            durationSeconds: 12.5,
            width: 1920,
            height: 1080,
            fps: 29.97,
            codec: "h264",
            hasAudio: true,
            tags: ["talking-head", "hero"]
        )
        #expect(record.slug == "c0048")
        #expect(record.filename == "C0048.MP4")
        #expect(record.filePath == "/tmp/C0048.MP4")
        #expect(record.fileSizeBytes == 123_456_789)
        #expect(record.durationSeconds == 12.5)
        #expect(record.width == 1920)
        #expect(record.height == 1080)
        #expect(record.fps == 29.97)
        #expect(record.codec == "h264")
        #expect(record.hasAudio == true)
        #expect(record.tags == ["talking-head", "hero"])
        #expect(record.created.isEmpty == false)

        let roundTrip = try assets.get(project: "proj", slug: "c0048")
        #expect(roundTrip?.slug == "c0048")
        #expect(roundTrip?.filename == "C0048.MP4")
        #expect(roundTrip?.filePath == "/tmp/C0048.MP4")
        #expect(roundTrip?.fileSizeBytes == 123_456_789)
        #expect(roundTrip?.durationSeconds == 12.5)
        #expect(roundTrip?.width == 1920)
        #expect(roundTrip?.height == 1080)
        #expect(roundTrip?.fps == 29.97)
        #expect(roundTrip?.codec == "h264")
        #expect(roundTrip?.hasAudio == true)
        #expect(roundTrip?.tags == ["talking-head", "hero"])
    }

    @Test("add upserts existing asset on (project, slug) conflict")
    func addUpsertsExisting() throws {
        let (projects, assets, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try assets.add(
            project: "proj",
            slug: "c0048",
            filename: "old.MP4",
            filePath: "/old/path.MP4",
            durationSeconds: 5.0,
            hasAudio: true
        )
        let updated = try assets.add(
            project: "proj",
            slug: "c0048",
            filename: "new.MP4",
            filePath: "/new/path.MP4",
            durationSeconds: 10.0,
            hasAudio: false
        )
        #expect(updated.filename == "new.MP4")
        #expect(updated.filePath == "/new/path.MP4")
        #expect(updated.durationSeconds == 10.0)
        #expect(updated.hasAudio == false)

        let fetched = try assets.get(project: "proj", slug: "c0048")
        #expect(fetched?.filename == "new.MP4")
        #expect(fetched?.filePath == "/new/path.MP4")
        #expect(fetched?.durationSeconds == 10.0)
        #expect(fetched?.hasAudio == false)
    }

    @Test("get returns nil for missing asset")
    func getReturnsNilForMissing() throws {
        let (projects, assets, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        #expect(try assets.get(project: "proj", slug: "nope") == nil)
    }

    @Test("list returns project's assets newest first")
    func listReturnsProjectsAssetsNewestFirst() throws {
        let (projects, assets, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try projects.createWithSlug(slug: "other", name: "Other")

        _ = try assets.add(project: "proj", slug: "a", filename: "a.mp4", filePath: "/a.mp4")
        Thread.sleep(forTimeInterval: 0.01)
        _ = try assets.add(project: "proj", slug: "b", filename: "b.mp4", filePath: "/b.mp4")
        _ = try assets.add(project: "other", slug: "x", filename: "x.mp4", filePath: "/x.mp4")

        let list = try assets.list(project: "proj")
        #expect(list.map { $0.slug } == ["b", "a"])

        let otherList = try assets.list(project: "other")
        #expect(otherList.map { $0.slug } == ["x"])
    }

    @Test("tag updates tags_json")
    func tagUpdatesTagsJson() throws {
        let (projects, assets, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try assets.add(project: "proj", slug: "c0048", filename: "c.mp4", filePath: "/c.mp4")

        try assets.tag(project: "proj", slug: "c0048", tags: ["hero", "intro"])
        let fetched = try assets.get(project: "proj", slug: "c0048")
        #expect(fetched?.tags == ["hero", "intro"])

        try assets.tag(project: "proj", slug: "c0048", tags: [])
        let cleared = try assets.get(project: "proj", slug: "c0048")
        #expect(cleared?.tags == [])
    }

    @Test("delete returns true then false")
    func deleteReturnsTrueThenFalse() throws {
        let (projects, assets, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try assets.add(project: "proj", slug: "gone", filename: "gone.mp4", filePath: "/gone.mp4")

        #expect(try assets.delete(project: "proj", slug: "gone") == true)
        #expect(try assets.delete(project: "proj", slug: "gone") == false)
    }

    @Test("FK cascade: deleting project removes its assets")
    func fkCascadeDeletesAssets() throws {
        let (projects, assets, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try assets.add(project: "proj", slug: "a", filename: "a.mp4", filePath: "/a.mp4")
        _ = try assets.add(project: "proj", slug: "b", filename: "b.mp4", filePath: "/b.mp4")

        #expect(try assets.list(project: "proj").count == 2)

        _ = try projects.delete(slug: "proj")

        let remaining = try assets.list(project: "proj")
        #expect(remaining.isEmpty)
    }
}
