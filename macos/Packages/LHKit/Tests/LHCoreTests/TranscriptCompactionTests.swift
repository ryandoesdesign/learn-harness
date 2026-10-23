import Foundation
import Testing
@testable import LHCore

// Port of tests/compaction.test.ts — the pure parts. The toLlmMessages
// suites ("toLlmMessages honors the cut", "carries the leading system
// message") are M3's WireProjection and are not ported here.

private func user(_ text: String, id: String = MessageID.mint()) -> Message {
	newUserMessage(text, id: id, now: 1)
}

private func assistantWithCall(_ id: String, _ callId: String, _ text: String = "Let me quiz you.") -> Message {
	Message(id: id, timestamp: 1, body: .assistant(AssistantBody(
		content: [.text(text), .toolUse(id: callId, name: "quiz", input: ["question": "Q?"])], model: "test", stopReason: "tool_use")))
}

private func assistantText(_ id: String, _ text: String) -> Message {
	Message(id: id, timestamp: 1, body: .assistant(AssistantBody(content: [.text(text)], model: "test", stopReason: "end_turn")))
}

private func resultFor(_ callId: String, _ text: String) -> Message {
	Message(id: "r_\(callId)", timestamp: 2, body: .toolResult(ToolResultBody(
		toolUseId: callId, toolName: "quiz", content: [.text(text)], isError: false)))
}

private func big(_ id: String, kb: Int = 8) -> Message {
	user("\(id): \(String(repeating: "x", count: kb * 1024))")
}

private func marker(_ summary: String, keptId: String, tokensBefore: Int = 1, at: String = "t") -> Message {
	newCompactionMarker(summary: summary, details: CompactionDetails(firstKeptMessageId: keptId, tokensBefore: tokensBefore, at: at))
}

private func userText(_ m: Message) -> String { m.user?.content.first?.text ?? "" }

@Suite struct EstimateContextTokensTests {
	/// pi usage {input: total-10, output: 10, totalTokens: total} (native: the sum).
	private func usageAssistant(_ id: String, _ total: Int, aborted: Bool = false) -> Message {
		Message(id: id, timestamp: 1, body: .assistant(AssistantBody(
			content: [.text("ok")], model: "test", stopReason: aborted ? "aborted" : "tool_use",
			usage: MessageUsage(input: total - 10, output: 10, cacheRead: 0, cacheWrite: 0))))
	}

	@Test func anchorsOnTheLastUsageAndEstimatesOnlyTheTail() {
		let msgs = [user(String(repeating: "x", count: 400_000)), usageAssistant("a1", 30_000), user(String(repeating: "y", count: 4_000))]
		let est = estimateContextTokens(msgs)
		#expect(est.lastUsageIndex != nil)
		#expect(est.usageTokens == 30_000)
		#expect(est.trailingTokens == 1_000)
		#expect(est.tokens == 31_000) // the 100k chars before the anchor are NOT re-estimated
	}

	@Test func skipsAbortedAndAllZeroUsageAssistants() {
		let msgs = [usageAssistant("a1", 30_000), usageAssistant("a2", 99_999, aborted: true), usageAssistant("a3", 0)]
		let est = estimateContextTokens(msgs)
		#expect(est.lastUsageIndex == 0)
		#expect(est.tokens == 30_000 + estimateMessageTokens(msgs[1]) + estimateMessageTokens(msgs[2]))
	}

	@Test func refusesAnchorsOlderThanTheNewestCompactionMarker() {
		let m = marker("summary text", keptId: "m1", tokensBefore: 500_000, at: "2026-10-05T00:00:00.000Z")
		let est = estimateContextTokens([usageAssistant("a1", 500_000), m, user("kept tail")])
		#expect(est.lastUsageIndex == nil, "the marker invalidates every anchor behind it")
	}

	@Test func unanchoredIsThePlainHeuristic() {
		let msgs = [big("m1", kb: 4), big("m2", kb: 4)]
		let est = estimateContextTokens(msgs)
		#expect(est.lastUsageIndex == nil)
		#expect(est.tokens == estimateTokens(msgs))
	}
}

@Suite struct EstimateMessageTokensTests {
	@Test func assistantCountsTextThinkingAndToolUseOnly() {
		let input: JSONValue = ["q": .string(String(repeating: "z", count: 200))]
		let m = Message(id: "a1", timestamp: 1, body: .assistant(AssistantBody(
			content: [
				.text(String(repeating: "x", count: 400)),
				.thinking(String(repeating: "y", count: 800), signature: "sig"),
				.toolUse(id: "c1", name: "quiz", input: input),
			],
			model: "test", stopReason: "tool_use", usage: MessageUsage(input: 9_999_999, output: 1, cacheRead: 0, cacheWrite: 0))))
		let chars = 400 + 800 + "quiz".count + input.serialized().count
		#expect(estimateMessageTokens(m) == Int((Double(chars) / 4).rounded(.up))) // usage/signature inflate nothing
	}

	@Test func calculateContextTokensTotalWinsElseTheSum() {
		#expect(calculateContextTokens(totalTokens: 42, input: 1, output: 2) == 42)
		#expect(calculateContextTokens(input: 10, output: 5, cacheRead: 3, cacheWrite: 2) == 20)
		#expect(calculateContextTokens() == 0)
	}

	@Test func utf16LengthsAndRedactedThinking() {
		// JS string length: "é" is 1 unit, "😀" is 2 — 3 units → ceil(3/4) = 1.
		#expect(estimateMessageTokens(user("é😀")) == 1)
		#expect(estimateMessageTokens(user(String(repeating: "😀", count: 4))) == 2)
		// pi stored redacted thinking as "[Reasoning redacted]" (20 chars → 5).
		let redacted = Message(id: "a", timestamp: 1, body: .assistant(AssistantBody(
			content: [Block(raw: ["type": "redacted_thinking", "data": "opaque"])], model: "m", stopReason: "end_turn")))
		#expect(estimateMessageTokens(redacted) == 5)
	}
}

@Suite struct CompactionCutIndexTests {
	@Test func keepsAboutTheBudgetOfRecentMessages() {
		let messages = [big("m1"), big("m2"), big("m3"), big("m4"), user("recent")]
		let cut = compactionCutIndex(messages, keepRecentTokens: 4_500)
		#expect(userText(messages[cut]).hasPrefix("m2"), "the oldest kept message sits at the cut")
	}

	@Test func neverSeparatesAToolResultFromItsCall() {
		let messages = [big("m1"), big("m2"), assistantWithCall("a1", "call_1"), resultFor("call_1", "correct"), big("m3"), big("m4")]
		let cut = compactionCutIndex(messages, keepRecentTokens: estimateTokens([big("m3"), big("m4")]) + 1)
		#expect(cut <= 2, "the cut must not sit between the call (idx 2) and its result (idx 3) — got \(cut)")
		let keptIds = Set(messages[cut...].map(\.id))
		#expect(keptIds.contains("a1") && keptIds.contains("r_call_1"), "call and result stay together")
	}

	@Test func aPendingQuestionCallAlwaysSurvives() {
		let messages = [big("m1"), big("m2"), big("m3"), assistantWithCall("a_pending", "call_p")]
		let cut = compactionCutIndex(messages, keepRecentTokens: 100)
		#expect(messages[cut...].contains { $0.id == "a_pending" }, "the pending pose is never dropped")
	}

	@Test func wholeHistoryInBudgetReturnsZero() {
		#expect(compactionCutIndex([user("hi")], keepRecentTokens: 100) == 0)
	}
}

@Suite struct CompactionMarkerTests {
	@Test func contentIsHeaderPlusSummaryAndDetailsCarryTheCut() {
		let m = newCompactionMarker(summary: "The learner knows X.", details: CompactionDetails(
			firstKeptMessageId: "m9", tokensBefore: 180_000, model: "openai:gpt-5.2", at: "2026-10-05T12:00:00.000Z"))
		#expect(m.marker?.kind == .compaction)
		#expect(m.marker?.content.hasPrefix(COMPACTED_HISTORY_HEADER) == true)
		#expect(m.marker?.content.hasSuffix("The learner knows X.") == true)
		#expect(m.marker?.details["firstKeptMessageId"]?.stringValue == "m9")
	}

	@Test func injectableIdAndClock() {
		let m = newCompactionMarker(summary: "s", details: CompactionDetails(firstKeptMessageId: "k", tokensBefore: 1, at: "t"), id: "cm_1", now: 42)
		#expect(m.id == "cm_1" && m.timestamp == 42)
	}

	@Test func theNewestMarkerRules() {
		let old = marker("old", keptId: "m1")
		let fresh = marker("fresh", keptId: "m5", tokensBefore: 2)
		let active = activeCompactionOf([old, user("x"), fresh])
		#expect(active?.content.hasSuffix("fresh") == true)
	}

	@Test func malformedDetailsAreNotAnActiveCompaction() {
		var broken = marker("s", keptId: "m1")
		if case .marker(var body) = broken.body {
			body.details = [:]
			broken.body = .marker(body)
		}
		#expect(activeCompactionOf([broken]) == nil)
	}

	@Test func keptIndexForFoundByIdMissingIsMinusOne() throws {
		let messages = [user("a", id: "m1"), user("b", id: "m2"), user("c")]
		let found = try #require(activeCompactionOf([marker("s", keptId: "m2")]))
		#expect(keptIndexFor(messages, found) == 1)
		let gone = try #require(activeCompactionOf([marker("s", keptId: "zzz")]))
		#expect(keptIndexFor(messages, gone) == -1)
	}
}

@Suite struct SerializeForSummaryTests {
	@Test func labelsRolesTruncatesLongResultsSkipsPlanBlocks() {
		let long = String(repeating: "y", count: 5_000)
		let messages = [
			user("hello"),
			assistantText("a1", "lecture"),
			resultFor("c1", long),
			Message(id: "pb", timestamp: 1, body: .marker(MarkerBody(kind: .planBlock, content: "", details: [:]))),
		]
		let text = serializeForSummary(messages)
		#expect(text.contains("[LEARNER] hello"))
		#expect(text.contains("[TUTOR] lecture"))
		#expect(text.contains("[RESULT for quiz]"))
		#expect(text.contains("…[truncated]"))
		#expect(!text.contains(String(repeating: "yyyyy", count: 1000)), "truncation bounded the result")
		#expect(!text.lowercased().contains("plan-block"), "UI-only markers never serialize")
	}

	@Test func thePromptDemandsTheFourSectionsInOrder() {
		let prompt = buildCompactionPrompt(spanText: "TRANSCRIPT", planTreeText: "- [done] A (a1)\n- A → B", kind: .teach)
		let order = ["The learner's understanding", "The teaching arc", "The plan dependency tree", "The current moment"].map {
			prompt.range(of: $0).map { prompt.distance(from: prompt.startIndex, to: $0.lowerBound) } ?? -1
		}
		#expect(!order.contains(-1))
		#expect(order == order.sorted(), "sections appear in the ruled order")
		#expect(prompt.contains("TRANSCRIPT"))
		#expect(prompt.contains("- [done] A (a1)"))
	}

	@Test func planTreeToTextStatusesEdgesAndEmpty() throws {
		#expect(planTreeToText(nil, []) == nil)
		let tree = PlanTree(nodes: [PlanNode(id: "a", title: "Alpha", summary: "first"), PlanNode(id: "b", title: "Beta")],
			edges: [PlanEdge(from: "a", to: "b")], version: 1)
		let text = try #require(planTreeToText(tree, []))
		#expect(text.contains("Alpha (a) — first"))
		#expect(text.contains("Alpha → Beta"))
	}
}

/// THE VIEW FOLD: two dividers from one marker — the moment divider where
/// the user is, the cut divider at the kept boundary.
@Suite struct ProjectViewCompactionDividerTests {
	private func record() -> [Message] {
		[
			user("earliest", id: "old1"),
			user("recent", id: "kept"),
			marker("SUMMARY TEXT", keptId: "kept", tokensBefore: 12345, at: "1970-01-01T00:00:00.000Z"),
		]
	}

	private func hasText(_ m: ViewMessage, _ text: String) -> Bool {
		m.parts.contains { $0.kind == .text && $0.text == text }
	}

	@Test func emitsTheCutDividerBeforeTheFirstKeptMessage() throws {
		let view = projectView(record())
		let idx = try #require(view.firstIndex { $0.parts.contains { $0.type == "data-compaction-cut" } }, "the cut divider exists")
		let keptIdx = try #require(view.firstIndex { hasText($0, "recent") })
		#expect(idx == keptIdx - 1, "immediately before the kept message")
		let part = try #require(view[idx].parts.first { $0.type == "data-compaction-cut" })
		#expect(part.data?["content"]?.stringValue?.contains("SUMMARY TEXT") == true)
	}

	@Test func emitsTheMomentDividerAtTheMarker() throws {
		let view = projectView(record())
		let momentIdx = try #require(view.firstIndex { $0.parts.contains { $0.type == "data-compaction" } }, "the moment divider exists")
		let part = try #require(view[momentIdx].parts.first { $0.type == "data-compaction" })
		#expect(part.data?["details"]?["tokensBefore"]?.intValue == 12345)
		let keptIdx = try #require(view.firstIndex { hasText($0, "recent") })
		#expect(momentIdx > keptIdx)
	}
}
