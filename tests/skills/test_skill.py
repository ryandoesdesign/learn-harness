"""The skill remains a portable folder, not an integration with the app."""

from __future__ import annotations

import ast
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _db

REPO = _db.REPO
SKILL = REPO / "skills" / "aster"
GOLDEN = _db.GOLDEN_DB
snapshot = _db.snapshot
COMMANDS = [
    ("sessions.py", ["list"]),
    ("sessions.py", ["read", "chat_mv27rrra_feff23b6"]),
    ("sessions.py", ["read", "chat_mv293wv5_10656952"]),
    ("sessions.py", ["read", "chat_mv293wv5_10656952", "--include-agent-thinking", "--include-operations"]),
    ("graph.py", ["sessions"]),
    ("graph.py", ["propositions"]),
    ("graph.py", ["find", "*"]),
    ("graph.py", ["chains"]),
    ("graph.py", ["chains", "--node", "n_nonexistent"]),
]

# Holds a write connection open in its own process, as the running app does,
# with automatic checkpoints off so committed rows stay in the -wal file.
APP = """
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("PRAGMA wal_autocheckpoint=0")
connection.execute("INSERT INTO chat (id, title, created_at, updated_at, version) VALUES ('chat_live', 'Only in the WAL', '2026-10-24T00:00:00Z', '2026-10-24T00:00:00Z', 1)")
connection.commit()
print("ready", flush=True)
sys.stdin.read()
"""


class SkillFolderTest(unittest.TestCase):
    def test_portable_frontmatter_and_local_reference(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        frontmatter = text.split("---", 2)[1]
        fields = dict(line.split(": ", 1) for line in frontmatter.strip().splitlines())
        self.assertEqual(fields["name"], SKILL.name)
        self.assertTrue(0 < len(fields["description"]) <= 1024)
        self.assertTrue(0 < len(fields["compatibility"]) <= 500)
        self.assertEqual(fields["license"], "AGPL-3.0-only")
        self.assertLess(len(text.splitlines()), 500)
        self.assertIn("references/data-format.md", text)
        self.assertTrue((SKILL / "references" / "data-format.md").is_file())
        self.assertIn("Never modify Aster's data", text)
        self.assertIn("archival view", text)
        self.assertNotIn("/Users/amos/", text)

    def test_license_is_bundled_for_a_standalone_copy(self):
        self.assertEqual((SKILL / "LICENSE").read_bytes(), (REPO / "LICENSE").read_bytes())
        self.assertIn("GNU AFFERO GENERAL PUBLIC LICENSE", (SKILL / "LICENSE").read_text(encoding="utf-8"))

    def test_python_syntax_supports_declared_minimum(self):
        for script in (SKILL / "scripts").glob("*.py"):
            with self.subTest(script=script.name):
                ast.parse(script.read_text(encoding="utf-8"), filename=str(script), feature_version=(3, 10))

    def test_copied_skill_runs_outside_repository_and_creates_no_cache_or_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            skill = base / "standalone" / "aster"
            data = base / "learning-data"
            elsewhere = base / "unrelated-working-directory"
            elsewhere.mkdir()
            data.mkdir()
            shutil.copytree(SKILL, skill)
            db = data / "aster.sqlite"
            shutil.copy2(GOLDEN, db)
            before_skill = snapshot(skill)
            before_data = snapshot(data)
            env = dict(os.environ)
            env.pop("PYTHONDONTWRITEBYTECODE", None)
            env.pop("PYTHONPATH", None)
            for filename, arguments in COMMANDS:
                for output_format in ("markdown", "json"):
                    with self.subTest(script=filename, arguments=arguments, format=output_format):
                        # Deliberately omit -B here: the entrypoints must disable
                        # bytecode before importing their helper on their own.
                        completed = subprocess.run(
                            [sys.executable, str(skill / "scripts" / filename), "--db", str(db), "--format", output_format, *arguments],
                            cwd=elsewhere, env=env, capture_output=True, text=True, encoding="utf-8", timeout=30,
                        )
                        self.assertEqual(completed.returncode, 0, completed.stderr)
                        self.assertTrue(completed.stdout.strip())
                        if output_format == "json":
                            result = json.loads(completed.stdout)
                            self.assertEqual(result["db"], str(db.resolve()))
                        else:
                            self.assertIn(str(db.resolve()), completed.stdout)
            self.assertEqual(snapshot(skill), before_skill)
            self.assertEqual(snapshot(data), before_data)
            self.assertEqual(list(elsewhere.iterdir()), [])

    def run_all(self, db):
        for filename, arguments in COMMANDS:
            completed = subprocess.run(
                [sys.executable, "-B", str(SKILL / "scripts" / filename), "--db", str(db), "--format", "json", *arguments],
                capture_output=True, text=True, encoding="utf-8", timeout=30,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
        listing = subprocess.run(
            [sys.executable, "-B", str(SKILL / "scripts" / "sessions.py"), "--db", str(db), "--format", "json", "list"],
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        return {item["id"] for item in json.loads(listing.stdout)["sessions"]}

    def test_reads_leave_the_database_and_its_wal_and_shm_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            live, copied = base / "live", base / "copied"
            live.mkdir()
            copied.mkdir()
            db = live / "aster.sqlite"
            shutil.copy2(GOLDEN, db)
            app = subprocess.Popen([sys.executable, "-B", "-c", APP, str(db)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(app.stdout.readline().strip(), "ready")
                for sibling in ("aster.sqlite-wal", "aster.sqlite-shm"):
                    self.assertTrue((live / sibling).is_file(), sibling)
                    shutil.copy2(live / sibling, copied / sibling)
                shutil.copy2(db, copied / db.name)
                # While the app runs: the WAL's rows are visible, nothing changes.
                before = snapshot(live)
                self.assertIn("chat_live", self.run_all(db))
                self.assertEqual(snapshot(live), before)
            finally:
                app.stdin.close()
                app.wait(timeout=30)
                app.stdout.close()
            # A copy taken with its -wal and -shm, no app attached.
            before = snapshot(copied)
            self.assertIn("chat_live", self.run_all(copied / db.name))
            self.assertEqual(snapshot(copied), before)
            # A WAL-mode database without siblings gets none created.
            bare = base / "bare"
            bare.mkdir()
            shutil.copy2(copied / db.name, bare / db.name)
            with sqlite3.connect(bare / db.name) as connection:
                connection.execute("PRAGMA journal_mode=WAL")
            connection.close()
            for sibling in ("aster.sqlite-wal", "aster.sqlite-shm"):
                (bare / sibling).unlink(missing_ok=True)
            before = snapshot(bare)
            self.run_all(bare / db.name)
            self.assertEqual(snapshot(bare), before)
            self.assertEqual(sorted(before), ["aster.sqlite"])


if __name__ == "__main__":
    unittest.main()
