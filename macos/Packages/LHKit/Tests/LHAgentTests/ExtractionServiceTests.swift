import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore
import LHStore

// The extraction pipeline over scripted transports (ports of the
// tests/extraction.test.ts trigger / batch / submit-seam / merge / abort /
// notes cases, plus the native backfill, docs/native-macos-m7.md).

private func teacher(_ id: String, _ text: String, at t: Int = 1) -> Message {
	Message(id: id, timestamp: t, body: .assistant(AssistantBody(content: [.text(text)], model: "claude-opus-5-5", stopReason: "end_turn")))
}

private func submitFindings(_ props: [JSONValue], chains: [JSONValue] = []) -> ScriptedTransport.Response {
	.sse(ScriptedSSE.message([.toolUse(id: "s\(UUID().uuidString.prefix(6))", name: "submit_findings", json: (["propositions": .array(props), "chains": .array(chains)] as JSONValue).serialized())], stopReason: "tool_use"))
}

private func submitReview(_ links: [JSONValue] = []) -> ScriptedTransport.Response {
	.sse(ScriptedSSE.message([.toolUse(id: "r\(UUID().uuidString.prefix(6))", name: "submit_review", json: (["links": .array(links)] as JSONValue).serialized())], stopReason: "tool_use"))
}

private func prop(_ id: String, _ name: String, anchor: String? = nil) -> JSONValue {
	var o = JSONObject(["id": .string(id), "name": .string(name), "statement": .string("\(name) is a true statement.")])
	if let anchor { o["messageId"] = .string(anchor) }
	return .object(o)
}

private struct Env {
	let db: AppDatabase
	let transport: ScriptedTransport
	let service: ExtractionService
	var graph: GraphRepository { GraphRepository(db) }

	init(_ responses: [ScriptedTransport.Response], transport: (any AnthropicTransport)? = nil, chunkTokens: Int? = nil, key: String? = "sk-ant-test") throws {
		db = try AppDatabase.inMemory()
		self.transport = ScriptedTransport(responses)
		let t: any AnthropicTransport = transport ?? self.transport
		if let chunkTokens { try SettingsRepository(db).update { $0.graph = GraphSettings(extractionChunkTokens: chunkTokens) } }
		service = ExtractionService(database: db, keychain: InMemoryKeychain(key: key), catalog: try ModelCatalog(data: Data(MODELS_JSON.utf8)), makeTransport: { t })
	}

	func chat(kind: ChatKind? = nil, _ messages: [Message]) throws -> String {
		let title = "Joins"
		let chat = try ChatRepository(db).createChat(title: title, kind: kind ?? .teach)
		try ChatRepository(db).append(messages, to: chat.id)
		return chat.id
	}

	func settled(_ source: String) async throws {
		let deadline = ContinuousClock.now + .seconds(10)
		while await service.isRunning(source) {
			guard ContinuousClock.now < deadline else { Issue.record("never settled"); throw CancellationError() }
			try await Task.sleep(for: .milliseconds(5))
		}
	}
}

@Suite(.serialized) struct ExtractionServiceTests {
	@Test func aBatchMergesWithCoverageAndUsage() async throws {
		let env = try Env([submitFindings([prop("p1", "Inner join", anchor: "t1")]), submitReview()])
		let chatId = try env.chat([newUserMessage("teach me", now: 0), teacher("t1", "An inner join keeps matching rows.")])
		#expect(await env.service.extractNow(chatId) == .started)
		#expect(await env.service.extractNow(chatId) == .alreadyRunning)
		try await env.settled(chatId)
		let nodes = getGraph(env.graph).nodes
		#expect(nodes.map(\.name) == ["Inner join"])
		#expect(nodes[0].provenance == [ProvenancePoint(chatId: chatId, messageId: "t1")])
		let cov = try #require(await env.service.coverage(chatId))
		#expect(cov.uncoveredCount == 0 && cov.coveredCount == 1 && cov.lastFoldedAt != nil)
		let runs = try #require(try ChatRepository(env.db).get(chatId)?.extractions)
		#expect(runs.count == 1)
		#expect(runs[0].stats?.nodes == 1)
		#expect(runs[0].stages.extractor.steps.count == 1 && runs[0].stages.auditor.steps.count == 1)
		// The extractor read teacher prose only, labelled by message id.
		let req = try JSONValue.parse(env.transport.requestBodies[0])
		#expect(req["messages"]?[0]?["content"]?[0]?["text"]?.stringValue == "# Joins\n\nTEACHER [t1] An inner join keeps matching rows.")
		#expect(await env.service.extractNow(chatId) == .nothingToDo)
	}

	@Test func anAnchorOutsideTheBatchIsSentBackAndRetried() async throws {
		let env = try Env([
			submitFindings([prop("p1", "Join", anchor: "u0")]),
			submitFindings([prop("p1", "Join", anchor: "t1")]),
			submitReview(),
		])
		let chatId = try env.chat([newUserMessage("q", id: "u0", now: 0), teacher("t1", "Joins combine tables.")])
		_ = await env.service.extractNow(chatId)
		try await env.settled(chatId)
		let second = try JSONValue.parse(env.transport.requestBodies[1])
		let result = second["messages"]?.arrayValue?.last?["content"]?[0]
		#expect(result?["is_error"]?.boolValue == true)
		#expect(result?["content"]?[0]?["text"]?.stringValue?.contains("names messageId \"u0\", which is not a passage of THIS stretch") == true)
		#expect(getGraph(env.graph).nodes.count == 1)
	}

	@Test func aFailedBatchStaysUncoveredAndBillsItsUsage() async throws {
		let env = try Env([.sse(ScriptedSSE.message([.text("I won't submit.")]))])
		let chatId = try env.chat([teacher("t1", "Prose.")])
		_ = await env.service.extractNow(chatId)
		try await env.settled(chatId)
		#expect(getGraph(env.graph).nodes.isEmpty)
		#expect(await env.service.coverage(chatId)?.uncoveredCount == 1)
		#expect(try ChatRepository(env.db).get(chatId)?.extractions?.first?.stats == nil)
	}

	@Test func theTurnTriggerWaitsForTheThreshold() async throws {
		// Two batches once over the threshold: the short message, then the long one alone.
		let env = try Env([submitFindings([prop("p1", "Short idea", anchor: "t1")]), submitReview(),
			submitFindings([prop("p1", "Long idea", anchor: "t2")]), submitReview()], chunkTokens: 500)
		let chatId = try env.chat([teacher("t1", "Short.")])
		await env.service.turnSettled(chatId)
		#expect(await !env.service.isRunning(chatId), "under the threshold: nothing runs")
		try ChatRepository(env.db).append([teacher("t2", String(repeating: "word ", count: 500), at: 2)], to: chatId)
		await env.service.turnSettled(chatId)
		try await env.settled(chatId)
		#expect(getGraph(env.graph).nodes.map(\.name) == ["Short idea", "Long idea"])
	}

	@Test func practiceAndExtractionOffNeverTrigger() async throws {
		let env = try Env([], chunkTokens: 500)
		let practice = try env.chat(kind: .practice, [teacher("t1", String(repeating: "x ", count: 2000))])
		await env.service.turnSettled(practice)
		#expect(await !env.service.isRunning(practice))
		try SettingsRepository(env.db).update { $0.graph = GraphSettings(enabled: false, extractionChunkTokens: 500) }
		let teach = try env.chat([teacher("t2", String(repeating: "x ", count: 2000))])
		await env.service.turnSettled(teach)
		#expect(await !env.service.isRunning(teach))
	}

	@Test func batchesRunInOrderAndTheSecondSeesTheFirstsDigest() async throws {
		let env = try Env([
			submitFindings([prop("p1", "Alpha", anchor: "t1")]), submitReview(),
			submitFindings([prop("p1", "Beta", anchor: "t2")]), submitReview(),
		], chunkTokens: 500)
		let long = String(repeating: "word ", count: 450)
		let chatId = try env.chat([teacher("t1", long), teacher("t2", long, at: 2)])
		_ = await env.service.extractNow(chatId)
		try await env.settled(chatId)
		#expect(getGraph(env.graph).nodes.map(\.name) == ["Alpha", "Beta"])
		let third = try JSONValue.parse(env.transport.requestBodies[2])
		#expect(third["messages"]?[0]?["content"]?[0]?["text"]?.stringValue?.hasPrefix("THE GRAPH SO FAR") == true)
	}

	@Test func abortMergesNothing() async throws {
		let gate = GatedTransport(ScriptedTransport([submitFindings([prop("p1", "X", anchor: "t1")]), submitReview()]))
		let env = try Env([], transport: gate)
		let chatId = try env.chat([teacher("t1", "Prose.")])
		_ = await env.service.extractNow(chatId)
		while !gate.reachedGate { try await Task.sleep(for: .milliseconds(5)) }
		#expect(await env.service.abort(chatId))
		gate.open()
		try await env.settled(chatId)
		#expect(getGraph(env.graph).nodes.isEmpty)
		#expect(await env.service.coverage(chatId)?.uncoveredCount == 1)
	}

	@Test func notesImportKeysByFullPathAndMerges() async throws {
		let env = try Env([submitFindings([prop("p1", "Monad")]), submitReview(), submitFindings([prop("p1", "Functor")]), submitReview()])
		// One at a time here: parallel files would race for the scripted replies.
		let results = await env.service.importNotes([.init(path: "/a/notes.md", text: "Monads are burritos.")])
			+ env.service.importNotes([.init(path: "/b/notes.md", text: "Functors map.")])
		#expect(results.map(\.outcome) == [.completed, .completed])
		let sources = env.graph.readSources()
		#expect(Set(sources.map(\.id)) == [notesSourceId(path: "/a/notes.md"), notesSourceId(path: "/b/notes.md")])
		#expect(Set(getGraph(env.graph).nodes.map(\.name)) == ["Monad", "Functor"])
		#expect(sources.allSatisfy { $0.extractions?.count == 1 })
	}

	@Test func theBackfillRunsOnceOverEveryEligibleSession() async throws {
		let env = try Env([submitFindings([prop("p1", "Old idea", anchor: "t1")]), submitReview()], chunkTokens: 4096)
		let old = try env.chat([teacher("t1", "A short old lesson.")])
		_ = try env.chat(kind: .practice, [teacher("t2", "Practice prose.")])
		await env.service.backfillIfNeeded()
		#expect(getGraph(env.graph).nodes.map(\.name) == ["Old idea"], "below the threshold, still extracted")
		#expect(env.graph.backfillDone)
		#expect(await env.service.coverage(old)?.uncoveredCount == 0)
		try ChatRepository(env.db).append([teacher("t3", "More.", at: 3)], to: old)
		await env.service.backfillIfNeeded()
		#expect(env.transport.requestBodies.count == 2, "a second launch never backfills again")
	}
}
