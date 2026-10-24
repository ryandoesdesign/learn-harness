"""Synthetic Aster databases for the skill tests.

`tests/fixtures/schema.sql` is the app's migrated schema (drift-tested by
SkillFixtureTests in LHImportTests). `insert_chat` writes a session given in
the TS record's terms as native rows, mirroring LHCore's
LegacyRecordConversion and LHStore's MessageRow, so a test can state
records the way the skill prints them.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import sys

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "skills" / "aster" / "scripts"
FIXTURES = REPO / "tests" / "fixtures"
SCHEMA = FIXTURES / "schema.sql"
GOLDEN_DB = FIXTURES / "golden-data.sqlite"
GOLDEN_JSON = FIXTURES / "golden-data"


def create(path: Path, *, migrations: list[str] | None = None) -> Path:
    """A fresh database with the app's schema (and its migration stamps)."""
    connection = sqlite3.connect(path)
    try:
        connection.executescript(SCHEMA.read_text(encoding="utf-8"))
        if migrations is not None:
            connection.execute("DELETE FROM grdb_migrations")
            connection.executemany("INSERT INTO grdb_migrations (identifier) VALUES (?)", [(m,) for m in migrations])
        connection.commit()
    finally:
        connection.close()
    return path


def snapshot(folder: Path) -> dict[str, tuple[str, int] | None]:
    """Bytes and mtimes of everything under a folder, including new files."""
    return {
        path.relative_to(folder).as_posix(): (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
        if path.is_file() else None
        for path in folder.rglob("*")
    }


def _native_block(block):
    if not isinstance(block, dict):
        return block
    kind = block.get("type")
    if kind == "toolCall":
        out = {"type": "tool_use", "id": block.get("id"), "name": block.get("name"), "input": block.get("arguments", {})}
        out.update({k: v for k, v in block.items() if k not in {"type", "id", "name", "arguments"}})
        return out
    if kind == "thinking":
        if block.get("redacted"):
            return {"type": "redacted_thinking", "data": block.get("thinkingSignature")}
        out = {"type": "thinking", "thinking": block.get("thinking", "")}
        if "thinkingSignature" in block:
            out["signature"] = block["thinkingSignature"]
        out.update({k: v for k, v in block.items() if k not in {"type", "thinking", "thinkingSignature"}})
        return out
    if kind == "image" and "data" in block:
        out = {"type": "image", "source": {"type": "base64", "media_type": block.get("mimeType", ""), "data": block["data"]}}
        out.update({k: v for k, v in block.items() if k not in {"type", "data", "mimeType"}})
        return out
    return block


def _blocks(content):
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [_native_block(block) for block in content]
    return content


def _dump(value):
    return None if value is None else json.dumps(value, ensure_ascii=False)


STOP = {"stop": "end_turn", "length": "max_tokens", "toolUse": "tool_use"}


def message_row(message: dict, chat_id: str, seq: int) -> dict:
    role = message.get("role")
    row = {"chat_id": chat_id, "seq": seq, "id": message.get("id", f"m{seq}"), "role": role,
           "timestamp": message.get("timestamp", 0), "custom_type": None, "tool_call_id": None,
           "tool_name": None, "model": None, "stop_reason": None, "details_json": None,
           "usage_json": None, "error_message": None, "is_error": None, "display": None}
    if role == "user":
        row["payload_json"] = _dump(_blocks(message.get("content")))
    elif role == "assistant":
        row["payload_json"] = _dump(_blocks(message.get("content")))
        if "model" in message:
            provider = message.get("provider", "anthropic")
            row["model"] = message["model"] if provider == "anthropic" else f"{provider}:{message['model']}"
        stop = message.get("stopReason")
        row["stop_reason"] = STOP.get(stop, stop) if stop is not None else "end_turn"
        row["usage_json"] = _dump(message.get("usage"))
        row["error_message"] = message.get("errorMessage")
    elif role == "toolResult":
        row.update(payload_json=_dump(_blocks(message.get("content"))), tool_call_id=message.get("toolCallId"),
                   tool_name=message.get("toolName"), is_error=bool(message.get("isError", False)),
                   details_json=_dump(message.get("details")))
    elif role == "custom":
        content = message.get("content", "")
        if isinstance(content, list):
            content = "".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
        row.update(role="marker", payload_json=_dump(content), custom_type=message.get("customType"),
                   display=bool(message.get("display", True)), details_json=_dump(message.get("details")))
    else:
        row["payload_json"] = _dump(message.get("content"))
        row["details_json"] = _dump(message.get("details"))
    return row


def insert_chat(path: Path, record: dict) -> None:
    """Insert a TS-shaped session record as native chat/message rows."""
    connection = sqlite3.connect(path)
    try:
        connection.execute(
            "INSERT INTO chat (id, title, kind, created_at, updated_at, settings_json, tree_json, origin, version) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 'native', ?)",
            (record["id"], record["title"], record.get("kind"), record["createdAt"], record["updatedAt"],
             _dump(record.get("settings")), _dump(record.get("tree")), record.get("version", 1)))
        for seq, message in enumerate(record.get("messages", [])):
            row = message_row(message, record["id"], seq)
            columns = ", ".join(row)
            connection.execute(f"INSERT INTO message ({columns}) VALUES ({', '.join('?' * len(row))})", tuple(row.values()))
        connection.commit()
    finally:
        connection.close()


def execute(path: Path, sql: str, parameters=()) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute(sql, parameters)
        connection.commit()
    finally:
        connection.close()


def insert_lines(path: Path, table: str, key: str, lines: list) -> None:
    """Append ledger rows; dicts are serialized, strings stored verbatim."""
    connection = sqlite3.connect(path)
    try:
        for line in lines:
            text = line if isinstance(line, str) else json.dumps(line, ensure_ascii=False)
            identifier = line.get("id", "") if isinstance(line, dict) else ""
            connection.execute(f"INSERT INTO {table} ({key}, line_json) VALUES (?, ?)", (identifier, text))
        connection.commit()
    finally:
        connection.close()
