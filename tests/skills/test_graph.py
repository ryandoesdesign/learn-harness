"""Portable, read-only graph CLI tests over SQLite; no application-store imports."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _db

SCRIPTS = _db.SCRIPTS
sys.path.insert(0, str(SCRIPTS))
import graph

GOLDEN = _db.GOLDEN_DB
# Notices both changed bytes/mtimes and newly created files (e.g. -wal/-shm).
snapshot = _db.snapshot


def point(chat, message=""):
    return {"chatId": chat, "messageId": message}


def node(identifier, session=None, **updates):
    value = {
        "id": identifier, "name": f"Name {identifier}",
        "statement": f"Full statement {identifier}", "aliases": [],
        "createdAt": "2026-01-01T00:00:00Z",
        "provenance": [] if session is None else [point(session)],
    }
    value.update(updates)
    return value


def chain(identifier, premises, conclusion, session, **updates):
    value = {
        "id": identifier, "premises": premises, "conclusion": conclusion,
        "createdAt": "2026-01-02T00:00:00Z", "provenance": [point(session)],
    }
    value.update(updates)
    return value


class GraphTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = _db.create(self.root / "aster.sqlite")

    def write_chat(self, identifier, title, updated, **extra):
        _db.insert_chat(self.db, {"id": identifier, "title": title, "createdAt": "2026-01-01T00:00:00Z",
                                  "updatedAt": updated, "messages": [], **extra})

    def write_source(self, identifier, file_path, imported_at, seq=0):
        _db.execute(self.db, "INSERT INTO source (id, seq, file_path, imported_at) VALUES (?, ?, ?, ?)",
                    (identifier, seq, file_path, imported_at))

    def write_ledger(self, name, records):
        table, key = {"nodes": ("graph_node_line", "node_id"), "chains": ("graph_chain_line", "chain_id")}[name]
        _db.insert_lines(self.db, table, key, records)

    def invoke(self, *arguments, format="json", db=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = graph.main(["--db", str(db or self.db), "--format", format, *arguments])
        return status, out.getvalue(), err.getvalue()

    def result(self, *arguments, db=None):
        status, output, diagnostics = self.invoke(*arguments, db=db)
        self.assertEqual(status, 0, diagnostics)
        self.assertEqual(diagnostics, "")
        payload = json.loads(output)
        self.assertEqual(payload["db"], str((db or self.db).resolve()))
        return payload["records"]

    def fixture(self):
        self.write_ledger("nodes", [
            node("n_b", "chat_old", name="Identity stands", statement="First precise statement", aliases=["Original wording"], provenance=[point("chat_old", "m1")], extra="preserved"),
            node("n_a", "src_notes", name="Café", statement="A separate proposition.", aliases=["Literal [brackets]?", "two\nlines"]),
            node("n_b", "chat_new", name="Name must not replace", statement="Later restatement", aliases=["Original wording", "Another phrasing", ""], createdAt="2099-01-01", provenance=[point("chat_old", "m1"), point("chat_new", "m2"), point("chat_new", "m2")]),
            node("n_empty"),
            node("n_surviving", "chat_new"),
            node("n_unknown", "missing_record"),
        ])
        self.write_ledger("chains", [
            chain("arg_first", ["n_b", "n_a"], "n_surviving", "chat_old", extra="preserved"),
            chain("arg_other_id", ["n_a", "n_b"], "n_surviving", "chat_new", createdAt="2099-01-01"),
            chain("arg_single", ["n_surviving"], "n_a", "src_notes"),
            chain("arg_dangling", ["n_missing"], "n_a", "chat_old"),
        ])
        for identifier, title, updated in [
            ("chat_old", "Old conversation", "2026-02-01T00:00:00Z"),
            ("chat_new", "Recent conversation", "2026-03-01T00:00:00Z"),
            ("chat_without_nodes", "Not a birth session", "2099-01-01"),
        ]:
            self.write_chat(identifier, title, updated)
        self.write_source("src_notes", "/never/open/these notes.md", "2026-02-15T00:00:00Z")

    def test_merge_nodes_first_identity_and_union(self):
        self.fixture()
        before = snapshot(self.root)
        merged = self.result("propositions")
        self.assertEqual([item["id"] for item in merged], ["n_a", "n_b", "n_empty", "n_surviving", "n_unknown"])
        value = next(item for item in merged if item["id"] == "n_b")
        self.assertEqual(value["name"], "Identity stands")
        self.assertEqual(value["statement"], "First precise statement")
        self.assertEqual(value["createdAt"], "2026-01-01T00:00:00Z")
        self.assertEqual(value["aliases"], ["Original wording", "Later restatement", "Another phrasing"])
        self.assertEqual(value["provenance"], [point("chat_old", "m1"), point("chat_new", "m2")])
        self.assertEqual(value["extra"], "preserved")
        self.assertEqual(snapshot(self.root), before)

    def test_chain_key_identity_provenance_and_endpoint_filter(self):
        self.fixture()
        merged = self.result("chains")
        self.assertEqual([item["id"] for item in merged], ["arg_first", "arg_single", "arg_dangling"])
        self.assertEqual(merged[0]["premises"], ["n_b", "n_a"])
        self.assertEqual(merged[0]["createdAt"], "2026-01-02T00:00:00Z")
        self.assertEqual(merged[0]["extra"], "preserved")
        self.assertEqual(merged[0]["provenance"], [point("chat_old"), point("chat_new")])
        self.assertEqual(self.result("chains", "--node", "n_b"), merged[:1])
        self.assertEqual(len(self.result("chains", "--node", "n_a")), 3)
        self.assertEqual(self.result("chains", "--node", "no-such-node"), [])

    def test_birth_index_metadata_and_filter(self):
        self.fixture()
        sessions = self.result("sessions")
        self.assertEqual([item["id"] for item in sessions], ["chat_new", "src_notes", "chat_old", "missing_record"])
        self.assertEqual([item["propositions"] for item in sessions], [1, 1, 1, 1])
        self.assertEqual(sessions[0]["kind"], "chat")
        self.assertEqual(sessions[0]["name"], "Recent conversation")
        self.assertEqual(sessions[1]["name"], "/never/open/these notes.md")
        self.assertEqual(sessions[-1], {"id": "missing_record", "name": "missing_record", "kind": "file", "createdAt": None, "updatedAt": None, "propositions": 1})
        self.assertEqual([item["id"] for item in self.result("propositions", "--session", "chat_new")], ["n_surviving"])
        self.assertEqual([item["id"] for item in self.result("propositions", "--session", "chat_old")], ["n_b"])
        self.assertEqual(self.result("propositions", "--session", "nonexistent"), [])

    def test_future_chat_metadata_is_isolated_and_diagnosed(self):
        self.fixture()
        _db.execute(self.db, "UPDATE chat SET version = 2 WHERE id = 'chat_old'")
        self.write_chat("chat_future", "Future metadata", "2026-01-01", version=3)
        before = snapshot(self.root)
        for arguments, format in [(("sessions",), "json"), (("propositions",), "markdown")]:
            with self.subTest(arguments=arguments):
                status, output, diagnostics = self.invoke(*arguments, format=format)
                self.assertEqual(status, 0, diagnostics)
                for name in ("chat chat_old", "chat chat_future"):
                    self.assertIn(name, diagnostics)
                for reason in ("format 2", "format 3", "skipped"):
                    self.assertIn(reason, diagnostics)
                if format == "json":
                    sessions = {item["id"]: item for item in json.loads(output)["records"]}
                    self.assertEqual(sessions["chat_old"]["name"], "chat_old")
                    self.assertIsNone(sessions["chat_old"]["createdAt"])
                    self.assertEqual(sessions["chat_new"]["name"], "Recent conversation")
                    self.assertEqual(sessions["src_notes"]["name"], "/never/open/these notes.md")
                else:
                    self.assertIn("First precise statement", output)
                    self.assertIn("Recent conversation", output)
                    self.assertIn("/never/open/these notes.md", output)
        self.assertEqual(snapshot(self.root), before)

    def test_explicit_empty_query_and_ids_rejected_but_whitespace_accepted(self):
        for arguments in (("find", ""), ("propositions", "--session", ""), ("chains", "--node", "")):
            with self.subTest(arguments=arguments):
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    with self.assertRaises(SystemExit) as raised:
                        graph.main(["--db", str(self.db), *arguments])
                self.assertEqual(raised.exception.code, 2)
                self.assertEqual(out.getvalue(), "")
                self.assertIn("must not be empty", err.getvalue())
        for arguments in (("find", " "), ("propositions", "--session", " "), ("chains", "--node", " ")):
            self.assertEqual(self.result(*arguments), [])
        self.assertEqual(list(self.root.iterdir()), [self.db])

    def test_empty_first_provenance_acquires_birth_from_surviving_link(self):
        self.write_ledger("nodes", [node("n_x"), node("n_x", "survivor")])
        self.assertEqual([item["id"] for item in self.result("propositions", "--session", "survivor")], ["n_x"])
        self.assertEqual(self.result("sessions")[0]["id"], "survivor")

    def test_session_order_timestamp_ties_then_stable_id(self):
        self.write_ledger("nodes", [node("n_b", "b"), node("n_a", "a"), node("n_c", "c")])
        self.assertEqual([item["id"] for item in self.result("sessions")], ["a", "b", "c"])

    def test_find_matches_names_statements_aliases_and_literal_punctuation(self):
        self.fixture()
        for query in ("IDENTITY", "precise", "later RESTATEMENT", "another phrasing"):
            self.assertEqual([item["id"] for item in self.result("find", query)], ["n_b"])
        self.assertEqual([item["id"] for item in self.result("find", "[brackets]?")], ["n_a"])
        self.assertEqual([item["id"] for item in self.result("find", "Café")], ["n_a"])
        self.assertEqual(self.result("find", "n_b"), [])  # IDs are not searchable fields.
        self.assertEqual(self.result("find", "Name must not replace"), [])
        self.assertEqual(self.result("find", " no such text "), [])

    def test_find_case_matching_agrees_with_app_js_regex(self):
        self.write_ledger("nodes", [node("n_case", name="Exact label", statement="Exact statement", aliases=["K", "ſ", "ı", "İ", "ς", "𐐨", "Café"])])
        for query in ("k", "s", "i", "𐐀"):
            # Explicit stars avoid unrelated substring matches in the name.
            self.assertEqual(self.result("find", query + "*"), [], query)
        for query in ("K*", "ſ*", "ı*", "İ*", "σ*", "𐐨*", "CAFÉ*"):
            self.assertEqual([item["id"] for item in self.result("find", query)], ["n_case"], query)

    def test_find_star_glob_newlines_and_ledger_order(self):
        self.fixture()
        self.assertEqual([item["id"] for item in self.result("find", "*statement*")], ["n_b", "n_empty", "n_surviving", "n_unknown"])
        self.assertEqual([item["id"] for item in self.result("find", "two*lines")], ["n_a"])
        self.assertEqual(self.result("find", "precise*"), [])
        self.assertEqual(len(self.result("find", "*")), 5)

    def test_empty_ledgers_empty_graph_and_no_file_creation(self):
        for command in ("sessions", "propositions", "chains"):
            self.assertEqual(self.result(command), [])
        self.assertEqual(self.result("find", "anything"), [])
        self.assertEqual(list(self.root.iterdir()), [self.db])
        status, output, diagnostics = self.invoke("propositions", format="markdown")
        self.assertEqual(status, 0, diagnostics)
        self.assertIn("No matching records", output)
        self.assertEqual(list(self.root.iterdir()), [self.db])

    def test_malformed_and_wrong_shape_rows_warn_instead_of_silent_loss(self):
        self.write_ledger("nodes", [node("n_ok", "source"), '{"torn":', '{"id":"bad"}', "null"])
        self.write_ledger("chains", [chain("arg_bad", [], "n_ok", "source")])
        before = snapshot(self.root)
        status, output, diagnostics = self.invoke("propositions")
        self.assertEqual(status, 0)
        self.assertEqual([item["id"] for item in json.loads(output)["records"]], ["n_ok"])
        self.assertIn("graph_node_line seq 2: malformed JSON", diagnostics)
        self.assertIn("graph_node_line seq 3: invalid record shape", diagnostics)
        self.assertIn("graph_node_line seq 4: invalid record shape", diagnostics)
        self.assertIn("graph_chain_line seq 1: invalid record shape", diagnostics)
        self.assertIn("incomplete", diagnostics)
        self.assertEqual(snapshot(self.root), before)

    def test_unknown_migration_refuses_without_partial_output_or_writes(self):
        self.fixture()
        _db.execute(self.db, "INSERT INTO grdb_migrations (identifier) VALUES ('v4')")
        before = snapshot(self.root)
        for command in ("sessions", "propositions", "chains"):
            status, output, diagnostics = self.invoke(command)
            self.assertNotEqual(status, 0)
            self.assertEqual(output, "")
            self.assertIn("v4", diagnostics)
            self.assertIn("Update the skill", diagnostics)
        self.assertEqual(snapshot(self.root), before)

    def test_known_older_migrations_work_and_non_databases_refuse(self):
        older = _db.create(self.root / "older.sqlite", migrations=["v1", "v2"])
        self.assertEqual(self.result("propositions", db=older), [])
        torn = self.root / "torn.sqlite"
        torn.write_text("{torn", encoding="utf-8")
        status, output, diagnostics = self.invoke("propositions", db=torn)
        self.assertNotEqual(status, 0)
        self.assertEqual(output, "")
        self.assertIn("torn.sqlite", diagnostics)

    def test_source_paths_are_only_references_and_markdown_is_full_text(self):
        self.fixture()
        before = snapshot(self.root)
        status, output, diagnostics = self.invoke("propositions", format="markdown")
        self.assertEqual(status, 0, diagnostics)
        for text in ("First precise statement", "Original wording", "Later restatement", "Another phrasing", "chat_old", "m1", "Recent conversation", "Café", "/never/open/these notes.md"):
            self.assertIn(text, output)
        self.assertIn(f"Database: {self.db.resolve()}", output)
        self.assertIn("not mastery or guaranteed truth", output)
        status, output, diagnostics = self.invoke("chains", "--node", "n_a", format="markdown")
        self.assertEqual(status, 0, diagnostics)
        self.assertIn("First precise statement", output)
        self.assertIn("missing proposition", output)
        self.assertEqual(snapshot(self.root), before)

    def test_cli_db_option_order_missing_db_and_no_bytecode(self):
        env = dict(os.environ)
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        before = snapshot(self.root)
        caches_before = set(SCRIPTS.rglob("*.pyc"))
        command = [sys.executable, str(SCRIPTS / "graph.py")]
        completed = subprocess.run([*command, "--db", str(self.db), "--format", "json", "sessions"], env=env, capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), {"db": str(self.db.resolve()), "records": []})  # Never falls back to an installed database.
        bad = subprocess.run([*command, "sessions", "--db", str(self.db)], env=env, capture_output=True, text=True, check=False)
        self.assertNotEqual(bad.returncode, 0)
        absent = subprocess.run([*command, "--db", str(self.root / "missing.sqlite"), "sessions"], env=env, capture_output=True, text=True, check=False)
        self.assertNotEqual(absent.returncode, 0)
        self.assertEqual(absent.stdout, "")
        self.assertEqual(snapshot(self.root), before)
        self.assertEqual(set(SCRIPTS.rglob("*.pyc")), caches_before)

    def test_golden_data_read_only_broad_graph(self):
        before = snapshot(GOLDEN.parent)
        nodes = self.result("propositions", db=GOLDEN)
        chains = self.result("chains", db=GOLDEN)
        sessions = self.result("sessions", db=GOLDEN)
        self.assertGreaterEqual(len(nodes), 250)
        self.assertGreaterEqual(len(chains), 150)
        self.assertEqual(len({item["id"] for item in nodes}), len(nodes))
        self.assertEqual(sum(item["propositions"] for item in sessions), sum(bool(item["provenance"]) for item in nodes))
        for session in sessions:
            born = self.result("propositions", "--session", session["id"], db=GOLDEN)
            self.assertEqual(len(born), session["propositions"])
            self.assertTrue(all(item["provenance"][0]["chatId"] == session["id"] for item in born))
        self.assertTrue(any(item["kind"] == "file" for item in sessions))
        # Golden chats are not the original graph birth sessions; their
        # missing historical metadata must remain honestly undated.
        self.assertTrue(any(item["createdAt"] is None for item in sessions))
        self.assertEqual(snapshot(GOLDEN.parent), before)


if __name__ == "__main__":
    unittest.main()
