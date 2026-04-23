-- moment_features — flat, queryable, sub-span-precise features.
-- Each row is one feature assertion on a moment or a sub-span inside it.
-- Populated incrementally across Plan 2 stages 4, 5a, 5b, 6, 7.

CREATE TABLE moment_features (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    moment_id     INTEGER NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    key           TEXT NOT NULL,
    value_num     REAL,
    value_text    TEXT,
    t_start       REAL,
    t_end         REAL,
    source        TEXT,
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_moment_features_moment ON moment_features(moment_id);
CREATE INDEX idx_moment_features_key_num ON moment_features(key, value_num);
CREATE INDEX idx_moment_features_key_text ON moment_features(key, value_text);
