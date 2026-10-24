import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore

// MARK: Test tools

struct ClockTool: AgentTool {
	let name = "get_current_time"
	let description = "The current time in a timezone."
	let schema = JSONSchema.object(["timezone": .string(description: "IANA timezone")], additionalProperties: false)
	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		.value(.string("12:00 in \(input["timezone"]?.stringValue ?? "?")"))
	}
}

struct QuizTool: AgentTool {
	let name = "quiz"
	let description = "Ask a question."
	let schema = JSONSchema.object(["question": .string()])
	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput { .questionPosed }
}

struct SleepyTool: AgentTool {
	let name = "sleepy"
	let description = "Sleeps."
	let schema = JSONSchema.object([:])
	let started: Box<Bool>
	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		started.mutate { $0 = true }
		try await Task.sleep(for: .seconds(30))
		return .value("woke")
	}
}

final class Box<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var v: T
	init(_ v: T) { self.v = v }
	var value: T { lock.withLock { v } }
	func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

/// A steering source with scripted batches per drain.
actor ScriptedSteering: SteeringSource {
	var batches: [[Message]]
	init(_ batches: [[Message]]) { self.batches = batches }
	func drain() -> [Message] { batches.isEmpty ? [] : batches.removeFirst() }
}

func loop(_ transport: ScriptedTransport, tools: [any AgentTool] = [ClockTool()], toolTimeout: Duration = .seconds(30)) -> AgentLoop {
	var client = MessagesClient(transport: transport, apiKey: { "sk-ant-test" })
	client.backoff = { _ in 0.001 }
	client.jitter = { 0 }
	var counter = 0
	let ids = Box(0)
	var l = AgentLoop(client: client, config: AgentConfig(model: "claude-opus-5-5", effort: .low, system: "SYS", tools: tools, cacheTTL: .oneHour, toolTimeout: toolTimeout, updateInterval: .zero))
	_ = counter
	counter += 1
	l.mintId = { ids.mutate { $0 += 1 }; return "m\(ids.value)" }
	l.now = { 1 }
	return l
}

func requestJSON(_ t: ScriptedTransport, _ i: Int) throws -> JSONValue { try JSONValue.parse(t.requestBodies[i]) }

@Suite struct AgentLoopTests {
	@Test func aTextTurnSettlesOneAssistantMessageWithUsage() async throws {
		let t = ScriptedTransport([.sse(ScriptedSSE.message([.thinking("plan", signature: "S"), .text("Hello!")],
			usage: ["input_tokens": 20, "output_tokens": 3, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 5000, "cache_creation": ["ephemeral_1h_input_tokens": 5000]]))])
		let events = Box<[String]>([])
		let out = await loop(t).run(history: [], inputs: [user("u1", "hi")]) { e in
			if case .messageUpdate = e { events.mutate { $0.append("update") } }
		}
		#expect(out.newMessages.map(\.role) == [.user, .assistant])
		let a = try #require(out.newMessages[1].assistant)
		#expect(a.content.map(\.raw).map { $0.serialized() } == [#"{"type":"thinking","thinking":"plan","signature":"S"}"#, #"{"type":"text","text":"Hello!"}"#])
		#expect(a.stopReason == "end_turn")
		#expect(out.steps == [UsageStepRecord(model: "claude-opus-5-5", usage: CallUsage(inputTokens: 20, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 5000, cacheWrite1hTokens: 5000), fallbackFrom: nil)])
		#expect(!events.value.isEmpty)
		#expect(!out.aborted)
	}

	@Test func toolsRunInParallelAndAllResultsReturnInOneUserMessage() async throws {
		let t = ScriptedTransport([
			.sse(ScriptedSSE.message([.text("Checking"), .toolUse(id: "toolu_1", name: "get_current_time", json: #"{"timezone":"Europe/Paris"}"#),
				.toolUse(id: "toolu_2", name: "get_current_time", json: #"{"timezone":"Asia/Tokyo"}"#)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Done")])),
		])
		let out = await loop(t).run(history: [user("u0", "time?")]) { _ in }
		#expect(out.newMessages.map(\.role) == [.assistant, .toolResult, .toolResult, .assistant])
		#expect(out.newMessages[1].toolResult?.firstText == "12:00 in Europe/Paris")
		#expect(out.newMessages[2].toolResult?.firstText == "12:00 in Asia/Tokyo")
		let second = try requestJSON(t, 1)
		let lastUser = try #require(second["messages"]?.arrayValue?.last)
		#expect(lastUser["role"] == "user")
		#expect(lastUser["content"]?.arrayValue?.map { $0["tool_use_id"] } == ["toolu_1", "toolu_2"])
		// The second request's prefix is the first request's messages, unchanged.
		let first = try requestJSON(t, 0)["messages"]!.arrayValue!
		#expect(Array(second["messages"]!.arrayValue!.prefix(first.count)) == first)
	}

	@Test func questionToolsTerminateAndTheirPlaceholderNeverPersists() async throws {
		let t = ScriptedTransport([.sse(ScriptedSSE.message([.toolUse(id: "toolu_q", name: "quiz", json: #"{"question":"Why?"}"#)], stopReason: "tool_use"))])
		let out = await loop(t, tools: [QuizTool()]).run(history: [user("u0", "teach me")]) { _ in }
		#expect(out.newMessages.map(\.role) == [.assistant])
		#expect(t.requests.count == 1)
		#expect(danglingQuestionOf([user("u0", "x")] + out.newMessages)?.toolCallId == "toolu_q")
	}

	@Test func steersQueuedMidTurnEnterAfterTheToolResults() async throws {
		let t = ScriptedTransport([
			.sse(ScriptedSSE.message([.toolUse(id: "toolu_1", name: "get_current_time", json: #"{"timezone":"UTC"}"#)], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("Noted your steer.")])),
		])
		let steer = newUserSteer("actually use Paris", id: "steer_1", now: 1)
		let out = await loop(t).run(history: [user("u0", "time?")], steering: ScriptedSteering([[], [steer]])) { _ in }
		#expect(out.newMessages.map(\.id).contains("steer_1"))
		let lastUser = try #require(try requestJSON(t, 1)["messages"]?.arrayValue?.last)
		#expect(lastUser["content"]?.arrayValue?.map { $0["type"] } == ["tool_result", "text"])
		#expect(lastUser["content"]?[1]?["text"] == "actually use Paris")
	}

	@Test func aSteerAfterAPlainReplyStartsAnotherRequest() async throws {
		let t = ScriptedTransport([.sse(ScriptedSSE.message([.text("one")])), .sse(ScriptedSSE.message([.text("two")]))])
		let out = await loop(t).run(history: [user("u0", "a")], steering: ScriptedSteering([[], [newUserSteer("b", id: "s", now: 1)], []])) { _ in }
		#expect(out.newMessages.map(\.role) == [.assistant, .user, .assistant])
	}

	@Test func abortMidStreamRecordsThePartialAsAborted() async throws {
		let sse = ScriptedSSE.message([.text("A long answer that never finishes streaming")], chunk: 4)
		let t = ScriptedTransport([.sseThenHang(sse, afterLines: 20)])
		let l = loop(t)
		let gotText = Box(false)
		let task = Task {
			await l.run(history: [user("u0", "a")]) { e in
				if case .messageUpdate(let m) = e, m.assistant?.content.first?.text?.isEmpty == false { gotText.mutate { $0 = true } }
			}
		}
		while !gotText.value { try await Task.sleep(for: .milliseconds(5)) }
		task.cancel()
		let out = await task.value
		#expect(out.aborted)
		let a = try #require(out.newMessages.last?.assistant)
		#expect(a.stopReason == "aborted")
		#expect(a.content.first?.text?.isEmpty == false)
		// The aborted partial never reaches the next request.
		#expect(WireProjection.project([user("u0", "a")] + out.newMessages).count == 1)
	}

	@Test func abortMidToolRecordsOperationAborted() async throws {
		let started = Box(false)
		let t = ScriptedTransport([.sse(ScriptedSSE.message([.toolUse(id: "toolu_s", name: "sleepy", json: "{}")], stopReason: "tool_use")), .sse("")])
		let l = loop(t, tools: [SleepyTool(started: started)])
		let task = Task { await l.run(history: [user("u0", "a")]) { _ in } }
		while !started.value { try await Task.sleep(for: .milliseconds(5)) }
		task.cancel()
		let out = await task.value
		#expect(out.aborted)
		#expect(out.newMessages.last?.toolResult?.firstText == "Operation aborted")
		#expect(out.newMessages.last?.toolResult?.isError == true)
		#expect(t.requests.count == 1, "no request after an abort")
	}

	@Test func aRefusalEndsTheTurnAndKeepsItsStopDetails() async throws {
		let details: JSONValue = ["type": "refusal", "category": "cyber", "explanation": "declined"]
		let t = ScriptedTransport([.sse(ScriptedSSE.message([.text("I can")], stopReason: "refusal", stopDetails: details))])
		let out = await loop(t).run(history: [user("u0", "x")]) { _ in }
		let a = try #require(out.newMessages.last?.assistant)
		#expect(a.stopReason == "refusal")
		#expect(a.stopDetails == details)
		#expect(t.requests.count == 1)
	}

	@Test func fallbackResponsesAreStoredAsReturnedAndBilledPerAttempt() async throws {
		let fb: JSONValue = ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-5"]]
		let usage: JSONValue = ["input_tokens": 10, "output_tokens": 4, "iterations": [
			["type": "message", "model": "claude-opus-5-5", "input_tokens": 10, "output_tokens": 0],
			["type": "fallback_message", "model": "claude-opus-5", "input_tokens": 10, "output_tokens": 4],
		]]
		let t = ScriptedTransport([.sse(ScriptedSSE.message(model: "claude-opus-5", [.raw(fb), .text("served")], usage: usage, finalUsage: usage))])
		let out = await loop(t).run(history: [user("u0", "x")]) { _ in }
		let a = try #require(out.newMessages.last?.assistant)
		#expect(a.content.first?.type == "fallback")
		#expect(a.model == "claude-opus-5")
		#expect(out.model == "claude-opus-5")
		#expect(out.steps.map(\.fallbackFrom) == [nil, "claude-opus-5-5"])
	}

	@Test func pauseTurnResendsWithinTheTurn() async throws {
		let srv = ScriptedSSE.Piece.serverToolUse(id: "srvtoolu_1", name: "web_search", json: #"{"query":"swift"}"#)
		let t = ScriptedTransport([
			.sse(ScriptedSSE.message([.text("Searching"), srv], stopReason: "pause_turn")),
			.sse(ScriptedSSE.message([.text("Found it")])),
		])
		let out = await loop(t).run(history: [user("u0", "search")]) { _ in }
		#expect(out.newMessages.map(\.role) == [.assistant, .assistant])
		let second = try requestJSON(t, 1)["messages"]!.arrayValue!
		#expect(second.last?["role"] == "assistant")
		#expect(second.last?["content"]?[1]?["type"] == "server_tool_use")
	}

	@Test func maxTokensWithAToolCallFailsTheCallsAndContinues() async throws {
		let t = ScriptedTransport([
			.sse(ScriptedSSE.message([.toolUse(id: "toolu_1", name: "get_current_time", json: #"{"timez"#)], stopReason: "max_tokens")),
			.sse(ScriptedSSE.message([.text("Retrying properly")])),
		])
		let out = await loop(t).run(history: [user("u0", "x")]) { _ in }
		let r = try #require(out.newMessages[1].toolResult)
		#expect(r.isError)
		#expect(r.firstText == AgentLoop.truncatedCallText("get_current_time"))
		#expect(out.newMessages.last?.assistant?.content.first?.text == "Retrying properly")
	}

	@Test func invalidStreamedJSONAndSchemaFailuresBecomeErrorResults() async throws {
		let t = ScriptedTransport([
			.sse(ScriptedSSE.message([
				.toolUse(id: "toolu_1", name: "get_current_time", json: #"{"timezone": "Par"#),
				.toolUse(id: "toolu_2", name: "get_current_time", json: #"{"zone":"UTC"}"#),
				.toolUse(id: "toolu_3", name: "nope", json: "{}"),
			], stopReason: "tool_use")),
			.sse(ScriptedSSE.message([.text("ok")])),
		])
		let out = await loop(t).run(history: [user("u0", "x")]) { _ in }
		let results = out.newMessages.compactMap(\.toolResult)
		#expect(results[0].firstText == #"{"INVALID_JSON":"{\"timezone\": \"Par"}"#)
		#expect(results[1].firstText?.hasPrefix("Validation failed for tool \"get_current_time\":") == true)
		#expect(results[2].firstText == "Tool nope not found")
		#expect(results.allSatisfy { $0.isError })
	}

	@Test func aMidStreamErrorSettlesAsAnErrorMessage() async throws {
		let sse = ScriptedSSE.message([.text("partial text here")]) + ScriptedSSE.errorEvent(type: "api_error", message: "Internal")
		let cut = sse.replacingOccurrences(of: ScriptedSSE.frame("message_stop", ["type": "message_stop"]), with: "")
		let t = ScriptedTransport([.sse(cut)])
		let out = await loop(t).run(history: [user("u0", "x")]) { _ in }
		let a = try #require(out.newMessages.last?.assistant)
		#expect(a.stopReason == "error")
		#expect(a.errorMessage == "Internal")
	}

	@Test func retryNoticesReachTheEventStream() async throws {
		let t = ScriptedTransport([.http(status: 529, body: "{}"), .sse(ScriptedSSE.message([.text("ok")]))])
		let notices = Box(0)
		_ = await loop(t).run(history: [user("u0", "x")]) { e in if case .retrying = e { notices.mutate { $0 += 1 } } }
		#expect(notices.value == 1)
	}
}

@Suite struct ToolGuardTests {
	@Test func timesOutWithTheTSWording() async {
		await #expect(throws: ToolGuardError.timedOut(tool: "slow", timeout: .milliseconds(50))) {
			_ = try await ToolGuard.run("slow", timeout: .milliseconds(50)) {
				// Ignores cancellation (a hung tool) until well past the grace.
				let deadline = Date().addingTimeInterval(1)
				while Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
				return .value("late")
			}
		}
		#expect(ToolGuardError.timedOut(tool: "slow", timeout: .seconds(30)).description == #"Tool "slow" timed out after 30s — the result was discarded"#)
		#expect(ToolGuardError.timedOut(tool: "slow", timeout: .milliseconds(50)).description == #"Tool "slow" timed out after 50ms — the result was discarded"#)
	}

	@Test func aCooperativeToolSettlesItsPartialWithinTheGrace() async throws {
		let out = try await ToolGuard.run("coop", timeout: .milliseconds(30)) {
			do { try await Task.sleep(for: .seconds(5)) } catch { return .value("partial") }
			return .value("full")
		}
		#expect(out.content.first?.text == "partial")
	}

	@Test func aPreCancelledRunRejectsWithPisWording() async {
		let task = Task {
			try await ToolGuard.run("x") {
				try await Task.sleep(for: .seconds(5))
				return .value("never")
			}
		}
		task.cancel()
		do {
			_ = try await task.value
			Issue.record("expected an abort")
		} catch {
			#expect((error as? ToolGuardError) == .aborted)
			#expect("\(error)" == "Operation aborted")
		}
	}

	@Test func resultMappingParity() {
		#expect(ToolOutput.value("plain").content.first?.text == "plain")
		#expect(ToolOutput.value(["a": 1]).content.first?.text == #"{"a":1}"#)
		#expect(ToolOutput.value(["a": 1]).details == ["a": 1])
		let q = ToolOutput.questionPosed
		#expect(q.terminate && q.ephemeral && q.details == nil)
		let bad = ToolOutput.invalidInput(tool: "quiz", problems: ["options: need 2"])
		#expect(bad.isError && bad.content.first?.text == "Invalid tool input for tool \"quiz\":\n- options: need 2")
	}
}

@Suite struct SessionEngineTests {
	@Test func oneTurnPerChatAndViewsReplayThenFollow() async throws {
		let t = ScriptedTransport([.sse(ScriptedSSE.message([.text("hello there")]))])
		let engine = SessionEngine(chatId: "c1")
		let task = try await engine.start(loop(t), history: [user("u0", "hi")])
		await #expect(throws: SessionEngine.StartError.turnAlreadyRunning) { try await engine.start(loop(t), history: []) }
		let outcome = await task.value
		#expect(outcome.newMessages.count == 1)
		// A late view replays the settled turn and ends.
		while await engine.isRunning { try await Task.sleep(for: .milliseconds(5)) }
		var kinds: [String] = []
		for await e in await engine.subscribe() {
			switch e {
			case .messageStart: kinds.append("start")
			case .messageEnd: kinds.append("end")
			case .agentEnd: kinds.append("agentEnd")
			default: break
			}
		}
		#expect(kinds.first == "start")
		#expect(kinds.last == "agentEnd")
	}

	@Test func abortFromTheEngineCancelsTheTurn() async throws {
		let t = ScriptedTransport([.sseThenHang(ScriptedSSE.message([.text("streaming forever")], chunk: 3), afterLines: 10)])
		let engine = SessionEngine(chatId: "c2")
		let task = try await engine.start(loop(t), history: [user("u0", "x")])
		try await Task.sleep(for: .milliseconds(50))
		await engine.abort()
		let out = await task.value
		#expect(out.aborted)
	}
}

@Suite struct ProviderEventRecorderTests {
	func temp() -> URL { FileManager.default.temporaryDirectory.appending(path: "lhpe-\(UUID().uuidString)", directoryHint: .isDirectory) }

	@Test func offMeansNoObserverAndNoFile() {
		let dir = temp()
		let r = ProviderEventRecorder(directory: dir, enabled: false)
		#expect(r.observer(chatId: "c", context: "turn", model: "m") == nil)
		r.note(chatId: "c", context: "turn", "x")
		#expect(!FileManager.default.fileExists(atPath: dir.path))
	}

	@Test func onWritesPinnedShapeLines() throws {
		let dir = temp()
		let r = ProviderEventRecorder(directory: dir, enabled: true, clock: { 7 })
		r.observer(chatId: "chat/1", context: "turn", model: "claude-opus-5-5")?(#"{"type":"ping"}"#)
		r.observer(chatId: "chat/1", context: "turn", model: "claude-opus-5-5")?("not json")
		let text = try String(contentsOf: dir.appending(path: "chat_1.jsonl"), encoding: .utf8)
		let lines = text.split(separator: "\n").map(String.init)
		#expect(lines[0] == #"{"t":7,"ctx":"turn","provider":"anthropic","model":"claude-opus-5-5","event":{"type":"ping"}}"#)
		#expect(lines[1].contains(#""__nonJSON":"not json""#))
	}

	@Test func theByteCapWritesOneMarkerAndStops() throws {
		let dir = temp()
		let r = ProviderEventRecorder(directory: dir, enabled: true, cap: 200, clock: { 1 })
		for _ in 0..<20 { r.note(chatId: "c", context: "turn", String(repeating: "x", count: 40)) }
		let lines = try String(contentsOf: dir.appending(path: "c.jsonl"), encoding: .utf8).split(separator: "\n")
		#expect(lines.last?.contains("cap 200 bytes reached — recording stopped") == true)
		#expect(lines.filter { $0.contains("recording stopped") }.count == 1)
		#expect(lines.count < 10)
	}
}
