import Foundation
import Testing
import LHAnthropic
import LHResources
@testable import LHAgent
@testable import LHCore
import LHStore

/// The M5 live acceptance (docs/native-macos-m5.md): opt-in only —
/// `LH_LIVE=1 ANTHROPIC_API_KEY=… swift test --filter LiveLesson`. A
/// scripted learner drives a real lesson through the TurnService on Sonnet
/// 5.5 at low effort: probe → probe_done → handoff → plan_init → a tagged
/// quiz → its answer → teaching continues. Never runs in CI.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LH_LIVE"] == "1"))
struct LiveLessonTests {
	@Test(.timeLimit(.minutes(10)))
	func aRealLessonGoesProbeToTeach() async throws {
		let key = try #require(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
		let db = try AppDatabase.inMemory()
		let catalog = try ModelCatalog(data: LHResources.modelsJSON)
		try SettingsRepository(db).update { s in s.models = ModelsSettings(strong: ModelSlot(model: "claude-sonnet-5-5", effort: .low)) }
		let service = TurnService(database: db, keychain: InMemoryKeychain(key: key), catalog: catalog)
		let chat = try ChatRepository(db).createChat(title: "SQL joins")
		let repo = ChatRepository(db)

		func runTurn(_ input: ChatInput) async throws {
			let events = await service.events()
			guard try await service.send(chat.id, input) == .started else { return }
			try await settles(events, chat.id, timeout: .seconds(240))
			// A handoff wake starts the teacher's turn right after the prober's.
			while await service.isRunning(chat.id) { try await Task.sleep(for: .milliseconds(200)) }
		}

		try await runTurn(.text("Teach me what an SQL inner join is. I already write basic SELECT queries with WHERE. Keep it short."))
		var answeredTagged = false
		for _ in 0..<14 {
			let record = try #require(try repo.get(chat.id))
			if answeredTagged, record.messages.last?.assistant != nil { break }
			guard let pending = danglingQuestionOf(record.messages) else {
				try await runTurn(.text("Sounds good — go ahead."))
				continue
			}
			let qd = try #require(dockQuestion(tool: pending.tool, toolCallId: pending.toolCallId, input: pending.input), "a posed question parses")
			let req: AnswerRequest = qd.mode == .text
				? AnswerRequest(text: "Rows from both tables are combined where the join condition matches; unmatched rows are dropped.")
				: AnswerRequest(values: [qd.options[0].value], thinking: "My best guess.", confidence: 70)
			let tagged = pending.input["nodeId"]?.stringValue?.isEmpty == false
			try await runTurn(.answer(toolCallId: pending.toolCallId, answer: buildAnswer(qd, req, tool: pending.tool)))
			if tagged { answeredTagged = true }
		}

		let r = try #require(try repo.get(chat.id))
		let calls = r.messages.compactMap(\.assistant).flatMap(\.toolUses).map(\.name)
		print("LIVE lesson calls:", calls)
		print("LIVE turns:", r.turns?.count ?? 0, "cache reads:", r.turns?.flatMap(\.steps).compactMap(\.cacheReadTokens).reduce(0, +) ?? 0)
		#expect(calls.contains("probe") || calls.contains("ask_user_question"), "the prober probed")
		#expect(calls.contains("probe_done"))
		#expect(r.messages.contains { $0.marker?.kind == .probeHandoff })
		#expect(calls.contains("plan_init"))
		#expect(r.tree?.nodes.isEmpty == false)
		#expect(r.messages.contains { $0.marker?.kind == .planBlock })
		#expect(answeredTagged, "a nodeId-tagged check was posed and answered")
		#expect(viewPhaseTimeline(projectView(r.messages)).last == .teach)
		#expect(!r.messages.contains { $0.assistant?.stopReason == "error" }, "\(r.messages.compactMap { $0.assistant?.errorMessage })")
		#expect((r.turns?.flatMap(\.steps).compactMap(\.cacheReadTokens).reduce(0, +) ?? 0) > 0, "later requests read the cache")
	}
}
