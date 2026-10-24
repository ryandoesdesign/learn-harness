"""Small read-only SQLite helpers for the LearnHarness skill.

No application imports, discovery scans, migrations, caches, or writes. The
database is opened read-only through sqlite3 URIs; imported-note paths and
artifact references are data, not instructions to open another file.
"""

from __future__ import annotations

import argparse
import errno
import json
from pathlib import Path
import sqlite3
import sys
from typing import Any

sys.dont_write_bytecode = True

DB_NAME = "learnharness.sqlite"
BUNDLE_ID = "com.ryandoesdesign.LearnHarness"
# GRDB migration identifiers this reader understands (LHStore AppDatabase).
KNOWN_MIGRATIONS = ("v1", "v2", "v3")
SQLITE_HEADER = b"SQLite format 3\x00"
# The native chat record version (LHCore CURRENT_CHAT_VERSION).
SUPPORTED_CHAT_VERSION = 1


class DataError(Exception):
    """An actionable reader error, suitable for stderr without a traceback."""


def container_database() -> Path:
    """The sandboxed app's database inside its container."""
    return (Path.home() / "Library" / "Containers" / BUNDLE_ID / "Data" / "Library"
            / "Application Support" / "LearnHarness" / DB_NAME)


def unsandboxed_database() -> Path:
    """The database of an unsandboxed (development) build."""
    return Path.home() / "Library" / "Application Support" / "LearnHarness" / DB_NAME


def _privacy_error(path: Path) -> DataError:
    return DataError(
        f"macOS blocked reading {path} (App Data privacy protects other apps' containers). "
        f"Copy {path.name} together with its -wal and -shm files, if present, to a folder this "
        "terminal can read (for example with Finder), then pass that copy with --db PATH. "
        "Nothing was written."
    )


def _exists(path: Path) -> bool:
    try:
        path.stat()
    except FileNotFoundError:
        return False
    except PermissionError as exc:
        raise _privacy_error(path) from exc
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENOTDIR):
            return False
        raise DataError(f"Cannot inspect {path}: {exc}") from exc
    return True


def database_path(override: str | None = None) -> Path:
    """Resolve an explicit database or the installed app's location.

    The sandbox container comes first, then an unsandboxed build's location.
    Never create a missing file or folder. For a copy, pass --db.
    """
    if override is not None:
        path = Path(override).expanduser()
        try:
            path = path.resolve()
        except (OSError, RuntimeError, ValueError) as exc:
            raise DataError(f"Cannot resolve the database path: {exc}") from exc
        if not _exists(path):
            raise DataError(f"Database not found: {path}. Check --db; nothing was created.")
        return path
    candidates = [container_database(), unsandboxed_database()]
    for candidate in candidates:
        if _exists(candidate):
            return candidate.resolve()
    raise DataError(
        "LearnHarness database not found at " + " or ".join(str(c) for c in candidates)
        + ". Use --db PATH for another copy; nothing was created."
    )


def open_database(path: Path) -> sqlite3.Connection:
    """Open read-only and refuse a database with unknown migrations.

    With a -wal file present (the app is running, or a copy carries one), the
    shared-memory file is opened read-only too, so neither sibling changes.
    Without one, the file is opened immutable so SQLite creates no -wal/-shm.
    """
    try:
        with path.open("rb") as handle:
            header = handle.read(len(SQLITE_HEADER))
    except PermissionError as exc:
        raise _privacy_error(path) from exc
    except IsADirectoryError as exc:
        raise DataError(f"{path} is a folder; pass the {DB_NAME} file itself with --db.") from exc
    except OSError as exc:
        raise DataError(f"Cannot read {path}: {exc}") from exc
    if header != SQLITE_HEADER:
        raise DataError(f"{path} is not a SQLite database.")
    wal = path.with_name(path.name + "-wal")
    params = "mode=ro&readonly_shm=1" if _exists(wal) else "mode=ro&immutable=1"
    try:
        connection = sqlite3.connect(f"{path.as_uri()}?{params}", uri=True)
    except sqlite3.Error as exc:
        raise _sqlite_error(path, exc) from exc
    try:
        connection.execute("PRAGMA query_only = ON")
        try:
            migrations = [row[0] for row in connection.execute("SELECT identifier FROM grdb_migrations")]
        except sqlite3.OperationalError as exc:
            if "no such table" in str(exc):
                raise DataError(f"{path} is not a LearnHarness database (no migration table).") from exc
            raise
        unknown = [identifier for identifier in migrations if identifier not in KNOWN_MIGRATIONS]
        if unknown:
            raise DataError(
                f"{path} has database migrations this skill does not know ({', '.join(map(str, unknown))}); "
                f"it supports {', '.join(KNOWN_MIGRATIONS)}. Update the skill; nothing was migrated."
            )
        if "v1" not in migrations:
            raise DataError(f"{path} is not a LearnHarness database (its schema was never created).")
    except sqlite3.Error as exc:
        connection.close()
        raise _sqlite_error(path, exc) from exc
    except DataError:
        connection.close()
        raise
    return connection


def _sqlite_error(path: Path, exc: sqlite3.Error) -> DataError:
    if "authorization denied" in str(exc).lower() or getattr(exc, "sqlite_errorname", "") == "SQLITE_AUTH":
        return _privacy_error(path)
    return DataError(f"Cannot read the database {path}: {exc}")


def parse_json(text: Any, where: str) -> Any:
    """Parse a stored JSON column; NULL stays None."""
    if text is None:
        return None
    try:
        return json.loads(text, parse_constant=_reject_constant)
    except (TypeError, ValueError) as exc:
        raise DataError(f"{where}: unreadable stored JSON ({exc}).") from exc


def _reject_constant(value: str) -> None:
    raise ValueError(f"Non-JSON numeric constant: {value}")


def _flag(value: Any, default: bool) -> bool:
    return default if value is None else bool(value)


def _stop_reason(value: str | None) -> str:
    """Anthropic stop_reason back to the TS record's words."""
    return {"end_turn": "stop", "max_tokens": "length", "tool_use": "toolUse"}.get(value or "end_turn", value or "stop")


def legacy_block(block: Any) -> Any:
    """A native (Anthropic) content block back in the TS record's terms."""
    if not isinstance(block, dict):
        return block
    kind = block.get("type")
    if kind == "tool_use":
        result = {"type": "toolCall", "id": block.get("id"), "name": block.get("name"), "arguments": block.get("input", {})}
        result.update({k: v for k, v in block.items() if k not in {"type", "id", "name", "input"}})
        return result
    if kind == "thinking":
        result = {"type": "thinking", "thinking": block.get("thinking", "")}
        if "signature" in block:
            result["thinkingSignature"] = block["signature"]
        result.update({k: v for k, v in block.items() if k not in {"type", "thinking", "signature"}})
        return result
    if kind == "redacted_thinking":
        return {"type": "thinking", "thinking": "", "thinkingSignature": block.get("data"), "redacted": True}
    source = block.get("source")
    if kind == "image" and isinstance(source, dict) and source.get("type") == "base64":
        result = {"type": "image", "data": source.get("data"), "mimeType": source.get("media_type")}
        result.update({k: v for k, v in block.items() if k not in {"type", "source"}})
        return result
    return block


def _blocks(payload: Any) -> Any:
    return [legacy_block(block) for block in payload] if isinstance(payload, list) else payload


def legacy_message(row: sqlite3.Row, where: str) -> dict[str, Any]:
    """One `message` row as the TS record's message.

    Native-only columns (stop details, wire flag) and the separate invert
    table are not surfaced.
    """
    payload = parse_json(row["payload_json"], where)
    details = parse_json(row["details_json"], where)
    role = row["role"]
    message: dict[str, Any] = {"id": row["id"]}
    if role == "user":
        message.update(role="user", content=_blocks(payload))
    elif role == "assistant":
        message.update(role="assistant", content=_blocks(payload))
        model = row["model"]
        if model:
            # Bare ids are Anthropic's; imported foreign models keep "provider:id".
            provider, separator, bare = model.partition(":")
            if separator:
                message.update(provider=provider, model=bare)
            else:
                message.update(provider="anthropic", model=model)
        usage = parse_json(row["usage_json"], where)
        if usage is not None:
            message["usage"] = usage
        message["stopReason"] = _stop_reason(row["stop_reason"])
        if row["error_message"] is not None:
            message["errorMessage"] = row["error_message"]
    elif role == "toolResult":
        message.update(role="toolResult", toolCallId=row["tool_call_id"], toolName=row["tool_name"], content=_blocks(payload))
        if details is not None:
            message["details"] = details
        message["isError"] = _flag(row["is_error"], False)
    elif role == "marker":
        message.update(role="custom", customType=row["custom_type"], content=payload, display=_flag(row["display"], True))
        if details is not None:
            message["details"] = details
    else:
        message.update(role=role, content=payload)
        if details is not None:
            message["details"] = details
    message["timestamp"] = row["timestamp"]
    return message


def _valid_session_id(session_id: str) -> bool:
    return bool(session_id) and session_id not in {".", ".."} and not any(char in session_id for char in ("/", "\\", "\x00"))


def check_chat_version(session_id: str, version: Any) -> None:
    if version is None:
        return
    if isinstance(version, bool) or not isinstance(version, (int, float)):
        raise DataError(f"Session {session_id} has an invalid version; this reader supports native format {SUPPORTED_CHAT_VERSION}.")
    if version > SUPPORTED_CHAT_VERSION:
        raise DataError(f"Session {session_id} uses format {version}; this reader supports {SUPPORTED_CHAT_VERSION}. Update the skill; no migration was attempted.")


def read_chat(connection: sqlite3.Connection, session_id: str) -> dict[str, Any]:
    """Read one session as the TS-shaped record; refuse unsupported versions."""
    if not _valid_session_id(session_id):
        raise DataError("Use a session ID from sessions.py list, not a filesystem path.")
    connection.row_factory = sqlite3.Row
    try:
        chat = connection.execute(
            "SELECT id, title, kind, created_at, updated_at, settings_json, tree_json, version FROM chat WHERE id = ?",
            (session_id,)).fetchone()
        if chat is None:
            raise DataError(f"Session not found: {session_id}.")
        check_chat_version(session_id, chat["version"])
        record: dict[str, Any] = {"id": chat["id"], "title": chat["title"]}
        if chat["kind"] is not None:
            record["kind"] = chat["kind"]
        record.update(createdAt=chat["created_at"], updatedAt=chat["updated_at"])
        if chat["version"] is not None:
            record["version"] = chat["version"]
        settings = parse_json(chat["settings_json"], f"Session {session_id} settings")
        if settings is not None:
            record["settings"] = settings
        tree = parse_json(chat["tree_json"], f"Session {session_id} plan tree")
        if tree is not None:
            record["tree"] = tree
        rows = connection.execute(
            "SELECT * FROM message WHERE chat_id = ? ORDER BY seq", (session_id,)).fetchall()
        record["messages"] = [legacy_message(row, f"Session {session_id}, message {row['seq']}") for row in rows]
    except sqlite3.Error as exc:
        raise DataError(f"Cannot read session {session_id}: {exc}") from exc
    finally:
        connection.row_factory = None
    return record


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    """Common CLI options precede the subcommand, as shown in SKILL.md."""
    parser.add_argument("--db", metavar="PATH", help=f"LearnHarness database ({DB_NAME}); default: the installed app's")
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown", help="Output format (default: markdown)")


def print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False))
