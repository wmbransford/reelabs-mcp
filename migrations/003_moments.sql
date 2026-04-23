-- moments — meaningful slices of library_assets.
-- ingest_stage tracks pipeline progress; populated in Plan 2.
-- embedding is a BLOB containing 1024 float32s (Cohere embed-v4), written in Plan 2 stage 8.

CREATE TABLE moments (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    library_asset_id        INTEGER NOT NULL REFERENCES library_assets(id) ON DELETE CASCADE,
    start_s                 REAL NOT NULL,
    end_s                   REAL NOT NULL,
    role                    TEXT CHECK (role IN (
                               'hook','claim','example','story','punchline',
                               'cta','transition','broll','vo_line',
                               'title_card','music_bed'
                            ) OR role IS NULL),
    transcript              TEXT,
    summary                 TEXT,
    scores_json             TEXT,
    dense_features_json     TEXT,
    embedding               BLOB,
    tags                    TEXT,
    ingest_stage            TEXT NOT NULL DEFAULT 'segment' CHECK (ingest_stage IN (
                               'segment','audio_features','visual_deterministic',
                               'visual_semantic','performance','semantic','embed','ready'
                            )),
    ingest_stage_status     TEXT NOT NULL DEFAULT 'pending' CHECK (ingest_stage_status IN (
                               'pending','in_progress','done','error'
                            )),
    ingest_error            TEXT,
    created_at              TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at              TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK (end_s > start_s)
);
CREATE INDEX idx_moments_asset ON moments(library_asset_id);
CREATE INDEX idx_moments_role ON moments(role);
CREATE INDEX idx_moments_stage ON moments(ingest_stage, ingest_stage_status);
CREATE INDEX idx_moments_ready ON moments(ingest_stage) WHERE ingest_stage = 'ready';
