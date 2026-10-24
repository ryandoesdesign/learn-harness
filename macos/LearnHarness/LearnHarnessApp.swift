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
		}
	}
}
