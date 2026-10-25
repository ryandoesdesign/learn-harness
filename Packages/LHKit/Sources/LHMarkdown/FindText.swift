import Foundation
import LHCore

// Session Find over displayed text (port of the session-find-dom seam's
// rules): each rendered text unit (a paragraph, heading, cell, code block…)
// is searched on its own — matches never cross units. Prose whitespace
// collapses (a phrase with spaces, tabs or line breaks between words
// matches); code keeps its literal whitespace. Math renders as an image,
// so it is one unsearchable object-replacement character.

/// The object replacement character standing in for an inline math image.
public let MATH_PLACEHOLDER = "\u{FFFC}"

/// A unit's displayed text, in the same order the renderer lays it out:
/// math → U+FFFC, line breaks → "\n".
public func displayText(_ runs: [MDInline]) -> String {
	runs.map { run -> String in
		switch run {
		case .text(let s), .code(let s): s
		case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, let c): displayText(c)
		case .math: MATH_PLACEHOLDER
		case .lineBreak: "\n"
		}
	}.joined()
}

/// Matches of `query` in a unit, as UTF-16 offsets into `text` as given.
public func findMatches(in text: String, query: String, preformatted: Bool = false) -> [SessionTextMatch] {
	guard !query.isEmpty else { return [] }
	if preformatted { return findSessionTextMatches(text, query) }
	// Collapse whitespace runs to one space, remembering where each
	// collapsed unit came from.
	let units = Array(text.utf16)
	var collapsed: [UInt16] = []
	var origin: [Int] = []
	var i = 0
	while i < units.count {
		if isCollapsible(units[i]) {
			let start = i
			while i < units.count, isCollapsible(units[i]) { i += 1 }
			collapsed.append(0x20)
			origin.append(start)
		} else {
			collapsed.append(units[i])
			origin.append(i)
			i += 1
		}
	}
	origin.append(units.count)
	let haystack = String(decoding: collapsed, as: UTF16.self)
	return findSessionTextMatches(haystack, query).map { m in
		// The end maps to just past the last matched original unit.
		let lastOrigin = origin[m.end - 1]
		let end = collapsed[m.end - 1] == 0x20 && isCollapsible(units[lastOrigin]) ? runEnd(units, lastOrigin) : lastOrigin + 1
		return SessionTextMatch(start: origin[m.start], end: end)
	}
}

private func isCollapsible(_ u: UInt16) -> Bool {
	u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x0C
}

private func runEnd(_ units: [UInt16], _ from: Int) -> Int {
	var j = from
	while j < units.count, isCollapsible(units[j]) { j += 1 }
	return j
}

/// One searchable text unit of a rendered block tree.
public struct FindUnit: Sendable, Hashable {
	/// Stable id: the renderer derives the same id for the same `Text`.
	public var id: String
	public var text: String
	public var preformatted: Bool
	public init(id: String, text: String, preformatted: Bool) {
		self.id = id
		self.text = text
		self.preformatted = preformatted
	}
}

/// The unit id of block `index` under `prefix` (the renderer's scheme).
public func blockUnitId(_ prefix: String, _ index: Int) -> String { "\(prefix).\(index)" }

/// Every searchable unit of `blocks`, in reading order. Ids nest by path:
/// a block is `prefix.i`; list item j's blocks `prefix.i.j.k`; quote and
/// callout children `prefix.i.k`; table cells `prefix.i.h<c>` /
/// `prefix.i.r<r>.<c>`. Math and mermaid have no searchable text.
public func findUnits(_ blocks: [MDBlock], prefix: String) -> [FindUnit] {
	var out: [FindUnit] = []
	for (i, block) in blocks.enumerated() {
		let id = blockUnitId(prefix, i)
		switch block {
		case .paragraph(let runs), .heading(_, let runs):
			out.append(FindUnit(id: id, text: displayText(runs), preformatted: false))
		case .list(_, _, let items):
			for (j, item) in items.enumerated() { out += findUnits(item.blocks, prefix: "\(id).\(j)") }
		case .quote(let children), .callout(_, let children):
			out += findUnits(children, prefix: id)
		case .code(_, let source, _, _):
			out.append(FindUnit(id: id, text: source, preformatted: true))
		case .table(let header, let rows, _):
			for (c, cell) in header.enumerated() { out.append(FindUnit(id: "\(id).h\(c)", text: displayText(cell), preformatted: false)) }
			for (r, row) in rows.enumerated() {
				for (c, cell) in row.enumerated() { out.append(FindUnit(id: "\(id).r\(r).\(c)", text: displayText(cell), preformatted: false)) }
			}
		case .html(let s):
			out.append(FindUnit(id: id, text: s, preformatted: true))
		case .mermaid, .displayMath, .thematicBreak:
			break
		}
	}
	return out
}

/// A block's text as a reading note quotes it: inline runs as displayed
/// but math as its TeX, children and cells space-joined; diagrams and
/// rules have none.
public func quotedText(_ block: MDBlock) -> String {
	switch block {
	case .paragraph(let runs), .heading(_, let runs): runs.plainText
	case .list(_, _, let items): items.flatMap(\.blocks).map(quotedText).joined(separator: " ")
	case .quote(let children), .callout(_, let children): children.map(quotedText).joined(separator: " ")
	case .code(_, let source, _, _): source
	case .displayMath(let tex, _): tex
	case .table(let header, let rows, _): ([header] + rows).flatMap { $0.map(\.plainText) }.joined(separator: " ")
	case .html(let s): s
	case .mermaid, .thematicBreak: ""
	}
}
