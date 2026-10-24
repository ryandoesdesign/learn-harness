import LHCore
import SwiftUI

/// The session filter (sidebar.tsx SessionKindFilter): Teaching / Practice / All.
enum SessionKindFilter: String, CaseIterable {
	case teach, practice, all
	var label: String {
		switch self {
		case .teach: "Teaching"
		case .practice: "Practice"
		case .all: "All"
		}
	}
}

/// The sessions sidebar (sidebar.tsx), read-only in M4: fuzzy search,
/// kind filter, rows with their state-aware meta, Export as Markdown….
struct SidebarView: View {
	var model: AppModel
	@Binding var selection: String?
	@AppStorage("lh.sessionKindFilter") private var filter: SessionKindFilter = .all
	@State private var query = ""
	@FocusState private var searchFocused: Bool

	var body: some View {
		let shown = filteredSessions(model.sessions, query: query, filter: filter)
		VStack(spacing: 8) {
			TextField("Search…", text: $query)
				.textFieldStyle(.roundedBorder)
				.focused($searchFocused)
				.onKeyPress(.downArrow) { walk(shown, 1); return .handled }
				.onKeyPress(.upArrow) { walk(shown, -1); return .handled }
				.onKeyPress(.escape) { searchFocused = false; return .handled }
				.onSubmit {
					if selection == nil || !shown.contains(where: { $0.id == selection }) { selection = shown.first?.id }
					searchFocused = false
				}
			Picker("Sessions", selection: $filter) {
				ForEach(SessionKindFilter.allCases, id: \.self) { Text($0.label).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			List(selection: $selection) {
				Section("Sessions") {
					if model.sessions.isEmpty {
						Text("No sessions yet.").foregroundStyle(Theme.muted)
					} else if shown.isEmpty {
						Text("No sessions match.").foregroundStyle(Theme.muted)
					}
					ForEach(shown, id: \.id) { s in
						SessionRow(summary: s)
							.tag(s.id)
							.contextMenu {
								Button("Export as Markdown…") { model.exportMarkdown(chatId: s.id) }
							}
					}
				}
			}
			.listStyle(.sidebar)
		}
		.padding(.top, 8)
		.padding(.horizontal, 8)
		.background {
			Button("") { searchFocused = true }
				.keyboardShortcut("f", modifiers: [.command, .shift])
				.hidden()
		}
	}

	/// ↑/↓ walk the shown rows with wrap.
	private func walk(_ shown: [ChatSummary], _ step: Int) {
		guard !shown.isEmpty else { return }
		let i = shown.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : shown.count)
		selection = shown[((i + step) % shown.count + shown.count) % shown.count].id
	}
}

/// Filter by kind, then fuzzy-rank by title (empty query keeps the natural
/// order; ties keep it too — the sort is stable).
func filteredSessions(_ sessions: [ChatSummary], query: String, filter: SessionKindFilter) -> [ChatSummary] {
	var list = sessions
	if filter != .all { list = list.filter { $0.kind.rawValue == filter.rawValue } }
	let q = query.trimmingCharacters(in: .whitespaces)
	guard !q.isEmpty else { return list }
	return list.enumerated()
		.compactMap { i, c in fuzzyScore(q, c.title).map { (i, c, $0) } }
		.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
		.map(\.1)
}

/// The row's second line (sessionMeta): the state when one exists,
/// otherwise how long ago. (Busy/compacting states arrive with M5.)
func sessionMeta(_ s: ChatSummary, now: Date = Date()) -> String {
	if s.pendingQuestion { return "Waiting for input · \(timeAgo(s.updatedAt, now: now))" }
	if s.kind == .practice, s.pendingProblem { return "Problem waiting · \(timeAgo(s.updatedAt, now: now))" }
	return timeAgo(s.updatedAt, now: now)
}

struct SessionRow: View {
	var summary: ChatSummary
	var body: some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(summary.title).font(.system(size: 13, design: .serif)).lineLimit(2)
				TimelineView(.periodic(from: .now, by: 60)) { context in
					Text(sessionMeta(summary, now: context.date)).font(Theme.ui).foregroundStyle(Theme.muted)
				}
			}
			Spacer(minLength: 0)
			if summary.kind == .practice {
				Image(systemName: "dumbbell").font(.system(size: 11)).foregroundStyle(Theme.faint).help("Practice session")
			}
		}
		.padding(.vertical, 2)
	}
}
