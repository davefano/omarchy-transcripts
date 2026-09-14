"""Exercise installation with real files and an isolated home; stub shell IPC."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
PLUGIN_ID = "io.github.davefano.transcripts"


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home with spaces"
        self.home.mkdir()
        self.source = Path(self.tmp.name) / "source"
        self.source.mkdir()
        for name in ("manifest.json", "Transcripts.qml", "README.md", "LICENSE",
                     "install.sh", "transcripts.py"):
            shutil.copy2(ROOT / name, self.source / name)
        self.plugins = self.home / ".config/omarchy/plugins"
        self.target = self.plugins / PLUGIN_ID
        self.legacy = self.plugins / "local.transcripts"
        self.launcher = self.home / ".local/bin/omarchy-transcripts"
        self.log = Path(self.tmp.name) / "commands"
        binaries = Path(self.tmp.name) / "bin"
        binaries.mkdir()
        for name in ("omarchy", "omarchy-shell"):
            script = binaries / name
            script.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$TEST_LOG"\n'
                              'if [[ -n "${TEST_FAIL_COMMAND:-}" && "$*" == "$TEST_FAIL_COMMAND"* ]]; then exit 7; fi\n'
                              'if [[ "$*" == "plugin validate "* ]]; then\n'
                              '  python3 -m json.tool "$3/manifest.json" >/dev/null\n'
                              'fi\n')
            script.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / ".config"),
                        PATH=str(binaries) + os.pathsep + os.environ["PATH"], TEST_LOG=str(self.log))

    def install(self, *args, source=None):
        return subprocess.run(["bash", str((source or self.source) / "install.sh"), *args],
                              env=self.env, capture_output=True, text=True)

    def legacy_install(self):
        self.legacy.mkdir(parents=True)
        (self.legacy / "manifest.json").write_text(json.dumps({"id": "local.transcripts"}))
        (self.legacy / "transcripts.py").write_text("legacy collector")
        self.launcher.parent.mkdir(parents=True)
        self.launcher.symlink_to(self.legacy / "transcripts.py")
        history = self.home / ".local/share/omarchy-transcripts/history.sqlite3"
        history.parent.mkdir(parents=True)
        history.write_bytes(b"history must stay intact")
        return history

    def test_fresh_install_and_repeat(self):
        for _ in range(2):
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.launcher.resolve(), self.target / "transcripts.py")
        self.assertEqual(json.loads((self.target / "manifest.json").read_text())["id"], PLUGIN_ID)
        self.assertTrue((self.target / "install.sh").exists())
        self.assertEqual(self.log.read_text().splitlines(), [
            f"plugin validate {self.source}",
            "shell rescanPlugins",
            f"plugin enable {PLUGIN_ID} --section right --before omarchy.audio",
        ] * 2)

    def test_marketplace_cli_setup_keeps_git_checkout_and_bar_placement(self):
        shutil.copytree(self.source, self.target)
        (self.target / ".git").mkdir()
        (self.target / ".git/marker").write_text("keep")
        result = self.install("--cli-only", source=self.target)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.launcher.resolve(), self.target / "transcripts.py")
        self.assertEqual((self.target / ".git/marker").read_text(), "keep")
        self.assertNotIn("plugin enable", self.log.read_text())

    def test_migration_requires_opt_in_and_preserves_history(self):
        history = self.legacy_install()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.launcher.resolve(), self.legacy / "transcripts.py")
        result = self.install("--migrate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.launcher.resolve(), self.target / "transcripts.py")
        self.assertIn("plugin disable local.transcripts", self.log.read_text())
        self.assertEqual(history.read_bytes(), b"history must stay intact")
        self.assertEqual((self.legacy / "transcripts.py").read_text(), "legacy collector")

    def test_marketplace_migration_preserves_checkout_placement_and_history(self):
        history = self.legacy_install()
        shutil.copytree(self.source, self.target)
        (self.target / ".git").mkdir()
        (self.target / ".git/marker").write_text("keep")
        result = self.install("--cli-only", "--migrate", source=self.target)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.launcher.resolve(), self.target / "transcripts.py")
        self.assertEqual((self.target / ".git/marker").read_text(), "keep")
        self.assertEqual(history.read_bytes(), b"history must stay intact")
        self.assertEqual(self.log.read_text().splitlines(), [
            f"plugin validate {self.target}", "plugin disable local.transcripts",
        ])

    def test_dangling_legacy_launcher_explains_migration(self):
        self.legacy_install()
        shutil.rmtree(self.legacy)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Use --migrate", result.stderr)
        self.assertEqual(self.launcher.readlink(), self.legacy / "transcripts.py")
        result = self.install("--migrate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.launcher.resolve(), self.target / "transcripts.py")
        self.assertNotIn("plugin disable", self.log.read_text())

    def test_validation_failure_stops_before_installing(self):
        self.env["TEST_FAIL_COMMAND"] = "plugin validate"
        result = self.install()
        self.assertEqual(result.returncode, 7)
        self.assertFalse(self.target.exists())
        self.assertFalse(self.launcher.is_symlink())

    def test_enable_failure_preserves_legacy_plugin_and_history(self):
        history = self.legacy_install()
        self.env["TEST_FAIL_COMMAND"] = "plugin enable"
        result = self.install("--migrate")
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("plugin disable", self.log.read_text())
        self.assertEqual(history.read_bytes(), b"history must stay intact")
        self.assertEqual((self.legacy / "transcripts.py").read_text(), "legacy collector")
        self.assertEqual(self.launcher.resolve(), self.target / "transcripts.py")

    def test_unrelated_launcher_is_never_replaced(self):
        self.launcher.parent.mkdir(parents=True)
        self.launcher.write_text("unrelated command")
        result = self.install("--migrate")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.launcher.read_text(), "unrelated command")
        self.assertFalse(self.target.exists())

    def test_external_install_refuses_to_overwrite_git_managed_plugin(self):
        self.target.mkdir(parents=True)
        (self.target / ".git").mkdir()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.target / "transcripts.py").exists())


if __name__ == "__main__":
    unittest.main()
