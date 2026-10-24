import Foundation

// The math split — runs BEFORE cmark so TeX never meets markdown escaping
// (remark-math's role in the TS pipeline, after transformMathDelimiters):
//
//   - flow math: a line opening with `$$` (no further `$` on it) through a
//     line opening with `$$` → a fenced `lh-math` block (unclosed runs to
//     the end, as micromark's math flow does);
//   - text math: a run of n unescaped `$` closed by the next run of exactly
//     n on the same line (singleDollarTextMath; code-span logic: ANY
//     size-matched run closes, `\$` included) → a private-use placeholder
//     token, mapped back to `MDInline.math` after parsing.
//
// Code fences and inline code spans are copied verbatim.

/// The fence language marking a flow-math block in the rewritten text.
let MATH_FENCE_LANGUAGE = "lh-math"
let MATH_OPEN_FENCE_LANGUAGE = "lh-math-open"
let TOKEN_OPEN: Character = "\u{E000}"
let TOKEN_CLOSE: Character = "\u{E001}"

struct MathPrepass {
	/// The rewritten markdown.
	var text: String
	/// Placeholder index → (TeX, the original source with its dollars).
	var inline: [(tex: String, source: String)]
}

private enum C {
	static let dollar = UInt16(UInt8(ascii: "$"))
	static let tick = UInt16(UInt8(ascii: "`"))
	static let tilde = UInt16(UInt8(ascii: "~"))
	static let backslash = UInt16(UInt8(ascii: "\\"))
	static let newline = UInt16(UInt8(ascii: "\n"))
	static let space = UInt16(UInt8(ascii: " "))
	static let tab = UInt16(UInt8(ascii: "\t"))
}

func mathPrepass(_ markdown: String) -> MathPrepass {
	let lines = markdown.components(separatedBy: "\n")
	var out: [String] = []
	var inline: [(String, String)] = []
	var i = 0
	var paragraph: [String] = []

	func flushParagraph() {
		guard !paragraph.isEmpty else { return }
		out.append(replaceInlineMath(paragraph.joined(separator: "\n"), &inline))
		paragraph.removeAll()
	}

	while i < lines.count {
		let line = lines[i]
		let (indent, body) = splitIndent(line)

		// Code fences: verbatim through the closing fence.
		if let fence = fenceMarker(body) {
			flushParagraph()
			out.append(line)
			i += 1
			while i < lines.count {
				out.append(lines[i])
				let (_, b) = splitIndent(lines[i])
				i += 1
				if isClosingFence(b, fence) { break }
			}
			continue
		}

		// Flow math.
		if body.hasPrefix("$$"), !body.dropFirst(2).contains("$") {
			flushParagraph()
			var content: [String] = []
			var closed = false
			var j = i + 1
			while j < lines.count {
				let (_, b) = splitIndent(lines[j])
				if b.hasPrefix("$$") {
					closed = true
					break
				}
				content.append(dedent(lines[j], indent.count))
				j += 1
			}
			let tex = content.joined(separator: "\n")
			let fence = String(repeating: "`", count: max(3, longestBacktickRun(tex) + 1))
			out.append(indent + fence + (closed ? MATH_FENCE_LANGUAGE : MATH_OPEN_FENCE_LANGUAGE))
			for c in content { out.append(indent + c) }
			out.append(indent + fence)
			i = closed ? j + 1 : j
			continue
		}

		if body.trimmingCharacters(in: .whitespaces).isEmpty {
			flushParagraph()
			out.append(line)
		} else {
			paragraph.append(line)
		}
		i += 1
	}
	flushParagraph()
	return MathPrepass(text: out.joined(separator: "\n"), inline: inline)
}

/// Leading whitespace and container markers (`>`), and the rest.
private func splitIndent(_ line: String) -> (String, String) {
	var idx = line.startIndex
	while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" || line[idx] == ">" { idx = line.index(after: idx) }
	return (String(line[..<idx]), String(line[idx...]))
}

private func dedent(_ line: String, _ n: Int) -> String {
	var dropped = 0
	var idx = line.startIndex
	while dropped < n, idx < line.endIndex, line[idx] == " " || line[idx] == "\t" || line[idx] == ">" {
		idx = line.index(after: idx)
		dropped += 1
	}
	return String(line[idx...])
}

private func fenceMarker(_ body: String) -> (Character, Int)? {
	guard let first = body.first, first == "`" || first == "~" else { return nil }
	let run = body.prefix { $0 == first }.count
	guard run >= 3 else { return nil }
	if first == "`", body.dropFirst(run).contains("`") { return nil }
	return (first, run)
}

private func isClosingFence(_ body: String, _ fence: (Character, Int)) -> Bool {
	let run = body.prefix { $0 == fence.0 }.count
	return run >= fence.1 && body.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty
}

private func longestBacktickRun(_ s: String) -> Int {
	var best = 0
	var cur = 0
	for c in s {
		if c == "`" { cur += 1; best = max(best, cur) } else { cur = 0 }
	}
	return best
}

/// Replace text math in one paragraph-ish chunk with placeholder tokens.
private func replaceInlineMath(_ chunk: String, _ inline: inout [(String, String)]) -> String {
	let s = Array(chunk.utf16)
	var out: [UInt16] = []
	out.reserveCapacity(s.count)
	var i = 0
	func run(_ c: UInt16, _ at: Int) -> Int {
		var j = at
		while j < s.count, s[j] == c { j += 1 }
		return j - at
	}
	while i < s.count {
		let ch = s[i]
		if ch == C.backslash, i + 1 < s.count, s[i + 1] == C.dollar || s[i + 1] == C.tick || s[i + 1] == C.backslash {
			out.append(contentsOf: s[i...(i + 1)])
			i += 2
			continue
		}
		if ch == C.tick {
			let n = run(C.tick, i)
			var j = i + n
			var close = -1
			while j < s.count {
				if s[j] == C.tick {
					let m = run(C.tick, j)
					if m == n { close = j; break }
					j += m
				} else { j += 1 }
			}
			if close != -1 {
				out.append(contentsOf: s[i..<(close + n)])
				i = close + n
			} else {
				out.append(contentsOf: s[i..<(i + n)])
				i += n
			}
			continue
		}
		if ch == C.dollar {
			let n = run(C.dollar, i)
			var j = i + n
			var close = -1
			while j < s.count, s[j] != C.newline {
				if s[j] == C.dollar {
					let m = run(C.dollar, j)
					if m == n { close = j; break }
					j += m
				} else { j += 1 }
			}
			if close != -1, close > i + n {
				let tex = String(decoding: s[(i + n)..<close], as: UTF16.self)
				let source = String(decoding: s[i..<(close + n)], as: UTF16.self)
				if !tex.trimmingCharacters(in: .whitespaces).isEmpty {
					out.append(contentsOf: "\(TOKEN_OPEN)\(inline.count)\(TOKEN_CLOSE)".utf16)
					inline.append((tex.trimmingCharacters(in: .whitespaces), source))
					i = close + n
					continue
				}
			}
			out.append(contentsOf: s[i..<(i + n)])
			i += n
			continue
		}
		out.append(ch)
		i += 1
	}
	return String(decoding: out, as: UTF16.self)
}
