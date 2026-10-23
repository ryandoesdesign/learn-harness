import Foundation

// Port of src/core/value-debris.ts — the model-value debris strip (the
// whitehead incident, 2026-10-09: `[":parmenides"]`, `"\"predict\""`).
// Applied at MEMBERSHIP comparisons only — never on free text.

private let debrisScalars: CharacterSet = CharacterSet.jsWhitespace.union(CharacterSet(charactersIn: ":.\"'`"))

/// Strip the copy-syntax debris a model glues onto a membership value: any
/// surrounding run of whitespace, colons, periods, quotes, and backticks
/// (JS `/^[\s:."'`]+/` and `/[\s:."'`]+$/`). The interior is untouched.
public func stripModelValueDebris(_ value: String) -> String {
	let u = value.unicodeScalars
	var start = u.startIndex, end = u.endIndex
	while start < end, debrisScalars.contains(u[start]) { start = u.index(after: start) }
	while end > start, debrisScalars.contains(u[u.index(before: end)]) { end = u.index(before: end) }
	return String(u[start..<end])
}
