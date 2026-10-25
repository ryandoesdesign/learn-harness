import Foundation
import LHCore
import LHResources
import LHStore
import Testing
@testable import Aster

// A new question arrives open only when the view is really at the bottom
// (your rule, 2026-10-24). Following is sticky — content growing past the
// window never clears `isAtBottom` — so arrival reads `viewAtBottom`.

@MainActor
@Suite struct QuestionArrivalTests {
	private func sessionWithQuestion(viewAtBottom: Bool) throws -> SessionModel {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhqa-\(UUID().uuidString)", directoryHint: .isDirectory)
		let db = try AppDatabase.open(directory: dir)
		let chat = try ChatRepository(db).createChat(title: "Q")
		let input: JSONValue = ["question": "Which join keeps every left row?", "options": [["label": "Left"], ["label": "Inner"]]]
		try ChatRepository(db).append([
			newUserMessage("Teach me joins", now: 0),
			Message(id: "a1", timestamp: 1, body: .assistant(AssistantBody(content: [.text(String(repeating: "Long prose. ", count: 400)), .toolUse(id: "q1", name: "ask_user_question", input: input)], model: "claude-opus-5-5", stopReason: "tool_use"))),
		], to: chat.id)
		let s = SessionModel(chatId: chat.id, database: db, dataDirectory: dir, catalog: try ModelCatalog(data: LHResources.modelsJSON))
		s.isAtBottom = true // following stayed on while the prose grew
		s.viewAtBottom = viewAtBottom
		s.load()
		return s
	}

	@Test func readingAboveTheBottomFoldsTheNewQuestion() throws {
		let s = try sessionWithQuestion(viewAtBottom: false)
		#expect(s.pending?.toolCallId == "q1")
		#expect(!s.dockExpanded, "you're still reading: the question waits folded")
	}

	@Test func atTheBottomTheQuestionOpens() throws {
		let s = try sessionWithQuestion(viewAtBottom: true)
		#expect(s.dockExpanded)
	}

	@Test func withAQuestionOpenTheComposerAsksAboutIt() throws {
		let s = try sessionWithQuestion(viewAtBottom: true)
		s.draft = "What's a left row?"
		#expect(s.pending != nil && s.canSend, "the composer sends while the question is open")
	}

	@Test func aReposedQuestionArrivesOpenEvenWhileReadingAbove() throws {
		let s = try sessionWithQuestion(viewAtBottom: false)
		let record = try #require(s.record)
		var appends = try inputAppends(record.messages, kind: nil, .discuss(toolCallId: "q1", text: "What's a left row?"), now: 2)
		appends.append(Message(id: "a2", timestamp: 3, body: .assistant(AssistantBody(content: [.text("The table named first.")], model: "claude-opus-5-5", stopReason: "stop"))))
		appends += reposeAppends(record.messages + appends, now: 4)
		try ChatRepository(s.database).append(appends, to: s.chatId)
		s.discussedOrigin = "q1"
		s.load()
		#expect(s.pending?.toolCallId == "rp1_q1")
		#expect(s.dockExpanded && s.revealed, "it picks up where you left it")
		#expect(s.discussedOrigin == nil)
	}
}
