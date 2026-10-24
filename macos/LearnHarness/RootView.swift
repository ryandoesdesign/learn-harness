import LHCore
import SwiftUI

/// The app shell: the sessions sidebar + the selected session.
struct RootView: View {
	@Bindable var model: AppModel
	/// The sidebar's shown state survives relaunch (View → Show / Hide Sidebar).
	@AppStorage("lh.sidebarShown") private var sidebarShown = true

	var body: some View {
		NavigationSplitView(columnVisibility: Binding(get: { sidebarShown ? .all : .detailOnly }, set: { sidebarShown = $0 != .detailOnly })) {
			SidebarView(model: model, selection: $model.selection)
				.navigationSplitViewColumnWidth(min: 220, ideal: 288)
		} detail: {
			if let error = model.startupError {
				ContentUnavailableView("Something Went Wrong", systemImage: "exclamationmark.triangle", description: Text(error))
			} else if model.drafting {
				DraftView(model: model)
			} else if let session = model.session {
				SessionView(session: session)
					.environment(model)
					.id(session.chatId)
					.task(id: session.chatId) { await session.observe() }
			} else {
				HomeSummaryView(model: model)
			}
		}
		.environment(model.dictation)
		.sheet(isPresented: Binding(get: { model.importState != .idle }, set: { if !$0 { model.importState = .idle } })) {
			ImportSheet(model: model)
		}
	}
}
