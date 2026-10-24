import Foundation
import LHCore
import LHResources
import LHStore
import SwiftUI
import Testing
@testable import Aster

// The menu map (docs/native-macos-m8.md): one table drives the menus and
// Help → Keyboard Shortcuts; no two items share a key, none takes a
// standard macOS shortcut, and the M7 clash (⇧⌘G opened both Find Previous
// and the graph) is gone.

@MainActor
@Suite struct ShortcutTests {
	private func combo(_ s: AppShortcut) -> String { s.label }

	@Test func noTwoItemsShareAKey() {
		let labels = AppShortcut.allCases.map(combo)
		#expect(Set(labels).count == labels.count, "\(Dictionary(grouping: AppShortcut.allCases, by: combo).filter { $0.value.count > 1 })")
	}

	@Test func noneTakesAStandardMacShortcut() {
		let standard: Set<String> = ["⌘Q", "⌘W", "⌘H", "⌘M", "⌘C", "⌘V", "⌘X", "⌘A", "⌘Z", "⇧⌘Z", "⌘O", "⌘S", "⌘P", "⌘E", "⌘J", "⌥⌘H", "⌃⌘F", "⌘`", "⌘?"]
		let ours = Set(AppShortcut.allCases.filter { $0 != .settings }.map(combo))
		#expect(ours.isDisjoint(with: standard), "\(ours.intersection(standard))")
	}

	@Test func theMapIsTheDesignedOne() {
		#expect(AppShortcut.newPracticeSession.label == "⇧⌘N")
		#expect(AppShortcut.findPrevious.label == "⇧⌘G")
		#expect(AppShortcut.knowledgeGraph.label == "⌥⌘G", "the graph moved off ⇧⌘G")
		#expect(AppShortcut.dictate.label == "⌘D")
		#expect(AppShortcut.toggleYourThinking.label == "⌘T")
		#expect(AppShortcut.modelAndEffort.label == "⌘K")
		#expect(AppShortcut.nextProblem.label == "⌘↩")
		#expect(AppShortcut.toggleSidebar.label == "⌃⌘S")
	}
}

@MainActor
@Suite struct ToggleYourThinkingTests {
	@Test func theFirstPressCollapsesEveryRowAndTheNextReopensThem() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhtt-\(UUID().uuidString)", directoryHint: .isDirectory)
		let db = try AppDatabase.open(directory: dir)
		let chat = try ChatRepository(db).createChat(title: "T", kind: .practice)
		try ChatRepository(db).append([
			newUserMessage("go", now: 0),
			newThinkingMessage(problemCallId: "p1", text: "first idea", id: "t1", now: 1),
			newThinkingMessage(problemCallId: "p1", text: "second idea", id: "t2", now: 2),
		], to: chat.id)
		let s = SessionModel(chatId: chat.id, database: db, dataDirectory: dir, catalog: try ModelCatalog(data: LHResources.modelsJSON))
		s.load()
		let ids = s.rows.filter { if case .practiceThinking = $0.kind { true } else { false } }.map(\.id)
		#expect(ids.count == 2)
		#expect(ids.allSatisfy { s.isOpen($0, default: true) }, "transcript rows start open")
		s.toggleAllUserThinking()
		#expect(ids.allSatisfy { !s.isOpen($0, default: true) })
		s.setOpen(ids[0], true)
		s.toggleAllUserThinking()
		#expect(ids.allSatisfy { s.isOpen($0, default: true) }, "an explicit set stomps the individual toggle")
		#expect(s.allUserThinkingOpen == true)
	}
}
