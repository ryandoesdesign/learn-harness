import LHCore
import LHMarkdown
import LHStore
import LHWeb
import SwiftUI

/// One session: toolbar (title — click to rename —, PLAN, coverage), the Find
/// bar, the transcript with the pinned dock, the bottom status bar, the
/// session-scoped overlays, and the layered Esc (overlays first, then
/// "Dismiss this question?", then "Abort this turn?").
struct SessionView: View {
	@Bindable var session: SessionModel
	@State private var abortAsk: AbortMode?
	@Environment(DictationService.self) private var dictation: DictationService?

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
		.background {
			// Practice (docs/native-macos-m8.md): Enter with no field focused
			// submits the thinking or asks for the next problem. A focused text
			// editor keeps its own Return.
			if session.nextReady || session.activeProblem != nil {
				Button("") { session.nextReady ? session.requestNext() : session.submitThinking() }
					.keyboardShortcut(.defaultAction)
					.hidden()
			}
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
		// Dictation first (dictation.tsx): Esc stops and discards the run.
		if let dictation, dictation.isActive { dictation.cancel(); return }
		if session.find.isOpen { session.find.close(); return }
		switch escAbortTarget(abortAsk: abortAsk != nil, diagram: session.overlays.diagram != nil, plan: session.overlays.planOpen,
			setup: false, pending: session.pending != nil, problem: session.activeProblem != nil, busy: session.busy)
		{
		case .diagram?: session.overlays.diagram = nil
		case .plan?: session.overlays.planOpen = false
		case .question?: abortAsk = .question
		case .problem?: abortAsk = .problem
		case .turn?: abortAsk = .turn
		case .setup?, nil: break
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
			if session.busy { session.abortTurn() }
			session.discardProblem()
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
				session.viewAtBottom = atBottom
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
			// Overlays, never the dock: a control that changed the dock's height would
			// move the bottom inset, which snaps a following view back down — scrolling
			// up a little would loop (pill shows, snap, pill hides).
			.overlay(alignment: .bottom) {
				if session.pending != nil, !session.viewAtBottom {
					Button { session.showPendingQuestion() } label: {
						HStack(spacing: 4) { Text("Question below"); Image(systemName: "arrow.down") }
							.font(Theme.uiMedium)
							.padding(.horizontal, 12)
							.padding(.vertical, 6)
							.background(Capsule().fill(Theme.card))
							.overlay(Capsule().strokeBorder(Theme.border))
					}
					.buttonStyle(.plain)
					.help("Scroll to the open question")
					.padding(.bottom, 8)
				} else if !session.isAtBottom {
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
					.accessibilityLabel("Scroll to the bottom")
					.padding(.bottom, 8)
				}
			}
			.onChange(of: session.find.scrollTick) {
				if let match = session.find.activeMatch {
					withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(match.rowId, anchor: UnitPoint(x: 0, y: 0.04)) }
				}
			}
			.onChange(of: session.rowRequest) {
				guard let row = session.rowRequest?.anchor else { return }
				withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(row, anchor: UnitPoint(x: 0, y: 0.04)) }
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
		case .textBlock(let block, _): NotedParagraph(rowId: row.id) { BlockView(block: block, unit: blockUnitId(row.id, 0), font: Theme.prose, fontSize: Theme.proseSize) }
		case .reasoning(let text, let streaming): ReasoningRow(text: text, id: row.id, streaming: streaming)
		case .liveTool(let part): LiveToolCard(part: part, id: row.id)
		case .separator: Divider().padding(.vertical, 4)
		case .planBlock(let data): PlanBlockView(data: data)
		case .answered(let answer, let input): AnsweredCard(answer: answer, input: input, id: row.id)
		case .pendingQuestion(let tool, let toolCallId, let input): InlineQuestion(tool: tool, toolCallId: toolCallId, input: input)
		case .tool(let part): ToolPartCard(part: part, id: row.id)
		case .retrying: SystemLine(text: "Retrying…")
		case .refusal(let explanation): RefusalLine(explanation: explanation, id: row.id)
		}
	}
}

/// An open question where it was asked: its card while the chat is idle
/// (an answer in flight or a running turn shows nothing, as the dock did).
struct InlineQuestion: View {
	var tool: String
	var toolCallId: String
	var input: JSONValue
	@Environment(SessionModel.self) private var session

	var body: some View {
		if session.pendingAll.contains(where: { $0.toolCallId == toolCallId }) {
			QuestionDockView(session: session, tool: tool, toolCallId: toolCallId, input: input)
				.id(reposeOrigin(toolCallId))
		}
	}
}

/// A paragraph of the teacher's prose with its reading notes: hovering shows
/// ✎, which opens a note field under it; sent notes stay under it, muted.
struct NotedParagraph<Content: View>: View {
	var rowId: String
	@ViewBuilder var content: Content
	@Environment(SessionModel.self) private var session
	@State private var hovering = false
	@FocusState private var focused: Bool

	var body: some View {
		@Bindable var session = session
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .top, spacing: 6) {
				content.frame(maxWidth: .infinity, alignment: .leading)
				Button {
					if session.noteDrafts[rowId] == nil { session.noteDrafts[rowId] = "" }
					// The field exists from the next update on.
					Task { @MainActor in focused = true }
				} label: {
					Image(systemName: "pencil").font(.system(size: 11))
				}
				.buttonStyle(.borderless)
				.foregroundStyle(Theme.muted)
				.help("Add your thinking about this paragraph")
				.accessibilityLabel("Add your thinking about this paragraph")
				.opacity(hovering && session.takesNotes(rowId) && session.noteDrafts[rowId] == nil ? 1 : 0)
				.disabled(!session.takesNotes(rowId))
			}
			ForEach(Array((session.sentNotes[rowId] ?? []).enumerated()), id: \.offset) { _, note in
				Text(note)
					.font(Theme.small)
					.foregroundStyle(Theme.muted)
					.textSelection(.enabled)
					.padding(.leading, 10)
					.overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
			}
			if let draft = session.noteDrafts[rowId] {
				noteField(Binding(get: { session.noteDrafts[rowId] ?? draft }, set: { session.noteDrafts[rowId] = $0 }))
			}
		}
		.onHover { hovering = $0 }
	}

	/// The composer's box (the ReadingThinkingField it replaces had the same).
	private func noteField(_ text: Binding<String>) -> some View {
		ZStack(alignment: .topLeading) {
			if text.wrappedValue.isEmpty {
				Text("Your thinking about this paragraph.").foregroundStyle(Theme.faint).padding(.horizontal, 5).padding(.vertical, 2).allowsHitTesting(false)
			}
			TextEditor(text: text)
				.scrollContentBackground(.hidden)
				.frame(minHeight: 24, maxHeight: 160)
				.fixedSize(horizontal: false, vertical: true)
				.focused($focused)
				.dictationTarget("note.\(rowId)", .readingThinking, text: text)
		}
		.font(Theme.prose)
		.padding(.horizontal, 7)
		.padding(.vertical, 10)
		.background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
		// A note emptied and left removes itself.
		.onChange(of: focused) { _, now in
			if !now, session.noteDrafts[rowId]?.jsTrimmed.isEmpty == true { session.noteDrafts[rowId] = nil }
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
			Button { find.step(-1) } label: { Image(systemName: "chevron.up") }.help("Previous match").accessibilityLabel("Previous match").disabled(find.matches.isEmpty)
			Button { find.step(1) } label: { Image(systemName: "chevron.down") }.help("Next match").accessibilityLabel("Next match").disabled(find.matches.isEmpty)
			Button { find.close() } label: { Image(systemName: "xmark") }.help("Close").accessibilityLabel("Close Find")
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
				// The session's mode (your call, 2026-10-24: moved from the toolbar).
				ModeIndicator(session: session)
				if !turns.isEmpty {
					Text("·").font(Theme.ui).foregroundStyle(Theme.faint)
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
				DictationButton()
				Spacer()
				if session.record != nil, session.service != nil { ModelControl(session: session) }
			}
			.padding(.horizontal, 12)
			.frame(height: 28)
		}
	}
}

/// The phase (PROBING / PLANNING / TEACHING) or PRACTICE, at the far left of
/// the status bar.
struct ModeIndicator: View {
	var session: SessionModel
	var body: some View {
		Group {
			if session.isPractice {
				Label("PRACTICE", systemImage: "dumbbell").labelStyle(.titleAndIcon)
			} else {
				Text(phaseLabel(session.phase).uppercased())
			}
		}
		.font(Theme.uiMedium)
		.tracking(0.6)
		.foregroundStyle(Theme.muted)
		.accessibilityLabel(session.isPractice ? "Practice session" : "Phase: \(phaseLabel(session.phase))")
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
		.popover(isPresented: Binding(get: { session.overlays.modelPickerOpen }, set: { session.overlays.modelPickerOpen = $0 }), arrowEdge: .top) {
			ModelEffortPicker(catalog: session.catalog, model: spec.model, effort: spec.effort) { session.setModel($0, effort: $1) }
		}
	}
}

/// ⌘K (model-picker.tsx's keyboard opening): the model and the effort it
/// supports, as pickers — Return or Esc closes it.
struct ModelEffortPicker: View {
	var catalog: ModelCatalog
	var model: String
	var effort: Effort
	var onChange: (String, Effort) -> Void

	var body: some View {
		let efforts = catalog.model(model)?.efforts ?? []
		Form {
			Picker("Model", selection: Binding(get: { model }, set: { onChange($0, effort) })) {
				ForEach(catalog.models, id: \.id) { Text($0.name).tag($0.id) }
			}
			Picker("Effort", selection: Binding(get: { effort }, set: { onChange(model, $0) })) {
				ForEach(efforts, id: \.self) { Text($0.rawValue).tag($0) }
			}
			.disabled(efforts.isEmpty)
		}
		.padding(12)
		.frame(width: 300)
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

// MARK: - Previews

/// A session as RootView shows it: an AppModel on a scratch directory (the
/// coverage ring reads it), the chat inserted, then selected; `configure`
/// sets view state on the loaded session (an opened check, note drafts).
@MainActor
private func sessionPreview(_ insert: (ChatRepository) throws -> String, configure: (SessionModel) throws -> Void = { _ in }) -> some View {
	let dir = FileManager.default.temporaryDirectory.appending(path: "lhpv-\(UUID().uuidString)", directoryHint: .isDirectory)
	let app = AppModel(dataDirectory: dir, keychain: InMemoryKeychain())
	app.selection = try! insert(ChatRepository(app.database))
	let session = app.session!
	session.load()
	try! configure(session)
	return NavigationStack {
		SessionView(session: session)
	}
	.environment(app)
	.environment(app.dictation)
	.frame(width: 900, height: 700)
}

#Preview("Render Gallery") {
	sessionPreview { repo in
		try repo.insert(RenderGallery.record(), origin: .native)
		return RenderGallery.chatId
	}
}

#Preview("New session") {
	sessionPreview { try $0.createChat(title: "New session").id }
}

#Preview("Practice") {
	sessionPreview { repo in
		let chat = try repo.createChat(title: "Joins", kind: .practice)
		let input: JSONValue = ["statement": "Join `a` and `b` keeping every row of `a`.", "mode": "recall", "modelSolution": "LEFT JOIN"]
		try repo.append([
			newUserMessage("Practise joins", now: 0),
			Message(id: "a_p1", timestamp: 1, body: .assistant(AssistantBody(content: [.toolUse(id: "p1", name: "problem", input: input)], model: "claude-opus-5-5", stopReason: "tool_use"))),
			Message(id: "r_p1", timestamp: 2, body: .toolResult(ToolResultBody(toolUseId: "p1", toolName: "problem", content: [.text("Problem posed")], isError: false, details: nil))),
		], to: chat.id)
		return chat.id
	}
}

// MARK: Inline questions and paragraph notes

private let previewProse = "An inner join pairs each row of one table with the rows of another whose join key matches.\n\nRows with no match on either side are dropped from the result."

/// A probe-phase chat whose last reply ends in an open question.
private func probeQuestion(_ repo: ChatRepository) throws -> String {
	let chat = try repo.createChat(title: "Joins")
	let input: JSONValue = [
		"question": "Which join keeps every row of the left table?",
		"options": [["label": "LEFT JOIN", "value": "left"], ["label": "INNER JOIN", "value": "inner"], ["label": "Not sure yet", "value": "unsure"]],
	]
	try repo.append([
		newUserMessage("Teach me SQL joins", now: 0),
		Message(id: "a_q1", timestamp: 1, body: .assistant(AssistantBody(content: [.text(previewProse), .toolUse(id: "q1", name: "ask_user_question", input: input)], model: "claude-opus-5-5", stopReason: "tool_use"))),
	], to: chat.id)
	return chat.id
}

/// A teach-phase chat (probe concluded, plan handed off) ending in a tagged check.
private func teachCheck(_ repo: ChatRepository) throws -> String {
	let chat = try repo.createChat(title: "Joins")
	let quiz: JSONValue = [
		"question": "Which rows survive an inner join?",
		"options": [["label": "Only rows whose key matches on both sides", "value": "a"], ["label": "Every row of the left table", "value": "b"]],
		"correctAnswer": "a", "explanation": "Unmatched rows are dropped.", "nodeId": "n1",
	]
	try repo.append([
		newUserMessage("Teach me SQL joins", now: 0),
		Message(id: "a_d", timestamp: 1, body: .assistant(AssistantBody(content: [.toolUse(id: "d1", name: "probe_done", input: ["assessment": ["summary": "Knows SELECT."]])], model: "claude-opus-5-5", stopReason: "tool_use"))),
		Message(id: "r_d", timestamp: 2, body: .toolResult(ToolResultBody(toolUseId: "d1", toolName: "probe_done", content: [.text(PROBE_DONE_ACK_TEXT)], isError: false))),
		Message(id: "h", timestamp: 3, body: .marker(MarkerBody(kind: .probeHandoff, content: HANDOFF_TEXT, display: true, details: [:]))),
		Message(id: "a_k1", timestamp: 4, body: .assistant(AssistantBody(content: [.text(previewProse), .toolUse(id: "k1", name: "quiz", input: quiz)], model: "claude-opus-5-5", stopReason: "tool_use"))),
	], to: chat.id)
	return chat.id
}

/// The probe question open: the card inline at its call, the composer inside it asking about it.
#Preview("Question open") {
	sessionPreview(probeQuestion)
}

/// A teach check arrives behind its bar.
#Preview("Teach check · waiting") {
	sessionPreview(teachCheck)
}

/// The same check opened in place.
#Preview("Teach check · opened") {
	sessionPreview(teachCheck) { $0.revealedChecks.insert("k1") }
}

/// Paragraph notes: one sent with an earlier answer (muted, under its
/// paragraph), one drafted on the next paragraph (the open field).
#Preview("Paragraph notes") {
	sessionPreview(probeQuestion) { s in
		// The note anchors to the first paragraph's row, so answer once the rows exist.
		let first = s.rows.first { if case .textBlock = $0.kind { true } else { false } }!.id
		var a = dismissedAnswer(.ask, questionText: "Which join keeps every row of the left table?")
		a.readingNotes = [ReadingNote(anchor: first, quote: readingQuote(previewProse), text: "So it's a filtered cross product?")]
		a.readingThinking = readingThinkingText(a.readingNotes!)
		try ChatRepository(s.database).append([
			newAnswerResult(toolCallId: "q1", toolName: "ask_user_question", answer: a, now: 2),
			Message(id: "a_more", timestamp: 3, body: .assistant(AssistantBody(content: [.text("A left join keeps them instead, filling the missing side with NULLs.")], model: "claude-opus-5-5", stopReason: "end_turn"))),
		], to: s.chatId)
		s.load()
		let last = s.rows.last { if case .textBlock = $0.kind { true } else { false } }!.id
		s.noteDrafts[last] = "Why NULLs and not empty strings?"
	}
}
