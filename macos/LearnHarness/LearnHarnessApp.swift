import LHStore
import SwiftUI

@main
struct LearnHarnessApp: App {
	@State private var model = AppModel()

	var body: some Scene {
		WindowGroup {
			RootView(model: model)
				.task { await model.observeSessions() }
		}
		.commands {
			CommandGroup(after: .newItem) {
				Divider()
				ImportCommand(model: model)
			}
			#if DEBUG
			CommandMenu("Debug") { PlaygroundCommand() }
			#endif
		}
		#if DEBUG
		Window("Anthropic Playground", id: "playground") {
			PlaygroundView(model: playground)
		}
		#endif
	}

	#if DEBUG
	@State private var playground = PlaygroundModel(keychain: SystemKeychain())
	#endif
}

#if DEBUG
private struct PlaygroundCommand: View {
	@Environment(\.openWindow) private var openWindow
	var body: some View {
		Button("Anthropic Playground") { openWindow(id: "playground") }.keyboardShortcut("p", modifiers: [.command, .option])
	}
}
#endif
