import LHCore
import SwiftUI

/// The app shell: sessions sidebar + detail. M2 lists sessions by title;
/// transcripts render in M4.
struct RootView: View {
	@Bindable var model: AppModel
	@State private var selection: String?

	var body: some View {
		NavigationSplitView {
			List(model.sessions, id: \.id, selection: $selection) { session in
				Text(session.title).lineLimit(2)
			}
			.navigationSplitViewColumnWidth(min: 200, ideal: 260)
			.navigationTitle("LearnHarness")
		} detail: {
			if let error = model.startupError {
				ContentUnavailableView("Something Went Wrong", systemImage: "exclamationmark.triangle", description: Text(error))
			} else if model.sessions.isEmpty {
				ContentUnavailableView("No Sessions", systemImage: "graduationcap",
					description: Text("Import your sessions with File → Import from LearnHarness (Electron)…"))
			} else {
				ContentUnavailableView("No Session Selected", systemImage: "graduationcap", description: Text("Sessions appear here."))
			}
		}
		.sheet(isPresented: Binding(get: { model.importState != .idle }, set: { if !$0 { model.importState = .idle } })) {
			ImportSheet(model: model)
		}
	}
}
