import Foundation
import SwiftMath

// The SwiftMath seam (docs/native-macos-m4.md: native math, KaTeX dropped).
// `normalizedTeX` rewrites the KaTeX-isms that have a faithful SwiftMath
// spelling; anything else SwiftMath rejects renders as the red raw-TeX
// fallback. `mathParseError` is the validity check the renderer and the
// tests share (nil = SwiftMath typesets it).

/// Plain spelling swaps (KaTeX command → SwiftMath command).
private let renames: [(String, String)] = [
	("\\tfrac", "\\frac"), ("\\dfrac", "\\frac"), ("\\cfrac", "\\frac"),
	("\\lVert", "\\|"), ("\\rVert", "\\|"), ("\\lvert", "|"), ("\\rvert", "|"),
	("\\varnothing", "\\emptyset"),
	("\\implies", "\\Longrightarrow"), ("\\impliedby", "\\Longleftarrow"),
	("\\dots", "\\ldots"), ("\\dotsc", "\\ldots"), ("\\dotsb", "\\cdots"),
	("\\iiint", "\\int\\!\\!\\int\\!\\!\\int"), ("\\iint", "\\int\\!\\!\\int"),
	("\\smallint", "\\int"), ("\\longmapsto", "\\mapsto"),
	("\\boldsymbol", "\\mathbf"), ("\\bm", "\\mathbf"), ("\\emph", "\\textit"),
	("\\mathop", "\\mathrm"), ("\\Box", "\\square"),
	("\\:", "\\;"), ("\\>", "\\;"),
]

/// Size prefixes on delimiters (`\big(` …): SwiftMath has none — dropped.
private let sizers = ["\\Biggl", "\\Biggr", "\\Bigg", "\\biggl", "\\biggr", "\\bigg", "\\Bigl", "\\Bigr", "\\Big", "\\bigl", "\\bigr", "\\big"]

/// Environments with a SwiftMath equivalent.
private let environments: [(String, String?)] = [
	("align*", "aligned"), ("align", "aligned"), ("gather*", "matrix"), ("gather", "matrix"), ("gathered", "matrix"),
	("equation*", nil), ("equation", nil),
]

/// KaTeX-only spellings → SwiftMath equivalents.
public func normalizedTeX(_ tex: String) -> String {
	var t = tex
	// transformMathDelimiters' escaped-dollar form (`\$` inside inline math).
	t = t.replacingOccurrences(of: "\\text{\\textdollar}", with: "\\$")
	t = t.replacingOccurrences(of: "\\textdollar", with: "\\$")
	t = rewriteCommandWithArgument(t, "\\operatorname*") { "\\mathrm{\($0)}" }
	t = rewriteCommandWithArgument(t, "\\operatorname") { "\\mathrm{\($0)}" }
	t = rewriteCommandWithArgument(t, "\\pmod") { "\\;(\\mathrm{mod}\\;\($0))" }
	t = rewriteCommandWithArgument(t, "\\tag") { "\\quad(\($0))" }
	t = rewriteCommandWithArgument(t, "\\phantom") { _ in "" }
	t = rewriteCommandWithArgument(t, "\\hspace") { _ in "\\quad" }
	for (from, to) in renames { t = replaceCommand(t, from, to) }
	for s in sizers { t = replaceCommand(t, s, "") }
	for (env, to) in environments {
		t = t.replacingOccurrences(of: "\\begin{\(env)}", with: to.map { "\\begin{\($0)}" } ?? "")
		t = t.replacingOccurrences(of: "\\end{\(env)}", with: to.map { "\\end{\($0)}" } ?? "")
	}
	return t
}

/// SwiftMath's parse error for `tex` (after normalization), or nil.
public func mathParseError(_ tex: String) -> String? {
	var error: NSError?
	let list = MTMathListBuilder.build(fromString: normalizedTeX(tex), error: &error)
	if let error { return error.localizedDescription }
	return list == nil ? "Unparseable math" : nil
}

/// Replace a control word only where it ends (not a prefix of a longer
/// command: `\big` must not hit `\bigcup`). Control symbols (`\:`) always match.
private func replaceCommand(_ s: String, _ command: String, _ replacement: String) -> String {
	guard s.contains(command) else { return s }
	let isWord = command.last?.isLetter == true
	var out = ""
	var rest = Substring(s)
	while let r = rest.range(of: command) {
		let after = rest[r.upperBound...].first
		// An odd run of backslashes before the match means its own backslash
		// closes a `\\` row break — not a command.
		var run = 0
		var k = r.lowerBound
		while k > rest.startIndex, rest[rest.index(before: k)] == "\\" { run += 1; k = rest.index(before: k) }
		if k == rest.startIndex, out.hasSuffix("\\") { run += out.reversed().prefix { $0 == "\\" }.count }
		let precededByBackslash = run % 2 == 1
		if (isWord && after?.isLetter == true) || precededByBackslash {
			out += rest[..<r.upperBound]
		} else {
			out += rest[..<r.lowerBound] + replacement
		}
		rest = rest[r.upperBound...]
	}
	return out + rest
}

/// `\cmd{arg}` → transform(arg), brace-balanced; a missing brace leaves it.
private func rewriteCommandWithArgument(_ s: String, _ command: String, _ transform: (String) -> String) -> String {
	guard s.contains(command) else { return s }
	var out = ""
	var rest = Substring(s)
	while let r = rest.range(of: command) {
		var i = r.upperBound
		if command.last?.isLetter == true, i < rest.endIndex, rest[i].isLetter || rest[i] == "*" {
			out += rest[..<i]
			rest = rest[i...]
			continue
		}
		while i < rest.endIndex, rest[i] == " " { i = rest.index(after: i) }
		guard i < rest.endIndex, rest[i] == "{" else {
			out += rest[..<r.upperBound]
			rest = rest[r.upperBound...]
			continue
		}
		var depth = 0
		var j = i
		var close: Substring.Index?
		while j < rest.endIndex {
			if rest[j] == "\\" { j = rest.index(after: j); if j < rest.endIndex { j = rest.index(after: j) }; continue }
			if rest[j] == "{" { depth += 1 }
			if rest[j] == "}" { depth -= 1; if depth == 0 { close = j; break } }
			j = rest.index(after: j)
		}
		guard let close else { out += rest; return out }
		out += rest[..<r.lowerBound] + transform(String(rest[rest.index(after: i)..<close]))
		rest = rest[rest.index(after: close)...]
	}
	return out + rest
}
