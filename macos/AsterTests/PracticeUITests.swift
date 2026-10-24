import AppKit
import Foundation
import LHCore
import LHResources
import LHStore
import SwiftUI
import Testing
@testable import Aster

// Practice in the host (docs/native-macos-m8.md): when the practice dock
// replaces the composer, when Next Problem is ready (only after a clean
// pose), Enter's routing, the draft's Teach / Practice switch, and the dock
// hugging a short problem.

private let poseInput: JSONValue = ["statement": "Join `a` and `b` keeping every row of `a`.", "mode": "recall", "modelSolution": "LEFT JOIN"]

private func posed(_ id: String, error: Bool = false) -> [Message] {
	[
		Message(id: "a_\(id)", timestamp: 1, body: .assistant(AssistantBody(content: [.toolUse(id: id, name: "problem", input: poseInput)], model: "claude-opus-5-5", stopReason: "tool_use"))),
		Message(id: "r_\(id)", timestamp: 2, body: .toolResult(ToolResultBody(toolUseId: id, toolName: "problem", content: [.text(error ? "Invalid" : "Problem posed")], isError: error, details: nil))),
	]
}

private func concluded(_ id: String) -> [Message] {
	[
		Message(id: "a_\(id)", timestamp: 3, body: .assistant(AssistantBody(content: [.toolUse(id: id, name: "conclude", input: ["outcome": "solved", "verdict": "Yes.", "rung": .null, "missClass": .null, "retest": false])], model: "claude-opus-5-5", stopReason: "tool_use"))),
		Message(id: "r_\(id)", timestamp: 4, body: .toolResult(ToolResultBody(toolUseId: id, toolName: "conclude", content: [.text(CONCLUDE_ACK_TEXT)], isError: false, details: nil))),
	]
}

@MainActor
@Suite(.serialized) struct PracticeUITests {
	private func session(_ messages: [Message], kind: ChatKind? = .practice) throws -> SessionModel {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhpr-\(UUID().uuidString)", directoryHint: .isDirectory)
		let db = try AppDatabase.open(directory: dir)
		let chat = try ChatRepository(db).createChat(title: "Joins", kind: kind)
		try ChatRepository(db).append([newUserMessage("Practise joins", now: 0)] + messages, to: chat.id)
		let s = SessionModel(chatId: chat.id, database: db, dataDirectory: dir, catalog: try ModelCatalog(data: LHResources.modelsJSON))
		s.load()
		return s
	}

	@Test func anActiveProblemTakesTheDockAndNextWaits() throws {
		let s = try session(posed("p1"))
		#expect(s.activeProblem?.toolCallId == "p1")
		#expect(s.activeProblem?.statement.contains("every row") == true)
		#expect(!s.nextReady)
	}

	@Test func nextIsReadyOnlyAfterACleanPoseIsConcluded() throws {
		#expect(try session(posed("p1") + concluded("c1")).nextReady)
		#expect(try !session(posed("p1", error: true)).nextReady, "a refused pose never readies Next (TS did)")
		#expect(try !session([]).nextReady, "nothing posed yet")
		#expect(try !session(posed("p1") + concluded("c1"), kind: nil).nextReady, "a teaching session has no Next")
		#expect(try session(posed("p1"), kind: nil).activeProblem == nil)
	}

	@Test func enterOnAnEmptyComposerAsksForTheNextProblem() {
		#expect(enterAction(busy: false, canSend: false, nextProblem: true) == .next)
		#expect(enterAction(busy: false, canSend: true, nextProblem: true) == .send, "typed text sends")
		#expect(enterAction(busy: true, canSend: false, nextProblem: true) == .stop)
	}

	@Test func theDraftsPracticeModeCreatesAPracticeChatWithItsPicks() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhpd-\(UUID().uuidString)", directoryHint: .isDirectory)
		let app = AppModel(dataDirectory: dir, keychain: InMemoryKeychain())
		app.newSession(kind: .practice)
		#expect(app.drafting && app.draftKind == .practice)
		app.draftPicks = [GraphContextPick(id: "n_a", name: "Inner join", statement: "Matching rows only.")]
		app.beginSession(prompt: "Drill me on joins")
		let id = try #require(app.selection)
		let record = try #require(try ChatRepository(app.database).get(id))
		#expect(record.kind == .practice)
		#expect(record.messages.first?.marker?.kind == .graphContext)
		app.newSession()
		#expect(app.draftKind == nil, "⌘N opens a teaching draft")
	}

	@Test func theDockHugsAShortProblem() async throws {
		let s = try session(posed("p1"))
		let problem = try #require(s.activeProblem)
		final class Box { var height: CGFloat = 0 }
		let box = Box()
		let view = Color.clear
			.safeAreaInset(edge: .bottom, spacing: 0) {
				PracticeDockView(session: s, problem: problem)
					.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.height = $0 }
			}
			.environment(s.find)
			.frame(width: 600, height: 1200)
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = NSHostingView(rootView: view)
		window.orderFrontRegardless()
		defer { window.orderOut(nil) }
		try await Task.sleep(for: .milliseconds(400))
		#expect(box.height > 100 && box.height < PracticeDockView.maxBody, "a one-line problem hugs: \(box.height)")
		s.problemDockExpanded = false
		try await Task.sleep(for: .milliseconds(300))
		#expect(box.height < 60, "folded to a bar: \(box.height)")
	}
}

@MainActor
@Suite struct FirstRunKeyTests {
	@Test func startingWithoutAKeyAsksForOneAndCreatesNothing() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhkey-\(UUID().uuidString)", directoryHint: .isDirectory)
		let app = AppModel(dataDirectory: dir, keychain: InMemoryKeychain())
		app.newSession()
		#expect(!app.startSession(prompt: "Teach me joins"))
		#expect(app.keyPromptOpen)
		#expect(try ChatRepository(app.database).listChats().isEmpty, "no orphan chat (TS created it first)")
		#expect(app.drafting && app.selection == nil)
	}
}
