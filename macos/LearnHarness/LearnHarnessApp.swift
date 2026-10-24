import LHStore
import SwiftUI

@main
struct LearnHarnessApp: App {
	@State private var model = Self.makeModel()

	private static func makeModel() -> AppModel {
		#if DEBUG
		// `-LHScratch YES`: a throwaway database in the container's temp
		// folder, so debug checks never touch the real library.
		if UserDefaults.standard.bool(forKey: "LHScratch") {
			let dir = FileManager.default.temporaryDirectory.appending(path: "lh-scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
			return AppModel(dataDirectory: dir)
		}
		#endif
		return AppModel()
	}

	var body: some Scene {
		WindowGroup {
			RootView(model: model)
				.task { await model.observeSessions() }
				.task { await model.observeService() }
				.task { await model.observeJobs() }
				.task { await model.observeExtraction() }
				#if DEBUG
				// `-LHOpenGallery YES` (with -LHScratch): open the Render Gallery.
				.task { if UserDefaults.standard.bool(forKey: "LHOpenGallery"), UserDefaults.standard.bool(forKey: "LHScratch") { model.addRenderGallery() } }
				#endif
		}
		.commands {
			CommandGroup(replacing: .newItem) {
				Button("New Session") { model.newSession() }.keyboardShortcut("n")
			}
			CommandGroup(after: .newItem) {
				Divider()
				ImportCommand(model: model)
				ExportCommand(model: model)
			}
			CommandGroup(after: .textEditing) {
				Divider()
				FindCommands()
				Divider()
				Button(model.dictation.isRecording ? "Stop Dictating" : "Dictate") { model.dictation.toggle() }
					.keyboardShortcut("d")
					.disabled(!model.dictation.available)
			}
			#if DEBUG
			CommandMenu("Debug") {
				PlaygroundCommand()
				Button("Add Render Gallery Session") { model.addRenderGallery() }
			}
			#endif
		}
		Settings {
			SettingsView(model: model)
		}
		// The knowledge graph (M7, your answer): its own window.
		Window("Knowledge Graph", id: "graph") {
			GraphWindow(app: model)
		}
		.keyboardShortcut("g", modifiers: [.command, .shift])
		.defaultSize(width: 1100, height: 760)
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
