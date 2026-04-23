-- moment_labels — human judgments on model-generated features and scores.
-- Written by the inspector when William clicks agree/disagree/wrong (Plan 3).

CREATE TABLE moment_labels (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    moment_id     INTEGER NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    field         TEXT NOT NULL,
    model_value   TEXT,
    human_value   TEXT,
    verdict       TEXT NOT NULL CHECK (verdict IN ('agree','disagree','wrong')),
    notes         TEXT,
    labeled_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_moment_labels_moment ON moment_labels(moment_id);
CREATE INDEX idx_moment_labels_field ON moment_labels(field);

-- eval_runs — metric history across commits. One row per metric per suite run.

CREATE TABLE eval_runs (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id       TEXT NOT NULL,
    commit_sha   TEXT,
    suite        TEXT NOT NULL,
    metric       TEXT NOT NULL,
    value        REAL NOT NULL,
    ran_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_eval_runs_ran ON eval_runs(ran_at DESC);
CREATE INDEX idx_eval_runs_suite_metric ON eval_runs(suite, metric, ran_at DESC);

-- golden_moments — hand-labeled ground truth for regression guard.

CREATE TABLE golden_moments (
    moment_id                INTEGER PRIMARY KEY REFERENCES moments(id) ON DELETE CASCADE,
    expected_features_json   TEXT NOT NULL,
    curated_by               TEXT,
    notes                    TEXT,
    curated_at               TEXT NOT NULL DEFAULT (datetime('now'))
);
