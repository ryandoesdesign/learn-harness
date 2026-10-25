import Foundation
import LHCore
import LHResources
import LHStore
import Testing
@testable import Aster

// Questions show inline where they were asked; a teach check waits behind
// its "Check your understanding" bar until opened, a re-posed one comes back
// open. Paragraph notes ride on the next answer and stay under their paragraph.

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

	@Test func theQuestionIsARowAtItsCallAfterTheProse() throws {
		let s = try sessionWithQuestion(viewAtBottom: false)
		#expect(s.pending?.toolCallId == "q1")
		let last = try #require(s.rows.last)
		guard case .pendingQuestion(_, "q1", _) = last.kind else { Issue.record("the card ends the reply: \(last.kind)"); return }
		#expect(s.pendingRowId == last.id)
		#expect(!s.waitsForReveal(tool: "ask_user_question", toolCallId: "q1", input: ["question": "x"]), "a probe-phase question shows open")
	}

	@Test func aQuestionsMessageIsProseJustBeforeItsCard() throws {
		let s = try sessionWithQuestion(viewAtBottom: true)
		// Double-escaped, as Opus sometimes sends it: the two paragraphs still split.
		let input: JSONValue = ["message": "Good pick.\\n\\nNow the remaining forces.", "question": "Second?", "options": [["label": "A"], ["label": "B"]]]
		try ChatRepository(s.database).append([
			newAnswerResult(toolCallId: "q1", toolName: "ask_user_question", answer: dismissedAnswer(.ask, questionText: "Which join keeps every left row?"), now: 2),
			Message(id: "a2", timestamp: 3, body: .assistant(AssistantBody(content: [.toolUse(id: "q2", name: "ask_user_question", input: input)], model: "claude-opus-5-5", stopReason: "tool_use"))),
		], to: s.chatId)
		s.load()
		let tail = s.rows.suffix(3)
		let kinds = tail.map { row -> String in
			switch row.kind {
			case .textBlock: "prose"
			case .pendingQuestion(_, let id, _): "card \(id)"
			default: "other"
			}
		}
		#expect(kinds == ["prose", "prose", "card q2"])
		#expect(tail.first.map { s.takesNotes($0.id) } == true, "its paragraphs take notes")
	}

	@Test func siblingsEachGetARowAndNoneShowWhileRunning() throws {
		let s = try sessionWithQuestion(viewAtBottom: true)
		let input: JSONValue = ["question": "Second?", "options": [["label": "A"], ["label": "B"]]]
		try ChatRepository(s.database).append([
			Message(id: "a2", timestamp: 2, body: .assistant(AssistantBody(content: [.toolUse(id: "q2", name: "ask_user_question", input: input), .toolUse(id: "q3", name: "ask_user_question", input: input)], model: "claude-opus-5-5", stopReason: "tool_use"))),
		], to: s.chatId)
		s.load()
		let ids = s.rows.compactMap { if case .pendingQuestion(_, let id, _) = $0.kind { id } else { nil } }
		#expect(ids == ["q2", "q3"], "only the latest reply's calls are open")
		#expect(s.pendingAll.map(\.toolCallId) == ["q2", "q3"])
		s.running = true
		#expect(s.pendingAll.isEmpty, "a running turn shows no card")
	}

	@Test func aTeachCheckWaitsForItsRevealUntilOpened() throws {
		let s = try sessionWithQuestion(viewAtBottom: true)
		let quiz: JSONValue = ["question": "Which rows survive?", "options": [["label": "Matched"], ["label": "All"]], "correctAnswer": "Matched", "explanation": "Inner.", "nodeId": "n1"]
		try ChatRepository(s.database).append([
			newAnswerResult(toolCallId: "q1", toolName: "ask_user_question", answer: dismissedAnswer(.ask, questionText: "Which join keeps every left row?"), now: 2),
			Message(id: "d", timestamp: 2, body: .assistant(AssistantBody(content: [.toolUse(id: "d1", name: "probe_done", input: ["assessment": ["summary": "Ready."]])], model: "claude-opus-5-5", stopReason: "tool_use"))),
			Message(id: "dr", timestamp: 2, body: .toolResult(ToolResultBody(toolUseId: "d1", toolName: "probe_done", content: [Block(raw: ["type": "text", "text": "ok"])], isError: false))),
			Message(id: "h", timestamp: 2, body: .marker(MarkerBody(kind: .probeHandoff, content: HANDOFF_TEXT, display: true, details: [:]))),
			Message(id: "a3", timestamp: 3, body: .assistant(AssistantBody(content: [.text("Joins match rows."), .toolUse(id: "k1", name: "quiz", input: quiz)], model: "claude-opus-5-5", stopReason: "tool_use"))),
		], to: s.chatId)
		s.load()
		#expect(s.phase == .teach)
		#expect(s.waitsForReveal(tool: "quiz", toolCallId: "k1", input: quiz))
		s.revealedChecks.insert("k1")
		#expect(!s.waitsForReveal(tool: "quiz", toolCallId: "k1", input: quiz))
	}

	@Test func notesQuoteTheirParagraphInOrderAndClear() throws {
		let s = try sessionWithQuestion(viewAtBottom: true)
		let paragraphs = s.rows.filter { if case .textBlock = $0.kind { true } else { false } }
		let first = try #require(paragraphs.first)
		s.noteDrafts[first.id] = "  so prose is long  "
		s.noteDrafts["nowhere"] = "dropped: no such paragraph"
		let notes = s.takeReadingNotes()
		#expect(notes.map(\.anchor) == [first.id])
		#expect(notes.first?.text == "so prose is long")
		#expect(notes.first?.quote.hasSuffix("…") == true && notes.first?.quote.count == READING_QUOTE_LIMIT + 1, "the long paragraph is cut")
		#expect(s.noteDrafts.isEmpty)
	}

	@Test func sentNotesFindTheirParagraph() throws {
		let s = try sessionWithQuestion(viewAtBottom: true)
		let anchor = try #require(s.rows.first { if case .textBlock = $0.kind { true } else { false } }?.id)
		var a = QuestionAnswerData(kind: .ask, questionText: "Which join keeps every left row?", dontKnow: false, answers: [], answeredAt: "2026-10-25T00:00:00.000Z")
		a.readingNotes = [ReadingNote(anchor: anchor, quote: "Long prose.", text: "why so long?")]
		a.readingThinking = readingThinkingText(a.readingNotes!)
		try ChatRepository(s.database).append([newAnswerResult(toolCallId: "q1", toolName: "ask_user_question", answer: a, now: 2)], to: s.chatId)
		s.load()
		#expect(s.sentNotes[anchor] == ["why so long?"])
		#expect(s.pending == nil)
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
		#expect(s.revealedChecks.contains("rp1_q1"), "it picks up where you left it: open")
		#expect(s.discussedOrigin == nil)
	}
}
