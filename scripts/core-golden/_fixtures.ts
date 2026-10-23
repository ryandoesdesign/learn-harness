/** Shared loaders for the golden dump areas. The runner imports every .ts
 *  here, so this helper module default-exports an empty dump. */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
export const GOLDEN = path.join(ROOT, "tests/fixtures/golden-data");
export const TEACH_CHAT = "chat_mv27rrra_feff23b6";
export const PRACTICE_CHAT = "chat_mv293wv5_10656952";

export function readJson<T = unknown>(rel: string): T {
	return JSON.parse(readFileSync(path.join(GOLDEN, rel), "utf8")) as T;
}

export function readJsonl<T = unknown>(rel: string): T[] {
	return readFileSync(path.join(GOLDEN, rel), "utf8")
		.split("\n")
		.filter((l) => l.trim())
		.map((l) => JSON.parse(l) as T);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function chat(id: string): any {
	return readJson(`chats/${id}.json`);
}

/** JSON-safe projection: Sets → sorted arrays, Maps → objects, undefined dropped. */
export function plain(value: unknown): unknown {
	return JSON.parse(
		JSON.stringify(value, (_k, v) => {
			if (v instanceof Set) return [...v].sort();
			if (v instanceof Map) return Object.fromEntries(v);
			return v;
		}),
	);
}

export default () => ({});
