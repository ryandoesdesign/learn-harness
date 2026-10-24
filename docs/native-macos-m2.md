# M2 design: store, importer and Keychain

This adds detail to `native-macos-plan.md`. It covers M2 only.

## Your answers (2026-10-24)
| Question | Answer |
|---|---|
| Steer card invert toggle | Kept in a separate `message_ui(message_id, inverted)` table. `message` rows stay strictly append-only. |
| Job artifacts | Demo HTML and visual SVG go to `artifacts/<jobId>/demo.html` or `visual.svg`. The job result and new steer details carry `artifactPath` instead of the inline string. Imported steer markers keep their inline copy, because payloads are never rewritten. Imported **job rows** do get their artifact moved out to a file. |
| Import folder | You pick the `…/Application Support/LearnHarness` folder (the panel opens there). The importer reads `data/` and `auth.json` inside it. Picking `data/` directly also works; the key step then reports that the key is unavailable. |
| Re-import | Skip existing. Ids already in the DB are never touched, and only new entities are added. Already-imported chats are reported as skipped. |

## Packages
- **GRDB.swift**, pinned `exact: "7.11.1"`.
- **New targets:**
  - `LHStore`, which depends on LHCore and GRDB.
  - `LHImport`, which depends on LHStore and LHCore.
- **Tests:** `LHStoreTests` and `LHImportTests` are added to the scheme's test plan.

## Locations
These are inside the sandbox container.
- The database: `Application Support/LearnHarness/learnharness.sqlite`, a `DatabasePool` in WAL mode with foreign keys on.
- Artifacts: `Application Support/LearnHarness/artifacts/<jobId>/`.
- Tests use a temporary directory.

## Schema (migration `v1`)
| Table | Columns / notes |
|---|---|
| `chat` | id PK, title, kind, created_at, updated_at, settings_json, tree_json, origin (`native` \| `import`), version |
| `message` | chat_id FK (cascade), seq, id, role (`user`/`assistant`/`toolResult`/`marker`), custom_type, tool_call_id, tool_name, model, stop_reason, timestamp, **payload_json** (content blocks, bytes untouched; a marker's model-facing text is stored as a JSON string), **details_json** (toolResult and marker UI payload), usage_json (assistant stamp), error_message, wire_ok. PK is (chat_id, seq), with a UNIQUE index on (chat_id, id). The store only INSERTs. |
| `message_ui` | message_id, chat_id, inverted, updated_at. Read back by layering it over `details.ui`. |
| `message_fts` | FTS5 over each message's searchable text: text blocks, marker content and tool-result text. Kept in sync on insert and delete. |
| `turn` | id PK, chat_id FK, message_id, at, model |
| `extraction_run` | id, owner_kind (`chat` \| `source`), owner_id, started_at, at, duration_ms, stats_json, extractor_model, auditor_model. UNIQUE on (owner_kind, owner_id, started_at). |
| `usage_step` | owner_kind (`turn` \| `extractor` \| `auditor` \| `job`), owner_id, step_index, model, input / output / cache_read / cache_write / reasoning tokens (nullable), web_search_requests, web_fetch_requests, fallback_from |
| `job` | the JobRecord columns, plus result_json and usage_json |
| `steer_outbox` | id, chat_id, message_json, state (`pending` → `handed` → `delivered`), timestamps. The schema only; M6 uses it. |
| `graph_node_line`, `graph_chain_line`, `graph_session`, `coverage` | seq PK, plus line_json exactly as the TS JSONL line, plus indexed id and chat columns. Merged at read time by the LHCore folds, as today. |
| `source` | id PK, file_path, imported_at, content_fp |
| `node_position` | node_id PK, x, y. The ledger's updated_at is in kv. |
| `kv_settings` | key PK, value_json. Keys: `user_settings`, `render_settings`, `positions_updated_at`. |
| `prompt_override` | segment_path PK, body, updated_at |
| `folder_bookmark` | id, path, bookmark blob, created_at. The import source is not persisted, because its access is one-shot. |
| `import_log` | id, started_at, finished_at, source_path, counts_json, warnings_json |

## LHStore API
- `AppDatabase`: opens or creates the database, runs migrations, and provides `inMemory()` for tests.
- **Repositories:**
  - `ChatRepository`:
    - create, get (returns `ChatRecord` with UI state layered in), and list (returns `ChatSummary` via the LHCore folds);
    - `append(messages:)`, saveTree, saveSettings, rename, delete (cascade), appendTurnUsage and appendExtractionUsage (both idempotent);
    - `setArtifactInverted`.
  - `JobRepository`: create, get, update, listJobs, findByToolCallId, deleteForChat, plus artifact file write and read.
  - `GraphRepository`: conforms to `GraphStore` and `PositionsLedgerStore` from LHCore, plus sources, checkpoints and coverage reads.
  - `SettingsRepository`: user_settings through the LHCore sanitizer, and render_settings as raw JSON (the M7 port).
  - `PromptOverrideRepository`: list, read, write, delete. A segment path is valid when it matches the `prompts/**.md` naming. The full segment list comes in M5.
- **Observation:** each repository exposes GRDB `ValueObservation` as `AsyncStream`s (`chatSummaries()`, `chat(id)`). M4 consumes them.
- `KeychainStore` is a protocol:
  - `SystemKeychain` uses SecItem generic passwords, with service `com.ryandoesdesign.LearnHarness` and account `anthropic-api-key`.
  - `InMemoryKeychain` is the test double.
  - One real round-trip test runs in the hosted app tests.
- `BookmarkStore`: create and resolve security-scoped bookmarks, re-create stale ones, and `withAccess(url) { … }`. M2 uses it for the import pick; M6 adds the persisted file-tool folders.
- **Version refusals**, as in TS:
  - a chat stamped newer than v1 is skipped with a warning;
  - `graph/format.json` newer than v1 refuses the graph import.

## LHImport (`LegacyImporter`)
**Input:** the chosen folder. The importer resolves `data/` and `auth.json`. The source is opened read-only and is never written.

**Each entity is imported in its own transaction:**
- **Chats:** `ChatRecord(legacyJSON:)` from M1 creates the row with origin `import`. Turns and extractions go to `turn`, `extraction_run` and `usage_step`.
- **Chat model overrides:** a non-Anthropic override is dropped, so the chat resolves to the Strong slot. The dropped model is reported.
- **Jobs:** a demo's HTML or a visual's SVG is moved out to a file with `artifactPath`. Everything else is copied.
- **Graph ledgers:** loaded line by line, keeping line order and bytes. Unparseable lines are skipped with a warning, as the TS reader does. `sources.json`, `positions.json` and `render-settings.json` are imported too.
- **Settings:** `UserSettings(legacyJSON:)` from M1. Then any non-Anthropic slot or role-override model is dropped, so it resolves to the factory default. `thinkingLevel` becomes effort.
- **Prompt overrides** are copied.

**Key:** if `auth.json` has `ANTHROPIC_API_KEY`, it is written to the Keychain. Other keys are listed by name only (values are never logged) and skipped.

**Report:** counts imported and skipped per entity, plus warnings, written to `import_log` and returned to the UI.

## App (minimal M2 UI)
- A **File → Import from LearnHarness (Electron)…** menu item opens an `NSOpenPanel` at `~/Library/Application Support/LearnHarness`.
- A sheet shows progress and the report.
- After an import, the sidebar lists the imported sessions by title (a plain `List` over the summary observation). Real rendering comes in M4.
- The `com.apple.security.files.user-selected.read-only` entitlement is added.

## Specs ported
- `golden-fixtures`: via the importer over `tests/fixtures/golden-data`.
- `schema-stamps`: the version refusals.
- `settings-store`
- `prompt-overrides`: the store part. Composition is M5.
- `auth-store`: becomes KeychainStore behaviour.
- Plus importer idempotency, read-only source, and per-entity failure isolation.

## Acceptance
- Importing the golden data dir reproduces the TS graph:
  - 298 node lines and 173 chain lines (the real counts, which correct the plan's 282 / 160);
  - the M1 golden `graphSnapshot`;
  - the session index;
  - both chats' messages.
- A re-import adds nothing.
- The source tree is unchanged, byte for byte.
- Importing your real folder puts the key in the Keychain.
- `xcodebuild test` and `swift test` are green.
- Then one commit, and I stop for review.
