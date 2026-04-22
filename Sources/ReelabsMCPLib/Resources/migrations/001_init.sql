-- bookkeeping (schema_migrations is created by Database.swift's migration runner)

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
