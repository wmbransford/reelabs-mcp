import Foundation
import GRDB

/// Owns the single `DatabasePool` for the ReeLabs data store.
/// - WAL mode is enabled by DatabasePool automatically.
/// - `PRAGMA foreign_keys=ON` is set for every connection via Configuration.
/// - Migrations are applied on init, in lexical order, from the bundled `Resources/migrations/`.
package final class Database: @unchecked Sendable {
    package let pool: DatabasePool
    package let paths: DataPaths

    package init(root: URL) throws {
        let paths = DataPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { conn in
            try conn.execute(sql: "PRAGMA foreign_keys = ON")
            try conn.execute(sql: "PRAGMA synchronous = NORMAL")
            try conn.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        self.pool = try DatabasePool(path: paths.databaseFile.path, configuration: config)
        self.paths = paths

        try runMigrations()
    }

    private func runMigrations() throws {
        try pool.write { conn in
            try conn.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version TEXT PRIMARY KEY,
                    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
        }

        let migrations = try loadBundledMigrations()
        for (version, sql) in migrations {
            let already = try pool.read { conn in
                try Int.fetchOne(conn, sql: "SELECT 1 FROM schema_migrations WHERE version = ?", arguments: [version])
            }
            if already != nil { continue }

            try pool.writeWithoutTransaction { conn in
                try conn.inTransaction {
                    try conn.execute(sql: sql)
                    try conn.execute(sql: "INSERT INTO schema_migrations (version) VALUES (?)", arguments: [version])
                    return .commit
                }
            }
        }
    }

    /// Loads `.sql` files from the bundled migrations directory, sorted by filename.
    /// Returns `(version, sql)` pairs where `version` is the filename without extension.
    private func loadBundledMigrations() throws -> [(String, String)] {
        let bundle = Bundle.module
        guard let dir = bundle.url(forResource: "migrations", withExtension: nil) else {
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sql" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try files.map { url in
            let version = url.deletingPathExtension().lastPathComponent
            let sql = try String(contentsOf: url, encoding: .utf8)
            return (version, sql)
        }
    }
}
