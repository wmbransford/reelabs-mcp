import Testing
import Foundation
import GRDB
@testable import ReelabsMCPLib

@Suite("RenderStore")
struct RenderStoreTests {
    private func makeStores() throws -> (ProjectStore, RenderStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try Database(root: tmp)
        return (ProjectStore(database: database), RenderStore(database: database), tmp)
    }

    private let sampleSpec = #"{"outputPath":"/tmp/out.mp4","segments":[]}"#

    @Test("save inserts render with spec_json and empty notes_md by default")
    func saveInsertsRenderWithEmptyNotes() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try renders.save(
            project: "proj",
            slug: "r1",
            specJSON: sampleSpec,
            outputPath: "/tmp/out.mp4",
            status: "completed",
            durationSeconds: 10.5,
            fileSizeBytes: 2_000_000,
            sources: ["a", "b"]
        )

        let spec = try renders.getSpec(project: "proj", slug: "r1")
        #expect(spec == sampleSpec)

        let notes = try renders.getNotes(project: "proj", slug: "r1")
        #expect(notes == "")
    }

    @Test("save with notes_md persists the notes")
    func saveWithNotesPersists() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try renders.save(
            project: "proj", slug: "r1", specJSON: sampleSpec,
            outputPath: "/tmp/out.mp4",
            notesMd: "## Notes\n\nThis render is excellent."
        )

        #expect(try renders.getNotes(project: "proj", slug: "r1") ==
                "## Notes\n\nThis render is excellent.")
    }

    @Test("save upserts on conflict")
    func saveUpsertsOnConflict() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try renders.save(project: "proj", slug: "r1", specJSON: sampleSpec,
                             outputPath: "/tmp/a.mp4", status: "pending")
        _ = try renders.save(project: "proj", slug: "r1", specJSON: sampleSpec,
                             outputPath: "/tmp/b.mp4", status: "completed",
                             notesMd: "updated")

        let record = try renders.get(project: "proj", slug: "r1")
        #expect(record?.outputPath == "/tmp/b.mp4")
        #expect(record?.status == "completed")
        #expect(try renders.getNotes(project: "proj", slug: "r1") == "updated")
        #expect(try renders.list(project: "proj").count == 1)
    }

    @Test("get returns the full record")
    func getReturnsFullRecord() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try renders.save(
            project: "proj", slug: "r1", specJSON: sampleSpec,
            outputPath: "/tmp/out.mp4",
            durationSeconds: 7.25, fileSizeBytes: 1_234_567, sources: ["x"]
        )

        let record = try renders.get(project: "proj", slug: "r1")
        #expect(record != nil)
        #expect(record?.outputPath == "/tmp/out.mp4")
        #expect(record?.durationSeconds == 7.25)
        #expect(record?.fileSizeBytes == 1_234_567)
        #expect(record?.sources == ["x"])
    }

    @Test("get returns nil for missing render")
    func getReturnsNilForMissing() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        #expect(try renders.get(project: "proj", slug: "nope") == nil)
        #expect(try renders.getSpec(project: "proj", slug: "nope") == nil)
        #expect(try renders.getNotes(project: "proj", slug: "nope") == nil)
    }

    @Test("list returns project's renders newest first")
    func listReturnsNewestFirst() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try projects.createWithSlug(slug: "other", name: "Other")

        _ = try renders.save(project: "proj", slug: "a", specJSON: sampleSpec, outputPath: "/a.mp4")
        Thread.sleep(forTimeInterval: 0.01)
        _ = try renders.save(project: "proj", slug: "b", specJSON: sampleSpec, outputPath: "/b.mp4")
        _ = try renders.save(project: "other", slug: "z", specJSON: sampleSpec, outputPath: "/z.mp4")

        let list = try renders.list(project: "proj")
        #expect(list.count == 2)
        #expect(list[0].outputPath == "/b.mp4")
        #expect(list[1].outputPath == "/a.mp4")
    }

    @Test("delete returns true then false")
    func deleteReturnsTrueThenFalse() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try renders.save(project: "proj", slug: "r1", specJSON: sampleSpec, outputPath: "/tmp/out.mp4")

        #expect(try renders.delete(project: "proj", slug: "r1") == true)
        #expect(try renders.get(project: "proj", slug: "r1") == nil)
        #expect(try renders.delete(project: "proj", slug: "r1") == false)
    }

    @Test("FK cascade: deleting project removes renders")
    func fkCascadeFromProject() throws {
        let (projects, renders, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try renders.save(project: "proj", slug: "a", specJSON: sampleSpec, outputPath: "/a.mp4")
        _ = try renders.save(project: "proj", slug: "b", specJSON: sampleSpec, outputPath: "/b.mp4")
        #expect(try renders.list(project: "proj").count == 2)

        _ = try projects.delete(slug: "proj")
        #expect(try renders.list(project: "proj").isEmpty)
    }
}
