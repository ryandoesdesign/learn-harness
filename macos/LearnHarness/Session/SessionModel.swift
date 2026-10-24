import Foundation
import LHCore
import LHMarkdown
import LHStore
import Observation

/// One open session, read-only in M4: the record (observed from the
/// store), its view projection and transcript rows, the expansion state
/// Find needs (collapsed sections are never searched), and the lookups the
/// cards read (jobs, artifacts, graph node names).
@MainActor
@Observable
final class SessionModel {
	let chatId: String
	private let database: AppDatabase
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
	private var jobCache: [String: JobRecord?] = [:]
	private var nodeNames: [String: String]?

	init(chatId: String, database: AppDatabase, dataDirectory: URL, catalog: ModelCatalog) {
		self.chatId = chatId
		self.database = database
		jobs = JobRepository(database, dataDirectory: dataDirectory)
		self.catalog = catalog
	}

	/// Mirror the record for as long as the session is shown.
	func observe() async {
		do {
			for try await next in ChatRepository(database).observe(chatId) {
				apply(next)
			}
		} catch {
			missing = record == nil
		}
	}

	/// One read of the record (no observation) — tests and previews.
	func load() {
		apply(try? ChatRepository(database).get(chatId))
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
		view = projectView(next.messages)
		rows = transcriptRows(native: next.messages, view: view)
		plan = latestTree(view)
		phase = viewPhaseTimeline(view).last ?? .probe
		jobCache.removeAll()
		refreshFindUnits()
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

	func setOpen(_ id: String, _ open: Bool) {
		openState[id] = open
		refreshFindUnits()
	}

	// MARK: - Lookups

	/// The job a dispatch box reports on (matched by tool call id).
	func job(toolCallId: String) -> JobRecord? {
		if let hit = jobCache[toolCallId] { return hit }
		let job = try? jobs.findJob(chatId: chatId, toolCallId: toolCallId)
		jobCache[toolCallId] = job
		return job
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
			case .reasoning(let text):
				if isOpen(id) { add(findUnits(MarkdownCache.blocks(text), prefix: "\(id).body"), id) }
			case .practiceThinking(let text):
				if isOpen(id, default: true) { plain("\(id).text", text, id) }
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
