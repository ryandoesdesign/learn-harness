import Foundation
import LHCore
import Testing
@testable import LHMarkdown

// The per-unit display text Find searches (port of the session-find DOM
// seam cases that have a native meaning).

private func m(_ s: Int, _ e: Int) -> SessionTextMatch { SessionTextMatch(start: s, end: e) }

@Suite struct FindTextTests {
	@Test func matchesTextSpanningInlineMarkupWithinOneUnit() {
		let blocks = parseMessageMarkdown("say **hello** *world* now")
		guard case .paragraph(let runs) = blocks[0] else { Issue.record(); return }
		let text = displayText(runs)
		#expect(text == "say hello world now")
		#expect(findMatches(in: text, query: "hello world") == [m(4, 15)])
	}
	@Test func neverAcrossBlocks() {
		let blocks = parseMessageMarkdown("ends here\n\nnext block")
		let units = blocks.compactMap { b -> String? in if case .paragraph(let r) = b { return displayText(r) }; return nil }
		#expect(units.allSatisfy { findMatches(in: $0, query: "here next").isEmpty })
	}
	@Test func collapsedWhitespaceMatches() {
		let text = "a phrase\twith \n  gaps"
		#expect(findMatches(in: text, query: "phrase with gaps") == [m(2, 21)])
	}
	@Test func codeKeepsLiteralWhitespace() {
		#expect(findMatches(in: "a  b", query: "a b", preformatted: true).isEmpty)
		#expect(findMatches(in: "a  b", query: "a  b", preformatted: true) == [m(0, 4)])
	}
	@Test func mathIsAnUnsearchableObject() {
		let blocks = parseMessageMarkdown("see $x^2$ here")
		guard case .paragraph(let runs) = blocks[0] else { Issue.record(); return }
		let text = displayText(runs)
		#expect(text == "see \u{FFFC} here")
		#expect(findMatches(in: text, query: "x^2").isEmpty)
		#expect(findMatches(in: text, query: "here") == [m(6, 10)])
	}
	@Test func lineBreaksCollapseLikeSpaces() {
		let text = displayText([.text("line one"), .lineBreak, .text("line two")])
		#expect(findMatches(in: text, query: "one line") == [m(5, 13)])
	}
	@Test func emptyQueryReturnsNothing() {
		#expect(findMatches(in: "anything", query: "").isEmpty)
	}
}

@Suite struct FindUnitTests {
	@Test func unitsFollowTheRenderPath() {
		let blocks = parseMessageMarkdown("Intro\n\n- one\n- two\n\n> [!NOTE]\n> boxed\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```js\nx  y\n```\n\n$$\nx\n$$")
		let units = findUnits(blocks, prefix: "m")
		#expect(units.map(\.id) == ["m.0", "m.1.0.0", "m.1.1.0", "m.2.0", "m.3.h0", "m.3.h1", "m.3.r0.0", "m.3.r0.1", "m.4"])
		#expect(units.map(\.text) == ["Intro", "one", "two", "boxed", "a", "b", "1", "2", "x  y"])
		#expect(units.last?.preformatted == true)
	}
}
