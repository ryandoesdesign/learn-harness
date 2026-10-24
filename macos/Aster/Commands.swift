import SwiftUI

/// The focused session, for menu commands.
struct SessionFocusKey: FocusedValueKey {
	typealias Value = SessionModel
}

extension FocusedValues {
	var session: SessionModel? {
		get { self[SessionFocusKey.self] }
		set { self[SessionFocusKey.self] = newValue }
	}
}

/// Edit → Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G): the session
/// Find bar. A second ⌘F re-selects the query.
struct FindCommands: View {
	@FocusedValue(\.session) private var session

	var body: some View {
		Button("Find…") { session?.find.open() }
			.keyboardShortcut(.find)
			.disabled(session == nil)
		Button("Find Next") { session.map { open($0); $0.find.step(1) } }
			.keyboardShortcut(.findNext)
			.disabled(session == nil)
		Button("Find Previous") { session.map { open($0); $0.find.step(-1) } }
			.keyboardShortcut(.findPrevious)
			.disabled(session == nil)
	}

	private func open(_ s: SessionModel) {
		if !s.find.isOpen { s.find.open() }
	}
}

/// File → Export as Markdown… for the open session.
struct ExportCommand: View {
	let model: AppModel
	@FocusedValue(\.session) private var session

	var body: some View {
		Button("Export as Markdown…") { session.map { model.exportMarkdown(chatId: $0.chatId) } }
			.disabled(session == nil)
	}
}
