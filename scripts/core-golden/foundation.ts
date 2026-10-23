import { chat, plain, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import { derivePlanStatusesLh } from "../../src/core/contracts/plan.ts";
import { titleFromPrompt } from "../../src/core/contracts/graph.ts";

export default () => {
	const teach = chat(TEACH_CHAT);
	const titles = [
		"short",
		"  many   spaces\n\tand lines  ",
		"x".repeat(80),
		"word ".repeat(30),
		"a😀 ".repeat(30),
		`${"y".repeat(72)} tail`,
	];
	return {
		"foundation.planStatuses": plain(derivePlanStatusesLh(teach.tree, teach.messages)),
		"foundation.titles": titles.map((t) => ({ input: t, output: titleFromPrompt(t) })),
		"foundation.messageCounts": { [TEACH_CHAT]: teach.messages.length, [PRACTICE_CHAT]: chat(PRACTICE_CHAT).messages.length },
	};
};
