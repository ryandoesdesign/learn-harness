import Foundation
import Testing
import LHCore
@testable import LHStore

enum Repo {
	static let root: URL = {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<5 { url.deleteLastPathComponent() }
		return url
	}()
	static let goldenData = root.appending(path: "tests/fixtures/golden-data")

	static func goldenChat(_ id: String) throws -> ChatRecord {
		try #require(ChatRecord(legacyJSON: JSONValue.parse(Data(contentsOf: goldenData.appending(path: "chats/\(id).json")))))
	}
}

private func tempDir() throws -> URL {
	let url = FileManager.default.temporaryDirectory.appending(path: "lhstore-\(UUID().uuidString)", directoryHint: .isDirectory)
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

@Suite struct ChatRepositoryTests {
	@Test func goldenRecordsRoundTripThroughTheDatabase() throws {
		let db = try AppDatabase.inMemory()
		let repo = ChatRepository(db)
		for id in ["chat_mv27rrra_feff23b6", "chat_mv293wv5_10656952"] {
			let record = try Repo.goldenChat(id)
			try repo.insert(record, origin: .import)
			var back = try #require(try repo.get(id))
			back.version = record.version // the store stamps v1
			#expect(back == record)
		}
	}

	@Test func payloadBytesAreStoredUntouched() throws {
		let db = try AppDatabase.inMemory()
		let record = try Repo.goldenChat("chat_mv27rrra_feff23b6")
		try ChatRepository(db).insert(record, origin: .import)
		let stored = try db.writer.read { db in try String.fetchAll(db, sql: "SELECT payload_json FROM message WHERE chat_id = ? AND role = 'assistant' ORDER BY seq", arguments: [record.id]) }
		let expected = record.messages.compactMap(\.assistant).map { JSONValue.array($0.content.map(\.raw)).serialized() }
		#expect(stored == expected)
	}

	@Test func createStampsVersionAndCleansTitle() throws {
		let repo = ChatRepository(try AppDatabase.inMemory())
		let chat = try repo.createChat(title: "   ")
		#expect(chat.title == "Untitled session")
		#expect(chat.id.hasPrefix("chat_"))
		#expect(try repo.get(chat.id)?.version == CURRENT_CHAT_VERSION)
		let practice = try repo.createChat(title: "p", kind: .practice)
		#expect(try repo.get(practice.id)?.kind == .practice)
	}

	@Test func appendIsAppendOnlyAndIdempotentPerId() throws {
		let repo = ChatRepository(try AppDatabase.inMemory())
		let chat = try repo.createChat(title: "t")
		let a = newUserMessage("one", id: "m1", now: 1)
		let b = newUserMessage("two", id: "m2", now: 2)
		try repo.append([a], to: chat.id)
		try repo.append([a, b], to: chat.id)
		#expect(try repo.get(chat.id)?.messages.map(\.id) == ["m1", "m2"])
		#expect(throws: StoreError.notFound("nope")) { try repo.append([a], to: "nope") }
	}

	@Test func usageLogsAreIdempotent() throws {
		let repo = ChatRepository(try AppDatabase.inMemory())
		let chat = try repo.createChat(title: "t")
		let turn = TurnUsage(id: "turn_1", messageId: "m1", at: "2026-01-01T00:00:00.000Z", model: "claude-opus-5-5",
			steps: [CallUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: nil, cacheWriteTokens: 2, cacheWrite1hTokens: 2, reasoningTokens: nil, webSearchRequests: 1)])
		try repo.appendTurnUsage(turn, chatId: chat.id)
		try repo.appendTurnUsage(turn, chatId: chat.id)
		let run = ExtractionRunUsage(startedAt: 7, at: "x", durationMs: 3, stats: EmissionStats(nodes: 2, chains: 1),
			stages: .init(extractor: ExtractionStageUsage(model: "a", steps: [CallUsage(inputTokens: 1)]), auditor: ExtractionStageUsage(model: "b", steps: [])))
		try repo.appendExtractionUsage(run, chatId: chat.id)
		try repo.appendExtractionUsage(run, chatId: chat.id)
		let back = try #require(try repo.get(chat.id))
		#expect(back.turns == [turn])
		#expect(back.extractions == [run])
	}

	@Test func summariesMatchTheTSListProjection() throws {
		let repo = ChatRepository(try AppDatabase.inMemory())
		for id in ["chat_mv27rrra_feff23b6", "chat_mv293wv5_10656952"] { try repo.insert(try Repo.goldenChat(id), origin: .import) }
		let golden = try JSONValue.parse(Data(contentsOf: Repo.root.appending(path: "Packages/LHKit/Tests/LHCoreTests/Golden/store.summaries.json")))
		let actual = try repo.summaries()
		#expect(actual.map(\.id) == golden.arrayValue?.compactMap { $0["id"]?.stringValue })
		for (s, g) in zip(actual, golden.arrayValue ?? []) {
			#expect(s.title == g["title"]?.stringValue)
			#expect(s.kind.rawValue == g["kind"]?.stringValue)
			#expect(s.messageCount == g["messageCount"]?.intValue)
			#expect(s.phase.rawValue == g["phase"]?.stringValue)
			#expect(s.pendingQuestion == g["pendingQuestion"]?.boolValue)
			#expect(s.pendingProblem == (s.kind == .practice && g["activeProblem"]?.boolValue == true))
		}
	}

	@Test func artifactInvertLivesBesideTheAppendOnlyRow() throws {
		let db = try AppDatabase.inMemory()
		let repo = ChatRepository(db)
		let chat = try repo.createChat(title: "t")
		let steer = buildSubagentSteer(jobId: "job_1", kind: .visual, toolCallId: "c1", result: .visual(VisualResult(svg: "<svg/>")), now: 1)
		let research = buildSubagentSteer(jobId: "job_2", kind: .research, toolCallId: "c2", result: .research(ResearchResult(brief: "b", sources: [])), now: 2)
		try repo.append([steer, research], to: chat.id)
		let before = try db.writer.read { db in try String.fetchOne(db, sql: "SELECT details_json FROM message WHERE id = 'steer_job_1'") }
		try repo.setArtifactInverted(true, messageId: "steer_job_1", chatId: chat.id)
		try repo.setArtifactInverted(true, messageId: "steer_job_2", chatId: chat.id) // research: no UI flag
		let back = try #require(try repo.get(chat.id))
		#expect(back.messages[0].marker?.details["ui"]?["inverted"] == .bool(true))
		#expect(back.messages[1].marker?.details["ui"] == nil)
		let after = try db.writer.read { db in try String.fetchOne(db, sql: "SELECT details_json FROM message WHERE id = 'steer_job_1'") }
		#expect(before == after)
		try repo.setArtifactInverted(false, messageId: "steer_job_1", chatId: chat.id)
		#expect(try repo.get(chat.id)?.messages[0].marker?.details["ui"]?["inverted"] == .bool(false))
	}

	@Test func deleteCascadesAndSearchFindsText() throws {
		let db = try AppDatabase.inMemory()
		let repo = ChatRepository(db)
		let chat = try repo.createChat(title: "t")
		try repo.append([newUserMessage("the chain rule of calculus", id: "m1", now: 1)], to: chat.id)
		#expect(try repo.search("chain rule") == [chat.id])
		#expect(try repo.search("") == [])
		#expect(try repo.delete(chat.id))
		#expect(try repo.delete(chat.id) == false)
		#expect(try repo.search("chain") == [])
		let leftovers = try db.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") }
		#expect(leftovers == 0)
	}

	@Test func observationEmitsOnChange() async throws {
		let repo = ChatRepository(try AppDatabase.inMemory())
		var iterator = repo.observeSummaries().makeAsyncIterator()
		#expect(try await iterator.next()?.isEmpty == true)
		try repo.createChat(title: "x")
		#expect(try await iterator.next()?.map(\.title) == ["x"])
	}
}

@Suite struct SettingsStoreTests {
	@Test func readsNilOnFirstBoot() throws {
		#expect(try SettingsRepository(try AppDatabase.inMemory()).read() == nil)
	}

	@Test func writeReadRoundTripsThroughTheSanitizer() throws {
		let repo = SettingsRepository(try AppDatabase.inMemory())
		try repo.write(UserSettings(graph: GraphSettings(enabled: false)))
		#expect(try repo.read()?.graph == GraphSettings(enabled: false))
	}

	@Test func aFossilChatSectionIsIgnored() throws {
		let db = try AppDatabase.inMemory()
		try db.writer.write { db in
			try KV.set(SettingsRepository.userKey, ["version": 1, "chat": ["model": "x"], "graph": ["enabled": true]], db: db)
		}
		let out = try #require(try SettingsRepository(db).read())
		#expect(out.json["chat"] == nil)
		#expect(out.graph == GraphSettings(enabled: true))
	}

	@Test func corruptValueReadsAsFirstBoot() throws {
		let db = try AppDatabase.inMemory()
		try db.writer.write { db in try db.execute(sql: "INSERT INTO kv_settings (key, value_json) VALUES ('user_settings', '{not json')") }
		#expect(try SettingsRepository(db).read() == nil)
	}
}

@Suite struct PromptOverrideStoreTests {
	@Test func segmentPathValidation() {
		for good in ["system-prompt.md", "teacher/20-teaching.md", "prober/10-probe-doctrine.md", "shared/10-personality.md"] {
			#expect(PromptOverrideRepository.isValidSegmentPath(good), "\(good)")
		}
		for bad in ["", "README.md", "teacher/README.md", "teacher/20-teaching.txt", "../system-prompt.md", "agent/../teacher/20-teaching.md",
			"/etc/passwd", "teacher", "teacher/", "teacher/sub/10-x.md", "prober\\10-x.md", "teacher/10-.md"] {
			#expect(!PromptOverrideRepository.isValidSegmentPath(bad), "\(bad)")
		}
	}

	@Test func listReadWriteDelete() throws {
		let repo = PromptOverrideRepository(try AppDatabase.inMemory())
		#expect(try repo.list() == [])
		try repo.write("teacher/20-teaching.md", body: "custom teaching")
		try repo.write("system-prompt.md", body: "custom base")
		#expect(try repo.list() == ["system-prompt.md", "teacher/20-teaching.md"])
		try repo.write("prober/30-probe-done.md", body: "custom probe-done")
		#expect(try repo.read("prober/30-probe-done.md") == "custom probe-done")
		try repo.delete("prober/30-probe-done.md")
		#expect(try repo.read("prober/30-probe-done.md") == nil)
		try repo.delete("prober/30-probe-done.md")
		try repo.write("../evil.md", body: "nope")
		#expect(try repo.list().count == 2)
	}
}

@Suite struct JobRepositoryTests {
	@Test func artifactsLiveInFilesNotRows() throws {
		let dir = try tempDir()
		let db = try AppDatabase.inMemory()
		let repo = JobRepository(db, dataDirectory: dir)
		let job = try repo.createJob(kind: .demo, chatId: "chat_x", toolCallId: "c1")
		#expect(job.status == .running && job.activity == "starting")
		try repo.updateJob(job.id, .init(status: .done, result: ["title": "T", "html": "<html>demo</html>", "tested": true]))
		let back = try #require(try repo.getJob(job.id))
		#expect(back.result?["html"] == nil)
		#expect(back.result?["artifactPath"]?.stringValue == "artifacts/\(job.id)/demo.html")
		#expect(try repo.artifactText(for: back.result!) == "<html>demo</html>")
		let row = try db.writer.read { db in try String.fetchOne(db, sql: "SELECT result_json FROM job") }
		#expect(row?.contains("demo</html>") == false)
		#expect(try repo.findJob(chatId: "chat_x", toolCallId: "c1")?.id == job.id)
		#expect(try repo.deleteJobs(chatId: "chat_x") == 1)
		#expect(!FileManager.default.fileExists(atPath: repo.artifactDirectory(job.id).path))
	}
}

@Suite struct KeychainTests {
	@Test func inMemoryRoundTrip() throws {
		let k = InMemoryKeychain()
		#expect(try k.anthropicKey() == nil)
		try k.setAnthropicKey("sk-ant-1")
		try k.setAnthropicKey("sk-ant-2")
		#expect(try k.anthropicKey() == "sk-ant-2")
		try k.deleteAnthropicKey()
		try k.deleteAnthropicKey()
		#expect(try k.anthropicKey() == nil)
	}
}

@Suite struct GraphRepositoryTests {
	@Test func ledgersKeepLinesVerbatimAndSkipCorruptOnRead() throws {
		let graph = GraphRepository(try AppDatabase.inMemory())
		let line = #"{"id":"n_1","name":"A","statement":"A.","aliases":[],"createdAt":"t","provenance":[{"chatId":"c","messageId":""}]}"#
		try graph.appendNodeLine(line, nodeId: "n_1")
		try graph.appendNodeLine("{broken", nodeId: "n_2")
		#expect(try graph.rawLines(.nodes) == [line, "{broken"])
		#expect(graph.readNodes().map(\.id) == ["n_1"])
		try graph.writePositions(["n_1": Position(x: 1.5, y: -2)])
		#expect(graph.readPositions() == ["n_1": Position(x: 1.5, y: -2)])
		try settleGraphLayout(graph)
		#expect(graph.readPositions().keys.sorted() == ["n_1"])
	}
}

@Suite struct JobDispatchStoreTests {
	@Test func getOrCreateIsOneJobPerToolCall() throws {
		let repo = JobRepository(try AppDatabase.inMemory(), dataDirectory: try tempDir())
		let (a, createdA) = try repo.getOrCreate(kind: .research, chatId: "chat_x", toolCallId: "c1")
		let (b, createdB) = try repo.getOrCreate(kind: .research, chatId: "chat_x", toolCallId: "c1")
		#expect(createdA && !createdB)
		#expect(a.id == b.id)
		#expect(throws: (any Error).self, "the v3 unique index") { try repo.createJob(kind: .research, chatId: "chat_x", toolCallId: "c1") }
		#expect(try repo.getOrCreate(kind: .pdf, chatId: "chat_y", toolCallId: "c1").created, "unique per chat")
		#expect(try repo.runningJobs().count == 2)
	}
}

@Suite struct GraphTransactionTests {
	@Test func aChatDeleteTakesItsCoverageAndCheckpoints() throws {
		let db = try AppDatabase.inMemory()
		let chat = try ChatRepository(db).createChat(title: "t")
		let graph = GraphRepository(db)
		try graph.appendCoverage(CoverageEntry(chatId: chat.id, fp: "f", tokens: 1, foldedAt: "x"))
		try graph.appendCheckpoint(SessionCheckpoint(chatId: chat.id, foldedAt: "x"))
		try graph.appendCoverage(CoverageEntry(chatId: "chat_other", fp: "g", tokens: 1, foldedAt: "x"))
		try ChatRepository(db).delete(chat.id)
		#expect(graph.readCoverage().map(\.chatId) == ["chat_other"])
		#expect(graph.readCheckpoints().isEmpty)
	}

	@Test func tracesAndTheChatDeleteAreAllOrNothing() throws {
		let db = try AppDatabase.inMemory()
		let chat = try ChatRepository(db).createChat(title: "t")
		let graph = GraphRepository(db)
		try graph.appendNode(GraphNode(id: "n_a", name: "A", statement: "S", aliases: [], createdAt: "", provenance: [ProvenancePoint(chatId: chat.id, messageId: "")]))
		struct Boom: Error {}
		#expect(throws: Boom.self) {
			try graph.transaction { tx in
				try deleteChatTraces(tx, chatId: chat.id, mode: .deleteNodes)
				throw Boom()
			}
		}
		#expect(graph.readNodes().count == 1, "rolled back")
		try graph.transaction { tx in
			try deleteChatTraces(tx, chatId: chat.id, mode: .deleteNodes)
			#expect(try tx.deleteChat(chat.id))
		}
		#expect(graph.readNodes().isEmpty)
		#expect(try ChatRepository(db).get(chat.id) == nil)
	}

	@Test func theRevisionTicksOnGraphWrites() async throws {
		let db = try AppDatabase.inMemory()
		let graph = GraphRepository(db)
		var it = graph.observeRevision().makeAsyncIterator()
		let first = try await it.next()
		try graph.appendNode(GraphNode(id: "n_a", name: "A", statement: "S", aliases: [], createdAt: "", provenance: []))
		let second = try await it.next()
		#expect(first != nil && second != nil && second != first)
	}
}
