import { chat, plain, readJson, readJsonl, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import type { ChatStore, GraphStore } from "../../src/core/ports.ts";
import type { CoverageEntry, GraphChain, GraphNode, NotesSource, Position } from "../../src/core/contracts.ts";
import type { LhMessage } from "../../src/core/native-messages.ts";
import {
	getGraph,
	graphSessionIndex,
	graphSessionPropositions,
	graphSnapshot,
	simplifyChains,
	type GraphDeps,
} from "../../src/core/graph.ts";
import { birthSessionPartition } from "../../src/core/session-clusters.ts";
import {
	batchRuns,
	batchTag,
	coverageOf,
	coverageSlots,
	coveredSet,
	messageViewLines,
	teacherProseBlocks,
} from "../../src/core/coverage.ts";

/** In-memory ports over the golden ledgers + the two golden chats (read-only
 *  — the snapshot / index derivations never write). */
function goldenDeps(): GraphDeps {
	const nodes = readJsonl<GraphNode>("graph/nodes.jsonl");
	const chains = readJsonl<GraphChain>("graph/chains.jsonl");
	const sources = Object.values(readJson<Record<string, NotesSource>>("graph/sources.json"));
	const positions = readJson<{ positions: Record<string, Position> }>("graph/positions.json").positions;
	const chats = [TEACH_CHAT, PRACTICE_CHAT].map((id) => chat(id));
	const graphStore = {
		readNodes: () => nodes,
		readChains: () => chains,
		readSources: () => sources,
		readPositions: () => positions,
	} as unknown as GraphStore;
	const chatStore = {
		getChat: (id: string) => chats.find((c) => c.id === id) ?? null,
		listChats: () =>
			chats.map((c) => ({ id: c.id, title: c.title, createdAt: c.createdAt, updatedAt: c.updatedAt })),
	} as unknown as ChatStore;
	return { chatStore, graphStore };
}

/** Graph derivations + coverage over the golden data dir. */
export default () => {
	const deps = goldenDeps();
	const graph = getGraph(deps.graphStore);
	const nodeLines = deps.graphStore.readNodes();
	const chainLines = deps.graphStore.readChains();
	const simplified = simplifyChains(chainLines);
	const index = graphSessionIndex(deps);
	const propositions: Record<string, unknown> = {};
	for (const entry of index) propositions[entry.id] = graphSessionPropositions(deps, entry.id);

	const out: Record<string, unknown> = {
		"graph.snapshot": plain(graphSnapshot(deps)),
		"graph.derived": plain({
			counts: {
				nodeLines: nodeLines.length,
				chainLines: chainLines.length,
				nodes: graph.nodes.length,
				chains: graph.chains.length,
				simplifiedChains: simplified.length,
			},
			graph,
			partition: birthSessionPartition(graph.nodes),
			simplifiedChainIds: simplified.map((c) => c.id),
			sessionIndex: index,
			sessionPropositions: propositions,
		}),
	};

	const ledger = readJsonl<CoverageEntry>("graph/coverage.jsonl");
	const ledgerChats = [...new Set(ledger.map((e) => e.chatId))];
	for (const id of [TEACH_CHAT, PRACTICE_CHAT]) {
		const messages = chat(id).messages as LhMessage[];
		const slots = coverageSlots(messages);
		// A synthetic ledger covering every other visible slot — exercises
		// both sides of the diff (the golden chats were never extracted).
		const visible = slots
			.map((s, i) => ({ s, i }))
			.filter(({ s }) => messageViewLines(s.message, s.message.id).length > 0);
		const synthetic: CoverageEntry[] = visible
			.filter((_, k) => k % 2 === 0)
			.map(({ s }) => ({ chatId: id, fp: s.fp, tokens: s.tokens, foldedAt: "2026-10-24T00:00:00.000Z" }));
		const covOf = (entries: CoverageEntry[]) => {
			const cov = coverageOf(messages, entries, id);
			const { slots: _slots, ...rest } = cov;
			return rest;
		};
		const synthCov = coverageOf(messages, synthetic, id);
		const runs: Record<string, unknown> = {};
		for (const budget of [0, 50, 500, 4096]) {
			runs[String(budget)] = batchRuns(synthCov.slots, synthCov.uncovered, budget).map((run) => ({
				ids: run.map((s) => s.message.id),
				tag: batchTag(run),
			}));
		}
		const allCov = coverageOf(messages, [], id);
		out[`graph.coverage.${id}`] = plain({
			slots: slots.map((s) => ({
				id: s.message.id,
				role: (s.message as { role: string }).role,
				lines: messageViewLines(s.message, s.message.id),
				fp: s.fp,
				tokens: s.tokens,
			})),
			teacherProseBlocks: teacherProseBlocks(messages),
			ledgerCoverage: covOf(ledger),
			emptyCoverage: covOf([]),
			syntheticCoverage: covOf(synthetic),
			syntheticRuns: runs,
			allUncoveredRuns4096: batchRuns(allCov.slots, allCov.uncovered, 4096).map((run) => ({
				ids: run.map((s) => s.message.id),
				tag: batchTag(run),
			})),
		});
	}
	out["graph.coveredSets"] = plain(Object.fromEntries(ledgerChats.map((c) => [c, coveredSet(ledger, c)])));

	// simplifyChains over synthetic ledgers (the real one drops nothing):
	// both rules, grouped keys, and the localeCompare tie-breaks (case,
	// punctuation vs digits) on equal premise counts + createdAt.
	const ch = (id: string, premises: string[], conclusion: string, createdAt = "2026-09-30T00:00:00.000Z", chatId = "c1"): GraphChain => ({
		id,
		premises,
		conclusion,
		createdAt,
		provenance: [{ chatId, messageId: "" }],
	});
	const simplifyCases: GraphChain[][] = [
		// Rule 1: a strict premise superset is redundant.
		[ch("arg_1", ["a", "b"], "x"), ch("arg_2", ["a"], "x"), ch("arg_3", ["a", "b", "c"], "x")],
		// Rule 2: ancestry cover — [A,B]⟹X plus [X,C]⟹Y makes [A,B,C]⟹Y redundant.
		[ch("arg_ab", ["A", "B"], "X"), ch("arg_xc", ["X", "C"], "Y"), ch("arg_abc", ["A", "B", "C"], "Y")],
		// Same key on two lines (one logical chain) — kept or dropped whole.
		[ch("arg_k", ["p", "q"], "z"), ch("arg_k", ["q", "p"], "z", "2026-09-30T00:00:01.000Z", "c2"), ch("arg_s", ["p"], "z", "2026-10-01T00:00:00.000Z")],
		// Tie-breaks: equal counts + createdAt → key localeCompare order.
		[ch("arg_t1", ["B"], "r"), ch("arg_t2", ["a"], "r"), ch("arg_t3", ["_"], "r"), ch("arg_t4", ["5"], "r"), ch("arg_t5", ["a", "B"], "r")],
		// …where the order decides the outcome (code-unit order would flip both).
		[ch("arg_v1", ["B"], "a"), ch("arg_v2", ["a"], "r"), ch("arg_v3", ["B"], "r")],
		[ch("arg_w1", ["5"], "_"), ch("arg_w2", ["_"], "r"), ch("arg_w3", ["5"], "r")],
		[ch("arg_u1", ["n>"], "s"), ch("arg_u2", ["n5"], "s"), ch("arg_u3", ["n5", "n>"], "s"), ch("arg_u4", ["n5", "zz"], "t")],
		// createdAt ordering decides between equal-count candidates; cycle guard.
		[ch("arg_c1", ["m"], "w", "2026-10-02T00:00:00.000Z"), ch("arg_c2", ["w"], "m"), ch("arg_c3", ["m", "w"], "v"), ch("arg_c4", ["m"], "v", "2026-10-03T00:00:00.000Z")],
		// Fewer than two lines → identity.
		[ch("arg_one", ["a"], "b")],
		[],
	];
	out["graph.simplify"] = plain(simplifyCases.map((input) => ({ input, output: simplifyChains(input) })));
	return out;
};
