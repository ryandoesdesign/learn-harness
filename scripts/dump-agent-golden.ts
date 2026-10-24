/**
 * Golden dumps for the native port's agent layer (docs/native-macos-m5.md):
 * the TS teaching-tool definitions (name, description, input schema) for
 * both agents in both quiz mechanics, the practice registry (M8), and the composed system prompts with
 * their segment order. LHAgentTests compares the Swift registries and the
 * PromptComposer against these.
 *
 *   npx tsx scripts/dump-agent-golden.ts
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createProberTools, createTeacherTools } from "../src/agent/tools.ts";
import { practiceTools } from "../src/agent/tools/practice.ts";
import { composeInstructions } from "../src/agent/teacher-agent.ts";
import { listSourceSegments } from "../src/agent/prompt-segments.ts";
import { auditorGraphTools } from "../src/agent/tools/graph.ts";
import {
	AUDITOR_INSTRUCTIONS, EXTRACTOR_INSTRUCTIONS, NOTES_EXTRACTOR_INSTRUCTIONS,
	auditSchema, findingsSchema, sessionFindingsSchema,
} from "../src/agent/subagents/extraction.ts";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const OUT = path.join(ROOT, "macos/Packages/LHKit/Tests/LHAgentTests/Golden");
mkdirSync(OUT, { recursive: true });

/** The native set: M5 teaching, M6 jobs and learner files, M7 the prober's graph tools. */
const TEACHING = new Set([
	"probe", "recall", "quiz", "explain", "ask_user_question", "probe_done", "plan_init",
	"research", "demo", "visual", "pdf", "read", "ls", "find", "grep",
	"list_sessions", "list_propositions",
	"problem", "conclude",
]);

const ctx = {
	chatId: "chat_golden",
	chatStore: { getChat: () => null, saveTree: () => {} },
	deliver: () => {},
	jobStore: {},
	spawn: () => {},
	searchAvailable: () => true,
	graphStore: {},
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
	// M7 (docs/native-macos-m7.md): the extraction stages' prompts and tools.
	extraction: {
		prompts: { extractor: EXTRACTOR_INSTRUCTIONS, notesExtractor: NOTES_EXTRACTOR_INSTRUCTIONS, auditor: AUDITOR_INSTRUCTIONS },
		tools: [
			{ name: "submit_findings", description: "Submit the session findings.", input_schema: JSON.parse(JSON.stringify(sessionFindingsSchema)) },
			{ name: "submit_findings_notes", description: "Submit the notes findings.", input_schema: JSON.parse(JSON.stringify(findingsSchema)) },
			{ name: "submit_review", description: "Submit the identity verdicts ONLY (links) — never the propositions themselves.", input_schema: JSON.parse(JSON.stringify(auditSchema)) },
			...Object.values(auditorGraphTools({ chatStore: {}, graphStore: {} } as never)).map((t) => ({
				name: t.name, description: t.description, input_schema: JSON.parse(JSON.stringify(t.parameters)),
			})),
		],
	},
	// M8 (docs/native-macos-m8.md): the practice registry, every optional
	// tool present (research live, map readers on).
	"tools-practice": defs(practiceTools({ ...(ctx as object), jobs: ctx, graph: ctx } as never)),
	"prompt-practice": composeInstructions("practice"),
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
