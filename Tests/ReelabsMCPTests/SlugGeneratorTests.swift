import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("SlugGenerator.slugify")
struct SlugGeneratorSlugifyTests {

    @Test("basic ASCII")
    func basicASCII() {
        #expect(SlugGenerator.slugify("Hello World") == "hello-world")
    }

    @Test("mixed punctuation collapses to single hyphen")
    func mixedPunctuation() {
        #expect(SlugGenerator.slugify("Hi! How's it going?") == "hi-how-s-it-going")
    }

    @Test("diacritics are stripped")
    func diacritics() {
        #expect(SlugGenerator.slugify("Café Résumé") == "cafe-resume")
    }

    @Test("consecutive whitespace and underscores collapse")
    func consecutiveSeparators() {
        #expect(SlugGenerator.slugify("A  B__C") == "a-b-c")
    }

    @Test("empty string returns untitled fallback")
    func emptyFallback() {
        #expect(SlugGenerator.slugify("") == "untitled")
    }

    @Test("only punctuation returns untitled fallback")
    func onlyPunctuation() {
        #expect(SlugGenerator.slugify("!!!???") == "untitled")
    }

    @Test("leading and trailing separators are trimmed")
    func trimmed() {
        #expect(SlugGenerator.slugify("!!!hello!!!") == "hello")
    }

    @Test("digits preserved")
    func digits() {
        #expect(SlugGenerator.slugify("C0048 April 16") == "c0048-april-16")
    }

    @Test("camera filename pattern")
    func cameraFilename() {
        #expect(SlugGenerator.slugify("C0048.MP4") == "c0048-mp4")
    }

    @Test("preserves already-slug input")
    func passThrough() {
        #expect(SlugGenerator.slugify("opus-47-video") == "opus-47-video")
    }
}

@Suite("SlugGenerator.uniqueSlug")
struct SlugGeneratorUniqueSlugTests {

    @Test("returns base when no collision")
    func noCollision() throws {
        let slug = try SlugGenerator.uniqueSlug(base: "my-slug") { _ in false }
        #expect(slug == "my-slug")
    }

    @Test("returns base-2 on first collision")
    func firstCollision() throws {
        let slug = try SlugGenerator.uniqueSlug(base: "my-slug") { candidate in
            candidate == "my-slug"
        }
        #expect(slug == "my-slug-2")
    }

    @Test("skips multiple collisions")
    func multipleCollisions() throws {
        let taken: Set<String> = ["my-slug", "my-slug-2", "my-slug-3"]
        let slug = try SlugGenerator.uniqueSlug(base: "my-slug") { candidate in
            taken.contains(candidate)
        }
        #expect(slug == "my-slug-4")
    }

    @Test("falls back to hex suffix after 100 collisions")
    func hexFallback() throws {
        var taken = Set<String>(["my-slug"])
        for n in 2...100 {
            taken.insert("my-slug-\(n)")
        }
        let slug = try SlugGenerator.uniqueSlug(base: "my-slug") { candidate in
            taken.contains(candidate)
        }
        // Starts with "my-slug-" and has at least a 4-char suffix
        #expect(slug.hasPrefix("my-slug-"))
        #expect(slug != "my-slug")
        let suffix = slug.dropFirst("my-slug-".count)
        #expect(suffix.count >= 4)
    }
}
