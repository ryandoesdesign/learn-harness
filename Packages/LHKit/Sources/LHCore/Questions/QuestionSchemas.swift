import Foundation

// The tool INPUT contracts of src/core/question-core.ts (and probe_done's
// from src/core/contracts/probe.ts). Parameter names AND order mirror the
// prompt docs: models emit args in schema order, so the order is authoring
// guidance (reasoning before the pick; the teach pair `type`, `nodeId` first).

/// One quiz answer option. Owner ruling (2026-09-26): NO `description` — the
/// model used it to leak correctness. The option is a bare claim.
private let quizOptionProperties: [JSONSchema.Property] = [
	.init("label", .string(description: "Display label for the answer option — a bare claim, no reasoning")),
	.init("value", .string(description: "Optional machine-readable value returned for the option. Defaults to the label.").optional()),
]

/// One ask answer option — keeps `description` (ask is ungraded).
private let askOptionProperties: [JSONSchema.Property] = quizOptionProperties + [
	.init("description", .string(description: "Optional extra detail shown below the option").optional()),
]

private let detailsSchema = JSONSchema.string(description:
	"Optional, a line at most: HOW to answer — the format or shorthand you'll accept (e.g. \"Shorthand is fine: " +
	"'1 H/H – because…'\"). Never teaching: cards, reference lists, definitions, recaps and explanations go in " +
	"your reply's visible text, above the question.").optional()

/// The reply he reads before the question, verbatim (Claude Opus 5.5 returns
/// longer text written before a tool call as a thinking block he never sees).
/// First in every question tool.
private let messageProperty = JSONSchema.Property("message", .string(description:
	"Your reply to him, shown as your normal message above the question: feedback on his last answer, the " +
	"teaching or working that leads into it, anything he reads before answering. Write it here, not as text " +
	"before the call: text before a tool call can be hidden from him.").optional())

private let nodeIdSchema = JSONSchema.string(description:
	"REQUIRED plan-tree node id this question is about — must EXACTLY match one of this session's " +
	"plan_init node slugs (validated at call time; a mismatched id is rejected back to you). " +
	"The lesson's position on the map derives from these tags (the node the latest tagged question is about is " +
	"where the map stands; earlier ones count as visited). A node takes as many questions as it deserves: stay on " +
	"one node for as many turns as the understanding needs — one reasoning step at a time, never rush forward. " +
	"For off-map checks use ask_user_question.")

/// The SHARED quiz authoring fields — everything except the message and the
/// teach pair. The explanation sits immediately BEFORE correctAnswer (owner,
/// 2026-09-25).
private let quizFields: [JSONSchema.Property] = [
	.init("question", .string(description:
		"The single quiz question to ask. ONE question per turn: ask, then end your turn — the answer determines the next question.")),
	.init("options", .array(.object(properties: quizOptionProperties), minItems: 2, description:
		"REQUIRED. The answer options (2 or more) as a JSON ARRAY of option objects — never a " +
		"JSON-encoded string. Options only — there is no free-text mode. " +
		"Give each option a stable `value`; you reference the correct one by that value in correctAnswer. " +
		"Never add your own 'I don't know' option — that choice is added for you.")),
	.init("multiSelect", .boolean(description:
		"Set to true when more than one option is correct and the learner must select all of them.").optional()),
	.init("explanation", .string(description:
		"REQUIRED. Explanation revealed AFTER the learner answers (shown whether they got it right or wrong). " +
		"Use it to reinforce why the correct answer is correct. It is written BEFORE correctAnswer by design: " +
		"reason it out first, then commit the answer the reasoning supports.")),
	.init("correctAnswer", .union([.string(), .array(.string())], description:
		"REQUIRED. The correct answer as the option value(s) — the `value` field of the option you intend. " +
		"Single-select: a single string (e.g. \"mercury\"). Multi-select: an array of strings (e.g. [\"belize\", \"niue\"]); " +
		"the learner is only correct if their selection matches this set exactly. " +
		"Always pass the value, not a position number — this is self-checking and prevents miscounting. " +
		"A value that matches no option fails validation and the call is returned to you to fix.")),
	.init("details", detailsSchema),
]

/// The probe-side quiz fields: the message, then the shared fields.
public let quizInputBase = JSONSchema.object(properties: [messageProperty] + quizFields)

/// The teaching-cycle role, shared VERBATIM by both teach quizzing tools.
/// Bare words, never quoted (the quote-copy wobble).
private let predictCheckType = JSONSchema.union([.literal("predict"), .literal("check")], description:
	"REQUIRED — the question's role in the teaching cycle, as a bare word (no quotes): predict = posed BEFORE " +
	"you teach the step (its own turn; the learner answers, then your teaching resolves it — arrives open, never " +
	"collapsed); check = posed AFTER the step's teaching is complete (arrives collapsed behind the Check your " +
	"understanding reveal). ONE question per turn either way.")

/// The TEACH-side quiz: the message, then the required pair (glm-5.3 dropped
/// trailing required fields), then the shared fields.
public let quizInputObject = JSONSchema.object(properties: [
	messageProperty,
	.init("type", predictCheckType),
	.init("nodeId", nodeIdSchema),
] + quizFields)

/// The TEACHER's quiz declaration.
public let quizInputSchema = quizInputObject

/// The PROBE-side quiz: the shared base, no nodeId and no `type`.
public let probeQuizInputSchema = quizInputBase

/// The DISPLAY parse for persisted quiz calls: base + `type` as an OPTIONAL
/// plain string (old records carry none; Clean keeps only known keys).
public let quizDisplayInputSchema = JSONSchema.object(properties: quizInputBase.properties + [
	.init("type", JSONSchema.string().optional()),
])

/// The explain tool (free-recall quizzing): ONE committed answer, reasoning
/// included, committed before the learner sees the question.
private let explainFields: [JSONSchema.Property] = [
	.init("question", .string(description:
		"The single question to ask. ONE question per turn: ask, then end your turn — the answer determines the next.")),
	.init("correctAnswer", .string(description:
		"REQUIRED. The full correct answer in your own words, reasoning included — COMMITTED before the learner " +
		"ever sees the question. The commitment is immutable: when his answer returns, grade it strictly against this " +
		"text — never revise the commitment after seeing his words, and never mark a wrong answer right to be kind. " +
		"It is shown to him on submit; your next reply grades the nuance of what he wrote.")),
	.init("details", detailsSchema),
]

public let explainInputBase = JSONSchema.object(properties: [messageProperty] + explainFields)

/// The TEACH-side explain: the role + position pair leads, as for quiz.
public let explainInputObject = JSONSchema.object(properties: [
	messageProperty,
	.init("type", predictCheckType),
	.init("nodeId", nodeIdSchema),
] + explainFields)

/// The DISPLAY parse for persisted explain calls (the quiz display pattern).
public let explainDisplayInputSchema = JSONSchema.object(properties: explainInputBase.properties + [
	.init("type", JSONSchema.string().optional()),
])

/// ask_user_question's optional plan tag: the map follows tagged asks too.
private let askNodeIdSchema = JSONSchema.string(description:
	"Optional plan-tree node id this question works on — an exercise or open question on that step. Must EXACTLY " +
	"match one of this session's plan_init node slugs (validated at call time; a mismatched id, or one sent before " +
	"there's a plan, is rejected back to you). Tag it so the map follows the lesson; leave it out for questions off " +
	"the map (preferences, logistics).").optional()

/// ask_user_question: no `mode` — inferred from whether options are present.
public let askInputSchema = JSONSchema.object(properties: [
	messageProperty,
	.init("nodeId", askNodeIdSchema),
	.init("question", .string(description:
		"The single question to ask the learner. ONE question per turn: ask, then end your turn — the answer determines the next question.")),
	.init("details", detailsSchema),
	.init("options", JSONSchema.array(.object(properties: askOptionProperties), minItems: 2, description:
		"Optional multiple-choice options. Omit for free-form text input. " +
		"The learner can always choose 'Other' and type a custom answer when options are provided.").optional()),
	.init("multiSelect", JSONSchema.boolean(description: "Set to true to allow multiple answers to the same question.").optional()),
])

/// probe_done's input (contracts/probe.ts) — the single source of truth for
/// the tool and the parse seam alike.
public let probeDoneInputSchema = JSONSchema.object([
	"assessment": .object([
		"strands": .array(.object([
			"strand": .string(description:
				"The dependency strand (e.g. 'the derivative as a limit') — a name the plan can hang a node on."),
			"assessment": .string(description:
				"Where his edge sits on this strand: the floor (what he reliably gets right), the ceiling (where it runs out), " +
				"misconceptions found, and what the lesson should build from."),
		]), minItems: 1, description: "Every strand the planned lesson will depend on, each with your read of his edge on it."),
		"summary": JSONSchema.string(description: "Optional overall synthesis: his apparent goal and where the teaching should enter.").optional(),
	], description: "The learner assessment — the probe's distilled output."),
])
