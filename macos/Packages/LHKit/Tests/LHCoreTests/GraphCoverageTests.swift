import Foundation
import Testing
@testable import LHCore

// Port of tests/coverage.test.ts — the teacher-prose ruling: fingerprints,
// slots, tokens and batching all derive from the teacher's text blocks.

private func user(_ id: String, _ text: String) -> Message { newUserMessage(text, id: id, now: 0) }

private func teacher(_ id: String, _ text: String) -> Message {
	Message(id: id, timestamp: 0, body: .assistant(AssistantBody(content: [.text(text)], model: "claude-opus-5-5", stopReason: "end_turn")))
}

private func assistantWithCalls(_ id: String, _ calls: [(id: String, name: String, args: JSONValue)]) -> Message {
	Message(id: id, timestamp: 0, body: .assistant(AssistantBody(
		content: calls.map { Block.toolUse(id: $0.id, name: $0.name, input: $0.args) }, model: "claude-opus-5-5", stopReason: "tool_use")))
}

/// newAnswerResult: a tool result carrying "ok" text + the details payload.
private func result(_ id: String, _ callId: String, _ name: String, _ details: JSONValue, isError: Bool = false) -> Message {
	Message(id: id, timestamp: 0, body: .toolResult(ToolResultBody(toolUseId: callId, toolName: name, content: [.text("ok")], isError: isError, details: details)))
}

private func slot(_ messages: [Message], _ id: String) throws -> CoverageSlot {
	try #require(coverageSlots(messages).first { $0.message.id == id }, "slot \(id)")
}

@Suite("messageFingerprint — what changes it, what never does")
struct GraphCoverageFingerprintTests {
	@Test func aTextEditChangesTheFingerprintRoleParticipates() {
		let a = messageFingerprint(teacher("m1", "hello world"))
		let b = messageFingerprint(teacher("m1", "hello worlds"))
		let same = messageFingerprint(teacher("m1", "hello world"))
		#expect(a != b)
		#expect(a == same)
		#expect(a != messageFingerprint(user("m1", "hello world")))
	}

	@Test func theMessageIdIsTheProvenanceTag() {
		#expect(messageFingerprint(teacher("m1", "same")) != messageFingerprint(teacher("m2", "same")))
		#expect(messageFingerprint(teacher("m1", "same")) == messageFingerprint(teacher("m1", "same")))
	}

	@Test func markerMessagesAreInvisible() {
		let marker = newPlanBlockMessage(planCallId: "call_p1", block: [
			"kind": "full", "at": "2026-09-26T00:00:00.000Z", "current": nil, "nodes": [], "edges": [],
		])
		#expect(messageViewLines(marker, mid: marker.id) == [])
		let before = messageFingerprint(teacher("t1", "the chain rule"))
		let withMarker = [teacher("t1", "the chain rule"), marker]
		#expect(messageFingerprint(withMarker[0]) == before, "the neighbour's fingerprint is unchanged by the attach")
	}

	@Test func quizQAIsInvisible() throws {
		let asking = assistantWithCalls("a1", [(id: "q1", name: "quiz", args: ["question": "Q?"])])
		let answer = result("r1", "q1", "quiz", ["questionText": "Q?", "correct": true])
		#expect(messageViewLines(asking, mid: "a1") == [])
		#expect(messageViewLines(answer, mid: "r1") == [])
		#expect(try slot([asking, answer], "a1").tokens == 0)
		#expect(try slot([asking, answer], "r1").tokens == 0)
	}

	@Test func learnerMessagesAndAllToolResultsAreInvisible() {
		#expect(messageViewLines(user("u1", "teach me"), mid: "u1") == [])
		let demo = result("r1", "j1", "demo", ["title": "T"])
		#expect(messageViewLines(demo, mid: "r1") == [])
		let failed = result("r9", "j2", "visual", ["oops": true], isError: true)
		#expect(messageViewLines(failed, mid: "r9") == [])
	}

	@Test func teacherProseBlocksArePlainAndInOrder() {
		let blocks = teacherProseBlocks([
			user("u1", "learner asks"),
			teacher("t1", " first insight "),
			assistantWithCalls("a1", [(id: "q1", name: "quiz", args: [:])]),
			teacher("t2", "second insight"),
		])
		#expect(blocks == ["first insight", "second insight"])
	}

	/// The persisted-digest law: the hash input is JSON.stringify([role, lines]).
	@Test func fingerprintIsSha256OfTheJSStringifiedView() {
		// Digests from node's createHash("sha256").update(JSON.stringify(…)).
		let text = " hello \"q\" é😀\n\u{2028}x\t "
		#expect(messageFingerprint(teacher("m1", text)) == "cc4940651800eabcd2d019c341c5a68e299f267128aa5ff7ed683cfa35f451b8")
		let marker = newPlanBlockMessage(planCallId: "p", block: [:])
		#expect(messageFingerprint(marker) == "b1329613763a9bc57053c927319f13befd73e5176cc3efe9a8b40c1fa1210191", "markers hash as pi's \"custom\" role")
		// batchTag: update("ab"), update("cd") → first 12 hex.
		#expect(batchTag([CoverageSlot(message: marker, fp: "ab", tokens: 0), CoverageSlot(message: marker, fp: "cd", tokens: 0)]) == "88d4266fd4e6")
	}
}

@Suite("coverageOf — uncovered is DERIVED, never dual-tracked")
struct GraphCoverageOfTests {
	@Test func diffsFingerprints() throws {
		let messages = [teacher("m1", "aaaa"), teacher("m2", "bbbb"), teacher("m3", "cccc")]
		let fp1 = try slot(messages, "m1").fp
		let fp2 = try slot(messages, "m2").fp
		let entries = [
			CoverageEntry(chatId: "c1", fp: fp1, tokens: 1, foldedAt: "2026-09-15T00:00:00.000Z"),
			CoverageEntry(chatId: "c1", fp: fp2, tokens: 1, foldedAt: "2026-09-15T00:00:00.000Z"),
			CoverageEntry(chatId: "c2", fp: try slot(messages, "m3").fp, tokens: 1, foldedAt: "2026-09-15T00:00:00.000Z"),
		]
		let cov = coverageOf(messages, entries: entries, chatId: "c1")
		#expect(cov.uncovered == [2])
		#expect(cov.slots[cov.uncovered[0]].message.id == "m3")
		#expect(cov.coveredCount == 2)
		#expect(cov.uncoveredCount == 1)
		#expect(cov.uncoveredTokens == (try slot(messages, "m3").tokens))
		#expect(cov.coveredTokens == (try slot(messages, "m1").tokens) + (try slot(messages, "m2").tokens))
	}

	@Test func aMutatedCoveredMessageReopensOnlyItself() {
		let messages = [teacher("m1", "aaaa"), teacher("m2", "bbbb")]
		let entries = coverageSlots(messages).map { CoverageEntry(chatId: "c1", fp: $0.fp, tokens: $0.tokens, foldedAt: "2026-09-15T00:00:00.000Z") }
		#expect(coverageOf(messages, entries: entries, chatId: "c1").uncoveredCount == 0)
		let mutated = [teacher("m1", "aaaa!"), messages[1]]
		let cov = coverageOf(mutated, entries: entries, chatId: "c1")
		#expect(cov.uncovered == [0])
		#expect(cov.slots[0].message.id == "m1")
	}
}

@Suite("batchRuns — token-budgeted, consecutive, never splits a message")
struct GraphBatchRunsTests {
	private func ids(_ runs: [[CoverageSlot]]) -> [[String]] { runs.map { $0.map(\.message.id) } }

	@Test func greedyOldestFirstFill() {
		let slots = coverageSlots([
			teacher("m1", String(repeating: "a", count: 40)),
			teacher("m2", String(repeating: "b", count: 40)),
			teacher("m3", String(repeating: "c", count: 40)),
			teacher("m4", String(repeating: "d", count: 40)),
		])
		#expect(ids(batchRuns(slots, uncovered: [0, 1, 2, 3], budget: 45)) == [["m1", "m2", "m3"], ["m4"]])
	}

	@Test func anOverBudgetMessageRidesAlone() {
		let slots = coverageSlots([teacher("m1", String(repeating: "x", count: 400)), teacher("m2", String(repeating: "y", count: 20))])
		#expect(ids(batchRuns(slots, uncovered: [0, 1], budget: 10)) == [["m1"], ["m2"]])
	}

	@Test func emptyOrNonPositiveBudget() {
		#expect(batchRuns(coverageSlots([teacher("m1", "hi")]), uncovered: [0], budget: 0).isEmpty)
		#expect(batchRuns([], uncovered: [], budget: 4096).isEmpty)
	}

	@Test func learnerMessagesAndToolResultsNeverJoinABatch() {
		let messages = [
			user("u1", "learner asks"),
			teacher("t1", String(repeating: "x", count: 40)),
			result("r1", "q1", "quiz", ["questionText": "Q?", "correct": true]),
			teacher("t2", String(repeating: "y", count: 40)),
		]
		let cov = coverageOf(messages, entries: [], chatId: "c1")
		#expect(cov.uncovered == [1, 3], "only the teacher-prose slots are uncovered")
		#expect(ids(batchRuns(cov.slots, uncovered: cov.uncovered, budget: 15)) == [["t1"], ["t2"]])
	}
}

@Suite("batchTag — deterministic, ref-stable, mutation-sensitive")
struct GraphBatchTagTests {
	@Test func sameMembersSameTagOrderMatters() {
		let slots = coverageSlots([teacher("m1", "aaaa"), teacher("m2", "bbbb")])
		#expect(batchTag(slots) == batchTag(coverageSlots([teacher("m1", "aaaa"), teacher("m2", "bbbb")])))
		#expect(batchTag(slots) != batchTag(slots.reversed()), "batches are ordered runs")
		#expect(batchTag(slots).wholeMatch(of: /[0-9a-f]{12}/) != nil)
	}

	@Test func aReopenedMemberChangesTheTag() {
		let slots = coverageSlots([teacher("m1", "aaaa"), teacher("m2", "bbbb")])
		let mutated = coverageSlots([teacher("m1", "aaaa!"), teacher("m2", "bbbb")])
		#expect(batchTag(slots) != batchTag(mutated))
	}
}
