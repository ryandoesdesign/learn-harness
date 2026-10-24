import Foundation
import Testing
import LHAnthropic
import LHResources
@testable import LHAgent
@testable import LHCore
import LHStore

/// The M8 live acceptance (docs/native-macos-m8.md): opt-in only —
/// `LH_LIVE=1 ANTHROPIC_API_KEY=… swift test --filter LivePractice`, on
/// Haiku 5.5 at low effort. A practice cycle: pose → the learner's
/// thinking → conclude → Next → pose again. Never runs in CI.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LH_LIVE"] == "1"))
struct LivePracticeTests {
	@Test(.timeLimit(.minutes(8)))
	func aPracticeCyclePosesConcludesAndPosesAgain() async throws {
		let key = try #require(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
		let db = try AppDatabase.inMemory()
		let catalog = try ModelCatalog(data: LHResources.modelsJSON)
		try SettingsRepository(db).update { s in s.models = ModelsSettings(strong: ModelSlot(model: "claude-haiku-5-5", effort: .low)) }
		let service = TurnService(database: db, keychain: InMemoryKeychain(key: key), catalog: catalog)
		let chat = try ChatRepository(db).createChat(title: "SQL joins", kind: .practice)
		let repo = ChatRepository(db)

		func runTurn(_ input: ChatInput) async throws {
			let events = await service.events()
			guard try await service.send(chat.id, input) == .started else { return }
			try await settles(events, chat.id, timeout: .seconds(240))
		}

		try await runTurn(.text("Give me one short practice problem on SQL LEFT JOIN. I know basic SELECT and WHERE."))
		let opening = try #require(try repo.get(chat.id))
		let first = try #require(activeProblemOf(opening.messages), "the opening turn poses")
		// Up to three thinking rounds until the agent concludes.
		for attempt in 0..<3 {
			let now = try #require(try repo.get(chat.id))
			guard activeProblemOf(now.messages) != nil else { break }
			let text = attempt == 0
				? "SELECT * FROM a LEFT JOIN b ON a.id = b.a_id — every row of a stays, b's columns are NULL where nothing matches. That's my final answer."
				: "That's all I have — please conclude."
			try await runTurn(.thinking(problemCallId: first.toolCallId, text: text))
		}
		var r = try #require(try repo.get(chat.id))
		#expect(activeProblemOf(r.messages) == nil, "concluded")
		try await runTurn(.next)
		r = try #require(try repo.get(chat.id))
		let calls = r.messages.compactMap(\.assistant).flatMap(\.toolUses).map(\.name)
		print("LIVE practice calls:", calls)
		#expect(calls.filter { $0 == "problem" }.count >= 2, "a second problem after Next")
		#expect(calls.contains("conclude"))
		#expect(r.turns?.isEmpty == false, "usage recorded")
	}
}
