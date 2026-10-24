# M7 design: extraction, notes import and the knowledge graph

This adds detail to `native-macos-plan.md`. It covers M7 only:
- extraction (lesson prose → graph nodes and chains), including the backfill;
- notes import;
- the prober's graph tools;
- the knowledge graph window, the chain table and graph deletion;
- the graph settings.

## Your answers (2026-10-24)
| Question | Answer |
|---|---|
| Backfill | **Automatic, once, everything.** On the first launch after M7, every non-practice session with any unextracted teacher prose is extracted, ignoring the token threshold. It runs in the background and shows in Background agents. |
| Lesson tail | **TS behaviour.** After the backfill, extraction runs automatically only once a session's unextracted prose reaches the threshold (default 4,096 tokens). Anything less waits for the per-session Extract action. |
| Session-delete bug | **Fixed.** In TS, "Also remove its graph traces" deletes every node with no provenance, even nodes that session never touched. Natively, only nodes the deleted session contributed to are candidates. |
| Notes import vs the Extraction switch | **An explicit override (TS).** Import always works. The switch governs automatic extraction from lessons only. |
| Notes source id | **The file's full path** (TS uses the file name). Same-named files in different folders stay separate. Re-importing a file updates its source; a moved or renamed file becomes a new one. Files imported in the TS app were recorded by name only, so re-importing one natively creates a new source. |
| Prober prompt lines | **Stripped when the tools are off.** The two `list_sessions` gates stay in `prompt-gates.json`. When the tools are on, the prompt matches TS. |
| Where the graph lives | **Its own window.** It opens from the Window menu with ⌘⇧G, so it can sit beside a session. The detail column keeps its current empty state. |
| Navigation | **Mac-native.** Two-finger scroll pans and pinch zooms at the cursor. Dragging empty space pans; dragging a node moves it. A mouse wheel without a trackpad zooms. ⌘= / ⌘- / ⌘0 zoom in, zoom out and fit. |
| Chain-table Delete | **TS node deletion, plus "Delete chain".** A chain row's context menu gains "Delete chain", which removes only that argument (the `arg_` branch). Its propositions and other chains stay. |
| Graph settings panel | **All of it.** Every TS control, with the same ladders, ranges and defaults. Your imported TS render settings carry over. |
| Sessions from picks | **Teaching too.** "New Session from Selection…" in the chain table opens the ⌘N draft with the picks attached, and the session starts with the Graph context card. M8's practice uses the same picker. |

## Packages
**LHCore:**
- **Trace deletion:** `deleteNodeTraces` (a node, or an `arg_` chain) and `deleteChatTraces` (the `preserve-graph` and `delete-nodes` modes, with the fix above).
- **`commitPositions`:**
  - keeps known ids only;
  - drops non-finite values and clamps to ±1e6;
  - re-settles when the view has ids the client didn't send.
- **Extraction helpers:**
  - **Prompt inputs:** `proseView`, `sourceDigest` and `chunkNotes`.
  - **Validators:** `validateSessionAnchors` and `validateFindingsChains`.
- **Render settings:** `GraphRenderSettings` with its region and physics tuning, the sanitizer (including the legacy `sizeUnits` reset) and the ladders, ported from `render-settings.ts`.
- **Canvas math:** the pure parts of `graph-canvas.ts`:
  - `zoomRatioOf` and `labelAlpha`;
  - `fitTransform` and `arrowGeometry`;
  - `pickNearest`;
  - label wrapping, `isNodeVisible`, `seedMissingNodePositions` and `displayCostTotals`.

**LHStore:**
- **Session delete:**
  - `ChatRepository.delete` also removes the chat's `coverage` and `graph_session` rows, as TS does in both modes. Today they're left behind.
  - The graph-trace deletes and the chat delete run in one transaction.
- **Revision counter:** a graph revision value bumped by every ledger write, which the UI observes.

**LHAgent:**
- **`ExtractionService`** (actor; the port of `extraction.ts` orchestration):
  - **Per source:** single-flight. Batches run in order, each seeing the previous merge.
  - **Concurrency:** extraction has its own FIFO limit of 3, as in TS; M6 jobs don't count against it. Audit and merge are serialized app-wide (the audit lock).
  - **Phases:** `queued` → `extracting` → `waiting` → `auditing` → `merging`.
  - **Abort and failure:** abort is real cancellation, keeping partial usage. A failed batch is isolated, and its messages stay uncovered.
  - **Usage:** one `ExtractionRunUsage` per batch, with its steps in `usage_step`.
- **The stages:** an extractor (4 turns) and an auditor (16 turns), on the extractor and auditor roles (the Cheap slot).
  - Both use the submit-agent pattern: the run ends at the first valid `submit_findings` or `submit_review`. Validation errors go back to the model, which retries.
  - Prompts are verbatim from TS, as resources under `prompts/extraction/`.
  - Tool definitions are golden-dumped. `tool_choice` is left on auto, as in TS, so thinking stays usable.
  - The auditor's tools are `find`, `list_sessions` and `list_propositions` (the auditor variants).
- **Triggers:**
  - after every settled non-practice turn, when Extraction is on and the session's unextracted tokens are at or over the threshold;
  - the per-session Extract action (no threshold);
  - notes import;
  - the one-time backfill sweep.
- **The backfill** is marked done in settings only after every eligible session has been attempted. A session that failed stays unextracted, so the Extract action still covers it.
- **The prober's `list_sessions` and `list_propositions`:**
  - Their text is TS-identical (golden-dumped from `tools-prober.json`).
  - They are registered after `pdf` and before `probe_done`, only while `graphToolsEnabled` is true (Extraction on, and the Graph tools toggle on).
  - `agent.tools` can also switch each one off.
- **Guards:**
  - Deleting a session aborts its extraction and waits for it to wind down.
  - Deleting a node is refused while any extraction is running, with "An extraction is running — try again when Background agents is clear."

**Notes import:**
- **Accepted files:** `.md`, `.markdown` and `.txt`, several at once, picked with an open panel.
- **Processing:**
  - Three files are processed in parallel, and each file's chunks run in order.
  - Each file is reported as completed, failed, partial, aborted or busy. Only failures are shown.
  - Re-importing a file re-extracts all of it, as in TS.

## The graph window
**Data:**
- The window observes the graph revision, so it updates live as extraction merges, nodes are deleted or sessions are renamed.
- Renames patch labels only, so a drag in progress is never cancelled.

**Layout and physics:**
- The stored positions are the layout. Nodes missing from it are seeded deterministically, as in TS.
- The live d3-force simulation (ported in M1) runs on a background actor:
  - It publishes position snapshots to the view at up to 60 Hz.
  - Drag pins go to the actor as messages.
  - When the simulation settles after a drag, the positions are committed through `commitPositions`.
  - The TS renderer constants are kept: decay 0.05, drag target 0.3, settle alpha 0.005, commit debounce 250 ms.

**Drawing:** SwiftUI `Canvas`, redrawn only when something changes. The draw order is TS's:
1. regions;
2. edges and arrowheads (headless into implication nodes);
3. node discs;
4. node labels, which fade with zoom;
5. the hover halo;
6. cluster labels.

These go beyond TS:
- Wrapped labels are cached per data or settings change, not rebuilt every tick.
- Labels and nodes outside the viewport are skipped.
- Regions are drawn as in TS's splat (intra-cluster strokes plus member discs, three box-blur rounds, alpha applied once), using vImage.

Colours follow the system accent and light/dark appearance.

**Interaction:**
- Navigation as in your answer.
- A click selects a node and opens its detail card: name, statement, and Sessions. A chat links to its first message; an imported file is shown as text.
- Right-click → Delete.
- Search (⌘F) filters by name or statement, as on the TS canvas.
- The camera is saved per window in UserDefaults; the first open fits the graph.

**Toolbar:**
- search;
- a Chains toggle that swaps in the chain table;
- Import notes…;
- the cost pill, with its panel of per-stage costs and recent runs;
- the gear (the settings popover).

Running extractions show in the sidebar's Background agents, not in the window.

**Empty state:** "Start a session or import notes to build your graph."

**With Graph rendering off,** the window shows the chain table in place of the canvas (TS's minimal home).

## Chain table
It is a TS port:
- **Layout:** groups by the conclusion's birth session, with chain rows and their propositions, all collapsed at start.
- **Columns:** Name, Props and Created, each sortable.
- **Search:** fuzzy over names, statements and aliases.
- **Selection:**
  - Selecting a session, chain or proposition adds node ids, with partial checkboxes when only some are selected.
  - A floating bar shows "N nodes → K chains", with Clear and Delete.
  - It also has **New Session from Selection…**.
- **Row actions:** a chain row's context menu has **Delete chain**.

**Deletion:**
- The node dialog matches TS: names (up to 8), the permanence line, and Cancel / Delete.
- Several nodes are deleted in one transaction, so it's all or nothing. TS stops at the first failure and keeps what it already deleted; one transaction is simpler, and there's no half-done state.

## Sessions and Settings
**In sessions:**
- **Coverage ring:** shown in the session toolbar, except for practice sessions. It fills toward the threshold and pulses while extracting. Its popover shows uncovered and covered tokens, messages covered, the threshold and the last extraction.
- **Sidebar context menu:** gains the coverage line plus **Extract** (or "Running").
- **Delete sheet:** gains "Also remove its graph traces", unchecked by default. Its copy is corrected: TS mentions "events" and "links" that no longer exist.

**Settings → Knowledge graph:**
- Extraction (on/off);
- Graph rendering (canvas or chain table);
- Chunk budget (500 tokens or more);
- Graph tools for the prober.

## Specs ported
| TS spec | Native coverage |
|---|---|
| `extraction` | Triggers and threshold, batching, digest, validators and retries, the submit capture, merge, phases, single-flight, the audit lock, abort semantics (an aborted run resolves with nothing merged, not an error), usage per batch, deletion during a run, and notes import, all with scripted transports. |
| `graph` (deletion) | `deleteNodeTraces`, the `arg_` branch, both `deleteChatTraces` modes, and the no-provenance fix. |
| `notes-import`, `notes-import-route` | Parallel files, mixed outcomes, re-import, full-path ids. |
| `graph-canvas`, `graph-view-filters`, `graph-rename-labels`, `render-settings` | The pure functions: zoom, labels, fit, arrows, picking, wrapping, visibility, seeding, sanitizer and ladders. |
| `commit-positions` | Sanitizing, clamping and the re-settle. |
| `render-chain-table`, `delete-node-dialog`, `render-extraction-coverage` | Grouping, sorting, search, selection maths, the delete and coverage view logic. |
| Prober tools | Golden text, gating, output formats. |

## Acceptance
- **Automated:** green under `swift test` and `xcodebuild test`.
- **Live** (`LH_LIVE=1`, a working key, cheap models): a scripted lesson crosses the threshold, extraction merges, and the graph revision changes. A notes file imports. The prober's `list_sessions` sees the result.
- **Manual (yours):**
  - the backfill populates the graph from your existing sessions;
  - the golden graph drags smoothly in the window;
  - deleting a node cascades through its chains;
  - "Delete chain" removes only the argument;
  - a session started from a selection opens with its Graph context card;
  - the session-delete option with traces.
- Then one commit, and I stop for your review.

## Implementation notes (2026-10-24)
**Parity with TS:**
- **Generated text:** the extraction prompts, both `submit_findings` variants, `submit_review`, the auditor's tools and the prober's `list_sessions` / `list_propositions` come from the golden dump.
- **How they're generated:**
  - `scripts/dump-agent-golden.ts` writes `extraction.json`. It needed `export` added to four constants in `src/agent/subagents/extraction.ts`; nothing else in the TS changed.
  - `scripts/gen-native-tools.py` generates `GeneratedGraphToolDefinitions.swift` and `prompts/extraction/*.md`.
  - The golden tests pin the prober's tool set (graph tools included) byte for byte. With the graph tools on, the prober's composed prompt is identical to TS; with them off, the two `list_sessions` gates strip the map section (your answer).

**Extraction** (`ExtractionService`, an actor):
- **Merges are atomic:** a batch's nodes, chains, coverage and layout settle land in one transaction (`GraphRepository.transaction`). TS appends them separately, so a crash mid-merge could leave nodes with no coverage, and the next run would extract them again.
- **Usage is recorded in two places:** on the job's row while it runs, and per batch on exit (success, failure or abort), as TS does.
- **The backfill:** runs in the background after launch recovery. It's marked done only after every eligible session has been attempted. It waits while there's no key or Extraction is off.

**Deletion:**
- **A session delete:** first winds down the session's extraction, then deletes its traces and the chat in one transaction.
  - `ChatRepository.delete` now also removes the chat's coverage and checkpoint rows.
  - A provenance-less line counts as "held elsewhere", which is your fix: legacy nodes survive.
  - A chain's position is pruned only when every line of that chain died. TS prunes it when any line dies.
- **Node deletion:** all selected nodes go in one transaction, and it's refused while any extraction runs. "Delete chain" uses the `arg_` branch.

**The graph window:**
- **Drawing:** an AppKit view drawn with Core Graphics. The simulation runs on the `GraphPhysics` actor.
  - **Commands:** drag pins and releases reach the actor through one ordered queue. Separate Tasks could reorder them and leave a node pinned; a hosted test caught that.
  - **Labels:** wrapped once per data or settings change.
  - **Culling:** nodes, edges, labels and cluster labels outside the viewport (plus a label-width margin) aren't drawn.
- **Regions:** drawn with the ported `boxBlurRound`, the exact TS splat, rather than vImage as the design said. The bitmap is at most 512 px, rebuilt every third frame while the simulation runs.
- **Renames:** relabel the clusters in place, so a drag in progress is never cancelled.
- **Search:** one toolbar field. On the canvas it matches name or statement as a substring (TS); in the chain table it's the fuzzy search over names, statements and aliases (TS).

**Smaller choices:**
- The coverage ring's popover has an "Extract now" button.
- The sidebar context menu shows the coverage line plus Extract (or "Running").
- The session delete sheet's copy no longer mentions "links" and "events".

**Tests:** all 814 pass under `xcodebuild test`.
- **New package tests:** graph deletion (including your fix), `commitPositions`, render settings, the canvas maths, the extraction inputs, the store transaction and revision, the extraction service over scripted transports (merge, retry, failure isolation, threshold, batch order, abort, notes import, backfill), and the prober's tool set with the graph tools on and off.
- **New hosted tests:** the graph window's load, search, drag and commit, deletion, and New Session from Selection.
- **One unexplained failure:** `graphToolsOffStripTheMapFromTheProber` failed once, on its first run, then passed eight times in a row (alone and with the full suite). I found no shared state that would explain it.

**Not yet done:**
- **The live acceptance hasn't run:** the `auth.json` key still returns 401. `LiveExtractionTests` is ready.
- **I haven't seen the window on screen:** this shell can't capture it. What I checked through the accessibility interface: the app launches, ⌘⇧G and Window → Knowledge Graph open the 1100×760 window, and it closes cleanly.
- **Yours to judge:** smooth dragging on the golden graph, and how the window looks, are in your manual checks.
