-- timelines — compositions. Source-agnostic edit decisions.
-- hub_brief_id is advisory FK across DBs into hub.db.video_briefs(id).

CREATE TABLE timelines (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT,
    hub_brief_id    INTEGER,
    duration_s      REAL,
    status          TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','locked','rendered','abandoned')),
    notes           TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_timelines_status ON timelines(status);
CREATE INDEX idx_timelines_brief ON timelines(hub_brief_id);

-- timeline_nodes — ordered, layered references into the library.
-- A node may reference a moment (preferred) OR a library_asset directly
-- (for music / graphics used unsliced).

CREATE TABLE timeline_nodes (
    id                            INTEGER PRIMARY KEY AUTOINCREMENT,
    timeline_id                   INTEGER NOT NULL REFERENCES timelines(id) ON DELETE CASCADE,
    track                         TEXT NOT NULL CHECK (track IN (
                                     'primary','overlay','audio','music','captions','graphics'
                                  )),
    track_order                   INTEGER NOT NULL,
    timeline_start_s              REAL NOT NULL,
    moment_id                     INTEGER REFERENCES moments(id) ON DELETE RESTRICT,
    library_asset_id              INTEGER REFERENCES library_assets(id) ON DELETE RESTRICT,
    source_in_s                   REAL,
    source_out_s                  REAL,
    transforms_json               TEXT,
    effects_json                  TEXT,
    selection_provenance_json     TEXT,
    created_at                    TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK (moment_id IS NOT NULL OR library_asset_id IS NOT NULL)
);
CREATE INDEX idx_timeline_nodes_timeline ON timeline_nodes(timeline_id, track, track_order);
CREATE INDEX idx_timeline_nodes_moment ON timeline_nodes(moment_id);
CREATE INDEX idx_timeline_nodes_asset ON timeline_nodes(library_asset_id);
