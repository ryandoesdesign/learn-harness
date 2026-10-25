# M5 design: live teaching sessions

This adds detail to `native-macos-plan.md`. It covers M5 only: a real teaching lesson, end to end. Practice (M8), background jobs and file tools (M6), and the graph (M7) are boundaries.

## Your answers (2026-10-24)
| Question | Answer |
|---|---|
| M6/M7 tools | **Omitted**, along with the prompt segments that describe them (teacher/40-jobs, teacher/50-demos, shared/30-learner-files). Only the teaching tools are registered. |
| Prober doctrine lines that name missing tools | **Tool-gated line removal at composition.** The bundled prompts stay verbatim. A small rule list next to the bundle drops a line whose named tool isn't registered. M6 and M7 delete their entries. |
| Dock | **Pinned below the transcript; it folds on demand, not on scroll.** A teach check still arrives behind the reveal bar. Includes a scroll-to-bottom button and stick-to-bottom while streaming. |
| Key and model | **Minimal Settings (⌘,)**: one Anthropic pane with the key, the Strong/Cheap/Vision slots and the default effort. **Per-session model and effort picker** in the status bar. A missing key refuses the send with an "Add a key" pill and keeps the draft. The rest of Settings is M8. |
| New session | **⌘N and a sidebar "+"** open a draft in the detail column. Sending creates the chat (titled from the prompt) and starts the first turn. |
| Relaunch | **Resume both cases.** When a session opens idle and its record ends in your text or an answer, with no question open and no dismissal pause, the turn starts automatically. This closes the TS gap for a trailing text message. |
| Persistence | **Append each settled message as it completes** (assistant step, tool result, steer). Usage and plan blocks are still written at settle. |
| Steers | **Persisted through `steer_outbox`** (pending → handed → delivered). Pending steers survive a relaunch and become the next turn's input. |
| Keys | **The dock's own keys, the composer's Enter/⇧Enter, and the layered Esc** with its confirmation dialogs. Global shortcuts stay in M8. |

## Packages
- **LHResources:**
  - `src/agent/system-prompt.md` and `src/agent/prompts/**`, copied verbatim (practice included, unused until M8);
  - `prompt-gates.json`, the tool-gated line rules, e.g. `{segment, contains, tool}`.
- **LHAgent** now depends on LHStore, per the plan's dependency direction. It gains:
  - **`PromptComposer`**, a port of `prompt-segments.ts`:
    - segment order: the base, then the agent's own `NN-*.md` sorted, then `shared/` sorted, joined with `\n\n---\n\n`;
    - an override applies when `agent.prompts[path] == true` and a `prompt_override` row exists;
    - then the tool gates are applied.
  - **The teaching tools**, ported with their exact TS names, schemas, descriptions and error wording, all wrapped by the M1 argument heal:
    - **Questions:** `probe`, `quiz`, `recall`, `explain`, `ask_user_question`. They validate the authored input. A valid call returns the ephemeral "Question posed" placeholder with `terminate`. `quiz` and `explain` check `nodeId` against the live tree. `agent.tools.explain` swaps quiz→explain and probe→recall.
    - **`plan_init {mermaid}`**: a port of `tools/mermaid-plan.ts` plus `createTree`. It saves the tree during the turn and returns `{ok, nodeIds, reminder}`, with `details {ok, tree}`. It doesn't end the turn.
    - **`probe_done {assessment}`**: it refuses while a question is open or after a previous conclusion. On success it queues the handoff and returns `PROBE_DONE_ACK_TEXT`. It doesn't end the turn.
  - **`TeacherAgent`**: the prober or teacher config, chosen per turn from `hasProbeDone(record)`.
    - Conversation chain: the chat's model override over the Strong slot; effort from the chat or the slot, clamped to the model.
    - 1-hour cache TTL and summarized thinking (M3 decisions).
    - The question stopper, which ends the run when every question call in the message resolved cleanly.
  - **`TurnService`**: the port of `chat-handler.ts`, `turn-service.ts` and `turn-liveness.ts`, on top of `TurnCoordinator` and `SessionEngine`. Described below.
  - **`CompactionService`**: the port of `server/compaction.ts`. Described below.
  - **`SteerOutbox`**: the delivery state over the `steer_outbox` table.

## TurnService (one per app, actor)
**Inputs** (`input-events.ts`):
- `text` and `answer {toolCallId, answer}`;
- `continue` (the resume rule);
- `steers` (the probe-handoff wake);
- `dismiss {toolCallId, answer}` (no turn).

**The gate order, as in TS:**
1. No Anthropic key → `.noKey` refusal. The UI shows the pill and keeps the draft.
2. Compaction: `ensureCompacted` is awaited.
3. An answer with no dangling question → rejected.
4. Parallel-question gate: an answer that leaves a sibling question open is saved and no turn runs.
5. One turn per chat → `.turnRunning`.
6. Write-ahead: the input's messages are appended before the agent runs.

**During the turn** (your persistence answer):
- **Appended as they complete:** each assistant message at `messageEnd`, each tool result at `toolEnd`, and each steer when the loop takes it.
- **Kept in memory only:** question placeholders, as in TS.
- **At settle,** in this order:
  1. usage (`appendTurnUsage`, keyed by the turn id);
  2. plan blocks (`planBlocksFor`);
  3. any parked dismissal;
  4. end the turn and notify;
  5. kick compaction;
  6. the handoff wake, if `probe_done` queued one;
  7. pending steers not delivered, which become the next turn.

**Steers** (your answer):
- **Sending:** a composer send while a turn runs writes a `steer_outbox` row (pending) and pushes it to the engine's steering queue.
- **Delivery:**
  - When the loop drains it, the row is marked handed. When its message is appended, the row is marked delivered.
  - A steer stranded by a question stop stays pending and is handed to the next turn, usually the answer turn.
- **On launch:** handed-but-undelivered rows go back to pending.

**Resume on open** (your answer). The turn starts automatically when the session opens and all of these hold:
- the record ends in a user text, or an answer's toolResult;
- there is no dangling question;
- the record does not end in a dismissal;
- no turn is running.

Pending steers ride along as input.

**Abort:**
- The turn is cancelled, and the partial assistant message is appended with stop reason `aborted`.
- Dismissing a question while a turn runs is parked, as in `dismissal-park.ts`, and applied at settle.

**Interrupted calls after a relaunch:** the M3 `WireProjection` synthesizes `INTERRUPTED_TEXT` for unfinished calls, so a resumed session never 400s.

**Notifications:** an `@Observable` `LiveSessions` registry, used by the UI:
- per chat: running, compacting, the live engine stream, pending steers;
- replaces `lh:turn-state` and the server events.

## CompactionService (port of `server/compaction.ts`)
- **When:**
  - before every turn (awaited, with a per-chat mutex);
  - kicked in the background at settle.
- **Threshold:** min(`compaction.thresholdTokens` (default 150k, floor 32k), contextWindow − 16,384).
- **The estimate:**
  - It is the last usage plus chars/4 of the later messages (M1 `estimateContextTokens`).
  - **Bug fix, not ported:** TS measured the prober with the teacher's prompt. The native version uses the agent that will actually run.
- **The cut and the prompt:** the M1 `compactionCutIndex` (≈20k kept tail) and `buildCompactionPrompt` (with the plan tree).
- **The summarizer:** the session's own model, with no tools, one call, and the TS system prompt (moved into a resource).
- **Output:** the compaction marker plus its usage. The UI shows "COMPACTING CONTEXT…" and blocks sends while it runs.

## Live UI
**Transcript (live):**
- `projectView(record, live:)` drives it. Streaming updates arrive at about 30 Hz, and only the trailing open block is re-parsed.
- **Placeholders:** "THINKING…" while submitted, and the thinking row once the stream arrives. "COMPACTING CONTEXT…" shows while compaction runs.
- **Live parts:** LiveToolCard covers input-streaming calls; Reasoning shows a spinner plus a "Thinking…" shimmer and auto-closes 1s after streaming if you had opened it.
- **Errors:** "Something went wrong: …" for a stop-reason `error` or a request failure.

**Scrolling:**
- Stick-to-bottom while you're at the bottom.
- A scroll-to-bottom button otherwise, anchored above the dock.

**The dock (pinned):**
- **Composer:**
  - Enter sends, ⇧Enter adds a newline.
  - Send becomes Stop while busy with an empty field. While busy with text, Enter sends a steer.
  - Placeholders: "Ask, answer, or steer the lesson…", and "What do you want to learn?" in a draft.
  - `canSend` follows TS: text present, no pending question, not compacting.
- **QuestionDock:** every teaching kind.
  - **Kinds:** quiz single/multi (seeded shuffle), predict, probe, recall, explain, and ask with option descriptions plus "Other".
  - **Answer fields:** "I don't know"; the confidence rail with stops 0/30/50/70/90/100, default 50; the thinking field, or the text-mode answer.
  - **Submit:** "↵ submits · ⇧↵ newline", the Submit button, and the malformed-question fallback.
  - **Answer:** built by M1 `buildAnswer` and submitted as the call's toolResult.
- **Folding:**
  - **The reveal bar:** a teach-phase check (`questionNeedsReveal`) arrives collapsed behind "Check your understanding · Open ›" (the `revealArrival` rules).
  - **Reading thinking (now paragraph notes):** questions show inline where they were asked, and the learner notes any paragraph of the teacher's prose (hover ✎). The notes ride on the next answer or dismissal as `readingNotes`, and as quoted `readingThinking` for the model. Sent notes stay under their paragraphs.
  - **The dock's own bar:** it folds and unfolds the dock ("Answer ↓"). Scrolling never folds it.
- **Queued steers:** muted right-aligned lines above the dock until delivered.
- **Plan marginalia:** beside the dock when a question is pending, a plan exists and the window is wide enough. A click opens the plan popup.
- **Keys:** the dock's ↑/↓ walk the rows (no wrap), Space toggles, ←/→ step confidence, Enter submits.

**Esc layering** (`escAbortTarget`): Find and the overlays claim Esc first. After that:
- a pending question asks "Dismiss this question?";
- a running turn asks "Abort this turn?".

Both dialogs use the TS copy, including "The working turn stops too." when a turn is also running.

**Status bar:**
- the cost meter (M4);
- ModelControl: the model pill and the effort pill. It writes the chat's settings, clamped. The menu footer reads "This session's model".

**Settings (⌘,), Anthropic pane:**
- API key: a secure field, saved to the Keychain, with a "Key saved" state and Remove.
- The Strong, Cheap and Vision slot pickers from the catalog.
- The default effort.

**New session (⌘N, sidebar "+"):**
- The draft shows the "New session" empty state and the composer.
- Sending creates the chat titled with `titleFromPrompt`, stamps its settings from the Strong slot, selects it, and sends the prompt as the first `text`.

**Sidebar and title (deferred from M4):**
- **Live states:** the spinner; "Working…", "Compacting context · ago" and "Waiting for input · ago".
- **Rename:** the context menu's Rename (inline), or clicking the toolbar title.
- **Delete…:** a confirmation dialog in the TS copy. It is refused while a turn runs. The graph-traces checkbox is M7.

## Specs ported
| TS spec | Coverage |
|---|---|
| `chat-flow` | The service cases, over a ScriptedTransport: pending quiz → answer continues; one turn per chat; remote abort keeps the partial; steering between units; an invalid quiz is retried; parallel questions defer to the last answer; a wake never double-appends; duplicate provider ids; the explain flow. |
| `question-tools` | Every case: nodeId validation, the prober quiz has no nodeId, descriptions, toggles, options-string repair, explain validation. |
| `probe-done` | Every case. |
| `compaction-service` | Every case, with an injected summarizer. |
| `dismissal-park` | The park registry and apply-at-settle. |
| `session-core` | The parts that become the native session model: continuation and resume rules, the dismissal pause, the answer's two audiences, the live-view law, queued-steer visibility. HTTP, SSE and StrictMode cases are dropped. |
| `settings-body` | The validators the M5 UI writes through: chat model and effort, model slots, the compaction floor. |
| UI specs | `render-composer` (`enterAction`), `esc-layering`, `reveal-arrival`, `render-queued-steers`, `render-live-tool-card`, `render-abort-turn-dialog` (copy), `thinking-default`. |
| New native tests | Per-message persistence and resume after a simulated kill; `steer_outbox` state transitions across a relaunch; prompt composition order and overrides; tool-gated line removal. |

## Acceptance
- **Automated:** every scripted-transport and unit test above is green under `swift test` and `xcodebuild test`.
- **Live** (`LH_LIVE=1`, with your key): a scripted-learner test drives a real lesson: probe → `probe_done` → handoff → `plan_init` → quiz → answer → teaching continues. It checks the record at each step and checks that the second request reads from the cache.
- **Manual (yours):**
  - a real lesson in the app;
  - quit mid-question and relaunch;
  - quit mid-turn and relaunch (it resumes);
  - steer while a turn runs;
  - continue an imported session without a 400.
- Then one commit, and I stop for your review.

## Implementation notes (2026-10-24)
**Client tools are sent non-strict** (your answer). The live lesson test showed that strict tool mode rejects the TS schemas: it requires closed objects and allows no `minItems` above 1. Client tools now go out with the TS schemas as they are, plus `eager_input_streaming`. Every call is still validated locally, and a failure returns the TS problem list so the model retries. This replaces M3's "strict client tools".

**Parity with TS:**
- **Golden dumps:** `scripts/dump-agent-golden.ts` writes the TS teaching-tool definitions and the composed prompts into `LHAgentTests/Golden`. The Swift registries match them byte for byte in name and description, and they are schema-equal. Both composed prompts are byte-identical.
- **Ported to LHCore:** `parseMermaidPlan`, `inputAppends` / `dismissAppends`, `dockQuestion` (the dock's QuestionData with the seeded shuffle), and `QuestionAnswerData(json:)`. The schema DSL gains `minLength`.

**The agent loop gains four things:**
1. a `settled` event, which drives per-message persistence (question placeholders are never persisted);
2. the question stopper, which ends the run without draining steers so they wait for the next turn;
3. sequential batches whenever a question tool is present;
4. the argument heal before validation.

**Two consequences of per-message persistence:**
- `probe_done` judges the record *before* its own assistant message, because that message is already persisted when the tool runs.
- Steers left in the engine queue when a turn settles go back to pending in the outbox, so nothing is delivered twice.

**`resumeIfNeeded`** starts a turn when the record ends in learner text, an answer, an undelivered wake marker, or when steers are pending. It holds for an open question or the dismissal pause. The Render Gallery now ends on a settled assistant message, so opening it never resumes a turn.

**Live acceptance** (`LH_LIVE=1`, Sonnet 5.5, low effort): `probe` → `probe_done` → handoff → `plan_init` → tagged `quiz` → answer → `quiz`. That took 5 turns and about 35 seconds, and later requests read about 60k tokens from the cache.

**How a new question arrives** (your rule, 2026-10-24; it replaces TS's revealArrival / probeArrivalExpanded):
- At the bottom of the conversation, a new question arrives expanded. When you've scrolled up, it arrives folded. This applies to every kind of question.
- A folded teach check still shows "Check your understanding · Open ›".
- "At the bottom" follows your own scrolling: reaching the bottom sets it, and only a scroll you make clears it. Content growing while a turn streams, or the dock changing height, never clears it.

**Small differences from TS:**
- The delete dialog drops "unless you check below", because the graph-traces checkbox arrives with M7.
- The session title is renamed with the native editable title (click it).
- Settings shows each model slot as a model plus its effort.
