# M8 design: practice, dictation, keyboard and settings, the Agent Skill, polish

This adds detail to `native-macos-plan.md`. It covers M8 only, the last milestone:
- practice sessions, end to end;
- on-device dictation;
- the menu bar and keyboard shortcuts;
- the rest of Settings;
- the Agent Skill reading the native database;
- polish: the remaining gaps between the TS app and the native one.

## Answers (2026-10-24)
You answered the first five questions. For the rest you said "answer all remaining questions with your recommended answers", so those rows are my recommendations, marked *(rec.)*. Any of them can be overturned before implementation starts.

### Practice
| Question | Answer |
|---|---|
| How a practice session starts | **A draft switch plus menus.** The ⌘N draft gets a Teach / Practice switch. File → New Practice Session (⇧⌘N) opens the draft in Practice. The chain table gets "Practice from Selection…" next to "New Session from Selection…". |
| Picking nodes from the draft | **A sheet on the draft.** "Pick Nodes…" opens the chain table as a sheet in select mode, and Done attaches the picks. You can edit them again the same way. It works for Teach and Practice. |
| The practice dock | **The question dock's look.** The same card, a chevron that folds it to a one-line "Problem …" bar, and a height that hugs its contents up to a cap, then scrolls. Half-written thinking survives folding. |
| "Your thinking" during a running turn | **Queued as a steer.** It reaches the running turn the way a teaching steer does, and shows in the queued-steers strip. (TS refuses it with an error.) |
| Enter from anywhere | **When no other field has focus.** Enter submits the thinking, or asks for the next problem after a conclusion. In the dock's field, Enter submits and ⇧Enter adds a newline. Next Problem is also a menu item (⌘↩). |
| Conclude, then pose in the same turn *(rec.)* | **Refused in code.** The prompt already forbids posing a problem in the turn that concluded one; TS only enforces it in the prompt. After a `conclude`, a `problem` call in the same turn fails with "Wait for the learner's next signal." |
| `dismissed` in `conclude`'s outcome *(rec.)* | **Removed from the tool's schema.** Its description says the model must never use it. Only the app writes it, when you discard a problem. Old records that carry it still display. |
| Tool switches in Settings *(rec.)* | **Practice's side tools obey them,** as the prober's and teacher's already do. In TS, practice ignores them. `problem` and `conclude` can't be switched off. |
| `research` in practice *(rec.)* | **Always offered,** as it is for the teacher natively. Anthropic's server-side web search is always available. |
| The stale wording in the TS prompts and tool text *(rec.)* | **Copied word for word.** Examples are "answer commits" in the pose acknowledgement and two-lane leftovers in comments. Prompt wording is yours to change. The list is under "For you to decide later". |
| The metadata popover on a concluded problem *(rec.)* | **Kept as is** (it's already native). |
| Ending a practice session *(rec.)* | **No end state (TS).** The model wraps up in prose, and Next Problem stays available. |
| When Next Problem appears *(rec.)* | **After a problem was posed without error.** TS shows it after any `problem` call, including one that failed, so a session that never posted a problem still showed Next. |

### Dictation *(all rec.)*
| Question | Answer |
|---|---|
| Engine | **On-device SpeechAnalyzer** (already decided in the plan). There's no Deepgram, no key and no keys row. |
| Where the button is | **The status bar's middle slot (TS).** "Dictate" with a mic icon. While recording: a red Stop pill, a pulsing dot and a level meter. While finishing: a spinner. |
| Shortcut | **⌘D (TS),** under Edit → Start Dictation in this app's menu. Neither SwiftUI nor this app uses ⌘D elsewhere. |
| Where the text goes | **Deferred insertion (TS).** The final text is added once, when you stop. A pending question's field takes it first (Your answer, or Your thinking), then the practice dock, then the reading-thinking field, then the composer. Submitting while recording waits for the text first, so nothing is lost. |
| Language | **The system language,** falling back to English when SpeechAnalyzer doesn't support it. TS is English only. |
| Esc | **Cancels and discards (TS),** as the top Esc layer above the dock's own layers. The Stop pill's tooltip is corrected to "Stop (⌘D) · Esc discards". TS's tooltip wrongly says Esc stops. |
| Missing language data | **The button shows "Downloading…"** while the system fetches it, then works. Dictation is hidden only when the language can't be supported at all. "Microphone access denied" opens System Settings → Privacy. |

### Keyboard and menus *(all rec.)*
| Question | Answer |
|---|---|
| Rebinding | **No in-app editor.** Shortcuts live in the menu bar, where macOS lets you rebind them (System Settings → Keyboard → App Shortcuts). TS's capture editor and its `lh:keymap` overrides are dropped. |
| ⌘ versus Ctrl | **⌘ only.** TS matches Ctrl too, which takes over the Mac's text-editing keys (⌃K, ⌃B, ⌃F…). |
| Effort (TS: ⇧Tab cycles it) | **⌘K opens the model and effort menu** in the status bar. ⇧Tab and Tab keep their Mac meaning: moving focus. |
| The knowledge graph (TS: ⌘G) | **⌥⌘G.** ⌘G and ⇧⌘G stay Find Next and Find Previous. This also fixes a live clash: ⇧⌘G currently opens both Find Previous and the graph. |
| Toggle all your thinking | **⌘T (TS),** as View → Expand / Collapse Your Thinking. The app has no Format menu, so nothing else uses ⌘T. |
| Toggle the sidebar (TS: ⌘B) | **The standard View → Show / Hide Sidebar (⌃⌘S).** |
| Rename a session (TS: F2) | **Session → Rename…,** plus Return on a selected sidebar row, as in Finder. |
| The "?" cheat sheet | **Dropped.** The menus list every shortcut, and Help → Keyboard Shortcuts opens a short native help page. |
| The sidebar's ↑/↓ | **Mac selection (as now).** |
| Docs | `docs/keyboard.md` gets a native section. The TS section stays as it is. |

### Settings *(all rec.)*
| Question | Answer |
|---|---|
| Appearance and the reading font | **They stay dropped.** M1 dropped Appearance entirely: the app uses the system look. The plan's mention of "font-menu" tests in M8 predates that, so no font menu is built. |
| Settings in the data but with no screen yet | **All get a screen.** This covers quizzing (multiple choice or free text), per-tool switches, the compaction threshold, per-role model overrides, and the prompt-override editor (a switch per segment and a text editor, as in TS). |
| Search engine, auto-update, theme mode | **Dropped** (already decided: server-side search, no updater, the system look). |

### Agent Skill *(all rec.)*
| Question | Answer |
|---|---|
| What it reads | **The native database only.** The scripts are rewritten for SQLite, as the plan says. The JSON reader and the Windows/Linux paths are removed. |
| The output | **The same rendering as today.** Native rows are translated back to the terms the output already uses. An agent reading `sessions.py read` sees the same thing either way. `data-format.md` is rewritten to describe the database. |
| Where the database is | **The sandbox container path,** with `--db` to override it. If the container can't be read, the scripts fall back to `~/Library/Application Support/LearnHarness/learnharness.sqlite` for unsandboxed builds. If macOS's App Data privacy blocks the read, the script says so and suggests copying the database and passing `--db`. |
| Version check | **Refuse unknown migrations.** If `grdb_migrations` names a migration the scripts don't know, they refuse, as they refuse future JSON versions today. |
| Opening the file | `mode=ro` through sqlite3, safe while the app is running. The no-write test also checks that the `-wal` and `-shm` files are unchanged. |
| Test data | **A committed `tests/fixtures/golden-data.sqlite`,** built from the golden JSON fixtures by the importer. A Swift test fails if the committed file drifts from what the importer produces. Small cases use a committed `schema.sql` dumped from the migrations, also drift-tested. Tests that only make sense for JSON files (torn lines, filename mismatch, the parts dialect, symlink escape) are retired. |
| Native-only data | **Not shown** (origin, stop details, the invert flag, usage tables). The output stays as it is today. |

### Polish *(all rec.)*
These are the gaps the inventory found outside the areas above. All are small.
1. **First run without a key.** Starting a session with no Anthropic key opens the key prompt before any chat is created, and the draft text is kept. Today a chat is created first and left behind empty.
2. **Model and effort on the draft.** The status bar shows them on the draft and sets the Strong slot, as in TS.
3. **A home summary.** With no session selected, the empty view shows counts of propositions, chains, teaching and practice sessions and imported notes, with buttons for New Session, New Practice Session, Knowledge Graph and Import Notes.
4. **The graph from the main window.** A toolbar button opens the Knowledge Graph window.
5. **App icon and About.** The icon is built from `build/icon.icon`. The About panel gets a copyright line.
6. **Window size.** The main window opens at 1440×900, with a minimum of 640×600 (Electron's values).
7. **The sidebar remembers whether it's shown,** and gets the standard View menu item.
8. **The last session reopens on relaunch.** This is native polish; TS doesn't do it.
9. **Reduced motion.** The spinner, shimmer and coverage-ring pulse respect the system setting.
10. **Accessibility labels** on every icon-only button.
11. **Small fixes:** the stale "traces option arrives with M7" comment, and the gallery fixture's invalid `rung: "nudge"`.

## Practice: how it works natively
The TS flow is kept as it is; the changes are the answers above.
- **Record.** `kind: "practice"` is set when the chat is created. Picks become the Graph context card at message 0, which is the same as teaching.
- **Agent.** Practice uses one agent from the first turn, with no prober and no plan. It runs on the session's conversation model (the Strong slot). The prompt is `practice/00-base.md` and `10-doctrine.md` plus the shared voice, accuracy, mental-model and formatting files (`PromptComposer.practice` already exists). Usage is recorded per turn, as for teaching.
- **Tools.** `problem` and `conclude`, ported from `src/agent/tools/practice.ts` with their argument healing:
  - Target names are resolved to node ids, unknown ids are rejected, and `[]` means no target.
  - One gate per turn, seeded from the active problem.
  - Posing while a problem is active is refused, and so is posing after a conclude in the same turn (the answer above).
  - The pose acknowledgement ends the turn. A conclusion doesn't.
  - The side tools are the file tools, `pdf`, `research` and, when graph tools are on, `list_sessions` and `list_propositions`. All of them obey the tool switches.
- **The cycle.** Pose, then your thinking (one or more submissions), then the model concludes, then a pause, then Next Problem. A discard (Esc, then "Discard this problem? The problem is dropped — no solution is revealed.") writes the silent dismiss marker. Your next input then carries the synthetic `conclude{outcome: "dismissed"}`. A discard during a running turn waits until the turn ends; `TurnService`'s parked dismissals gain problems.
- **No graph writes.** Practice sessions are never extracted, and the coverage ring is hidden (both already native).
- **UI.**
  - The dock: PROBLEM, then the statement, then YOUR THINKING and Submit thinking. It replaces the composer while a problem is active.
  - The pause: the composer's button becomes a green **Next Problem**, with the placeholder "Ask anything, or press Enter for the next one."
  - The cards, sidebar icon, filter, status line, toolbar tag and Markdown export already exist.

## Dictation: how it works natively
- A `DictationService` on the main actor:
  - **Audio:** `AVAudioEngine` input feeds `SpeechAnalyzer` with a `SpeechTranscriber` for the chosen locale, final results only.
  - **Assets:** `AssetInventory` checks the language data and installs it.
  - **Level meter:** the input level from the tap, every 60 ms, over −50 to −10 dB.
- States: idle, preparing (assets or microphone), recording, finishing, and error with a message. Text from the finished run joins with single spaces.
- The microphone needs `NSMicrophoneUsageDescription` and the sandbox's audio-input entitlement.
- Fields register as dictation targets in priority order, the way `useDictationTarget` works. Submit actions call `finishDictation()` first.

## Menus and shortcuts
The full map once M8 is done:

| Menu | Item | Key |
|---|---|---|
| File | New Session | ⌘N |
| File | New Practice Session | ⇧⌘N |
| File | Import… / Import Notes… / Export as Markdown… | (as now) |
| Edit | Find… / Find Next / Find Previous | ⌘F / ⌘G / ⇧⌘G |
| Edit | Search Sessions | ⇧⌘F |
| Edit | Start / Stop Dictation | ⌘D |
| View | Show / Hide Sidebar | ⌃⌘S |
| View | Expand / Collapse Your Thinking | ⌘T |
| Session | Rename… | (Return in the sidebar) |
| Session | Model and Effort… | ⌘K |
| Session | Next Problem | ⌘↩ |
| Window | Knowledge Graph | ⌥⌘G |
| Help | Keyboard Shortcuts | |

The dock's own keys (↑/↓, Space, ←/→, Return) and the layered Esc are unchanged.

## Settings layout
- **Anthropic:** the key, the Strong / Cheap / Vision slots, the default effort (as now), and per-role model overrides.
- **Teaching:** quizzing (multiple choice or free text), the per-tool switches, the compaction threshold.
- **Prompts:** each prompt segment with an override switch and an editor, showing the built-in text for reference.
- **Knowledge graph** and **Learner folders:** as now.

## Tests
- **LHCore and LHAgent:**
  - port `practice-record`, `practice-flow`, `practice-heal` and `practice-agents`;
  - the gate (including the new same-turn refusal);
  - target resolution;
  - the dismiss-and-park path;
  - Next readiness;
  - the tool definitions, golden-tested against TS with the two recorded differences.
- **Hosted:**
  - the practice dock's layout and fold;
  - Enter routing;
  - the draft's Teach / Practice switch and the picks sheet;
  - dictation target priority and finishing on submit (with a scripted transcriber);
  - the menu map, with no duplicate shortcuts;
  - the Settings panes saving.
- **Skill:** the 53 Python tests, ported to `golden-data.sqlite` and `schema.sql`, plus the drift tests on the Swift side.
- **Live (`LH_LIVE=1`, needs a working key):** a practice cycle on Haiku: pose, thinking, conclude, Next, pose again.

## Acceptance
1. A full practice cycle works: start from the draft (with and without picks), solve, conclude, Next, and discard a problem.
2. Dictation fills the composer and the question and practice fields.
3. Every shortcut in the table works, with no duplicates.
4. The Python skill tests pass against the database built by the importer.
5. The polish items are in.

## For you to decide later
- **Stale prompt and tool wording copied from TS:**
  - "answer commits" in the pose acknowledgement;
  - the Nudge / Commit and `decisionPoints` leftovers;
  - the `movedOn` and `surrendered` outcomes next to doctrine §VIII ("conclude only when solved or the learner asks").
- **Still open from earlier milestones:**
  - the live runs (`LiveJobs`, `LiveExtraction`, the new practice live test) wait on a working key;
  - the M6 and M7 screens haven't been checked by eye.

## Implementation notes (2026-10-24)
Commits on `native-macos`:

| Commit | What |
|---|---|
| dfc1808 | The practice agent, its tools and the turn service |
| 9e14909 | Practice in the app |
| 0362ac9 | The opt-in live practice test |
| b51da25 | On-device dictation |
| d37d235 | Menus and shortcuts |
| 42569be | The Agent Skill on SQLite |
| a4b9bd8 | The rest of Settings |
| 678a0ec | Polish |

What differs from the plan above, or was settled while building:
- **Practice:**
  - The golden dumps now include the TS practice registry and prompt (`tools-practice.json`, `prompt-practice.json`). The Swift test applies the one recorded schema difference (no `dismissed`) before comparing.
  - The pose-after-conclude refusal reads: "a problem was concluded in this turn — the next one waits for the learner's go-ahead … end your turn".
  - Targets are checked against the raw node ledger (`readNodes`), as TS does.
  - A record that ends in thinking or Next now resumes on open.
  - A problem's statement also gets the literal-newline repair (c3bf90c).
- **Dictation:**
  - It uses `DictationTranscriber` (`.longDictation`) rather than `SpeechTranscriber`, because it punctuates like the system's dictation.
  - It uses macOS 27's `installAudioTap`.
  - The menu item is Edit → "Dictate" / "Stop Dictating", because the system already adds its own "Start Dictation…".
- **Menus:**
  - View → Show / Hide Sidebar is SwiftUI's standard sidebar command.
  - Next Problem is ⌘↩. Plain Return with no field focused is a hidden default button.
- **Settings:** TS deliberately removed the per-role model rows (agent-section.tsx: "the six per-role rows disappeared"). They're back natively, collapsed under "Per-role models", as this design says. Say if you'd rather they stay hidden.
- **Agent Skill:** the agent's open choices, kept as built:
  1. **Opening the file:** `mode=ro` changes `-shm` and creates WAL siblings. It opens with `readonly_shm=1` when a `-wal` exists and `immutable=1` when it doesn't, and a test confirms nothing next to the file changes.
  2. **Output names:** the JSON key `data_dir` is now `db`.
  3. **No fallback when blocked:** a container that exists but is blocked is reported, never swapped for the fallback copy.
  4. **Settings shape:** settings show in the stored native shape. Stop reasons are mapped back.
  5. **Web search:** server web-search blocks show as unsupported content.
  6. **Omission counts:** they're lower because the importer drops turns, `api` and `responseId`.
  - Four JSON-only tests were retired, leaving 52 tests in all.
  - From a terminal, macOS App Data privacy blocks the real container, as predicted, and the script prints the copy-and-`--db` guidance.
- **Polish:**
  - The first-run check splits `startSession` (which checks the key) from `beginSession` (which creates the chat, used by tests).
  - The About copyright line reads "© 2026 Ryan Tessier".

Still not done:
- the live runs (`LiveLesson`, `LiveJobs`, `LiveExtraction`, `LivePractice`), which need a working key;
- every UI check by eye;
- a real-microphone dictation run.
