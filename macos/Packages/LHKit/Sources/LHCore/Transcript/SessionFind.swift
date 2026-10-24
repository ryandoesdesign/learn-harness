import Foundation

// Port of src/core/session-find.ts — literal, case-insensitive session Find
// over displayed text. Offsets are UTF-16 into the text as-is.

public struct SessionTextMatch: Sendable, Hashable {
	public var start: Int
	public var end: Int
	public init(start: Int, end: Int) {
		self.start = start
		self.end = end
	}
}

/// Every literal, case-insensitive occurrence of `query` in `text`
/// (non-overlapping, left to right — `matchAll` with the `giu` flags).
public func findSessionTextMatches(_ text: String, _ query: String) -> [SessionTextMatch] {
	guard !query.isEmpty else { return [] }
	let ns = text as NSString
	var out: [SessionTextMatch] = []
	var from = 0
	while from <= ns.length {
		let r = ns.range(of: query, options: [.caseInsensitive, .literal], range: NSRange(location: from, length: ns.length - from))
		guard r.location != NSNotFound, r.length > 0 else { break }
		out.append(SessionTextMatch(start: r.location, end: r.location + r.length))
		from = r.location + r.length
	}
	return out
}

/// Wraparound step through `count` matches; -1 when there are none.
public func stepSessionMatch(_ index: Int, _ count: Int, _ direction: Int) -> Int {
	guard count > 0 else { return -1 }
	return ((index + direction) % count + count) % count
}
