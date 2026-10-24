# LearnHarness data: a field reference

The database is the user's record, not an import format to rewrite. Work read-only.
The bundled readers make common views convenient; they are not required for custom
analysis. This reference describes the native app's SQLite database at the schema
migrations `v1`, `v2` and `v3`. A database stamped with any other migration is
refused rather than guessed.

## The database

One SQLite file, `learnharness.sqlite`, in WAL mode while the app runs (it then has
`-wal` and `-shm` siblings holding recent commits). The readers open it through a
`file:…?mode=ro` URI: with a `-wal` present the shared-memory file is opened
read-only too (`readonly_shm=1`), and without one the file is opened `immutable=1`
so SQLite creates no siblings. For your own queries, open it the same way, e.g.
`sqlite3.connect("file:/path/learnharness.sqlite?mode=ro&readonly_shm=1", uri=True)`,
and never run `PRAGMA`s that write, `VACUUM`, checkpoints or schema statements.

`grdb_migrations` lists the applied schema migrations (`identifier`). The tables
the skill reads:

```text
chat               One row per session
message            Every session message, one row each, ordered by (chat_id, seq)
graph_node_line    Proposition ledger: one JSON line per row, append order = seq
graph_chain_line   Reasoning-chain ledger: one JSON line per row, append order = seq
source             Imported-note source metadata
```

Other tables are not learning evidence and the readers do not show them:
`message_ui` (a display toggle for artifact cards), `turn`, `usage_step`,
`extraction_run` (usage/cost observation), `job`, `steer_outbox` (background
work and delivery bookkeeping), `graph_session` (extraction checkpoints, **not**
the session index), `coverage` (extraction fingerprints, **not** learner
assessment), `node_position` (canvas layout), `kv_settings`, `prompt_override`,
`folder_bookmark`, `import_log`, and the `message_fts` search index. API keys are
in the macOS Keychain, not in the database. Imported-note paths, research URLs, and
artifact references are not automatically followed by the readers.

## A session record

`chat` columns:

| Column | Meaning |
| --- | --- |
| `id`, `title` | Stable session identity and user-visible name |
| `created_at`, `updated_at` | ISO date strings for the session, not a date for every idea |
| `kind` | `teach` or `practice`; NULL means `teach` |
| `version` | Record format stamp (1); NULL means 1. Newer is refused |
| `tree_json` | Optional session plan: nodes, prerequisite edges, revision number |
| `settings_json` | Per-session model/effort overrides, not an understanding assessment |
| `origin` | `native` or `import` (from the older app); not learning evidence |

The plan is session scaffolding, not the persistent knowledge graph. Its visited
or current positions are not proof of mastery. Context compaction changes what the
teaching model sees; it does **not** mean earlier messages were deleted from this
stored history.

### Messages and content blocks

`message` columns: `chat_id`, `seq` (order), `id` (application message ID),
`role`, `timestamp` (Unix milliseconds), `payload_json` (the content), and per role
`custom_type`, `tool_call_id`, `tool_name`, `is_error`, `details_json`, `display`,
`model`, `stop_reason`, `usage_json`, `error_message`. Stored roles are:

- `user`: learner prose; `payload_json` is an array of `text`/`image` blocks.
- `assistant`: an array of `text`, `thinking`, `redacted_thinking` and `tool_use`
  blocks (Anthropic's shapes). `thinking` here is **agent reasoning**, not learner
  thinking.
- `toolResult`: result of a call, identified by `tool_call_id` and `tool_name`.
  `payload_json` is often only a compact model-facing summary; `details_json` can be richer.
- `marker`: an application event identified by `custom_type`; `payload_json` is a
  JSON **string** (its model-facing text). Some contain irreplaceable learner work
  or teaching artifacts, so do not discard this role.

The readers print messages in the older app's vocabulary, which the rest of this
reference uses: `marker` → role `custom` with `customType`; `tool_use{id,name,input}`
→ `toolCall{id,name,arguments}`; `thinking{thinking,signature}` →
`thinking{thinking,thinkingSignature}`; `redacted_thinking{data}` → `thinking` with
`redacted: true`; `image{source:{type:"base64",media_type,data}}` →
`image{mimeType,data}` (the base64 data is never printed); `tool_call_id` →
`toolCallId`, `is_error` → `isError`, `details_json` → `details`. On assistant
messages, `model` (`provider:id`, or a bare Anthropic id) becomes `provider` and
`model`, and `stop_reason` becomes `stopReason` (`stop`, `length`, `toolUse`, or the
stored value). Other block types are shown as stored, as unsupported content.

An assistant tool call, as the readers print it, has roughly this shape:

```json
{
  "type": "toolCall",
  "id": "call_EXAMPLE",
  "name": "probe",
  "arguments": {
    "question": "Which claim follows?",
    "options": [{"label": "A claim", "value": "claim"}],
    "correctAnswer": "claim",
    "explanation": "The teacher's explanation."
  }
}
```

This is an illustrative fragment, not a valid complete question fixture. Tool
arguments are authored by the teacher; correct answers, explanations, and practice
solutions can already be stored before the learner answers. A call without a
learner-result message may be pending or interrupted; never invent an answer.
An `isError: true` result means the call failed, not that its contents were
successfully posed or taught.

Some historical fields contain JSON encoded inside a string where an array/object
was intended. If inspecting them, decode in memory only and keep the original
record unchanged. Do not evaluate text as code. Historical LaTeX escaping mistakes
can also be present in the source; a readable transcript is not a data-repair pass.

### Questions and answers: where the evidence actually lives

Question tools include `ask_user_question`, `probe`, `quiz`, `recall`, and `explain`.
Probe/quiz are multiple-choice checks; recall/explain use a teacher-committed answer
and the learner's own words. Ask questions clarify goals/preferences and are not
graded quizzes. Older records can use older tool names or lack newer type fields.

A question's learner response is a separate `toolResult` message. Prefer its
**`details`** payload: `content[*].text` deliberately omits material already in
the call, including some question/options/solution fields. The reader deduplicates
that compact content only after verifying it adds nothing to the full snapshot.
Extra or conflicting content is retained as a separately attributed source, not
silently reconciled; `--include-operations` also restores verified duplicates.

Important answer-detail fields:

| Field | Meaning |
| --- | --- |
| `kind` | `quiz`, `ask`, or `explain` |
| `tool`, `questionType` | Optional tool/role snapshots; a quiz can be `predict` or `check` |
| `questionText`, `options` | Question and displayed-option snapshots |
| `answers` | Selected `{label, value, index}` tuples; index is 1-based **display order** |
| `text`, `other` | Free-text response or ask's Other answer |
| `dontKnow`, `dismissed` | Explicit don't-know or skipped state |
| `thinking` | Learner reasoning about the question |
| `note` | Legacy name for that same channel; use `thinking ?? note` |
| `readingThinking` | Separate learner thinking while reading the teaching |
| `confidence` | Self-reported 0–100 probability that the selected quiz answer is correct |
| `correct`, `correctIndices` | Mechanical quiz grading in displayed-option order |
| `committed`, `explanation` | Teacher's committed answer / quiz explanation, not learner speech |
| `answeredAt` | ISO answer timestamp |

**Options are shuffled.** Never apply a learner's display index to the raw call's
authored option order. Use the answer snapshot and its label/value tuples. Missing
confidence is not zero, and no confidence is sent for don't-know. The slider's 50%
resting value is a real recorded 50%, but the record cannot tell whether it was
left untouched or chosen deliberately.

Retain incorrect responses, failed attempts, skipped questions, and don't-know;
they are evidence, not noise to clean up. Do not invent a numeric grade for a
recall/explain response: the teacher's subsequent prose is its interpretation.

### Practice and custom markers

| `customType` | Interpretation |
| --- | --- |
| `practice-thinking` | **Learner-authored work**, including intermediate attempts and claimed answers; raw text is `details.text`, associated through `details.problemCallId` |
| `graph-context` | Picked propositions/chains supplied as session context; app-injected, not learner speech |
| `plan-block` | Historical plan presentation snapshot in `details.block` |
| `subagent-steer` | Delivered teaching artifact; `details.kind` and `details.result` identify the payload |
| `subagent-abort` | Background work was aborted; no result should be invented |
| `probe-handoff` | Probe-to-teach transition |
| `practice-next` | Learner moved on to another problem |
| `problem-dismissed` | Learner skipped a practice problem; points to its problem call |
| `compaction` | Context-management bookkeeping, not a learner statement or replacement for history |

The practice `problem` tool holds the statement, target proposition IDs, and
precommitted `modelSolution`. There may be many `practice-thinking` submissions for
one problem. `conclude` carries the teacher's outcome/verdict; a dismissal can be
recorded before its synthetic conclude pair appears. Preserve the sequence rather
than treating only the last submission as the learner's work.

Call IDs may repeat in older records. When joining, associate a result with the
nearest matching **preceding** call; a whole-session last-wins map can attach it
to a later call. Message IDs distinguish occurrences. Neither source order nor
learner attribution should be reconstructed from model-compacted context.

### Delivered artifacts

`subagent-steer.details.result` contains the stored artifact:

- Research: `brief`, plus `sources` containing titles/URLs.
- PDF reading: `path`, `question`, `brief`, `pagesRead`, `pagesConsulted`.
  These page lists are citations/audit information, not the original document.
- Demo: `title`, `notes`, and executable `html`.
- Visual: `notes` and `svg` markup.

Readable briefs and notes belong to the learning record. Demo HTML and SVG are
artifacts to describe, not commands to execute while reading. Binary/image blocks
can be large; their existence should be noted without dumping encoded bytes. No
reader needs to open the original PDF or notes file merely to read these records.

## The graph: assertions must be merged, not counted as unique lines

The ledgers keep each assertion as its original JSON line (`line_json`), byte for
byte, with `seq` giving append order. Read them in `seq` order and merge.

### Propositions (`graph_node_line`)

Each line contains `id`, `name`, `statement`, `aliases`, `createdAt`, and
`provenance`—an array of `{chatId, messageId}` points.

- A short `name` is a display label, **not** a unique identity or full claim.
- The **first line for an ID** defines its name, statement, and creation date.
- Later lines' nonempty statements and aliases join the aliases with exact-string
  deduplication. Later names do not replace the name or become aliases.
- Provenance unions by exact `(chatId, messageId)` pair, retaining encounter order.
- Do not deduplicate different node IDs just because their labels look alike.

### Reasoning chains (`graph_chain_line`)

Each line contains `id`, `premises` (node IDs), `conclusion` (node ID), `createdAt`,
and `provenance`. **All premises within a chain are used together.** Different
chains with the same conclusion are separate arguments, not one pooled premise
set. Merge repeated assertions by the sorted premise list plus conclusion, keeping
the first assertion's ID, premise order, and date; union provenance.

The graph canvas derives arrows and implication junctions from these records.
Those visual edges are not the stored truth and can lose the joint-premise
structure. Read chains directly. Missing endpoints are reported as missing, not
silently substituted or repaired.

### Sources, birth sessions, and provenance

A node's **birth source** is `provenance[0].chatId` after merging—the first surviving
point, not the earliest timestamp and not every session that mentioned it.
Graph session listings and `propositions --session` use this rule. A node with no
provenance remains readable/searchable but belongs to no birth session.

- `chat_…` IDs usually refer to `chat` rows. Use the matching `messageId` when
  present to find the exact source message (`message.id`). Empty message IDs in
  older data are chat-level attribution; they do not identify an exact message.
- Imported notes use `src_…` source IDs. The `source` table supplies `id`,
  `file_path`, and `imported_at`; these source paths are references only.
- Missing/deleted source metadata can leave a valid graph. The session index then
  uses the source ID as its label and `file` as its fallback kind; this fallback
  alone does not prove the source was an imported file.
- Chat deletion and chain simplification can rewrite ledgers. They are normally
  appended during extraction, but do not assume the ledgers are immutable logs.

`graph_session` records extraction checkpoints, and `coverage` records
fingerprints of extracted teacher text. Neither is a session catalog, quiz-event
ledger, mastery scale, or record of every idea the learner personally endorsed.
Practice does not itself write new propositions to the graph.

## Reader limits

The readers intentionally stop short of analysis: no inferred mastery, scoring,
semantic search, transitive traversal, or automatic report generation. Their JSON
output can be processed further, or you can query the database read-only yourself.

Malformed/unsupported records must be identified, not silently counted as valid.
The app may commit while a reader runs, so a run's separate queries are not one
atomic snapshot. Re-read or quit the app for a stable comparison. Never introduce locks,
migrations, cleanup, or writes to make a read succeed.
