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

    private func extractText(_ result: CallTool.Result) -> String {
        for item in result.content {
            if case .text(let text, _, _) = item { return text }
        }
        return ""
    }
}
