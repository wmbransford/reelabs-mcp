import Testing
import Foundation
import GRDB
@testable import ReelabsMCPLib

@Suite("MarkdownImporter")
struct MarkdownImporterTests {
    @Test("imports existing project.md on first DB init")
    func importsExistingProjectMarkdown() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed one on-disk project the old way.
        let projectDir = tmp.appendingPathComponent("projects/my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let md = """
        ---
        schema_version: 1
        slug: my-project
        name: My Project
        status: active
        created: 2026-04-01T00:00:00.000Z
        updated: 2026-04-01T00:00:00.000Z
        description: A legacy project
        ---

        A legacy project
        """
        try md.write(to: projectDir.appendingPathComponent("project.md"), atomically: true, encoding: .utf8)

        // Open the DB — importer should run and pick it up.
        let database = try Database(root: tmp)
        let store = ProjectStore(database: database)

        let imported = try store.get(slug: "my-project")
        #expect(imported != nil)
        #expect(imported?.name == "My Project")
        #expect(imported?.status == "active")
    }

    @Test("re-opening DB does not double-import")
    func importIsIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let projectDir = tmp.appendingPathComponent("projects/my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let md = """
        ---
        schema_version: 1
        slug: my-project
        name: My Project
        status: active
        created: 2026-04-01T00:00:00.000Z
        updated: 2026-04-01T00:00:00.000Z
        ---
        """
        try md.write(to: projectDir.appendingPathComponent("project.md"), atomically: true, encoding: .utf8)

        _ = try Database(root: tmp)
        _ = try Database(root: tmp) // open again; importer should no-op

        let database = try Database(root: tmp)
        let count = try database.pool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM projects")
        }
        #expect(count == 1)
    }
}
