import Testing
import Foundation
import MCP
@testable import ReelabsMCPLib

@Suite("IngestTool")
struct IngestToolTests {
    private func makeStore() throws -> (LibraryAssetStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try ReelabsMCPLib.Database(root: tmp)
        return (LibraryAssetStore(database: database), tmp)
    }

    @Test("tool name and schema fields")
    func toolDescriptor() {
        #expect(IngestTool.tool.name == "reelabs_ingest")
        #expect(IngestTool.tool.description?.contains("library") ?? false)
    }

    @Test("missing path returns error")
    func missingPath() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = await IngestTool.handle(
            arguments: ["kind": .string("captured_video")],
            store: store
        )
        #expect(result.isError == true)
        let text = extractText(result)
        #expect(text.contains("path"))
    }

    @Test("unknown kind returns error")
    func unknownKind() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = await IngestTool.handle(
            arguments: [
                "path": .string("/tmp/x.mp4"),
                "kind": .string("not_a_real_kind")
            ],
            store: store
        )
        #expect(result.isError == true)
        let text = extractText(result)
        #expect(text.contains("kind"))
    }

    @Test("unsupported kind in plan 1 returns clear error")
    func unsupportedKindRejected() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = await IngestTool.handle(
            arguments: [
                "path": .string("/tmp/anything.mp3"),
                "kind": .string("tts_audio")
            ],
            store: store
        )
        #expect(result.isError == true)
        let text = extractText(result)
        #expect(text.contains("not yet supported"))
    }

    @Test("missing file on disk returns error")
    func missingFile() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = await IngestTool.handle(
            arguments: [
                "path": .string("/tmp/definitely-not-here-\(UUID().uuidString).mp4"),
                "kind": .string("captured_video")
            ],
            store: store
        )
        #expect(result.isError == true)
        let text = extractText(result)
        #expect(text.contains("not found") || text.contains("No such file"))
    }

    @Test("registers a real file and returns json with id + content_hash")
    func registersRealFile() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Copy a test-fixture video into the tmp dir so VideoProbe + ContentHasher have a real file.
        guard let fixtureURL = Bundle.module.url(forResource: "tiny", withExtension: "mov", subdirectory: "Fixtures") else {
            Issue.record("Missing test fixture: tiny.mov — ensure Tests/ReelabsMCPTests/Fixtures/tiny.mov is bundled")
            return
        }
        let dest = tmp.appendingPathComponent("tiny.mov")
        try FileManager.default.copyItem(at: fixtureURL, to: dest)

        let result = await IngestTool.handle(
            arguments: [
                "path": .string(dest.path),
                "kind": .string("captured_video")
            ],
            store: store
        )
        #expect(result.isError == false)
        let text = extractText(result)
        #expect(text.contains("library_asset_id"))
        #expect(text.contains("content_hash"))

        let rows = try store.listByKind(.capturedVideo)
        #expect(rows.count == 1)
        #expect(rows[0].path == dest.path)
        #expect((rows[0].contentHash?.count ?? 0) == 64)
        #expect(rows[0].durationS != nil)
    }

    @Test("re-ingesting same file returns existing record without duplicating")
    func dedupSameFile() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let fixtureURL = Bundle.module.url(forResource: "tiny", withExtension: "mov", subdirectory: "Fixtures") else {
            Issue.record("Missing test fixture: tiny.mov")
            return
        }
        let dest = tmp.appendingPathComponent("tiny.mov")
        try FileManager.default.copyItem(at: fixtureURL, to: dest)

        let first = await IngestTool.handle(
            arguments: ["path": .string(dest.path), "kind": .string("captured_video")],
            store: store
        )
        let second = await IngestTool.handle(
            arguments: ["path": .string(dest.path), "kind": .string("captured_video")],
            store: store
        )
        #expect(first.isError == false)
        #expect(second.isError == false)

        let rows = try store.listByKind(.capturedVideo)
        #expect(rows.count == 1)

        let secondText = extractText(second)
        #expect(secondText.contains("already_registered"))
    }

    private func extractText(_ result: CallTool.Result) -> String {
        for item in result.content {
            if case .text(let text, _, _) = item { return text }
        }
        return ""
    }
}
