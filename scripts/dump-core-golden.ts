/**
 * Golden dumps for the native port (docs/native-macos-m1.md): runs the TS
 * core functions over tests/fixtures/golden-data and writes their outputs
 * as JSON into the Swift test bundle, where LHCore's tests compare against
 * them. Each scripts/core-golden/<area>.ts default-exports a function
 * returning { "<file name>": value, … }.
 *
 *   npx tsx scripts/dump-core-golden.ts
 */
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const OUT = path.join(ROOT, "macos/Packages/LHKit/Tests/LHCoreTests/Golden");
const AREAS = path.join(ROOT, "scripts/core-golden");

mkdirSync(OUT, { recursive: true });
for (const file of readdirSync(AREAS).filter((f) => f.endsWith(".ts")).sort()) {
	const mod = (await import(pathToFileURL(path.join(AREAS, file)).href)) as {
		default: () => Record<string, unknown> | Promise<Record<string, unknown>>;
	};
	const dumps = await mod.default();
	for (const [name, value] of Object.entries(dumps)) {
		writeFileSync(path.join(OUT, `${name}.json`), `${JSON.stringify(value, null, "\t")}\n`);
		console.log(`${file} → ${name}.json`);
	}
}
