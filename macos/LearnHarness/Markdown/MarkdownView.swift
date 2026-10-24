import AppKit
import LHCore
import LHMarkdown
import LHWeb
import SwiftUI

/// The MessageResponse port: message text → the LHMarkdown block model →
/// SwiftUI blocks. `unit` is the find-unit prefix (LHMarkdown `findUnits`
/// uses the same id scheme), so Find highlights land on the right Text.
struct MarkdownView: View {
	var blocks: [MDBlock]
	var unit: String
	var font: Font = Theme.prose
	var fontSize: CGFloat = Theme.proseSize

	init(_ text: String, unit: String, font: Font = Theme.prose, fontSize: CGFloat = Theme.proseSize) {
		blocks = MarkdownCache.blocks(text)
		self.unit = unit
		self.font = font
		self.fontSize = fontSize
	}

	init(blocks: [MDBlock], unit: String, font: Font = Theme.prose, fontSize: CGFloat = Theme.proseSize) {
		self.blocks = blocks
		self.unit = unit
		self.font = font
		self.fontSize = fontSize
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
				BlockView(block: block, unit: blockUnitId(unit, i), font: font, fontSize: fontSize)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// Parsed blocks per text (the transcript re-renders often; parsing is pure).
@MainActor
enum MarkdownCache {
	private static var cache: [String: [MDBlock]] = [:]
	static func blocks(_ text: String) -> [MDBlock] {
		if let hit = cache[text] { return hit }
		let parsed = parseMessageMarkdown(text)
		if cache.count > 4000 { cache.removeAll() }
		cache[text] = parsed
		return parsed
	}
}

struct BlockView: View {
	var block: MDBlock
	var unit: String
	var font: Font
	var fontSize: CGFloat

	var body: some View {
		switch block {
		case .paragraph(let runs):
			InlineText(runs: runs, unit: unit, font: font, fontSize: fontSize)
		case .heading(let level, let runs):
			let size = headingSize(level)
			InlineText(runs: runs, unit: unit, font: .system(size: size, weight: .semibold, design: .serif), fontSize: size)
				.padding(.top, level <= 2 ? 6 : 2)
		case .list(let ordered, let start, let items):
			ListBlock(ordered: ordered, start: start, items: items, unit: unit, font: font, fontSize: fontSize)
		case .quote(let children):
			HStack(alignment: .top, spacing: 14) {
				Rectangle().fill(Theme.border).frame(width: 4)
				MarkdownView(blocks: children, unit: unit, font: font.italic(), fontSize: fontSize)
					.foregroundStyle(Theme.muted)
			}
			.fixedSize(horizontal: false, vertical: true)
		case .callout(_, let children):
			MarkdownView(blocks: children, unit: unit, font: font, fontSize: fontSize)
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
				.overlay(Rectangle().strokeBorder(Color.primary, lineWidth: 1))
				.fixedSize(horizontal: true, vertical: false)
				.frame(maxWidth: .infinity, alignment: .leading)
		case .code(let language, let source, let startLine, let lineNumbers):
			CodeBlockView(language: language, source: source, startLine: startLine, lineNumbers: lineNumbers, unit: unit)
		case .mermaid(let source, let closed):
			MermaidBlockView(source: source, closed: closed)
		case .displayMath(let tex, let closed):
			DisplayMathView(tex: tex, closed: closed, fontSize: fontSize)
		case .table(let header, let rows, let alignments):
			TableBlock(header: header, rows: rows, alignments: alignments, unit: unit, font: font, fontSize: fontSize)
		case .thematicBreak:
			Divider().padding(.vertical, 4)
		case .html(let raw):
			HighlightedPlainText(text: raw, unit: unit, font: Theme.mono, preformatted: true)
		}
	}

	private func headingSize(_ level: Int) -> CGFloat {
		switch level {
		case 1: fontSize * 1.5
		case 2: fontSize * 1.3
		case 3: fontSize * 1.15
		default: fontSize
		}
	}
}

/// One unit's inline runs as a single selectable Text: math as baseline-
/// aligned template images (raw red TeX when MathJax can't typeset it),
/// inline code as the muted pill, find highlights as backgrounds.
struct InlineText: View {
	var runs: [MDInline]
	var unit: String
	var font: Font
	var fontSize: CGFloat
	@Environment(FindModel.self) private var find: FindModel?

	var body: some View {
		build()
			.font(font)
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func build() -> Text {
		var builder = InlineBuilder(fontSize: fontSize, highlights: find?.highlights(unit) ?? [])
		builder.append(runs, style: .init())
		return builder.text
	}
}

/// Plain (non-markdown) text with find highlights — user bands, thinking.
struct HighlightedPlainText: View {
	var text: String
	var unit: String
	var font: Font
	var preformatted = false
	@Environment(FindModel.self) private var find: FindModel?

	var body: some View {
		var builder = InlineBuilder(fontSize: Theme.proseSize, highlights: find?.highlights(unit) ?? [])
		builder.appendPlain(text)
		return builder.text
			.font(font)
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// Walks runs in `displayText` order (math = one U+FFFC, line break = "\n")
/// so find offsets line up with what is drawn.
@MainActor
struct InlineBuilder {
	struct Style {
		var bold = false
		var italic = false
		var strike = false
		var link: URL?
	}

	var fontSize: CGFloat
	var highlights: [(SessionTextMatch, Bool)]
	private(set) var text = Text("")
	private var offset = 0

	init(fontSize: CGFloat, highlights: [(SessionTextMatch, Bool)]) {
		self.fontSize = fontSize
		self.highlights = highlights
	}

	mutating func append(_ runs: [MDInline], style: Style) {
		for run in runs {
			switch run {
			case .text(let s):
				appendString(s, style: style, code: false)
			case .emphasis(let c):
				var st = style
				st.italic = true
				append(c, style: st)
			case .strong(let c):
				var st = style
				st.bold = true
				append(c, style: st)
			case .strikethrough(let c):
				var st = style
				st.strike = true
				append(c, style: st)
			case .link(let destination, let c):
				var st = style
				st.link = destination.flatMap(URL.init(string:))
				append(c, style: st)
			case .code(let s):
				appendString(s, style: style, code: true)
			case .lineBreak:
				appendString("\n", style: style, code: false)
			case .math(let tex):
				appendMath(tex)
			}
		}
	}

	mutating func appendPlain(_ s: String) {
		appendString(s, style: Style(), code: false)
	}

	private mutating func appendString(_ s: String, style: Style, code: Bool) {
		var a = AttributedString(s)
		if style.bold { a.inlinePresentationIntent = (a.inlinePresentationIntent ?? []).union(.stronglyEmphasized) }
		if style.italic { a.inlinePresentationIntent = (a.inlinePresentationIntent ?? []).union(.emphasized) }
		if style.strike { a.strikethroughStyle = .single }
		if let link = style.link {
			a.link = link
			a.underlineStyle = .single
		}
		if code {
			a.font = .system(size: fontSize * 0.85, design: .monospaced)
			a.backgroundColor = Theme.mutedFill
		}
		let length = s.utf16.count
		paint(&a, start: offset, length: length)
		offset += length
		text = Text("\(text)\(Text(a))")
	}

	private mutating func appendMath(_ tex: String) {
		let start = offset
		offset += 1
		if let r = MathImage.render(tex, size: fontSize, display: false) {
			var piece = Text(Image(nsImage: r.image)).baselineOffset(-r.descent)
			if highlights.contains(where: { $0.0.start <= start && start < $0.0.end }) {
				piece = piece.foregroundStyle(Color.accentColor)
			}
			text = Text("\(text)\(piece)")
		} else {
			var a = AttributedString(tex)
			a.font = .system(size: fontSize * 0.85, design: .monospaced)
			a.foregroundColor = Theme.red
			text = Text("\(text)\(Text(a))")
		}
	}

	/// Background the find matches overlapping [start, start+length).
	private func paint(_ a: inout AttributedString, start: Int, length: Int) {
		guard !highlights.isEmpty, length > 0 else { return }
		for (range, active) in highlights {
			let lo = max(range.start, start) - start
			let hi = min(range.end, start + length) - start
			guard lo < hi else { continue }
			guard let r = utf16Range(in: a, lo, hi) else { continue }
			a[r].backgroundColor = active ? Color.accentColor : Color.accentColor.opacity(0.25)
			if active { a[r].foregroundColor = .white }
		}
	}

	private func utf16Range(in a: AttributedString, _ lo: Int, _ hi: Int) -> Range<AttributedString.Index>? {
		let s = String(a.characters)
		let u = s.utf16
		guard lo <= u.count, hi <= u.count,
		      let sLo = u.index(u.startIndex, offsetBy: lo).samePosition(in: s),
		      let sHi = u.index(u.startIndex, offsetBy: hi).samePosition(in: s)
		else { return nil }
		let cLo = s.distance(from: s.startIndex, to: sLo)
		let cHi = s.distance(from: s.startIndex, to: sHi)
		let start = a.characters.index(a.startIndex, offsetBy: cLo)
		let end = a.characters.index(a.startIndex, offsetBy: cHi)
		return start..<end
	}
}

// MARK: - Lists

struct ListBlock: View {
	var ordered: Bool
	var start: Int
	var items: [MDListItem]
	var unit: String
	var font: Font
	var fontSize: CGFloat

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(Array(items.enumerated()), id: \.offset) { j, item in
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					marker(j, item)
						.font(font)
						.foregroundStyle(Theme.muted)
						.frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
					MarkdownView(blocks: item.blocks, unit: "\(unit).\(j)", font: font, fontSize: fontSize)
				}
			}
		}
	}

	@ViewBuilder
	private func marker(_ j: Int, _ item: MDListItem) -> some View {
		if let checked = item.checked {
			Image(systemName: checked ? "checkmark.square" : "square")
		} else if ordered {
			Text("\(start + j).")
		} else {
			Text("•")
		}
	}
}

// MARK: - Tables

struct TableBlock: View {
	var header: [[MDInline]]
	var rows: [[[MDInline]]]
	var alignments: [MDAlignment?]
	var unit: String
	var font: Font
	var fontSize: CGFloat

	var body: some View {
		ScrollView(.horizontal) {
			Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
				GridRow {
					ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
						cellView(cell, unit: "\(unit).h\(c)", column: c).fontWeight(.semibold)
					}
				}
				Divider().gridCellUnsizedAxes(.horizontal)
				ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
					GridRow {
						ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
							cellView(cell, unit: "\(unit).r\(r).\(c)", column: c)
						}
					}
					if r < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
				}
			}
		}
		.scrollIndicators(.automatic)
		.fixedSize(horizontal: false, vertical: true)
		.copyCorner(label: "Copy table") { tableMarkdown() }
	}

	private func cellView(_ cell: [MDInline], unit: String, column: Int) -> some View {
		InlineText(runs: cell, unit: unit, font: font, fontSize: fontSize)
			.fixedSize()
			.frame(maxWidth: .infinity, alignment: alignment(column))
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
	}

	private func alignment(_ c: Int) -> Alignment {
		switch alignments.indices.contains(c) ? alignments[c] : nil {
		case .center?: .center
		case .trailing?: .trailing
		default: .leading
		}
	}

	/// The copy corner's payload: the table back as GFM Markdown.
	private func tableMarkdown() -> String {
		func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
		let sep = header.indices.map { c -> String in
			switch alignments.indices.contains(c) ? alignments[c] : nil {
			case .center?: ":---:"
			case .trailing?: "---:"
			case .leading?: ":---"
			case nil: "---"
			}
		}
		return ([line(header.map(\.plainText)), line(sep)] + rows.map { line($0.map(\.plainText)) }).joined(separator: "\n")
	}
}

// MARK: - Display math

struct DisplayMathView: View {
	var tex: String
	var closed: Bool
	var fontSize: CGFloat

	var body: some View {
		Group {
			if !closed {
				ProgressView().controlSize(.small).frame(maxWidth: .infinity)
			} else if let r = MathImage.render(tex, size: fontSize, display: true) {
				ScrollView(.horizontal) {
					Image(nsImage: r.image)
						.foregroundStyle(.primary)
						.padding(.vertical, 4)
						.frame(maxWidth: .infinity)
				}
				.scrollIndicators(.never)
				.fixedSize(horizontal: false, vertical: true)
			} else {
				Text(tex)
					.font(.system(size: fontSize * 0.85, design: .monospaced))
					.foregroundStyle(Theme.red)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		}
		.copyCorner(label: "Copy equation source") { tex }
	}
}

// MARK: - Code

struct CodeBlockView: View {
	var language: String?
	var source: String
	var startLine: Int?
	var lineNumbers: Bool
	var unit: String
	@Environment(\.colorScheme) private var scheme
	@Environment(FindModel.self) private var find: FindModel?

	var body: some View {
		let lines = source.components(separatedBy: "\n")
		ScrollView(.horizontal) {
			HStack(alignment: .top, spacing: 12) {
				if lineNumbers {
					VStack(alignment: .trailing, spacing: 0) {
						ForEach(lines.indices, id: \.self) { i in
							Text("\((startLine ?? 1) + i)")
						}
					}
					.font(Theme.mono)
					.foregroundStyle(Theme.faint)
				}
				code
					.font(Theme.mono)
					.textSelection(.enabled)
					.fixedSize()
			}
			.padding(12)
		}
		.fixedSize(horizontal: false, vertical: true)
		.background(RoundedRectangle(cornerRadius: 8).fill(Theme.mutedFill))
		.copyCorner(label: "Copy code") { source }
	}

	private var code: Text {
		var a = CodeHighlighter.highlight(source, language: language, dark: scheme == .dark)
		for (range, active) in find?.highlights(unit) ?? [] {
			let s = String(a.characters)
			let u = s.utf16
			guard range.end <= u.count,
			      let lo = u.index(u.startIndex, offsetBy: range.start).samePosition(in: s),
			      let hi = u.index(u.startIndex, offsetBy: range.end).samePosition(in: s)
			else { continue }
			let start = a.characters.index(a.startIndex, offsetBy: s.distance(from: s.startIndex, to: lo))
			let end = a.characters.index(a.startIndex, offsetBy: s.distance(from: s.startIndex, to: hi))
			a[start..<end].backgroundColor = active ? Color.accentColor : Color.accentColor.opacity(0.25)
		}
		return Text(a)
	}
}

// MARK: - Copy corner

/// The hover copy corner (md-blocks CopyCorner): a muted icon at the
/// block's top-right, visible only while that block is hovered; the icon
/// flips to a check for 1.5s after copying.
struct CopyCorner: ViewModifier {
	var label: String
	var payload: () -> String
	@State private var hovered = false
	@State private var copied = false

	func body(content: Content) -> some View {
		content
			.overlay(alignment: .topTrailing) {
				Button {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(payload(), forType: .string)
					copied = true
					Task {
						try? await Task.sleep(for: .seconds(1.5))
						copied = false
					}
				} label: {
					Image(systemName: copied ? "checkmark" : "doc.on.doc")
						.font(.system(size: 11))
						.frame(width: 24, height: 24)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.foregroundStyle(Theme.muted)
				.help(label)
				.accessibilityLabel(label)
				.opacity(hovered || copied ? 1 : 0)
				.padding(4)
			}
			.onHover { hovered = $0 }
	}
}

extension View {
	func copyCorner(label: String, _ payload: @escaping () -> String) -> some View {
		modifier(CopyCorner(label: label, payload: payload))
	}
}
