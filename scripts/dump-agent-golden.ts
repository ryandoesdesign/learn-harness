/**
 * Golden dumps for the native port's agent layer (docs/native-macos-m5.md):
 * the TS teaching-tool definitions (name, description, input schema) for
 * both agents in both quiz mechanics, and the composed system prompts with
 * their segment order. LHAgentTests compares the Swift registries and the
 * PromptComposer against these.
 *
 *   npx tsx scripts/dump-agent-golden.ts
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createProberTools, createTeacherTools } from "../src/agent/tools.ts";
import { composeInstructions } from "../src/agent/teacher-agent.ts";
import { listSourceSegments } from "../src/agent/prompt-segments.ts";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const OUT = path.join(ROOT, "macos/Packages/LHKit/Tests/LHAgentTests/Golden");
mkdirSync(OUT, { recursive: true });

/** The M5 teaching set — every other tool (fs, jobs, graph) is a later milestone. */
const TEACHING = new Set(["probe", "recall", "quiz", "explain", "ask_user_question", "probe_done", "plan_init"]);

const ctx = {
	chatId: "chat_golden",
	chatStore: { getChat: () => null, saveTree: () => {} },
	deliver: () => {},
	jobStore: {},
	spawn: () => {},
	searchAvailable: () => true,
} as never;

function defs(tools: Record<string, { name: string; description: string; parameters: unknown }>) {
	return Object.values(tools)
		.filter((t) => TEACHING.has(t.name))
		.map((t) => ({ name: t.name, description: t.description, input_schema: JSON.parse(JSON.stringify(t.parameters)) }));
}

const dumps: Record<string, unknown> = {
	"tools-prober": defs(createProberTools(ctx)),
	"tools-prober-free": defs(createProberTools(ctx, { explain: true })),
	"tools-teacher": defs(createTeacherTools(ctx)),
	"tools-teacher-free": defs(createTeacherTools(ctx, { explain: true })),
	"prompt-prober": composeInstructions("prober"),
	"prompt-teacher": composeInstructions("teacher"),
	"prompt-segments": {
		prober: listSourceSegments("prober").map((s) => s.path),
		teacher: listSourceSegments("teacher").map((s) => s.path),
		practice: listSourceSegments("practice").map((s) => s.path),
	},
};
for (const [name, value] of Object.entries(dumps)) {
	writeFileSync(path.join(OUT, `${name}.json`), `${JSON.stringify(value, null, "\t")}\n`);
	console.log(`→ ${name}.json`);
}
