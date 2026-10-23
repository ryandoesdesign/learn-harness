import { createHash } from "node:crypto";
import { chat, plain, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import { projectView, type LhViewMessage, type LiveTurnState } from "../../src/core/view.ts";
import {
	activeCompactionOf,
	buildCompactionPrompt,
	compactionCutIndex,
	estimateContextTokens,
	estimateMessageTokens,
	estimateTokens,
	keptIndexFor,
	newCompactionMarker,
	planTreeToText,
	serializeForSummary,
} from "../../src/core/compaction.ts";
import type { LhMessage } from "../../src/core/native-messages.ts";

/**
 * The transcript area (core/view.ts + core/compaction.ts) over both golden
 * chats. NORMALIZATION (record-shape difference, not behaviour): the native
 * record stores a pi `details: null` tool result as absent details, so a
 * part's `output: null` is dropped here — the Swift projection has no null
 * to carry. Every-prefix views are dumped as a part skeleton plus the
 * SHA-256 of a canonical (key-sorted) serialization: the full dumps would
 * run to megabytes.
 */

/** Drop `output: null` (see the normalization note). */
function normalizeView(view: LhViewMessage[]): unknown {
	const v = plain(view) as Array<{ parts: Array<Record<string, unknown>> }>;
	for (const m of v) {
		for (const p of m.parts) if (p.output === null) delete p.output;
	}
	return v;
}

/** Key-sorted JSON (keys by UTF-16 code unit — JS's default sort), written
 *  by hand so integer-like keys can't be re-ordered by the engine. */
function canonical(v: unknown): string {
	if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
	if (v !== null && typeof v === "object") {
		const o = v as Record<string, unknown>;
		return `{${Object.keys(o)
			.sort()
			.map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
			.join(",")}}`;
	}
	return JSON.stringify(v);
}

const sha = (s: string): string => createHash("sha256").update(s, "utf8").digest("hex");

/** One compact line per part: type|state|id|toolCallId. */
function skeleton(view: unknown): string[][] {
	return (view as Array<{ id: string; role: string; parts: Array<Record<string, unknown>> }>).map((m) => [
		`${m.role}:${m.id}`,
		...m.parts.map((p) => [p.type, p.state ?? "", p.id ?? "", p.toolCallId ?? ""].join("|")),
	]);
}

/** The live layer as the session hook drives it mid-turn: the tail message streaming, no executions yet. */
function liveFor(prefix: readonly LhMessage[]): LiveTurnState {
	const last = prefix[prefix.length - 1];
	return { executions: new Map(), inFlight: true, streamingIds: new Set(last ? [last.id] : []) };
}

export default () => {
	const out: Record<string, unknown> = {};
	for (const id of [TEACH_CHAT, PRACTICE_CHAT]) {
		const record = chat(id);
		const messages = record.messages as LhMessage[];

		const full = normalizeView(projectView(messages));
		const prefixes = [];
		for (let i = 0; i <= messages.length; i++) {
			const prefix = messages.slice(0, i);
			const settled = normalizeView(projectView(prefix));
			const live = normalizeView(projectView(prefix, liveFor(prefix)));
			prefixes.push({
				n: i,
				skeleton: skeleton(settled),
				sha256: sha(canonical(settled)),
				liveSha256: sha(canonical(live)),
			});
		}
		out[`transcript.view.${id}`] = { full, fullSha256: sha(canonical(full)), prefixes };

		const contexts = [];
		for (let i = 0; i <= messages.length; i++) {
			const prefix = messages.slice(0, i);
			contexts.push({
				n: i,
				estimate: estimateContextTokens(prefix),
				cut: compactionCutIndex(prefix),
				cut5k: compactionCutIndex(prefix, 5_000),
				planTreeText: planTreeToText(record.tree, prefix),
			});
		}
		const cut = compactionCutIndex(messages);
		const cut5k = compactionCutIndex(messages, 5_000);
		const active = activeCompactionOf(messages);
		const treeText = planTreeToText(record.tree, messages);
		const span = serializeForSummary(messages.slice(0, cut5k));
		out[`transcript.compaction.${id}`] = plain({
			messageTokens: messages.map((m) => ({ id: m.id, tokens: estimateMessageTokens(m) })),
			estimateTokens: estimateTokens(messages),
			contexts,
			cut,
			cuts: [0, 1, 500, 1_000, 5_000, 20_000, 50_000, 1_000_000].map((budget) => ({
				budget,
				cut: compactionCutIndex(messages, budget),
			})),
			serializeFull: serializeForSummary(messages),
			serializeSpan5k: span,
			active: active ? { id: active.id, content: active.content, details: active.details, keptIndex: keptIndexFor(messages, active) } : null,
			prompt: buildCompactionPrompt({ spanText: span, planTreeText: treeText, kind: record.kind ?? "teach" }),
			promptNoTree: buildCompactionPrompt({ spanText: "TRANSCRIPT", planTreeText: null, kind: "practice" }),
			markerContent: newCompactionMarker("  The learner knows X.\n\n", {
				firstKeptMessageId: messages[cut5k]?.id ?? "none",
				tokensBefore: estimateContextTokens(messages).tokens,
				model: "claude-opus-5-5",
				at: "2026-10-05T12:00:00.000Z",
			}).content,
		});
	}
	return out;
};
