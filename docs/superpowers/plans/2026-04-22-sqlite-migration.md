# ReeLabs MCP — SQLite Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move ReeLabs MCP's runtime state (projects, assets, transcripts, words, analyses, scenes, renders, presets) off scattered markdown/JSON files into a single SQLite database (`reelabs.db`), mirroring the Williams Hub `hub.db` pattern. Binaries (rendered videos, extracted frames, generated PNGs, audio) stay on disk but are tracked by DB rows.

**Architecture:** Swift Package adds GRDB 7.5+ as the single SQLite dependency. A `Storage/Database.swift` owns a `DatabasePool` (WAL on, `PRAGMA foreign_keys=ON`), runs plain `.sql` migrations from `migrations/*.sql` in lexical order, and records applied migrations in a `schema_migrations` table (same convention as hub.db). Each existing `*Store` struct keeps its package-visible API but swaps its markdown-backed implementation for GRDB. On first DB init, an auto-importer reads any existing `{dataRoot}/projects/**/*.md` + `.words.json` + `.scenes.json` + `presets/*.md` and populates rows so no data is lost. `MarkdownStore` and the `Yams` dependency are deleted at the end. Kits stay as markdown (hand-authored editorial recipes) — they're templates, not runtime state.

**Tech Stack:** Swift 6.0, GRDB.swift 7.5+, SQLite (bundled), SwiftPM, XCTest. No new runtime deps beyond GRDB. `scripts/db` is a bash wrapper around `sqlite3` for human queries (parity with hub.db muscle-memory).

**Locked decisions** (don't re-argue mid-execution):
1. Kits (`{dataRoot}/kits/*.md`) are NOT migrated — they're editorial recipes, not runtime state.
2. Binaries (`Media/Frames/`, rendered `.mp4`s, PNGs from `reelabs_graphic`, extracted audio) stay on disk. File paths live in DB columns.
3. Render rows store `spec_json` (full RenderSpec as JSON) AND `notes_md` (the prose half of the old `.render.md` body). Never collapse to one.
4. `scripts/db` bash wrapper is the primary query surface (not a Swift CLI subcommand). Keeps parity with hub.db.
5. Grep-on-markdown is dead. Transcripts get an FTS5 virtual table. `CLAUDE.md` must be updated in Phase F.
6. No plan step deletes the original `.md`/`.json` files. Per William's `feedback_consolidate_not_purge` rule, that's a manual flip after parity is verified in prod.

**Repo root:** `/Users/william/Desktop/reelabs-mcp`. All paths below are relative to it unless absolute.

---

## File Structure

**New files:**
- `Sources/ReelabsMCPLib/Storage/Database.swift` — owns `DatabasePool`, runs migrations on init, runs auto-import on empty DB.
- `Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift` — one-shot: scans `{dataRoot}` for existing markdown/JSON state and writes it to DB. Idempotent (skips rows that already exist).
- `migrations/001_init.sql` — creates all tables + indexes + FTS5 virtual table + triggers.
- `scripts/db` — bash wrapper around `sqlite3` (mirrors hub.db `scripts/db`).
- `Tests/ReelabsMCPTests/DatabaseTests.swift` — migrations apply, WAL on, FKs on.
- `Tests/ReelabsMCPTests/ProjectStoreTests.swift` — replaces markdown-backed coverage.
- `Tests/ReelabsMCPTests/PresetStoreTests.swift`
- `Tests/ReelabsMCPTests/AssetStoreTests.swift`
- `Tests/ReelabsMCPTests/TranscriptStoreTests.swift`
- `Tests/ReelabsMCPTests/AnalysisStoreTests.swift`
- `Tests/ReelabsMCPTests/RenderStoreTests.swift`
- `Tests/ReelabsMCPTests/MarkdownImporterTests.swift`

**Modified files:**
- `Package.swift` — add GRDB dep, later remove Yams dep.
- `Sources/ReelabsMCPLib/Storage/Paths.swift` — add `databaseFile` URL.
- `Sources/ReelabsMCPLib/Storage/ProjectStore.swift` — rewrite internals (API unchanged).
- `Sources/ReelabsMCPLib/Storage/PresetStore.swift` — rewrite internals.
- `Sources/ReelabsMCPLib/Storage/AssetStore.swift` — rewrite internals.
- `Sources/ReelabsMCPLib/Storage/TranscriptStore.swift` — rewrite internals.
- `Sources/ReelabsMCPLib/Storage/AnalysisStore.swift` — rewrite internals.
- `Sources/ReelabsMCPLib/Storage/RenderStore.swift` — rewrite internals.
- `Sources/ReelabsMCPLib/Storage/Models.swift` — drop `Codable` ceremony where GRDB's `FetchableRecord`/`PersistableRecord` replaces it; keep DTOs where tools need them.
- `Sources/ReelabsMCPLib/ServerConfig.swift` (or wherever the Stores are constructed) — pass the shared `Database` into each Store.
- `CLAUDE.md` — replace "Grep on `*.md`" with FTS5 guidance; update `{dataRoot}` layout.
- `AGENTS.md` — update storage architecture section.

**Deleted files (end of plan only):**
- `Sources/ReelabsMCPLib/Storage/MarkdownStore.swift`
- Yams imports throughout Storage (`import Yams` → removed).

---

## Schema (embedded here for reference; authoritative form is `migrations/001_init.sql`)

```sql
-- bookkeeping
CREATE TABLE schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- projects
CREATE TABLE projects (
    slug         TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'active',
    description  TEXT,
    tags_json    TEXT,                        -- JSON array or NULL
    created      TEXT NOT NULL,                -- ISO8601 with fractional seconds
    updated      TEXT NOT NULL
);
CREATE INDEX idx_projects_status ON projects(status);
CREATE INDEX idx_projects_created ON projects(created DESC);

-- assets
CREATE TABLE assets (
    project_slug      TEXT NOT NULL REFERENCES projects(slug) ON DELETE CASCADE,
    slug              TEXT NOT NULL,
    filename          TEXT NOT NULL,
    file_path         TEXT NOT NULL,
    file_size_bytes   INTEGER,
    duration_seconds  REAL,
    width             INTEGER,
    height            INTEGER,
    fps               REAL,
    codec             TEXT,
    has_audio         INTEGER NOT NULL DEFAULT 1,
    tags_json         TEXT,
    created           TEXT NOT NULL,
    PRIMARY KEY (project_slug, slug)
);
CREATE INDEX idx_assets_created ON assets(project_slug, created DESC);

-- transcripts (one row per source)
CREATE TABLE transcripts (
    project_slug      TEXT NOT NULL REFERENCES projects(slug) ON DELETE CASCADE,
    source_slug       TEXT NOT NULL,
    source_path       TEXT NOT NULL,
    duration_seconds  REAL NOT NULL,
    word_count        INTEGER NOT NULL,
    language          TEXT NOT NULL DEFAULT 'en-US',
    mode              TEXT NOT NULL DEFAULT 'sync',
    full_text         TEXT NOT NULL DEFAULT '',
    created           TEXT NOT NULL,
    PRIMARY KEY (project_slug, source_slug)
);

-- transcript words (one row per word)
CREATE TABLE transcript_words (
    project_slug   TEXT NOT NULL,
    source_slug    TEXT NOT NULL,
    word_index     INTEGER NOT NULL,
    word           TEXT NOT NULL,
    start_time     REAL NOT NULL,
    end_time       REAL NOT NULL,
    confidence     REAL,
    PRIMARY KEY (project_slug, source_slug, word_index),
    FOREIGN KEY (project_slug, source_slug)
      REFERENCES transcripts(project_slug, source_slug) ON DELETE CASCADE
);
CREATE INDEX idx_words_time ON transcript_words(project_slug, source_slug, start_time);

-- FTS5 on transcripts.full_text (contentless, populated by triggers)
CREATE VIRTUAL TABLE transcripts_fts USING fts5(
    full_text,
    project_slug UNINDEXED,
    source_slug  UNINDEXED,
    tokenize = 'porter unicode61'
);

CREATE TRIGGER transcripts_fts_ai AFTER INSERT ON transcripts BEGIN
    INSERT INTO transcripts_fts(rowid, full_text, project_slug, source_slug)
    VALUES (new.rowid, new.full_text, new.project_slug, new.source_slug);
END;
CREATE TRIGGER transcripts_fts_ad AFTER DELETE ON transcripts BEGIN
    INSERT INTO transcripts_fts(transcripts_fts, rowid, full_text, project_slug, source_slug)
    VALUES ('delete', old.rowid, old.full_text, old.project_slug, old.source_slug);
END;
CREATE TRIGGER transcripts_fts_au AFTER UPDATE ON transcripts BEGIN
    INSERT INTO transcripts_fts(transcripts_fts, rowid, full_text, project_slug, source_slug)
    VALUES ('delete', old.rowid, old.full_text, old.project_slug, old.source_slug);
    INSERT INTO transcripts_fts(rowid, full_text, project_slug, source_slug)
    VALUES (new.rowid, new.full_text, new.project_slug, new.source_slug);
END;

-- analyses (one row per source)
CREATE TABLE analyses (
    project_slug      TEXT NOT NULL REFERENCES projects(slug) ON DELETE CASCADE,
    source_slug       TEXT NOT NULL,
    source_path       TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'extracted',
    sample_fps        REAL NOT NULL,
    frame_count       INTEGER NOT NULL DEFAULT 0,
    scene_count       INTEGER NOT NULL DEFAULT 0,
    duration_seconds  REAL NOT NULL DEFAULT 0,
    frames_dir        TEXT NOT NULL DEFAULT '',
    created           TEXT NOT NULL,
    PRIMARY KEY (project_slug, source_slug)
);

-- scenes (one row per scene)
CREATE TABLE scenes (
    project_slug  TEXT NOT NULL,
    source_slug   TEXT NOT NULL,
    scene_index   INTEGER NOT NULL,
    start_time    REAL NOT NULL,
    end_time      REAL NOT NULL,
    description   TEXT NOT NULL,
    tags_json     TEXT,
    scene_type    TEXT,
    PRIMARY KEY (project_slug, source_slug, scene_index),
    FOREIGN KEY (project_slug, source_slug)
      REFERENCES analyses(project_slug, source_slug) ON DELETE CASCADE
);

-- renders
CREATE TABLE renders (
    project_slug      TEXT NOT NULL REFERENCES projects(slug) ON DELETE CASCADE,
    slug              TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'completed',
    duration_seconds  REAL,
    output_path       TEXT NOT NULL,
    file_size_bytes   INTEGER,
    sources_json      TEXT,                     -- JSON array of source slugs
    spec_json         TEXT NOT NULL,            -- full RenderSpec as JSON
    notes_md          TEXT NOT NULL DEFAULT '', -- prose half of the old .render.md body
    created           TEXT NOT NULL,
    PRIMARY KEY (project_slug, slug)
);
CREATE INDEX idx_renders_created ON renders(project_slug, created DESC);

-- presets (global, unique by name)
CREATE TABLE presets (
    name         TEXT PRIMARY KEY,
    type         TEXT NOT NULL,
    description  TEXT,
    config_json  TEXT NOT NULL,
    created      TEXT NOT NULL,
    updated      TEXT NOT NULL
);
```

---

## Phase A — DB foundation

### Task A1: Add GRDB dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Edit `Package.swift` to add GRDB**

Add to `dependencies` array (in alphabetical order with siblings):

```swift
.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
```

Add to the `ReelabsMCPLib` target's `dependencies` array:

```swift
.product(name: "GRDB", package: "GRDB.swift"),
```

- [ ] **Step 2: Resolve packages**

Run: `swift package resolve`
Expected: `Fetching https://github.com/groue/GRDB.swift.git ...` then `Resolved`. No errors.

- [ ] **Step 3: Verify the build still compiles**

Run: `swift build`
Expected: build succeeds, warnings OK.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "chore: add GRDB.swift 7.5 dependency"
```

---

### Task A2: Create `scripts/db` bash wrapper

**Files:**
- Create: `scripts/db`

- [ ] **Step 1: Write `scripts/db`**

```bash
#!/usr/bin/env bash
# scripts/db — thin wrapper around sqlite3 for ReeLabs MCP
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# Respect REELABS_DATA_DIR in dev; fall back to the Homebrew/prod location.
if [[ -n "${REELABS_DATA_DIR:-}" ]]; then
    DATA_ROOT="${REELABS_DATA_DIR/#\~/$HOME}"
else
    DATA_ROOT="$HOME/Library/Application Support/ReelabsMCP"
fi
DB="$DATA_ROOT/reelabs.db"

PRAGMAS=(-cmd "PRAGMA foreign_keys=ON" -cmd "PRAGMA synchronous=NORMAL" -cmd ".timeout 5000")

usage() {
    cat <<EOF
Usage: db <subcommand> [args]

Subcommands:
  query "<SQL>"       Run SELECT, aligned columns with headers.
  query-json "<SQL>"  Run SELECT, output JSON.
  exec "<SQL>"        Run INSERT/UPDATE/DELETE/DDL.
  tables              List tables.
  path                Print resolved DB path.
EOF
}

require_db() {
    if [[ ! -f "$DB" ]]; then
        echo "error: reelabs.db not found at $DB" >&2
        echo "hint: start the MCP server once so migrations run" >&2
        exit 1
    fi
}

sub="${1-}"
[[ -z "$sub" ]] && { usage; exit 1; }
shift || true
case "$sub" in
    query)      require_db; sqlite3 "${PRAGMAS[@]}" -header -column "$DB" "${1:?usage: db query \"<SQL>\"}";;
    query-json) require_db; sqlite3 "${PRAGMAS[@]}" -json "$DB" "${1:?usage: db query-json \"<SQL>\"}";;
    exec)       require_db; sqlite3 "${PRAGMAS[@]}" "$DB" "${1:?usage: db exec \"<SQL>\"}";;
    tables)     require_db; sqlite3 "${PRAGMAS[@]}" "$DB" ".tables";;
    path)       echo "$DB";;
    -h|--help)  usage;;
    *)          echo "unknown subcommand: $sub" >&2; usage; exit 1;;
esac
```

- [ ] **Step 2: chmod + smoke test**

Run: `chmod +x scripts/db && scripts/db path`
Expected: prints a path ending in `/reelabs.db`. (File won't exist yet; that's fine.)

- [ ] **Step 3: Commit**

```bash
git add scripts/db
git commit -m "chore: add scripts/db wrapper (mirrors hub.db pattern)"
```

---

### Task A3: Write migration `001_init.sql`

**Files:**
- Create: `migrations/001_init.sql`

- [ ] **Step 1: Create the migrations directory and the SQL file**

Write the full schema from the "Schema" section above into `migrations/001_init.sql` verbatim. Include every `CREATE TABLE`, `CREATE INDEX`, `CREATE VIRTUAL TABLE`, and `CREATE TRIGGER`.

- [ ] **Step 2: Sanity-check the SQL parses**

Run: `sqlite3 :memory: < migrations/001_init.sql`
Expected: exits 0 with no output. Any syntax error aborts with a message.

- [ ] **Step 3: Commit**

```bash
git add migrations/001_init.sql
git commit -m "feat: initial SQLite schema (projects, assets, transcripts, renders, presets, FTS5)"
```

---

### Task A4: Create `Database.swift` — DatabasePool + migration runner

**Files:**
- Modify: `Sources/ReelabsMCPLib/Storage/Paths.swift`
- Create: `Sources/ReelabsMCPLib/Storage/Database.swift`
- Modify: `Package.swift` (Resources)
- Create: `Tests/ReelabsMCPTests/DatabaseTests.swift`

- [ ] **Step 1: Add `databaseFile` to `DataPaths`**

In `Paths.swift`, after `framesDir`, add:

```swift
package var databaseFile: URL { root.appendingPathComponent("reelabs.db") }
package var migrationsDir: URL { root.appendingPathComponent("migrations", isDirectory: true) }
```

Note: at runtime migrations come from the bundled resources, not `{dataRoot}`. `migrationsDir` is only used by tests that want to load the SQL directly.

- [ ] **Step 2: Bundle migrations/ as a Resource**

In `Package.swift`, inside the `ReelabsMCPLib` target, change:

```swift
resources: [
    .copy("Resources/kits"),
],
```

to:

```swift
resources: [
    .copy("Resources/kits"),
    .copy("Resources/migrations"),
],
```

Then copy the physical files:

```bash
mkdir -p Sources/ReelabsMCPLib/Resources/migrations
cp migrations/001_init.sql Sources/ReelabsMCPLib/Resources/migrations/
```

(`migrations/` at repo root stays as the human-editable source; the Resources copy is what the binary ships with. A CI/lint step can enforce parity later — out of scope.)

- [ ] **Step 3: Write the failing test**

Create `Tests/ReelabsMCPTests/DatabaseTests.swift`:

```swift
import XCTest
import GRDB
@testable import ReelabsMCPLib

final class DatabaseTests: XCTestCase {
    func test_migrationsApplyOnOpen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try Database(root: tmp)

        try db.pool.read { conn in
            let count = try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM schema_migrations WHERE version = '001_init'"
            )
            XCTAssertEqual(count, 1)
        }
    }

    func test_foreignKeysAreOn() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try Database(root: tmp)
        let fk = try db.pool.read { conn in
            try Int.fetchOne(conn, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(fk, 1)
    }

    func test_walModeIsOn() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try Database(root: tmp)
        let mode = try db.pool.read { conn in
            try String.fetchOne(conn, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `swift test --filter DatabaseTests`
Expected: FAIL with "cannot find 'Database' in scope" (compilation error).

- [ ] **Step 5: Create `Database.swift`**

```swift
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
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter DatabaseTests`
Expected: 3 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/ReelabsMCPLib/Storage/Database.swift Sources/ReelabsMCPLib/Storage/Paths.swift Sources/ReelabsMCPLib/Resources/migrations/001_init.sql Tests/ReelabsMCPTests/DatabaseTests.swift
git commit -m "feat: Database.swift — DatabasePool, WAL, FK, migration runner"
```

---

## Phase B — ProjectStore as template

### Task B1: Port ProjectStore tests to DB backend

**Files:**
- Create: `Tests/ReelabsMCPTests/ProjectStoreTests.swift`

- [ ] **Step 1: Write the tests**

```swift
import XCTest
@testable import ReelabsMCPLib

final class ProjectStoreTests: XCTestCase {
    private func makeStore() throws -> (ProjectStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelabs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let database = try Database(root: tmp)
        return (ProjectStore(database: database), tmp)
    }

    func test_create_insertsRow() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let record = try store.create(name: "Opus 4.7 Video", description: "A test project", tags: ["ai", "video"])
        XCTAssertEqual(record.slug, "opus-4-7-video")
        XCTAssertEqual(record.name, "Opus 4.7 Video")
        XCTAssertEqual(record.status, "active")
        XCTAssertEqual(record.tags, ["ai", "video"])
    }

    func test_create_isIdempotent() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = try store.create(name: "Same Name")
        let second = try store.create(name: "Same Name")
        XCTAssertEqual(first.slug, second.slug)
        XCTAssertEqual(first.created, second.created)
    }

    func test_createWithSlug_returnsExistingIfPresent() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "my-slug", name: "First")
        let existing = try store.createWithSlug(slug: "my-slug", name: "Renamed")
        XCTAssertEqual(existing.name, "First")
    }

    func test_get_returnsNilForMissing() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertNil(try store.get(slug: "nope"))
    }

    func test_list_returnsAllMostRecentFirst() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "a", name: "A")
        Thread.sleep(forTimeInterval: 0.01)
        _ = try store.createWithSlug(slug: "b", name: "B")

        let all = try store.list()
        XCTAssertEqual(all.map { $0.slug }, ["b", "a"])
    }

    func test_list_filtersByStatus() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "a", name: "A")
        _ = try store.createWithSlug(slug: "b", name: "B")
        _ = try store.archive(slug: "a")

        XCTAssertEqual(try store.list(status: "active").map { $0.slug }, ["b"])
        XCTAssertEqual(try store.list(status: "archived").map { $0.slug }, ["a"])
    }

    func test_archive_flipsStatusAndBumpsUpdated() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try store.createWithSlug(slug: "x", name: "X")
        Thread.sleep(forTimeInterval: 0.01)
        let archived = try store.archive(slug: "x")
        XCTAssertEqual(archived?.status, "archived")
        XCTAssertNotEqual(archived?.updated, created.updated)
    }

    func test_delete_returnsTrueWhenRowExists() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.createWithSlug(slug: "gone", name: "Gone")
        XCTAssertTrue(try store.delete(slug: "gone"))
        XCTAssertFalse(try store.delete(slug: "gone"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ProjectStoreTests`
Expected: compile errors — `ProjectStore` still has the old `init(paths: DataPaths)` signature, not `init(database: Database)`.

- [ ] **Step 3: Commit tests-first**

```bash
git add Tests/ReelabsMCPTests/ProjectStoreTests.swift
git commit -m "test: ProjectStore DB-backed coverage (red)"
```

---

### Task B2: Rewrite `ProjectStore` internals to use GRDB

**Files:**
- Modify: `Sources/ReelabsMCPLib/Storage/ProjectStore.swift`

- [ ] **Step 1: Replace the entire file**

```swift
import Foundation
import GRDB

/// SQLite-backed project storage. One row per project in the `projects` table.
package struct ProjectStore: Sendable {
    let database: Database

    package init(database: Database) {
        self.database = database
    }

    /// Create a project. Slug is derived from the name and made unique against existing rows.
    /// If the derived slug already exists, returns the existing row (idempotent by name).
    package func create(name: String, description: String? = nil, tags: [String]? = nil) throws -> ProjectRecord {
        let baseSlug = SlugGenerator.slugify(name)
        if let existing = try get(slug: baseSlug), existing.name == name {
            return existing
        }
        let uniqueSlug = try database.pool.read { conn in
            try SlugGenerator.uniqueSlug(base: baseSlug) { candidate in
                try Int.fetchOne(conn, sql: "SELECT 1 FROM projects WHERE slug = ?", arguments: [candidate]) != nil
            }
        }
        return try createWithSlug(slug: uniqueSlug, name: name, description: description, tags: tags)
    }

    /// Create a project with an explicit slug. Returns the existing row if the slug already exists.
    package func createWithSlug(slug: String, name: String? = nil, description: String? = nil, tags: [String]? = nil) throws -> ProjectRecord {
        if let existing = try get(slug: slug) {
            return existing
        }
        let now = Timestamp.now()
        let record = ProjectRecord(
            slug: slug,
            name: name ?? slug,
            status: "active",
            created: now,
            updated: now,
            description: description,
            tags: tags
        )
        let tagsJSON = try record.tags.map { try JSONSerialization.data(withJSONObject: $0).asUTF8String() }
        try database.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO projects (slug, name, status, description, tags_json, created, updated)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [record.slug, record.name, record.status, record.description, tagsJSON, record.created, record.updated]
            )
        }
        return record
    }

    package func get(slug: String) throws -> ProjectRecord? {
        try database.pool.read { conn in
            try ProjectRecord.fetchOneBySlug(conn, slug: slug)
        }
    }

    package func list(status: String? = nil) throws -> [ProjectRecord] {
        try database.pool.read { conn in
            if let status {
                return try ProjectRecord.fetchAll(conn, sql: """
                    SELECT slug, name, status, description, tags_json, created, updated
                    FROM projects WHERE status = ? ORDER BY created DESC
                """, arguments: [status])
            } else {
                return try ProjectRecord.fetchAll(conn, sql: """
                    SELECT slug, name, status, description, tags_json, created, updated
                    FROM projects ORDER BY created DESC
                """)
            }
        }
    }

    @discardableResult
    package func archive(slug: String) throws -> ProjectRecord? {
        guard try get(slug: slug) != nil else { return nil }
        let now = Timestamp.now()
        try database.pool.write { conn in
            try conn.execute(
                sql: "UPDATE projects SET status = 'archived', updated = ? WHERE slug = ?",
                arguments: [now, slug]
            )
        }
        return try get(slug: slug)
    }

    @discardableResult
    package func delete(slug: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM projects WHERE slug = ?", arguments: [slug])
            return conn.changesCount > 0
        }
    }
}

// MARK: - GRDB row decoding

extension ProjectRecord: FetchableRecord {
    package init(row: Row) throws {
        let tagsJSON: String? = row["tags_json"]
        let tags: [String]?
        if let tagsJSON, let data = tagsJSON.data(using: .utf8) {
            tags = try? JSONSerialization.jsonObject(with: data) as? [String]
        } else {
            tags = nil
        }
        self.init(
            slug: row["slug"],
            name: row["name"],
            status: row["status"],
            created: row["created"],
            updated: row["updated"],
            description: row["description"],
            tags: tags
        )
    }

    static func fetchOneBySlug(_ conn: GRDB.Database, slug: String) throws -> ProjectRecord? {
        try ProjectRecord.fetchOne(conn, sql: """
            SELECT slug, name, status, description, tags_json, created, updated
            FROM projects WHERE slug = ?
        """, arguments: [slug])
    }
}

// small helper
private extension Data {
    func asUTF8String() throws -> String {
        guard let s = String(data: self, encoding: .utf8) else {
            throw NSError(domain: "ProjectStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "tags_json not valid UTF-8"])
        }
        return s
    }
}
```

- [ ] **Step 2: Tighten `SlugGenerator.uniqueSlug` to support throwing predicates**

Open `Sources/ReelabsMCPLib/Storage/SlugGenerator.swift` and change the existing `uniqueSlug(base:exists:)` signature from `(String) -> Bool` to `(String) throws -> Bool`, and rethrow from inside. If it's already throwing, skip.

- [ ] **Step 3: Wire call sites to the new `init(database:)`**

Grep for `ProjectStore(paths:` across the repo and replace with `ProjectStore(database:)`. These are the Tool layer files (`ProjectTool.swift` and anywhere Stores are constructed at server startup). They'll need the shared `Database` — which doesn't exist yet at server startup. For this task, leave Tool-layer changes as compile errors and stub a TODO; fix them in Phase E where we wire up the shared `Database` in `ServerConfig`.

Actually: to keep the tree compiling commit-to-commit, wire it up now. Open `ServerConfig.swift` (or whichever top-level object builds Stores), add a `let database: Database` property initialized from the existing data-root, and pass it into `ProjectStore(database:)` at every call site. Leave the old `paths` property in place for the stores that still use it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ProjectStoreTests`
Expected: 7 tests pass.

- [ ] **Step 5: Run the full test suite to catch regressions**

Run: `swift test`
Expected: all tests pass (only `ProjectStore`-related code has changed; other stores untouched).

- [ ] **Step 6: Commit**

```bash
git add Sources/ReelabsMCPLib/Storage/ProjectStore.swift Sources/ReelabsMCPLib/Storage/SlugGenerator.swift Sources/ReelabsMCPLib/ServerConfig.swift
git commit -m "feat: ProjectStore now backed by SQLite via GRDB"
```

---

### Task B3: Auto-import existing `project.md` on empty DB

**Files:**
- Create: `Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift`
- Modify: `Sources/ReelabsMCPLib/Storage/Database.swift`
- Create: `Tests/ReelabsMCPTests/MarkdownImporterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ReelabsMCPLib

final class MarkdownImporterTests: XCTestCase {
    func test_importsExistingProjectMarkdown() throws {
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
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported?.name, "My Project")
        XCTAssertEqual(imported?.status, "active")
    }

    func test_importIsIdempotent() throws {
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
        XCTAssertEqual(count, 1)
    }
}
```

- [ ] **Step 2: Verify it fails**

Run: `swift test --filter MarkdownImporterTests`
Expected: failure — `MarkdownImporter` doesn't exist.

- [ ] **Step 3: Create `MarkdownImporter.swift`**

```swift
import Foundation
import Yams
import GRDB

/// One-shot importer that reads pre-SQLite on-disk markdown state and writes it into the DB.
/// Called from `Database.init` *after* migrations. Idempotent — re-running it on a populated
/// DB is a no-op for rows that already exist.
package enum MarkdownImporter {
    package static func runIfNeeded(database: Database) throws {
        try importProjects(database: database)
        // Later tasks will extend this with presets, assets, transcripts, analyses, renders.
    }

    static func importProjects(database: Database) throws {
        let projectsDir = database.paths.projectsDir
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return }

        let entries = try FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            let projectMd = entry.appendingPathComponent("project.md")
            guard FileManager.default.fileExists(atPath: projectMd.path) else { continue }

            guard let parsed = try? MarkdownStore.read(at: projectMd, as: ProjectRecord.self).frontMatter else {
                continue
            }

            let tagsJSON: String?
            if let tags = parsed.tags {
                let data = try JSONSerialization.data(withJSONObject: tags)
                tagsJSON = String(data: data, encoding: .utf8)
            } else {
                tagsJSON = nil
            }

            try database.pool.write { conn in
                try conn.execute(
                    sql: """
                        INSERT OR IGNORE INTO projects (slug, name, status, description, tags_json, created, updated)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [parsed.slug, parsed.name, parsed.status, parsed.description, tagsJSON, parsed.created, parsed.updated]
                )
            }
        }
    }
}
```

- [ ] **Step 4: Call it from `Database.init`**

At the bottom of `Database.init`, after `try runMigrations()`, add:

```swift
try MarkdownImporter.runIfNeeded(database: self)
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MarkdownImporterTests` then `swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift Sources/ReelabsMCPLib/Storage/Database.swift Tests/ReelabsMCPTests/MarkdownImporterTests.swift
git commit -m "feat: auto-import existing project.md files on DB init (idempotent)"
```

---

## Phase C — Remaining stores (one commit per store)

Each store follows the same shape as Phase B (test first → rewrite internals → extend `MarkdownImporter` → verify → commit). Snippets below show the final store code for each; tests follow the ProjectStore shape — cover `create`, `get`, `list`, `delete`, status filters where applicable, and any store-specific methods (e.g. `update`, `tag`, `getWords`).

### Task C1: PresetStore

**Files:**
- Modify: `Sources/ReelabsMCPLib/Storage/PresetStore.swift`
- Modify: `Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift` (add `importPresets`)
- Create: `Tests/ReelabsMCPTests/PresetStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Create `PresetStoreTests.swift` mirroring `ProjectStoreTests.swift` shape. Cover: `upsert(name:type:description:configJson:)`, `get(name:)`, `list()`, `list(type:)`, `delete(name:)`. Use a fresh `Database` per test.

- [ ] **Step 2: Verify they fail**

Run: `swift test --filter PresetStoreTests`
Expected: compile errors (old signature).

- [ ] **Step 3: Rewrite `PresetStore.swift`**

```swift
import Foundation
import GRDB

package struct PresetStore: Sendable {
    let database: Database

    package init(database: Database) { self.database = database }

    @discardableResult
    package func upsert(name: String, type: String, configJson: String, description: String? = nil) throws -> PresetRecord {
        let now = Timestamp.now()
        let existing = try get(name: name)
        let created = existing?.created ?? now
        let record = PresetRecord(name: name, type: type, configJson: configJson, description: description, created: created, updated: now)

        try database.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO presets (name, type, description, config_json, created, updated)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        type = excluded.type,
                        description = excluded.description,
                        config_json = excluded.config_json,
                        updated = excluded.updated
                """,
                arguments: [record.name, record.type, record.description, record.configJson, record.created, record.updated]
            )
        }
        return record
    }

    package func get(name: String) throws -> PresetRecord? {
        try database.pool.read { conn in
            try PresetRecord.fetchOne(conn, sql: """
                SELECT name, type, description, config_json, created, updated
                FROM presets WHERE name = ?
            """, arguments: [name])
        }
    }

    package func list(type: String? = nil) throws -> [PresetRecord] {
        try database.pool.read { conn in
            if let type {
                return try PresetRecord.fetchAll(conn, sql: "SELECT name, type, description, config_json, created, updated FROM presets WHERE type = ? ORDER BY name", arguments: [type])
            } else {
                return try PresetRecord.fetchAll(conn, sql: "SELECT name, type, description, config_json, created, updated FROM presets ORDER BY name")
            }
        }
    }

    @discardableResult
    package func delete(name: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM presets WHERE name = ?", arguments: [name])
            return conn.changesCount > 0
        }
    }
}

extension PresetRecord: FetchableRecord {
    package init(row: Row) throws {
        self.init(
            name: row["name"],
            type: row["type"],
            configJson: row["config_json"],
            description: row["description"],
            created: row["created"],
            updated: row["updated"]
        )
    }
}
```

- [ ] **Step 4: Extend `MarkdownImporter`**

Add to `MarkdownImporter.swift`:

```swift
static func importPresets(database: Database) throws {
    let dir = database.paths.presetsDir
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "md" }
    for file in files {
        guard let parsed = try? MarkdownStore.read(at: file, as: PresetRecord.self).frontMatter else { continue }
        try database.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT OR IGNORE INTO presets (name, type, description, config_json, created, updated)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [parsed.name, parsed.type, parsed.description, parsed.configJson, parsed.created, parsed.updated]
            )
        }
    }
}
```

Call it from `runIfNeeded`.

- [ ] **Step 5: Fix Tool-layer call sites**

Grep for `PresetStore(paths:` → `PresetStore(database:)`.

- [ ] **Step 6: Run tests + full suite, commit**

```bash
swift test
git add Sources/ReelabsMCPLib/Storage/PresetStore.swift Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift Tests/ReelabsMCPTests/PresetStoreTests.swift Sources/ReelabsMCPLib/Tools/PresetTool.swift
git commit -m "feat: PresetStore backed by SQLite; auto-import from presets/*.md"
```

---

### Task C2: AssetStore

**Files:**
- Modify: `Sources/ReelabsMCPLib/Storage/AssetStore.swift`
- Modify: `Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift` (add `importAssets`)
- Create: `Tests/ReelabsMCPTests/AssetStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Cover: `add(project:slug:filename:filePath:...)`, `get(project:slug:)`, `list(project:)`, `tag(project:slug:tags:)`, `delete(project:slug:)`. FK cascade test: create project + asset, delete project via `ProjectStore.delete(slug:)`, assert the asset row is gone.

- [ ] **Step 2: Rewrite `AssetStore.swift`**

```swift
import Foundation
import GRDB

package struct AssetStore: Sendable {
    let database: Database

    package init(database: Database) { self.database = database }

    @discardableResult
    package func add(
        project: String,
        slug: String,
        filename: String,
        filePath: String,
        fileSizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        codec: String? = nil,
        hasAudio: Bool = true,
        tags: [String]? = nil
    ) throws -> AssetRecord {
        let now = Timestamp.now()
        let record = AssetRecord(
            slug: slug, filename: filename, filePath: filePath,
            fileSizeBytes: fileSizeBytes, durationSeconds: durationSeconds,
            width: width, height: height, fps: fps, codec: codec,
            hasAudio: hasAudio, tags: tags, created: now
        )
        let tagsJSON = try tags.flatMap {
            String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)
        }
        try database.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO assets (project_slug, slug, filename, file_path, file_size_bytes,
                        duration_seconds, width, height, fps, codec, has_audio, tags_json, created)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(project_slug, slug) DO UPDATE SET
                        filename = excluded.filename,
                        file_path = excluded.file_path,
                        file_size_bytes = excluded.file_size_bytes,
                        duration_seconds = excluded.duration_seconds,
                        width = excluded.width, height = excluded.height,
                        fps = excluded.fps, codec = excluded.codec,
                        has_audio = excluded.has_audio, tags_json = excluded.tags_json
                """,
                arguments: [project, slug, filename, filePath, fileSizeBytes, durationSeconds,
                            width, height, fps, codec, hasAudio ? 1 : 0, tagsJSON, now]
            )
        }
        return record
    }

    package func get(project: String, slug: String) throws -> AssetRecord? {
        try database.pool.read { conn in
            try AssetRecord.fetchOne(conn, sql: """
                SELECT slug, filename, file_path, file_size_bytes, duration_seconds,
                       width, height, fps, codec, has_audio, tags_json, created
                FROM assets WHERE project_slug = ? AND slug = ?
            """, arguments: [project, slug])
        }
    }

    package func list(project: String) throws -> [AssetRecord] {
        try database.pool.read { conn in
            try AssetRecord.fetchAll(conn, sql: """
                SELECT slug, filename, file_path, file_size_bytes, duration_seconds,
                       width, height, fps, codec, has_audio, tags_json, created
                FROM assets WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    package func tag(project: String, slug: String, tags: [String]) throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: tags), encoding: .utf8)
        try database.pool.write { conn in
            try conn.execute(sql: "UPDATE assets SET tags_json = ? WHERE project_slug = ? AND slug = ?",
                             arguments: [json, project, slug])
        }
    }

    @discardableResult
    package func delete(project: String, slug: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM assets WHERE project_slug = ? AND slug = ?", arguments: [project, slug])
            return conn.changesCount > 0
        }
    }
}

extension AssetRecord: FetchableRecord {
    package init(row: Row) throws {
        let tagsJSON: String? = row["tags_json"]
        let tags: [String]? = tagsJSON.flatMap {
            ($0.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }
        }
        self.init(
            slug: row["slug"],
            filename: row["filename"],
            filePath: row["file_path"],
            fileSizeBytes: row["file_size_bytes"],
            durationSeconds: row["duration_seconds"],
            width: row["width"],
            height: row["height"],
            fps: row["fps"],
            codec: row["codec"],
            hasAudio: (row["has_audio"] as Int? ?? 1) != 0,
            tags: tags,
            created: row["created"]
        )
    }
}
```

- [ ] **Step 3: Extend `MarkdownImporter` with `importAssets`**

Walks each `projects/{slug}/*.asset.md` file, parses frontmatter into `AssetRecord`, and does `INSERT OR IGNORE INTO assets`. The `project_slug` comes from the parent directory name.

- [ ] **Step 4: Fix call sites, run tests, commit**

```bash
swift test
git add -A
git commit -m "feat: AssetStore backed by SQLite; auto-import from *.asset.md"
```

---

### Task C3: TranscriptStore (transcripts + transcript_words)

**Files:**
- Modify: `Sources/ReelabsMCPLib/Storage/TranscriptStore.swift`
- Modify: `Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift` (add `importTranscripts`)
- Create: `Tests/ReelabsMCPTests/TranscriptStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Cover: `save(project:source:transcript:words:)` (inserts transcript + all words in ONE transaction), `get(project:source:)` (returns transcript + optionally words), `list(project:)`, `delete(project:source:)` (cascades to words), and an FTS check: `fullTextSearch(project:query:)` returns matching source_slugs.

- [ ] **Step 2: Rewrite `TranscriptStore.swift`**

```swift
import Foundation
import GRDB

package struct TranscriptStore: Sendable {
    let database: Database

    package init(database: Database) { self.database = database }

    @discardableResult
    package func save(
        project: String,
        source: String,
        sourcePath: String,
        words: [WordEntry],
        fullText: String,
        durationSeconds: Double,
        language: String = "en-US",
        mode: String = "sync"
    ) throws -> TranscriptRecord {
        let now = Timestamp.now()
        let record = TranscriptRecord(
            slug: "\(project)/\(source)",
            sourcePath: sourcePath,
            durationSeconds: durationSeconds,
            wordCount: words.count,
            language: language, mode: mode, created: now
        )

        try database.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO transcripts (project_slug, source_slug, source_path, duration_seconds,
                    word_count, language, mode, full_text, created)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_slug, source_slug) DO UPDATE SET
                    source_path = excluded.source_path,
                    duration_seconds = excluded.duration_seconds,
                    word_count = excluded.word_count,
                    language = excluded.language,
                    mode = excluded.mode,
                    full_text = excluded.full_text,
                    created = excluded.created
            """, arguments: [project, source, sourcePath, durationSeconds,
                             words.count, language, mode, fullText, now])

            try conn.execute(sql: "DELETE FROM transcript_words WHERE project_slug = ? AND source_slug = ?",
                             arguments: [project, source])

            for (i, w) in words.enumerated() {
                try conn.execute(sql: """
                    INSERT INTO transcript_words (project_slug, source_slug, word_index, word, start_time, end_time, confidence)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [project, source, i, w.word, w.start, w.end, w.confidence])
            }
        }
        return record
    }

    package func get(project: String, source: String) throws -> TranscriptRecord? {
        try database.pool.read { conn in
            try TranscriptRecord.fetchOne(conn, sql: """
                SELECT project_slug, source_slug, source_path, duration_seconds,
                       word_count, language, mode, created
                FROM transcripts WHERE project_slug = ? AND source_slug = ?
            """, arguments: [project, source])
        }
    }

    package func getWords(project: String, source: String) throws -> [WordEntry] {
        try database.pool.read { conn in
            try WordEntry.fetchAll(conn, sql: """
                SELECT word, start_time AS start, end_time AS end, confidence
                FROM transcript_words
                WHERE project_slug = ? AND source_slug = ?
                ORDER BY word_index
            """, arguments: [project, source])
        }
    }

    package func list(project: String) throws -> [TranscriptRecord] {
        try database.pool.read { conn in
            try TranscriptRecord.fetchAll(conn, sql: """
                SELECT project_slug, source_slug, source_path, duration_seconds,
                       word_count, language, mode, created
                FROM transcripts WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    package func fullTextSearch(project: String, query: String) throws -> [String] {
        try database.pool.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT source_slug FROM transcripts_fts
                WHERE transcripts_fts MATCH ? AND project_slug = ?
                ORDER BY rank
            """, arguments: [query, project])
        }
    }

    @discardableResult
    package func delete(project: String, source: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM transcripts WHERE project_slug = ? AND source_slug = ?",
                             arguments: [project, source])
            return conn.changesCount > 0
        }
    }
}

extension TranscriptRecord: FetchableRecord {
    package init(row: Row) throws {
        self.init(
            slug: "\(row["project_slug"] as String)/\(row["source_slug"] as String)",
            sourcePath: row["source_path"],
            durationSeconds: row["duration_seconds"],
            wordCount: row["word_count"],
            language: row["language"],
            mode: row["mode"],
            created: row["created"]
        )
    }
}

extension WordEntry: FetchableRecord {
    package init(row: Row) throws {
        self.init(
            word: row["word"],
            start: row["start"],
            end: row["end"],
            confidence: row["confidence"]
        )
    }
}
```

- [ ] **Step 3: Extend `MarkdownImporter` with `importTranscripts`**

For each `projects/{slug}/*.transcript.md`, parse the frontmatter and read the sibling `{source}.words.json`. Build a `[WordEntry]`, then call `TranscriptStore.save(...)` (or inline SQL) inside a single transaction.

- [ ] **Step 4: Fix call sites, run tests, commit**

```bash
swift test
git add -A
git commit -m "feat: TranscriptStore backed by SQLite + FTS5; migrate *.transcript.md + *.words.json"
```

---

### Task C4: AnalysisStore (analyses + scenes)

**Files:**
- Modify: `Sources/ReelabsMCPLib/Storage/AnalysisStore.swift`
- Modify: `Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift` (add `importAnalyses`)
- Create: `Tests/ReelabsMCPTests/AnalysisStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Cover: `save(project:source:sourcePath:sampleFps:framesDir:)` (creates analysis row, no scenes yet); `saveScenes(project:source:scenes:)` (inserts scenes, updates `scene_count` and `duration_seconds`); `get(project:source:)`, `getScenes(project:source:)`, `list(project:)`, `delete(project:source:)` (cascades to scenes).

- [ ] **Step 2: Rewrite `AnalysisStore.swift`**

```swift
import Foundation
import GRDB

package struct AnalysisStore: Sendable {
    let database: Database

    package init(database: Database) { self.database = database }

    @discardableResult
    package func save(
        project: String,
        source: String,
        sourcePath: String,
        sampleFps: Double,
        frameCount: Int = 0,
        framesDir: String = "",
        durationSeconds: Double = 0
    ) throws -> AnalysisRecord {
        let now = Timestamp.now()
        let record = AnalysisRecord(
            slug: "\(project)/\(source)", sourcePath: sourcePath,
            sampleFps: sampleFps, frameCount: frameCount,
            sceneCount: 0, durationSeconds: durationSeconds,
            framesDir: framesDir, created: now
        )
        try database.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO analyses (project_slug, source_slug, source_path, status, sample_fps,
                    frame_count, scene_count, duration_seconds, frames_dir, created)
                VALUES (?, ?, ?, 'extracted', ?, ?, 0, ?, ?, ?)
                ON CONFLICT(project_slug, source_slug) DO UPDATE SET
                    source_path = excluded.source_path,
                    sample_fps = excluded.sample_fps,
                    frame_count = excluded.frame_count,
                    duration_seconds = excluded.duration_seconds,
                    frames_dir = excluded.frames_dir
            """, arguments: [project, source, sourcePath, sampleFps,
                             frameCount, durationSeconds, framesDir, now])
        }
        return record
    }

    package func saveScenes(project: String, source: String, scenes: [SceneRecord]) throws {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM scenes WHERE project_slug = ? AND source_slug = ?",
                             arguments: [project, source])
            for s in scenes {
                let tagsJSON = try s.tags.flatMap {
                    String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)
                }
                try conn.execute(sql: """
                    INSERT INTO scenes (project_slug, source_slug, scene_index, start_time, end_time,
                        description, tags_json, scene_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [project, source, s.sceneIndex, s.startTime, s.endTime,
                                 s.description, tagsJSON, s.sceneType])
            }
            let duration = scenes.map { $0.endTime }.max() ?? 0
            try conn.execute(sql: """
                UPDATE analyses SET scene_count = ?, duration_seconds = MAX(duration_seconds, ?), status = 'analyzed'
                WHERE project_slug = ? AND source_slug = ?
            """, arguments: [scenes.count, duration, project, source])
        }
    }

    package func get(project: String, source: String) throws -> AnalysisRecord? {
        try database.pool.read { conn in
            try AnalysisRecord.fetchOne(conn, sql: """
                SELECT project_slug, source_slug, source_path, status, sample_fps,
                       frame_count, scene_count, duration_seconds, frames_dir, created
                FROM analyses WHERE project_slug = ? AND source_slug = ?
            """, arguments: [project, source])
        }
    }

    package func getScenes(project: String, source: String) throws -> [SceneRecord] {
        try database.pool.read { conn in
            try SceneRecord.fetchAll(conn, sql: """
                SELECT scene_index, start_time, end_time, description, tags_json, scene_type
                FROM scenes WHERE project_slug = ? AND source_slug = ? ORDER BY scene_index
            """, arguments: [project, source])
        }
    }

    package func list(project: String) throws -> [AnalysisRecord] {
        try database.pool.read { conn in
            try AnalysisRecord.fetchAll(conn, sql: """
                SELECT project_slug, source_slug, source_path, status, sample_fps,
                       frame_count, scene_count, duration_seconds, frames_dir, created
                FROM analyses WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    @discardableResult
    package func delete(project: String, source: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM analyses WHERE project_slug = ? AND source_slug = ?",
                             arguments: [project, source])
            return conn.changesCount > 0
        }
    }
}

extension AnalysisRecord: FetchableRecord {
    package init(row: Row) throws {
        self.init(
            slug: "\(row["project_slug"] as String)/\(row["source_slug"] as String)",
            sourcePath: row["source_path"],
            status: row["status"],
            sampleFps: row["sample_fps"],
            frameCount: row["frame_count"],
            sceneCount: row["scene_count"],
            durationSeconds: row["duration_seconds"],
            framesDir: row["frames_dir"],
            created: row["created"]
        )
    }
}

extension SceneRecord: FetchableRecord {
    package init(row: Row) throws {
        let tagsJSON: String? = row["tags_json"]
        let tags: [String]? = tagsJSON.flatMap {
            ($0.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }
        }
        self.init(
            sceneIndex: row["scene_index"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            description: row["description"],
            tags: tags,
            sceneType: row["scene_type"]
        )
    }
}
```

- [ ] **Step 3: Extend `MarkdownImporter`**

For each `projects/{slug}/*.analysis.md`, read frontmatter → `analyses` row; read sibling `{source}.scenes.json` → `scenes` rows.

- [ ] **Step 4: Fix call sites, run tests, commit**

```bash
swift test
git add -A
git commit -m "feat: AnalysisStore backed by SQLite; migrate *.analysis.md + *.scenes.json"
```

---

### Task C5: RenderStore

**Files:**
- Modify: `Sources/ReelabsMCPLib/Storage/RenderStore.swift`
- Modify: `Sources/ReelabsMCPLib/Storage/MarkdownImporter.swift` (add `importRenders`)
- Create: `Tests/ReelabsMCPTests/RenderStoreTests.swift`

Note the split: `spec_json` holds the RenderSpec as JSON, `notes_md` holds whatever prose the old `.render.md` body contained.

- [ ] **Step 1: Write failing tests**

Cover: `save(project:slug:specJSON:outputPath:...)` with and without notes; `get(project:slug:)` returns both fields; `list(project:)`; `delete(project:slug:)`.

- [ ] **Step 2: Rewrite `RenderStore.swift`**

```swift
import Foundation
import GRDB

package struct RenderStore: Sendable {
    let database: Database

    package init(database: Database) { self.database = database }

    @discardableResult
    package func save(
        project: String,
        slug: String,
        specJSON: String,
        outputPath: String,
        status: String = "completed",
        durationSeconds: Double? = nil,
        fileSizeBytes: Int64? = nil,
        sources: [String]? = nil,
        notesMd: String = ""
    ) throws -> RenderRecord {
        let now = Timestamp.now()
        let sourcesJSON = try sources.flatMap {
            String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)
        }
        try database.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO renders (project_slug, slug, status, duration_seconds, output_path,
                    file_size_bytes, sources_json, spec_json, notes_md, created)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_slug, slug) DO UPDATE SET
                    status = excluded.status,
                    duration_seconds = excluded.duration_seconds,
                    output_path = excluded.output_path,
                    file_size_bytes = excluded.file_size_bytes,
                    sources_json = excluded.sources_json,
                    spec_json = excluded.spec_json,
                    notes_md = excluded.notes_md
            """, arguments: [project, slug, status, durationSeconds, outputPath,
                             fileSizeBytes, sourcesJSON, specJSON, notesMd, now])
        }
        return RenderRecord(
            slug: "\(project)/\(slug)", status: status, created: now,
            durationSeconds: durationSeconds, outputPath: outputPath,
            fileSizeBytes: fileSizeBytes, sources: sources
        )
    }

    package func get(project: String, slug: String) throws -> RenderRecord? {
        try database.pool.read { conn in
            try RenderRecord.fetchOne(conn, sql: """
                SELECT project_slug, slug, status, duration_seconds, output_path,
                       file_size_bytes, sources_json, spec_json, notes_md, created
                FROM renders WHERE project_slug = ? AND slug = ?
            """, arguments: [project, slug])
        }
    }

    package func getSpec(project: String, slug: String) throws -> String? {
        try database.pool.read { conn in
            try String.fetchOne(conn, sql: "SELECT spec_json FROM renders WHERE project_slug = ? AND slug = ?",
                                arguments: [project, slug])
        }
    }

    package func getNotes(project: String, slug: String) throws -> String? {
        try database.pool.read { conn in
            try String.fetchOne(conn, sql: "SELECT notes_md FROM renders WHERE project_slug = ? AND slug = ?",
                                arguments: [project, slug])
        }
    }

    package func list(project: String) throws -> [RenderRecord] {
        try database.pool.read { conn in
            try RenderRecord.fetchAll(conn, sql: """
                SELECT project_slug, slug, status, duration_seconds, output_path,
                       file_size_bytes, sources_json, spec_json, notes_md, created
                FROM renders WHERE project_slug = ? ORDER BY created DESC
            """, arguments: [project])
        }
    }

    @discardableResult
    package func delete(project: String, slug: String) throws -> Bool {
        try database.pool.write { conn in
            try conn.execute(sql: "DELETE FROM renders WHERE project_slug = ? AND slug = ?", arguments: [project, slug])
            return conn.changesCount > 0
        }
    }
}

extension RenderRecord: FetchableRecord {
    package init(row: Row) throws {
        let sourcesJSON: String? = row["sources_json"]
        let sources: [String]? = sourcesJSON.flatMap {
            ($0.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }
        }
        self.init(
            slug: "\(row["project_slug"] as String)/\(row["slug"] as String)",
            status: row["status"],
            created: row["created"],
            durationSeconds: row["duration_seconds"],
            outputPath: row["output_path"],
            fileSizeBytes: row["file_size_bytes"],
            sources: sources
        )
    }
}
```

- [ ] **Step 3: Extend `MarkdownImporter`**

For each `projects/{slug}/*.render.md`: frontmatter → `RenderRecord` fields; the body needs to be split — if the body begins with a fenced `json` block, extract that as `spec_json` and the remainder as `notes_md`; otherwise use the frontmatter's serialized form (if any) as `spec_json` and the full body as `notes_md`. (Implementation reads the existing render.md format — check one sample before writing the parser.)

- [ ] **Step 4: Run tests, commit**

```bash
swift test
git add -A
git commit -m "feat: RenderStore backed by SQLite (spec_json + notes_md split); migrate *.render.md"
```

---

## Phase D — Parity verification

### Task D1: `scripts/db verify-parity` — re-export DB and diff against markdown

**Files:**
- Create: `scripts/verify-parity.py` (Python 3, no deps)
- Modify: `scripts/db` (add `verify-parity` subcommand that shells to the Python script)

- [ ] **Step 1: Write the verifier**

`scripts/verify-parity.py` reads every project from the DB via `sqlite3`, re-renders the equivalent markdown frontmatter in memory, and compares against the on-disk `.md` / `.json` files. Reports: `OK` (files match), `MISSING_IN_DB` (file on disk but no row), `MISSING_ON_DISK` (row but no file), `DIFFER` (both exist but content differs — prints a minimal diff). Exits 0 on OK, 1 on any mismatch.

Keep scope minimal: check projects, assets, transcripts (words.json), analyses (scenes.json), renders, presets. Ignore body whitespace and timestamp formatting jitter where possible; raise when a field value actually differs.

The script's job is to answer one question: *can we safely delete the on-disk `.md` files?* Run it; read the report; decide manually.

- [ ] **Step 2: Wire it into `scripts/db`**

Add to `scripts/db`:

```bash
verify-parity) python3 "$HERE/verify-parity.py" "$DATA_ROOT";;
```

Add a usage line above.

- [ ] **Step 3: Commit**

```bash
git add scripts/db scripts/verify-parity.py
git commit -m "feat: scripts/db verify-parity — compare SQLite rows against on-disk markdown"
```

- [ ] **Step 4: Manual parity run (documented, not automated)**

Add a section to `AGENTS.md` titled "Verifying the SQLite migration" that says:

```
After upgrading, run:

  scripts/db verify-parity

If the report is all OK, the on-disk markdown files are now redundant and can be
deleted manually. Suggested:

  cd "$(scripts/db path | xargs dirname)"
  mv projects projects.pre-sqlite.bak

Leave the backup folder in place for at least a week before deleting.
```

Commit that doc change with the verifier.

---

## Phase E — Cleanup

### Task E1: Delete MarkdownStore and Yams

**Files:**
- Delete: `Sources/ReelabsMCPLib/Storage/MarkdownStore.swift`
- Modify: `Package.swift` (drop Yams)
- Modify: all Storage files (remove `import Yams`)

- [ ] **Step 1: Verify nothing outside MarkdownImporter still imports Yams or uses MarkdownStore**

Run: `grep -r "MarkdownStore\|import Yams" Sources/ReelabsMCPLib/`
Expected: only `MarkdownImporter.swift` and `MarkdownStore.swift` itself appear. If anything else matches, fix those first — they should be using the DB-backed store.

- [ ] **Step 2: Move `MarkdownImporter` + `MarkdownStore` into an `Importer/` subdirectory**

Keep them — they're still needed for the one-shot import path. Move to `Sources/ReelabsMCPLib/Storage/Importer/` so it's visually separated from the live stores.

- [ ] **Step 3: Verify the build still passes**

Run: `swift build && swift test`
Expected: green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: isolate MarkdownImporter under Storage/Importer (legacy read path only)"
```

Note: Yams stays because `MarkdownImporter` still parses YAML frontmatter. Only drop Yams after William confirms the legacy markdown is gone from disk and the importer can be deleted entirely. That's a future plan, not this one.

---

### Task E2: Expose full-text search through the MCP tool surface

**Files:**
- Modify: `Sources/ReelabsMCPLib/Tools/TranscriptTool.swift` (add `search` action)

- [ ] **Step 1: Write a test**

Add to `TranscriptStoreTests.swift`:

```swift
func test_fullTextSearch_findsMatchingSources() throws {
    let (store, db, tmp) = try makeStore()
    defer { try? FileManager.default.removeItem(at: tmp) }
    _ = try ProjectStore(database: db).createWithSlug(slug: "p", name: "P")
    _ = try store.save(project: "p", source: "a", sourcePath: "/a.mp4",
                       words: [WordEntry(word: "hello", start: 0, end: 1, confidence: 1)],
                       fullText: "hello world", durationSeconds: 1)
    _ = try store.save(project: "p", source: "b", sourcePath: "/b.mp4",
                       words: [WordEntry(word: "goodbye", start: 0, end: 1, confidence: 1)],
                       fullText: "goodbye moon", durationSeconds: 1)
    let hits = try store.fullTextSearch(project: "p", query: "hello")
    XCTAssertEqual(hits, ["a"])
}
```

- [ ] **Step 2: Add `search` action to `TranscriptTool`**

Extend the existing tool's action dispatch with a `search` case that takes `project` + `query` args and calls `TranscriptStore.fullTextSearch(project:query:)`. Return the list of matching source slugs.

- [ ] **Step 3: Run tests, commit**

```bash
swift test
git add -A
git commit -m "feat: reelabs_transcript gains a 'search' action (FTS5-backed)"
```

---

## Phase F — Documentation

### Task F1: Update CLAUDE.md + AGENTS.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update CLAUDE.md**

1. Replace the paragraph that begins `> Full-text search is done via your built-in Grep tool on {dataRoot}/**/*.md` with:

   ```
   > Full-text search over transcripts uses the `search` action on `reelabs_transcript` (FTS5-backed). Other state (projects, assets, renders, presets, analyses) is queryable via `scripts/db query "..."` — the SQLite database at `{dataRoot}/reelabs.db` is the source of truth.
   ```

2. Update the `{dataRoot}` description line to mention `reelabs.db` sits alongside `kits/`.

3. In the "ID format" section, note that slugs are primary keys in SQLite.

- [ ] **Step 2: Update AGENTS.md**

Replace the storage architecture section with the new layout:

- `reelabs.db` (SQLite, WAL, GRDB) — projects, assets, transcripts, words, analyses, scenes, renders, presets.
- `kits/*.md` — hand-authored editorial recipes. NOT in the DB.
- `Media/Frames/`, rendered `.mp4`s, generated PNGs, extracted `.m4a` — binary outputs on disk, tracked by DB rows.
- `migrations/*.sql` — schema evolution, applied in lexical order, recorded in `schema_migrations`.

Document the `scripts/db` commands and the `verify-parity` subcommand.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md AGENTS.md
git commit -m "docs: CLAUDE.md + AGENTS.md updated for SQLite-backed storage"
```

---

## Done

At the end of this plan:

- `reelabs.db` holds all runtime state.
- Stores expose unchanged package APIs to the Tool layer; internals are GRDB.
- FTS5 gives transcript search; `scripts/db` gives ad-hoc SQL.
- On-disk `.md` / `.json` state still exists but is dormant — the importer reads it once on first DB init, and `verify-parity` confirms nothing was dropped.
- Deletion of dormant files is a manual follow-up after bake-time.

What's intentionally NOT in this plan:
- Deleting on-disk markdown (manual, after verified parity).
- Dropping Yams (blocked on deleting `MarkdownImporter`, which is blocked on deleting the markdown).
- Backup automation for `reelabs.db` (follow-up; mirror hub's `scripts/backup-hub`).
- A `reelabs_search` tool distinct from `reelabs_transcript`'s search action (not needed; Grep instruction in CLAUDE.md already goes away).
