import LHCore
import LHMarkdown
import LHWeb
import SwiftUI

/// One session: toolbar (title — click to rename —, PLAN, phase), the Find
/// bar, the transcript with the pinned dock, the bottom status bar, the
/// session-scoped overlays, and the layered Esc (overlays first, then
/// "Dismiss this question?", then "Abort this turn?").
struct SessionView: View {
	@Bindable var session: SessionModel
	@State private var abortAsk: AbortMode?

	var body: some View {
		VStack(spacing: 0) {
			if session.find.isOpen {
				FindBar(find: session.find)
				Divider()
			}
			ZStack {
				TranscriptView(session: session)
					.safeAreaInset(edge: .bottom, spacing: 0) {
						if session.record != nil { DockView(session: session) }
					}
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
		.navigationTitle(titleBinding)
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
				if !session.isPractice { CoverageRing(chatId: session.chatId) }
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
		.onExitCommand(perform: escape)
		.alert(abortAsk?.title ?? "", isPresented: Binding(get: { abortAsk != nil }, set: { if !$0 { abortAsk = nil } }), presenting: abortAsk) { mode in
			Button(mode.action, role: .destructive) { confirm(mode) }
			Button("Cancel", role: .cancel) {}
		} message: { mode in
			Text(mode.line(busy: session.busy))
		}
		.focusedSceneValue(\.session, session)
		.task(id: session.chatId) { await session.start() }
	}

	/// Click-to-rename (the native editable title).
	private var titleBinding: Binding<String> {
		Binding(get: { session.title }, set: { session.rename($0) })
	}

	/// chat.tsx escAbortTarget: overlays and Find claim Esc first.
	private func escape() {
		if session.find.isOpen { session.find.close(); return }
		switch escAbortTarget(abortAsk: abortAsk != nil, diagram: session.overlays.diagram != nil, plan: session.overlays.planOpen,
			setup: false, pending: session.pending != nil, problem: false, busy: session.busy)
		{
		case .diagram?: session.overlays.diagram = nil
		case .plan?: session.overlays.planOpen = false
		case .question?: abortAsk = .question
		case .turn?: abortAsk = .turn
		case .setup?, .problem?, nil: break
		}
	}

	private func confirm(_ mode: AbortMode) {
		switch mode {
		case .question:
			if session.busy { session.abortTurn() }
			session.dismissPending()
		case .turn:
			session.abortTurn()
		case .problem:
			break
		}
	}
}

/// The view sits at the bottom of the transcript. `containerSize` excludes
/// BOTH insets — the dock below and the toolbar the transcript scrolls under
/// above — while the offset at rest at the bottom only accounts for the
/// dock (measured: content 2793, dock 150, toolbar 52 → offset 2443,
/// container 298). So the bottom is offset + container + top inset =
/// content height. Ignoring the top inset left the toolbar's height short
/// of the 24pt tolerance: the button never hid.
/// The dock growing (a question expanding) or shrinking moves the scroll
/// view by the same amount, so what was on screen stays there: at the
/// bottom it stays at the bottom, otherwise the offset shifts by the delta.
extension View {
	func followsBottomInset(position: Binding<ScrollPosition>, atBottom: Bool, toBottom: @escaping () -> Void) -> some View {
		onScrollGeometryChange(for: BottomInset.self) { geo in
			BottomInset(inset: geo.contentInsets.bottom, offset: geo.contentOffset.y)
		} action: { old, new in
			guard new.inset != old.inset else { return }
			if atBottom {
				toBottom()
			} else {
				position.wrappedValue.scrollTo(y: old.offset + new.inset - old.inset)
			}
		}
	}
}

/// The bottom inset with the offset it was seen at.
struct BottomInset: Equatable {
	var inset: CGFloat
	var offset: CGFloat
}

func isBottom(_ geo: ScrollGeometry) -> Bool {
	geo.contentOffset.y + geo.containerSize.height + geo.contentInsets.top >= geo.contentSize.height - 24
}

/// The transcript column (chat.tsx Conversation): rows in a lazy stack,
/// opening at the bottom and sticking there while it streams; a
/// scroll-to-bottom button otherwise. Find and graph anchors scroll rows
/// into view. The trailing placeholders and the error banner end it.
struct TranscriptView: View {
	var session: SessionModel
	@State private var flash: String?
	@State private var position = ScrollPosition(edge: .bottom)

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 16) {
					if session.rows.isEmpty, !session.busy {
						ContentUnavailableView("New session", systemImage: "graduationcap",
							description: Text("The teacher will open by probing what you already know."))
							.padding(.top, 60)
					}
					ForEach(session.rows) { row in
						RowView(row: row)
							.id(row.id)
							.background(flash == row.id ? Color.accentColor.opacity(0.15) : .clear)
					}
					if session.compacting {
						HStack(spacing: 8) { BrailleSpinner(); ShimmerText(text: "Compacting context…") }
					}
					if session.status == .submitted || (session.running && session.status == .idle) {
						HStack(spacing: 8) { BrailleSpinner(); ShimmerText(text: "Thinking…") }
					}
					if let error = session.errorText {
						Text("Something went wrong: \(error)")
							.font(Theme.small)
							.textSelection(.enabled)
							.padding(.horizontal, 12)
							.padding(.vertical, 8)
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(RoundedRectangle(cornerRadius: 8).fill(Theme.red.opacity(0.1)))
							.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.red.opacity(0.5)))
					}
					Color.clear.frame(height: 1).id("bottom")
				}
				.padding(.horizontal, Theme.column)
				.padding(.vertical, 16)
			}
			.scrollPosition($position)
			.defaultScrollAnchor(.bottom)
			// "At the bottom" follows YOUR scrolling: reaching the bottom sets it,
			// but only a scroll you make can clear it — content growing while a
			// turn streams, or the dock changing height, never does.
			.onScrollGeometryChange(for: Bool.self) { geo in
				isBottom(geo)
			} action: { _, atBottom in
				if atBottom { session.isAtBottom = true }
			}
			.followsBottomInset(position: $position, atBottom: session.isAtBottom) {
				proxy.scrollTo("bottom", anchor: .bottom)
			}
			.onScrollPhaseChange { old, new, context in
				if new == .idle, old == .interacting || old == .decelerating {
					session.isAtBottom = isBottom(context.geometry)
				}
			}
			.onChange(of: session.rows.count) {
				if session.isAtBottom, session.busy { proxy.scrollTo("bottom", anchor: .bottom) }
			}
			.onChange(of: session.streaming?.assistant?.content.count) {
				if session.isAtBottom { proxy.scrollTo("bottom", anchor: .bottom) }
			}
			.overlay(alignment: .bottom) {
				if !session.isAtBottom {
					Button {
						withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
					} label: {
						Image(systemName: "arrow.down")
							.font(.system(size: 12, weight: .semibold))
							.frame(width: 30, height: 30)
							.background(Circle().fill(Theme.card))
							.overlay(Circle().strokeBorder(Theme.border))
					}
					.buttonStyle(.plain)
					.help("Scroll to the bottom")
					.padding(.bottom, 8)
				}
			}
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
		case .reasoning(let text, let streaming): ReasoningRow(text: text, id: row.id, streaming: streaming)
		case .liveTool(let part): LiveToolCard(part: part, id: row.id)
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

/// stats-bar.tsx: the cost meter (`ctx · cost` → SESSION STATS, shown once
/// turns exist) on the left; ModelControl (this session's model + effort) on
/// the right.
struct StatusBar: View {
	var session: SessionModel
	@State private var open = false

	var body: some View {
		let turns = session.record?.turns ?? []
		VStack(spacing: 0) {
			Divider()
			HStack {
				if !turns.isEmpty {
					let cost = sessionCost(turns, catalog: session.catalog)
					let ctx = contextWindow(turns, catalog: session.catalog)
					Button { open.toggle() } label: {
						Text("\(ctxLabel(ctx)) · \(costLabel(cost, turns: turns.count))")
							.font(Theme.ui)
							.monospacedDigit()
							.foregroundStyle(Theme.muted)
					}
					.buttonStyle(.plain)
					.popover(isPresented: $open, arrowEdge: .top) { SessionStats(turns: turns, catalog: session.catalog) }
				}
				Spacer()
				if session.record != nil, session.service != nil { ModelControl(session: session) }
			}
			.padding(.horizontal, 12)
			.frame(height: 28)
		}
	}
}

/// model-picker.tsx ModelControl: the model pill and the effort pill —
/// this session's own (stored on the chat, effort clamped to the model).
struct ModelControl: View {
	var session: SessionModel

	var body: some View {
		let spec = session.conversationSpec
		let efforts = session.catalog.model(spec.model)?.efforts ?? []
		HStack(spacing: 6) {
			Menu {
				Section("This session's model") {
					ForEach(session.catalog.models, id: \.id) { m in
						Button {
							session.setModel(m.id, effort: spec.effort)
						} label: {
							if m.id == spec.model { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
						}
					}
				}
			} label: {
				Text(session.catalog.model(spec.model)?.name ?? prettyModel(spec.model))
			}
			Menu {
				Section("Levels this model actually supports") {
					ForEach(efforts, id: \.self) { e in
						Button {
							session.setModel(spec.model, effort: e)
						} label: {
							if e == spec.effort { Label(e.rawValue, systemImage: "checkmark") } else { Text(e.rawValue) }
						}
					}
				}
			} label: {
				Text(spec.effort.rawValue)
			}
			.disabled(efforts.isEmpty)
		}
		.menuStyle(.button)
		.buttonStyle(.borderless)
		.font(Theme.ui)
		.fixedSize()
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
