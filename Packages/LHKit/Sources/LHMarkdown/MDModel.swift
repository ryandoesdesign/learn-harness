import Foundation

// The block model the transcript renders — the native counterpart of the TS
// MessageResponse pipeline (Streamdown + remark-gfm + remark-breaks +
// remark-math + md-blocks overrides). Pure values; SwiftUI draws them.

/// An inline run.
public indirect enum MDInline: Sendable, Hashable {
	case text(String)
	case emphasis([MDInline])
	case strong([MDInline])
	case strikethrough([MDInline])
	/// An inline code span (the muted pill).
	case code(String)
	case link(destination: String?, [MDInline])
	/// Inline (text) math — the TeX between the dollar runs.
	case math(String)
	/// remark-breaks: every soft line break renders as a hard break.
	case lineBreak
}

public enum MDAlignment: Sendable, Hashable {
	case leading, center, trailing
}

/// A block.
public indirect enum MDBlock: Sendable, Hashable {
	case paragraph([MDInline])
	case heading(level: Int, [MDInline])
	/// `items` are each a block list; `checked` is per item (nil = no task box).
	case list(ordered: Bool, start: Int, items: [MDListItem])
	/// A plain blockquote: left rail, italic, muted.
	case quote([MDBlock])
	/// A GitHub alert (`[!NOTE]` etc.): the sharp outlined key-idea box.
	case callout(kind: String, [MDBlock])
	case code(language: String?, source: String, startLine: Int?, lineNumbers: Bool)
	/// A `mermaid` fence; `closed` is false while the fence is still open.
	case mermaid(source: String, closed: Bool)
	/// Flow math (`$$` fence lines); `closed` is false while unterminated.
	case displayMath(tex: String, closed: Bool)
	case table(header: [[MDInline]], rows: [[[MDInline]]], alignments: [MDAlignment?])
	case thematicBreak
	/// Raw HTML — shown as literal text (no HTML rendering natively).
	case html(String)
}

public struct MDListItem: Sendable, Hashable {
	public var checked: Bool?
	public var blocks: [MDBlock]
	public init(checked: Bool?, blocks: [MDBlock]) {
		self.checked = checked
		self.blocks = blocks
	}
}

extension MDInline {
	/// The displayed text of a run (math shows its TeX; find skips math —
	/// see `findText`).
	public var plainText: String {
		switch self {
		case .text(let s), .code(let s): s
		case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, let c): c.plainText
		case .math(let tex): tex
		case .lineBreak: "\n"
		}
	}
}

extension [MDInline] {
	public var plainText: String { map(\.plainText).joined() }
}
