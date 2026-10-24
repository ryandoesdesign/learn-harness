import LHCore
import LHMarkdown
import LHWeb
import SwiftUI

/// One session: toolbar (title, PLAN, phase), the Find bar, the read-only
/// transcript, the bottom status bar (cost meter), and the session-scoped
/// overlays above the detail column.
struct SessionView: View {
	@Bindable var session: SessionModel
	@Environment(\.openURL) private var openURL

	var body: some View {
		VStack(spacing: 0) {
			if session.find.isOpen {
				FindBar(find: session.find)
				Divider()
			}
			ZStack {
				TranscriptView(session: session)
				if let diagram = session.overlays.diagram {
					DiagramOverlay(diagram: diagram, onClose: { session.overlays.diagram = nil })
				} else if session.overlays.planOpen {
					PlanPopup(tree: session.plan, messages: session.record?.messages ?? [], onClose: { session.overlays.planOpen = false })
				}
			}
			StatusBar(session: session)
		}
		.environment(session)
		.environment(session.find)
		.environment(session.overlays)
		.navigationTitle(session.title)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				if session.plan != nil {
					Button {
						session.overlays.openPlan()
					} label: {
						Label("Plan", systemImage: "point.3.connected.trianglepath.dotted")
							.labelStyle(.titleAndIcon)
					}
					.help("Open the plan")
				}
				if session.isPractice {
					Label("Practice", systemImage: "dumbbell")
						.labelStyle(.titleAndIcon)
						.font(Theme.uiMedium)
						.foregroundStyle(Theme.muted)
						.allowsHitTesting(false)
				} else {
					Text(phaseLabel(session.phase).uppercased())
						.font(Theme.uiMedium)
						.tracking(0.6)
						.foregroundStyle(Theme.muted)
						.allowsHitTesting(false)
				}
			}
		}
		.focusedSceneValue(\.session, session)
	}
}

/// The transcript column (chat.tsx Conversation): rows in a lazy stack,
/// opening at the bottom; Find and graph anchors scroll rows into view.
struct TranscriptView: View {
	var session: SessionModel
	@State private var flash: String?

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 16) {
					if session.rows.isEmpty {
						ContentUnavailableView("New session", systemImage: "graduationcap",
							description: Text("The teacher will open by probing what you already know."))
							.padding(.top, 60)
					}
					ForEach(session.rows) { row in
						RowView(row: row)
							.id(row.id)
							.background(flash == row.id ? Color.accentColor.opacity(0.15) : .clear)
					}
				}
				.padding(.horizontal, Theme.column)
				.padding(.vertical, 16)
			}
			.defaultScrollAnchor(.bottom)
			.onChange(of: session.find.scrollTick) {
				if let match = session.find.activeMatch {
					withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(match.rowId, anchor: UnitPoint(x: 0, y: 0.04)) }
				}
			}
			.onChange(of: session.anchorRequest) {
				guard let request = session.anchorRequest, let row = session.rowId(forAnchor: request) else { return }
				proxy.scrollTo(row, anchor: UnitPoint(x: 0, y: 0.04))
				flash = row
				Task {
					try? await Task.sleep(for: .seconds(2))
					withAnimation { if flash == row { flash = nil } }
				}
			}
		}
	}
}

/// One row → its renderer (the chat.tsx dispatch).
struct RowView: View {
	var row: TranscriptRow

	var body: some View {
		switch row.kind {
		case .userBand(let text): UserBand(text: text, unit: "\(row.id).text")
		case .steer(let m): SteerCard(message: m, id: row.id)
		case .phaseDivider(let phase): PhaseDividerView(phase: phase)
		case .graphContext(let data): GraphContextCard(data: data, id: row.id)
		case .compactionMoment:
			Text("Context compacted").font(Theme.ui).foregroundStyle(Theme.faint).frame(maxWidth: .infinity).padding(.vertical, 4)
		case .compactionCut(let tokens):
			DottedDivider(label: "History compacted" + (tokens > 0 ? " · \(Int((Double(tokens) / 1000).rounded()))k tok" : ""))
		case .practiceThinking(let text): ThinkingBlock(text: text, id: row.id, defaultOpen: true)
		case .practiceNext:
			HStack(spacing: 6) {
				Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
				Eyebrow("Next problem")
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 16)
		case .textBlock(let block, _): BlockView(block: block, unit: blockUnitId(row.id, 0), font: Theme.prose, fontSize: Theme.proseSize)
		case .reasoning(let text): ReasoningRow(text: text, id: row.id)
		case .separator: Divider().padding(.vertical, 4)
		case .planBlock(let data): PlanBlockView(data: data)
		case .answered(let answer, let input): AnsweredCard(answer: answer, input: input, id: row.id)
		case .tool(let part): ToolPartCard(part: part, id: row.id)
		case .retrying: SystemLine(text: "Retrying…")
		case .refusal(let explanation): RefusalLine(explanation: explanation, id: row.id)
		}
	}
}

/// The live diagram / figure focus (MermaidOverlay): one WKWebView, page
/// scripts off, transformed by the native pan/zoom.
struct DiagramOverlay: View {
	var diagram: SessionOverlays.Diagram
	var onClose: () -> Void

	var body: some View {
		FocusOverlay(title: diagram.figure ? "Figure" : "Diagram", subtitle: "from this lesson", box: diagram.size, onClose: onClose) { v in
			DiagramWebView(svg: diagram.svg, size: diagram.size, zoom: v.zoom, x: v.x, y: v.y,
				whiteBacking: diagram.figure, inverted: diagram.inverted)
		}
	}
}

// MARK: - Find bar

/// The Find bar (session-find.tsx): "Find in session…", i/N, ↑ ↓ ✕.
/// Enter = next, ⇧Enter = previous, Esc closes.
struct FindBar: View {
	@Bindable var find: FindModel
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
			TextField("Find in session…", text: $find.query)
				.textFieldStyle(.plain)
				.focused($focused)
				.onSubmit { find.step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); focused = true }
				.onKeyPress(.escape) {
					find.close()
					return .handled
				}
			if !find.query.isEmpty {
				Text(find.matches.isEmpty ? "0/0" : "\(find.active + 1)/\(find.matches.count)")
					.font(Theme.ui)
					.monospacedDigit()
					.foregroundStyle(Theme.muted)
			}
			Button { find.step(-1) } label: { Image(systemName: "chevron.up") }.help("Previous match").disabled(find.matches.isEmpty)
			Button { find.step(1) } label: { Image(systemName: "chevron.down") }.help("Next match").disabled(find.matches.isEmpty)
			Button { find.close() } label: { Image(systemName: "xmark") }.help("Close")
		}
		.buttonStyle(.borderless)
		.padding(.horizontal, 12)
		.frame(height: 40)
		.onAppear { focused = true }
		.onChange(of: find.focusTick) { focused = true }
	}
}

// MARK: - Status bar (stats-bar.tsx)

/// The cost meter: `ctx · cost`; click → SESSION STATS. Hidden without turns.
struct StatusBar: View {
	var session: SessionModel
	@State private var open = false

	var body: some View {
		let turns = session.record?.turns ?? []
		if !turns.isEmpty {
			let cost = sessionCost(turns, catalog: session.catalog)
			let ctx = contextWindow(turns, catalog: session.catalog)
			VStack(spacing: 0) {
				Divider()
				HStack {
					Button { open.toggle() } label: {
						Text("\(ctxLabel(ctx)) · \(costLabel(cost, turns: turns.count))")
							.font(Theme.ui)
							.monospacedDigit()
							.foregroundStyle(Theme.muted)
					}
					.buttonStyle(.plain)
					.popover(isPresented: $open, arrowEdge: .top) { SessionStats(turns: turns, catalog: session.catalog) }
					Spacer()
				}
				.padding(.horizontal, 12)
				.frame(height: 26)
			}
		}
	}
}

private func ctxLabel(_ ctx: ContextWindowReading?) -> String {
	guard let ctx else { return "—" }
	if let limit = ctx.limit { return "\(formatTokens(ctx.usedTokens)) / \(formatTokens(limit))" }
	return formatTokens(ctx.usedTokens)
}

/// "—" when no turn is priced (stats-bar.tsx).
private func costLabel(_ cost: SessionCost, turns: Int) -> String {
	cost.unpriced >= turns ? "—" : formatUsd(cost.cost)
}

struct SessionStats: View {
	var turns: [TurnUsage]
	var catalog: ModelCatalog

	var body: some View {
		let cost = sessionCost(turns, catalog: catalog)
		VStack(alignment: .leading, spacing: 10) {
			Eyebrow("Session stats")
			Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
				GridRow { Text("Context (last call)").foregroundStyle(Theme.muted); Text(ctxLabel(contextWindow(turns, catalog: catalog))) }
				GridRow { Text("Total cost").foregroundStyle(Theme.muted); Text(costLabel(cost, turns: turns.count)) }
				if cost.unpriced > 0 { GridRow { Text("Unpriced turns").foregroundStyle(Theme.muted); Text("\(cost.unpriced)") } }
			}
			Divider()
			Eyebrow("Turns")
			ScrollView {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(Array(turns.enumerated()), id: \.offset) { i, turn in
						HStack {
							Text("#\(i + 1) · \(prettyModel(turn.model, qualified: true))")
							Spacer()
							Text("\(turn.steps.count) step\(turn.steps.count == 1 ? "" : "s")").foregroundStyle(Theme.muted)
							Text(turnCost(turn, catalog: catalog).map(formatUsd) ?? "—").frame(minWidth: 60, alignment: .trailing)
						}
					}
				}
			}
			.frame(maxHeight: 240)
		}
		.font(Theme.ui)
		.monospacedDigit()
		.padding(16)
		.frame(width: 340)
	}
}
