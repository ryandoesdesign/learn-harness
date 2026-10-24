"""Database location, read-only opening and record decoding for the standalone skill."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _db

sys.path.insert(0, str(_db.SCRIPTS))
import _data


class DataHelpersTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.folder = self.base / "data"
        self.folder.mkdir()
        self.db = _db.create(self.folder / "aster.sqlite")

    def tearDown(self):
        self.temp.cleanup()

    def record(self, **changes):
        value = {
            "id": "chat_one", "title": "A lesson", "createdAt": "2026-10-01T00:00:00Z",
            "updatedAt": "2026-10-02T00:00:00Z", "messages": [],
        }
        value.update(changes)
        return value

    def save_chat(self, **changes):
        _db.insert_chat(self.db, self.record(**changes))

    def read(self, session_id="chat_one"):
        connection = _data.open_database(self.db)
        try:
            return _data.read_chat(connection, session_id)
        finally:
            connection.close()

    def installed(self, *parts):
        path = self.base.joinpath(*parts)
        path.parent.mkdir(parents=True)
        path.write_bytes(self.db.read_bytes())
        return path

    def test_explicit_existing_database(self):
        self.assertEqual(_data.database_path(str(self.db)), self.db.resolve())

    def test_missing_database_is_not_created(self):
        target = self.base / "not-created" / "aster.sqlite"
        with self.assertRaisesRegex(_data.DataError, "nothing was created"):
            _data.database_path(str(target))
        self.assertFalse(target.parent.exists())

    def test_sandbox_container_is_the_default(self):
        expected = self.installed("Library", "Containers", "com.ryandoesdesign.Aster", "Data", "Library",
                                  "Application Support", "Aster", "aster.sqlite")
        with patch.object(Path, "home", return_value=self.base):
            self.assertEqual(_data.database_path(), expected.resolve())

    def test_unsandboxed_location_is_the_fallback(self):
        expected = self.installed("Library", "Application Support", "Aster", "aster.sqlite")
        with patch.object(Path, "home", return_value=self.base):
            self.assertEqual(_data.database_path(), expected.resolve())

    def test_no_installed_database_requires_explicit_db(self):
        with patch.object(Path, "home", return_value=self.base):
            with self.assertRaisesRegex(_data.DataError, "--db"):
                _data.database_path()
        self.assertFalse((self.base / "Library").exists())

    def test_container_wins_over_unsandboxed_copy(self):
        container = self.installed("Library", "Containers", "com.ryandoesdesign.Aster", "Data", "Library",
                                   "Application Support", "Aster", "aster.sqlite")
        self.installed("Library", "Application Support", "Aster", "aster.sqlite")
        with patch.object(Path, "home", return_value=self.base):
            self.assertEqual(_data.database_path(), container.resolve())

    def test_app_data_privacy_block_suggests_a_copy(self):
        denied = PermissionError(1, "Operation not permitted")
        with patch.object(Path, "open", side_effect=denied):
            with self.assertRaisesRegex(_data.DataError, "App Data privacy") as raised:
                _data.open_database(self.db)
        self.assertIn("-wal and -shm", str(raised.exception))
        self.assertIn("--db", str(raised.exception))
        with patch.object(Path, "home", return_value=self.base), patch.object(Path, "stat", side_effect=denied):
            with self.assertRaisesRegex(_data.DataError, "copy"):
                _data.database_path()

    def test_explicit_database_ignores_the_installed_locations(self):
        with patch.object(Path, "home", return_value=self.base / "nobody"):
            self.assertEqual(_data.database_path(str(self.db)), self.db.resolve())
            with self.assertRaisesRegex(_data.DataError, "--db"):
                _data.database_path()

    def test_folder_and_non_database_files_are_refused(self):
        with self.assertRaisesRegex(_data.DataError, "folder"):
            _data.open_database(self.folder)
        other = self.base / "notes.txt"
        other.write_text("not SQLite", encoding="utf-8")
        with self.assertRaisesRegex(_data.DataError, "not a SQLite database"):
            _data.open_database(other)
        bare = self.base / "bare.sqlite"
        _db.execute(bare, "CREATE TABLE unrelated (x)")
        with self.assertRaisesRegex(_data.DataError, "not a Aster database"):
            _data.open_database(bare)

    def test_unreadable_stored_json_is_an_error_without_writes(self):
        self.save_chat(messages=[{"id": "u", "role": "user", "content": "hello"}])
        _db.execute(self.db, "UPDATE message SET payload_json = '{' WHERE id = 'u'")
        before = _db.snapshot(self.folder)
        with self.assertRaisesRegex(_data.DataError, "unreadable stored JSON"):
            self.read()
        self.assertEqual(_db.snapshot(self.folder), before)

    def test_non_json_constants_are_not_accepted(self):
        with self.assertRaises(_data.DataError):
            _data.parse_json('{"value": NaN}', "test")
        self.assertIsNone(_data.parse_json(None, "test"))

    def test_unstamped_chat_is_read_without_writes(self):
        self.save_chat()
        _db.execute(self.db, "UPDATE chat SET version = NULL")
        before = _db.snapshot(self.folder)
        self.assertEqual(self.read(), self.record())
        self.assertEqual(_db.snapshot(self.folder), before)
        self.assertEqual(sorted(before), ["aster.sqlite"])

    def test_future_chat_version_is_refused(self):
        self.save_chat(version=2)
        with self.assertRaisesRegex(_data.DataError, "Update the skill"):
            self.read()
        _db.execute(self.db, "UPDATE chat SET version = 'one'")
        with self.assertRaisesRegex(_data.DataError, "invalid version"):
            self.read()

    def test_unknown_migration_is_refused(self):
        _db.execute(self.db, "INSERT INTO grdb_migrations (identifier) VALUES ('v99')")
        with self.assertRaisesRegex(_data.DataError, "v99.*Update the skill"):
            _data.open_database(self.db)
        older = _db.create(self.base / "older.sqlite", migrations=["v1"])
        _data.open_database(older).close()

    def test_read_chat_rejects_missing_records(self):
        with self.assertRaisesRegex(_data.DataError, "not found"):
            self.read()

    def test_read_chat_rejects_path_in_place_of_id(self):
        self.save_chat()
        for value in ("../auth", "..", "", "chats/chat_one", "chats\\chat_one"):
            with self.subTest(value=value), self.assertRaises(_data.DataError):
                self.read(value)

    def test_native_rows_read_back_in_record_terms(self):
        self.save_chat(kind="practice", tree={"nodes": []}, settings={"effort": "low"}, messages=[
            {"id": "a", "role": "assistant", "provider": "openrouter", "model": "vendor/model", "stopReason": "toolUse",
             "usage": {"input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0}, "timestamp": 5, "content": [
                 {"type": "thinking", "thinking": "T", "thinkingSignature": "S"},
                 {"type": "thinking", "thinking": "", "thinkingSignature": "R", "redacted": True},
                 {"type": "toolCall", "id": "c", "name": "quiz", "arguments": {"question": "Q"}},
                 {"type": "image", "data": "BASE64", "mimeType": "image/png"}]},
            {"id": "r", "role": "toolResult", "toolCallId": "c", "toolName": "quiz", "isError": False,
             "details": {"kind": "quiz"}, "timestamp": 6, "content": [{"type": "text", "text": "ok"}]},
            {"id": "k", "role": "custom", "customType": "practice-next", "content": "go", "display": False,
             "details": {}, "timestamp": 7},
        ])
        self.assertEqual(self.read(), self.record(kind="practice", tree={"nodes": []}, settings={"effort": "low"}, version=1, messages=[
            {"id": "a", "role": "assistant", "provider": "openrouter", "model": "vendor/model", "stopReason": "toolUse",
             "usage": {"input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0}, "timestamp": 5, "content": [
                 {"type": "thinking", "thinking": "T", "thinkingSignature": "S"},
                 {"type": "thinking", "thinking": "", "thinkingSignature": "R", "redacted": True},
                 {"type": "toolCall", "id": "c", "name": "quiz", "arguments": {"question": "Q"}},
                 {"type": "image", "data": "BASE64", "mimeType": "image/png"}]},
            {"id": "r", "role": "toolResult", "toolCallId": "c", "toolName": "quiz", "isError": False,
             "details": {"kind": "quiz"}, "timestamp": 6, "content": [{"type": "text", "text": "ok"}]},
            {"id": "k", "role": "custom", "customType": "practice-next", "content": "go", "display": False,
             "details": {}, "timestamp": 7},
        ]))

    def test_common_flags_and_unicode_json(self):
        parser = argparse.ArgumentParser()
        _data.add_common_arguments(parser)
        args = parser.parse_args(["--db", str(self.db), "--format", "json"])
        self.assertEqual(args.db, str(self.db))
        self.assertEqual(args.format, "json")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            _data.print_json({"statement": "∇ and café"})
        self.assertIn("∇", out.getvalue())
        self.assertEqual(json.loads(out.getvalue()), {"statement": "∇ and café"})


if __name__ == "__main__":
    unittest.main()
