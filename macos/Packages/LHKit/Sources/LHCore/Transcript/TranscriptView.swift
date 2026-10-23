import Foundation

// Port of src/core/view.ts — the transcript view model: native record
// messages (+ the live turn's working messages) grouped into the render
// shape. Everything the agent produces is ONE continuous document per run:
// step separators between the loop's steps, cards inline.
//
// GROUPING RULE: one assistant view message per GROUP — consecutive
// assistant + toolResult messages, bounded by user/marker messages;
// toolResults attach to the tool part of their call (searching backward);
// a group's id is its FIRST assistant message's id.
//
// Plan blocks splice into the preceding assistant group, right after the
// last successful plan_init call. Question tools: a clean placeholder
// execution/ack never flips the part to output-available.
//
// Pure and deterministic: same input → same view.

/// A view part's kind — the same `type` strings as the TS parts.
public enum ViewPartKind: Sendable, Hashable {
	case text
	case reasoning
	/// "step-start" — the separator between a run's steps.
	case stepStart
	/// "tool-<name>"
	case tool(String)
	/// "data-<name>" (compaction, compaction-cut, graph-context, …)
	case data(String)

	public init?(type: String) {
		switch type {
		case "text": self = .text
		case "reasoning": self = .reasoning
		case "step-start": self = .stepStart
		default:
			if type.hasPrefix("tool-") { self = .tool(String(type.dropFirst("tool-".count))) }
			else if type.hasPrefix("data-") { self = .data(String(type.dropFirst("data-".count))) }
			else { return nil }
		}
	}

	public var type: String {
		switch self {
		case .text: "text"
		case .reasoning: "reasoning"
		case .stepStart: "step-start"
		case .tool(let name): "tool-\(name)"
		case .data(let name): "data-\(name)"
		}
	}
}

/// Part states: "done" for text/reasoning; the tool lifecycle otherwise.
public enum ViewPartState: String, Sendable, Hashable {
	case done
	case inputStreaming = "input-streaming"
	case inputAvailable = "input-available"
	case outputAvailable = "output-available"
	case outputError = "output-error"
}

/// One view part — the loose part vocabulary the renderers consume.
public struct ViewPart: Sendable, Hashable {
	public var kind: ViewPartKind
	public var id: String?
	public var text: String?
	public var state: ViewPartState?
	public var toolCallId: String?
	public var input: JSONValue?
	public var output: JSONValue?
	public var rawInput: JSONValue?
	public var errorText: String?
	public var data: JSONValue?
	/// Conclude parts: the pose's committed modelSolution.
	public var reveal: String?
	/// Conclude parts: the whole pose-side problem input.
	public var problemInput: JSONValue?

	public init(kind: ViewPartKind, id: String? = nil, text: String? = nil, state: ViewPartState? = nil, toolCallId: String? = nil,
		input: JSONValue? = nil, output: JSONValue? = nil, rawInput: JSONValue? = nil, errorText: String? = nil, data: JSONValue? = nil,
		reveal: String? = nil, problemInput: JSONValue? = nil)
	{
		self.kind = kind
		self.id = id
		self.text = text
		self.state = state
		self.toolCallId = toolCallId
		self.input = input
		self.output = output
		self.rawInput = rawInput
		self.errorText = errorText
		self.data = data
		self.reveal = reveal
		self.problemInput = problemInput
	}

	public var type: String { kind.type }

	/// The tool name for `tool-*` parts.
	public var toolName: String? { if case .tool(let n) = kind { return n }; return nil }

	/// The TS part object (absent fields dropped, as JSON.stringify drops undefined).
	public var json: JSONValue {
		var o = JSONObject(["type": .string(type)])
		if let id { o["id"] = .string(id) }
		if let text { o["text"] = .string(text) }
		if let state { o["state"] = .string(state.rawValue) }
		if let toolCallId { o["toolCallId"] = .string(toolCallId) }
		if let input { o["input"] = input }
		if let output { o["output"] = output }
		if let rawInput { o["rawInput"] = rawInput }
		if let errorText { o["errorText"] = .string(errorText) }
		if let data { o["data"] = data }
		if let reveal { o["reveal"] = .string(reveal) }
		if let problemInput { o["problemInput"] = problemInput }
		return .object(o)
	}
}

/// A view message: user (bubble/card) or assistant (one continuous run).
public struct ViewMessage: Sendable, Hashable, Identifiable {
	public enum Role: String, Sendable, Hashable {
		case user, assistant
	}

	public var id: String
	public var role: Role
	public var parts: [ViewPart]
	/// The subagentResult meta the steer cards read (marker details).
	public var metadata: JSONValue?

	public init(id: String, role: Role, parts: [ViewPart], metadata: JSONValue? = nil) {
		self.id = id
		self.role = role
		self.parts = parts
		self.metadata = metadata
	}

	public var json: JSONValue {
		var o = JSONObject(["id": .string(id), "role": .string(role.rawValue), "parts": .array(parts.map(\.json))])
		if let metadata { o["metadata"] = metadata }
		return .object(o)
	}
}

/// A tool call's live execution outcome (from tool_execution_end).
public struct LiveExecution: Sendable, Hashable {
	public var isError: Bool
	/// The clean result's details payload (the card's output).
	public var output: JSONValue?
	/// The failure text (output-error parts).
	public var errorText: String?

	public init(isError: Bool, output: JSONValue? = nil, errorText: String? = nil) {
		self.isError = isError
		self.output = output
		self.errorText = errorText
	}
}

/// The live turn's execution layer, maintained by the session.
public struct LiveTurnState: Sendable, Hashable {
	/// toolUseId → its execution outcome seen so far.
	public var executions: [String: LiveExecution]
	/// True while the turn runs.
	public var inFlight: Bool
	/// Ids of the messages THIS turn is streaming: an arrived-but-empty
	/// streaming message projects one empty reasoning part (the thinking
	/// row); a call renders input-streaming only inside one of these.
	public var streamingIds: Set<String>

	public init(executions: [String: LiveExecution] = [:], inFlight: Bool, streamingIds: Set<String> = []) {
		self.executions = executions
		self.inFlight = inFlight
		self.streamingIds = streamingIds
	}
}

private func textPart(_ text: String) -> ViewPart {
	ViewPart(kind: .text, text: text, state: .done)
}

/// Project the native record (+ live turn) into the view messages.
public func projectView(_ messages: [Message], live: LiveTurnState? = nil) -> [ViewMessage] {
	var out: [ViewMessage] = []

	/// NEWEST-FIRST scan: a result pairs with the most RECENT call carrying
	/// its id (legacy duplicate-id records route each answer to its own call).
	func findToolPart(_ toolUseId: String) -> (Int, Int)? {
		for i in out.indices.reversed() {
			for p in out[i].parts.indices.reversed() {
				let part = out[i].parts[p]
				if part.toolName != nil, part.toolCallId == toolUseId { return (i, p) }
			}
		}
		return nil
	}

	// The active compaction: the CUT DIVIDER renders immediately BEFORE the
	// first kept message (full history stays visible to the user).
	let compaction = activeCompactionOf(messages)

	for m in messages {
		if let compaction, m.id == compaction.firstKeptMessageId {
			out.append(ViewMessage(id: "cut_\(compaction.id)", role: .user, parts: [
				ViewPart(kind: .data("compaction-cut"), id: "cc_\(compaction.id)", data: ["content": .string(compaction.content), "details": compaction.details]),
			]))
		}

		switch m.body {
		case .user(let u):
			out.append(ViewMessage(id: m.id, role: .user, parts: u.content.filter { $0.type == "text" }.map { b in
				ViewPart(kind: .text, text: b.raw["text"]?.stringValue, state: .done)
			}))

		case .marker(let marker):
			projectMarker(marker, id: m.id, into: &out)

		case .toolResult(let result):
			if let (i, p) = findToolPart(result.toolUseId) { applyResult(to: &out[i].parts[p], result) }
			// A result with no visible part is dropped from the view.

		case .assistant(let a):
			// Reasoning ALWAYS renders above its message: stable-partition,
			// reasoning parts first (their own order kept), then the rest.
			var rest: [ViewPart] = []
			var reasoning: [ViewPart] = []
			var textN = 0
			var reasoningN = 0
			// LIVE IS POSITIVE EVIDENCE: a call renders live ONLY when its own
			// message is streaming this turn.
			let streamingMessage = live?.streamingIds.contains(m.id) == true
			for block in a.content {
				switch block.type {
				case "text":
					rest.append(ViewPart(kind: .text, id: "\(m.id)-t\(textN)", text: block.raw["text"]?.stringValue, state: .done))
					textN += 1
				case "thinking", "redacted_thinking":
					let text = block.type == "thinking" ? block.raw["thinking"]?.stringValue : REDACTED_THINKING_TEXT
					reasoning.append(ViewPart(kind: .reasoning, id: "\(m.id)-r\(reasoningN)", text: text, state: .done))
					reasoningN += 1
				case "tool_use":
					guard let call = block.toolUse else { continue }
					var part = toolPart(call, live: live, streamingMessage: streamingMessage)
					// The conclusion's reveal join: the pose's committed solution.
					if call.name == PRACTICE_CONCLUDE_TOOL {
						part.reveal = modelSolutionForConclude(messages, concludeCallId: call.id)
						part.problemInput = problemInputForConclude(messages, concludeCallId: call.id)
					}
					rest.append(part)
				default:
					continue
				}
			}
			var parts = reasoning + rest
			if parts.isEmpty {
				// An arrived-but-silent STREAMING message renders the thinking
				// row; settled empty messages stay hidden.
				guard live?.streamingIds.contains(m.id) == true else { continue }
				parts.append(ViewPart(kind: .reasoning, id: "\(m.id)-r0", text: "", state: .done))
			}
			if let last = out.indices.last, out[last].role == .assistant {
				out[last].parts.append(ViewPart(kind: .stepStart))
				out[last].parts.append(contentsOf: parts)
			} else {
				out.append(ViewMessage(id: m.id, role: .assistant, parts: [ViewPart(kind: .stepStart)] + parts))
			}
		}
	}
	return out
}

/// The dock-owned tools: question tools plus the practice pose — a clean
/// placeholder result never flips them to output-available.
private func isPlaceholderResultTool(_ name: String) -> Bool {
	QUESTION_TOOLS.contains(name) || name == PRACTICE_PROBLEM_TOOL
}

/// A tool_use block → its view part, with the live execution layer.
private func toolPart(_ call: ToolUse, live: LiveTurnState?, streamingMessage: Bool) -> ViewPart {
	var part = ViewPart(kind: .tool(call.name), toolCallId: call.id, input: call.input)
	if let exec = live?.executions[call.id] {
		if exec.isError {
			// An invalid call NEVER becomes input-available (the dock's mount gate).
			part.state = .outputError
			part.rawInput = call.input
			part.errorText = exec.errorText ?? "The tool call failed."
		} else if isPlaceholderResultTool(call.name) {
			// The clean "Question posed" placeholder is IGNORED.
			part.state = .inputAvailable
		} else {
			part.state = .outputAvailable
			part.output = exec.output
		}
	} else {
		// No execution yet: live ONLY on positive evidence.
		part.state = streamingMessage ? .inputStreaming : .inputAvailable
	}
	return part
}

/// Apply a native toolResult to its call's part.
private func applyResult(to part: inout ViewPart, _ result: ToolResultBody) {
	let tool = part.toolName ?? part.type
	// Null details read as absent (the native record has no null payload;
	// see scripts/core-golden/transcript.ts's normalization note).
	// (No `? nil :` ternary: JSONValue is ExpressibleByNilLiteral, so that
	// `nil` would type as `.null`.)
	var details: JSONValue? = result.details
	if details?.isNull == true { details = Optional<JSONValue>.none }
	if isPlaceholderResultTool(tool), !result.isError, details == nil {
		// The clean pose/ask ack carries no card data — never
		// output-available, but the call IS settled.
		part.state = .inputAvailable
		return
	}
	if result.isError {
		part.state = .outputError
		part.rawInput = part.input
		part.errorText = result.firstText ?? "The tool call failed."
	} else {
		part.state = .outputAvailable
		part.output = details
	}
}

/// The newest successful plan_init part (`output.ok === true`), or -1.
private func lastSuccessfulPlanInit(_ parts: [ViewPart]) -> Int {
	var idx = -1
	for (i, p) in parts.enumerated() where p.toolName == "plan_init" {
		if p.output?["ok"]?.boolValue == true { idx = i }
	}
	return idx
}

/// A marker's projected message (handoff/steers/cards) or splice (plan block).
private func projectMarker(_ marker: MarkerBody, id: String, into out: inout [ViewMessage]) {
	func card(_ name: String, _ prefix: String, _ data: JSONValue) {
		out.append(ViewMessage(id: id, role: .user, parts: [ViewPart(kind: .data(name), id: "\(prefix)_\(id)", data: data)]))
	}
	switch marker.kind {
	case .graphContext:
		card("graph-context", "gc", marker.details)
	case .probeHandoff:
		card("probe-handoff", "ph", marker.details)
	case .subagentSteer:
		var artifact = JSONObject()
		for key in ["kind", "result", "ui"] {
			if let v = marker.details[key] { artifact[key] = v }
		}
		out.append(ViewMessage(id: id, role: .user, parts: [
			textPart(marker.content),
			ViewPart(kind: .data("subagent-artifact"), id: "sa_\(id)", data: .object(artifact)),
		], metadata: ["subagentResult": marker.details]))
	case .subagentAbort:
		out.append(ViewMessage(id: id, role: .user, parts: [
			textPart(marker.content),
			ViewPart(kind: .data("subagent-aborted"), id: "sa_\(id)", data: marker.details),
		], metadata: ["subagentResult": marker.details]))
	case .practiceThinking:
		card("practice-thinking", "pt", marker.details)
	case .practiceNext:
		// The label is chrome, single-sourced in the renderer.
		card("practice-next", "pn", .null)
	case .problemDismissed:
		// UI-only: the synthesized conclude pair carries the record's face.
		return
	case .compaction:
		// THE MOMENT DIVIDER at the compaction moment (the record's tail).
		card("compaction", "cm", ["content": .string(marker.content), "details": marker.details])
	case .planBlock:
		// No message of its own: splice after the group's last successful plan_init.
		guard let g = out.indices.last, out[g].role == .assistant else { return }
		let idx = lastSuccessfulPlanInit(out[g].parts)
		if idx == -1 { return }
		out[g].parts.insert(ViewPart(kind: .data("plan-block"), id: id, data: marker.details["block"]), at: idx + 1)
	}
}
