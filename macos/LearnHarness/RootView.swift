import LHCore
import SwiftUI

/// The app shell: the sessions sidebar + the selected session.
struct RootView: View {
	@Bindable var model: AppModel

	var body: some View {
		NavigationSplitView {
			SidebarView(model: model, selection: $model.selection)
				.navigationSplitViewColumnWidth(min: 220, ideal: 288)
		} detail: {
			if let error = model.startupError {
				ContentUnavailableView("Something Went Wrong", systemImage: "exclamationmark.triangle", description: Text(error))
			} else if model.drafting {
				DraftView(model: model)
			} else if let session = model.session {
				SessionView(session: session)
					.id(session.chatId)
					.task(id: session.chatId) { await session.observe() }
			} else if model.sessions.isEmpty {
				ContentUnavailableView {
					Label("No Sessions", systemImage: "graduationcap")
				} description: {
					Text("Start one with File → New Session (⌘N), or import your sessions with File → Import from LearnHarness (Electron)…")
				} actions: {
					Button("New Session") { model.newSession() }
				}
			} else {
				ContentUnavailableView("No Session Selected", systemImage: "graduationcap", description: Text("Choose a session in the sidebar."))
			}
		}
		.sheet(isPresented: Binding(get: { model.importState != .idle }, set: { if !$0 { model.importState = .idle } })) {
			ImportSheet(model: model)
		}
	}
}
