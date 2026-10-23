# M1 design: scaffold + LHCore

This adds detail to `native-macos-plan.md`. It covers M1 only.

## Your answers (2026-10-24)
| Question | Answer |
|---|---|
| Xcode project | XcodeGen `macos/project.yml` is the source of truth. The generated `.xcodeproj` is committed too. |
| models.json | Current Anthropic models only: Opus 5.5, Sonnet 5.5, Haiku 5.5, Fable 5, Fable 5.1. Every other model is unpriced ("—"). |
| Message record | Anthropic-native content blocks, stored verbatim. LHCore ships the pure pi→Anthropic conversion. |
| Slot defaults | Factory defaults: Strong = `claude-opus-5-5`, Cheap = Vision = `claude-sonnet-5-5`. |
| Default effort | `high`. Fable is clamped to `xhigh`. |
| Appearance | Dropped entirely. The app uses the pure system look. |

## Scaffold
- `macos/project.yml` defines:
  - the `LearnHarness` app: macOS 27.0, Swift 6 language mode, complete strict concurrency, App Sandbox on, team `5U34MG28NQ`, bundle id `com.ryandoesdesign.LearnHarness`;
  - the `LearnHarnessTests` hosted test target;
  - the `LearnHarness` scheme, which also runs the LHKit package tests.
- `macos/Packages/LHKit/Package.swift` (tools 6.x, `.macOS(.v27)`) has **only `LHCore`** and `LHResources` (holding `models.json`) in M1. The other targets are added in the milestones that need them. M1 has no external packages.
- The app shows an empty `NavigationSplitView` (a sidebar plus a "No session" placeholder).

## The message record (LHCore `Message`)
| Field | Content |
|---|---|
| All rows | `id`, `timestamp` (ms) |
| Role | `user` · `assistant` · `toolResult` · `marker` (one per pi role; `custom` becomes `marker`) |
| `user` | `content: [Block]` (text, image) |
| `assistant` | `content: [Block]`, `model` (a bare id; foreign ids keep their `provider:id`), `stopReason` |
| `toolResult` | `toolUseId`, `toolName`, `content: [Block]`, `isError`, `details: JSONValue?` (the UI payload, never sent to the model) |
| `marker` | `customType` (the same 9 kinds), `content` (the model-facing text), `details` |

- **Blocks** keep the raw `JSONValue` and expose typed views (`text`, `thinking`, `redactedThinking`, `toolUse`, `serverToolUse`, `image`, and unknown blocks passed through). The stored bytes are always the original ones.
- **pi→Anthropic conversion** (`LegacyRecordConversion`, pure):
  - `toolCall{id,name,arguments}` becomes `tool_use{id,name,input}`.
  - pi `thinking` from provider `anthropic` with a signature becomes `thinking{thinking,signature}`.
  - Any other thinking becomes `thinking{thinking}` with no signature. It still shows in the UI, and M3's WireProjection drops unsigned thinking.
  - `image{data,mimeType}` becomes `image{source:{type:base64,…}}`.
  - Model stamps become bare ids for `anthropic`; other providers keep `provider:id`.
- **Golden tests** run the conversion over the golden chats before the Swift folds run.

## Settings (LHCore `UserSettings`, delta record, unknown keys preserved)
| Section | Status |
|---|---|
| `models` | Kept: `strong`/`cheap`/`vision` → `{model?: String, effort?: Effort}` |
| `agent.models` | Kept: per-background-role overrides |
| `agent.tools`, `agent.prompts`, `agent.graphTools` | Kept |
| `graph` | Kept: `{enabled, rendering, extractionChunkTokens}` |
| `compaction` | Kept: `{thresholdTokens}` |
| `general` (autoUpdate) | Dropped: there is no updater |
| `appearance` | Dropped |
| `agent.search` | Dropped: the server tools replace Tavily/Brave |
| `modelsNotConfigured` / `slotsConfigured` | Dropped: factory defaults exist |
| `ProviderKeyMissing` | Becomes the single "No Anthropic key" refusal |

- **`Effort`** is `low | medium | high | xhigh | max`. A level the model doesn't support clamps to the nearest supported one, rounding upward (Fable: anything → `xhigh`/`max`).
- **Bug fix, not ported:** the TS sanitizer only sanitizes `compaction` when a `graph` section is present (settings.ts:619). The Swift version sanitizes it on its own.
- **Unknown model ids** in slots resolve, but are unpriced and have no context window.

## models.json
These 5 entries come from pi-ai's `anthropic.json`:
- `id`, `name`
- `contextWindow` (1M) and `maxTokens` (128k)
- `input` modalities
- the supported effort levels
- the price, including Haiku 5.5's tier above 100k input.

**Price folds:** `callCost` applies the tier when a call's input exceeds 100k. The TS code ignores tiers, but none of the golden usage is Anthropic, so parity is unaffected.

## Ported in M1
**Core:**
- `contracts` (plan, graph, chat, jobs, probe)
- `question-core`, `plan-tree`, `plan-blocks`, `phases`
- `pending`: the native parts only. The UIMessage-era `findPendingToolCall` and `streamingToolActivity` die.
- the native-messages **scans and constructors**: `danglingQuestionOf`, `needsContinuation`, `activeProblemOf` and friends. `toLlmMessages` is M3.

**Graph:**
- `graph` (merge, simplify, derive, snapshot, session index), behind Swift `GraphStore`/`ChatStore` protocols (from `ports.ts`)
- `chains`, `session-clusters`, `clusters`, `layout`, `layout-settle`, `coverage`

**Everything else:**
- `compaction`, `cost-summary` + prices, `settings` + `settings-resolution`
- `math-delims`, `session-markdown`, `view`
- `fuzzy`, `value-debris`, `argument-heal`, `tool-parts`

**Deferred to their milestones:**
- `auth-keys` (M2 Keychain)
- `native-messages.toLlmMessages`, `events` (M3)
- `input-events`, `prompt-segments` (M5)
- `render-settings`, `graph-deletion` (M7)
- `keyboard` (M8)
- `session-find`, `session-navigation` (M4)

**Dropped:** `search`.

## Technique
- **Schemas:** typebox schemas become Swift `JSONSchema` values. A small in-house validator covers the subset in use (type, properties, required, items, minItems, enum, anyOf, additionalProperties). The same value is sent to the API in M3.
- **Layout:** a faithful port of the d3-force functions in use (d3's LCG, phyllotaxis initial placement, alpha/velocity decay, Barnes-Hut many-body with θ=0.9, link and x/y/radial forces), using `SIMD2<Double>`. Parity tolerance is 1e-6.
- **Regex** (math-delims, heal): Swift `Regex`, checked case by case against the TS outputs.
- **Hashing:** CryptoKit SHA-256, the same digests as node `createHash`.
- **Golden parity:** `scripts/dump-core-golden.ts` (run via `npx tsx`) runs the TS functions over `tests/fixtures/golden-data` and writes `macos/Packages/LHKit/Tests/LHCoreTests/Golden/*.json`. Those dumps are committed, and the Swift tests compare against them.
- **Spec tests:** the TS tests named in the plan are ported case by case to Swift Testing, except cases for deferred or dropped behaviour.

## Acceptance
- `xcodebuild test … -scheme LearnHarness` is green.
- `swift test --package-path macos/Packages/LHKit` is green.
- The app launches to the empty split view.
- Then one commit on `native-macos`, and I stop for your review.
