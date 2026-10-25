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

	@Test func discussSetsAsideEveryOpenQuestionThenAddsTheMessage() throws {
		let two = Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [
			.toolUse(id: "c1", name: "probe", input: ["question": "Q?"]), .toolUse(id: "c2", name: "explain", input: ["question": "Why?"]),
		], model: "m", stopReason: "tool_use")))
		let out = try inputAppends([two], kind: nil, .discuss(toolCallId: "c1", text: "What's a force?"), now: 1)
		#expect(out.compactMap(\.toolResult?.toolUseId) == ["c1", "c2"])
		#expect(out.last?.user != nil)
		#expect(out.first?.toolResult?.details?["discussed"]?.boolValue == true)
		let face = try JSONValue.parse(Data((out[1].toolResult?.content.first?.raw["text"]?.stringValue ?? "").utf8))
		#expect(face["kind"]?.stringValue == "explain" && face["discussed"]?.boolValue == true && face["note"]?.stringValue == DISCUSSED_NOTE)
		#expect(danglingQuestionOf([two] + out) == nil)
	}
	@Test func discussIsRefusedWithoutAnOpenQuestionOrText() {
		#expect(throws: ChatInputError("discuss input targets no pending question call")) { try inputAppends([], kind: nil, .discuss(toolCallId: "c1", text: "hm")) }
		#expect(throws: ChatInputError("discuss input requires non-empty text")) { try inputAppends([q], kind: nil, .discuss(toolCallId: "c1", text: "  ")) }
	}
	@Test func theSetAsideCallsAreReposedAfterTheReply() throws {
		var record = [q] + (try inputAppends([q], kind: nil, .discuss(toolCallId: "c1", text: "hm"), now: 1))
		record.append(Message(id: "a1", timestamp: 2, body: .assistant(AssistantBody(content: [.text("A force is…")], model: "m", stopReason: "stop"))))
		let reposed = reposeAppends(record, now: 3)
		let call = try #require(reposed.first?.assistant?.toolUses.first)
		#expect(call.id == "rp1_c1" && call.name == "probe" && call.input == q.assistant?.toolUses.first?.input)
		#expect(reposed.first?.assistant?.model == REPOSE_MODEL)
		record += reposed
		#expect(danglingQuestionOf(record)?.toolCallId == "rp1_c1")
		#expect(reposeAppends(record).isEmpty, "re-posed once")

		// Set aside again: the next copy counts up from the same origin.
		record += try inputAppends(record, kind: nil, .discuss(toolCallId: "rp1_c1", text: "and?"), now: 4)
		record.append(Message(id: "a2", timestamp: 5, body: .assistant(AssistantBody(content: [.text("Also…")], model: "m", stopReason: "stop"))))
		#expect(reposeAppends(record).first?.assistant?.toolUses.first?.id == "rp2_c1")
		#expect(reposeOrigin("rp2_c1") == "c1" && reposeOrigin("c1") == "c1")
	}
	@Test func aNewQuestionReplacesTheSetAsideOneButAnAbortedOneDoesNot() throws {
		let base = [q] + (try inputAppends([q], kind: nil, .discuss(toolCallId: "c1", text: "hm"), now: 1))
		let asked = Message(id: "a1", timestamp: 2, body: .assistant(AssistantBody(content: [.toolUse(id: "c9", name: "probe", input: ["question": "New?"])], model: "m", stopReason: "tool_use")))
		#expect(reposeAppends(base + [asked]).isEmpty)
		var aborted = asked
		aborted.body = .assistant(AssistantBody(content: [.toolUse(id: "c9", name: "probe", input: ["question": "New?"])], model: "m", stopReason: "aborted"))
		#expect(reposeAppends(base + [aborted]).count == 1)
	}
	@Test func theReposedShuffleMatchesTheOriginal() throws {
		let input: JSONValue = ["question": "Q?", "options": [["label": "A", "value": "a"], ["label": "B", "value": "b"], ["label": "C", "value": "c"], ["label": "D", "value": "d"]], "explanation": "A.", "correctAnswer": "a"]
		let a = try #require(dockQuestion(tool: "probe", toolCallId: "toolu_x", input: input, now: 0))
		let b = try #require(dockQuestion(tool: "probe", toolCallId: "rp3_toolu_x", input: input, now: 0))
		#expect(a.options.map(\.label) == b.options.map(\.label))
	}
}
