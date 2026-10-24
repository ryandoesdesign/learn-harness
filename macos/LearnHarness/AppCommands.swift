import LHCore
import SwiftUI

/// Every app-level shortcut in one table (docs/native-macos-m8.md): the menus
/// read their keys from here, Help → Keyboard Shortcuts lists it, and a test
/// checks no two share a key. macOS lets you rebind any of them under System
/// Settings → Keyboard → App Shortcuts, by menu title.
enum AppShortcut: String, CaseIterable {
	case newSession, newPracticeSession, settings
	case find, findNext, findPrevious, searchSessions, dictate
	case toggleSidebar, toggleYourThinking
	case modelAndEffort, nextProblem
	case knowledgeGraph

	var title: String {
		switch self {
		case .newSession: "New Session"
		case .newPracticeSession: "New Practice Session"
		case .settings: "Settings…"
		case .find: "Find…"
		case .findNext: "Find Next"
		case .findPrevious: "Find Previous"
		case .searchSessions: "Search Sessions"
		case .dictate: "Dictate / Stop Dictating"
		case .toggleSidebar: "Show / Hide Sidebar"
		case .toggleYourThinking: "Expand / Collapse Your Thinking"
		case .modelAndEffort: "Model and Effort…"
		case .nextProblem: "Next Problem"
		case .knowledgeGraph: "Knowledge Graph"
		}
	}

	var menu: String {
		switch self {
		case .newSession, .newPracticeSession: "File"
		case .settings: "LearnHarness"
		case .find, .findNext, .findPrevious, .searchSessions, .dictate: "Edit"
		case .toggleSidebar, .toggleYourThinking: "View"
		case .modelAndEffort, .nextProblem: "Session"
		case .knowledgeGraph: "Window"
		}
	}

	var key: KeyEquivalent {
		switch self {
		case .newSession, .newPracticeSession: "n"
		case .settings: ","
		case .find: "f"
		case .findNext, .findPrevious, .knowledgeGraph: "g"
		case .searchSessions: "f"
		case .dictate: "d"
		case .toggleSidebar: "s"
		case .toggleYourThinking: "t"
		case .modelAndEffort: "k"
		case .nextProblem: .return
		}
	}

	var modifiers: EventModifiers {
		switch self {
		case .newPracticeSession, .findPrevious, .searchSessions: [.command, .shift]
		case .toggleSidebar: [.command, .control]
		case .knowledgeGraph: [.command, .option]
		default: .command
		}
	}

	var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

	/// "⇧⌘N" — the menu bar's own spelling.
	var label: String {
		var s = ""
		if modifiers.contains(.control) { s += "⌃" }
		if modifiers.contains(.option) { s += "⌥" }
		if modifiers.contains(.shift) { s += "⇧" }
		if modifiers.contains(.command) { s += "⌘" }
		return s + (key == .return ? "↩" : String(key.character).uppercased())
	}
}

/// The question dock's and composer's own keys (not menu items; listed in Help).
let DOCK_KEYS: [(keys: String, action: String)] = [
	("↑ / ↓", "Question · walk the options"),
	("Space", "Question · pick the walked option"),
	("← / →", "Question · confidence"),
	("↩", "Submit (the question, your thinking, the composer)"),
	("⇧↩", "A new line"),
	("Esc", "Discard dictation · close Find or an overlay · dismiss the question or problem · stop the turn"),
]

extension View {
	func keyboardShortcut(_ s: AppShortcut) -> some View { keyboardShortcut(s.key, modifiers: s.modifiers) }
}

/// The app's menus (M8): File, Edit, View, Session, Window and Help additions.
struct AppCommands: Commands {
	let model: AppModel

	var body: some Commands {
		CommandGroup(replacing: .newItem) {
			Button(AppShortcut.newSession.title) { model.newSession() }.keyboardShortcut(.newSession)
			Button(AppShortcut.newPracticeSession.title) { model.newSession(kind: .practice) }.keyboardShortcut(.newPracticeSession)
		}
		CommandGroup(after: .newItem) {
			Divider()
			ImportCommand(model: model)
			ExportCommand(model: model)
		}
		CommandGroup(after: .textEditing) {
			Divider()
			FindCommands()
			Button(AppShortcut.searchSessions.title) { model.searchRequest += 1 }.keyboardShortcut(.searchSessions)
			Divider()
			Button(model.dictation.isRecording ? "Stop Dictating" : "Dictate") { model.dictation.toggle() }
				.keyboardShortcut(.dictate)
				.disabled(!model.dictation.available)
		}
		SidebarCommands()
		CommandGroup(after: .sidebar) {
			ThinkingCommand()
		}
		CommandMenu("Session") {
			SessionCommands(model: model)
		}
		CommandGroup(replacing: .help) {
			HelpCommands()
		}
	}
}

private struct ThinkingCommand: View {
	@FocusedValue(\.session) private var session
	var body: some View {
		Button(AppShortcut.toggleYourThinking.title) { session?.toggleAllUserThinking() }
			.keyboardShortcut(.toggleYourThinking)
			.disabled(session == nil)
	}
}

private struct SessionCommands: View {
	let model: AppModel
	@FocusedValue(\.session) private var session

	var body: some View {
		Button("Rename…") { session.map { model.renameRequest = $0.chatId } }
			.disabled(session == nil)
		Button(AppShortcut.modelAndEffort.title) { session?.overlays.modelPickerOpen = true }
			.keyboardShortcut(.modelAndEffort)
			.disabled(session?.service == nil)
		Divider()
		Button(AppShortcut.nextProblem.title) { session?.requestNext() }
			.keyboardShortcut(.nextProblem)
			.disabled(!(session?.nextReady ?? false))
	}
}

private struct HelpCommands: View {
	@Environment(\.openWindow) private var openWindow
	var body: some View {
		Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
	}
}

/// Help → Keyboard Shortcuts: the table above, by menu, then the dock's keys.
struct ShortcutsView: View {
	var body: some View {
		let menus = ["File", "Edit", "View", "Session", "Window", "LearnHarness"]
		List {
			ForEach(menus, id: \.self) { menu in
				Section(menu) {
					ForEach(AppShortcut.allCases.filter { $0.menu == menu }, id: \.self) { s in
						row(s.title, s.label)
					}
				}
			}
			Section("In a session") {
				ForEach(DOCK_KEYS, id: \.action) { row($0.action, $0.keys) }
			}
			Section {
				Text("Change any menu shortcut in System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts.")
					.font(Theme.ui).foregroundStyle(Theme.muted)
			}
		}
		.frame(minWidth: 460, minHeight: 520)
	}

	private func row(_ title: String, _ keys: String) -> some View {
		HStack {
			Text(title)
			Spacer()
			Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(Theme.muted)
		}
	}
}
