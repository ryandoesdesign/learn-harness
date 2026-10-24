# M4 design: native shell and transcript rendering

This adds detail to `native-macos-plan.md`. It covers M4 only. M4 is **read-only**: it renders the stored sessions. Live turns, the composer and the question docks are M5.

## Your answers (2026-10-24)
| Question | Answer |
|---|---|
| Text engine | SwiftUI blocks, as the plan says. Selection is per block; copy corners cover code, math and tables. |
| Math | **Native SwiftMath** (pinned), not KaTeX. No WebKit for math. KaTeX and the `katex-security` spec are dropped. |
| Mermaid | Snapshot + live overlay: a shared hidden WKWebView renders each diagram to a cached image. Expand opens one live WKWebView in the session overlay. |
| Look | The TS layout, labels and order, drawn with system type (SF Pro, New York for prose, SF Mono) and semantic system colors. |
| Demo / figure cards | Figures render now. Demo cards show header, title and Download (.html), plus a placeholder until M6. |
| Sidebar | A read-only list plus export: search, kind filter, row meta, Export as Markdown…. Rename and Delete wait for M5. |
| Refusal | A muted, centered system line: "Claude declined to continue this response." If `stop_details` has an explanation, a disclosure shows it. |
| Plan layout | A **native layered (Sugiyama-style) layout** in Swift. No dagre, and no parity test against the TS positions. |
| Cost meter | A slim **bottom status bar** under the transcript. M5's composer later sits above it. |
| Top bar | The **native toolbar**: the title is the navigation title, PLAN is a toolbar button, and the phase chip is a toolbar label. |

## Packages
These are added, pinned `exact:`:
- `swift-markdown` 0.9.0
- `SwiftMath` 1.7.3 (`mgriebling/SwiftMath`)
- `Highlightr` 2.3.0
- `mermaid` 11.17.0's `mermaid.min.js`, copied from `node_modules` into `LHResources`.

`swift-collections` is not needed yet.

**New targets:**
- **`LHMarkdown`** (depends on LHCore and swift-markdown). It is pure, with no SwiftUI, and turns message text into a block model:
  - `MDBlock`: paragraph, heading, list, quote, alert callout, code fence, mermaid, display math, table, thematic break.
  - `MDInline` runs: text, emphasis, strong, code, link, inline math, line break.
  - It is fully unit-testable.
- **`LHWeb`** (depends on LHCore). It holds `WebRenderer`: one hidden, non-persistent WKWebView, used for:
  - mermaid → SVG → image snapshot;
  - figure SVG → image snapshot, with JavaScript off for figures.

  Results are cached by (source, width, appearance). It also holds `DiagramOverlayWebView`, the live overlay view.

**Entitlement:** `files.user-selected.read-only` becomes `read-write`, so Export can save through `NSSavePanel`.

## Markdown pipeline (port of `MessageResponse` + `md-blocks`)
**1. Text transforms.** Message text goes through `transformMathDelimiters` (M1, LHCore). Tool inputs shown in cards also go through `repairMathForDisplay` first, on exactly the surfaces TS uses.

**2. Math is split out before the markdown parse.**
- A code-aware scanner reuses the M1 `MathDelimiters` span logic.
- `$$…$$` flow blocks become display-math blocks.
- Inline `$…$` spans become private placeholder tokens. They are mapped back to `MDInline.math` after parsing, so cmark never sees TeX.

**3. Parsing.** swift-markdown parses with GFM (tables, strikethrough).
- A soft break renders as a line break, which ports remark-breaks. Code blocks and lists are unaffected.
- A `mermaid` fence becomes a mermaid block.
- A blockquote starting `[!NOTE|TIP|IMPORTANT|WARNING|CAUTION]` becomes an alert callout (port of `parseAlertMarker`), with the marker stripped. A standalone marker line drops its empty paragraph.

**4. SwiftMath rendering.**
- **Inline math** is drawn to an image embedded in `Text`, baseline-aligned and sized to the prose font.
- **Display math** is a centered block with a hover copy corner that copies the TeX.
- **Normalizations before SwiftMath:**
  - `\text{\textdollar}` → `\$`, so the escaped-dollar transform still renders a dollar.
  - Any other command SwiftMath lacks is listed in the M4 notes as found.
- **On a parse error**, the raw TeX shows in red mono. This mirrors KaTeX's `throwOnError:false` fallback.

**5. SwiftUI block renderer.**
- Each block is its own view; `Text` gets `.textSelection(.enabled)`.
- **Code fences:** Highlightr with line numbers and the `startLine=N` / `noLineNumbers` meta, plus a hover copy corner.
- **Inline code** is a muted pill. **Strong** is a real bold weight.
- **Tables:** a `Grid` that scrolls horizontally, with a hover copy corner that copies the table as Markdown.
- **Plain quotes:** a left rail, italic and muted.
- **Callouts:** a sharp outlined box hugging the content, with no label or icon.
- **Mermaid:** a spinner, then the cached image width-capped as in TS. The hover corner offers Copy (the source) and Expand. On failure, the error, the source and Retry (port of `MermaidError`).

## Transcript (port of chat.tsx 1316–1578)
- **Input:** `ChatRepository.observe(id)` → `projectView(record.messages)` → a `LazyVStack` in a `ScrollView` that opens at the bottom.
- **New LHCore ports for the view side:**
  - `phaseTimeline` over `ViewMessage` and `teachStepIndex` over `[ViewPart]`, ported from TS. Today Swift only has the native variants.
  - `latestTree`.
  - `formatUsd`, `formatTokens`, `prettyModel`, `timeAgo`.
  - `session-navigation` (`messageAnchorId`, `textPartMessageId`, `firstSourceTextParts`).
  - `session-find` (`findSessionTextMatches`, `stepSessionMatch`).
  - `pan-zoom` (`fitZoomFor`, `fitGraphView`, `zoomedGraphView`).
  - `PlanLayout`: the native layered layout, with rank by longest path, barycentric ordering and simple coordinate assignment.

**Every renderer from the inventory, with TS labels and order:**
- **Messages and dividers:**
  - the user band ("YOU", rail, plain text, no markdown);
  - assistant text;
  - Reasoning ("AGENT'S THINKING", collapsed);
  - the step separator;
  - PhaseDivider (Planning, and Teaching at the prepended or step position);
  - the compaction moment and cut dividers.
- **Marker cards:**
  - GraphContextCard;
  - the practice ThinkingCard ("YOUR THINKING");
  - the practice-next line.
- **Plan and question cards:**
  - PlanBlock, which opens the plan popup;
  - AnsweredCard, covering every eyebrow, chip, option state, confidence rail, "Why" toggle and the explain commit.
- **Tool cards:**
  - ProbeDoneCard;
  - ProblemCard;
  - ConcludeCard, with its METADATA popover; target names are resolved through `GraphRepository`;
  - ToolCallCard (read/ls/find/grep/list_*);
  - the "Retrying…" line.
- **Sub-agent steer cards:**
  - research and PDF one-liners with their briefs;
  - VisualOutputCard: the snapshot on a white backing, with invert, Download and Fullscreen. The invert toggle reads `message_ui` but stays read-only, because writing it is M5;
  - DemoOutputCard as a placeholder;
  - AbortedBadge.
- **Status:**
  - DispatchCard in its **settled form**, read from `JobRepository.findByToolCallId`: "✓ … delivered", "✗ … failed", or "Dispatched…" when there is no job;
  - the refusal line (your answer);
  - an assistant `stopReason:"error"` shows its partial content, as in TS.

**Not in M4:**
- LiveToolCard and the "THINKING…" / compacting placeholders: M5 (live).
- The ⌘T thinking toggle: M8 (keyboard). Rows toggle one at a time for now.

## Shell
- **Sidebar:**
  - A Search field (`fuzzyScore`; ↑/↓ walk the rows with wrap, Enter opens, Esc blurs; ⌘⇧F focuses it).
  - A Teaching / Practice / All segmented filter, saved in `@AppStorage`, default All.
  - Rows: the title, the meta line (`timeAgo`; the "waiting for input" and "problem waiting" states come from the summary), and the practice icon.
  - The empty and no-match states.
  - A right-click menu with **Export as Markdown…** only.
- **Toolbar:** the title is the navigation title. A **PLAN** button appears when `latestTree` exists. The phase label shows Probing/Planning/Teaching, or PRACTICE with the dumbbell.
- **Bottom status bar:**
  - Shows `ctx · cost`, from `contextWindow` and `sessionCost`.
  - Clicking it opens the SESSION STATS popover: context, total cost, unpriced turns, and the turns list with `prettyModel` and the step count.
  - It is hidden when the session has no turns.
- **Overlays:** these cover the detail column, with a dimmed and blurred backdrop.
  - **Plan popup:** a Canvas DAG with live `derivePlanStatuses` styling.
  - **Diagram / figure:** the live WKWebView.
  - **Shared behaviour:** pan and zoom through the ported pan-zoom math (wheel zooms to the cursor; drag pans only past the fit; zoom out / fit / zoom in; the "Drag to pan · scroll to zoom" hint). Esc closes. The plan popup also closes on a backdrop click and shows "No plan in this session yet." when there is no tree.
- **Find:**
  - ⌘F opens a bar under the toolbar: "Find in session…", the "i/N" count, ↑/↓ and ✕. Enter goes to the next match and ⇧Enter to the previous; Esc closes.
  - Edit-menu Find Next / Previous items (⌘G / ⇧⌘G) are added.
  - Matching is literal, case-insensitive and per block, over each block's displayed text with whitespace collapsed. Code keeps its literal whitespace.
  - Collapsed sections and math images aren't searched, as in TS.
  - Highlights are AttributedString backgrounds (25% accent for all matches, solid accent for the active one).
  - The active match scrolls to 16pt from the top.
- **Export:** Export as Markdown… opens an `NSSavePanel` named `<slug>.md`, writing `sessionMarkdown(messages, title:, anchors:false)`. An unsalvageable title falls back to `session`.
- **Anchors:** a `scrollTo(messageId:)` API with a 2-second highlight flash, the port of `SessionMessageNavigation`. M7's graph links call it.

## Specs ported
| TS spec | Swift test |
|---|---|
| `render-markdown` | LHMarkdown block-model tests. The delimiter transform cases are already in M1. The rest port: dollar math and legacy compatibility, line breaks, mermaid blocks, bold, escaped dollars, the over-escape heal. Each KaTeX DOM assertion becomes "this TeX reaches `MDInline.math` / display math and SwiftMath parses it without error". |
| `render-md-blocks` | Code, mermaid, tables, the display-math copy source, `codeSource`, callouts and `parseAlertMarker`, and plain quotes. Hover and DOM-geometry cases become view-model assertions or are dropped. |
| `repair-math-display` | The composition cases, which already pass, plus "card inputs go through `repairMathForDisplay` and record and history stay raw". |
| `session-find` | `findSessionTextMatches`, `stepSessionMatch`, and per-block display-text extraction. The DOM, highlight-API and foreground-layer cases are dropped. |
| `markdown-export` | Filename slug and fallback, empty-session header document, and anchorless output. |
| `pan-zoom` | All 9 cases. |
| `katex-security` | **Dropped**: there is no KaTeX. |
| Plan layout | New tests: every edge points to a lower rank, there are no overlaps, and the output is deterministic. |

## Acceptance
- **Golden chats:** importing the golden data dir renders both golden chats.
- **Every marker kind:** a Debug-only **Render Gallery** session, built from a synthetic record fixture checked into the tests, renders every marker kind, card and markdown construct listed above, including math, mermaid, callouts, tables and code.
- **Interactions:** find works on both of these, Export writes the file, and the plan popup and diagram overlay pan and zoom.
- **Checking:** I check this visually with screenshots of the running app, in light and dark.
- `xcodebuild test` and `swift test` are green.
- Then one commit, and I stop for review.

## Implementation notes (2026-10-24)
**Additions:**
- **LHMarkdown also depends on SwiftMath.** `mathParseError` is the shared validity check the renderer and the tests use.
- **LHCore gains:**
  - `viewPhaseTimeline` / `viewTeachStepIndex`. These are new names, because overloading the native ones was ambiguous on `[]`.
  - `latestTree`, `SessionFind`, `SessionNavigation`, `PanZoom`, `PlanLayout`.
  - `UsageFormat`: `formatUsd`, `formatTokens` with a JS-exact `toFixed`, `prettyModel`, `timeAgo`.
  - The two TS slugs: `slugFilename` and `sessionExportSlug`.
  - `QuestionAnswerData(json:)`.

**SwiftMath normalizations** (`normalizedTeX`):
- **Rewritten:**
  - `\tfrac` / `\dfrac` / `\cfrac` → `\frac`
  - `\lVert` / `\rVert` / `\lvert` / `\rvert`
  - `\varnothing`
  - `\implies` / `\impliedby`
  - `\dots`
  - `\iint` / `\iiint` / `\smallint`
  - `\longmapsto`
  - `\boldsymbol` / `\bm` → `\mathbf`
  - `\emph`
  - `\mathop`
  - `\Box`
  - `\:` / `\>`
  - `\operatorname{…}` / `\operatorname*{…}` → `\mathrm{…}`
  - `\pmod{…}`
  - `\tag{…}`
  - `\phantom{…}` (dropped)
  - `\hspace{…}` → `\quad`
  - the `\big` … `\Bigg` sizers (dropped)
  - `align(*)` → `aligned`
  - `gather(ed)` → `matrix`
  - `equation(*)` (unwrapped)
  - `\textdollar` → `\$`
- **Known gaps** (shown as red raw TeX):
  - `\underbrace`, `\overset` / `\underset` / `\stackrel`
  - `\xrightarrow`, `\overrightarrow`
  - `\boxed`, `\cancel`
  - the `array` environment and `\hline`
  - `\checkmark`, `\vdash`

  `MathTeXTests` pins both lists.

**Behaviour to know:**
- **Math colour:** math images are template images, so they take the surrounding text colour (muted, red).
- **Mermaid theme:** it follows the appearance: `default` in light, `dark` in dark. The TS app was dark-only.
- **Find** searches content: prose, user text, open thinking, card questions, options, verdicts and briefs. It does not search the chrome labels (YOU, CHECK…). A match scrolls its row into view near the top.
- **Plan diagram:** the arrowhead is a simplified barbed head, not the TS SVG path. Long edges route through dummy-node waypoints.
- **`prettyModel` is a faithful port**, so it drops a trailing all-digit dash segment. `claude-opus-5-5` therefore shows as `claude-opus-5` in SESSION STATS.

**Debug-only launch arguments:**
- `-LHScratch YES` runs on a throwaway database in the container's temp folder.
- Adding `-LHOpenGallery YES` also opens the Render Gallery.
- **Debug → Add Render Gallery Session** inserts the gallery into the current database.

**Tests:**
- **Hosted tests** (LearnHarnessTests):
  - the gallery carries every marker kind and every row kind;
  - both golden chats (bundled as test resources) build and render offscreen;
  - mermaid and figure snapshots render with ink in both themes;
  - Find skips collapsed sections;
  - anchors resolve;
  - the sidebar's filter, ranking and meta work.
- **Not done:** I could not take screenshots: this session has no screen-capture or computer-use access. The visual check of the running app, in light and dark, is yours.
