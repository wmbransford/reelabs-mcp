#!/usr/bin/env python3
"""
verify-parity.py — compare SQLite rows against on-disk markdown/JSON state.

Runs read-only against `{data_root}/reelabs.db` and reports, per row/file:

    OK              values match
    MISSING_IN_DB   file on disk but no matching DB row
    MISSING_ON_DISK DB row but no matching file
    DIFFER          both exist but at least one scalar field differs

Exit 0 if all OK, 1 if any mismatch is reported. Used as a one-shot
pre-deletion check: "can we safely delete the legacy .md files?"

Scope (narrow on purpose):
  - projects   ↔ {project}/project.md frontmatter
  - presets    ↔ presets/{name}.md frontmatter
  - assets     ↔ {project}/{source}.asset.md frontmatter
  - transcripts↔ {project}/{source}.transcript.md + {source}.words.json
                 (word_count + first/last word sanity check; no deep diff)
  - analyses   ↔ {project}/{source}.analysis.md + {source}.scenes.json
                 (scene_count + first/last scene sanity check)
  - renders    ↔ {project}/{slug}.render.md (slug + status + output_path)

Ignored on purpose:
  - timestamp formatting jitter (trailing Z, fractional seconds precision)
  - body whitespace (trailing newline, indentation)
  - fields not listed above
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sqlite3
import sys
from typing import Any


# ----------------------------------------------------------------------
# Frontmatter parsing
# ----------------------------------------------------------------------


def split_frontmatter(text: str) -> tuple[dict[str, Any] | None, str]:
    """Parse a minimal YAML-ish frontmatter block `---\\n...\\n---\\n...`.

    Returns (frontmatter_dict_or_None, body). Only handles the shapes our
    stores produce: top-level scalar keys + flat list values. Falls back to
    None + full text when the shape is unexpected.
    """
    if not text.startswith("---"):
        return None, text
    lines = text.split("\n")
    # Find the closing --- line.
    end = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end = i
            break
    if end is None:
        return None, text

    fm_lines = lines[1:end]
    body = "\n".join(lines[end + 1 :])

    fm: dict[str, Any] = {}
    current_list_key: str | None = None
    i = 0
    while i < len(fm_lines):
        raw = fm_lines[i]
        if not raw.strip():
            current_list_key = None
            i += 1
            continue
        if raw.startswith("- "):
            if current_list_key is None:
                return None, text
            item = raw[2:].strip()
            fm[current_list_key].append(_unquote(item))
            i += 1
            continue
        if ":" not in raw:
            current_list_key = None
            i += 1
            continue
        key, _, value = raw.partition(":")
        key = key.strip()
        value = value.strip()
        # Multi-line quoted scalar: accumulate continuation lines until the
        # closing quote. YAML's default block-folded form for long strings.
        if value.startswith('"') and not _double_quoted_closes(value):
            parts = [value]
            i += 1
            while i < len(fm_lines):
                parts.append(fm_lines[i].strip())
                if _double_quoted_closes(fm_lines[i].strip()):
                    break
                i += 1
            value = " ".join(parts)
        elif value.startswith("'") and not _single_quoted_closes(value):
            parts = [value]
            i += 1
            while i < len(fm_lines):
                parts.append(fm_lines[i].strip())
                if _single_quoted_closes(fm_lines[i].strip()):
                    break
                i += 1
            value = " ".join(parts)
        if value == "":
            fm[key] = []
            current_list_key = key
        else:
            fm[key] = _coerce(value)
            current_list_key = None
        i += 1
    return fm, body


def _double_quoted_closes(s: str) -> bool:
    """True if s ends a double-quoted scalar (closing `"` not preceded by `\\`)."""
    if not s.endswith('"'):
        return False
    if s == '"':
        return False
    backslashes = 0
    for ch in reversed(s[:-1]):
        if ch == "\\":
            backslashes += 1
        else:
            break
    return backslashes % 2 == 0


def _single_quoted_closes(s: str) -> bool:
    """True if s ends a single-quoted scalar (closing `'` not part of an escaped `''`)."""
    if not s.endswith("'") or s == "'":
        return False
    # YAML escapes `'` inside single-quoted strings as `''`; the closing quote
    # is one that isn't followed by another `'` from the right side. Counted
    # from the end: trailing run of `'` of odd length means we're closing.
    run = 0
    for ch in reversed(s):
        if ch == "'":
            run += 1
        else:
            break
    return run % 2 == 1


def _unquote(s: str) -> Any:
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1]
    if s.startswith('"') and s.endswith('"'):
        return _decode_double_quoted(s[1:-1])
    return _coerce(s)


def _decode_double_quoted(s: str) -> str:
    """Decode YAML double-quoted escapes (\\uXXXX, \\\", \\\\, \\n, \\t)."""
    try:
        return s.encode("utf-8").decode("unicode_escape")
    except UnicodeDecodeError:
        return s


def _coerce(s: str) -> Any:
    # Booleans / nulls
    if s in ("true", "True"):
        return True
    if s in ("false", "False"):
        return False
    if s in ("null", "~", ""):
        return None
    # Quoted string
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1]
    if s.startswith('"') and s.endswith('"'):
        return _decode_double_quoted(s[1:-1])
    # Number (handles YAML 1e+01-style scientific notation)
    try:
        if "." in s or "e" in s or "E" in s:
            return float(s)
        return int(s)
    except ValueError:
        return s


# ----------------------------------------------------------------------
# Normalization — strip jitter before comparing
# ----------------------------------------------------------------------


_TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?$")


def norm_ts(v: Any) -> str:
    """Strip sub-second precision + trailing Z so 'jitter' isn't reported."""
    if not isinstance(v, str) or not _TS_RE.match(v):
        return str(v)
    # Keep everything up to the seconds field.
    return v[:19]


def norm_scalar(v: Any) -> Any:
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, (int,)):
        return int(v)
    if isinstance(v, float):
        # Round to 3 decimals — enough to catch real drift, tolerant to YAML float jitter.
        return round(v, 3)
    if isinstance(v, str):
        return v
    return v


# ----------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.ok = 0
        self.issues: list[str] = []

    def record_ok(self) -> None:
        self.ok += 1

    def record(self, kind: str, label: str, detail: str = "") -> None:
        msg = f"[{kind}] {label}"
        if detail:
            msg += f" — {detail}"
        self.issues.append(msg)

    def diff(self, label: str, expected: dict[str, Any], actual: dict[str, Any]) -> None:
        diffs: list[str] = []
        for key in sorted(set(expected) | set(actual)):
            e = norm_scalar(expected.get(key))
            a = norm_scalar(actual.get(key))
            if e != a:
                diffs.append(f"{key}: db={a!r} md={e!r}")
        if diffs:
            self.record("DIFFER", label, "; ".join(diffs))
        else:
            self.record_ok()


# ----------------------------------------------------------------------
# Table-by-table checkers
# ----------------------------------------------------------------------


def check_projects(conn: sqlite3.Connection, root: pathlib.Path, r: Report) -> None:
    rows = {row["slug"]: row for row in conn.execute("SELECT * FROM projects")}
    projects_dir = root / "projects"
    on_disk: dict[str, dict[str, Any]] = {}
    if projects_dir.is_dir():
        for pdir in projects_dir.iterdir():
            if not pdir.is_dir():
                continue
            pm = pdir / "project.md"
            if not pm.is_file():
                continue
            fm, _ = split_frontmatter(pm.read_text())
            if not fm:
                continue
            on_disk[pdir.name] = fm

    for slug, fm in on_disk.items():
        if slug not in rows:
            r.record("MISSING_IN_DB", f"projects/{slug}")
            continue
        db = rows[slug]
        expected = {
            "name": fm.get("name"),
            "status": fm.get("status"),
            "description": fm.get("description"),
            "created": norm_ts(fm.get("created")),
            "updated": norm_ts(fm.get("updated")),
        }
        actual = {
            "name": db["name"],
            "status": db["status"],
            "description": db["description"],
            "created": norm_ts(db["created"]),
            "updated": norm_ts(db["updated"]),
        }
        r.diff(f"projects/{slug}", expected, actual)

    for slug in rows:
        if slug not in on_disk:
            r.record("MISSING_ON_DISK", f"projects/{slug}")


def check_presets(conn: sqlite3.Connection, root: pathlib.Path, r: Report) -> None:
    rows = {row["name"]: row for row in conn.execute("SELECT * FROM presets")}
    presets_dir = root / "presets"
    on_disk: dict[str, dict[str, Any]] = {}
    if presets_dir.is_dir():
        for f in presets_dir.iterdir():
            if f.suffix != ".md":
                continue
            fm, _ = split_frontmatter(f.read_text())
            if not fm:
                continue
            name = fm.get("name") or f.stem
            on_disk[name] = fm

    for name, fm in on_disk.items():
        if name not in rows:
            r.record("MISSING_IN_DB", f"presets/{name}")
            continue
        db = rows[name]
        expected = {
            "type": fm.get("type"),
            "description": fm.get("description"),
        }
        actual = {
            "type": db["type"],
            "description": db["description"],
        }
        r.diff(f"presets/{name}", expected, actual)

    for name in rows:
        if name not in on_disk:
            r.record("MISSING_ON_DISK", f"presets/{name}")


def check_assets(conn: sqlite3.Connection, root: pathlib.Path, r: Report) -> None:
    rows = {
        (row["project_slug"], row["slug"]): row
        for row in conn.execute("SELECT * FROM assets")
    }
    on_disk: dict[tuple[str, str], dict[str, Any]] = {}
    projects_dir = root / "projects"
    if projects_dir.is_dir():
        for pdir in projects_dir.iterdir():
            if not pdir.is_dir():
                continue
            for f in pdir.iterdir():
                if not f.name.endswith(".asset.md"):
                    continue
                fm, _ = split_frontmatter(f.read_text())
                if not fm:
                    continue
                source = fm.get("slug") or f.name.removesuffix(".asset.md")
                on_disk[(pdir.name, source)] = fm

    for (proj, source), fm in on_disk.items():
        key = (proj, source)
        if key not in rows:
            r.record("MISSING_IN_DB", f"assets/{proj}/{source}")
            continue
        db = rows[key]
        expected = {
            "filename": fm.get("filename"),
            "file_path": fm.get("file_path"),
            "file_size_bytes": fm.get("file_size_bytes"),
            "duration_seconds": norm_scalar(fm.get("duration_seconds")),
            "width": fm.get("width"),
            "height": fm.get("height"),
            "fps": norm_scalar(fm.get("fps")),
            "codec": fm.get("codec"),
        }
        actual = {
            "filename": db["filename"],
            "file_path": db["file_path"],
            "file_size_bytes": db["file_size_bytes"],
            "duration_seconds": norm_scalar(db["duration_seconds"]),
            "width": db["width"],
            "height": db["height"],
            "fps": norm_scalar(db["fps"]),
            "codec": db["codec"],
        }
        r.diff(f"assets/{proj}/{source}", expected, actual)

    for (proj, source) in rows:
        if (proj, source) not in on_disk:
            r.record("MISSING_ON_DISK", f"assets/{proj}/{source}")


def check_transcripts(conn: sqlite3.Connection, root: pathlib.Path, r: Report) -> None:
    rows = {
        (row["project_slug"], row["source_slug"]): row
        for row in conn.execute("SELECT * FROM transcripts")
    }
    on_disk: dict[tuple[str, str], tuple[dict[str, Any], list[dict[str, Any]]]] = {}
    projects_dir = root / "projects"
    if projects_dir.is_dir():
        for pdir in projects_dir.iterdir():
            if not pdir.is_dir():
                continue
            for f in pdir.iterdir():
                if not f.name.endswith(".transcript.md"):
                    continue
                fm, _ = split_frontmatter(f.read_text())
                if not fm:
                    continue
                source = fm.get("slug") or f.name.removesuffix(".transcript.md")
                words_file = pdir / f"{source}.words.json"
                words: list[dict[str, Any]] = []
                if words_file.is_file():
                    try:
                        words = json.loads(words_file.read_text())
                    except json.JSONDecodeError:
                        words = []
                on_disk[(pdir.name, source)] = (fm, words)

    for (proj, source), (fm, words) in on_disk.items():
        key = (proj, source)
        if key not in rows:
            r.record("MISSING_IN_DB", f"transcripts/{proj}/{source}")
            continue
        db = rows[key]
        expected = {
            "source_path": fm.get("source_path"),
            "duration_seconds": norm_scalar(fm.get("duration_seconds")),
            "word_count": fm.get("word_count"),
            "language": fm.get("language"),
            "mode": fm.get("mode"),
        }
        actual = {
            "source_path": db["source_path"],
            "duration_seconds": norm_scalar(db["duration_seconds"]),
            "word_count": db["word_count"],
            "language": db["language"],
            "mode": db["mode"],
        }
        r.diff(f"transcripts/{proj}/{source}", expected, actual)

        # Sanity-check the words sidecar: word-count DB row should match on-disk JSON length,
        # and first/last word should match.
        if words:
            db_words = list(
                conn.execute(
                    """SELECT word FROM transcript_words
                       WHERE project_slug = ? AND source_slug = ? ORDER BY word_index""",
                    (proj, source),
                )
            )
            db_word_strs = [row["word"] for row in db_words]
            md_word_strs = [str(w.get("word", "")) for w in words]
            if len(db_word_strs) != len(md_word_strs):
                r.record(
                    "DIFFER",
                    f"transcripts/{proj}/{source}.words",
                    f"db_word_count={len(db_word_strs)} md_word_count={len(md_word_strs)}",
                )
            elif db_word_strs and md_word_strs and (
                db_word_strs[0] != md_word_strs[0] or db_word_strs[-1] != md_word_strs[-1]
            ):
                r.record(
                    "DIFFER",
                    f"transcripts/{proj}/{source}.words",
                    f"first/last differ: db=[{db_word_strs[0]!r},{db_word_strs[-1]!r}] "
                    f"md=[{md_word_strs[0]!r},{md_word_strs[-1]!r}]",
                )

    for (proj, source) in rows:
        if (proj, source) not in on_disk:
            r.record("MISSING_ON_DISK", f"transcripts/{proj}/{source}")


def check_analyses(conn: sqlite3.Connection, root: pathlib.Path, r: Report) -> None:
    rows = {
        (row["project_slug"], row["source_slug"]): row
        for row in conn.execute("SELECT * FROM analyses")
    }
    on_disk: dict[tuple[str, str], tuple[dict[str, Any], list[dict[str, Any]]]] = {}
    projects_dir = root / "projects"
    if projects_dir.is_dir():
        for pdir in projects_dir.iterdir():
            if not pdir.is_dir():
                continue
            for f in pdir.iterdir():
                if not f.name.endswith(".analysis.md"):
                    continue
                fm, _ = split_frontmatter(f.read_text())
                if not fm:
                    continue
                source = fm.get("slug") or f.name.removesuffix(".analysis.md")
                scenes_file = pdir / f"{source}.scenes.json"
                scenes: list[dict[str, Any]] = []
                if scenes_file.is_file():
                    try:
                        scenes = json.loads(scenes_file.read_text())
                    except json.JSONDecodeError:
                        scenes = []
                on_disk[(pdir.name, source)] = (fm, scenes)

    for (proj, source), (fm, scenes) in on_disk.items():
        key = (proj, source)
        if key not in rows:
            r.record("MISSING_IN_DB", f"analyses/{proj}/{source}")
            continue
        db = rows[key]
        expected = {
            "source_path": fm.get("source_path"),
            "status": fm.get("status"),
            "sample_fps": norm_scalar(fm.get("sample_fps")),
            "frame_count": fm.get("frame_count"),
            "scene_count": fm.get("scene_count"),
            "duration_seconds": norm_scalar(fm.get("duration_seconds")),
            "frames_dir": fm.get("frames_dir"),
        }
        actual = {
            "source_path": db["source_path"],
            "status": db["status"],
            "sample_fps": norm_scalar(db["sample_fps"]),
            "frame_count": db["frame_count"],
            "scene_count": db["scene_count"],
            "duration_seconds": norm_scalar(db["duration_seconds"]),
            "frames_dir": db["frames_dir"],
        }
        r.diff(f"analyses/{proj}/{source}", expected, actual)

        if scenes:
            db_scenes = list(
                conn.execute(
                    """SELECT scene_index, description FROM scenes
                       WHERE project_slug = ? AND source_slug = ? ORDER BY scene_index""",
                    (proj, source),
                )
            )
            if len(db_scenes) != len(scenes):
                r.record(
                    "DIFFER",
                    f"analyses/{proj}/{source}.scenes",
                    f"db_scene_count={len(db_scenes)} md_scene_count={len(scenes)}",
                )
            elif db_scenes and scenes:
                first_match = (db_scenes[0]["description"] == scenes[0].get("description"))
                last_match = (db_scenes[-1]["description"] == scenes[-1].get("description"))
                if not (first_match and last_match):
                    r.record(
                        "DIFFER",
                        f"analyses/{proj}/{source}.scenes",
                        "first/last scene description differs",
                    )

    for (proj, source) in rows:
        if (proj, source) not in on_disk:
            r.record("MISSING_ON_DISK", f"analyses/{proj}/{source}")


def check_renders(conn: sqlite3.Connection, root: pathlib.Path, r: Report) -> None:
    rows = {
        (row["project_slug"], row["slug"]): row
        for row in conn.execute("SELECT * FROM renders")
    }
    on_disk: dict[tuple[str, str], dict[str, Any]] = {}
    projects_dir = root / "projects"
    if projects_dir.is_dir():
        for pdir in projects_dir.iterdir():
            if not pdir.is_dir():
                continue
            for f in pdir.iterdir():
                if not f.name.endswith(".render.md"):
                    continue
                fm, _ = split_frontmatter(f.read_text())
                if not fm:
                    continue
                slug = fm.get("slug") or f.name.removesuffix(".render.md")
                on_disk[(pdir.name, slug)] = fm

    for (proj, slug), fm in on_disk.items():
        key = (proj, slug)
        if key not in rows:
            r.record("MISSING_IN_DB", f"renders/{proj}/{slug}")
            continue
        db = rows[key]
        expected = {
            "status": fm.get("status"),
            "output_path": fm.get("output_path"),
            "file_size_bytes": fm.get("file_size_bytes"),
        }
        actual = {
            "status": db["status"],
            "output_path": db["output_path"],
            "file_size_bytes": db["file_size_bytes"],
        }
        r.diff(f"renders/{proj}/{slug}", expected, actual)

    for (proj, slug) in rows:
        if (proj, slug) not in on_disk:
            r.record("MISSING_ON_DISK", f"renders/{proj}/{slug}")


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <data_root>", file=sys.stderr)
        return 2
    root = pathlib.Path(os.path.expanduser(argv[1]))
    db_path = root / "reelabs.db"
    if not db_path.is_file():
        print(f"error: {db_path} does not exist", file=sys.stderr)
        return 2

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    r = Report()
    check_projects(conn, root, r)
    check_presets(conn, root, r)
    check_assets(conn, root, r)
    check_transcripts(conn, root, r)
    check_analyses(conn, root, r)
    check_renders(conn, root, r)

    print(f"OK: {r.ok} rows matched")
    for issue in r.issues:
        print(issue)

    return 0 if not r.issues else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
