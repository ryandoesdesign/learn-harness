import Foundation
import Testing
@testable import LHCore

// Port of core/input-events.ts's contract: the appends per input, and the
// orphan discipline (answers/dismissals target the dangling question).

private let q = Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [.toolUse(id: "c1", name: "probe", input: ["question": "Q?"])], model: "m", stopReason: "tool_use")))

private func answer(_ kind: QuestionKind = .quiz) -> QuestionAnswerData {
	QuestionAnswerData(kind: kind, questionText: "Q?", dontKnow: true, answers: [], answeredAt: "t")
}

@Suite struct InputEventsTests {
	@Test func textAppendsTheUserMessage() throws {
		let out = try inputAppends([], kind: nil, .text("hi"), now: 1)
		#expect(out.count == 1 && out[0].user != nil)
	}
	@Test func anAnswerBecomesTheDanglingCallsResult() throws {
		let out = try inputAppends([q], kind: nil, .answer(toolCallId: "c1", answer: answer()), now: 1)
		#expect(out.first?.toolResult?.toolUseId == "c1")
		#expect(out.first?.toolResult?.toolName == "probe")
	}
	@Test func anOrphanAnswerIsRefused() {
		#expect(throws: ChatInputError("answer input targets no pending question call")) { try inputAppends([q], kind: nil, .answer(toolCallId: "zz", answer: answer())) }
		#expect(throws: ChatInputError("answer input targets no pending question call")) { try inputAppends([], kind: nil, .answer(toolCallId: "c1", answer: answer())) }
	}
	@Test func continueAppendsNothingWithoutAParkedProblemDismissal() throws {
		#expect(try inputAppends([q], kind: nil, .continue).isEmpty)
	}
	@Test func nextIsPracticeOnly() {
		#expect(throws: ChatInputError("next input is a practice-session affordance")) { try inputAppends([], kind: .teach, .next) }
	}
	@Test func aDismissalMustBeADismissalOfTheRightKind() throws {
		var d = answer()
		#expect(throws: ChatInputError("dismiss input's answer must be a dismissal (dismissed: true)")) { try dismissAppends([q], .dismiss(toolCallId: "c1", answer: d)) }
		d = dismissedAnswer(.ask, questionText: "Q?")
		#expect(throws: ChatInputError("dismiss input's answer kind does not match the question")) { try dismissAppends([q], .dismiss(toolCallId: "c1", answer: d)) }
		let ok = try dismissAppends([q], .dismiss(toolCallId: "c1", answer: dismissedAnswer(.quiz, questionText: "Q?")))
		#expect(endsInDismissal([q] + ok))
	}
}
