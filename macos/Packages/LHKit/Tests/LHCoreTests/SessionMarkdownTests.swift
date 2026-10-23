import Foundation
import Testing
@testable import LHCore

// Port of tests/session-markdown.test.ts.

private func user(_ id: String, _ text: String) -> Message {
	newUserMessage(text, id: id, now: 0)
}

private func teacher(_ id: String, _ text: String) -> Message {
	Message(id: id, timestamp: 0, body: .assistant(AssistantBody(content: [.text(text)], model: "openrouter:test", stopReason: "end_turn")))
}

private func result(_ id: String, _ toolCallId: String, _ toolName: String, _ details: JSONValue, isError: Bool = false) -> Message {
	Message(id: id, timestamp: 0, body: .toolResult(ToolResultBody(
		toolUseId: toolCallId, toolName: toolName, content: [.text("ok")], isError: isError, details: details.isNull ? nil : details)))
}

/// An assistant message carrying one tool_use (the practice join's call side).
private func callMsg(_ id: String, _ callId: String, _ name: String, _ args: JSONValue) -> Message {
	Message(id: id, timestamp: 0, body: .assistant(AssistantBody(content: [.toolUse(id: callId, name: name, input: args)], model: "openrouter:test", stopReason: "tool_use")))
}

/// JS `/^line$/m`: some line equals `line` exactly.
private func hasLine(_ md: String?, _ line: String) -> Bool {
	(md ?? "").split(separator: "\n", omittingEmptySubsequences: false).contains { $0 == line }
}

@Suite struct SessionMessageMarkdownTests {
	@Test func speakerBlocksWithTheIdAnchor() {
		#expect(messageMarkdown(user("u1", "teach me the chain rule"), "u1") == "### Learner · u1\n\nteach me the chain rule")
		#expect(messageMarkdown(teacher("a1", "The derivative measures change."), "a1") == "### Teacher · a1\n\nThe derivative measures change.")
	}

	@Test func anchorsOff() {
		#expect(messageMarkdown(user("u1", "hello"), "u1", anchors: false) == "### Learner\n\nhello")
	}

	@Test func quizBlocks() {
		let md = messageMarkdown(result("r1", "q1", "quiz", ["questionText": "What is a derivative?", "correct": false, "dontKnow": false, "note": "mixed up signs"]), "r1")
		#expect(hasLine(md, "### Quiz · r1"))
		#expect(md?.contains("**Q:** What is a derivative?") == true)
		#expect(md?.contains("The learner answered incorrectly.") == true)
		#expect(md?.contains("*(his thinking: mixed up signs)*") == true)
	}

	@Test func explainResultsShowTheLearnersOwnWords() {
		let md = messageMarkdown(result("r1", "e1", "explain", ["questionText": "Why does Mercury stay near the Sun?", "text": "it never strays far"]), "r1")
		#expect(hasLine(md, "### Recall check · r1"))
		#expect(md?.contains("The learner answered in his own words: it never strays far") == true)
	}

	@Test func probePhaseQuestionsExportUnderTheirOwnNames() {
		let probe = messageMarkdown(result("r1", "p1", "probe", ["questionText": "What is a derivative?", "correct": true, "dontKnow": false]), "r1")
		#expect(hasLine(probe, "### Probe · r1"))
		let recall = messageMarkdown(result("r2", "rr1", "recall", ["questionText": "Why does Mercury stay near the Sun?", "text": "it never strays far"]), "r2")
		#expect(hasLine(recall, "### Recall · r2"))
	}

	@Test func askBlocks() {
		let chosen = messageMarkdown(result("r1", "a1", "ask_user_question", ["questionText": "Which way?", "answers": ["second"], "other": "also the third"]), "r1")
		#expect(hasLine(chosen, "### Question · r1"))
		#expect(chosen?.contains("The learner chose: second, also the third") == true)
		let free = messageMarkdown(result("r2", "a2", "ask_user_question", ["questionText": "Why?", "text": "because"]), "r2")
		#expect(free?.contains("The learner answered: because") == true)
	}

	@Test func otherCleanToolResultsOneLineFailedAndMarkersNothing() {
		#expect(messageMarkdown(result("r1", "j1", "research", ["brief": "long"]), "r1") == "### Tool · r1\n\n*research result delivered*")
		#expect(messageMarkdown(result("r2", "j2", "research", [:], isError: true), "r2") == nil, "a failed call is retry context")
		#expect(messageMarkdown(user("u3", "   "), "u3") == nil, "empty text renders nothing")
		#expect(messageMarkdown(newNextMessage(id: "mk", now: 0), "mk") == nil, "markers are invisible")
	}
}

@Suite struct SessionMarkdownPracticeJoinTests {
	@Test func aProblemResultRendersThePosesStatement() {
		let md = sessionMarkdown([
			callMsg("a1", "call-p1", "problem", ["statement": "Push the prior through the learning transition.", "mode": "recall", "target": [], "modelSolution": "Two phases, in forced order."]),
			result("r1", "call-p1", "problem", nil),
		])
		#expect(md.contains("### Problem"))
		#expect(md.contains("Push the prior through the learning transition."))
		#expect(!md.contains("Two phases"), "the solution does NOT leak at pose time")
	}

	@Test func aConcludeResultRendersOutcomeVerdictAndTheReveal() {
		let md = sessionMarkdown([
			callMsg("a1", "call-p1", "problem", ["statement": "Compute P(knows | correct).", "modelSolution": "Bayes, twice over."]),
			result("r1", "call-p1", "problem", nil),
			callMsg("a2", "call-c1", "conclude", ["outcome": "solvedWithHints", "verdict": "Right answer, one nudge."]),
			result("r2", "call-c1", "conclude", nil),
		])
		#expect(md.contains("### Concluded"))
		#expect(md.contains("**Solved with hints.** Right answer, one nudge."))
		#expect(md.contains("> **Model solution**"))
		#expect(md.contains("> Bayes, twice over."))
	}

	@Test func aDismissedProblemConcludesWithoutLeakingTheSolution() {
		let md = sessionMarkdown([
			callMsg("a1", "call-p1", "problem", ["statement": "Derive the posterior.", "modelSolution": "The answer."]),
			result("r1", "call-p1", "problem", nil),
			callMsg("a2", "call-c1", "conclude", ["outcome": "dismissed"]),
			result("r2", "call-c1", "conclude", nil),
		])
		#expect(md.contains("The learner skipped this problem."))
		#expect(!md.contains("The answer."))
		#expect(md.contains("### Problem"))
	}

	@Test func anErroredPoseRendersNothing() {
		let md = sessionMarkdown([
			callMsg("a1", "call-p1", "problem", ["statement": "Never acked."]),
			result("r1", "call-p1", "problem", nil, isError: true),
		])
		#expect(!md.contains("### Problem"))
		#expect(!md.contains("Never acked."))
	}

	/// Swift-side: multi-line solutions quote every line, CRLF included.
	@Test func multiLineSolutionsQuoteEveryLine() {
		let md = sessionMarkdown([
			callMsg("a1", "call-p1", "problem", ["statement": "S", "modelSolution": "one\r\ntwo\nthree"]),
			result("r1", "call-p1", "problem", nil),
			callMsg("a2", "call-c1", "conclude", ["outcome": "unsolved"]),
			result("r2", "call-c1", "conclude", nil),
		], anchors: false)
		#expect(md.hasSuffix("### Concluded\n\n**Unsolved.**\n\n> **Model solution**\n>\n> one\r\n> two\n> three"))
	}
}

@Suite struct SessionMarkdownDocumentTests {
	@Test func assemblesBlocksInOrderUnderTheTitleSkippingNothings() {
		let md = sessionMarkdown([user("u1", "go"), teacher("a1", "First."), user("u2", "  ")], title: "My session")
		#expect(md == "# My session\n\n### Learner · u1\n\ngo\n\n### Teacher · a1\n\nFirst.")
	}

	@Test func noTitleNoHeaderAnchorsDefaultOn() {
		#expect(sessionMarkdown([user("u1", "go")]) == "### Learner · u1\n\ngo")
	}

	/// The seam-split case, markdown side only (messageViewLines is
	/// core/coverage.ts, ported separately): every clean message renders,
	/// the failed call does not.
	@Test func theSeamSplitMarkdownSide() {
		let messages = [
			user("u1", "teach me"),
			teacher("a1", "The chain rule multiplies local rates."),
			result("r1", "q1", "quiz", ["questionText": "Q?", "correct": true, "dontKnow": false]),
			result("r2", "j1", "research", ["brief": "b"]),
			result("r3", "j2", "research", [:], isError: true),
		]
		#expect(messages.map { messageMarkdown($0, $0.id) != nil } == [true, true, true, true, false])
	}
}
