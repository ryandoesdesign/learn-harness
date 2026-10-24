# Native macOS rewrite of LearnHarness (Swift 6 / SwiftUI / macOS 27)

## Context
You want a fully native macOS 27 app in place of the Next.js + Electron + TypeScript stack. The TS app (~27k LOC UI, ~25k LOC engine, 139 test files) stays in the repo as the reference implementation. The native app is a separate product inside it.

All decisions below are yours:

| Decision | Choice |
|---|---|
| Location | `macos/` in this repo |
| Storage | new SQLite via **GRDB**, with a one-time importer from the old data dir |
| Providers | **Anthropic only**, through a **hand-written** URLSession client |
| Research | Anthropic `web_search`/`web_fetch` server tools |
| Web views | WKWebView only where unavoidable: KaTeX, Mermaid, demos, SVG snapshot |
| PDF | PDFKit |
| Dictation | Apple on-device SpeechAnalyzer |
| Packages | liberal, pinned to exact versions |
| Look | native macOS 27, follows system light/dark |
| Distribution | local Xcode build, Apple Development cert, no updater |
| Sandbox | **App Sandbox on**: security-scoped bookmarks back the allowed folders |
| Key storage | **Keychain** |
| Bundle ID | `com.ryandoesdesign.LearnHarness` |
| Agent Skill | Python scripts rewritten to read the new DB |
| Delivery | milestones, with review between each |

## Architecture
```
macos/
  LearnHarness.xcodeproj      thin app target: entitlements, Info.plist
  LearnHarness/               SwiftUI app (MainActor, @Observable view models)
  Packages/LHKit/             one local package, library targets:
    LHCore       pure domain ports of src/core (Foundation + CryptoKit only)
    LHAnthropic  Messages API client (SSE streaming)
    LHStore      GRDB schema/migrations/repositories, KeychainStore, BookmarkStore
    LHImport     legacy data-dir importer
    LHAgent      agent loop, tools, agents, sub-agents, JobRunner, WakePipeline, extraction
    LHWeb        WKWebView islands + headless demo verifier / SVG snapshot
    LHResources  prompts/**.md, katex/, mermaid/, models.json
```
- **Dependency direction:**
  - `LHCore ← LHAnthropic ← LHAgent → LHStore ← LHImport`
  - `LHWeb` depends on `LHCore` only. `LHAgent` reaches it through a `HeadlessVerifier` protocol, so it can be tested without WebKit.
- **Concurrency (Swift 6 strict):**
  - **Database:** one `DatabasePool` in WAL mode. The UI reads through GRDB `ValueObservation` streams, which replace the SSE notify→fetch loop.
  - **Turns:** a `TurnCoordinator` actor holds one `SessionEngine` actor per chat. Only one turn runs per chat at a time. The engine owns the live loop, the steering queue and abort, and publishes `AsyncStream<AgentEvent>` for live deltas.
  - **Background work:** `JobRunner`, `WakePipeline`, `ExtractionScheduler` (a semaphore of 3, ported from `bg-llm-semaphore.ts`) and `CompactionService`, each an actor.
- **Packages (pinned exact):**
  - GRDB.swift 7.x
  - swift-markdown (Apple), feeding an in-house SwiftUI block renderer that owns math, mermaid and streaming
  - Highlightr for code
  - swift-collections
  - KaTeX 0.18.2 and mermaid 11.x JS bundled locally (no CDN)
  - Force layout ported directly from `src/core/layout.ts`: Barnes-Hut with SIMD and a seeded RNG
- **Prompts:**
  - `src/agent/prompts/**` is reused verbatim as bundled resources, with the same ordering and override rules, ported from `prompt-segments.ts`. Tool names and schemas stay identical because the prompts reference them.
  - The inline sub-agent prompts (researcher, demo builder, visual maker, PDF reader, extractor, auditor, compaction) move into markdown resources. The researcher prompt is rewritten for the server tools.

## Database schema (migration v1)
| Table | Columns / notes |
|---|---|
| `chat` | id, title, kind, timestamps, settings_json, tree_json, origin, version |
| `message` | id, chat_id, seq, role, custom_type, tool_call_id, tool_name, model, stop_reason, timestamp, **payload_json** (raw content blocks, bytes untouched), wire_ok. **Append-only.** |
| `message_fts` | FTS5 index for sidebar search and find |
| `usage_step` | owner_kind/id, model, input/output/cache_read/cache_write/reasoning tokens, web_search/web_fetch request counts, fallback_from. Dollars are computed at read time from `models.json`. |
| `job` | job state; artifacts stored as files under `Application Support/LearnHarness/artifacts/<jobId>/` |
| `steer_outbox` | delivery state: pending → handed → delivered, guaranteeing exactly-once |
| `graph_node_line`, `graph_chain_line` | append-only ledger lines, merged at read time as today |
| `coverage`, `graph_session`, `source`, `node_position` | graph bookkeeping |
| `kv_settings` | settings and render settings |
| `prompt_override`, `folder_bookmark`, `import_log` | |

## Anthropic client and conversation rules
- **Requests:**
  - Streaming Messages with SSE parsing.
  - `thinking: {type:"adaptive"}`, using `display:"summarized"` for the conversation agents.
  - `output_config.effort` always explicit. Thinking is never `disabled`, since Opus 5.5 and Sonnet 5.5 reject it.
  - Strict client tools with `eager_input_streaming` and client-side validation.
  - Image blocks for PDF page renders and SVG snapshots.
  - Prompt caching on a stable system prompt and fixed tool order.
  - `web_search_20260209` / `web_fetch_20260209` server tools.
  - `fallbacks:"default"` (beta `server-side-fallback-2026-07-01`). A remaining refusal becomes a persisted refusal card.
  - Handling for `pause_turn` and `max_tokens`.
  - Retries with backoff on 429/5xx, honouring `retry-after`.
- **Agent loop** (a port of how pi-agent-core is used):
  1. The assistant message arrives.
  2. Tools run in parallel.
  3. All `tool_result`s go back in one user message.
  4. Terminating question tools stop the turn.
  5. The steering queue is polled at turn boundaries.
  6. Abort is Task cancellation, recorded as `stopReason:"aborted"`.
- **Preserved thinking / prefix stability (highest risk).** `WireProjection` (ported from `native-messages.ts toLlmMessages`) must turn the record into a byte-stable, append-only prefix. A property test enforces this.
  - Anthropic blocks are re-sent untouched.
  - Imported foreign-provider history (e.g. OpenRouter/DeepSeek) is sent as text and tool_use only, with no thinking.
  - At the prober→teacher handoff, prober-era thinking is stripped deterministically. This is backed by `drop_block` mismatch handling, with debug logging.
  - Compaction sends the summary plus a kept tail with thinking stripped.
  - Interrupted tool calls get a deterministic synthesized result.
  - Steers go in as a text block after the tool results.

## Milestones
Each milestone ends runnable, with `xcodebuild test` green and a commit on branch `native-macos`. I then **stop for your review**. Behavioural specs come from the TS tests named below.

| # | Milestone | Main TS sources ported | Specs | Acceptance |
|---|---|---|---|---|
| **M1** | Scaffold + `LHCore` | `src/core/*`: question-core, graph, layout, compaction, coverage, settings(-resolution), cost/prices, math-delims, session-markdown, plan-tree/blocks, phases, pending, view, contracts | question-core, graph, layout, clusters, compaction, coverage, settings-*, cost-summary, plan-*, phases, fuzzy, search, session-markdown, tool-heal | App launches to an empty split view. Core tests pass. Swift outputs match JSON dumps of the TS functions over the golden fixtures. |
| **M2** | Store + importer + Keychain | `src/store/*`, `config.ts` | golden-fixtures, schema-stamps, settings-store, prompt-overrides, auth-store | Importing `tests/fixtures/golden-data` reproduces the TS graph counts (282 node lines / 160 chain lines) and the session index. Importing your real data dir moves the key into Keychain. Import is idempotent and never touches the source. |
| **M3** | Anthropic client + agent loop | `pi/ui-stream.ts`, `tool-execute.ts`, `native-messages.ts`, `provider-events.ts` | events, provider-events, tool-abort, usage, byok-refusal, chat-flow (projection) | A debug playground streams Opus 5.5 with a tool, and the second turn shows cache reads. Scripted-transport tests cover steer, abort and refusal. |
| **M4** | Native shell + transcript rendering | `components/chat.tsx`, `ai-elements/*`, `md-blocks`, `plan-block`, `pan-zoom`, sidebar, cost meter | render-markdown/md-blocks, repair-math-display, katex-security, session-find, markdown-export, pan-zoom | Imported golden chats render every marker kind, with math, mermaid, find and export working. |
| **M5** | Live teaching sessions | `teacher-agent.ts`, `tools.ts`, `prompt-segments.ts`, `chat-handler.ts`, `compaction.ts`, question/composer docks | chat-flow, question-tools, probe-done, compaction-service, dismissal-park, session-core, settings-body | A real lesson goes probe → handoff → plan → quiz → teach. It survives a relaunch mid-question, steering works, and an imported session continues without a 400. |
| **M6** | Background jobs + file tools | `runner.ts`, `server/jobs.ts`, `headless.ts`, `demo-builder.ts`, `visual-maker.ts`, `pdf-*.ts`, `tools/fs-*.ts` | jobs, activity-feed, pdf-*, demos, svg-native-render, file-access, fs-tools | Each job kind delivers exactly once, both live and idle. Abort works. Killing the app mid-job, then relaunching, recovers the job. File tools refuse anything outside the bookmarked folders. |
| **M7** | Extraction + notes import + knowledge graph | `extraction.ts`, `core/graph.ts`, `graph-canvas.ts`, `graph-view.tsx`, `chain-table.tsx` | extraction, coverage, graph-*, notes-import, delete-node | A lesson triggers extraction and the graph updates live. The golden graph drags smoothly. Deleting a node cascades through its chains. |
| **M8** | Practice, dictation, keyboard/settings, Agent Skill, polish | `tools/practice.ts`, practice docks, `keyboard.ts`, `skills/learnharness/*` | practice-*, keyboard, font-menu, tests/skills | A full practice cycle works. Dictation fills the composer. The Python skill tests pass against a DB built by the importer. |

### Notes for specific milestones
- **M2, importer:** you pick the old data folder (default: `~/Library/Application Support/LearnHarness/data`). Only `ANTHROPIC_API_KEY` moves to Keychain; other provider keys are reported and skipped. Non-Anthropic model slots map to the defaults: Opus 5.5 for Strong, Sonnet 5.5 for Cheap and Vision. The old `thinkingLevel` maps to `effort`.
- **M6, sandbox:** file tools go through one `withAccess(bookmark)` helper that checks the symlink-resolved path and denies the container's own data. Demo web views use a non-persistent data store, a strict CSP, no native bridge in display mode, and a kill timeout.
- **M7, backfill** (your answer, 2026-10-24): extraction also processes sessions from before M7 (native sessions from M5 and M6, which never ran extraction), so their answers reach the graph. How and when it runs is decided in M7's design.
- **M8, font menu:** dropped. M1 dropped Appearance entirely, so the "font-menu" tests in the M8 row don't apply (docs/native-macos-m8.md).
- **M8, Agent Skill:** the scripts open `~/Library/Containers/com.ryandoesdesign.LearnHarness/Data/Library/Application Support/LearnHarness/learnharness.sqlite` read-only via sqlite3 `mode=ro`, with a `--db` override. `references/data-format.md` is updated.

## Risks
| Risk | Mitigation |
|---|---|
| Preserved-thinking 400s | Prefix-stability property test; request snapshot tests; `drop_block` safety net |
| Streaming partial markdown | Re-parse only the trailing open block. Math and mermaid render once their block closes. UI updates throttled to about 30 Hz. |
| Graph performance | Simulation off the main thread; Canvas redraws only on change; labels culled |
| Sandbox | Stale bookmarks are re-requested in the UI; tests run hosted so they get real entitlements |
| SpeechAnalyzer locale assets | Download them via AssetInventory; hide dictation if unavailable |
| Import data loss | The source is read-only, each entity is imported in its own transaction, and a warnings log is kept |

## Verification
- `xcodebuild test -project macos/LearnHarness.xcodeproj -scheme LearnHarness -destination 'platform=macOS'`, plus `swift test --package-path macos/Packages/LHKit` for pure targets. Tests use Swift Testing.
- A `ScriptedTransport` replays `.sse` fixtures for deterministic agent tests, with no network and no key. A `RecordingTransport` refreshes those fixtures only when `LH_RECORD=1` is set.
- Golden-corpus importer parity tests. LHCore is compared against JSON dumps produced by a one-off TS script over the fixtures.
- Manual acceptance run per milestone with your key at low effort, checking the cost meter against the Anthropic console.
