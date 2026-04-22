import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("PresetStore")
struct PresetStoreTests {
    private func makeStore() throws -> (PresetStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try Database(root: tmp)
        return (PresetStore(database: database), tmp)
    }

    @Test("upsert inserts new preset")
    func upsertInsertsNewPreset() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let record = try store.upsert(
            name: "cinema-2k",
            type: "render",
            configJson: #"{"width":2048,"height":1152}"#,
            description: "2K cinema render"
        )
        #expect(record.name == "cinema-2k")
        #expect(record.type == "render")
        #expect(record.configJson == #"{"width":2048,"height":1152}"#)
        #expect(record.description == "2K cinema render")

        let roundTrip = try store.get(name: "cinema-2k")
        #expect(roundTrip?.name == "cinema-2k")
        #expect(roundTrip?.type == "render")
        #expect(roundTrip?.configJson == #"{"width":2048,"height":1152}"#)
        #expect(roundTrip?.description == "2K cinema render")
    }

    @Test("upsert updates existing preset, preserving created")
    func upsertUpdatesExisting() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = try store.upsert(name: "p1", type: "render", configJson: #"{"v":1}"#, description: "v1")
        Thread.sleep(forTimeInterval: 0.01)
        let second = try store.upsert(name: "p1", type: "caption", configJson: #"{"v":2}"#, description: "v2")

        #expect(second.created == first.created)
        #expect(second.updated != first.updated)
        #expect(second.type == "caption")
        #expect(second.configJson == #"{"v":2}"#)
        #expect(second.description == "v2")

        let fetched = try store.get(name: "p1")
        #expect(fetched?.type == "caption")
        #expect(fetched?.configJson == #"{"v":2}"#)
        #expect(fetched?.description == "v2")
        #expect(fetched?.created == first.created)
    }

    @Test("get returns nil for missing")
    func getReturnsNilForMissing() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(try store.get(name: "nope") == nil)
    }

    @Test("list returns all sorted by name")
    func listReturnsAllSortedByName() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.upsert(name: "zeta", type: "render", configJson: "{}")
        _ = try store.upsert(name: "alpha", type: "render", configJson: "{}")
        _ = try store.upsert(name: "mu", type: "caption", configJson: "{}")

        let all = try store.list()
        #expect(all.map { $0.name } == ["alpha", "mu", "zeta"])
    }

    @Test("list filters by type")
    func listFiltersByType() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.upsert(name: "render-a", type: "render", configJson: "{}")
        _ = try store.upsert(name: "render-b", type: "render", configJson: "{}")
        _ = try store.upsert(name: "cap-a", type: "caption", configJson: "{}")

        #expect(try store.list(type: "render").map { $0.name } == ["render-a", "render-b"])
        #expect(try store.list(type: "caption").map { $0.name } == ["cap-a"])
        #expect(try store.list(type: "audio").map { $0.name } == [])
    }

    @Test("delete returns true when row exists, false on second call")
    func deleteReturnsTrueWhenRowExists() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.upsert(name: "gone", type: "render", configJson: "{}")
        #expect(try store.delete(name: "gone") == true)
        #expect(try store.delete(name: "gone") == false)
    }
}
