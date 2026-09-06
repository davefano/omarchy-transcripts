import concurrent.futures
import argparse
import json
import os
import sqlite3
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import transcripts


CLI = str(Path(__file__).with_name("transcripts.py"))


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.env = dict(os.environ, OMARCHY_TRANSCRIPTS_DIR=self.directory.name + "/store")

    def run_cli(self, *args, text=b"", env=None):
        return subprocess.run([sys.executable, CLI, *args], input=text,
                              capture_output=True, env=env or self.env, timeout=5)

    def listing(self, *args):
        result = self.run_cli("list", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_exact_passthrough_and_source_search(self):
        original = "  Café 東京\n\n$HOME `id` <b>literal</b>\n".encode()
        result = self.run_cli("ingest", "--source", "VoxType", "--passthrough", text=original)
        self.assertEqual(result.stdout, original)
        self.assertEqual(result.returncode, 0)
        row = self.listing("--query", "voxtype")["entries"][0]
        self.assertEqual(row["text"].encode(), original)
        self.assertEqual(self.run_cli("get", str(row["id"])).stdout, original)
        self.assertEqual(self.listing("--query", "東京")["total"], 1)

    def test_no_lost_dictation_when_storage_fails(self):
        occupied = Path(self.directory.name) / "not-a-directory"
        occupied.touch()
        env = dict(self.env, OMARCHY_TRANSCRIPTS_DIR=str(occupied))
        result = self.run_cli("ingest", "--passthrough", text=b"retain this", env=env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"retain this")
        self.assertNotIn(b"retain this", result.stderr)
        self.assertNotEqual(self.run_cli("ingest", text=b"retain this", env=env).returncode, 0)

    def test_pause_trash_restore_export(self):
        self.run_cli("pause")
        self.assertTrue(self.listing()["paused"])
        self.assertEqual(self.run_cli("ingest", "--passthrough", text=b"private").stdout, b"private")
        self.assertEqual(self.listing()["total"], 0)
        self.run_cli("resume")
        self.run_cli("ingest", text=b"saved")
        ident = str(self.listing()["entries"][0]["id"])
        self.run_cli("trash", ident)
        self.assertEqual(self.listing()["total"], 0)
        self.assertEqual(self.listing("--trash")["total"], 1)
        self.assertEqual(json.loads(self.run_cli("export").stdout), [])
        self.run_cli("restore", ident)
        self.assertEqual(self.listing()["total"], 1)
        self.assertEqual(json.loads(self.run_cli("export").stdout)[0]["text"], "saved")

    def test_concurrent_tools_repeated_text_and_pagination(self):
        def add(i):
            return self.run_cli("ingest", "--source", "Tool " + str(i % 2), text=b"same words")
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(add, range(55)))
        self.assertTrue(all(r.returncode == 0 for r in results))
        first = self.listing()
        second = self.listing("--offset", "50")
        self.assertEqual(first["total"], 55)
        self.assertEqual(len(first["entries"]), 50)
        self.assertEqual(len(second["entries"]), 5)
        self.assertEqual(len({r["id"] for r in first["entries"] + second["entries"]}), 55)

    def test_empty_input_and_private_permissions(self):
        self.run_cli("ingest", text=b" \n\t")
        self.assertEqual(self.listing()["total"], 0)
        directory = Path(self.env["OMARCHY_TRANSCRIPTS_DIR"])
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((directory / "history.sqlite3").stat().st_mode & 0o777, 0o600)

    def test_pause_committed_immediately_before_insert_skips_save(self):
        with mock.patch.dict(os.environ, self.env):
            db = transcripts.connect()
            pauser = transcripts.connect()
        self.addCleanup(db.close)
        self.addCleanup(pauser.close)
        transcripts.save(db, "earlier", "Tool")
        wrapped = mock.MagicMock(wraps=db)
        wrapped.__enter__.side_effect = db.__enter__
        wrapped.__exit__.side_effect = db.__exit__

        def execute(sql, params=()):
            if sql.startswith("INSERT INTO transcripts"):
                # Commit Pause at the old check/insert scheduling boundary.
                with pauser:
                    pauser.execute("INSERT OR REPLACE INTO settings VALUES ('paused', 'true')")
            return db.execute(sql, params)

        wrapped.execute.side_effect = execute
        self.assertIsNone(transcripts.save(wrapped, "private", "Tool"))
        self.assertEqual([r[0] for r in db.execute("SELECT text FROM transcripts")], ["earlier"])

    def seed_entries(self, count):
        with mock.patch.dict(os.environ, self.env):
            db = transcripts.connect()
        self.addCleanup(db.close)
        with db:
            db.executemany("INSERT INTO transcripts(created_at, source, text) VALUES (?, ?, ?)",
                           [("2026-09-06T12:00:00+00:00", "Tool", "--help sample " + str(i))
                            for i in range(count)])
        return db

    def test_page_only_preserves_cli_totals_and_literal_search(self):
        self.seed_entries(55)
        first = self.listing("--page-only", "--query=--help")
        self.assertIsNone(first["total"])
        self.assertTrue(first["has_more"])
        self.assertEqual(len(first["entries"]), 50)
        last = self.listing("--page-only", "--query=--help", "--offset", "50")
        self.assertEqual(last["total"], 55)
        self.assertFalse(last["has_more"])
        self.assertEqual(len(last["entries"]), 5)
        self.assertEqual(self.listing("--query=--help")["total"], 55)
        for mode in ([], ["--page-only"]):
            partial = self.listing(*mode, "--offset", "25")
            self.assertEqual((partial["offset"], len(partial["entries"])), (25, 30))

    def test_page_only_avoids_count_and_empty_query_text_scan(self):
        db = self.seed_entries(55)

        def authorize(action, first, second, database, trigger):
            if action == sqlite3.SQLITE_FUNCTION and second in ("count", "lower", "instr"):
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        db.set_authorizer(authorize)
        result = transcripts.snapshot(db, argparse.Namespace(
            query="", trash=False, offset=0, limit=50, page_only=True))
        self.assertTrue(result["has_more"])
        self.assertEqual(len(result["entries"]), 50)

    def test_empty_last_page_clamps_after_trash_and_restore(self):
        self.seed_entries(51)
        last = self.listing("--page-only", "--offset", "50")
        self.assertEqual(self.run_cli("trash", str(last["entries"][0]["id"])).returncode, 0)
        for mode in ([], ["--page-only"]):
            page = self.listing(*mode, "--query=--help", "--offset", "50")
            self.assertEqual((page["offset"], page["total"], len(page["entries"])), (0, 50, 50))
            self.assertFalse(page["has_more"])
        # Move the rest to Trash, then restore the only entry on its last page.
        for row in page["entries"]:
            self.assertEqual(self.run_cli("trash", str(row["id"])).returncode, 0)
        last = self.listing("--trash", "--page-only", "--offset", "50")
        self.assertEqual(self.run_cli("restore", str(last["entries"][0]["id"])).returncode, 0)
        page = self.listing("--trash", "--page-only", "--offset", "50")
        self.assertEqual((page["offset"], page["total"], len(page["entries"])), (0, 50, 50))
        empty = self.listing("--page-only", "--query=missing", "--offset", "100")
        self.assertEqual((empty["offset"], empty["total"], empty["entries"]), (0, 0, []))

    def test_copy_sends_literal_text_over_stdin(self):
        text = b"Quotes ' \" and $(do-not-run)\nsecond line"
        self.run_cli("ingest", text=text)
        ident = str(self.listing()["entries"][0]["id"])
        with mock.patch.dict(os.environ, self.env), \
             mock.patch.object(sys, "argv", [CLI, "copy", ident]), \
             mock.patch("transcripts.subprocess.run") as copy:
            self.assertEqual(transcripts.main(), 0)
        copy.assert_called_once_with(
            ["wl-copy", "--type", "text/plain;charset=utf-8"],
            input=text, check=True, timeout=3,
        )


if __name__ == "__main__":
    unittest.main()
