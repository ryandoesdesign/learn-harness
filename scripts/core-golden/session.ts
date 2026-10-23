import { chat, plain, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import type { LhMessage } from "../../src/core/native-messages.ts";
import { phaseAt3Lh, teachStepIndex } from "../../src/core/phases.ts";
import { emittedPlanBlockCalls, planBlocksFor } from "../../src/core/plan-blocks.ts";
import { messageMarkdown, sessionMarkdown } from "../../src/core/session-markdown.ts";
import { projectView } from "../../src/core/view.ts";

type Part = { type: string; input?: unknown; toolCallId?: string };

function tagged(p: Part): boolean {
	const nodeId = (p.input as { nodeId?: unknown } | undefined)?.nodeId;
	return (p.type === "tool-quiz" || p.type === "tool-explain") && typeof nodeId === "string" && nodeId.length > 0;
}

/** A plan-block marker's comparable face: the call it presents + its
 *  snapshot with `at` normalized (the clock is injected on the Swift side). */
function blockFace(m: LhMessage): unknown {
	const d = (m as { details: { planCallId: string; block: Record<string, unknown> } }).details;
	return { planCallId: d.planCallId, block: { ...d.block, at: "<at>" } };
}

/** Session-area dumps (phases, plan blocks, session markdown) over both golden chats. */
export default () => {
	const out: Record<string, unknown> = {};
	for (const id of [TEACH_CHAT, PRACTICE_CHAT]) {
		const record = chat(id);
		const messages = record.messages as LhMessage[];

		// phaseAt3Lh at every prefix (n = 0 … length) and at every upToIndex.
		const prefixPhases = [];
		for (let n = 0; n <= messages.length; n++) prefixPhases.push(phaseAt3Lh(messages.slice(0, n)));
		const upTo = messages.map((_, i) => phaseAt3Lh(messages, i));

		// teachStepIndex: every view group carrying a tagged quiz/explain part,
		// with the step ordinal and the call it found (the Swift native slice
		// runs from the group's first message through the call's message).
		const teachSteps = [];
		for (const vm of projectView(messages)) {
			if (vm.role !== "assistant") continue;
			const parts = vm.parts as Part[];
			const at = parts.findIndex(tagged);
			if (at < 0) continue;
			teachSteps.push({
				groupId: vm.id,
				flipCallId: parts[at]!.toolCallId,
				stepOrdinal: parts.slice(0, at).filter((p) => p.type === "step-start").length,
				index: teachStepIndex(parts as never),
			});
		}

		// planBlocksFor: the whole chat as one turn over an empty record, the
		// replay over the full record, and per learner turn (record = what
		// came before, its plan-block markers stripped).
		const strip = (ms: LhMessage[]) =>
			ms.filter((m) => !((m as { role?: string }).role === "custom" && (m as { customType?: string }).customType === "plan-block"));
		const bare = strip(messages);
		const wholeTurn = planBlocksFor([], bare, record.tree, bare).map(blockFace);
		const replay = planBlocksFor(messages, messages, record.tree, messages).map(blockFace);
		const starts = bare.flatMap((m, i) => ((m as { role?: string }).role === "user" || i === 0 ? [i] : []));
		const perTurn = [];
		const seen: LhMessage[] = [];
		for (let k = 0; k < starts.length; k++) {
			const turn = bare.slice(starts[k], starts[k + 1] ?? bare.length);
			const blocks = planBlocksFor(seen, turn, record.tree, [...seen, ...turn]);
			perTurn.push({ start: starts[k], blocks: blocks.map(blockFace) });
			seen.push(...turn, ...blocks);
		}

		out[`session.${id}`] = plain({
			prefixPhases,
			upTo,
			teachSteps,
			emittedPlanBlockCalls: emittedPlanBlockCalls(messages),
			planBlocks: { wholeTurn, replay, perTurn },
			messageMarkdown: messages.map((m) => ({
				id: m.id,
				anchored: messageMarkdown(m, m.id ?? ""),
				bare: messageMarkdown(m, m.id ?? "", false),
			})),
			sessionMarkdown: {
				default: sessionMarkdown(messages),
				noAnchors: sessionMarkdown(messages, { anchors: false }),
				titled: sessionMarkdown(messages, { title: record.title }),
				titledNoAnchors: sessionMarkdown(messages, { title: record.title, anchors: false }),
				emptyTitle: sessionMarkdown(messages, { title: "" }),
			},
		});
	}
	return out;
};
