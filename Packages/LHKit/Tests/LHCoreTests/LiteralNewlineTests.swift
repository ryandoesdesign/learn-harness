import Foundation
import Testing
@testable import LHCore

// A model sometimes double-escapes a tool argument's newlines, so a question
// arrives as one line with backslash-n pairs in it. The display seam turns
// them back into newlines, leaving math, code and real newlines alone.

@Suite struct LiteralNewlineTests {
	@Test func aDoubleEscapedQuestionGetsItsLinesBack() {
		let raw = #"Your ranking finds two things:\n\n- The shortage.\n- AI acceptance.\n\nHow should each be used?"#
		#expect(restoreLiteralNewlines(raw) == "Your ranking finds two things:\n\n- The shortage.\n- AI acceptance.\n\nHow should each be used?")
	}

	@Test(arguments: [
		"Real lines\nstay as they are, even with a literal " + #"\n"# + " later.",
		#"Inline math $\nu \neq \nabla f$ is copied as is."#,
		#"Paren math \(\nu\) and bracket math \[\nabla\] too."#,
		#"Display $$\nabla \cdot E$$ as well."#,
		#"Code `printf("a\n")` keeps its escape."#,
		#"An escaped backslash \\n is a backslash and an n."#,
		"No backslashes at all.",
	])
	func everythingElseIsUnchanged(_ text: String) {
		#expect(restoreLiteralNewlines(text) == text)
	}

	@Test func mathNextToALiteralNewlineSurvives() {
		#expect(restoreLiteralNewlines(#"Let $\nu$ be a frequency.\nThen:"#) == "Let $\\nu$ be a frequency.\nThen:")
	}

	@Test func theQuestionParsersApplyIt() throws {
		let input: JSONValue = [
			"question": .string(#"Two things:\n\n- One\n- Two\n\nWhich?"#),
			"options": .array([["label": .string("A")], ["label": .string("B")]]),
		]
		let ask = try #require(parseAskInput(input))
		#expect(ask.question == "Two things:\n\n- One\n- Two\n\nWhich?")
	}
}
