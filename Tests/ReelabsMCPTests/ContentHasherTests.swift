import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("ContentHasher")
struct ContentHasherTests {
    private func writeFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hasher-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("deterministic hash for same content")
    func deterministicHash() throws {
        let a = try writeFile([0x48, 0x65, 0x6c, 0x6c, 0x6f])
        let b = try writeFile([0x48, 0x65, 0x6c, 0x6c, 0x6f])
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let ha = try ContentHasher.sha256(fileAt: a)
        let hb = try ContentHasher.sha256(fileAt: b)
        #expect(ha == hb)
        #expect(ha.count == 64)
    }

    @Test("different content produces different hash")
    func differentHash() throws {
        let a = try writeFile([0x01, 0x02, 0x03])
        let b = try writeFile([0x04, 0x05, 0x06])
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(try ContentHasher.sha256(fileAt: a) != ContentHasher.sha256(fileAt: b))
    }

    @Test("known SHA-256 value for 'abc'")
    func knownVector() throws {
        let a = try writeFile(Array("abc".utf8))
        defer { try? FileManager.default.removeItem(at: a) }
        #expect(try ContentHasher.sha256(fileAt: a) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("missing file throws")
    func missingFile() {
        let nowhere = URL(fileURLWithPath: "/tmp/definitely-not-a-real-file-\(UUID().uuidString)")
        #expect(throws: Error.self) {
            try ContentHasher.sha256(fileAt: nowhere)
        }
    }
}
