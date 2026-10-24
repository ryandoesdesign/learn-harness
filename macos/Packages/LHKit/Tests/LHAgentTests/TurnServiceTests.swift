import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore
import LHStore

// The live teaching service over scripted transports — the ported
// chat-flow / probe-done / dismissal-park cases plus the native M5 laws
// (per-message persistence, the steer outbox, resume on open).

// MARK: Harness

/// Holds the FIRST request until `open()` (deterministic mid-turn steering).
final class GatedTransport: AnthropicTransport, @unchecked Sendable {
	let inner: ScriptedTransport
	private let lock = NSLock()
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private var isOpen = false
	private var calls = 0
	private(set) var reachedGate = false

	init(_ inner: ScriptedTransport) { self.inner = inner }

	func open() {
		let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
			isOpen = true
			defer { waiters = [] }
			return waiters
		}
		for c in w { c.resume() }
	}

	func send(_ request: URLRequest) async throws -> TransportResponse {
		let first = lock.withLock { () -> Bool in
			calls += 1
			return calls == 1 && !isOpen
		}
		if first {
			await withCheckedContinuation { c in
				let resumeNow = lock.withLock { () -> Bool in
					reachedGate = true
					if isOpen { return true }
					waiters.append(c)
					return false
				}
				if resumeNow { c.resume() }
			}
		}
		return try await inner.send(request)
	}
}

struct Harness {
	let db: AppDatabase
	let transport: ScriptedTransport
	let service: TurnService
	let chatId: String

	init(_ responses: [ScriptedTransport.Response], key: String? = "sk-ant-test", gated: GatedTransport? = nil, messages: [Message] = [],
		db: AppDatabase? = nil, chatId: String? = nil) throws
	{
		self.db = try db ?? AppDatabase.inMemory()
		transport = gated?.inner ?? ScriptedTransport(responses)
		let t: any AnthropicTransport = gated ?? transport
		service = TurnService(database: self.db, keychain: InMemoryKeychain(key: key), catalog: try ModelCatalog(data: Data(MODELS_JSON.utf8)),
			makeTransport: { t }, summarizer: { _, _ in ("summary", []) })
		if let chatId {
			self.chatId = chatId
		} else {
			let chat = try ChatRepository(self.db).createChat(title: "Joins")
			self.chatId = chat.id
			if !messages.isEmpty { try ChatRepository(self.db).append(messages, to: chat.id) }
		}
	}

	var record: ChatRecord { get throws { try #require(try ChatRepository(db).get(chatId)) } }
	func request(_ i: Int) throws -> JSONValue { try JSONValue.parse(transport.requestBodies[i]) }
}

let MODELS_JSON = #"{"version":1,"models":[{"id":"claude-opus-5-5","name":"Claude Opus 5.5","contextWindow":1000000,"maxTokens":128000,"input":["text","image"],"efforts":["low","medium","high","xhigh","max"],"price":{"input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25,"cacheWrite1h":10}}]}"#

/// Wait for `count` settles of the chat (with a timeout).
func settles(_ events: AsyncStream<TurnService.Event>, _ chatId: String, count: Int = 1, timeout: Duration = .seconds(10)) async throws {
	try await withThrowingTaskGroup(of: Void.self) { group in
		group.addTask {
			var n = 0
			for await e in events {
				if case .turnSettled(chatId) = e { n += 1; if n == count { return } }
			}
		}
		group.addTask {
			try await Task.sleep(for: timeout)
			throw CancellationError()
		}
		try await group.next()
		group.cancelAll()
	}
}

func tool(_ id: String, _ name: String, _ json: JSONValue) -> ScriptedSSE.Piece { .toolUse(id: id, name: name, json: json.serialized()) }

let probeInput: JSONValue = [
	"question": "What does SQL stand for?",
	"options": [["label": "Structured Query Language", "value": "a"], ["label": "Simple Query Logic", "value": "b"]],
	"explanation": "It's Structured.", "correctAnswer": "a",
]

func answer(_ text: String = "What does SQL stand for?") -> QuestionAnswerData {
	var a = QuestionAnswerData(kind: .quiz, questionText: text, dontKnow: false, answers: [OptionAnswer(label: "Structured Query Language", value: "a", index: 1)], answeredAt: "2026-10-24T00:00:00.000Z")
	a.tool = "probe"
	a.correct = true
	a.correctIndices = [1]
	return a
}

// MARK: Tests

@Suite(.serialized) struct TurnServiceTests {
	@Test func aPosedQuestionPersistsWithoutItsPlaceholderAndTheAnswerContinues() async throws {
		let h = try Harness([
			.sse(ScriptedSSE.message([.text("Let's see."), tool("c1", "probe", probeInput)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Right — structured.")])),
		])
		let ev = await h.service.events()
		#expect(try await h.service.send(h.chatId, .text("Teach me joins")) == .started)
		try await settles(ev, h.chatId)
		var r = try h.record
		#expect(r.messages.map(\.role) == [.user, .assistant], "the placeholder result never persists")
		#expect(danglingQuestionOf(r.messages)?.toolCallId == "c1")

		let ev2 = await h.service.events()
		#expect(try await h.service.send(h.chatId, .answer(toolCallId: "c1", answer: answer())) == .started)
		try await settles(ev2, h.chatId)
		r = try h.record
		#expect(r.messages.map(\.role) == [.user, .assistant, .toolResult, .assistant])
		let msgs = try #require(h.request(1)["messages"]?.arrayValue)
		#expect(msgs.last?["content"]?.arrayValue?.first?["type"]?.stringValue == "tool_result")
		#expect(r.turns?.count == 2, "usage recorded per turn")
	}

	@Test func theSystemPromptIsTheGatedProberAndTheToolsAreTheProbeSet() async throws {
		// M7: the graph tools ride while graphToolsEnabled (on by default).
		let h = try Harness([.sse(ScriptedSSE.message([.text("Hi.")]))])
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("Teach me joins"))
		try await settles(ev, h.chatId)
		let req = try h.request(0)
		#expect(req["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["probe", "ask_user_question", "list_sessions", "list_propositions", "probe_done"])
		let system = req["system"]?.arrayValue?.first?["text"]?.stringValue ?? ""
		#expect(system.contains("`list_sessions`"))
	}

	@Test func graphToolsOffStripTheMapFromTheProber() async throws {
		let h = try Harness([.sse(ScriptedSSE.message([.text("Hi.")]))])
		try SettingsRepository(h.db).update { $0.agent = AgentSettings(graphTools: GraphToolsSettings(enabled: false)) }
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("Teach me joins"))
		try await settles(ev, h.chatId)
		let req = try h.request(0)
		#expect(req["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["probe", "ask_user_question", "probe_done"])
		let sys = req["system"]?.arrayValue?.first?["text"]?.stringValue ?? ""
		#expect(!sys.contains("`list_sessions`"), "\(sys.components(separatedBy: "\n").filter { $0.contains("list_sessions") })")
	}

	@Test func anAnswerWithNoPendingQuestionIsRefused() async throws {
		let h = try Harness([])
		await #expect(throws: TurnService.Refusal.invalid("answer input targets no pending question call")) {
			try await h.service.send(h.chatId, .answer(toolCallId: "nope", answer: answer()))
		}
	}

	@Test func noKeyIsRefusedBeforeAnythingIsWritten() async throws {
		let h = try Harness([], key: nil)
		await #expect(throws: TurnService.Refusal.noKey) { try await h.service.send(h.chatId, .text("hi")) }
		#expect(try h.record.messages.isEmpty)
	}

	@Test func oneTurnPerChatAndAbortKeepsThePartial() async throws {
		let h = try Harness([.sseThenHang(ScriptedSSE.message([.text("A long partial answer")]), afterLines: 12)])
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("first"))
		await #expect(throws: TurnService.Refusal.turnRunning) { try await h.service.send(h.chatId, .text("second")) }
		try await Task.sleep(for: .milliseconds(100))
		await h.service.abort(h.chatId)
		try await settles(ev, h.chatId)
		let last = try #require(try h.record.messages.last?.assistant)
		#expect(last.stopReason == "aborted")
	}

	@Test func anInvalidProbeIsRetriedWithTheProblemList() async throws {
		var bad = probeInput
		bad["options"] = [["label": "only one", "value": "a"]]
		let h = try Harness([
			.sse(ScriptedSSE.message([tool("c1", "probe", bad)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Let me fix that.")])),
		])
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("go"))
		try await settles(ev, h.chatId)
		let r = try h.record
		let result = try #require(r.messages.first { $0.toolResult != nil }?.toolResult)
		#expect(result.isError)
		#expect(r.messages.last?.assistant != nil, "the loop continued after the invalid call")
	}

	@Test func parallelQuestionsDeferToTheLastAnswer() async throws {
		var second = probeInput
		second["question"] = "Second?"
		let h = try Harness([
			.sse(ScriptedSSE.message([tool("c1", "probe", probeInput), tool("c2", "probe", second)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Both noted.")])),
		])
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("go"))
		try await settles(ev, h.chatId)
		#expect(try await h.service.send(h.chatId, .answer(toolCallId: "c1", answer: answer())) == .saved)
		let ev2 = await h.service.events()
		#expect(try await h.service.send(h.chatId, .answer(toolCallId: "c2", answer: answer("Second?"))) == .started)
		try await settles(ev2, h.chatId)
		let last = try #require(try h.request(1)["messages"]?.arrayValue?.last)
		#expect(last["content"]?.arrayValue?.compactMap { $0["tool_use_id"]?.stringValue } == ["c1", "c2"], "results adjacent, in call order")
	}

	@Test func probeDoneHandsOffToTheTeacher() async throws {
		let assessment: JSONValue = ["assessment": ["strands": [["strand": "SQL basics", "assessment": "Knows SELECT."]], "summary": "Ready."]]
		let h = try Harness([
			.sse(ScriptedSSE.message([tool("d1", "probe_done", assessment)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Thanks — over to planning.")])),
			.sse(ScriptedSSE.message([.text("Here is the plan.")])),
		])
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("go"))
		try await settles(ev, h.chatId, count: 2)
		let r = try h.record
		let done = try #require(r.messages.compactMap(\.toolResult).first { $0.toolName == "probe_done" })
		#expect(!done.isError)
		#expect(done.content.first?.raw["text"]?.stringValue == PROBE_DONE_ACK_TEXT)
		#expect(r.messages.contains { $0.marker?.kind == .probeHandoff })
		let teacher = try h.request(2)
		#expect(teacher["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["quiz", "ask_user_question", "plan_init"])
		#expect(r.messages.last?.assistant != nil)
	}

	@Test func probeDoneRefusesASecondConclusion() async throws {
		let assessment: JSONValue = ["assessment": ["strands": [["strand": "s", "assessment": "a"]]]]
		let prior = Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [.toolUse(id: "d0", name: "probe_done", input: assessment)], model: "claude-opus-5-5", stopReason: "tool_use")))
		let ctx = TeachingContext(chatId: "c", record: { ChatRecord(id: "c", title: "t", createdAt: "", updatedAt: "", messages: [prior]) }, saveTree: { _ in }, queueHandoff: {})
		let out = try await ProbeDoneTool(ctx: ctx).execute(assessment, context: ToolContext(toolCallId: "d1"))
		#expect(out.details?["ok"]?.boolValue == false)
		#expect(out.details?["error"]?.stringValue == "The probe is already concluded — probe_done fires exactly once.")
	}

	@Test func planInitSavesTheTreeAndEmitsOnePlanBlockAtSettle() async throws {
		let handoff = newHandoffMessage(chatId: "x")
		let prior: [Message] = [
			newUserMessage("go", id: "u0", now: 0),
			Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [.toolUse(id: "d0", name: "probe_done", input: ["assessment": ["strands": [["strand": "s", "assessment": "a"]]]])], model: "claude-opus-5-5", stopReason: "tool_use"))),
			Message(id: "r0", timestamp: 0, body: .toolResult(ToolResultBody(toolUseId: "d0", toolName: "probe_done", content: [.text(PROBE_DONE_ACK_TEXT)], isError: false, details: ["ok": true]))),
			handoff,
		]
		let h = try Harness([
			.sse(ScriptedSSE.message([tool("p1", "plan_init", ["mermaid": "graph TD\n  joins[What a join is] --> inner[Inner joins]"])], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("That's the plan.")])),
		], messages: prior)
		let ev = await h.service.events()
		try await h.service.resumeIfNeeded(h.chatId)
		try await settles(ev, h.chatId)
		let r = try h.record
		#expect(r.tree?.nodes.map(\.id) == ["joins", "inner"])
		#expect(r.messages.filter { $0.marker?.kind == .planBlock }.count == 1)
	}

	@Test func aSteerMidTurnLandsAtTheBoundaryAndIsDelivered() async throws {
		let gate = GatedTransport(ScriptedTransport([
			.sse(ScriptedSSE.message([tool("d1", "probe_done", ["assessment": ["strands": [["strand": "s", "assessment": "a"]]]])], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Noted your aside.")])),
			.sse(ScriptedSSE.message([.text("The teacher's plan.")])),
		]))
		let h = try Harness([], gated: gate)
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("go"))
		while !gate.reachedGate { try await Task.sleep(for: .milliseconds(5)) }
		let steered = try await h.service.steer(h.chatId, text: "also, use Postgres")
		guard case .queued(let id) = steered else { Issue.record("not queued"); return }
		gate.open()
		try await settles(ev, h.chatId, count: 2)
		let r = try h.record
		#expect(r.messages.contains { $0.id == id })
		#expect(try SteerOutboxRepository(h.db).steers(chatId: h.chatId, state: .delivered).map(\.id) == [id])
		let second = try #require(try h.request(1)["messages"]?.arrayValue?.last)
		#expect(second["content"]?.arrayValue?.contains { $0["text"]?.stringValue == "also, use Postgres" } == true)
	}

	@Test func aSteerStrandedByAQuestionRidesTheAnswerTurn() async throws {
		let gate = GatedTransport(ScriptedTransport([
			.sse(ScriptedSSE.message([tool("c1", "probe", probeInput)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Good — and noted.")])),
		]))
		let h = try Harness([], gated: gate)
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("go"))
		while !gate.reachedGate { try await Task.sleep(for: .milliseconds(5)) }
		_ = try await h.service.steer(h.chatId, text: "aside")
		gate.open()
		try await settles(ev, h.chatId)
		#expect(try SteerOutboxRepository(h.db).steers(chatId: h.chatId, state: .pending).count == 1, "the question stop leaves it pending")
		#expect(danglingQuestionOf(try h.record.messages) != nil)
		let ev2 = await h.service.events()
		try await h.service.send(h.chatId, .answer(toolCallId: "c1", answer: answer()))
		try await settles(ev2, h.chatId)
		let msgs = try #require(try h.request(1)["messages"]?.arrayValue)
		let last = try #require(msgs.last?["content"]?.arrayValue)
		#expect(last.first?["type"]?.stringValue == "tool_result", "the result stays first")
		#expect(last.contains { $0["text"]?.stringValue == "aside" }, "the steer follows in the same user message")
	}

	@Test func pendingSteersSurviveARelaunchAndResume() async throws {
		let db = try AppDatabase.inMemory()
		let chat = try ChatRepository(db).createChat(title: "t")
		try ChatRepository(db).append([newUserMessage("hi", now: 0), Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [.text("Hello.")], model: "claude-opus-5-5", stopReason: "end_turn")))], to: chat.id)
		let steer = newUserSteer("one more thing", id: "steer_x")
		try SteerOutboxRepository(db).enqueue(steer, chatId: chat.id)
		try SteerOutboxRepository(db).mark([steer.id], .handed) // a quit mid-turn
		let h = try Harness([.sse(ScriptedSSE.message([.text("Got it.")]))], db: db, chatId: chat.id)
		await h.service.recoverOnLaunch()
		let ev = await h.service.events()
		await h.service.resumeIfNeeded(chat.id)
		try await settles(ev, chat.id)
		#expect(try h.record.messages.map(\.id).contains("steer_x"))
	}

	@Test func resumeStartsATurnForATrailingTextMessage() async throws {
		let h = try Harness([.sse(ScriptedSSE.message([.text("Back where we were.")]))], messages: [newUserMessage("are you there?", now: 0)])
		let ev = await h.service.events()
		await h.service.resumeIfNeeded(h.chatId)
		try await settles(ev, h.chatId)
		#expect(try h.record.messages.last?.assistant != nil)
	}

	@Test func resumeHoldsForAnOpenQuestionOrADismissal() async throws {
		let q = Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [.toolUse(id: "c1", name: "probe", input: probeInput)], model: "claude-opus-5-5", stopReason: "tool_use")))
		let h = try Harness([], messages: [newUserMessage("go", now: 0), q])
		await h.service.resumeIfNeeded(h.chatId)
		#expect(await !h.service.isRunning(h.chatId))
		try await h.service.dismiss(h.chatId, toolCallId: "c1", answer: dismissedAnswer(.quiz, questionText: "What does SQL stand for?"))
		#expect(endsInDismissal(try h.record.messages))
		await h.service.resumeIfNeeded(h.chatId)
		#expect(await !h.service.isRunning(h.chatId), "the dismissal pause")
	}

	@Test func perMessagePersistenceKeepsCompletedStepsOfAnAbortedTurn() async throws {
		let h = try Harness([
			.sse(ScriptedSSE.message([tool("c0", "probe_done", ["assessment": ["strands": [["strand": "s", "assessment": "a"]]]])], stopReason: "tool_use")),
			.sseThenHang(ScriptedSSE.message([.text("still writing")]), afterLines: 10),
		])
		let ev = await h.service.events()
		try await h.service.send(h.chatId, .text("go"))
		// The first step (assistant + its result) lands before the second stream ends.
		for _ in 0..<200 where (try h.record.messages.count) < 3 { try await Task.sleep(for: .milliseconds(10)) }
		#expect(try h.record.messages.map(\.role) == [.user, .assistant, .toolResult])
		await h.service.abort(h.chatId)
		try await settles(ev, h.chatId)
	}
}
