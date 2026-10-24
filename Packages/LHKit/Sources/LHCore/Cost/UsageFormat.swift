import Foundation

// Port of components/usage-format.ts and sidebar.tsx `timeAgo` — money,
// token and model presentation helpers.

/// USD for cent-scale money: >= $1 keeps two decimals, smaller keeps four.
public func formatUsd(_ c: Double) -> String {
	c >= 1 ? "$\(jsToFixed(c, 2))" : "$\(jsToFixed(c, 4))"
}

/// 38000 → "38k", 1234567 → "1.2M" — trimmed, never "38.0k".
public func formatTokens(_ n: Int) -> String {
	let d = Double(n)
	if d >= 1e6 { return trimmedFixed1(d / 1e6) + "M" }
	if d >= 1e3 { return trimmedFixed1(d / 1e3) + "k" }
	return String(n)
}

/// `+(x).toFixed(1)` printed as a JS number ("38.0" → "38").
private func trimmedFixed1(_ x: Double) -> String {
	let s = jsToFixed(x, 1)
	return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
}

/// Split a provider-qualified stamp "provider:id"; no colon = a bare id.
public func splitQualified(_ id: String) -> (provider: String?, id: String) {
	guard let colon = id.firstIndex(of: ":") else { return (nil, id) }
	return (String(id[..<colon]), String(id[id.index(after: colon)...]))
}

/// Vendor prefix dropped, a trailing all-digit dash segment dropped, the
/// name kept exactly as written; `qualified` appends "· provider".
public func prettyModel(_ id: String, qualified: Bool = false) -> String {
	let (provider, bare) = splitQualified(id)
	let short = bare.lastIndex(of: "/").map { String(bare[bare.index(after: $0)...]) } ?? bare
	var parts = short.components(separatedBy: "-")
	if let last = parts.last, last.wholeMatch(of: /\d+/) != nil { parts.removeLast() }
	let pretty = parts.joined(separator: "-")
	if qualified, let provider { return "\(pretty) · \(provider)" }
	return pretty
}

/// "just now" / "Nm ago" / "Nh ago" / "Nd ago", then the local YYYY-MM-DD.
public func timeAgo(_ iso: String, now: Date = Date()) -> String {
	guard let date = parseISODate(iso) else { return "" }
	let ms = (now.timeIntervalSince1970 - date.timeIntervalSince1970) * 1000
	if ms < 60_000 { return "just now" }
	let min = Int((ms / 60_000).rounded(.down))
	if min < 60 { return "\(min)m ago" }
	let h = min / 60
	if h < 24 { return "\(h)h ago" }
	let d = h / 24
	if d < 7 { return "\(d)d ago" }
	let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
	return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

private func parseISODate(_ iso: String) -> Date? {
	let f = ISO8601DateFormatter()
	f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
	if let d = f.date(from: iso) { return d }
	f.formatOptions = [.withInternetDateTime]
	return f.date(from: iso)
}

/// JS `Number.prototype.toFixed(digits)` for finite x: rounds the EXACT
/// binary value, ties away from zero (JS picks the larger n).
public func jsToFixed(_ x: Double, _ digits: Int) -> String {
	let negative = x < 0
	// %.60f prints the exact binary expansion (every double's is finite).
	let exact = String(format: "%.60f", abs(x))
	let dot = exact.firstIndex(of: ".")!
	var intDigits = Array(exact[..<dot])
	let frac = Array(exact[exact.index(after: dot)...])
	var kept = Array(frac.prefix(digits))
	let rest = frac.dropFirst(digits)
	if let first = rest.first, first >= "5" {
		// Increment kept (and carry into the integer part).
		var all = intDigits + kept
		var i = all.count - 1
		while i >= 0 {
			if all[i] == "9" { all[i] = "0"; i -= 1 } else { all[i] = Character(String(all[i].wholeNumberValue! + 1)); break }
		}
		if i < 0 { all.insert("1", at: 0) }
		intDigits = Array(all.prefix(all.count - digits))
		kept = Array(all.suffix(digits))
	}
	let body = String(intDigits) + (digits > 0 ? "." + String(kept) : "")
	let isZero = body.allSatisfy { $0 == "0" || $0 == "." }
	return negative && !isZero ? "-" + body : body
}
