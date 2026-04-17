import Testing
import Foundation
@testable import ReelabsMCPLib

/// Sample front matter type used across these tests.
private struct SampleFM: Codable, Equatable, Sendable {
    let slug: String
    let name: String
    let tags: [String]
    let count: Int
}

@Suite("MarkdownStore round-trip")
struct MarkdownStoreRoundTripTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-mdstore-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("write then read preserves front matter and body")
    func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("sample.md")
        let fm = SampleFM(slug: "my-slug", name: "Test Project", tags: ["a", "b"], count: 42)
        let original = MarkdownFile(frontMatter: fm, body: "# Heading\n\nBody content.\n")

        try MarkdownStore.write(original, to: url)
        let loaded: MarkdownFile<SampleFM> = try MarkdownStore.read(at: url, as: SampleFM.self)

        #expect(loaded.frontMatter == fm)
        #expect(loaded.body == "# Heading\n\nBody content.\n")
    }

    @Test("read throws on missing file")
    func missingFile() {
        let url = URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString).md")
        #expect(throws: MarkdownStore.MarkdownError.self) {
            _ = try MarkdownStore.read(at: url, as: SampleFM.self)
        }
    }

    @Test("read throws on missing front matter delimiters")
    func missingFrontMatter() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("no-fm.md")
        try "Just a body, no front matter.\n".data(using: .utf8)!.write(to: url)

        #expect(throws: MarkdownStore.MarkdownError.self) {
            _ = try MarkdownStore.read(at: url, as: SampleFM.self)
        }
    }

    @Test("overwriting an existing file succeeds")
    func overwrite() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("sample.md")
        let first = MarkdownFile(
            frontMatter: SampleFM(slug: "first", name: "First", tags: [], count: 1),
            body: "First body\n"
        )
        let second = MarkdownFile(
            frontMatter: SampleFM(slug: "second", name: "Second", tags: ["x"], count: 99),
            body: "Second body\n"
        )

        try MarkdownStore.write(first, to: url)
        try MarkdownStore.write(second, to: url)

        let loaded: MarkdownFile<SampleFM> = try MarkdownStore.read(at: url, as: SampleFM.self)
        #expect(loaded.frontMatter == second.frontMatter)
        #expect(loaded.body.contains("Second body"))
    }
}

@Suite("MarkdownStore.writeAtomicPair")
struct MarkdownStoreAtomicPairTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-mdstore-pair-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("writes both files on success")
    func success() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mdURL = dir.appendingPathComponent("t.transcript.md")
        let jsonURL = dir.appendingPathComponent("t.words.json")

        let fm = SampleFM(slug: "t", name: "Transcript", tags: [], count: 2)
        let file = MarkdownFile(frontMatter: fm, body: "transcript body\n")
        let jsonPayload: [[String: Any]] = [
            ["start": 0.0, "end": 0.3, "word": "Hello"],
            ["start": 0.3, "end": 0.6, "word": "World"]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonPayload)

        try MarkdownStore.writeAtomicPair(
            markdown: (url: mdURL, file: file),
            sidecar: (url: jsonURL, data: jsonData)
        )

        #expect(FileManager.default.fileExists(atPath: mdURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        let loaded: MarkdownFile<SampleFM> = try MarkdownStore.read(at: mdURL, as: SampleFM.self)
        #expect(loaded.frontMatter == fm)

        let loadedJSON = try MarkdownStore.readData(at: jsonURL)
        let parsed = try JSONSerialization.jsonObject(with: loadedJSON) as? [[String: Any]]
        #expect(parsed?.count == 2)
    }

    @Test("no temp files left behind on success")
    func noTempLeaks() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mdURL = dir.appendingPathComponent("t.transcript.md")
        let jsonURL = dir.appendingPathComponent("t.words.json")

        let file = MarkdownFile(
            frontMatter: SampleFM(slug: "t", name: "T", tags: [], count: 0),
            body: ""
        )
        try MarkdownStore.writeAtomicPair(
            markdown: (url: mdURL, file: file),
            sidecar: (url: jsonURL, data: Data("{}".utf8))
        )

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let tempFiles = contents.filter { $0.contains(".tmp.") }
        #expect(tempFiles.isEmpty)
        #expect(contents.count == 2)
    }

    @Test("atomic pair replaces existing files")
    func atomicReplace() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mdURL = dir.appendingPathComponent("t.transcript.md")
        let jsonURL = dir.appendingPathComponent("t.words.json")

        // Seed with existing content
        try Data("old md".utf8).write(to: mdURL)
        try Data("old json".utf8).write(to: jsonURL)

        let file = MarkdownFile(
            frontMatter: SampleFM(slug: "new", name: "New", tags: [], count: 5),
            body: "new body\n"
        )
        try MarkdownStore.writeAtomicPair(
            markdown: (url: mdURL, file: file),
            sidecar: (url: jsonURL, data: Data("new json".utf8))
        )

        let loaded: MarkdownFile<SampleFM> = try MarkdownStore.read(at: mdURL, as: SampleFM.self)
        #expect(loaded.frontMatter.slug == "new")

        let jsonBytes = try MarkdownStore.readData(at: jsonURL)
        #expect(String(data: jsonBytes, encoding: .utf8) == "new json")
    }
}

@Suite("MarkdownStore.splitFrontMatter")
struct MarkdownStoreSplitTests {

    @Test("splits standard format")
    func standard() throws {
        let contents = "---\nslug: x\nname: Test\ntags: []\ncount: 0\n---\n\nBody here\n"
        let url = URL(fileURLWithPath: "/tmp/placeholder.md")
        let (yaml, body) = try MarkdownStore.splitFrontMatter(contents, fileURL: url)
        #expect(yaml.contains("slug: x"))
        #expect(body == "Body here\n")
    }

    @Test("handles no body")
    func noBody() throws {
        let contents = "---\nslug: x\nname: Test\ntags: []\ncount: 0\n---\n"
        let url = URL(fileURLWithPath: "/tmp/placeholder.md")
        let (_, body) = try MarkdownStore.splitFrontMatter(contents, fileURL: url)
        #expect(body == "")
    }
}
