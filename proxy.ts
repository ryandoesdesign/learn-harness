import { NextResponse, type NextRequest } from "next/server";

/**
 * The API guard (security hardening, 2026-10-24): the local server answers
 * only requests that come from the app itself. Any website the user visits
 * could otherwise POST to 127.0.0.1:<port>/api/… (simple requests skip the
 * CORS preflight) or read responses through DNS rebinding. Three checks:
 *   - Host must be loopback (a rebound hostname fails here);
 *   - an Origin header, when sent, must be this same origin;
 *   - Sec-Fetch-Site, when sent, must be same-origin or none.
 * Header-less callers (scripts/smoke-server.mjs, curl) pass — local
 * programs can read the data dir directly anyway; the guard is about the
 * browser. Route handlers stay untouched.
 */
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);

export function proxy(request: NextRequest): NextResponse {
	const host = request.headers.get("host") ?? "";
	if (!LOOPBACK_HOSTS.has(hostnameOf(host))) return forbidden("host is not loopback");
	const origin = request.headers.get("origin");
	if (origin !== null && origin !== `http://${host}`) return forbidden("cross-origin request");
	const fetchSite = request.headers.get("sec-fetch-site");
	if (fetchSite !== null && fetchSite !== "same-origin" && fetchSite !== "none") {
		return forbidden("cross-site request");
	}
	return NextResponse.next();
}

/** "127.0.0.1:3000" → "127.0.0.1"; "[::1]:3000" → "[::1]". */
function hostnameOf(host: string): string {
	return host.startsWith("[") ? host.slice(0, host.indexOf("]") + 1) : host.split(":")[0]!;
}

function forbidden(reason: string): NextResponse {
	return NextResponse.json({ error: `Forbidden: ${reason}` }, { status: 403 });
}

export const config = {
	matcher: ["/api/:path*"],
};
