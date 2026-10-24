# M3 design: Anthropic client and agent loop

This adds detail to `native-macos-plan.md`. It covers M3 only. Wire details were checked against the current Claude API reference (API version `2026-10-21`).

## Your answers (2026-10-24)
| Question | Answer |
|---|---|
| Usage semantics | Anthropic-native: `inputTokens` is the uncached input, exactly as the API reports it. |
| Cache TTL | 1 hour for the conversation agents (prober, teacher, practice). Background sub-agents keep the default 5 minutes. |

### What the usage answer changes in M1 code
- `callCost` = input·in + cacheRead·cr + cacheWrite5m·cw + cacheWrite1h·cw1h + output·out.
- The Haiku tier is checked on input + cacheRead + cacheWrite.
- `CallUsage` gains `cacheWrite1hTokens` (a subset of `cacheWriteTokens`), `webSearchRequests` and `webFetchRequests`.
- `models.json` gains a `cacheWrite1h` price per model (2× input).
- Web search is billed at $10 per 1,000 searches; web fetch has no per-request charge.
- `usage_step` gains a `cache_write_1h_tokens` column (migration `v2`).

## New packages (no external dependencies)
- **`LHAnthropic`**, which depends on LHCore:
  - `MessagesRequest`, plus the block and event types.
  - An `SSEParser`.
  - The `AnthropicTransport` protocol.
  - Three transports:
    - `URLSessionTransport`: the real one;
    - `ScriptedTransport`: replays `.sse` fixture files;
    - `RecordingTransport`: tees a real stream into a fixture file, only when `LH_RECORD=1` is set.
  - `MessagesClient`: streaming plus retries.
- **`LHAgent`**, which depends on LHCore and LHAnthropic. M3 adds:
  - `WireProjection`
  - `AgentLoop`
  - the `AgentTool` protocol
  - `SessionEngine` (an actor) and `TurnCoordinator` (an actor)
  - the `ProviderEventRecorder`
  - The teacher, prober and real tools come in M5. M3 ships only a test tool and the playground tool.

## Requests
- **Headers:**
  - `anthropic-version: 2026-10-21`
  - `x-api-key` from the Keychain
  - `anthropic-beta`, which carries:
    - `server-side-fallback-2026-07-01` (left off for Haiku, which has no fallback);
    - `thinking-binding-controls-2026-08-01`.
- **Thinking:** `thinking: {type: "adaptive", display: "summarized", block_binding: {prefix_mismatch_behavior: "drop_block"}}`. `display` is `summarized` for the conversation agents and `omitted` for the sub-agents. Thinking is never disabled.
- **Effort:** `output_config: {effort}` is always sent explicitly. No sampling parameters are ever sent.
- **max_tokens:** 64000 for streaming requests, capped at the model's own limit.
- **Tools:**
  - Client tools carry `eager_input_streaming: true`, and their schemas come from the M1 `JSONSchema`. (They were `strict: true` until M5. Strict mode rejects the TS schemas, so they are now sent non-strict and validated locally; see docs/native-macos-m5.md.)
  - The server tools are `web_search_20260209` and `web_fetch_20260209`, used only by the researcher.
  - The tool list is in a fixed order.
- **Caching:** `system` is one text block with a `cache_control` breakpoint (`ttl` per role), plus a top-level automatic `cache_control` that caches the conversation's growing prefix.
- **Fallbacks:** `fallbacks: "default"`, except on Haiku.
- **Stop reasons:**
  - `pause_turn`: the paused assistant content is sent back and the request continues, in the same turn.
  - `max_tokens` with a `tool_use` present: those calls get an error result and nothing runs. This is pi's behaviour for a `length` stop.
  - `refusal`: the turn ends, and the assistant message is stored with stop reason `refusal` plus `stop_details`. The transcript shows it as a refusal card.
  - A response containing `fallback` blocks is stored as the API returned it.
- **Retries:**
  - **When:** on 408, 409, 429, 500–599 and 529, and on connection errors, **but only before the first SSE event**.
  - **How:** up to 4 retries, with exponential backoff (1s, 2s, 4s, 8s, plus jitter, capped at 30s). A `retry-after` header is honoured.
  - **Mid-stream errors** end the message as stop reason `error` with an `errorMessage`, as in TS.
  - Other 4xx errors are surfaced immediately.
- **Usage:**
  - `message_start` usage and the final `message_delta` usage are merged.
  - `usage.iterations` becomes one `usage_step` per attempt, with `fallback_from` set on the fallback attempts.
  - `server_tool_use` counts go to the web columns.
  - `input_transformations` entries are written to the debug log.

## WireProjection (record → `messages[]`)
This is a port of `toLlmMessages`, together with the pi-ai transform rules that ran after it.

**Markers and cuts:**
- **Compaction cut:** the summary marker becomes the head, and the kept tail follows with its thinking blocks stripped (the keep-tail rule).
- Markers become user text. `plan-block` and `problem-dismissed` markers are dropped.

**Assistant messages:**
- **Dropped entirely:** messages whose stop reason is `aborted`, `error` or `refusal`. The refusal rule is new; the other two follow pi.
- **Fallback turns:** blocks before the final `fallback` block follow the echo rule. Thinking, `tool_use` and unpaired server-tool blocks are dropped. `fallback` blocks themselves are dropped.
- **Thinking:** signed thinking and `redacted_thinking` are sent unchanged. Unsigned (imported, foreign) thinking is dropped.
- **Prober→teacher handoff:** once a chat is in the teach phase, every thinking block before the probe-handoff marker is stripped. Removing from the front of the history is allowed, and the system prompt and tools change at this point anyway.

**Tool calls and results:**
- **Tool results:** a result becomes a `tool_result` block (the `details` field is never sent). An image in an error result is replaced by a placeholder, and the image follows in the same user message, as pi does.
- **Dangling calls:** a call with no result in the rest of the record gets a synthesized `INTERRUPTED_TEXT` result. A result whose call is not in the projected history is dropped.

**Imported tool ids:** ids not matching `^[a-zA-Z0-9_-]{1,64}$`, and duplicates such as DeepSeek's `call_0` reused every turn, are remapped deterministically as `lh_<n>_<sanitized>`, numbered by first appearance. The same remap applies to the result's `tool_use_id`.

**Merging:** consecutive user-role entries (tool results, then steer or marker text) are merged into one user message, with `tool_result` blocks first.

**Determinism:** the output is a pure function of (record, phase, model), so the bytes are identical on every rebuild.

**Property test:** for every request boundary in the golden chats and in synthetic records (steer, abort, refusal, compaction, handoff), the projection of the prefix is a byte-exact prefix of the projection of the full record.

## Agent loop (a port of how pi-agent-core is used)
**The turn:**
- `SessionEngine.run(turn)` streams one assistant message.
- It runs its client tools in parallel, each through `withToolGuard`:
  - a 30-second timeout;
  - abort forwarding, with a 250ms grace period;
  - the exact TS error wordings.
- All results come back in one user message.

**When the turn ends:**
- **Terminate:** only when every tool in the batch reports `terminate`. Question tools and the problem tool do.
- **Question placeholders:** the "question posed" placeholder results stay in memory only and are never persisted, as in TS.
- **Steering:** the steering queue is polled at each turn boundary. Steers are added as user text after the tool results.

**Abort:**
- Abort is Task cancellation.
- The partial assistant message is recorded with stop reason `aborted`, and tools still running get "Operation aborted".

**Events:**
- `AgentEvent` (`messageStart`/`Update`/`End`, `toolStart`/`Update`/`End`, `turnEnd`, `agentEnd`) is published as an `AsyncStream`.
- Updates are coalesced to about 30 Hz, and settled events are kept so a late subscriber can replay them.
- The engine returns the settled new messages. M5 persists them.

**Tool-input validation:** after `content_block_stop`, the JSON is parsed strictly and checked against the tool's schema. A failure becomes an error `tool_result` with the TS wording (`INVALID_JSON`, or the invalid-input problem list).

## Debug playground (acceptance)
- A **Debug → Anthropic Playground** window, in Debug builds only. It has:
  - a key field (writes to the Keychain);
  - model and effort pickers;
  - one strict client tool, `get_current_time {timezone}`;
  - a streaming transcript with text, a collapsible thinking section and tool cards;
  - a per-turn usage line: input, cache read, 5m and 1h cache writes, output, and $.
- **Acceptance:** Opus 5.5 streams, calls the tool, and continues. The second turn shows cache-read tokens greater than 0.

## Specs ported
- `tool-abort`: the guard.
- `usage`: cost folds, rewritten to the new semantics where the math changes.
- `provider-events`: the recorder, with a byte cap, writing `debug/provider-events/<chatId>.jsonl` and switched on by a Debug setting instead of an env var.
- `chat-flow`: the projection and loop cases that fit LHAgent: dangling synthesis, steer adjacency, parallel results, duplicate tool ids, abort, refusal.
- `events`: the bus becomes `AsyncStream`, so the subscriber-isolation and unsubscribe cases are ported.

`byok-refusal` covers BYOK/setup UI that M1 removed, so only `isProviderKeyRefusal` was kept, and it is already tested.

**Scripted-transport tests:** text, thinking, tool use, parallel tools, steer mid-turn, abort mid-stream and mid-tool, refusal, fallback blocks, pause_turn, max_tokens with a tool, 529 retry plus `retry-after`, and a mid-stream error.

## Acceptance
- Everything above is green under `xcodebuild test` and `swift test`.
- The playground check is run manually with your key.
- Then one commit, and I stop for review.
