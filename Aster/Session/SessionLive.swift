import Foundation
import LHAgent
import LHCore
import LHStore

/// The live session (port of components/session-core.ts as a native model):
/// follow the running turn's events into the streaming layer, send / steer /
/// answer / dismiss / abort through the TurnService, and derive the dock's
/// pending question and arrival state.
extension SessionModel {
	/// The open question (only when no turn runs — a question being written
	/// is a live tool row, never the dock).
	var pending: (toolCallId: String, tool: String, input: JSONValue)? {
		guard !running, status == .idle, let record else { return nil }
		return danglingQuestionOf(record.messages)
	}

	/// A teach-phase check arrives behind the reveal bar (questionNeedsReveal).
	var requiresReveal: Bool {
		guard let p = pending else { return false }
		return questionNeedsReveal(tool: p.tool, rawInput: p.input, phase: phase.rawValue)
	}

	var busy: Bool { running || status != .idle }

	/// The active practice problem (activeProblemOf): its call id and the
	/// statement as displayed. The practice dock replaces the composer.
	var activeProblem: (toolCallId: String, statement: String)? {
		guard isPractice, let record, let p = activeProblemOf(record.messages) else { return nil }
		return (p.toolCallId, repairMathForDisplay(restoreLiteralNewlines(p.input["statement"]?.stringValue ?? "")))
	}

	/// The practice pause: idle, nothing active, and a problem has been posed
	/// cleanly — the composer's button becomes Next Problem.
	var nextReady: Bool {
		guard isPractice, !busy, let record, activeProblemOf(record.messages) == nil else { return false }
		return hasPosedProblem(record.messages)
	}

	/// TS canSend: text present, not compacting. With a question open, the text asks about it.
	var canSend: Bool { !draft.jsTrimmed.isEmpty && !compacting }

	// MARK: Open / follow

	/// On open: the record, the resume rule, then follow any running turn.
	func start() async {
		guard let service else { return }
		running = await service.isRunning(chatId)
		compacting = await service.isCompacting(chatId)
		queuedSteers = await service.queuedSteers(chatId)
		if !running {
			await service.resumeIfNeeded(chatId)
			running = await service.isRunning(chatId)
		}
		if running { follow() }
	}

	/// A turn started (ours, a wake, a resume): attach to its live stream.
	func follow() {
		guard let service, !following else { return }
		following = true
		running = true
		if status == .idle { status = .submitted }
		Task { @MainActor in
			defer { following = false }
			guard let events = await service.live(chatId) else {
				settleLive()
				return
			}
			for await event in events { apply(event) }
			settleLive()
			queuedSteers = await service.queuedSteers(chatId)
		}
	}

	private func apply(_ event: AgentEvent) {
		switch event {
		case .messageStart(let m), .messageUpdate(let m):
			guard m.assistant != nil else { return }
			streaming = m
			if status != .streaming, !(m.assistant?.content.isEmpty ?? true) { status = .streaming }
			rebuild()
		case .messageEnd(let m):
			if m.assistant != nil, streaming?.id == m.id { streaming = m }
			rebuild()
		case .toolEnd(let id, let output):
			executions[id] = LiveExecution(isError: output.isError, output: output.details, errorText: output.isError ? output.content.first?.raw["text"]?.stringValue : nil)
			rebuild()
		case .agentEnd(let outcome):
			if let failed = outcome.newMessages.last?.assistant, failed.stopReason == "error" {
				errorText = failed.errorMessage ?? "The turn failed."
			}
		case .settled(let m):
			if m.id.hasPrefix("steer_") { queuedSteers.removeAll { $0.id == m.id } }
		default:
			break
		}
	}

	private func settleLive() {
		running = false
		status = .idle
		executions = [:]
		streaming = nil
		load()
	}

	// MARK: Actions

	/// The composer's send: a steer while busy, a message about the open
	/// question when one is open, otherwise a turn.
	func sendDraft() {
		let text = draft
		guard !text.jsTrimmed.isEmpty, service != nil else { return }
		draft = ""
		if let p = pending { discuss(text, toolCallId: p.toolCallId) } else { sendText(text) }
	}

	/// Ask about the open question instead of answering it: it is set aside,
	/// the teacher replies, and it comes back open (Discuss.swift).
	private func discuss(_ text: String, toolCallId: String) {
		guard let service else { return }
		errorText = nil
		needsKey = false
		discussedOrigin = reposeOrigin(toolCallId)
		status = .submitted
		Task {
			do {
				try await service.send(chatId, .discuss(toolCallId: toolCallId, text: text))
				follow()
			} catch {
				status = .idle
				discussedOrigin = nil
				refused(error, draft: text)
			}
		}
	}

	/// Send `text` as the learner (the composer, the demo chip's "Send to
	/// teacher"): a steer while busy, otherwise a turn.
	func sendText(_ text: String) {
		guard !text.jsTrimmed.isEmpty, let service else { return }
		errorText = nil
		needsKey = false
		if busy {
			Task {
				do {
					switch try await service.steer(chatId, text: text) {
					case .queued: queuedSteers = await service.queuedSteers(chatId)
					case .sent: follow()
					}
				} catch {
					refused(error, draft: text)
				}
			}
			return
		}
		status = .submitted
		Task {
			do {
				try await service.send(chatId, .text(text))
				follow()
			} catch {
				status = .idle
				refused(error, draft: text)
			}
		}
	}

	/// The answer is the question call's tool result (one input, one turn).
	func submitAnswer(_ answer: QuestionAnswerData, toolCallId: String) {
		guard let service else { return }
		var a = answer
		let reading = readingThinking.jsTrimmed
		if !reading.isEmpty { a.readingThinking = reading }
		readingThinking = ""
		status = .submitted
		Task {
			do {
				switch try await service.send(chatId, .answer(toolCallId: toolCallId, answer: a)) {
				case .started: follow()
				case .saved:
					// A sibling question stays open: it arrives right after this one.
					status = .idle
					updatePendingArrival()
				}
			} catch {
				status = .idle
				refused(error, draft: nil)
			}
		}
	}

	/// Esc → "Dismiss this question?" → Dismiss.
	func dismissPending() {
		guard let service, let p = pending, let record else { return }
		let text = dockQuestion(tool: p.tool, toolCallId: p.toolCallId, input: p.input)?.question
			?? record.messages.last?.assistant?.toolUses.first?.input["question"]?.stringValue ?? ""
		var a = dismissedAnswer(toolQuestionKind(p.tool), questionText: text)
		let reading = readingThinking.jsTrimmed
		if !reading.isEmpty { a.readingThinking = reading }
		readingThinking = ""
		Task {
			do { try await service.dismiss(chatId, toolCallId: p.toolCallId, answer: a) } catch { refused(error, draft: nil) }
			load()
		}
	}

	/// Practice: send the thinking on the active problem — a steer while a
	/// turn runs (docs/native-macos-m8.md), otherwise a turn.
	func submitThinking() {
		let text = practiceThinking
		guard let service, let problem = activeProblem, !text.jsTrimmed.isEmpty, !compacting else { return }
		practiceThinking = ""
		errorText = nil
		needsKey = false
		if !busy { status = .submitted }
		Task {
			do {
				switch try await service.submitThinking(chatId, problemCallId: problem.toolCallId, text: text) {
				case .queued: queuedSteers = await service.queuedSteers(chatId)
				case .sent: follow()
				}
			} catch {
				if status == .submitted, !running { status = .idle }
				if practiceThinking.isEmpty { practiceThinking = text }
				refused(error, draft: nil)
			}
		}
	}

	/// Practice: the learner's go-ahead for the next problem.
	func requestNext() {
		guard let service, nextReady else { return }
		errorText = nil
		status = .submitted
		Task {
			do {
				try await service.send(chatId, .next)
				follow()
			} catch {
				status = .idle
				refused(error, draft: nil)
			}
		}
	}

	/// Esc → "Discard this problem?" → Discard (no solution is revealed).
	func discardProblem() {
		guard let service, let problem = activeProblem else { return }
		practiceThinking = ""
		Task {
			do { try await service.dismissProblem(chatId, problemCallId: problem.toolCallId) } catch { refused(error, draft: nil) }
			load()
		}
	}

	/// The toolbar title's rename (empty or unchanged titles are discarded).
	func rename(_ title: String) {
		let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !t.isEmpty, t != record?.title else { return }
		try? ChatRepository(database).rename(chatId, title: t)
	}

	/// ModelControl: this session's model and effort (clamped to the model).
	func setModel(_ model: String, effort: Effort?) {
		let supported = catalog.model(model)?.efforts ?? []
		let e = effort.map { clampEffort($0, supported: supported) }
		try? ChatRepository(database).saveSettings(ChatSettings(model: model, effort: e), chatId: chatId)
	}

	/// The session's resolved model + effort (the chat's own over the Strong slot).
	var conversationSpec: EffectiveModelSpec {
		let settings = (try? SettingsRepository(database).read()) ?? nil
		return resolveConversationSpec(record?.settings, strong: settings?.models?.strong, catalog: catalog)
	}

	/// Esc → "Abort this turn?" → Abort (the partial stays).
	func abortTurn() {
		guard let service else { return }
		Task { await service.abort(chatId) }
	}

	private func refused(_ error: Error, draft: String?) {
		if case TurnService.Refusal.noKey = error {
			needsKey = true
			if let draft { self.draft = draft }
			return
		}
		if let draft, self.draft.isEmpty { self.draft = draft }
		errorText = "\(error)"
	}

	// MARK: Dock arrival

	func updatePendingArrival() {
		let id = pending?.toolCallId
		guard id != lastPendingId else { return }
		// While an answer is in flight the question is gone from view, but a
		// sibling may follow it directly — keep the previous id until the
		// turn actually runs (or the sibling arrives).
		if id == nil, status == .submitted { return }
		lastPendingId = id
		guard let id else { return }
		// A re-posed question picks up where the learner left it: open, reading thinking kept.
		if reposeOrigin(id) == discussedOrigin {
			discussedOrigin = nil
			dockExpanded = true
			revealed = true
			return
		}
		discussedOrigin = nil
		// The view's real position (your rule): reading content that grew past
		// the window means not at the bottom, even while following is sticky.
		let arrival = questionArrival(atBottom: viewAtBottom)
		dockExpanded = arrival.expanded
		revealed = arrival.revealed
		readingThinking = ""
	}

	/// Open the folded dock (reveals a teach check).
	func expandDock() {
		dockExpanded = true
		revealed = true
	}
}

/// How a new question arrives (your rule, 2026-10-24 — replaces the TS
/// revealArrival/probeArrivalExpanded pair): expanded when the view is at
/// the bottom of the conversation, folded otherwise — every kind alike (a
/// folded teach check shows "Check your understanding"). "At the bottom" is
/// where the view really is (`viewAtBottom`): reading prose that grew past
/// the window folds the question even though following stays on.
func questionArrival(atBottom: Bool) -> (expanded: Bool, revealed: Bool) {
	(atBottom, atBottom)
}

/// composer.tsx enterAction.
enum EnterAction: Equatable { case stop, send, next, none }

func enterAction(busy: Bool, canSend: Bool, nextProblem: Bool = false) -> EnterAction {
	if busy { return canSend ? .send : .stop }
	if canSend { return .send }
	if nextProblem { return .next }
	return .none
}

/// chat.tsx escAbortTarget (the layered Esc).
enum EscTarget: Equatable { case diagram, plan, setup, question, problem, turn }

func escAbortTarget(abortAsk: Bool, diagram: Bool, plan: Bool, setup: Bool, pending: Bool, problem: Bool, busy: Bool) -> EscTarget? {
	if abortAsk { return nil }
	if diagram { return .diagram }
	if plan { return .plan }
	if setup { return .setup }
	if pending { return .question }
	if problem { return .problem }
	if busy { return .turn }
	return nil
}

/// abort-turn-dialog.tsx COPY.
enum AbortMode: Equatable {
	case turn, question, problem

	var title: String {
		switch self {
		case .turn: "Abort this turn?"
		case .question: "Dismiss this question?"
		case .problem: "Discard this problem?"
		}
	}

	func line(busy: Bool) -> String {
		let base = switch self {
		case .turn: "The partial answer stays in the transcript."
		case .question: "Skipped — the teacher moves on without it."
		case .problem: "The problem is dropped — no solution is revealed."
		}
		return base + (busy && self != .turn ? " The working turn stops too." : "")
	}

	var action: String {
		switch self {
		case .turn: "Abort"
		case .question: "Dismiss"
		case .problem: "Discard"
		}
	}
}
