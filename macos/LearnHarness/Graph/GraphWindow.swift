import LHCore
import SwiftUI

/// The knowledge graph window (docs/native-macos-m7.md, your answer: its own
/// window, ⌘⇧G). Toolbar: the Chains toggle, Import notes… and the gear, then
/// the search field; the cost sits in the bottom status bar. With Graph
/// rendering off it shows the chain table.
struct GraphWindow: View {
	var app: AppModel
	@State private var model: GraphWindowModel?

	var body: some View {
		Group {
			if let model { GraphWindowContent(model: model) } else { Color.clear }
		}
		.onAppear { if model == nil { model = GraphWindowModel(app: app) } }
	}
}

private struct GraphWindowContent: View {
	@Bindable var model: GraphWindowModel
	@State private var showSettings = false
	@FocusState private var searchFocused: Bool

	var body: some View {
		let canvasMode = model.renderingEnabled && !model.showChains
		VStack(spacing: 0) {
			ZStack(alignment: .topLeading) {
				if model.snapshot == nil {
					ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if model.isEmpty {
					ContentUnavailableView("Knowledge graph", systemImage: "point.3.connected.trianglepath.dotted",
						description: Text("Start a session or import notes to build your graph."))
				} else if canvasMode {
					GraphCanvas(model: model)
					if model.noMatches {
						Text("No matching nodes.").foregroundStyle(.secondary).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
					}
					if let sel = model.selected { DetailCard(model: model, id: sel.id, anchor: sel.at) }
				} else {
					ChainTableView(model: model)
				}
				if !model.importErrors.isEmpty { importErrors.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
			}
			if let costs = model.costs, costs.stages.extraction.runs + costs.stages.audit.runs > 0 {
				GraphStatusBar(costs: costs)
			}
		}
		.navigationTitle("Knowledge Graph")
		.toolbar { toolbar(canvasMode: canvasMode) }
		// The native search field, its own group at the trailing edge (your
		// call, 2026-10-24); Esc clears it.
		.modifier(GraphSearch(enabled: !model.isEmpty, query: $model.query,
			prompt: canvasMode ? "Search nodes…" : "Search chains…", focused: $searchFocused))
		.task { await model.observe() }
		.onChange(of: model.app.sessions) { _, sessions in model.sessionsChanged(sessions) }
		.sheet(isPresented: Binding(get: { !model.deleteTargets.isEmpty }, set: { if !$0 { model.deleteTargets = [] } })) {
			DeleteNodeSheet(model: model)
		}
		.background {
			// Search focus and the camera commands, active while this window is key.
			Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
			Button("") { model.zoomBy(1.25) }.keyboardShortcut("=").hidden()
			Button("") { model.zoomBy(0.8) }.keyboardShortcut("-").hidden()
			Button("") { model.fit() }.keyboardShortcut("0").hidden()
		}
	}

	@ToolbarContentBuilder
	private func toolbar(canvasMode: Bool) -> some ToolbarContent {
		ToolbarItemGroup {
			if !model.isEmpty {
				if model.renderingEnabled {
					Toggle(isOn: $model.showChains) { Label("Chains", systemImage: "list.bullet.indent") }
						.help("Show the chain table")
				}
			}
			Button {
				Task { await model.importNotes() }
			} label: { Label("Import notes…", systemImage: "square.and.arrow.down") }
				.disabled(model.importing)
				.help("Import .md, .markdown or .txt notes into the graph")
			if !model.isEmpty {
				Button { showSettings.toggle() } label: { Label("Graph display settings", systemImage: "gearshape") }
					.popover(isPresented: $showSettings) { GraphSettingsPanel(model: model) }
			}
		}
	}

	private var importErrors: some View {
		VStack(alignment: .leading, spacing: 4) {
			ForEach(Array(model.importErrors.enumerated()), id: \.offset) { _, r in
				Text("\((r.path as NSString).lastPathComponent): \(r.error ?? r.outcome.rawValue)").foregroundStyle(.red)
			}
			Button("Dismiss") { model.importErrors = [] }.buttonStyle(.link)
		}
		.font(.system(size: 12))
		.padding(10)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}

/// `.searchable` only while the graph has nodes (no search on the empty state).
private struct GraphSearch: ViewModifier {
	var enabled: Bool
	@Binding var query: String
	var prompt: String
	var focused: FocusState<Bool>.Binding

	func body(content: Content) -> some View {
		if enabled {
			content
				.searchable(text: $query, placement: .toolbar, prompt: prompt)
				.searchFocused(focused)
		} else {
			content
		}
	}
}

/// The bottom status bar (your call, 2026-10-24: the cost moved from the
/// toolbar): the graph pipeline total — click for GraphCostPanel. Shown once
/// extraction or audit has run.
private struct GraphStatusBar: View {
	var costs: GraphCostSummary
	@State private var open = false

	var body: some View {
		VStack(spacing: 0) {
			Divider()
			HStack {
				Button { open.toggle() } label: {
					Text("$\(String(format: "%.2f", displayCostTotals(costs).totalDollars))")
						.font(Theme.ui)
						.monospacedDigit()
						.foregroundStyle(Theme.muted)
				}
				.buttonStyle(.plain)
				.help("Graph pipeline costs")
				.popover(isPresented: $open, arrowEdge: .top) { GraphCostPanel(costs: costs) }
				Spacer()
			}
			.padding(.horizontal, 12)
			.frame(height: 28)
		}
	}
}

/// The node detail card: below the node (above near the bottom edge),
/// clamped horizontally — name, statement, and its sessions.
private struct DetailCard: View {
	var model: GraphWindowModel
	var id: String
	var anchor: CGPoint

	var body: some View {
		GeometryReader { geo in
			let width = 300.0
			let below = anchor.y < geo.size.height - 220
			let x = min(max(anchor.x - width / 2, 12), max(12, geo.size.width - width - 12))
			card(width: width)
				.fixedSize(horizontal: false, vertical: true)
				.alignmentGuide(.top) { d in below ? -(anchor.y + 14) : -(anchor.y - d.height - 14) }
				.alignmentGuide(.leading) { _ in -x }
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
	}

	private func card(width: Double) -> some View {
		let node = model.nodeById[id]
		let sessions = model.sessions(of: id)
		return VStack(alignment: .leading, spacing: 6) {
			Text(node?.name ?? id).font(.system(size: 13, weight: .semibold))
			Text(node?.statement ?? "").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
			Divider()
			Text("SESSIONS").font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
			if sessions.isEmpty {
				Text("No sessions recorded.").font(.system(size: 12)).foregroundStyle(.secondary)
			}
			ForEach(sessions, id: \.id) { s in
				if s.isFile {
					Label((s.title as NSString).lastPathComponent, systemImage: "doc.text").font(.system(size: 12)).foregroundStyle(.secondary).help(s.title)
				} else {
					Button(s.title) { model.open(chat: s.id, node: id) }.buttonStyle(.link).font(.system(size: 12))
				}
			}
		}
		.padding(12)
		.frame(width: width, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
		.shadow(radius: 8, y: 2)
	}
}
