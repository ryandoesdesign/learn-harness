import { Type } from "typebox";
import { Value } from "typebox/value";
import type { TSchema } from "typebox";
import { chat, plain, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import {
	askInputSchema,
	askOptionProblems,
	buildAnswer,
	coerceCorrectAnswer,
	compactAnswerForModel,
	dismissedAnswer,
	explainDisplayInputSchema,
	explainInputBase,
	explainInputObject,
	explainInputProblems,
	normalizeOptions,
	normalizeQuizType,
	probeQuizInputSchema,
	questionNeedsReveal,
	quizDisplayInputSchema,
	quizInputBase,
	quizInputObject,
	quizInputProblems,
	resolveCorrect,
	seededRandom,
	shuffleOptions,
	toClientQuestion,
	type AnswerRequest,
	type QuestionAnswerData,
	type QuestionData,
	type QuestionMode,
	type QuizOption,
} from "../../src/core/question-core.ts";
import { parseAskInput, parseExplainInput, parseProbeDoneInput, parseQuizInput } from "../../src/core/tool-parts.ts";
import { healEncodedArguments } from "../../src/core/argument-heal.ts";
import { stripModelValueDebris } from "../../src/core/value-debris.ts";
import { probeDoneInputSchema } from "../../src/core/contracts/probe.ts";
import { toolQuestionKind } from "../../src/core/pending.ts";
import { newAnswerResult } from "../../src/core/native-messages.ts";

/** The answered-at stamp every rebuilt answer carries (buildAnswer reads
 *  the clock; the Swift port takes it as `now`). */
const ANSWERED_AT_MS = 1791626469187;

/** A synthetic schema covering the heal/convert kinds the tool schemas
 *  don't (null, number, integer, literal ∪ null, additionalProperties). */
const healSchema = Type.Object(
	{
		mode: Type.Union([Type.Literal("recall"), Type.Literal("apply")]),
		maybe: Type.Union([Type.Literal("a"), Type.Null()]),
		flag: Type.Boolean(),
		n: Type.Number(),
		i: Type.Integer(),
		list: Type.Array(Type.String()),
		bare: Type.Literal(3),
		nothing: Type.Null(),
	},
	{ additionalProperties: false },
);

const SCHEMAS: Record<string, TSchema> = {
	quizInputBase,
	quizInputObject,
	probeQuizInputSchema,
	quizDisplayInputSchema,
	explainInputBase,
	explainInputObject,
	explainDisplayInputSchema,
	askInputSchema,
	probeDoneInputSchema,
	healSchema,
};

const PARSERS: Record<string, (input: unknown) => unknown> = {
	quiz: parseQuizInput,
	probe: parseQuizInput,
	ask_user_question: parseAskInput,
	explain: parseExplainInput,
	recall: parseExplainInput,
	probe_done: parseProbeDoneInput,
};

const QUOTED = (v: string) => `"${v}"`;
const PROBER = {
	question: "Which planet is closest to the sun?",
	options: [{ label: "Venus" }, { label: "Mercury" }],
	correctAnswer: "Mercury",
	explanation: "Mercury is the innermost planet.",
};
const WHITEHEAD = {
	question: "What was Parmenides' claim?",
	options: [
		{ label: "Being is changeless and complete", value: "parmenides" },
		{ label: "Becoming is fundamental", value: "heraclitus" },
	],
	explanation: "The flux is appearance.",
	correctAnswer: [":parmenides"],
	type: QUOTED("predict"),
	nodeId: "experience-first",
};
const ASSESSMENT = {
	assessment: {
		strands: [{ strand: "modal logic", assessment: "Floor: intuition." }],
		summary: "Teach the symbols.",
	},
};

/** Hand-made parse inputs beyond the golden chats: every coercion branch. */
const SYNTHETIC: Array<{ tool: string; input: unknown }> = [
	{ tool: "quiz", input: PROBER },
	{ tool: "quiz", input: { ...PROBER, nodeId: "n", type: "check", extra: 1 } },
	{ tool: "quiz", input: { ...PROBER, options: JSON.stringify(PROBER.options) } },
	{ tool: "quiz", input: { ...PROBER, options: [{ label: "17", value: "17" }, { label: "27" }], correctAnswer: 17 } },
	{ tool: "quiz", input: { ...PROBER, options: [{ label: "17" }, { label: "27" }], multiSelect: true, correctAnswer: [17, "27"] } },
	{ tool: "quiz", input: { ...PROBER, correctAnswer: { bad: true } } },
	{ tool: "quiz", input: { ...PROBER, multiSelect: "true", correctAnswer: ["Venus", "Mercury"] } },
	{ tool: "quiz", input: { ...PROBER, multiSelect: "1", correctAnswer: '["Venus", "Mercury"]' } },
	{ tool: "quiz", input: { ...PROBER, question: 42, explanation: null } },
	{ tool: "quiz", input: { ...PROBER, question: 1.5e21, explanation: true } },
	{ tool: "quiz", input: { ...PROBER, options: [{ label: "A", description: "leak" }, { label: "B", value: " b " }], correctAnswer: "b" } },
	{ tool: "quiz", input: { ...PROBER, options: [{ label: "A" }] } },
	{ tool: "quiz", input: { ...PROBER, options: { label: "A" } } },
	{ tool: "quiz", input: { ...PROBER, correctAnswer: "nope" } },
	{ tool: "quiz", input: { ...PROBER, correctAnswer: ' "Mercury": ' } },
	{ tool: "quiz", input: WHITEHEAD },
	{ tool: "quiz", input: "a string" },
	{ tool: "quiz", input: [PROBER] },
	{ tool: "quiz", input: null },
	{ tool: "ask_user_question", input: { question: "What do you want to learn?" } },
	{ tool: "ask_user_question", input: { question: "Which?", options: [{ label: "A", description: " d " }, { label: "B" }], multiSelect: true } },
	{ tool: "ask_user_question", input: { question: "q", options: "[]" } },
	{ tool: "ask_user_question", input: { question: "q", options: [{ label: "A", value: "x" }, { label: "B", value: "x" }] } },
	{ tool: "ask_user_question", input: { question: "q", options: [{ label: "A" }] } },
	{ tool: "ask_user_question", input: { question: "q", details: 7, multiSelect: 0 } },
	{ tool: "explain", input: { question: "q", correctAnswer: "a", nodeId: "n", type: "predict" } },
	{ tool: "explain", input: { question: "q", correctAnswer: 42 } },
	{ tool: "explain", input: { question: "q", correctAnswer: "   " } },
	{ tool: "explain", input: { question: "q", correctAnswer: { nested: true } } },
	{ tool: "explain", input: { explanation: "e", correctAnswer: "a" } },
	{ tool: "probe_done", input: ASSESSMENT },
	{ tool: "probe_done", input: { assessment: JSON.stringify(ASSESSMENT.assessment) } },
	{ tool: "probe_done", input: { assessment: { summary: "…" } } },
	{ tool: "probe_done", input: { assessment: { strands: [] } } },
	{ tool: "probe_done", input: { assessment: { strands: { strand: "s", assessment: "a" }, extra: true } } },
	{ tool: "probe_done", input: { assessment: { strands: [{ strand: 1, assessment: false, x: 1 }] } } },
];

/** The dock's QuestionData construction (components/question-dock.tsx),
 *  over the PARSED input. */
function questionDataFor(tool: string, toolCallId: string, input: Record<string, unknown>): QuestionData {
	const kind = toolQuestionKind(tool);
	const multi = "multiSelect" in input ? input.multiSelect === true : false;
	const opts = (input.options as { label: string; value?: string }[] | undefined) ?? [];
	const mode: QuestionMode =
		kind === "quiz" ? (multi ? "multi-select" : "single-select") : kind === "ask" && opts.length ? (multi ? "multi-select" : "single-select") : "text";
	const options = normalizeOptions(kind === "explain" ? [] : opts);
	const ordered = kind === "quiz" && options.length > 0 ? shuffleOptions(options, seededRandom(toolCallId)) : options;
	const qd: QuestionData = {
		id: toolCallId,
		kind,
		questionType: kind === "quiz" ? normalizeQuizType(input.type) : undefined,
		question: input.question as string,
		context: input.details as string | undefined,
		mode,
		options: ordered,
		createdAt: "2026-01-01T00:00:00.000Z",
	};
	if (kind === "quiz") {
		qd.correctIndices = resolveCorrect(input.correctAnswer as string | string[], ordered).indices;
		qd.explanation = input.explanation as string;
	}
	if (kind === "explain") qd.committedAnswer = input.correctAnswer as string;
	return qd;
}

/** The AnswerRequest a recorded answer implies. */
function requestFrom(d: QuestionAnswerData): AnswerRequest {
	return {
		dontKnow: d.dontKnow,
		values: (d.answers ?? []).map((a) => a.value),
		other: d.other,
		text: d.text,
		thinking: d.thinking ?? d.note,
		readingThinking: d.readingThinking,
		confidence: d.confidence,
	};
}

type Block = { type: string; id?: string; name?: string; arguments?: unknown };
type Msg = { role: string; content: Block[]; toolCallId?: string; toolName?: string; details?: unknown; isError?: boolean };

export default () => {
	// 1. parse rows over every golden question call + the synthetic set
	const chatRows: unknown[] = [];
	const answerRows: unknown[] = [];
	for (const id of [TEACH_CHAT, PRACTICE_CHAT]) {
		const messages = chat(id).messages as Msg[];
		for (const m of messages) {
			if (m.role !== "assistant") continue;
			for (const b of m.content) {
				if (b.type !== "toolCall" || !PARSERS[b.name!]) continue;
				const parsed = PARSERS[b.name!]!(b.arguments);
				chatRows.push({ chatId: id, toolCallId: b.id, tool: b.name, parsed: parsed ?? null });
				const result = messages.find((r) => r.role === "toolResult" && r.toolCallId === b.id);
				const d = result?.details as QuestionAnswerData | undefined;
				if (!parsed || b.name === "probe_done" || result?.isError || !d || typeof d.kind !== "string") continue;
				const qd = questionDataFor(b.name!, b.id!, parsed as Record<string, unknown>);
				const answer = { ...buildAnswer(qd, requestFrom(d), b.name), answeredAt: new Date(ANSWERED_AT_MS).toISOString() };
				const res = newAnswerResult(b.id!, b.name!, d);
				answerRows.push({
					chatId: id,
					toolCallId: b.id,
					tool: b.name,
					client: toClientQuestion(qd),
					answer,
					compact: compactAnswerForModel(answer),
					compactRecorded: compactAnswerForModel(d),
					resultText: (res.content[0] as { text: string }).text,
				});
			}
		}
	}
	const syntheticRows = SYNTHETIC.map(({ tool, input }) => ({ tool, input, parsed: PARSERS[tool]!(input) ?? null }));

	// 2. heal rows
	const healCases: Array<{ schema: string; args: unknown }> = [
		{ schema: "quizInputObject", args: { type: QUOTED("predict") } },
		{ schema: "quizInputObject", args: { type: "predict", multiSelect: "true", options: JSON.stringify(PROBER.options) } },
		{ schema: "quizInputObject", args: { type: "\"bogus\"", multiSelect: "yes", options: "not json", correctAnswer: '["a"]' } },
		{ schema: "quizDisplayInputSchema", args: WHITEHEAD },
		{ schema: "askInputSchema", args: { options: "{}", multiSelect: "false" } },
		{ schema: "healSchema", args: { mode: '"recall"', maybe: "null", flag: "false", n: "1.50", i: "7", list: '["x"]', bare: "3", nothing: "null" } },
		{ schema: "healSchema", args: { mode: "recall", maybe: '"a"', flag: "1", n: "x", i: '"7"', list: "[1", bare: "4" } },
		{ schema: "healSchema", args: "not an object" },
		{ schema: "healSchema", args: [1, 2] },
	];
	const healRows = healCases.map((c) => ({ ...c, healed: healEncodedArguments(c.args, SCHEMAS[c.schema] as never) }));

	// 3. Value.Check / Convert / Clean over the schemas
	const values: unknown[] = [
		null, true, 0, 1, 17, 1.5, "", "x", "true", "0", "null", [], ["a"], [1, "b"], {}, { label: "L" },
		PROBER, { ...PROBER, nodeId: "n", type: "predict" }, { ...PROBER, type: "nope", nodeId: "n" }, WHITEHEAD, ASSESSMENT,
		{ mode: "apply", maybe: null, flag: false, n: 2, i: 3, list: [], bare: 3, nothing: null },
		{ mode: "apply", maybe: "a", flag: 1, n: "2", i: 3.7, list: "solo", bare: "3", nothing: 0, extra: 1 },
		{ mode: 1, maybe: false, flag: 5, n: [], i: "x", list: [{}], bare: true, nothing: 7 },
		{ question: "q", correctAnswer: "a" }, { question: "q", options: [{ label: "A", description: "d" }, { label: "B" }] },
	];
	const valueRows = Object.entries(SCHEMAS).flatMap(([schema, s]) =>
		values.map((value) => {
			const converted = structuredClone(value);
			const c = Value.Convert(s, converted);
			return {
				schema,
				value,
				check: Value.Check(s, value),
				converted: c ?? null,
				clean: Value.Clean(s, structuredClone(c)) ?? null,
			};
		}),
	);

	// 4. debris / coercion / problems / reveal
	const debris = [":parmenides", QUOTED("predict"), ': "primary-external" ', "`value`", "a:b", '["x"]', "  .:x. ", "...", "", "﻿y　"];
	const coerceCases: Array<[string | string[], string[]]> = [
		["mercury", ["mercury"]], [["a", "b"], ["a"]], ['["a", "b"]', []], ["[not json", []], ['["a", "b"]', ['["a", "b"]']],
		["[]", ["[]"]], ["[]", []], [[":parmenides"], ["parmenides"]], ['[1, true, null, [1, null], {"a":1}, 1.0, 1e21]', []],
		[" value. ", ["value."]], [" value. ", []], ['  [" x ", ":y"]  ', ["x"]],
	];
	const optionSets = [
		[{ label: "Venus" }, { label: "Mercury" }, { label: "Mars" }],
		[{ label: "A", value: "a" }, { label: "B", value: "b" }, { label: "C", value: "c" }],
		[{ label: "  " }, { label: "x", value: " " }, { label: "x" }],
		[{ label: "A", value: "same" }, { label: "B", value: "same" }],
	];
	const problemRows = optionSets.flatMap((options) =>
		([["Mercury"], "Mercury", "", "[]", ["a", "b"], '["a","b"]', "x", ["a", "a"]] as Array<string | string[]>).flatMap((correctAnswer) =>
			[undefined, true].map((multiSelect) => ({
				options,
				correctAnswer,
				multiSelect: multiSelect ?? null,
				problems: quizInputProblems({ options, correctAnswer, multiSelect }),
				askProblems: askOptionProblems(options),
			})),
		),
	);
	const resolveRows = coerceCases.map(([answer]) => {
		const options = normalizeOptions([{ label: "a" }, { label: "b" }, { label: "x" }, { label: "parmenides" }, { label: "value." }]);
		return { answer, ...resolveCorrect(answer, options) };
	});
	const reveal = (["quiz", "explain", "probe", "ask_user_question"] as const).flatMap((tool) =>
		[undefined, { type: "check" }, { type: "predict" }, { type: '"predict"' }, { type: 7 }, "raw"].flatMap((input) =>
			["teach", "probe", "plan"].map((phase) => ({ tool, input: input ?? null, phase, reveal: questionNeedsReveal(tool, input, phase) })),
		),
	);

	// 5. the seeded shuffle
	const seeds = ["", "a", "call_abc", "chat_mv27rrra_feff23b6", "ünï🙂", "call_b55e75640e3a414f801b2dcb0e0a8bfd"];
	const six: QuizOption[] = ["a", "b", "c", "d", "e", "f"].map((v) => ({ label: v.toUpperCase(), value: v }));
	const random = seeds.map((seed) => {
		const r = seededRandom(seed);
		return { seed, sequence: Array.from({ length: 12 }, () => r()), shuffled: shuffleOptions(six, seededRandom(seed)).map((o) => o.value) };
	});

	// 6. option normalization over raw shapes
	const normalizeCases: unknown[] = [
		[{ label: "  Mercury  " }, { label: "Venus", value: " v " }, { label: "", value: "x" }, { label: "D", description: " d " }],
		JSON.stringify([{ label: "Slope", value: "slope" }]),
		"not json",
		[{ label: "a", value: "x" }, { label: "b", value: "x" }],
		undefined,
	];
	const normalizeRows = normalizeCases.map((options) => {
		try {
			return { options: options ?? null, normalized: normalizeOptions(options as never) };
		} catch (e) {
			return { options: options ?? null, error: (e as Error).message };
		}
	});

	return {
		"questions.schemas": plain(SCHEMAS),
		"questions.parse": plain({ chat: chatRows, synthetic: syntheticRows }),
		"questions.answers": plain({ answeredAtMs: ANSWERED_AT_MS, rows: answerRows, dismissed: { ...dismissedAnswer("ask", "Skip me?"), answeredAt: new Date(ANSWERED_AT_MS).toISOString() } }),
		"questions.heal": plain({ rows: healRows }),
		"questions.values": plain({ rows: valueRows }),
		"questions.grading": plain({
			debris: debris.map((value) => ({ value, stripped: stripModelValueDebris(value) })),
			coerce: coerceCases.map(([answer, values]) => ({ answer, values, coerced: coerceCorrectAnswer(answer, values) })),
			problems: problemRows,
			explainProblems: ["Full speed is c.", "   ", ""].map((correctAnswer) => ({ correctAnswer, problems: explainInputProblems({ correctAnswer }) })),
			resolve: resolveRows,
			quizType: [QUOTED("predict"), "check", ": check.", "prediction", "", 42, null].map((raw) => ({ raw, type: normalizeQuizType(raw) ?? null })),
			reveal,
			normalize: normalizeRows,
		}),
		"questions.random": plain({ rows: random }),
	};
};
