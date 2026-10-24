import Foundation
import Testing
import LHAnthropic
import LHResources
@testable import LHAgent
@testable import LHCore
import LHStore

/// The M7 live acceptance (docs/native-macos-m7.md): opt-in only —
/// `LH_LIVE=1 ANTHROPIC_API_KEY=… swift test --filter LiveExtraction`, on
/// Haiku 5.5 at low effort. A lesson over the threshold extracts and merges
/// (the graph revision moves); a notes file imports; the prober's
/// list_sessions then sees both sources.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LH_LIVE"] == "1"), .serialized)
struct LiveExtractionTests {
	@Test(.timeLimit(.minutes(8)))
	func aLessonAndANotesFileReachTheGraph() async throws {
		let key = try #require(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
		let db = try AppDatabase.inMemory()
		let catalog = try ModelCatalog(data: LHResources.modelsJSON)
		let haiku = ModelSlot(model: "claude-haiku-5-5", effort: .low)
		try SettingsRepository(db).update { s in
			s.models = ModelsSettings(strong: haiku, cheap: haiku, vision: haiku)
			s.graph = GraphSettings(extractionChunkTokens: 500)
		}
		let service = ExtractionService(database: db, keychain: InMemoryKeychain(key: key), catalog: catalog)
		let chat = try ChatRepository(db).createChat(title: "SQL joins")
		let prose = """
			An inner join returns only the rows whose join keys match in both tables. A left outer join keeps every row of the left table \
			and fills the right table's columns with NULL where no match exists. Because NULL is not equal to anything — not even NULL — \
			a join condition on a nullable key silently drops rows whose key is NULL. That is why filtering on a right-table column in the \
			WHERE clause of a left join turns it back into an inner join: the NULL-filled rows fail the predicate. Put such filters in the \
			ON clause instead, where they restrict the match rather than the result.
			"""
		try ChatRepository(db).append([
			newUserMessage("Teach me SQL joins.", now: 0),
			Message(id: "t1", timestamp: 1, body: .assistant(AssistantBody(content: [.text(String(repeating: prose + "\n\n", count: 2))], model: "claude-haiku-5-5", stopReason: "end_turn"))),
		], to: chat.id)
		var revisions = GraphRepository(db).observeRevision().makeAsyncIterator()
		let first = try await revisions.next()

		await service.turnSettled(chat.id)
		#expect(await service.isRunning(chat.id), "over the threshold: the turn trigger starts it")
		while await service.isRunning(chat.id) { try await Task.sleep(for: .milliseconds(250)) }
		let nodes = getGraph(GraphRepository(db)).nodes
		print("LIVE lesson nodes:", nodes.map(\.name))
		#expect(!nodes.isEmpty)
		#expect(nodes.allSatisfy { $0.provenance.contains { $0.chatId == chat.id && $0.messageId == "t1" } })
		#expect(try await revisions.next() != first, "the graph revision moved")
		let run = try #require(try ChatRepository(db).get(chat.id)?.extractions?.first)
		print("LIVE run:", run.stats ?? EmissionStats(nodes: 0), "cost:", graphCostSummary(CostSummaryInput(chats: [.init(title: "t", extractions: [run])], sources: []), catalog: catalog).totalDollars)

		let results = await service.importNotes([.init(path: "/notes/normal-forms.md", text: "# Normal forms\n\nThird normal form removes transitive dependencies: every non-key attribute depends on the key, the whole key, and nothing but the key.")])
		#expect(results.map(\.outcome) == [.completed], "\(results)")

		let listing = try await proberGraphTools(GraphToolDeps { GraphDeps(chatStore: ChatRepository(db), graphStore: GraphRepository(db)) })[0]
			.execute([:], context: ToolContext(toolCallId: "c"))
		let text = listing.content.first?.raw["text"]?.stringValue ?? ""
		print("LIVE list_sessions:\n" + text)
		#expect(text.contains("SQL joins (chat,") && text.contains("/notes/normal-forms.md (file,"))
	}
}
