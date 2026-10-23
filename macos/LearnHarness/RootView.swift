import SwiftUI

/// The app shell: sessions sidebar + detail. Empty until M4 wires the store.
struct RootView: View {
	var body: some View {
		NavigationSplitView {
			List {}
				.navigationSplitViewColumnWidth(min: 200, ideal: 260)
				.navigationTitle("LearnHarness")
		} detail: {
			ContentUnavailableView("No Session", systemImage: "graduationcap", description: Text("Sessions appear here."))
		}
	}
}

#Preview {
	RootView()
}
