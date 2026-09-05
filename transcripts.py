#!/usr/bin/env python3
"""Shared transcript store and stdin adapter. Python standard library only."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


def connect():
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    directory = Path(os.environ.get("OMARCHY_TRANSCRIPTS_DIR", base / "omarchy-transcripts"))
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    db = directory / "history.sqlite3"
    connection = sqlite3.connect(db, timeout=1.0)
    db.chmod(0o600)
    connection.row_factory = sqlite3.Row
    connection.executescript("""
        CREATE TABLE IF NOT EXISTS transcripts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            source TEXT NOT NULL,
            text TEXT NOT NULL,
            trashed INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS transcripts_visible ON transcripts(trashed, id DESC);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """)
    return connection


def is_paused(db):
    row = db.execute("SELECT value FROM settings WHERE key = 'paused'").fetchone()
    return row is not None and row[0] == "true"


def save(db, text, source):
    if not text.strip() or is_paused(db):
        return None
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    with db:
        cursor = db.execute(
            "INSERT INTO transcripts(created_at, source, text) VALUES (?, ?, ?)",
            (now, source, text),
        )
    return cursor.lastrowid


def ingest(args):
    # Preserve exact bytes, including Unicode, whitespace and trailing newlines.
    raw = sys.stdin.buffer.read()
    error = None
    try:
        with connect() as db:
            save(db, raw.decode("utf-8"), args.source)
    except (OSError, sqlite3.Error, UnicodeError) as exc:
        error = exc
    # Storage failure must never eat a dictation in a post-processing pipeline.
    if args.passthrough:
        sys.stdout.buffer.write(raw)
        sys.stdout.buffer.flush()
    if error:
        print("Transcripts: could not save transcript (" + type(error).__name__ + ").", file=sys.stderr)
        return 0 if args.passthrough else 1
    return 0


def snapshot(db, args):
    where = "trashed = ? AND (instr(lower(text), lower(?)) > 0 OR instr(lower(source), lower(?)) > 0)"
    params = (int(args.trash), args.query, args.query)
    rows = db.execute(
        "SELECT * FROM transcripts WHERE " + where + " ORDER BY id DESC LIMIT ? OFFSET ?",
        (*params, args.limit, args.offset),
    ).fetchall()
    total = db.execute("SELECT count(*) FROM transcripts WHERE " + where, params).fetchone()[0]
    return {"entries": [dict(row) for row in rows], "total": total,
            "paused": is_paused(db), "offset": args.offset}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("ingest", help="Save UTF-8 text from stdin")
    add.add_argument("--source", default="Unknown")
    add.add_argument("--passthrough", action="store_true", help="Echo exact input, even if saving fails")
    listing = commands.add_parser("list", help="Search history as JSON")
    listing.add_argument("--query", default="")
    listing.add_argument("--limit", type=int, default=50)
    listing.add_argument("--offset", type=int, default=0)
    listing.add_argument("--trash", action="store_true")
    for name in ("get", "copy", "trash", "restore"):
        item = commands.add_parser(name)
        item.add_argument("id", type=int)
    commands.add_parser("pause")
    commands.add_parser("resume")
    commands.add_parser("capture-clipboard", help="Explicitly save clipboard text once")
    commands.add_parser("export", help="Write all non-trashed entries as JSON to stdout")
    commands.add_parser("open", help="Open the Omarchy panel")
    args = parser.parse_args()
    if args.command == "ingest":
        return ingest(args)
    if args.command == "open":
        return subprocess.call(["omarchy-shell", "shell", "summon", "local.transcripts"])
    try:
        with connect() as db:
            if args.command == "list":
                args.limit = max(1, min(args.limit, 100))
                args.offset = max(0, args.offset)
                print(json.dumps(snapshot(db, args), ensure_ascii=False))
            elif args.command in ("pause", "resume"):
                db.execute("INSERT OR REPLACE INTO settings VALUES ('paused', ?)",
                           ("true" if args.command == "pause" else "false",))
            elif args.command in ("trash", "restore"):
                db.execute("UPDATE transcripts SET trashed = ? WHERE id = ?",
                           (int(args.command == "trash"), args.id))
            elif args.command in ("copy", "get"):
                row = db.execute("SELECT text FROM transcripts WHERE id = ?", (args.id,)).fetchone()
                if row is None:
                    raise ValueError("Transcript no longer exists")
                if args.command == "copy":
                    subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"],
                                   input=row[0].encode("utf-8"), check=True, timeout=3)
                else:
                    sys.stdout.write(row[0])
            elif args.command == "capture-clipboard":
                if is_paused(db):
                    raise ValueError("History is paused; resume before saving")
                result = subprocess.run(["wl-paste", "--no-newline", "--type", "text"],
                                        capture_output=True, check=True, timeout=3)
                if save(db, result.stdout.decode("utf-8"), "Clipboard (manual)") is None:
                    raise ValueError("Clipboard has no text")
            elif args.command == "export":
                rows = db.execute("SELECT * FROM transcripts WHERE trashed = 0 ORDER BY id").fetchall()
                print(json.dumps([dict(row) for row in rows], ensure_ascii=False, indent=2))
        return 0
    except (OSError, sqlite3.Error, UnicodeError, subprocess.SubprocessError, ValueError) as exc:
        # Never include transcript contents in diagnostics.
        print("Transcripts: operation failed (" + type(exc).__name__ + ").", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
