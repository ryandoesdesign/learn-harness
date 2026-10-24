import LHCore
import LHStore
import SwiftUI

/// The main window with no session selected (minimal-home.tsx
/// KnowledgeSummary): the quiet counts, each on its own line, then the ways
/// in — New Session, New Practice Session, Knowledge Graph, Import Notes.
struct HomeSummaryView: View {
	let model: AppModel
	@Environment(\.openWindow) private var openWindow
	@State private var counts = Counts()

	struct Counts: Equatable {
		var propositions = 0, chains = 0, notes = 0
	}

	var body: some View {
		let teach = model.sessions.filter { $0.kind != .practice }.count
		let practice = model.sessions.count - teach
		VStack(spacing: 20) {
			VStack(spacing: 2) {
				if counts == Counts(), model.sessions.isEmpty {
					Text("Nothing here yet — import notes to begin building the graph.")
				} else {
					Text(plural(counts.propositions, "proposition"))
					Text(plural(counts.chains, "chain"))
					Text(" ")
					Text(plural(teach, "teaching session"))
					Text(plural(practice, "practice session"))
					Text(" ")
					Text(plural(counts.notes, "imported note"))
				}
			}
			.font(Theme.small)
			.foregroundStyle(Theme.muted)
			HStack(spacing: 10) {
				Button("New Session") { model.newSession() }
				Button("New Practice Session") { model.newSession(kind: .practice) }
				Button("Knowledge Graph") { openWindow(id: "graph") }
				Button("Import Notes…") { Task { _ = await model.importNotes() } }
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.task {
			do {
				for try await _ in GraphRepository(model.database).observeRevision() { reload() }
			} catch {}
		}
		.onAppear(perform: reload)
	}

	private func reload() {
		let snap = graphSnapshot(GraphDeps(chatStore: ChatRepository(model.database), graphStore: GraphRepository(model.database)))
		counts = Counts(propositions: snap.propositions.count, chains: snap.chains.count, notes: snap.fileSources.count)
	}

	private func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
