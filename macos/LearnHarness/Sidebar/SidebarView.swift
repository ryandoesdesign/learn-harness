import LHAgent
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

/// The sessions sidebar (sidebar.tsx): "+" (new session), fuzzy search,
/// kind filter, rows with their live state (spinner, Working…, Compacting,
/// Waiting for input), and the context menu: Rename, Export as Markdown…,
/// Delete….
struct SidebarView: View {
	var model: AppModel
	@Binding var selection: String?
	@AppStorage("lh.sessionKindFilter") private var filter: SessionKindFilter = .all
	@State private var query = ""
	@FocusState private var searchFocused: Bool
	@State private var renaming: String?
	@State private var renameText = ""
	@FocusState private var renameFocused: Bool
	@State private var deleting: ChatSummary?
	@State private var deleteError: String?

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
						Group {
							if renaming == s.id {
								TextField("Title", text: $renameText)
									.textFieldStyle(.plain)
									.focused($renameFocused)
									.onSubmit { commitRename(s.id) }
									.onKeyPress(.escape) { renaming = nil; return .handled }
									.onChange(of: renameFocused) { _, f in if !f, renaming == s.id { commitRename(s.id) } }
							} else {
								SessionRow(summary: s, busy: model.runningChats.contains(s.id), compacting: model.compactingChats.contains(s.id))
							}
						}
						.tag(s.id)
						.contextMenu {
							Button("Rename") { startRename(s) }
							Button("Export as Markdown…") { model.exportMarkdown(chatId: s.id) }
							if s.kind != .practice { CoverageMenuItems(model: model, chatId: s.id) }
							Divider()
							Button("Delete…", role: .destructive) {
								deleteError = nil
								deleting = s
							}
						}
					}
				}
			}
			.listStyle(.sidebar)
			// Return on a selected row renames it, as in Finder.
			.onKeyPress(.return) {
				guard renaming == nil, let id = selection, let s = model.sessions.first(where: { $0.id == id }) else { return .ignored }
				startRename(s)
				return .handled
			}
			BackgroundAgentsSection(model: model)
		}
		.padding(.top, 8)
		.padding(.horizontal, 8)
		.toolbar {
			ToolbarItem {
				Button { model.newSession() } label: { Label("New Session", systemImage: "plus") }
					.help("New session (⌘N)")
			}
		}
		.sheet(item: $deleting) { s in
			DeleteSessionSheet(summary: s, error: deleteError, onCancel: { deleting = nil }) { traces in
				Task {
					if let error = await model.delete(s.id, removeGraphTraces: traces) { deleteError = error } else { deleting = nil }
				}
			}
		}
		.onChange(of: model.searchRequest) { searchFocused = true }
		.onChange(of: model.renameRequest) {
			guard let id = model.renameRequest, let s = model.sessions.first(where: { $0.id == id }) else { return }
			model.renameRequest = nil
			startRename(s)
		}
	}

	private func startRename(_ s: ChatSummary) {
		renameText = s.title
		renaming = s.id
		renameFocused = true
	}

	private func commitRename(_ id: String) {
		let title = renameText
		renaming = nil
		model.rename(id, to: title)
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
/// otherwise how long ago.
func sessionMeta(_ s: ChatSummary, busy: Bool = false, compacting: Bool = false, now: Date = Date()) -> String {
	if compacting { return "Compacting context · \(timeAgo(s.updatedAt, now: now))" }
	if s.pendingQuestion { return "Waiting for input · \(timeAgo(s.updatedAt, now: now))" }
	if s.kind == .practice, s.pendingProblem { return "Problem waiting · \(timeAgo(s.updatedAt, now: now))" }
	if busy { return "Working…" }
	return timeAgo(s.updatedAt, now: now)
}

struct SessionRow: View {
	var summary: ChatSummary
	var busy = false
	var compacting = false
	var body: some View {
		HStack(spacing: 8) {
			if busy || compacting { BrailleSpinner() }
			VStack(alignment: .leading, spacing: 2) {
				Text(summary.title).font(.system(size: 13, design: .serif)).lineLimit(2)
				TimelineView(.periodic(from: .now, by: 60)) { context in
					Text(sessionMeta(summary, busy: busy, compacting: compacting, now: context.date)).font(Theme.ui).foregroundStyle(Theme.muted)
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

extension ChatSummary: @retroactive Identifiable {}

/// delete-session-dialog.tsx, with the graph-traces option (M7). Its copy is
/// corrected: TS mentions "links" and "events" the graph no longer has.
struct DeleteSessionSheet: View {
	var summary: ChatSummary
	var error: String?
	var onCancel: () -> Void
	var onDelete: (_ removeTraces: Bool) -> Void
	@State private var traces = false

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Delete session?").font(.headline).foregroundStyle(Theme.red)
			Text(summary.title).font(Theme.mono)
			Text("This permanently removes the session — its messages, background jobs, and extraction records. This cannot be undone.")
				.font(Theme.small)
				.foregroundStyle(Theme.muted)
				.fixedSize(horizontal: false, vertical: true)
			Toggle(isOn: $traces) {
				VStack(alignment: .leading, spacing: 2) {
					Text("Also remove its graph traces")
					Text("The propositions and chains this session added leave the graph too. Anything another session or imported notes also hold survives; what only this session created is removed entirely.")
						.font(Theme.small)
						.foregroundStyle(Theme.muted)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.toggleStyle(.checkbox)
			if let error {
				Text(error).font(Theme.small).foregroundStyle(Theme.red)
			}
			HStack {
				Spacer()
				Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
				Button(error == nil ? "Delete" : "Try again", role: .destructive) { onDelete(traces) }
			}
		}
		.padding(20)
		.frame(width: 440)
	}
}

/// sidebar.tsx CoverageMenuBlock: the session's extraction coverage and Extract.
struct CoverageMenuItems: View {
	var model: AppModel
	var chatId: String

	var body: some View {
		if let c = model.coverage(chatId) {
			Divider()
			Text(c.running ? "extracting…" : c.uncoveredCount == 0 ? "fully extracted" : "\(c.uncoveredTokens) tok uncovered / \(c.uncoveredCount) messages unextracted")
			Button(c.running ? "Running" : "Extract") { model.extract(chatId) }.disabled(c.running || c.uncoveredCount == 0)
		}
	}
}
