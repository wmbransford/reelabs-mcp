import Testing
import Foundation
import GRDB
@testable import ReelabsMCPLib

@Suite("Spine migrations")
struct SpineMigrationsTests {
    private func makeDatabase() throws -> (ReelabsMCPLib.Database, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-spine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try ReelabsMCPLib.Database(root: tmp)
        return (database, tmp)
    }

    private func tableExists(_ db: ReelabsMCPLib.Database, _ name: String) throws -> Bool {
        try db.pool.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [name]
            ) == 1
        }
    }

    @Test("all spine tables created after init")
    func allSpineTablesExist() throws {
        let (db, tmp) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try tableExists(db, "library_assets"))
        #expect(try tableExists(db, "moments"))
        #expect(try tableExists(db, "moment_features"))
        #expect(try tableExists(db, "timelines"))
        #expect(try tableExists(db, "timeline_nodes"))
        #expect(try tableExists(db, "moment_labels"))
        #expect(try tableExists(db, "eval_runs"))
        #expect(try tableExists(db, "golden_moments"))
    }

    @Test("all spine migrations recorded in schema_migrations")
    func allSpineMigrationsRecorded() throws {
        let (db, tmp) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let versions = try db.pool.read { conn in
            try String.fetchAll(conn, sql: "SELECT version FROM schema_migrations ORDER BY version")
        }
        #expect(versions.contains("002_library_assets"))
        #expect(versions.contains("003_moments"))
        #expect(versions.contains("004_moment_features"))
        #expect(versions.contains("005_timelines"))
        #expect(versions.contains("006_eval"))
    }
}
