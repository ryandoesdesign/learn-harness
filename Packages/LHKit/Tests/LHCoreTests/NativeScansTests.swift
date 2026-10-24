import Foundation
import Testing
@testable import LHCore

@Suite struct NativeScansGoldenTests {
	@Test(arguments: [Fixtures.teachChatId, Fixtures.practiceChatId])
	func everyPrefixMatchesTS(chatId: String) throws {
		let golden = try Golden.load("scans.\(chatId)")
		let messages = try Fixtures.chat(chatId).messages
		for row in golden["prefixes"]?.arrayValue ?? [] {
			let n = try #require(row["n"]?.intValue)
			let prefix = Array(messages.prefix(n))
			let dangling = danglingQuestionOf(prefix).map { d -> JSONValue in
				["toolCallId": .string(d.toolCallId), "tool": .string(d.tool), "input": d.input]
			} ?? .null
			let active = activeProblemOf(prefix).map { p -> JSONValue in ["toolCallId": .string(p.toolCallId), "input": p.input] } ?? .null
			let actual: JSONValue = [
				"n": .number(n),
				"dangling": dangling,
				"needsContinuation": .bool(needsContinuation(prefix)),
				"endsInDismissal": .bool(endsInDismissal(prefix)),
				"activeProblem": active,
				"pendingDismissal": pendingProblemDismissalOf(prefix).map(JSONValue.string) ?? .null,
				"hasProbeDone": .bool(hasProbeDone(prefix)),
			]
			expectJSONEqual(actual, row)
		}
		for row in golden["problemInputs"]?.arrayValue ?? [] {
			let id = try #require(row["concludeCallId"]?.stringValue)
			expectJSONEqual(problemInputForConclude(messages, concludeCallId: id) ?? .null, row["input"]!)
		}
	}

	@Test func dismissalPairIsDeterministicOffTheProblemCall() {
		let (a, r) = concludedByDismissalPair(problemCallId: "call_p1", now: 5)
		#expect(a.assistant?.toolUses.first?.id == "call_conc_call_p1")
		#expect(r.toolResult?.toolUseId == "call_conc_call_p1")
		#expect(r.toolResult?.firstText == CONCLUDE_ACK_TEXT)
	}
}
