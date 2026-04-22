import Testing
import Foundation
import GRDB
@testable import ReelabsMCPLib

@Suite("AnalysisStore")
struct AnalysisStoreTests {
    private func makeStores() throws -> (ProjectStore, AnalysisStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try Database(root: tmp)
        return (ProjectStore(database: database), AnalysisStore(database: database), tmp)
    }

    private func sampleScenes(_ count: Int) -> [SceneRecord] {
        (0..<count).map { i in
            SceneRecord(
                sceneIndex: i,
                startTime: Double(i) * 2.0,
                endTime: Double(i) * 2.0 + 1.8,
                description: "Scene \(i)",
                tags: ["tag-\(i)"],
                sceneType: i % 2 == 0 ? "talking_head" : "b_roll"
            )
        }
    }

    @Test("save inserts analysis row with extracted status and zero scenes")
    func saveInsertsAnalysisRow() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try analyses.save(
            project: "proj",
            source: "c0048",
            sourcePath: "/tmp/C0048.MP4",
            sampleFps: 1.0,
            frameCount: 10,
            framesDir: "/tmp/frames",
            durationSeconds: 12.5
        )

        let fetched = try analyses.get(project: "proj", source: "c0048")
        #expect(fetched != nil)
        #expect(fetched?.sourcePath == "/tmp/C0048.MP4")
        #expect(fetched?.status == "extracted")
        #expect(fetched?.sampleFps == 1.0)
        #expect(fetched?.frameCount == 10)
        #expect(fetched?.sceneCount == 0)
        #expect(fetched?.durationSeconds == 12.5)
        #expect(fetched?.framesDir == "/tmp/frames")
    }

    @Test("saveScenes inserts all scenes and updates scene_count + status='analyzed'")
    func saveScenesInsertsAndUpdatesParent() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try analyses.save(
            project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
            sampleFps: 1.0, frameCount: 5, framesDir: "/tmp/f", durationSeconds: 5.0
        )

        let scenes = sampleScenes(4)
        try analyses.saveScenes(project: "proj", source: "c0048", scenes: scenes)

        let parent = try analyses.get(project: "proj", source: "c0048")
        #expect(parent?.sceneCount == 4)
        #expect(parent?.status == "analyzed")
        // Duration should be at least the last scene's end time.
        #expect((parent?.durationSeconds ?? 0) >= scenes.last?.endTime ?? 0)

        let fetched = try analyses.getScenes(project: "proj", source: "c0048")
        #expect(fetched.count == 4)
        #expect(fetched.map { $0.sceneIndex } == [0, 1, 2, 3])
    }

    @Test("saveScenes replaces existing scenes on second call")
    func saveScenesReplacesOnSecondCall() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try analyses.save(
            project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
            sampleFps: 1.0, durationSeconds: 5.0
        )

        try analyses.saveScenes(project: "proj", source: "c0048", scenes: sampleScenes(5))
        #expect(try analyses.getScenes(project: "proj", source: "c0048").count == 5)

        try analyses.saveScenes(project: "proj", source: "c0048", scenes: sampleScenes(2))
        let after = try analyses.getScenes(project: "proj", source: "c0048")
        #expect(after.count == 2)
        let parent = try analyses.get(project: "proj", source: "c0048")
        #expect(parent?.sceneCount == 2)
    }

    @Test("get returns nil for missing analysis")
    func getReturnsNilForMissing() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        #expect(try analyses.get(project: "proj", source: "nope") == nil)
    }

    @Test("getScenes returns scenes ordered by scene_index")
    func getScenesReturnsOrdered() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try analyses.save(
            project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
            sampleFps: 1.0, durationSeconds: 20.0
        )
        // Insert scenes intentionally out of order by constructing a shuffled list
        var scenes = sampleScenes(6)
        scenes.reverse()
        try analyses.saveScenes(project: "proj", source: "c0048", scenes: scenes)

        let fetched = try analyses.getScenes(project: "proj", source: "c0048")
        #expect(fetched.map { $0.sceneIndex } == [0, 1, 2, 3, 4, 5])
    }

    @Test("list returns project's analyses newest first")
    func listReturnsNewestFirst() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try projects.createWithSlug(slug: "other", name: "Other")

        _ = try analyses.save(project: "proj", source: "a", sourcePath: "/a.mp4",
                              sampleFps: 1.0, durationSeconds: 1.0)
        Thread.sleep(forTimeInterval: 0.01)
        _ = try analyses.save(project: "proj", source: "b", sourcePath: "/b.mp4",
                              sampleFps: 1.0, durationSeconds: 1.0)
        _ = try analyses.save(project: "other", source: "x", sourcePath: "/x.mp4",
                              sampleFps: 1.0, durationSeconds: 1.0)

        let list = try analyses.list(project: "proj")
        #expect(list.count == 2)
        #expect(list[0].sourcePath == "/b.mp4")
        #expect(list[1].sourcePath == "/a.mp4")
    }

    @Test("delete cascades to scenes")
    func deleteCascadesToScenes() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try analyses.save(project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
                              sampleFps: 1.0, durationSeconds: 5.0)
        try analyses.saveScenes(project: "proj", source: "c0048", scenes: sampleScenes(3))
        #expect(try analyses.getScenes(project: "proj", source: "c0048").count == 3)

        #expect(try analyses.delete(project: "proj", source: "c0048") == true)
        #expect(try analyses.get(project: "proj", source: "c0048") == nil)
        #expect(try analyses.getScenes(project: "proj", source: "c0048").isEmpty)

        #expect(try analyses.delete(project: "proj", source: "c0048") == false)
    }

    @Test("FK cascade: deleting project removes analyses and scenes")
    func fkCascadeDeletesAnalysesAndScenes() throws {
        let (projects, analyses, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try analyses.save(project: "proj", source: "a", sourcePath: "/a.mp4",
                              sampleFps: 1.0, durationSeconds: 5.0)
        _ = try analyses.save(project: "proj", source: "b", sourcePath: "/b.mp4",
                              sampleFps: 1.0, durationSeconds: 5.0)
        try analyses.saveScenes(project: "proj", source: "a", scenes: sampleScenes(2))
        try analyses.saveScenes(project: "proj", source: "b", scenes: sampleScenes(3))

        #expect(try analyses.list(project: "proj").count == 2)

        _ = try projects.delete(slug: "proj")

        #expect(try analyses.list(project: "proj").isEmpty)
        #expect(try analyses.getScenes(project: "proj", source: "a").isEmpty)
        #expect(try analyses.getScenes(project: "proj", source: "b").isEmpty)
    }
}
