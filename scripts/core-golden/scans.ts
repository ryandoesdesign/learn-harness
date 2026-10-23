import { chat, plain, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import {
	activeProblemOf,
	danglingQuestionOf,
	endsInDismissal,
	hasProbeDone,
	needsContinuation,
	pendingProblemDismissalOf,
	problemInputForConclude,
	type LhMessage,
} from "../../src/core/native-messages.ts";

/** Every native scan at every prefix of both golden chats. */
export default () => {
	const out: Record<string, unknown> = {};
	for (const id of [TEACH_CHAT, PRACTICE_CHAT]) {
		const messages = chat(id).messages as LhMessage[];
		const rows = [];
		for (let i = 0; i <= messages.length; i++) {
			const prefix = messages.slice(0, i);
			rows.push({
				n: i,
				dangling: danglingQuestionOf(prefix),
				needsContinuation: needsContinuation(prefix),
				endsInDismissal: endsInDismissal(prefix),
				activeProblem: activeProblemOf(prefix),
				pendingDismissal: pendingProblemDismissalOf(prefix),
				hasProbeDone: hasProbeDone(prefix),
			});
		}
		const concludes = messages.flatMap((m) =>
			m.role === "assistant"
				? (m.content as Array<{ type: string; name?: string; id?: string }>).filter(
						(b) => b.type === "toolCall" && b.name === "conclude",
					)
				: [],
		);
		out[`scans.${id}`] = plain({
			prefixes: rows,
			problemInputs: concludes.map((c) => ({ concludeCallId: c.id, input: problemInputForConclude(messages, c.id!) ?? null })),
		});
	}
	return out;
};
