import { readdirSync } from "node:fs";
import path from "node:path";
import { chat, GOLDEN } from "./_fixtures.ts";
import { activeProblemOf, danglingQuestionOf, type LhMessage } from "../../src/core/native-messages.ts";
import { phaseAt3Lh } from "../../src/core/phases.ts";

/** The chat store's listChats projection over the golden data dir (what the
 *  importer's summaries must reproduce), newest activity first. */
export default () => {
	const ids = readdirSync(path.join(GOLDEN, "chats"))
		.filter((f) => f.endsWith(".json"))
		.map((f) => f.slice(0, -5));
	const summaries = ids
		.map((id) => {
			const r = chat(id);
			const messages = r.messages as LhMessage[];
			return {
				id: r.id,
				title: r.title,
				createdAt: r.createdAt,
				updatedAt: r.updatedAt,
				kind: r.kind ?? "teach",
				messageCount: messages.length,
				phase: phaseAt3Lh(messages),
				pendingQuestion: danglingQuestionOf(messages) !== null,
				activeProblem: activeProblemOf(messages) !== null,
			};
		})
		.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
	return { "store.summaries": summaries };
};
