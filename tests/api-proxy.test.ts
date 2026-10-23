/**
 * The API guard (proxy.ts, security hardening 2026-10-24): /api answers
 * only same-origin, loopback-hosted requests. Driven with crafted
 * NextRequests — no server.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { NextRequest } from "next/server";
import { config, proxy } from "../proxy.ts";

function request(headers: Record<string, string>, method = "POST"): NextRequest {
	return new NextRequest("http://127.0.0.1:3000/api/chats", { method, headers });
}

/** NextResponse.next() carries this marker; a rejection is a plain 403. */
const passed = (res: Response) => res.headers.get("x-middleware-next") === "1";

describe("API guard (proxy.ts)", () => {
	it("passes the app's own requests: same origin, loopback host", () => {
		assert.ok(passed(proxy(request({ host: "127.0.0.1:3000", origin: "http://127.0.0.1:3000", "sec-fetch-site": "same-origin" }))));
		assert.ok(passed(proxy(request({ host: "localhost:3000", origin: "http://localhost:3000" }))), "dev server");
		assert.ok(passed(proxy(request({ host: "[::1]:3000" }, "GET"))), "IPv6 loopback");
	});

	it("passes header-less local callers (smoke script, curl)", () => {
		assert.ok(passed(proxy(request({ host: "127.0.0.1:51234" }, "GET"))));
		assert.ok(passed(proxy(request({ host: "127.0.0.1:3000", "sec-fetch-site": "none" }, "GET"))), "typed-in URL");
	});

	it("rejects a cross-site POST from another website", async () => {
		const res = proxy(request({ host: "127.0.0.1:3000", origin: "https://evil.example", "sec-fetch-site": "cross-site" }));
		assert.equal(res.status, 403);
		assert.match((await res.json()).error, /cross-origin/);
	});

	it("rejects a cross-site request even without an Origin header", () => {
		assert.equal(proxy(request({ host: "127.0.0.1:3000", "sec-fetch-site": "cross-site" }, "GET")).status, 403);
		assert.equal(proxy(request({ host: "127.0.0.1:3000", "sec-fetch-site": "same-site" }, "GET")).status, 403);
	});

	it("rejects DNS rebinding: a non-loopback Host, even with a matching Origin", () => {
		assert.equal(proxy(request({ host: "rebind.evil.example:3000", origin: "http://rebind.evil.example:3000" })).status, 403);
		assert.equal(proxy(request({ host: "localhost.evil.example" }, "GET")).status, 403);
		assert.equal(proxy(request({}, "GET")).status, 403, "no Host at all");
	});

	it("an Origin on another port of the same host is a different origin", () => {
		assert.equal(proxy(request({ host: "127.0.0.1:3000", origin: "http://127.0.0.1:4000" })).status, 403);
	});

	it("guards only /api", () => {
		assert.deepEqual(config.matcher, ["/api/:path*"]);
	});
});
