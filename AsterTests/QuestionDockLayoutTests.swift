import AppKit
import Foundation
import LHCore
import LHResources
import LHStore
import SwiftUI
import Testing
@testable import Aster

// The expanded question hugs its contents: a short question doesn't stretch
// to the scroll area's cap, and a long one stops at it and scrolls.

@MainActor
private final class HeightBox { var height: CGFloat = 0 }

@MainActor
@Suite struct QuestionDockLayoutTests {
	private func height(question: String, options: Int) async throws -> CGFloat {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhqd-\(UUID().uuidString)", directoryHint: .isDirectory)
		let db = try AppDatabase.open(directory: dir)
		let chat = try ChatRepository(db).createChat(title: "Q")
		let session = SessionModel(chatId: chat.id, database: db, dataDirectory: dir, catalog: try ModelCatalog(data: LHResources.modelsJSON))
		let input: JSONValue = ["question": .string(question), "options": .array((0..<options).map { ["label": .string("Option \($0)")] })]
		#expect(dockQuestion(tool: "ask_user", toolCallId: "c1", input: input) != nil)
		// Hosted the way the app hosts it: the dock as the transcript's bottom
		// inset, offered the whole window's height.
		let box = HeightBox()
		let view = Color.clear
			.safeAreaInset(edge: .bottom, spacing: 0) {
				QuestionDockView(session: session, tool: "ask_user", toolCallId: "c1", input: input)
					.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.height = $0 }
			}
			.environment(session.find)
			.frame(width: 600, height: 1200)
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = NSHostingView(rootView: view)
		window.orderFrontRegardless()
		defer { window.orderOut(nil) }
		try await Task.sleep(for: .milliseconds(400))
		return box.height
	}

	@Test func aShortQuestionHugsItsContents() async throws {
		let h = try await height(question: "Which join keeps every left row?", options: 2)
		// The "Ask about it" row adds ~40pt to every card.
		#expect(h < 340, "two options, a line of question, Other and Ask about it: \(h)")
	}

	@Test func aLongQuestionStopsAtTheCap() async throws {
		let h = try await height(question: "Pick one.", options: 30)
		#expect(h > QuestionDockView.maxBody, "\(h)")
		#expect(h < QuestionDockView.maxBody + 220, "the body scrolls past the cap: \(h)")
	}
}
