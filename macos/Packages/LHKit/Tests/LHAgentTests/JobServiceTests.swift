import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore
import LHStore

// The job service over scripted transports (ports of tests/jobs.test.ts'
// store / dispatch / wake / handoff / abort / recovery cases, adapted to
// docs/native-macos-m6.md): one steer per job, exactly once, on every path.

private struct JobHarness {
	let turns: Harness
	let jobs: JobService
	let sub: ScriptedTransport
	var db: AppDatabase { turns.db }
	var chatId: String { turns.chatId }
	var repo: JobRepository

	init(teacher: [ScriptedTransport.Response], sub: [ScriptedTransport.Response] = [], subTransport: (any AnthropicTransport)? = nil,
		gated: GatedTransport? = nil, messages: [Message] = [greeting, hello], db: AppDatabase? = nil, chatId: String? = nil) async throws
	{
		turns = try Harness(teacher, gated: gated, messages: messages, db: db, chatId: chatId)
		let dir = FileManager.default.temporaryDirectory.appending(path: "lh-jobs-\(UUID().uuidString)")
		self.sub = ScriptedTransport(sub)
		let t: any AnthropicTransport = subTransport ?? self.sub
		jobs = JobService(database: turns.db, dataDirectory: dir, keychain: InMemoryKeychain(key: "sk-ant-test"),
			catalog: try ModelCatalog(data: Data(MODELS_JSON.utf8)), makeTransport: { t }, verifier: FakeVerifier(), fileAccess: FileAccess(folders: { [] }))
		repo = JobRepository(turns.db, dataDirectory: dir)
		await jobs.attach(turns.service)
	}

	func job(_ toolCallId: String) throws -> JobRecord? { try repo.findJob(chatId: chatId, toolCallId: toolCallId) }
	var steers: [Message] { get throws { try turns.record.messages.filter { $0.id.hasPrefix("steer_job_") } } }
}

private let greeting = newUserMessage("hi", now: 0)
private let hello = Message(id: "a0", timestamp: 0, body: .assistant(AssistantBody(content: [.text("Hello.")], model: "claude-opus-5-5", stopReason: "end_turn")))
private let BRIEF = "## Summary\nJoins combine rows. [Docs](https://www.postgresql.org/docs/)"
private let researched: ScriptedTransport.Response = .sse(ScriptedSSE.message([.text(BRIEF)]))
private let researchInput: JSONValue = ["question": "How do joins work?"]

/// Poll until `condition` holds (10s budget).
private func eventually(_ what: String, _ condition: () throws -> Bool) async throws {
	let deadline = ContinuousClock.now + .seconds(10)
	while ContinuousClock.now < deadline {
		if (try? condition()) == true { return }
		try await Task.sleep(for: .milliseconds(10))
	}
	Issue.record("timed out waiting for \(what)")
	throw CancellationError()
}

@Suite(.serialized) struct JobServiceTests {
	@Test func dispatchCreatesOneJobPerToolCallAndAcks() async throws {
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("Using it.")]))], sub: [researched])
		let ack = await h.jobs.dispatch(kind: .research, chatId: h.chatId, toolCallId: "tc1", input: researchInput, ack: RESEARCH_ACK)
		let again = await h.jobs.dispatch(kind: .research, chatId: h.chatId, toolCallId: "tc1", input: researchInput, ack: RESEARCH_ACK)
		let job = try #require(try h.job("tc1"))
		#expect(ack == "Dispatched (job \(job.id)). \(RESEARCH_ACK)")
		#expect(again == ack)
		try await eventually("delivery") { try h.job("tc1")?.status == .done }
		#expect(h.sub.requestBodies.count == 1, "the second dispatch spawned nothing")
	}

	@Test func anIdleSessionIsWokenWithTheMarkerWrittenAhead() async throws {
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("The research is in.")]))], sub: [researched])
		let ev = await h.turns.service.events()
		_ = await h.jobs.dispatch(kind: .research, chatId: h.chatId, toolCallId: "tc1", input: researchInput, ack: RESEARCH_ACK)
		try await settles(ev, h.chatId)
		let job = try #require(try h.job("tc1"))
		#expect(job.status == .done)
		#expect(job.activity == "delivered")
		#expect(job.usage?.steps == 1)
		#expect(try h.repo.usageSteps(jobId: job.id).map(\.inputTokens) == [10], "each call lands in usage_step")
		let ids = try h.turns.record.messages.map(\.id)
		#expect(ids.firstIndex(of: "steer_\(job.id)")! < ids.count - 1, "the marker precedes the wake turn's reply")
		guard case .marker(let m) = try #require(try h.steers.first).body else { Issue.record("not a marker"); return }
		#expect(m.kind == .subagentSteer)
		#expect(m.details["result"]?["sources"]?[0]?["url"]?.stringValue == "https://www.postgresql.org/docs/")
		#expect(h.turns.transport.requestBodies.count == 1)
	}

	@Test func aRunningTurnTakesTheSteerAtItsBoundary() async throws {
		let gate = GatedTransport(ScriptedTransport([
			.sse(ScriptedSSE.message([.text("Working on it.")])),
			.sse(ScriptedSSE.message([.text("Here's what the research says.")])),
		]))
		let h = try await JobHarness(teacher: [], sub: [researched], gated: gate)
		let ev = await h.turns.service.events()
		try await h.turns.service.send(h.chatId, .text("teach me joins"))
		while !gate.reachedGate { try await Task.sleep(for: .milliseconds(5)) }
		_ = await h.jobs.dispatch(kind: .research, chatId: h.chatId, toolCallId: "tc1", input: researchInput, ack: RESEARCH_ACK)
		try await eventually("handed") { try !SteerOutboxRepository(h.db).steers(chatId: h.chatId, state: .handed).isEmpty }
		gate.open()
		try await settles(ev, h.chatId)
		try await eventually("settled job") { try h.job("tc1")?.status == .done }
		#expect(try h.steers.count == 1)
		#expect(gate.inner.requestBodies.count == 2, "one turn, two calls: the steer rode the boundary")
	}

	@Test func anOpenQuestionHoldsTheSteerForTheAnswerTurn() async throws {
		let h = try await JobHarness(teacher: [
			.sse(ScriptedSSE.message([tool("c1", "probe", probeInput)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Right — and the research is in.")])),
		], sub: [researched], messages: [])
		let ev = await h.turns.service.events()
		try await h.turns.service.send(h.chatId, .text("go"))
		try await settles(ev, h.chatId)
		_ = await h.jobs.dispatch(kind: .research, chatId: h.chatId, toolCallId: "tc1", input: researchInput, ack: RESEARCH_ACK)
		try await eventually("pending") { try SteerOutboxRepository(h.db).steers(chatId: h.chatId, state: .pending).count == 1 }
		#expect(try h.job("tc1")?.status == .running, "held: not delivered yet")
		#expect(try h.steers.isEmpty)
		let ev2 = await h.turns.service.events()
		try await h.turns.service.send(h.chatId, .answer(toolCallId: "c1", answer: answer()))
		try await settles(ev2, h.chatId)
		try await eventually("delivered") { try h.job("tc1")?.status == .done }
		#expect(try h.steers.count == 1)
	}

	@Test func endAbortsWithOneAbortSteerAndTheResultNeverLands() async throws {
		let subGate = GatedTransport(ScriptedTransport([researched]))
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("Okay, without it.")]))], subTransport: subGate)
		let ev = await h.turns.service.events()
		_ = await h.jobs.dispatch(kind: .research, chatId: h.chatId, toolCallId: "tc1", input: researchInput, ack: RESEARCH_ACK)
		while !subGate.reachedGate { try await Task.sleep(for: .milliseconds(5)) }
		let job = try #require(try h.job("tc1"))
		#expect(await h.jobs.abort(job.id) == .ok)
		try await settles(ev, h.chatId)
		subGate.open()
		try await Task.sleep(for: .milliseconds(200))
		let after = try #require(try h.job("tc1"))
		#expect(after.status == .error)
		#expect(after.error == "Aborted by learner")
		let steers = try h.steers
		#expect(steers.count == 1)
		guard case .marker(let m) = try #require(steers.first).body else { return }
		#expect(m.kind == .subagentAbort)
		#expect(await h.jobs.abort(job.id) == .notRunning)
		#expect(await h.jobs.abort("job_nope") == .notFound)
	}

	@Test func aFailureStillDeliversAndMarksTheJobError() async throws {
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("I'll go from memory.")]))],
			sub: [.http(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#)])
		let ev = await h.turns.service.events()
		_ = await h.jobs.dispatch(kind: .research, chatId: h.chatId, toolCallId: "tc1", input: researchInput, ack: RESEARCH_ACK)
		try await settles(ev, h.chatId)
		let job = try #require(try h.job("tc1"))
		#expect(job.status == .error)
		guard case .marker(let m) = try #require(try h.steers.first).body else { return }
		#expect(m.content.hasPrefix("Research failed: "))
	}

	@Test func aDemoArtifactIsStoredOutOfLineAndDelivered() async throws {
		let html = "<!doctype html><body>demo</body>"
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("Try the demo.")]))], sub: [
			.sse(ScriptedSSE.message([.toolUse(id: "w", name: "write_demo", json: (["html": .string(html)] as JSONValue).serialized())], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.toolUse(id: "r", name: "run_demo", json: "{}")], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Drag it.")])),
		])
		let ev = await h.turns.service.events()
		_ = await h.jobs.dispatch(kind: .demo, chatId: h.chatId, toolCallId: "tc1", input: ["title": "Slopes", "brief": "b"], ack: DEMO_ACK)
		try await settles(ev, h.chatId)
		let job = try #require(try h.job("tc1"))
		#expect(job.status == .done)
		#expect(job.result?["artifactPath"]?.stringValue == "artifacts/\(job.id)/demo.html")
		#expect(try h.repo.artifactText(for: job.result!) == html)
	}

	// MARK: Launch recovery

	@Test func recoveryRedeliversAStoredResult() async throws {
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("Back to it.")]))])
		let job = try h.repo.createJob(kind: .research, chatId: h.chatId, toolCallId: "tc1")
		try h.repo.updateJob(job.id, JobRepository.Patch(result: SubagentResult.research(ResearchResult(brief: BRIEF, sources: [])).json))
		let ev = await h.turns.service.events()
		await h.jobs.recoverOnLaunch()
		try await settles(ev, h.chatId)
		#expect(try h.job("tc1")?.status == .done)
		#expect(try h.steers.count == 1)
		#expect(h.sub.requestBodies.isEmpty, "no re-run")
	}

	@Test func recoveryRerunsFromTheTranscriptsToolInput() async throws {
		let call = Message(id: "a1", timestamp: 1, body: .assistant(AssistantBody(content: [
			Block(raw: ["type": "tool_use", "id": "tc1", "name": "research", "input": researchInput]),
		], model: "claude-opus-5-5", stopReason: "tool_use")))
		let result = Message(id: "r1", timestamp: 2, body: .toolResult(ToolResultBody(toolUseId: "tc1", toolName: "research", content: [.text("Dispatched")], isError: false)))
		let done = Message(id: "a2", timestamp: 3, body: .assistant(AssistantBody(content: [.text("Meanwhile…")], model: "claude-opus-5-5", stopReason: "end_turn")))
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("Here it is.")]))], sub: [researched], messages: [greeting, call, result, done])
		_ = try h.repo.createJob(kind: .research, chatId: h.chatId, toolCallId: "tc1")
		let ev = await h.turns.service.events()
		await h.jobs.recoverOnLaunch()
		try await settles(ev, h.chatId)
		#expect(try h.job("tc1")?.status == .done)
		let req = try JSONValue.parse(h.sub.requestBodies[0])
		#expect(req["messages"]?[0]?["content"]?[0]?["text"]?.stringValue?.hasPrefix("Research question: How do joins work?") == true)
	}

	@Test func recoveryFailsAJobWhoseInputWasNeverSaved() async throws {
		let h = try await JobHarness(teacher: [.sse(ScriptedSSE.message([.text("Noted.")]))])
		_ = try h.repo.createJob(kind: .visual, chatId: h.chatId, toolCallId: "tc_lost")
		let ev = await h.turns.service.events()
		await h.jobs.recoverOnLaunch()
		try await settles(ev, h.chatId)
		let job = try #require(try h.job("tc_lost"))
		#expect(job.status == .error)
		#expect(job.error == "interrupted — its input was never saved")
		#expect(h.sub.requestBodies.isEmpty)
	}

	@Test func aSteerAlreadyInTheRecordOnlySettlesTheJob() async throws {
		let h = try await JobHarness(teacher: [])
		let job = try h.repo.createJob(kind: .research, chatId: h.chatId, toolCallId: "tc1")
		let r = SubagentResult.research(ResearchResult(brief: BRIEF, sources: []))
		try h.repo.updateJob(job.id, JobRepository.Patch(result: r.json))
		try ChatRepository(h.db).append([buildSubagentSteer(jobId: job.id, kind: .research, toolCallId: "tc1", result: r)], to: h.chatId)
		await h.jobs.recoverOnLaunch()
		try await eventually("settled") { try h.job("tc1")?.status == .done }
		#expect(try h.steers.count == 1)
		#expect(h.turns.transport.requestBodies.isEmpty, "no second delivery, no wake")
	}
}
