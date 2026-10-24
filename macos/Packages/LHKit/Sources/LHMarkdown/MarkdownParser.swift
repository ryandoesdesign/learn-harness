import Foundation
import LHCore
import Markdown

/// Message text → blocks. `parseMessageMarkdown` runs the TS pipeline order:
/// `transformMathDelimiters` first (legacy `\(…\)` / `\[…\]` → dollars,
/// escaped dollars inside math), then the math split, then GFM.
public func parseMessageMarkdown(_ text: String) -> [MDBlock] {
	parseMarkdown(transformMathDelimiters(text))
}

/// Markdown (already delimiter-transformed) → blocks.
public func parseMarkdown(_ markdown: String) -> [MDBlock] {
	let pre = mathPrepass(markdown)
	let document = Document(parsing: pre.text, options: [])
	let converter = Converter(inline: pre.inline, lines: pre.text.components(separatedBy: "\n"))
	return converter.blocks(document.children)
}

/// A code fence's source as written (the copy corner's payload).
public func codeSource(_ block: MDBlock) -> String? {
	switch block {
	case .code(_, let source, _, _): source
	case .mermaid(let source, _): source
	case .displayMath(let tex, _): tex
	default: nil
	}
}

nonisolated(unsafe) private let alertMarker = /^\[!(?i:(note|tip|important|warning|caution))\][ \t]*(?:\n|$)/

/// `[!KIND]` at the very start of a quote's first paragraph text → the
/// lowercased kind and the text after the marker line.
public func parseAlertMarker(_ lead: String) -> (kind: String, rest: String)? {
	guard let m = lead.prefixMatch(of: alertMarker) else { return nil }
	return (String(m.1).lowercased(), String(lead[m.range.upperBound...]))
}

private struct Converter {
	let inline: [(tex: String, source: String)]
	/// The rewritten source, for fence-closure checks.
	let lines: [String]

	func blocks(_ children: some Sequence<Markup>) -> [MDBlock] {
		children.compactMap { block($0) }
	}

	func block(_ node: Markup) -> MDBlock? {
		switch node {
		case let p as Paragraph:
			return .paragraph(inlines(p.children))
		case let h as Heading:
			return .heading(level: h.level, inlines(h.children))
		case let l as UnorderedList:
			return .list(ordered: false, start: 1, items: l.listItems.map(item))
		case let l as OrderedList:
			return .list(ordered: true, start: Int(l.startIndex), items: l.listItems.map(item))
		case let q as BlockQuote:
			return quote(q)
		case let c as CodeBlock:
			return code(c)
		case let t as Markdown.Table:
			return table(t)
		case is ThematicBreak:
			return .thematicBreak
		case let h as HTMLBlock:
			return .html(restoreTokens(h.rawHTML.trimmingCharacters(in: .newlines)))
		default:
			let text = restoreTokens(node.format())
			return text.isEmpty ? nil : .paragraph([.text(text)])
		}
	}

	func item(_ li: ListItem) -> MDListItem {
		let checked: Bool? = li.checkbox.map { $0 == .checked }
		return MDListItem(checked: checked, blocks: blocks(li.children))
	}

	func quote(_ q: BlockQuote) -> MDBlock {
		var children = blocks(q.children)
		guard case .paragraph(let runs)? = children.first, case .text(let lead)? = runs.first,
		      let alert = parseAlertMarker(lead)
		else { return .quote(children) }
		// Rebuild the first paragraph without the marker line; drop it when
		// the marker stood alone.
		var rest = Array(runs.dropFirst())
		if !alert.rest.isEmpty { rest.insert(.text(alert.rest), at: 0) }
		while case .lineBreak? = rest.first { rest.removeFirst() }
		if rest.isEmpty || rest.allSatisfy({ $0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }) {
			children.removeFirst()
		} else {
			children[0] = .paragraph(rest)
		}
		return .callout(kind: alert.kind, children)
	}

	func code(_ c: CodeBlock) -> MDBlock {
		let info = c.language ?? ""
		let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
		var source = c.code
		if source.hasSuffix("\n") { source.removeLast() }
		switch language {
		case MATH_FENCE_LANGUAGE?: return .displayMath(tex: source, closed: true)
		case MATH_OPEN_FENCE_LANGUAGE?: return .displayMath(tex: source, closed: false)
		default: break
		}
		source = restoreTokens(source)
		if language == "mermaid" { return .mermaid(source: source, closed: isClosedFence(c)) }
		let meta = info.dropFirst(language?.count ?? 0)
		let startLine = meta.firstMatch(of: /startLine=(\d+)/).flatMap { Int($0.1) }.flatMap { $0 >= 1 ? $0 : nil }
		let lineNumbers = meta.firstMatch(of: /\bnoLineNumbers\b/) == nil
		return .code(language: language, source: source, startLine: startLine, lineNumbers: lineNumbers)
	}

	/// cmark closes an unterminated fence at the end of the document; the
	/// block's last source line tells whether a closing fence exists.
	func isClosedFence(_ c: CodeBlock) -> Bool {
		guard let range = c.range else { return true }
		let first = range.lowerBound.line - 1
		let last = range.upperBound.line - 1
		guard last > first, lines.indices.contains(first), lines.indices.contains(last) else { return false }
		let open = lines[first].trimmingCharacters(in: .whitespaces)
		guard let fenceChar = open.first else { return false }
		let openRun = open.prefix { $0 == fenceChar }.count
		let close = lines[last].trimmingCharacters(in: .whitespaces)
		return close.prefix { $0 == fenceChar }.count >= openRun && close.allSatisfy { $0 == fenceChar }
	}

	func table(_ t: Markdown.Table) -> MDBlock {
		let header: [[MDInline]] = Array(t.head.cells.map { inlines($0.children) })
		let rows: [[[MDInline]]] = t.body.rows.map { row in Array(row.cells.map { inlines($0.children) }) }
		let alignments: [MDAlignment?] = t.columnAlignments.map {
			switch $0 {
			case .left?: .leading
			case .center?: .center
			case .right?: .trailing
			case nil: nil
			}
		}
		return .table(header: header, rows: rows, alignments: alignments)
	}

	func inlines(_ children: some Sequence<Markup>) -> [MDInline] {
		var out: [MDInline] = []
		for child in children { out.append(contentsOf: inlineRuns(child)) }
		return merge(out)
	}

	func inlineRuns(_ node: Markup) -> [MDInline] {
		switch node {
		case let t as Markdown.Text: return expandTokens(t.string)
		case let e as Emphasis: return [.emphasis(inlines(e.children))]
		case let s as Strong: return [.strong(inlines(s.children))]
		case let s as Strikethrough: return [.strikethrough(inlines(s.children))]
		case let c as InlineCode: return [.code(restoreTokens(c.code))]
		case let l as Markdown.Link: return [.link(destination: l.destination, inlines(l.children))]
		case let i as Markdown.Image: return [.link(destination: i.source, inlines(i.children))]
		case is SoftBreak, is LineBreak: return [.lineBreak]
		case let h as InlineHTML: return [.text(restoreTokens(h.rawHTML))]
		case let s as SymbolLink: return [.code(s.destination ?? "")]
		default: return expandTokens(node.format())
		}
	}

	/// Split a text run at placeholder tokens → text + math runs.
	func expandTokens(_ s: String) -> [MDInline] {
		guard s.contains(TOKEN_OPEN) else { return [.text(s)] }
		var out: [MDInline] = []
		var buffer = ""
		var idx = s.startIndex
		while idx < s.endIndex {
			let c = s[idx]
			if c == TOKEN_OPEN, let close = s[idx...].firstIndex(of: TOKEN_CLOSE),
			   let n = Int(s[s.index(after: idx)..<close]), n < inline.count
			{
				if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
				out.append(.math(inline[n].tex))
				idx = s.index(after: close)
				continue
			}
			buffer.append(c)
			idx = s.index(after: idx)
		}
		if !buffer.isEmpty { out.append(.text(buffer)) }
		return out
	}

	/// Placeholder tokens back to their dollar source (code contexts).
	func restoreTokens(_ s: String) -> String {
		guard s.contains(TOKEN_OPEN) else { return s }
		var out = ""
		var idx = s.startIndex
		while idx < s.endIndex {
			let c = s[idx]
			if c == TOKEN_OPEN, let close = s[idx...].firstIndex(of: TOKEN_CLOSE),
			   let n = Int(s[s.index(after: idx)..<close]), n < inline.count
			{
				out += inline[n].source
				idx = s.index(after: close)
				continue
			}
			out.append(c)
			idx = s.index(after: idx)
		}
		return out
	}

	/// Adjacent text runs merged (cmark splits text at escapes and entities).
	func merge(_ runs: [MDInline]) -> [MDInline] {
		var out: [MDInline] = []
		for r in runs {
			if case .text(let b) = r, case .text(let a)? = out.last {
				out[out.count - 1] = .text(a + b)
			} else {
				out.append(r)
			}
		}
		return out
	}
}
