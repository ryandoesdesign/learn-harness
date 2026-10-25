import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore

// The hidden-reply rejection: a question whose reply went into a second
// thinking block (no visible text) fails once so the teacher writes it out;
// replies with text, and single-thinking questions (probes), pass.

private func vettedLoop(_ transport: ScriptedTransport) -> AgentLoop {
	var client = MessagesClient(transport: transport, apiKey: { "sk-ant-test" })
	client.backoff = { _ in 0.001 }
	client.jitter = { 0 }
	let ids = Box(0)
	var l = AgentLoop(client: client, config: AgentConfig(model: "claude-opus-5-5", effort: .low, system: "SYS", tools: [QuizTool()],
		cacheTTL: .oneHour, updateInterval: .zero, shouldStop: questionStopper, vetCalls: hiddenReplyVetter))
	l.mintId = { ids.mutate { $0 += 1 }; return "m\(ids.value)" }
	l.now = { 1 }
	return l
}

private func quiz(_ id: String, _ pieces: [ScriptedSSE.Piece]) -> ScriptedTransport.Response {
	.sse(ScriptedSSE.message(pieces + [.toolUse(id: id, name: "quiz", json: #"{"question":"Why?"}"#)], stopReason: "tool_use"))
}

@Suite struct HiddenReplyTests {
	@Test func aHiddenReplyIsRejectedAndTheRetryPosed() async throws {
		let t = ScriptedTransport([
			quiz("q1", [.thinking("plan", signature: "S1"), .thinking("I've laid out the card.", signature: "S2")]),
			quiz("q2", [.thinking("plan", signature: "S3"), .text("Here's the card.")]),
		])
		let out = await vettedLoop(t).run(history: [user("u0", "teach me")]) { _ in }
		#expect(t.requests.count == 2)
		#expect(out.newMessages.map(\.role) == [.assistant, .toolResult, .assistant])
		let rejection = try #require(out.newMessages[1].toolResult)
		#expect(rejection.isError && rejection.toolUseId == "q1")
		#expect(rejection.content.first?.raw["text"]?.stringValue == HIDDEN_REPLY_TEXT)
		#expect(danglingQuestionOf([user("u0", "x")] + out.newMessages)?.toolCallId == "q2")
	}

	@Test func aReplyWithTextPasses() async throws {
		let t = ScriptedTransport([quiz("q1", [.thinking("plan", signature: "S1"), .text("Here's the card.")])])
		let out = await vettedLoop(t).run(history: [user("u0", "teach me")]) { _ in }
		#expect(t.requests.count == 1)
		#expect(danglingQuestionOf([user("u0", "x")] + out.newMessages)?.toolCallId == "q1")
	}

	@Test func aQuestionCarryingItsMessagePasses() async throws {
		// Opus 5.5 returns longer text before a call as a thinking block; the reply rides in `message`.
		let t = ScriptedTransport([.sse(ScriptedSSE.message([
			.thinking("plan", signature: "S1"), .thinking("Good — now the card.", signature: "S2"),
			.toolUse(id: "q1", name: "quiz", json: #"{"message":"Here's the card.","question":"Why?"}"#),
		], stopReason: "tool_use"))])
		let out = await vettedLoop(t).run(history: [user("u0", "teach me")]) { _ in }
		#expect(t.requests.count == 1)
		#expect(danglingQuestionOf([user("u0", "x")] + out.newMessages)?.toolCallId == "q1")
	}

	@Test func oneThinkingBlockWithoutTextPasses() async throws {
		let t = ScriptedTransport([quiz("q1", [.thinking("what do they know?", signature: "S1")])])
		let out = await vettedLoop(t).run(history: [user("u0", "teach me")]) { _ in }
		#expect(t.requests.count == 1)
		#expect(danglingQuestionOf([user("u0", "x")] + out.newMessages)?.toolCallId == "q1")
	}

	@Test func aSecondHiddenReplyGoesThrough() async throws {
		let t = ScriptedTransport([
			quiz("q1", [.thinking("a", signature: "S1"), .thinking("b", signature: "S2")]),
			quiz("q2", [.thinking("c", signature: "S3"), .thinking("d", signature: "S4")]),
		])
		let out = await vettedLoop(t).run(history: [user("u0", "teach me")]) { _ in }
		#expect(t.requests.count == 2, "rejected once, then posed — no loop")
		#expect(danglingQuestionOf([user("u0", "x")] + out.newMessages)?.toolCallId == "q2")
	}
}
