import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore
import LHStore

// Practice sessions over scripted transports (docs/native-macos-m8.md): the
// practice registry and prompt, the pose → thinking → conclude → Next cycle,
// the per-turn gate (including the native same-turn refusal), target
// resolution, the discard (and its mid-turn park), and thinking as a steer.

private let pose: JSONValue = [
	"statement": "Join `a` and `b` keeping every row of `a`.",
	"mode": "recall",
	"modelSolution": "SELECT * FROM a LEFT JOIN b ON a.id = b.a_id",
]

private let conclusion: JSONValue = [
	"outcome": "solved", "verdict": "Right join kind.", "rung": .null, "missClass": .null, "retest": false,
]

private func practiceHarness(_ responses: [ScriptedTransport.Response], gated: GatedTransport? = nil) throws -> Harness {
	let db = try AppDatabase.inMemory()
	let chat = try ChatRepository(db).createChat(title: "Joins", kind: .practice)
	return try Harness(responses, gated: gated, db: db, chatId: chat.id)
}

private func names(_ request: JSONValue) -> [String] {
	request["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
}

private func resultText(_ r: ChatRecord, _ callId: String) -> (text: String, isError: Bool)? {
	for m in r.messages {
		if let t = m.toolResult, t.toolUseId == callId { return (t.content.compactMap(\.text).joined(), t.isError) }
	}
	return nil
}

@Suite(.serialized) struct PracticeServiceTests {
	@Test func aPracticeSessionRunsThePracticeAgentFromTheFirstTurn() async throws {
		let h = try practiceHarness([.sse(ScriptedSSE.message([tool("p1", "problem", pose)], stopReason: "tool_use"))])
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("Practise joins"))
		try await settles(ev, h.chatId)
		let req = try h.request(0)
		#expect(names(req) == ["problem", "conclude", "list_sessions", "list_propositions"])
		let system = req["system"]?.arrayValue?.first?["text"]?.stringValue ?? ""
		#expect(system == PromptComposer().compose(.practice, tools: Set(names(req))))
		let r = try h.record
		#expect(activeProblemOf(r.messages)?.toolCallId == "p1")
		#expect(resultText(r, "p1")?.isError == false, "the pose ack persists")
		#expect(h.transport.requestBodies.count == 1, "the pose ends the turn")
	}

	@Test func aFullCycleThinkingConcludeNextPose() async throws {
		let h = try practiceHarness([
			.sse(ScriptedSSE.message([tool("p1", "problem", pose)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([tool("c1", "conclude", conclusion)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Well done.")])),
			.sse(ScriptedSSE.message([tool("p2", "problem", pose)], stopReason: "tool_use")),
		])
		var ev = await h.service.events()
		try await h.service.send(h.chatId, .text("Practise joins"))
		try await settles(ev, h.chatId)

		ev = await h.service.events()
		#expect(try await h.service.submitThinking(h.chatId, problemCallId: "p1", text: "LEFT JOIN on the id") == .sent)
		try await settles(ev, h.chatId)
		var r = try h.record
		#expect(activeProblemOf(r.messages) == nil, "concluded")
		#expect(r.messages.contains { $0.marker?.kind == .practiceThinking })

		ev = await h.service.events()
		try await h.service.send(h.chatId, .next)
		try await settles(ev, h.chatId)
		r = try h.record
		#expect(activeProblemOf(r.messages)?.toolCallId == "p2")
		#expect(r.messages.contains { $0.marker?.kind == .practiceNext })
	}

	@Test func posingAfterAConclusionInTheSameTurnIsRefused() async throws {
		let h = try practiceHarness([
			.sse(ScriptedSSE.message([tool("p1", "problem", pose)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([tool("c1", "conclude", conclusion)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([tool("p2", "problem", pose)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("I'll wait for your go-ahead.")])),
		])
		var ev = await h.service.events()
		try await h.service.send(h.chatId, .text("Practise joins"))
		try await settles(ev, h.chatId)
		ev = await h.service.events()
		try await h.service.submitThinking(h.chatId, problemCallId: "p1", text: "LEFT JOIN")
		try await settles(ev, h.chatId)
		let r = try h.record
		let refused = try #require(resultText(r, "p2"))
		#expect(refused.isError)
		#expect(refused.text.contains("concluded in this turn"))
		#expect(activeProblemOf(r.messages) == nil)
	}

	@Test func theGateRefusesASecondPoseAndAConcludeWithNothingActive() async throws {
		let gate = PracticeGate(problemActive: false)
		let tools = practiceTools(gate: gate, graphNodes: nil, enabled: nil)
		let problem = try #require(tools.first { $0.name == "problem" })
		let conclude = try #require(tools.first { $0.name == "conclude" })
		let ctx = ToolContext(toolCallId: "x")
		#expect(try await conclude.execute(conclusion, context: ctx).isError)
		#expect(try await !problem.execute(pose, context: ctx).isError)
		let second = try await problem.execute(pose, context: ctx)
		#expect(second.isError)
		#expect(second.content.first?.text?.contains("already active") == true)
	}

	@Test func targetsResolveNamesAndRejectUnknownsAndEmptyListsHealAway() async throws {
		let node = GraphNode(id: "n_left", name: "Left outer join", statement: "Keeps every left row.", aliases: [], createdAt: "", provenance: [])
		let tool = ProblemTool(gate: PracticeGate(problemActive: false), graphNodes: { [node] })
		var input = pose
		input["target"] = ["Left outer join"]
		#expect(tool.prepare(input)["target"] == ["n_left"])
		input["target"] = .array([])
		#expect(tool.prepare(input)["target"] == nil)
		input["target"] = ["Cross join"]
		let refused = try await tool.execute(tool.prepare(input), context: ToolContext(toolCallId: "x"))
		#expect(refused.isError)
		#expect(refused.content.first?.text?.contains("not a known proposition") == true)
	}

	@Test func aDiscardRidesTheNextInputAsTheSyntheticConclusion() async throws {
		let h = try practiceHarness([
			.sse(ScriptedSSE.message([tool("p1", "problem", pose)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([tool("p2", "problem", pose)], stopReason: "tool_use")),
		])
		var ev = await h.service.events()
		try await h.service.send(h.chatId, .text("Practise joins"))
		try await settles(ev, h.chatId)
		try await h.service.dismissProblem(h.chatId, problemCallId: "p1")
		var r = try h.record
		#expect(r.messages.last?.marker?.kind == .problemDismissed)
		#expect(activeProblemOf(r.messages) == nil)
		#expect(!TurnService.owesTurn(r.messages), "a discard starts no turn")

		ev = await h.service.events()
		try await h.service.send(h.chatId, .next)
		try await settles(ev, h.chatId)
		r = try h.record
		#expect(r.messages.contains { $0.assistant?.toolUses.contains { $0.id == "call_conc_p1" } ?? false })
		let msgs = try #require(try h.request(1)["messages"]?.arrayValue)
		#expect(msgs.contains { $0["content"]?.arrayValue?.contains { $0["id"]?.stringValue == "call_conc_p1" } == true })
	}

	@Test func thinkingMidTurnIsASteerAndADiscardMidTurnIsParked() async throws {
		let gate = GatedTransport(ScriptedTransport([
			.sse(ScriptedSSE.message([.text("Let me look at that.")])),
			.sse(ScriptedSSE.message([.text("Your thinking is on the right track.")])),
		]))
		let h = try practiceHarness([], gated: gate)
		try ChatRepository(h.db).append([
			newUserMessage("Practise joins", now: 0),
			Message(id: "a1", timestamp: 1, body: .assistant(AssistantBody(content: [.toolUse(id: "p1", name: "problem", input: pose)], model: "claude-opus-5-5", stopReason: "tool_use"))),
			Message(id: "r1", timestamp: 2, body: .toolResult(ToolResultBody(toolUseId: "p1", toolName: "problem", content: [.text("Problem posed")], isError: false, details: nil))),
		], to: h.chatId)
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("Is NULL a match?"))
		while !gate.reachedGate { try await Task.sleep(for: .milliseconds(5)) }
		guard case .queued(let id) = try await h.service.submitThinking(h.chatId, problemCallId: "p1", text: "LEFT JOIN") else {
			Issue.record("thinking mid-turn should queue")
			return
		}
		try await h.service.dismissProblem(h.chatId, problemCallId: "p1")
		#expect(try h.record.messages.last?.marker?.kind != .problemDismissed, "parked while the turn runs")
		gate.open()
		try await settles(ev, h.chatId)
		let r = try h.record
		#expect(r.messages.contains { $0.id == id && $0.marker?.kind == .practiceThinking })
		#expect(r.messages.last?.marker?.kind == .problemDismissed, "applied at settle")
	}
}

/// tests/practice-heal.test.ts: the double-encoded enums and their siblings
/// heal against the practice schemas; plain strings and bad values stay.
@Suite struct PracticeHealTests {
	private func quoted(_ s: String) -> JSONValue { .string("\"\(s)\"") }

	@Test func theDoubleEncodedModeHeals() {
		#expect(healEncodedArguments(["mode": quoted("recall")], schema: problemInputSchema)["mode"] == "recall")
		#expect(healEncodedArguments(["mode": quoted("bogus")], schema: problemInputSchema)["mode"] == quoted("bogus"), "unhealable stays")
	}

	@Test func theConcludeEnumsNullAndBooleanHeal() {
		let a = healEncodedArguments(["outcome": quoted("solved"), "rung": "null"], schema: concludeInputSchema)
		#expect(a["outcome"] == "solved" && a["rung"] == .null)
		let b = healEncodedArguments(["rung": quoted("R2"), "retest": "true"], schema: concludeInputSchema)
		#expect(b["rung"] == "R2" && b["retest"] == true)
	}

	@Test func aStringifiedTargetArrayHealsAndPlainStringsStay() {
		#expect(healEncodedArguments(["target": #"["a","b"]"#], schema: problemInputSchema)["target"] == ["a", "b"])
		let args: JSONValue = ["statement": "\"not JSON-healed\"", "mode": "recall"]
		#expect(healEncodedArguments(args, schema: problemInputSchema) == args)
	}

	@Test func theProblemToolHealsBeforeValidating() {
		let tool = ProblemTool(gate: PracticeGate(problemActive: false), graphNodes: nil)
		var raw = pose
		raw["mode"] = quoted("recall")
		#expect(tool.prepare(raw)["mode"] == "recall")
	}
}
