import Foundation

/// Port of src/core/math-delims.ts — legacy `\(…\)`/`\[…\]` delimiter
/// preprocessing, escaped-dollar normalization, JSON-debris restoration and
/// the over-escaped command heal. Byte-identical to the TS for every input.
///
/// Every scan runs on the UTF-16 code-unit array (JS string indexing). All
/// slice boundaries sit on ASCII delimiters, so a slice never splits a
/// surrogate pair and the final UTF-16 → String decode is lossless.
///
/// The TS regexes are hand-expanded into code-unit scans (see the comment on
/// each helper for the equivalence argument); no Swift/ICU regex engine is
/// used, so none of the `\s`/`\b`/`.`/flag differences can leak in.

// MARK: - Public API

/// Rewrite balanced `\(...\)` → `$$...$$` and `\[...\]` → `$$\n...\n$$`;
/// inside balanced inline `$…$` spans, `\$` → `\text{\textdollar}`.
/// Everything else passes through byte-for-byte.
public func transformMathDelimiters(_ markdown: String) -> String {
	let s = Array(markdown.utf16)
	var out: [UInt16] = []
	out.reserveCapacity(s.count)
	var i = 0

	while i < s.count {
		let ch = s[i]

		// Fenced code blocks: copied verbatim (only detectable at line start).
		if atLineStart(s, i) && fenceOpenMarker(s, i) != nil {
			i = copyFencedBlock(s, i, &out)
			continue
		}

		// Inline code spans: copied verbatim.
		if ch == U.tick {
			let run = backtickRun(s, i)
			var j = i + run
			while j < s.count {
				let nextRun = backtickRun(s, j)
				if nextRun == run { break }
				j += Swift.max(nextRun, 1)
			}
			if j < s.count {
				out.append(contentsOf: s[i..<(j + run)])
				i = j + run
			} else {
				out.append(contentsOf: s[i..<(i + run)])
				i += run
			}
			continue
		}

		// Math delimiters.
		if ch == U.backslash && !isEscaped(s, i) {
			let next = at(s, i + 1)
			if next == U.lparen || next == U.lbracket {
				let isDisplay = next == U.lbracket
				let closeChar = isDisplay ? U.rbracket : U.rparen
				let closeAt = findClose(s, i + 2, closeChar)
				if closeAt != -1 {
					let content = jsTrim(Array(s[(i + 2)..<closeAt]))
					if !content.isEmpty {
						if isDisplay && displayIsIndented(s, i) {
							// Indented display math degrades to the inline form;
							// mathText cannot span line endings, so collapse them.
							out.append(contentsOf: U.dollars2)
							out.append(contentsOf: collapseNewlineWhitespace(content))
							out.append(contentsOf: U.dollars2)
						} else if isDisplay {
							let afterClose = closeAt + 2
							if !displayIsBlockPositioned(s, i) { out.append(contentsOf: [U.newline, U.newline]) }
							out.append(contentsOf: U.dollars2)
							out.append(U.newline)
							out.append(contentsOf: content)
							out.append(U.newline)
							out.append(contentsOf: U.dollars2)
							if !closeEndsLine(s, afterClose) { out.append(contentsOf: [U.newline, U.newline]) }
						} else {
							out.append(contentsOf: U.dollars2)
							out.append(contentsOf: content)
							out.append(contentsOf: U.dollars2)
						}
						i = closeAt + 2
						continue
					}
				}
				// Unbalanced or empty: leave both characters untouched.
			}
		}

		// Escaped dollars inside inline math; display runs copied whole.
		if ch == U.dollar && !isEscaped(s, i) {
			let run = dollarRun(s, i)
			if run == 1 {
				let closeAt = findInlineDollarCloseEscapeAware(s, i + 1)
				if closeAt != -1 {
					// The whole balanced span is copied, escapes replaced. DELIBERATE
					// DIVERGENCE from math-delims.ts (owner, 2026-10-24): TS copies
					// only the opening `$` of a clean span and rescans inside it, so
					// the span's closing `$` reopens a bogus span that swallows any
					// later `\(…\)`, `\[…\]` or `\$` up to the next dollar.
					let content = Array(s[(i + 1)..<closeAt])
					out.append(U.dollar)
					out.append(contentsOf: replaceEscapedDollars(content))
					out.append(U.dollar)
					i = closeAt + 1
					continue
				}
			} else {
				out.append(contentsOf: s[i..<(i + run)])
				i += run
				continue
			}
		}

		out.append(ch)
		i += 1
	}

	return string(out)
}

/// Shared display-only repair. Keep raw arguments and model history unchanged.
public func repairMathForDisplay(_ text: String) -> String {
	healOverescapedCommands(restoreMathEscapes(text))
}

/// LaTeX-escape restoration — the JSON-debris fix (see the TS for the rules).
public func restoreMathEscapes(_ text: String) -> String {
	let s = Array(text.utf16)
	if !s.contains(where: isDebris) { return text }
	return string(restoreDollarMathEscapes(restoreLegacyMathEscapes(s)))
}

/// Over-escaped command heal — collapse even backslash runs before a command
/// start inside balanced math spans (see the TS for the rules).
public func healOverescapedCommands(_ text: String) -> String {
	let s = Array(text.utf16)
	// `text.includes("\\\\")`: two adjacent backslashes anywhere.
	guard s.indices.dropLast().contains(where: { s[$0] == U.backslash && s[$0 + 1] == U.backslash }) else { return text }
	var out: [UInt16] = []
	out.reserveCapacity(s.count)
	var i = 0
	while i < s.count {
		if atLineStart(s, i) && fenceOpenMarker(s, i) != nil {
			i = copyFencedBlock(s, i, &out)
			continue
		}
		if s[i] == U.tick {
			let after = codeSpanEnd(s, i)
			out.append(contentsOf: s[i..<after])
			i = after
			continue
		}
		if s[i] == U.backslash && !isEscaped(s, i) {
			let next = at(s, i + 1)
			if next == U.lparen || next == U.lbracket {
				let isDisplay = next == U.lbracket
				let closeChar = isDisplay ? U.rbracket : U.rparen
				let closeAt = findClose(s, i + 2, closeChar)
				if closeAt != -1 {
					out.append(contentsOf: s[i..<(i + 2)])
					out.append(contentsOf: halveOverescapedCommandRuns(Array(s[(i + 2)..<closeAt])))
					out.append(contentsOf: s[closeAt..<(closeAt + 2)])
					i = closeAt + 2
					continue
				}
			}
		}
		if s[i] == U.dollar && !isEscaped(s, i) {
			let size = dollarRun(s, i)
			let isDisplay = dollarIsDisplay(s, i, size)
			if let close = findDollarClose(s, i + size, size, isDisplay) {
				out.append(contentsOf: s[i..<(i + size)])
				out.append(contentsOf: halveOverescapedCommandRuns(Array(s[(i + size)..<close.at])))
				out.append(contentsOf: s[close.at..<close.after])
				i = close.after
				continue
			}
			out.append(contentsOf: s[i..<(i + size)])
			i += size
			continue
		}
		out.append(s[i])
		i += 1
	}
	return string(out)
}

// MARK: - Code units

private enum U {
	static let backslash: UInt16 = 0x5C
	static let lparen: UInt16 = 0x28
	static let rparen: UInt16 = 0x29
	static let lbracket: UInt16 = 0x5B
	static let rbracket: UInt16 = 0x5D
	static let dollar: UInt16 = 0x24
	static let tick: UInt16 = 0x60
	static let tilde: UInt16 = 0x7E
	static let newline: UInt16 = 0x0A
	static let cr: UInt16 = 0x0D
	static let space: UInt16 = 0x20
	static let tab: UInt16 = 0x09
	static let dollars2: [UInt16] = [0x24, 0x24]
	/// `\text{\textdollar}`
	static let textDollar: [UInt16] = Array("\\text{\\textdollar}".utf16)
}

private func string(_ units: [UInt16]) -> String {
	String(decoding: units, as: UTF16.self)
}

/// `text[i]` — nil past the end (JS `undefined`).
private func at(_ s: [UInt16], _ i: Int) -> UInt16? {
	i >= 0 && i < s.count ? s[i] : nil
}

// MARK: - Shared scanning helpers

/// Is the backslash at `i` itself escaped (odd number of backslashes before)?
private func isEscaped(_ s: [UInt16], _ i: Int) -> Bool {
	var count = 0
	var j = i - 1
	while j >= 0 && s[j] == U.backslash {
		count += 1
		j -= 1
	}
	return count % 2 == 1
}

private func backtickRun(_ s: [UInt16], _ i: Int) -> Int {
	var count = 0
	while i + count < s.count && s[i + count] == U.tick { count += 1 }
	return count
}

private func dollarRun(_ s: [UInt16], _ i: Int) -> Int {
	var count = 0
	while i + count < s.count && s[i + count] == U.dollar { count += 1 }
	return count
}

/// The code-span skip shared by restoreDollarMathEscapes/heal: the index
/// after the matching same-length run, or after the opening run if unclosed.
private func codeSpanEnd(_ s: [UInt16], _ i: Int) -> Int {
	let run = backtickRun(s, i)
	var j = i + run
	while j < s.count {
		let nextRun = backtickRun(s, j)
		if nextRun == run { break }
		j += Swift.max(nextRun, 1)
	}
	return j < s.count ? j + run : i + run
}

/// Closing `\)`/`\]` for an opener ending at `from`; `` ` `` is a barrier.
/// -1 when unbalanced.
private func findClose(_ s: [UInt16], _ from: Int, _ closeChar: UInt16) -> Int {
	var j = from
	while j < s.count - 1 {
		if s[j] == U.tick { return -1 }
		if s[j] == U.backslash && s[j + 1] == closeChar && !isEscaped(s, j) { return j }
		j += 1
	}
	return -1
}

private func atLineStart(_ s: [UInt16], _ i: Int) -> Bool {
	i == 0 || s[i - 1] == U.newline
}

/// `FENCE_OPEN_RE = /^ {0,3}(`{3,}|~{3,})/` tested on `text.slice(i)` — no
/// `m` flag, so `^` is the slice start. Returns group 1 as (char, length).
/// Equivalence: backtracking ` {0,3}` to fewer spaces only leaves another
/// space before the marker, so "≤3 spaces then a maximal run" is exact.
private func fenceOpenMarker(_ s: [UInt16], _ i: Int) -> (char: UInt16, length: Int)? {
	var j = i
	while j < s.count && j - i < 3 && s[j] == U.space { j += 1 }
	guard j < s.count, s[j] == U.tick || s[j] == U.tilde else { return nil }
	let c = s[j]
	var k = j
	while k < s.count && s[k] == c { k += 1 }
	return k - j >= 3 ? (c, k - j) : nil
}

/// `new RegExp("^ {0,3}\\" + marker[0] + "{" + len + ",}[ \\t]*$")` on one
/// line (already split at `\n`; may still hold `\r`, which `[ \t]` rejects —
/// so a CRLF closing fence does not close, exactly as in JS). No `m` flag:
/// `$` is end of the line string.
private func isClosingFence(_ s: ArraySlice<UInt16>, _ c: UInt16, _ length: Int) -> Bool {
	var j = s.startIndex
	while j < s.endIndex && j - s.startIndex < 3 && s[j] == U.space { j += 1 }
	var k = j
	while k < s.endIndex && s[k] == c { k += 1 }
	guard k - j >= length else { return false }
	while k < s.endIndex && (s[k] == U.space || s[k] == U.tab) { k += 1 }
	return k == s.endIndex
}

/// Copy a fenced block starting at line-start `i` verbatim; returns the index
/// after the closing fence line, or the end when unclosed.
private func copyFencedBlock(_ s: [UInt16], _ i: Int, _ out: inout [UInt16]) -> Int {
	let marker = fenceOpenMarker(s, i) ?? (U.tick, 3)
	var j = i
	while j < s.count {
		let lineEnd = s[j...].firstIndex(of: U.newline)
		let next = lineEnd.map { $0 + 1 } ?? s.count
		let line = s[j..<(lineEnd ?? s.count)]
		out.append(contentsOf: s[j..<next])
		if j > i && isClosingFence(line, marker.char, marker.length) { return next }
		j = next
	}
	return s.count
}

/// Only whitespace (space/tab) between the previous `\n` (or start) and `i`.
private func displayIsBlockPositioned(_ s: [UInt16], _ i: Int) -> Bool {
	var j = i - 1
	while j >= 0 {
		let ch = s[j]
		if ch == U.newline { return true }
		if ch != U.space && ch != U.tab { return false }
		j -= 1
	}
	return true
}

private func displayIsIndented(_ s: [UInt16], _ i: Int) -> Bool {
	var sawWhitespace = false
	var j = i - 1
	while j >= 0 {
		let ch = s[j]
		if ch == U.newline { return sawWhitespace }
		if ch != U.space && ch != U.tab { return false }
		sawWhitespace = true
		j -= 1
	}
	return sawWhitespace
}

private func closeEndsLine(_ s: [UInt16], _ afterClose: Int) -> Bool {
	afterClose >= s.count || s[afterClose] == U.newline
}

// MARK: - JS whitespace

/// ECMAScript WhiteSpace + LineTerminator — the set JS `\s` and `trim()`
/// use (all BMP, so a per-code-unit test is exact). Same set as
/// `CharacterSet.jsWhitespace`.
private func isJSWhitespace(_ c: UInt16) -> Bool {
	switch c {
	case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
	     0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	default:
		return false
	}
}

/// `String.prototype.trim` on code units.
private func jsTrim(_ s: [UInt16]) -> [UInt16] {
	var lo = 0
	var hi = s.count
	while lo < hi && isJSWhitespace(s[lo]) { lo += 1 }
	while hi > lo && isJSWhitespace(s[hi - 1]) { hi -= 1 }
	return Array(s[lo..<hi])
}

/// `content.replace(/\s*\n\s*/g, " ")`. Equivalence: the leading greedy `\s*`
/// backtracks to the run's LAST `\n` and the trailing `\s*` takes the rest,
/// so each maximal JS-whitespace run containing a `\n` becomes one space;
/// runs without `\n` never match (inner start positions fail the same way).
private func collapseNewlineWhitespace(_ s: [UInt16]) -> [UInt16] {
	var out: [UInt16] = []
	out.reserveCapacity(s.count)
	var i = 0
	while i < s.count {
		guard isJSWhitespace(s[i]) else {
			out.append(s[i])
			i += 1
			continue
		}
		var j = i
		var sawNewline = false
		while j < s.count && isJSWhitespace(s[j]) {
			if s[j] == U.newline { sawNewline = true }
			j += 1
		}
		if sawNewline {
			out.append(U.space)
		} else {
			out.append(contentsOf: s[i..<j])
		}
		i = j
	}
	return out
}

// MARK: - Escaped dollars (transform)

/// An escaped dollar never closes; otherwise the first lone `$` closes and
/// longer runs are skipped whole.
private func findInlineDollarCloseEscapeAware(_ s: [UInt16], _ from: Int) -> Int {
	var j = from
	while j < s.count {
		if s[j] != U.dollar {
			j += 1
			continue
		}
		if isEscaped(s, j) {
			j += 1
			continue
		}
		let count = dollarRun(s, j)
		if count == 1 { return j }
		j += count
	}
	return -1
}

/// `\$` (odd-backslash) → `\text{\textdollar}`; even-backslash dollars stay.
private func replaceEscapedDollars(_ content: [UInt16]) -> [UInt16] {
	var replaced: [UInt16] = []
	replaced.reserveCapacity(content.count)
	var j = 0
	while j < content.count {
		if content[j] == U.backslash && at(content, j + 1) == U.dollar && !isEscaped(content, j) {
			replaced.append(contentsOf: U.textDollar)
			j += 2
		} else {
			replaced.append(content[j])
			j += 1
		}
	}
	return replaced
}

// MARK: - Escape debris

/// `DEBRIS_RE = /[\b\t\n\v\f\r]/` — inside a class `\b` is U+0008.
private func isDebris(_ c: UInt16) -> Bool {
	c == 0x08 || c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D
}

/// `DISPLAY_DEBRIS_RE = /[\b\t\v\f\r]/` — debris minus `\n`.
private func isDisplayDebris(_ c: UInt16) -> Bool {
	c != 0x0A && isDebris(c)
}

/// `inner.replace(DEBRIS_RE, c => ESCAPE_DEBRIS[c])` — the regexes have no
/// `g` flag, so ONLY THE FIRST debris char is restored (pinned by the TS
/// "first-match-only" test).
private func replaceFirstDebris(_ s: ArraySlice<UInt16>, display: Bool) -> [UInt16] {
	var out = Array(s)
	guard let k = out.firstIndex(where: display ? isDisplayDebris : isDebris) else { return out }
	let letter: UInt16
	switch out[k] {
	case 0x08: letter = 0x62 // b
	case 0x09: letter = 0x74 // t
	case 0x0A: letter = 0x6E // n
	case 0x0B: letter = 0x76 // v
	case 0x0C: letter = 0x66 // f
	default: letter = 0x72 // r
	}
	out.replaceSubrange(k...k, with: [U.backslash, letter])
	return out
}

private func restoreLegacyMathEscapes(_ s: [UInt16]) -> [UInt16] {
	if !s.contains(where: isDebris) { return s }
	var out: [UInt16] = []
	out.reserveCapacity(s.count)
	var i = 0
	while i < s.count {
		let ch = s[i]
		if ch == U.backslash && !isEscaped(s, i) {
			let next = at(s, i + 1)
			if next == U.lparen || next == U.lbracket {
				let isDisplay = next == U.lbracket
				let closeChar = isDisplay ? U.rbracket : U.rparen
				let closeAt = findClose(s, i + 2, closeChar)
				if closeAt != -1 {
					out.append(contentsOf: s[i..<(i + 2)])
					out.append(contentsOf: replaceFirstDebris(s[(i + 2)..<closeAt], display: isDisplay))
					out.append(contentsOf: s[closeAt..<(closeAt + 2)])
					i = closeAt + 2
					continue
				}
			}
		}
		out.append(ch)
		i += 1
	}
	return out
}

/// Native math fences start at a line's block position; one-line `$$…$$`
/// remains inline. A flow opener may have metadata, but never another `$`.
private func dollarIsDisplay(_ s: [UInt16], _ i: Int, _ size: Int) -> Bool {
	if size < 2 || !displayIsBlockPositioned(s, i) { return false }
	let start = Swift.min(i + size, s.count)
	let end = s[start...].firstIndex(of: U.newline) ?? s.count
	return !s[start..<end].contains(U.dollar)
}

/// `/^([ \t]{0,3})(\$+)[ \t]*\r?$/.exec(line)` (no `m` flag; the line is
/// split at `\n` but may contain `\r`). Returns (group 1 length, group 2
/// length). Equivalence: no backtracking choice can change the outcome —
/// fewer leading blanks leave a blank before `$`, a shorter `$` run leaves a
/// `$` that `[ \t]*\r?` cannot consume.
private func matchDisplayCloseLine(_ s: ArraySlice<UInt16>) -> (indent: Int, run: Int)? {
	var j = s.startIndex
	while j < s.endIndex && j - s.startIndex < 3 && (s[j] == U.space || s[j] == U.tab) { j += 1 }
	var k = j
	while k < s.endIndex && s[k] == U.dollar { k += 1 }
	guard k > j else { return nil }
	var m = k
	while m < s.endIndex && (s[m] == U.space || s[m] == U.tab) { m += 1 }
	if m < s.endIndex && s[m] == U.cr { m += 1 }
	guard m == s.endIndex else { return nil }
	return (j - s.startIndex, k - j)
}

/// micromark's delimiter runs: exact size inline, at least the opener's size
/// on an otherwise-empty line for display.
private func findDollarClose(_ s: [UInt16], _ from: Int, _ size: Int, _ isDisplay: Bool) -> (at: Int, after: Int)? {
	if isDisplay {
		var lineEnd = from < s.count ? s[from...].firstIndex(of: U.newline) : nil
		while let le = lineEnd {
			let start = le + 1
			lineEnd = start < s.count ? s[start...].firstIndex(of: U.newline) : nil
			let line = s[start..<(lineEnd ?? s.count)]
			if let close = matchDisplayCloseLine(line), close.run >= size {
				let at = start + close.indent
				return (at, at + close.run)
			}
		}
		return nil
	}
	var j = from
	while j < s.count {
		if s[j] != U.dollar {
			j += 1
			continue
		}
		let count = dollarRun(s, j)
		if count == size { return (j, j + count) }
		j += count
	}
	return nil
}

/// Dollar recognition only — the same six/five-character repair maps.
private func restoreDollarMathEscapes(_ s: [UInt16]) -> [UInt16] {
	if !s.contains(where: isDebris) || !s.contains(U.dollar) { return s }
	var out: [UInt16] = []
	out.reserveCapacity(s.count)
	var i = 0
	while i < s.count {
		if atLineStart(s, i) && fenceOpenMarker(s, i) != nil {
			i = copyFencedBlock(s, i, &out)
			continue
		}
		if s[i] == U.tick {
			let after = codeSpanEnd(s, i)
			out.append(contentsOf: s[i..<after])
			i = after
			continue
		}
		// Legacy spans were handled by the first pass; copy them whole.
		if s[i] == U.backslash && !isEscaped(s, i) {
			let next = at(s, i + 1)
			if next == U.lparen || next == U.lbracket {
				let closeAt = findClose(s, i + 2, next == U.lbracket ? U.rbracket : U.rparen)
				if closeAt != -1 {
					out.append(contentsOf: s[i..<(closeAt + 2)])
					i = closeAt + 2
					continue
				}
			}
		}
		if s[i] == U.dollar && !isEscaped(s, i) {
			let size = dollarRun(s, i)
			let isDisplay = dollarIsDisplay(s, i, size)
			if let close = findDollarClose(s, i + size, size, isDisplay) {
				out.append(contentsOf: s[i..<(i + size)])
				out.append(contentsOf: replaceFirstDebris(s[(i + size)..<close.at], display: isDisplay))
				out.append(contentsOf: s[close.at..<close.after])
				i = close.after
				continue
			}
			out.append(contentsOf: s[i..<(i + size)])
			i += size
			continue
		}
		out.append(s[i])
		i += 1
	}
	return out
}

// MARK: - Over-escaped commands

/// `COMMAND_START_CLASS = [A-Za-z,;:!|]` (ASCII only; no `i`/`u` flag).
private func isCommandStart(_ c: UInt16) -> Bool {
	(c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
		|| c == 0x2C || c == 0x3B || c == 0x3A || c == 0x21 || c == 0x7C
}

/// `inner.replace(/(\\+)(?=[A-Za-z,;:!|])/g, run => run.length % 2 === 0 ? "\\" : run)`.
/// Equivalence: the scan reaches a run's first backslash first; a match
/// there takes the whole run (backtracking leaves a `\` before the
/// lookahead, which the class rejects), and starts inside a run fail the
/// same way — so each maximal run followed by a command start is replaced.
private func halveOverescapedCommandRuns(_ s: [UInt16]) -> [UInt16] {
	var out: [UInt16] = []
	out.reserveCapacity(s.count)
	var i = 0
	while i < s.count {
		guard s[i] == U.backslash else {
			out.append(s[i])
			i += 1
			continue
		}
		var j = i
		while j < s.count && s[j] == U.backslash { j += 1 }
		let length = j - i
		if j < s.count && isCommandStart(s[j]) && length % 2 == 0 {
			out.append(U.backslash)
		} else {
			out.append(contentsOf: s[i..<j])
		}
		i = j
	}
	return out
}
