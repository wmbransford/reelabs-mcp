import Testing
import Foundation
import GRDB
@testable import ReelabsMCPLib

@Suite("TranscriptStore")
struct TranscriptStoreTests {
    private func makeStores() throws -> (ProjectStore, TranscriptStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try Database(root: tmp)
        return (ProjectStore(database: database), TranscriptStore(database: database), tmp)
    }

    private func sampleWords(_ count: Int, offset: Double = 0.0) -> [WordEntry] {
        (0..<count).map { i in
            WordEntry(
                word: "word\(i)",
                start: offset + Double(i) * 0.5,
                end: offset + Double(i) * 0.5 + 0.4,
                confidence: 0.95
            )
        }
    }

    @Test("save inserts transcript and all words in one txn")
    func saveInsertsTranscriptAndWords() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        let words = sampleWords(5)
        let record = try transcripts.save(
            project: "proj",
            source: "c0048",
            sourcePath: "/tmp/C0048.MP4",
            words: words,
            fullText: "word0 word1 word2 word3 word4",
            durationSeconds: 12.5,
            language: "en-US",
            mode: "sync"
        )
        #expect(record.sourcePath == "/tmp/C0048.MP4")
        #expect(record.durationSeconds == 12.5)
        #expect(record.wordCount == 5)

        let fetched = try transcripts.get(project: "proj", source: "c0048")
        #expect(fetched != nil)
        #expect(fetched?.sourcePath == "/tmp/C0048.MP4")
        #expect(fetched?.wordCount == 5)
        #expect(fetched?.language == "en-US")
        #expect(fetched?.mode == "sync")

        let fetchedWords = try transcripts.getWords(project: "proj", source: "c0048")
        #expect(fetchedWords.count == 5)
        #expect(fetchedWords.map { $0.word } == ["word0", "word1", "word2", "word3", "word4"])
    }

    @Test("save replaces words on re-save")
    func saveReplacesWordsOnReSave() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try transcripts.save(
            project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
            words: sampleWords(5), fullText: "word0 word1 word2 word3 word4",
            durationSeconds: 5.0
        )
        #expect(try transcripts.getWords(project: "proj", source: "c0048").count == 5)

        _ = try transcripts.save(
            project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
            words: sampleWords(3), fullText: "word0 word1 word2",
            durationSeconds: 3.0
        )
        let finalWords = try transcripts.getWords(project: "proj", source: "c0048")
        #expect(finalWords.count == 3)
        #expect(finalWords.map { $0.word } == ["word0", "word1", "word2"])
    }

    @Test("get returns nil for missing transcript")
    func getReturnsNilForMissing() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        #expect(try transcripts.get(project: "proj", source: "nope") == nil)
    }

    @Test("getWords returns ordered by word_index")
    func getWordsReturnsOrdered() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        let words = sampleWords(10)
        _ = try transcripts.save(
            project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
            words: words, fullText: "all words", durationSeconds: 10.0
        )

        let fetched = try transcripts.getWords(project: "proj", source: "c0048")
        #expect(fetched.count == 10)
        // Verify order matches insertion order (word_index ASC)
        #expect(fetched.map { $0.word } == (0..<10).map { "word\($0)" })
        // Also verify timestamps are in non-decreasing order (a proxy for ordering)
        for i in 1..<fetched.count {
            #expect(fetched[i].start >= fetched[i - 1].start)
        }
    }

    @Test("list returns project's transcripts newest first")
    func listReturnsNewestFirst() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try projects.createWithSlug(slug: "other", name: "Other")

        _ = try transcripts.save(project: "proj", source: "a", sourcePath: "/a.mp4",
                                 words: sampleWords(1), fullText: "a",
                                 durationSeconds: 1.0)
        Thread.sleep(forTimeInterval: 0.01)
        _ = try transcripts.save(project: "proj", source: "b", sourcePath: "/b.mp4",
                                 words: sampleWords(1), fullText: "b",
                                 durationSeconds: 1.0)
        _ = try transcripts.save(project: "other", source: "x", sourcePath: "/x.mp4",
                                 words: sampleWords(1), fullText: "x",
                                 durationSeconds: 1.0)

        let list = try transcripts.list(project: "proj")
        #expect(list.count == 2)
        // Newest first — b inserted after a
        #expect(list[0].sourcePath == "/b.mp4")
        #expect(list[1].sourcePath == "/a.mp4")

        let otherList = try transcripts.list(project: "other")
        #expect(otherList.map { $0.sourcePath } == ["/x.mp4"])
    }

    @Test("fullTextSearch finds matching source_slugs")
    func fullTextSearchMatches() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")

        _ = try transcripts.save(
            project: "proj", source: "alpha", sourcePath: "/alpha.mp4",
            words: sampleWords(3),
            fullText: "the quick brown fox jumps over the lazy dog",
            durationSeconds: 5.0
        )
        _ = try transcripts.save(
            project: "proj", source: "beta", sourcePath: "/beta.mp4",
            words: sampleWords(3),
            fullText: "opus is a transformer model for speech",
            durationSeconds: 5.0
        )

        let foxHits = try transcripts.fullTextSearch(project: "proj", query: "fox")
        #expect(foxHits == ["alpha"])

        let opusHits = try transcripts.fullTextSearch(project: "proj", query: "opus")
        #expect(opusHits == ["beta"])

        let missingHits = try transcripts.fullTextSearch(project: "proj", query: "giraffe")
        #expect(missingHits.isEmpty)
    }

    @Test("delete cascades to words")
    func deleteCascadesToWords() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try transcripts.save(
            project: "proj", source: "c0048", sourcePath: "/tmp/A.MP4",
            words: sampleWords(7), fullText: "lots of words here",
            durationSeconds: 7.0
        )
        #expect(try transcripts.getWords(project: "proj", source: "c0048").count == 7)

        #expect(try transcripts.delete(project: "proj", source: "c0048") == true)

        let leftoverWords = try transcripts.getWords(project: "proj", source: "c0048")
        #expect(leftoverWords.isEmpty)
        #expect(try transcripts.get(project: "proj", source: "c0048") == nil)

        // Second delete returns false (nothing to remove).
        #expect(try transcripts.delete(project: "proj", source: "c0048") == false)
    }

    @Test("FK cascade: deleting project removes transcripts AND words")
    func fkCascadeDeletesTranscriptsAndWords() throws {
        let (projects, transcripts, tmp) = try makeStores()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try projects.createWithSlug(slug: "proj", name: "Proj")
        _ = try transcripts.save(project: "proj", source: "a", sourcePath: "/a.mp4",
                                 words: sampleWords(4), fullText: "one two three four",
                                 durationSeconds: 4.0)
        _ = try transcripts.save(project: "proj", source: "b", sourcePath: "/b.mp4",
                                 words: sampleWords(2), fullText: "alpha beta",
                                 durationSeconds: 2.0)

        #expect(try transcripts.list(project: "proj").count == 2)

        _ = try projects.delete(slug: "proj")

        #expect(try transcripts.list(project: "proj").isEmpty)
        #expect(try transcripts.getWords(project: "proj", source: "a").isEmpty)
        #expect(try transcripts.getWords(project: "proj", source: "b").isEmpty)
    }
}
