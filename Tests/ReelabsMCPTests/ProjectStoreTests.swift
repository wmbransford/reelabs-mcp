import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("ProjectStore")
struct ProjectStoreTests {
    private func makeStore() throws -> (ProjectStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try Database(root: tmp)
        return (ProjectStore(database: database), tmp)
    }

    @Test("create inserts row")
    func createInsertsRow() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let record = try store.create(name: "Opus 4.7 Video", description: "A test project", tags: ["ai", "video"])
        #expect(record.slug == "opus-4-7-video")
        #expect(record.name == "Opus 4.7 Video")
        #expect(record.status == "active")
        #expect(record.tags == ["ai", "video"])
    }

    @Test("create is idempotent")
    func createIsIdempotent() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = try store.create(name: "Same Name")
        let second = try store.create(name: "Same Name")
        #expect(first.slug == second.slug)
        #expect(first.created == second.created)
    }

    @Test("createWithSlug returns existing if present")
    func createWithSlugReturnsExistingIfPresent() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "my-slug", name: "First")
        let existing = try store.createWithSlug(slug: "my-slug", name: "Renamed")
        #expect(existing.name == "First")
    }

    @Test("get returns nil for missing")
    func getReturnsNilForMissing() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(try store.get(slug: "nope") == nil)
    }

    @Test("list returns all most-recent first")
    func listReturnsAllMostRecentFirst() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "a", name: "A")
        Thread.sleep(forTimeInterval: 0.01)
        _ = try store.createWithSlug(slug: "b", name: "B")

        let all = try store.list()
        #expect(all.map { $0.slug } == ["b", "a"])
    }

    @Test("list filters by status")
    func listFiltersByStatus() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "a", name: "A")
        _ = try store.createWithSlug(slug: "b", name: "B")
        _ = try store.archive(slug: "a")

        #expect(try store.list(status: "active").map { $0.slug } == ["b"])
        #expect(try store.list(status: "archived").map { $0.slug } == ["a"])
    }

    @Test("archive flips status and bumps updated")
    func archiveFlipsStatusAndBumpsUpdated() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try store.createWithSlug(slug: "x", name: "X")
        Thread.sleep(forTimeInterval: 0.01)
        let archived = try store.archive(slug: "x")
        #expect(archived?.status == "archived")
        #expect(archived?.updated != created.updated)
    }

    @Test("delete returns true when row exists, false on second call")
    func deleteReturnsTrueWhenRowExists() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "gone", name: "Gone")
        #expect(try store.delete(slug: "gone") == true)
        #expect(try store.delete(slug: "gone") == false)
    }
}
