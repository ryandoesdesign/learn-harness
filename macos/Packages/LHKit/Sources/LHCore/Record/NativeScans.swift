import Foundation

// Port of src/core/native-messages.ts — the record scans and marker
// constructors. The wire projection (toLlmMessages) is M3's WireProjection.

/// The hard-invariant wording for an aborted turn's unanswered calls.
public let INTERRUPTED_TEXT = "The question was interrupted — the learner never answered; continue without holding a result for it."

/// The practice agent's two tools.
public let PRACTICE_PROBLEM_TOOL = "problem"
public let PRACTICE_CONCLUDE_TOOL = "conclude"

/// One picked proposition of the graph-context marker.
public struct GraphContextPick: Sendable, Hashable, Codable {
	public var id: String
	public var name: String
	public var statement: String
	public init(id: String, name: String, statement: String) {
		self.id = id
		self.name = name
		self.statement = statement
	}
}

// MARK: - Constructors

/// A learner-authored user message.
public func newUserMessage(_ text: String, id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	Message(id: id, timestamp: now, body: .user(UserBody(content: [.text(text)])))
}

/// A steered user message with the client-minted steer id.
public func newUserSteer(_ text: String, id: String, now: Int = MessageID.nowMillis()) -> Message {
	newUserMessage(text, id: id, now: now)
}

/// The plan presentation block — UI-only (filtered from the wire).
public func newPlanBlockMessage(planCallId: String, block: JSONValue, now: Int = MessageID.nowMillis()) -> Message {
	let ms = String(now, radix: 36)
	return Message(id: "pb_\(ms)_\(UUID().uuidString.lowercased().prefix(8))", timestamp: now, body: .marker(MarkerBody(
		kind: .planBlock, content: "", display: true, details: ["planCallId": .string(planCallId), "block": block])))
}

/// The session's map context marker (before the learner's first message).
public func newGraphContextMessage(picks: [GraphContextPick], chains: [String], id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	var lines = [
		"[Session context] — picked from the learner's knowledge map when starting this session:",
		"",
		"Propositions (id — name: statement; the problem tool's target field uses these ids):",
	]
	lines += picks.map { "- [\($0.id)] \($0.name): \($0.statement)" }
	if !chains.isEmpty {
		lines += ["", "Reasoning chains among them (premises → conclusion):"]
		lines += chains.map { "- \($0)" }
	}
	let pickJSON: [JSONValue] = picks.map { ["id": .string($0.id), "name": .string($0.name), "statement": .string($0.statement)] }
	return Message(id: id, timestamp: now, body: .marker(MarkerBody(
		kind: .graphContext, content: lines.joined(separator: "\n"), display: true,
		details: ["propositions": .array(pickJSON), "chains": .array(chains.map(JSONValue.string))])))
}

/// The learner's thinking submission (one send lane).
public func newThinkingMessage(problemCallId: String, text: String, id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	Message(id: id, timestamp: now, body: .marker(MarkerBody(
		kind: .practiceThinking, content: "\(THINKING_LABEL):\n\(text)", display: true,
		details: ["problemCallId": .string(problemCallId), "text": .string(text)])))
}

/// The learner's explicit move-on signal.
public func newNextMessage(id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	Message(id: id, timestamp: now, body: .marker(MarkerBody(kind: .practiceNext, content: NEXT_PROBLEM_TEXT, display: true, details: [:])))
}

/// The problem-dismissal marker (UI-only; its model face is the deferred conclude pair).
public func newProblemDismissedMarker(problemCallId: String, id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	Message(id: id, timestamp: now, body: .marker(MarkerBody(
		kind: .problemDismissed, content: "", display: true, details: ["problemCallId": .string(problemCallId)])))
}

/// The dismissal's deferred conclude: a synthetic assistant conclude call
/// plus its ack, prepended to the learner's next input. Call id is
/// deterministic off the problem call id.
public func concludedByDismissalPair(problemCallId: String, now: Int = MessageID.nowMillis()) -> (Message, Message) {
	let callId = "call_conc_\(problemCallId)"
	let assistant = Message(id: MessageID.mint(), timestamp: now, body: .assistant(AssistantBody(
		content: [.toolUse(id: callId, name: PRACTICE_CONCLUDE_TOOL, input: ["outcome": "dismissed"])],
		model: "synthetic:synthetic-conclude", stopReason: "tool_use",
		usage: MessageUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))))
	let result = Message(id: MessageID.mint(), timestamp: now, body: .toolResult(ToolResultBody(
		toolUseId: callId, toolName: PRACTICE_CONCLUDE_TOOL, content: [.text(CONCLUDE_ACK_TEXT)], isError: false,
		details: ["outcome": "dismissed", "problemCallId": .string(problemCallId)])))
	return (assistant, result)
}

// MARK: - Scans

/// Ids of tool calls whose results are clean (not errored).
func cleanToolCallIds(_ messages: [Message]) -> Set<String> {
	var ids = Set<String>()
	for m in messages {
		if let r = m.toolResult, !r.isError { ids.insert(r.toolUseId) }
	}
	return ids
}

/// Every toolResult id in the slice.
func resultIds<C: Collection>(_ messages: C) -> Set<String> where C.Element == Message {
	Set(messages.compactMap { $0.toolResult?.toolUseId })
}

/// The pose-side fold: everything the agent filled into the newest
/// cleanly-acked problem call before this conclude call.
public func problemInputForConclude(_ messages: [Message], concludeCallId: String) -> JSONValue? {
	guard var mi = messages.firstIndex(where: { $0.assistant?.toolUses.contains { $0.id == concludeCallId } ?? false }) else { return nil }
	let clean = cleanToolCallIds(messages)
	while mi >= 0 {
		if let a = messages[mi].assistant {
			for call in a.toolUses.reversed() where call.name == PRACTICE_PROBLEM_TOOL {
				guard clean.contains(call.id) else { continue }
				return call.input.nonNull
			}
		}
		mi -= 1
	}
	return nil
}

/// The conclusion's reveal: the pose's committed modelSolution.
public func modelSolutionForConclude(_ messages: [Message], concludeCallId: String) -> String? {
	problemInputForConclude(messages, concludeCallId: concludeCallId)?["modelSolution"]?.stringValue
}

/// The active problem: the newest cleanly-acked problem call with no clean
/// conclude or dismissal marker after it.
public func activeProblemOf(_ messages: [Message]) -> (toolCallId: String, input: JSONValue)? {
	let clean = cleanToolCallIds(messages)
	for m in messages.reversed() {
		if let marker = m.marker {
			if marker.kind == .problemDismissed { return nil }
			continue
		}
		guard let a = m.assistant else { continue }
		for call in a.toolUses.reversed() {
			if call.name == PRACTICE_CONCLUDE_TOOL {
				if clean.contains(call.id) { return nil }
				continue
			}
			guard call.name == PRACTICE_PROBLEM_TOOL else { continue }
			if clean.contains(call.id) { return (call.id, call.input) }
		}
	}
	return nil
}

/// A problem-dismissal marker waiting for its conclude synthesis → its problem call id.
public func pendingProblemDismissalOf(_ messages: [Message]) -> String? {
	let clean = cleanToolCallIds(messages)
	for m in messages.reversed() {
		if let marker = m.marker {
			if marker.kind == .problemDismissed { return marker.details["problemCallId"]?.stringValue }
			continue
		}
		guard let a = m.assistant else { continue }
		for call in a.toolUses.reversed() {
			if call.name == PRACTICE_CONCLUDE_TOOL || call.name == PRACTICE_PROBLEM_TOOL {
				if clean.contains(call.id) { return nil }
			}
		}
	}
	return nil
}

/// The pending-question gate: the newest assistant message's first
/// question-tool call with no result after it.
public func danglingQuestionOf(_ messages: [Message]) -> (toolCallId: String, tool: String, input: JSONValue)? {
	for mi in messages.indices.reversed() {
		guard let a = messages[mi].assistant else { continue }
		let answered = resultIds(messages[(mi + 1)...])
		for call in a.toolUses where QUESTION_TOOLS.contains(call.name) && !answered.contains(call.id) {
			return (call.id, call.name, call.input)
		}
		return nil
	}
	return nil
}

/// A probe_done call anywhere (any state) means the probe is concluded.
public func hasProbeDone(_ messages: [Message]) -> Bool {
	messages.contains { $0.assistant?.toolUses.contains { $0.name == "probe_done" } ?? false }
}

/// Every toolResult id in the record.
public func answeredCallIds(_ messages: [Message]) -> Set<String> { resultIds(messages) }

private func isDismissedResult(_ m: Message) -> Bool {
	m.toolResult?.details?["dismissed"]?.boolValue == true
}

/// The dismissal pause: the record ends in a user dismissal.
public func endsInDismissal(_ messages: [Message]) -> Bool {
	messages.last.map(isDismissedResult) ?? false
}

/// Does the record end on un-consumed tool results the agent owes a
/// continuation for? (The mount/sync continuation gate.)
public func needsContinuation(_ messages: [Message]) -> Bool {
	guard let last = messages.last, last.toolResult != nil else { return false }
	var start = messages.count - 1
	while start > 0, messages[start - 1].toolResult != nil { start -= 1 }
	if isDismissedResult(last) { return false }
	guard start > 0, let owner = messages[start - 1].assistant else { return false }
	let results = messages[start...].compactMap(\.toolResult)
	// A batch acking a problem pose owes nothing (the pose ended the turn deliberately).
	if results.contains(where: { $0.toolName == PRACTICE_PROBLEM_TOOL && !$0.isError && ($0.details == nil || $0.details!.isNull) }) {
		return false
	}
	let answered = Set(results.map(\.toolUseId))
	let calls = owner.toolUses
	return !calls.isEmpty && calls.allSatisfy { answered.contains($0.id) }
}
