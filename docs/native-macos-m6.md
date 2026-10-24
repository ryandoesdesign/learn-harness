# M6 design: background jobs and file tools

This adds detail to `native-macos-plan.md`. It covers M6 only: the four sub-agent jobs (research, demo, visual, pdf) end to end, and the learner file tools (read, ls, find, grep).

## Your answers (2026-10-24)
| Question | Answer |
|---|---|
| File access | **A "Learner folders" list in Settings**, with Add… and Remove. These are security-scoped bookmarks. No path, or a relative path, resolves against the first folder. Absolute and `~` paths are allowed only inside a granted folder. A path outside every folder is refused with a message telling the agent to ask you to add the folder. The container's own data is always denied. |
| Demo sandbox | **CDN scripts only, no bridge.** The CSP allows scripts and styles from cdnjs, jsdelivr and unpkg, and blocks every other network request and all storage. The page can't call into the app: the app reads the page's height and caught errors itself, with `evaluateJavaScript`. The builder's prompt and the verifier follow the same rules. |
| Job recovery | **Re-run (TS parity), eagerly at launch.** A finished but undelivered result is re-delivered. A mid-run job re-runs from its original tool input, shown as "recovering: re-running". A job whose input was lost fails instead of running "(no question)". |
| Demo origin (added during implementation) | **A private scheme.** WebKit masks every uncaught error as "Script error." in an opaque origin. Each view therefore serves its demo from its own `lhdemo://<uuid>/` handler, with the CSP as a response header. Storage works only inside that view's non-persistent store and never outlives it. |
| TS bugs fixed | **All four:** the pdf `"all"` page spec and unbounded ranges; `~` paths, and the pdf path resolving against the process's working directory; a raw error on an invalid grep regex; `read` size limits (25 MB, images downscaled to 2,000 px, binary files reported). |

## Packages
**LHStore:**
- **Migration `v3`:** `UNIQUE(chat_id, tool_call_id)` on `job`, used by get-or-insert dispatch.
- **`BookmarkStore` gains the persisted learner folders:** `folder_bookmark` rows; `withAccess(url)`; stale bookmarks re-created.
- **The new entitlement `com.apple.security.files.bookmarks.app-scope`.**

**LHAgent:**
- **`JobService`** (actor; the port of `server/jobs.ts`, `runner.ts` and `aborts.ts`): dispatch, runs, abort, delivery, recovery.
- **The four dispatch tools,** with TS-identical names, schemas, descriptions and acks (golden-dumped, as in M5).
- **The sub-agents:**
  - **`Researcher`:** rewritten for the Anthropic `web_search_20260209` / `web_fetch_20260209` server tools.
  - **`DemoBuilder`:** `write_demo` and `run_demo`.
  - **`VisualMaker`:** `write_svg`, `edit_svg` and `render_svg`. The render goes back to the model as an image.
  - **`PdfReader`:** `pdf_info`, `pdf_extract`, `pdf_search` and `pdf_render`.
- **The file tools:** `read`, `ls`, `find` and `grep`. They are TS ports (the TS output formats and notices) with the fixes above.

**LHWeb:**
- **`HeadlessVerifier`** (the protocol LHAgent depends on, as in the plan): an offscreen, non-persistent WKWebView.
  - It loads the demo under the display CSP, in the same opaque-origin, storage-less sandbox it will run in.
  - It hooks `console.error`, `error` and `unhandledrejection` with a user script, and approximates failed subresources with capture-phase `error` listeners.
  - It evaluates an optional probe, and has a 20-second load timeout plus a 2-second settle.
  - It fits under the tool's 30-second guard, which fixes a TS gap.
- **`renderSvg`:** the M4 snapshot renderer at 2×, on white. Its PNGs are single-IDAT via ImageIO, with a test that pins that.
- **`DemoWebView`:** the live demo in the transcript.
  - It is non-persistent and uses the display CSP.
  - It has no message handler. The app polls `document.body.scrollHeight` and an injected `window.__lhErrors` with `evaluateJavaScript` for the height (clamped to 80–2,400) and the error chip.

**PDFs** go through PDFKit:
- Text comes from `PDFPage.string`. It keeps newlines, unlike the TS pdfjs blob, so search lines become meaningful.
- Search uses NSRegularExpression or a literal match.
- Rendering draws each page into a CGContext at dpi/72.
- `image_count` comes from a CGPDFScanner counting `Do` operators.
- The `math_density` heuristic is ported.

## Jobs
**Dispatch:**
- The tool does get-or-insert by `(chat_id, tool_call_id)`, then spawns the run only for a new row. It returns `Dispatched (job <id>). <ACK>`.
- **Who gets which tools:** the teacher gets all four (toggle-filtered); the prober gets research and pdf (toggle-filtered). Research is always on when a key exists; there is no search provider any more.
- **The M5 prompt gates are removed for these tools,** and the read and research segments come back.

**The run:**
- One Task per job, registered for abort.
- Status `running`, then `done` or `error`. An abort sets `error` with "Aborted by learner".
- **Activity lines:** "researching", "building demo", "drawing figure", "reading pdf". The researcher's lines come from `server_tool_use` blocks in the stream: `web_search: "q"` or `web_fetch: host`.
- **Usage:** written per step and kept on abort. Web search requests land in `usage_step`.
- **Roles:**
  - researcher and demoBuilder run on the Cheap slot; visualMaker and pdfReader on the Vision slot;
  - `agent.models` overrides apply, as in TS (pdfReader has none);
  - effort comes from the override or the slot.
- **Budgets:** researcher 12 turns (web_search `max_uses` 8), demo 24, visual 8 iterations, pdf 14.
- **No concurrency cap,** as in TS.

**Failures still deliver.** Each kind's failure shape arrives as a steer: research gets "Research failed: …"; demo and visual get an empty body with `FAILED:` notes; pdf gets "PDF failed: …". A refusal before the loop (no key, no model) also delivers.

**Delivery, exactly once:**
- **The steer:** the result becomes `buildSubagentSteer`, whose id is the deterministic `steer_<jobId>`. It goes into the M5 **`steer_outbox`**. Then:
  - **During a turn:** it is handed to the turn and lands at the next boundary.
  - **When idle:** the TurnService fires a wake turn, writing the marker ahead.
- **The holds:** a dangling question or the dismissal pause keeps it pending; your next send carries it.
- **Exactly once:** `steerDelivered` (the id is in the record) guards every path.
- **Completion:** the job becomes `done` or `error` (`isSubagentFailure`) when the marker lands.
- **Abort:** End cancels the Task, drops the job's undelivered pending steer, sets the status, and delivers `buildAbortSteer` with the same id. Whichever lands first is the only one delivered.

**Recovery at launch** (your answer): every `running` row is an orphan.
- With a stored result, it is re-queued.
- Without one, it re-runs from the tool input recovered from the transcript. If the input is missing, it fails with "interrupted — its input was never saved".

## File tools
- **Resolution** (your answer): see the File access answer above.
  - Expansion: `~` expands to your real home folder (the user-directory path, not the container's), and then the folder check applies to the symlink-resolved path.
  - Refusal message: `"<path>" is outside the folders LearnHarness can read (<folders>). Ask the learner to add its folder in Settings → Learner folders.`
  - With no folders granted, every call returns `No learner folders are set up yet. Ask the learner to add one in Settings → Learner folders.`
- **Behaviour (TS):**
  - walks exclude `node_modules`, `.git`, `Library` and `.Trash`;
  - symlinks are skipped in walks, while `ls` and `read` follow them, inside the folders only;
  - a 10-second walk budget with partial results;
  - output capped at 50 KB on whole lines;
  - the TS notices and error wording;
  - `find` uses fd-style globs, `grep` the TS format.
- **The fixes:**
  - `read` refuses files over 25 MB and reports binary files (a NUL byte in the first 8 KB) instead of decoding them;
  - images over 2,000 px on their long edge are downscaled;
  - `grep` returns `Invalid regex: …` for a bad pattern;
  - the pdf job resolves its path like the file tools;
  - `"all"` and page ranges are clamped to the document.
- **Who gets them:** the prober and the teacher (and practice in M8), always on, as in TS.

## UI
**Sidebar "Background agents"** (activity-dock.tsx):
- Each running job across all chats is a row: kind icon, session title, activity, cost, a ticking elapsed time, and End.
- Clicking a row expands the detail: cost, context, model, steps, and Open session.
- The header shows the total.

**DispatchCard running form:** a spinner, the label, `· Ns` and the activity line. The settled form is from M4.

**Demo card (live):** `DemoWebView` replaces the M4 placeholder, with:
- the invert toggle (persisted to `message_ui`, which also covers the figure card — M4 left that write undone);
- Download;
- the error chip "This demo threw an error" with "Send to teacher", which sends `The demo "<title>" threw an error: <message>` as your text.

**Settings → Learner folders:** the list, Add… (NSOpenPanel, directories), Remove, and a stale-bookmark "Re-grant" state.

## Specs ported
| TS spec | Native coverage |
|---|---|
| `jobs` | The job store, steer helpers, dispatch, each runner, the wake pipeline over the outbox, live handoff and settlement, abort, the recovery sweep (adapted to launch), BYOK and key refusals. |
| `activity-feed` | The running-only, all-chats feed, oldest first, with titles. |
| `demos` | The display bridge semantics, rewritten for the polled height and errors; the steer and dispatch cards; invert; the demo builder and visual maker with a fake model and a fake verifier; runner wiring. |
| `svg-native-render` | Intrinsic size, viewBox-only renders 900 wide, size overrides, single-IDAT PNGs. |
| `pdf-*` | pdf-ops over PDFKit (info, extract headers, search literal/regex, probe), the reader loop with a fake engine, native rendering (DPI scaling, out-of-range skipped). |
| `fs-tools` / `read-tool` | Globs, ls, find, grep, read (text and image), abort, plus the folder resolution and refusals and the four fixes. |
| `researcher-pdf`, `web-search` | Replaced: the server-tool researcher's request shape (tools, `max_uses`, pause_turn continuation) and source extraction from `web_search_tool_result` blocks and citations. |
| `headless-png` | The single-IDAT check. |

## Acceptance
- **Automated:** green under `swift test` and `xcodebuild test`, including a hosted test that verifies a real demo in WebKit (a passing demo and a throwing one).
- **Live** (`LH_LIVE=1`, your key, cheap models): one job of each kind delivers exactly once, both while a turn runs and while idle. An abort lands as one abort steer. A simulated kill mid-job, followed by launch recovery, re-runs and delivers.
- **Manual (yours):**
  - a real lesson with a demo and a figure;
  - a PDF from a granted folder;
  - End on a running job;
  - quit mid-job, then relaunch;
  - a path outside your folders is refused.
- Then one commit, and I stop for your review.

## Implementation notes (2026-10-24)
**The demo sandbox runs on a private scheme** (your answer during implementation; it replaces "opaque origin, storage-less").
- **Why:** I measured that WebKit reports every uncaught error as "Script error." whenever the document's origin is opaque. That covers both `loadHTMLString` with no base URL and the CSP `sandbox` directive. The builder would then iterate blind.
- **How it works:**
  - Each view (each verifier run, each transcript card) registers its own `lhdemo` handler and serves the document at a fresh `lhdemo://<uuid>/`.
  - The CSP is a real response header, so the document can't widen it (tested).
  - Its store is non-persistent, so nothing outlives the view and no two demos share anything.
- **The CSP:**
  - Scripts, styles and fonts may come only from the three CDN hosts.
  - `connect-src`, frames and forms are `'none'`; images and media are `data:` and `blob:` only.
  - It also allows `'unsafe-eval'`. Some CDN libraries compile code at runtime, and eval can't reach the network.
- **Error messages** are the error's message, matching the TS `pageerror` handler's `err.message`.

**Parity with TS:**
- **Generated tool text:** the eight new tools' names, descriptions and schemas come from the TS golden dump. `scripts/gen-native-tools.py` writes `GeneratedToolDefinitions.swift`, and the golden tests pin them byte for byte.
- **Ported verbatim:** the demo builder, visual maker and PDF reader loops are line-for-line ports, with TS-identical result texts and gates:
  - final verification;
  - never an unlooked SVG;
  - never an unread brief.
- **Prompt resources:** the sub-agent prompts are bundled at `prompts/subagents/*.md`.
  - The demo builder's prompt gains one line naming the CDN hosts.
  - The researcher's prompt is rewritten for the server tools.
- **Prompt gates:** only the `list_sessions` gates remain in `prompt-gates.json`, since every M6 tool is now registered.

**The researcher** runs on `web_search_20260209` (`max_uses` 8) and `web_fetch_20260209`, for 12 turns.
- Activity lines come from the streamed `server_tool_use` blocks.
- Sources are the brief's markdown links, falling back to the fetched and searched results (at most 10).

**PDFs** use PDFKit throughout.
- Page text keeps its newlines, so `pdf_search` hits are real lines.
- `image_count` counts the page's `Do` operators that draw an Image XObject.
- `pdf_render` reports when the spec held more than its 6-page batch.

**Delivery** runs through three new TurnService hooks:
- **`deliverSteer`:**
  - If the steer is already in the record, it only reports it.
  - Mid-turn, it's handed to the loop.
  - When the session is idle, the marker is written ahead and a wake turn starts.
  - It holds for an open question, the dismissal pause, or a missing key.
- **`dropPendingSteer`:** used by abort.
- **A landed-steer observer:** settles the job when its `steer_<jobId>` lands. A failure shape settles it as `error`.
- **Abort and delete:**
  - An abort drops only a *pending* result steer. A result already handed to a running loop may still land, in which case the abort steer, which has the same id, is skipped.
  - Deleting a session cancels its jobs without delivering anything.

**Usage:**
- Each sub-agent call is written to `usage_step` (owner `job`).
- The job's folded total adds the 1-hour cache writes and web search/fetch counts. That way, a job's cost includes its searches.
- `JobService` uses a native fold; the TS-parity fold is unchanged.

**The demo card** measures `body` plus its margins, as the TS bridge did. It's 360pt until the first measure, then clamped to 80–2,400. The Render Gallery's demo is now a real one: a slider, and a button that throws so you can see the error chip.

**Tests:**
- 781 tests in total pass under `xcodebuild test`.
- The hosted `DemoSandboxHostTests` verify a passing demo, a throwing one, a blocked host and the gallery demo inside the sandboxed app.
- With `LH_LIVE=1`, they also load a real script from jsdelivr under the sandbox (passed).

**Not yet done:**
- **The live acceptance hasn't run.** The Anthropic key in the repo's `auth.json` is now rejected with a 401 (it worked in M5). The run did confirm that every kind's failure path delivers exactly one steer. `LiveJobsTests` is ready to run with a working key.
- **I haven't seen the new UI on screen.** That's the running dispatch card, the live demo card, Background agents and Learner folders. This shell can't capture the app's window, so these are in your manual checks.
