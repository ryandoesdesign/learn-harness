import Foundation

// Port of src/core/fuzzy.ts — the model picker's search ranking (pi's
// `/model` pattern): space-separated tokens, each token must match SOME
// field (case-insensitive substring), ranked so exact field matches beat
// prefixes beat buried substrings. Comparisons run on UTF-16 code units so
// scores (which depend on match offsets) equal the JS ones.

/// Score one candidate, or nil when any token matches no field. Higher is
/// better; ties break by list order (stable sort).
///
/// Per-token points: exact field equality 100 · field prefix 60 ·
/// substring 30 minus a depth penalty (min(offset, 27)). Whole-query
/// contiguity in one field adds +50.
public func fuzzyScore(_ query: String, _ fields: String...) -> Int? {
	fuzzyScore(query, fields: fields)
}

public func fuzzyScore(_ query: String, fields: [String]) -> Int? {
	let tokens = query.jsTrimmed.lowercased()
		.components(separatedBy: .jsWhitespace)
		.filter { !$0.isEmpty }
		.map { Array($0.utf16) }
	if tokens.isEmpty { return 0 }
	let hay = fields.map { Array($0.lowercased().utf16) }

	var total = 0
	for token in tokens {
		var best = -1
		for f in hay {
			if f == token { best = max(best, 100) }
			else if f.starts(with: token) { best = max(best, 60) }
			else if let at = utf16IndexOf(f, token) { best = max(best, 30 - min(at, 27)) }
		}
		if best < 0 { return nil }
		total += best
	}
	var joined: [UInt16] = []
	for (i, t) in tokens.enumerated() {
		if i > 0 { joined.append(0x20) }
		joined.append(contentsOf: t)
	}
	if hay.contains(where: { utf16IndexOf($0, joined) != nil }) { total += 50 }
	return total
}

/// JS `indexOf` over code units.
private func utf16IndexOf(_ hay: [UInt16], _ needle: [UInt16]) -> Int? {
	if needle.isEmpty { return 0 }
	guard needle.count <= hay.count else { return nil }
	for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
		if hay[start..<(start + needle.count)].elementsEqual(needle) { return start }
	}
	return nil
}
