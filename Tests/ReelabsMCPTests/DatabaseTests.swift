import Testing
import Foundation
import GRDB
@testable import ReelabsMCPLib

@Suite("Database")
struct DatabaseTests {
    private func makeTempRoot() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("migrations apply on open")
    func migrationsApplyOnOpen() throws {
        let tmp = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try Database(root: tmp)

        let count = try db.pool.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM schema_migrations WHERE version = '001_init'"
            )
        }
        #expect(count == 1)
    }

    @Test("foreign keys are on")
    func foreignKeysAreOn() throws {
        let tmp = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try Database(root: tmp)
        let fk = try db.pool.read { conn in
            try Int.fetchOne(conn, sql: "PRAGMA foreign_keys")
        }
        #expect(fk == 1)
    }

    @Test("WAL mode is on")
    func walModeIsOn() throws {
        let tmp = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try Database(root: tmp)
        let mode = try db.pool.read { conn in
            try String.fetchOne(conn, sql: "PRAGMA journal_mode")
        }
        #expect(mode?.lowercased() == "wal")
    }
}
