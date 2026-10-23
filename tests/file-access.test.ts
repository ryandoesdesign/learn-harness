/**
 * The file-access policy (security hardening, 2026-10-24): the learner-file
 * tools reach only the folders allowed in settings. Fail closed when no
 * folder is allowed (or no policy is registered); `..` escapes and
 * symlinks that point out are judged by their REAL path; denied paths
 * (the app's data dir, auth.json, .env*) stay refused even when nested in
 * an allowed folder. Fixtures live in tmpdir.
 */
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { after, afterEach, describe, it } from "node:test";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { resolveAllowedPaths, setFileAccessPolicy } from "../src/agent/tools/fs-shared.ts";
import { findTool } from "../src/agent/tools/find.ts";
import { grepTool } from "../src/agent/tools/grep.ts";
import { lsTool } from "../src/agent/tools/ls.ts";
import { readTool } from "../src/agent/tools/read.ts";

const base = fs.mkdtempSync(path.join(os.tmpdir(), "lh-access-"));
const notes = path.join(base, "notes");
const papers = path.join(base, "papers");
const outside = path.join(base, "outside");
for (const dir of [notes, papers, outside]) fs.mkdirSync(dir);
fs.writeFileSync(path.join(notes, "linear.txt"), "eigenvectors keep their direction\n");
fs.writeFileSync(path.join(papers, "calc.txt"), "eigenvalues scale them\n");
fs.writeFileSync(path.join(outside, "secret.txt"), "eigen-secret\n");
fs.symlinkSync(path.join(outside, "secret.txt"), path.join(notes, "link-to-secret.txt"));
const keysDir = path.join(notes, "app-data");
fs.mkdirSync(keysDir);
fs.writeFileSync(path.join(keysDir, "auth.json"), "eigen-key\n");

function allow(folders: string[], denied: string[] = []): void {
	setFileAccessPolicy(() => ({ allowedFolders: folders, deniedPaths: denied }));
}

async function runText(tool: AgentTool<any>, args: Record<string, unknown>): Promise<string> {
	const result = await tool.execute!("t", args);
	return (result.content[0] as { type: "text"; text: string }).text;
}

afterEach(() => setFileAccessPolicy(null));
after(() => fs.rmSync(base, { recursive: true, force: true }));

describe("file access — fail closed", () => {
	it("no registered policy: every tool refuses", async () => {
		for (const [tool, args] of [
			[readTool, { path: path.join(notes, "linear.txt") }],
			[lsTool, {}],
			[findTool, { pattern: "*.txt" }],
			[grepTool, { pattern: "eigen" }],
		] as const) {
			await assert.rejects(runText(tool, args), /File access is off/, `${tool.name} refuses`);
		}
	});

	it("an empty allowed list refuses with the Settings hint", async () => {
		allow([]);
		await assert.rejects(runText(readTool, { path: path.join(notes, "linear.txt") }), /Settings → Agent → File access/);
	});
});

describe("file access — inside vs outside", () => {
	it("reads inside an allowed folder", async () => {
		allow([notes]);
		assert.match(await runText(readTool, { path: path.join(notes, "linear.txt") }), /eigenvectors/);
	});

	it("refuses absolute paths outside, and ../ escapes", async () => {
		allow([notes]);
		await assert.rejects(runText(readTool, { path: path.join(outside, "secret.txt") }), /Access denied/);
		await assert.rejects(runText(readTool, { path: "../outside/secret.txt" }), /Access denied/);
		await assert.rejects(runText(lsTool, { path: base }), /Access denied/);
	});

	it("refuses a symlink inside the folder that points out", async () => {
		allow([notes]);
		await assert.rejects(runText(readTool, { path: path.join(notes, "link-to-secret.txt") }), /Access denied/);
	});

	it("denied paths stay refused even nested in an allowed folder", async () => {
		allow([notes], [keysDir]);
		await assert.rejects(runText(readTool, { path: path.join(keysDir, "auth.json") }), /Access denied/);
		const grep = await runText(grepTool, { pattern: "eigen" });
		assert.ok(!grep.includes("eigen-key"), "grep skips denied files");
		assert.ok(!grep.includes("eigen-secret"), "grep never follows the outward symlink");
		assert.match(grep, /eigenvectors/);
	});
});

describe("file access — default roots and relative paths", () => {
	it("no-path find/grep cover every allowed folder with absolute labels; ls lists the folders", async () => {
		allow([notes, papers]);
		const found = await runText(findTool, { pattern: "*.txt" });
		assert.ok(found.includes(path.join(notes, "linear.txt")));
		assert.ok(found.includes(path.join(papers, "calc.txt")));
		assert.ok(!found.includes("secret.txt"));
		const grep = await runText(grepTool, { pattern: "eigenvalues" });
		assert.ok(grep.startsWith(`${path.join(papers, "calc.txt")}:1:`));
		assert.equal(await runText(lsTool, {}), `${notes}/\n${papers}/`);
	});

	it("a single explicit root keeps pi's relative output", async () => {
		allow([notes, papers]);
		assert.equal(await runText(findTool, { pattern: "*.txt", path: papers }), "calc.txt");
	});

	it("a relative path resolves in the first allowed folder where it exists", async () => {
		allow([notes, papers]);
		assert.match(await runText(readTool, { path: "calc.txt" }), /eigenvalues/);
		assert.deepEqual(await resolveAllowedPaths("calc.txt"), [path.join(papers, "calc.txt")]);
	});
});
