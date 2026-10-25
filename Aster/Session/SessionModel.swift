import Foundation
import LHAgent
import LHCore
import LHMarkdown
import LHStore
import Observation

/// One open session: the record (observed from the store), the live turn
/// layered over it (M5 — the streaming message and tool executions), its
/// view projection and transcript rows, the expansion state Find needs
/// (collapsed sections are never searched), the dock state, and the
/// lookups the cards read (jobs, artifacts, graph node names).
@MainActor
@Observable
final class SessionModel {
	let chatId: String
	let database: AppDatabase
	/// The live service (nil = read-only: tests, previews).
	let service: TurnService?
	private let jobs: JobRepository
	let catalog: ModelCatalog

	private(set) var record: ChatRecord?
	private(set) var view: [ViewMessage] = []
	private(set) var rows: [TranscriptRow] = []
	private(set) var plan: PlanTree?
	private(set) var phase: Phase3 = .probe
	private(set) var missing = false
	let find = FindModel()
	let overlays = SessionOverlays()

	/// Disclosure state by element id (rows and their sub-sections).
	private var openState: [String: Bool] = [:]
	/// This chat's jobs by dispatching tool call (observed: the cards are live).
	private(set) var jobsByToolCall: [String: JobRecord] = [:]
	private var nodeNames: [String: String]?

	// MARK: Live (M5)
	enum Status: Equatable { case idle, submitted, streaming }
	var status: Status = .idle
	/// A turn is running for this chat (ours, a wake, or a resumed one).
	var running = false
	var compacting = false
	/// "Something went wrong: …" (a turn error or a refused request).
	var errorText: String?
	/// The last send was refused for a missing key (the "Add a key" pill).
	var needsKey = false
	var draft = ""
	var queuedSteers: [Message] = []
	/// The streaming assistant snapshot (not yet persisted).
	var streaming: Message?
	var executions: [String: LiveExecution] = [:]
	var following = false
	var isAtBottom = true
	/// Where the view actually is, from its geometry on every change — unlike
	/// the sticky `isAtBottom`, content growing past the window clears it.
	/// A new question arrives open only when this holds.
	var viewAtBottom = true
	/// Teach checks opened from their "Check your understanding" bar, by call id.
	var revealedChecks: Set<String> = []
	/// Paragraph notes not yet sent, by paragraph row id (an open field is a
	/// key); they ride on the next answer or dismissal.
	var noteDrafts: [String: String] = [:]
	/// Sent paragraph notes by paragraph row id (the record's answers).
	private(set) var sentNotes: [String: [String]] = [:]
	/// The streaming message's row-id prefix: its paragraphs aren't settled, so take no notes.
	private(set) var unsettledRowPrefix: String?
	var lastPendingId: String?
	/// Set to scroll the transcript to a row (the "Question below" pill).
	var rowRequest: AnchorRequest?
	/// The question set aside to ask about it (its origin call id): its re-posed copy arrives open.
	var discussedOrigin: String?
	/// What the learner had started in a question card, by origin call id — a set-aside card leaves
	/// the dock while the teacher replies and gets it back when it's re-posed.
	var cardDrafts: [String: QuestionCardDraft] = [:]
	/// Cards that have taken the focus once (an inline card scrolled back into view doesn't again).
	var focusedCards: Set<String> = []
	// Practice (M8): the dock's thinking draft and fold.
	var practiceThinking = ""
	var problemDockExpanded = true

	init(chatId: String, database: AppDatabase, dataDirectory: URL, catalog: ModelCatalog, service: TurnService? = nil) {
		self.chatId = chatId
		self.database = database
		self.service = service
		jobs = JobRepository(database, dataDirectory: dataDirectory)
		self.catalog = catalog
	}

	/// Mirror the record (and its jobs) for as long as the session is shown.
	func observe() async {
		let jobsTask = Task { await observeJobs() }
		defer { jobsTask.cancel() }
		do {
			for try await next in ChatRepository(database).observe(chatId) {
				apply(next)
			}
		} catch {
			missing = record == nil
		}
	}

	private func observeJobs() async {
		do {
			for try await list in jobs.observe(chatId: chatId) {
				jobsByToolCall = Dictionary(list.map { ($0.toolCallId, $0) }, uniquingKeysWith: { a, _ in a })
			}
		} catch {}
	}

	/// One read of the record (no observation) — tests and previews.
	func load() {
		apply(try? ChatRepository(database).get(chatId))
		let list = (try? jobs.listJobs(chatId: chatId)) ?? []
		jobsByToolCall = Dictionary(list.map { ($0.toolCallId, $0) }, uniquingKeysWith: { a, _ in a })
	}

	private func apply(_ next: ChatRecord?) {
		guard let next else {
			record = nil
			missing = true
			rows = []
			return
		}
		missing = false
		record = next
		if let s = streaming, next.messages.contains(where: { $0.id == s.id }) { streaming = nil }
		rebuild()
	}

	/// The projection over the record plus the live layer.
	func rebuild() {
		guard let record else { return }
		var messages = record.messages
		if let s = streaming, !messages.contains(where: { $0.id == s.id }) { messages.append(s) }
		let live = running || status != .idle
			? LiveTurnState(executions: executions, inFlight: true, streamingIds: streaming.map { [$0.id] } ?? [])
			: nil
		view = projectView(messages, live: live)
		rows = transcriptRows(native: messages, view: view, streaming: status == .streaming)
		var sent: [String: [String]] = [:]
		for m in messages {
			guard let details = m.toolResult?.details, let notes = QuestionAnswerData(json: details)?.readingNotes else { continue }
			for n in notes { sent[n.anchor, default: []].append(n.text) }
		}
		sentNotes = sent
		unsettledRowPrefix = status == .streaming ? view.last.map { "\($0.id.isEmpty ? "m-\(view.count - 1)" : $0.id)/" } : nil
		plan = latestTree(view)
		phase = viewPhaseTimeline(view).last ?? .probe
		refreshFindUnits()
		updatePendingArrival()
	}

	var title: String { record?.title ?? "" }

	// MARK: - Anchors (session-navigation: graph links → a message)

	struct AnchorRequest: Equatable {
		var anchor: String
		var nonce = UUID()
	}

	/// Set to scroll the transcript to a native message's first prose block
	/// and flash it (M7's graph links call `scrollTo(messageId:)`).
	private(set) var anchorRequest: AnchorRequest?

	func scrollTo(messageId: String) {
		anchorRequest = AnchorRequest(anchor: messageAnchorId(messageId))
	}

	func rowId(forAnchor request: AnchorRequest) -> String? {
		rows.first { row in
			if case .textBlock(_, let anchor) = row.kind { return anchor == request.anchor }
			return false
		}?.id
	}
	var isPractice: Bool { record?.kind == .practice }

	// MARK: - Disclosure

	func isOpen(_ id: String, default fallback: Bool = false) -> Bool { openState[id] ?? fallback }

	/// ⌘T's last set (thinking-block.tsx): nil = rows run their own defaults.
	private(set) var allUserThinkingOpen: Bool?

	/// ⌘T: every "your thinking" row to one state — transcript rows default
	/// open, so the first press collapses everything, the next re-expands.
	/// An explicit set stomps individual toggles; later rows honor it too.
	func toggleAllUserThinking() {
		let open = !(allUserThinkingOpen ?? true)
		allUserThinkingOpen = open
		for row in rows {
			switch row.kind {
			case .practiceThinking: openState[row.id] = open
			case .answered(let a, _):
				if a.thinking != nil || a.note != nil { openState["\(row.id).thinking"] = open }
				if a.readingThinking != nil, a.readingNotes == nil { openState["\(row.id).reading"] = open }
			default: break
			}
		}
		refreshFindUnits()
	}

	func setOpen(_ id: String, _ open: Bool) {
		openState[id] = open
		refreshFindUnits()
	}

	// MARK: - Lookups

	/// The job a dispatch box reports on (matched by tool call id).
	func job(toolCallId: String) -> JobRecord? { jobsByToolCall[toolCallId] }

	/// The demo/figure card's invert toggle, persisted to `message_ui`.
	func setInverted(_ inverted: Bool, messageId: String) {
		try? ChatRepository(database).setArtifactInverted(inverted, messageId: messageId, chatId: chatId)
	}

	/// A delivered artifact's text: inline (imported steers) or its file.
	func artifactText(_ result: JSONValue, key: String) -> String? {
		if let inline = result[key]?.stringValue { return inline }
		return try? jobs.artifactText(for: result)
	}

	/// Graph node id → name, read once (the conclude card's targets).
	func nodeName(_ id: String) -> String {
		if nodeNames == nil {
			var names: [String: String] = [:]
			for node in GraphRepository(database).readNodes() { names[node.id] = node.name }
			nodeNames = names
		}
		return nodeNames?[id] ?? id
	}

	// MARK: - Find

	/// The visible units, row by row (matches never cross units).
	private func refreshFindUnits() {
		var units: [FindModel.Unit] = []
		func add(_ list: [FindUnit], _ row: String) { units += list.map { FindModel.Unit(unit: $0, rowId: row) } }
		func plain(_ id: String, _ text: String, _ row: String) { add([FindUnit(id: id, text: text, preformatted: false)], row) }
		for row in rows {
			let id = row.id
			switch row.kind {
			case .userBand(let text):
				plain("\(id).text", text, id)
			case .textBlock(let block, _):
				add(findUnits([block], prefix: id), id)
			case .reasoning(let text, _):
				if isOpen(id) { add(findUnits(MarkdownCache.blocks(text), prefix: "\(id).body"), id) }
			case .practiceThinking(let text):
				if isOpen(id, default: allUserThinkingOpen ?? true) { plain("\(id).text", text, id) }
			case .answered(let answer, let input):
				add(answeredUnits(answer, input: input, id: id), id)
			case .tool(let part):
				add(toolUnits(part, id: id), id)
			case .steer(let m):
				if isOpen(id), let brief = m.parts.first(where: { $0.type == "data-subagent-artifact" })?.data?["result"]?["brief"]?.stringValue {
					add(findUnits(MarkdownCache.blocks(brief), prefix: "\(id).brief"), id)
				}
			default:
				break
			}
		}
		find.setUnits(units)
	}

	private func answeredUnits(_ a: QuestionAnswerData, input: JSONValue?, id: String) -> [FindUnit] {
		var out = findUnits(MarkdownCache.blocks(a.questionText), prefix: "\(id).q")
		if a.dismissed == true { return out }
		if let details = answeredDetails(a, input: input) { out += findUnits(MarkdownCache.blocks(details), prefix: "\(id).d") }
		for o in a.options ?? [] { out += findUnits(MarkdownCache.blocks(o.label), prefix: "\(id).o\(o.index)") }
		if a.kind == .quiz, let why = a.explanation, isOpen("\(id).why") { out += findUnits(MarkdownCache.blocks(why), prefix: "\(id).why") }
		if a.kind == .explain, let committed = a.committed { out += findUnits(MarkdownCache.blocks(committed), prefix: "\(id).c") }
		return out
	}

	private func toolUnits(_ part: ViewPart, id: String) -> [FindUnit] {
		switch part.toolName {
		case "problem":
			let statement = part.input?["statement"]?.stringValue ?? ""
			return findUnits(MarkdownCache.blocks(repairMathForDisplay(statement)), prefix: "\(id).s")
		case "conclude":
			let verdict = part.input?["verdict"]?.stringValue ?? ""
			let reveal = part.reveal ?? part.input?["solutionReveal"]?.stringValue ?? ""
			return findUnits(MarkdownCache.blocks(repairMathForDisplay(verdict)), prefix: "\(id).v")
				+ findUnits(MarkdownCache.blocks(repairMathForDisplay(reveal)), prefix: "\(id).r")
		default:
			return []
		}
	}
}

/// The details line an answered card shows (parsed from the call input).
func answeredDetails(_ a: QuestionAnswerData, input: JSONValue?) -> String? {
	guard let input else { return nil }
	switch a.kind {
	case .ask: return parseAskInput(input)?.details
	case .quiz: return parseQuizInput(input)?.details
	default: return nil
	}
}

/// The session-scoped focus overlays (session-overlay.tsx): the live diagram
/// or figure, and the plan popup. One at a time, over the detail column.
@MainActor
@Observable
final class SessionOverlays {
	struct Diagram: Equatable {
		var svg: String
		var size: CGSize
		var figure: Bool
		var inverted: Bool
	}

	var diagram: Diagram?
	var planOpen = false
	/// Session → Model and Effort… (⌘K): the status bar's picker popover.
	var modelPickerOpen = false

	func openDiagram(svg: String, size: CGSize, figure: Bool, inverted: Bool) {
		planOpen = false
		diagram = Diagram(svg: svg, size: size, figure: figure, inverted: inverted)
	}

	func openPlan() {
		diagram = nil
		planOpen = true
	}

	/// Esc: the topmost overlay closes; true when one did.
	@discardableResult
	func closeTop() -> Bool {
		if diagram != nil {
			diagram = nil
			return true
		}
		if planOpen {
			planOpen = false
			return true
		}
		return false
	}
}

extension SessionModel {
	/// A paragraph row takes notes: the teacher's settled prose, outside practice.
	func takesNotes(_ rowId: String) -> Bool {
		!isPractice && !(unsettledRowPrefix.map(rowId.hasPrefix) ?? false)
	}
}
