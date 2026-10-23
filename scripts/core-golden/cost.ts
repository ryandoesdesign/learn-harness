import { chat, plain, readJson, readJsonl, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import { readdirSync } from "node:fs";
import path from "node:path";
import { GOLDEN } from "./_fixtures.ts";
import { fuzzyScore } from "../../src/core/fuzzy.ts";
import { graphCostSummary } from "../../src/core/cost-summary.ts";
import { PRICES, contextWindow, jobCost, sessionCost, sumSteps, turnCost } from "../../src/core/prices.ts";
import type { CallUsage, ExtractionRunUsage, JobRecord, TurnUsage } from "../../src/core/contracts.ts";

/** The context window the dump's limits index gives every golden model
 *  (the Swift test builds its catalog with the same number). */
const GOLDEN_CONTEXT_WINDOW = 131_072;

/** Hand-picked (query, fields) pairs: the fuzzy.test.ts shapes, picker-like
 *  rows over the native catalog, and edge cases (whitespace, case, depth
 *  penalty cap, non-ASCII). */
const PAIRS: Array<[string, string[]]> = [
	["GLM", ["openrouter", "z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash"]],
	["flash", ["openrouter", "z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash"]],
	["glm flash", ["openrouter", "z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash"]],
	["glm qwen", ["openrouter", "z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash"]],
	["glm 5.3", ["openrouter", "z-ai/glm-5.3-flash", "x"]],
	["flash", ["openrouter", "flash", "other"]],
	["flash", ["openrouter", "flash-2", "other"]],
	["", ["anything"]],
	["   ", ["anything"]],
	["opus", ["claude-opus-5-5", "Claude Opus 5.5"]],
	["claude opus", ["claude-opus-5-5", "Claude Opus 5.5"]],
	["Claude Opus 5.5", ["claude-opus-5-5", "Claude Opus 5.5"]],
	["5.5", ["claude-haiku-5-5", "Claude Haiku 5.5"]],
	["fable 5.1", ["claude-fable-5-1", "Claude Fable 5.1"]],
	["  sonnet\t5.5 ", ["claude-sonnet-5-5", "Claude Sonnet 5.5"]],
	["z", ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaz"]],
	["ä", ["Zürich Ärger"]],
	["ÄRGER", ["Zürich Ärger"]],
	["émoji 🙂", ["an émoji 🙂 field"]],
	["x", []],
];

const NODE_QUERIES = [
	"relational",
	"key",
	"primary key",
	"normal form",
	"join",
	"database",
	"sql",
	"tuple",
	"functional dependency",
	"null",
	"Information Principle",
	"table",
	"codd",
	"zzz",
	"",
];

interface NodeLine {
	id: string;
	name: string;
	aliases?: string[];
}

export default () => {
	// ─── fuzzy ───
	const seen = new Set<string>();
	const nodeFields: string[][] = [];
	for (const n of readJsonl<NodeLine>("graph/nodes.jsonl")) {
		if (seen.has(n.id)) continue;
		seen.add(n.id);
		nodeFields.push([n.name, ...(n.aliases ?? [])]);
	}
	const fuzzy = {
		pairs: PAIRS.map(([query, fields]) => ({ query, fields, score: fuzzyScore(query, ...fields) })),
		nodeFields,
		nodeQueries: NODE_QUERIES.map((query) => ({ query, scores: nodeFields.map((f) => fuzzyScore(query, ...f)) })),
	};

	// ─── usage folds over the golden records ───
	const chats = [TEACH_CHAT, PRACTICE_CHAT].map(chat);
	const sources = Object.values(
		readJson<Record<string, { filePath: string; extractions?: ExtractionRunUsage[] }>>("graph/sources.json"),
	);
	const jobs = readdirSync(path.join(GOLDEN, "jobs"))
		.sort()
		.map((f) => readJson<JobRecord>(`jobs/${f}`));

	// Every model the golden usage names, with the TS price (all are
	// provider-qualified foreign ids — unpriced in the native catalog, so
	// the Swift test prices them from this table to check the folds).
	const models = new Set<string>();
	for (const c of chats) for (const t of (c.turns ?? []) as TurnUsage[]) models.add(t.model);
	for (const s of sources)
		for (const r of s.extractions ?? []) {
			models.add(r.stages.extractor.model);
			models.add(r.stages.auditor.model);
		}
	for (const j of jobs) if (j.usage) models.add(j.usage.model);
	const prices = Object.fromEntries([...models].sort().filter((m) => PRICES[m]).map((m) => [m, PRICES[m]]));
	const limits = new Map([...models].map((m) => [m, GOLDEN_CONTEXT_WINDOW]));

	const usage = {
		prices,
		contextWindow: GOLDEN_CONTEXT_WINDOW,
		chats: chats.map((c) => {
			const turns = (c.turns ?? []) as TurnUsage[];
			return {
				id: c.id,
				turns: turns.map((t) => ({ id: t.id, cost: turnCost(t), sum: sumSteps(t.steps) })),
				sessionCost: sessionCost(c),
				contextWindow: contextWindow(c, limits),
				// A zeroed last step must fall back to the previous one.
				contextWindowZeroedTail: contextWindow(
					{
						turns: turns.length
							? [
									...turns.slice(0, -1),
									{ ...turns[turns.length - 1]!, steps: [...turns[turns.length - 1]!.steps, zeroStep()] },
								]
							: [],
					},
					limits,
				),
				allSteps: sumSteps(turns.flatMap((t) => t.steps)),
			};
		}),
		jobs: jobs.map((j) => ({ id: j.id, cost: jobCost(j) })),
		stageSums: sources.flatMap((s) =>
			(s.extractions ?? []).map((r) => ({
				startedAt: r.startedAt,
				extractor: sumSteps(r.stages.extractor.steps),
				auditor: sumSteps(r.stages.auditor.steps),
			})),
		),
	};

	const input = {
		chats: chats.map((c) => ({ title: c.title as string, extractions: (c.extractions ?? []) as ExtractionRunUsage[] })),
		sources: sources.map((s) => ({ filePath: s.filePath, extractions: s.extractions ?? [] })),
	};
	const summary = {
		default: graphCostSummary(input),
		capped: graphCostSummary({ ...input, recentCap: 1 }),
	};

	return {
		"cost.fuzzy": plain(fuzzy),
		"cost.usage": plain(usage),
		"cost.graphCostSummary": plain(summary),
	};
};

function zeroStep(): CallUsage {
	return { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0 };
}
