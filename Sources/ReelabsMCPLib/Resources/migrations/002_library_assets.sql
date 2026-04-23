-- library_assets — the spine's universal source registry.
-- Distinct from the existing `assets` table (which is project-scoped captured media).
-- This table holds every source (captured or generated) the composition brain shops in.

CREATE TABLE library_assets (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    kind                   TEXT NOT NULL CHECK (kind IN (
                              'captured_video','captured_audio',
                              'tts_audio','ai_video','ai_image',
                              'graphic_spec','stock_video','stock_image',
                              'music','screen_recording'
                           )),
    path                   TEXT,
    external_ref           TEXT,
    content_hash           TEXT,
    duration_s             REAL,
    width                  INTEGER,
    height                 INTEGER,
    fps                    REAL,
    codec                  TEXT,
    has_audio              INTEGER,
    provenance_json        TEXT,
    source_metadata_json   TEXT,
    created_at             TEXT NOT NULL DEFAULT (datetime('now')),
    ingested_at            TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK (path IS NOT NULL OR external_ref IS NOT NULL)
);
CREATE INDEX idx_library_assets_kind ON library_assets(kind);
CREATE INDEX idx_library_assets_hash ON library_assets(content_hash) WHERE content_hash IS NOT NULL;
CREATE INDEX idx_library_assets_created ON library_assets(created_at DESC);
