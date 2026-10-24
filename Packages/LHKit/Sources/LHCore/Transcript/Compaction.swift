import Foundation

// Port of src/core/compaction.ts — the context-fitting mechanic.
//
// THE CONTRACT: full history stays persisted in the record. A compaction
// marker (customType "compaction") carries a summary plus the cut
// (firstKeptMessageId); the wire projection sends [summary] + [messages
// from the cut onward] on every request. Token estimation follows pi's law:
// anchor on the provider-reported usage of the last assistant message,
// chars/4 only for messages appended after that anchor.

// MARK: - Constants (the tunables, owner-approved)

/// Kept-recent tail budget: ~20k tokens of verbatim recent transcript
/// always ride after the summary.
public let KEEP_RECENT_TOKENS = 20_000

/// The reserve subtracted from the model's contextWindow when the window
/// (not the user's threshold) is the binding constraint.
public let COMPACTION_RESERVE_TOKENS = 16_384

/// Factory default for the settings threshold.
public let DEFAULT_COMPACTION_THRESHOLD_TOKENS = 150_000

/// Tool-result truncation when serializing the span for the summarizer.
let SUMMARY_TOOL_RESULT_TRUNCATE = 2_000

/// pi's stand-in text for a redacted thinking block (pi-ai stores
/// `thinking: "[Reasoning redacted]"`); the native record keeps the
/// opaque `redacted_thinking` block, so the folds read this text for it.
public let REDACTED_THINKING_TEXT = "[Reasoning redacted]"

// MARK: - Token estimation (usage-anchored, chars/4 only for the tail)

/// Context tokens from a provider-reported usage block (pi's
/// calculateContextTokens): `totalTokens` wins when non-zero, else the sum.
public func calculateContextTokens(totalTokens: Int? = nil, input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil) -> Int {
	if let totalTokens, totalTokens != 0 { return totalTokens }
	return (input ?? 0) + (output ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
}

/// The native usage stamp carries no `totalTokens` (pi's always equalled the
/// field sum), so its context tokens are the sum.
public func calculateContextTokens(_ usage: MessageUsage) -> Int {
	calculateContextTokens(input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite)
}

/// Estimate a message's context tokens from its WIRE-relevant text only
/// (pi's estimator): text + thinking + tool_use name/input for assistants,
/// content text for user/toolResult/marker. Never the whole message's JSON
/// (record scaffolding inflates ~3x). UTF-16 lengths, `ceil(chars / 4)`.
public func estimateMessageTokens(_ message: Message) -> Int {
	var chars = 0
	switch message.body {
	case .assistant(let a):
		for block in a.content {
			switch block.type {
			case "text": chars += block.raw["text"]?.stringValue?.jsLength ?? 0
			case "thinking": chars += block.raw["thinking"]?.stringValue?.jsLength ?? 0
			case "redacted_thinking": chars += REDACTED_THINKING_TEXT.jsLength
			case "tool_use":
				// `arguments ?? {}`: absent or null input counts as "{}".
				var input: JSONValue = .object(JSONObject())
				if let raw = block.raw["input"], !raw.isNull { input = raw }
				chars += (block.raw["name"]?.stringValue?.jsLength ?? 0) + input.serialized().jsLength
			default: break
			}
		}
	case .user(let u): chars = textChars(u.content)
	case .toolResult(let t): chars = textChars(t.content)
	case .marker(let m): chars = m.content.jsLength
	}
	return (chars + 3) / 4
}

/// Any block's string `text` (the TS `type === "text" || "text" in block`).
private func textChars(_ blocks: [Block]) -> Int {
	blocks.reduce(0) { $0 + ($1.raw["text"]?.stringValue?.jsLength ?? 0) }
}

/// The newest assistant message carrying VALID provider usage (skip aborted
/// and all-zero usage). The scan STOPS at the newest compaction marker:
/// usage captured before a compaction described the pre-cut context.
public func lastAssistantUsageIndex(_ messages: [Message]) -> Int? {
	for i in messages.indices.reversed() {
		switch messages[i].body {
		case .marker(let m) where m.kind == .compaction:
			return nil
		case .assistant(let a):
			if a.stopReason == "aborted" { continue }
			guard let usage = a.usage, calculateContextTokens(usage) != 0 else { continue }
			return i
		default:
			continue
		}
	}
	return nil
}

public struct ContextTokenEstimate: Sendable, Hashable {
	/// The estimate the trigger compares against the threshold.
	public var tokens: Int
	/// Provider-reported tokens from the usage anchor (0 when unanchored).
	public var usageTokens: Int
	/// chars/4-estimated tokens after the anchor (or everything, unanchored).
	public var trailingTokens: Int
	/// Index of the usage anchor, or nil (diagnostics).
	public var lastUsageIndex: Int?

	public var json: JSONValue {
		["tokens": .number(tokens), "usageTokens": .number(usageTokens), "trailingTokens": .number(trailingTokens),
		 "lastUsageIndex": lastUsageIndex.map(JSONValue.number) ?? .null]
	}
}

/// THE trigger estimator (pi's estimateContextTokens): the last assistant
/// usage plus chars/4 of ONLY what was appended after it.
public func estimateContextTokens(_ messages: [Message]) -> ContextTokenEstimate {
	guard let anchor = lastAssistantUsageIndex(messages), let usage = messages[anchor].assistant?.usage else {
		let trailing = estimateTokens(messages)
		return ContextTokenEstimate(tokens: trailing, usageTokens: 0, trailingTokens: trailing, lastUsageIndex: nil)
	}
	let usageTokens = calculateContextTokens(usage)
	let trailing = estimateTokens(messages[(anchor + 1)...])
	return ContextTokenEstimate(tokens: usageTokens + trailing, usageTokens: usageTokens, trailingTokens: trailing, lastUsageIndex: anchor)
}

/// Estimate a whole message list (the plain heuristic — cut-walk use).
public func estimateTokens<C: Collection>(_ messages: C) -> Int where C.Element == Message {
	messages.reduce(0) { $0 + estimateMessageTokens($1) }
}

// MARK: - The cut walk

/// The compaction cut index: walk BACKWARDS accumulating estimates until
/// ~keepRecentTokens are kept; the cut lands there.
///
/// HARD INVARIANT — a tool result is never separated from its call: if the
/// cut lands on a toolResult, the kept region extends to the assistant
/// message carrying its call. A pending (unanswered) call at the transcript
/// end is always kept. Returns 0 when everything must be summarized.
public func compactionCutIndex(_ messages: [Message], keepRecentTokens: Int = KEEP_RECENT_TOKENS) -> Int {
	var kept = 0
	for i in messages.indices.reversed() {
		if kept >= keepRecentTokens {
			var cut = i + 1
			while cut < messages.count, let result = messages[cut].toolResult {
				let callIndex = assistantIndexOfCall(messages, toolUseId: result.toolUseId, before: cut)
				if callIndex == -1 { break } // no call found (defensive): stop extending
				cut = callIndex
			}
			return cut
		}
		kept += estimateMessageTokens(messages[i])
	}
	return 0
}

/// The newest assistant message before `before` carrying the call `toolUseId`.
private func assistantIndexOfCall(_ messages: [Message], toolUseId: String, before: Int) -> Int {
	var i = before - 1
	while i >= 0 {
		if let a = messages[i].assistant, a.content.contains(where: { $0.type == "tool_use" && $0.raw["id"]?.stringValue == toolUseId }) {
			return i
		}
		i -= 1
	}
	return -1
}

// MARK: - The marker

/// The compaction marker's details (UI payload — never model-visible).
public struct CompactionDetails: Sendable, Hashable {
	/// Record id of the first KEPT message.
	public var firstKeptMessageId: String
	/// The estimated context tokens that triggered this compaction.
	public var tokensBefore: Int
	/// The model that wrote the summary (provenance only).
	public var model: String?
	/// ISO timestamp of the compaction moment.
	public var at: String

	public init(firstKeptMessageId: String, tokensBefore: Int, model: String? = nil, at: String) {
		self.firstKeptMessageId = firstKeptMessageId
		self.tokensBefore = tokensBefore
		self.model = model
		self.at = at
	}

	public var json: JSONValue {
		var o = JSONObject(["firstKeptMessageId": .string(firstKeptMessageId), "tokensBefore": .number(tokensBefore)])
		if let model { o["model"] = .string(model) }
		o["at"] = .string(at)
		return .object(o)
	}
}

/// Build the compaction marker: content is the FULL model-facing text
/// (header + trimmed summary). Id and clock are injectable.
public func newCompactionMarker(summary: String, details: CompactionDetails, id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	Message(id: id, timestamp: now, body: .marker(MarkerBody(
		kind: .compaction, content: "\(COMPACTED_HISTORY_HEADER)\n\n\(summary.jsTrimmed)", display: true, details: details.json)))
}

/// The active compaction: its marker message plus the cut it names.
public struct ActiveCompaction: Sendable, Hashable {
	public var message: Message
	public var firstKeptMessageId: String

	public var id: String { message.id }
	/// The marker's model-facing text (header + summary).
	public var content: String { message.marker?.content ?? "" }
	/// The marker's raw details (the UI payload, verbatim).
	public var details: JSONValue { message.marker?.details ?? .null }
}

/// The ACTIVE compaction marker: the newest one whose details name a
/// string firstKeptMessageId (chained compactions — the last one rules).
public func activeCompactionOf(_ messages: [Message]) -> ActiveCompaction? {
	for m in messages.reversed() {
		guard let marker = m.marker, marker.kind == .compaction else { continue }
		if let kept = marker.details["firstKeptMessageId"]?.stringValue {
			return ActiveCompaction(message: m, firstKeptMessageId: kept)
		}
	}
	return nil
}

/// The index of the first KEPT message, or -1 when the marker names an id
/// that no longer exists (callers fall back to rendering everything).
public func keptIndexFor(_ messages: [Message], _ compaction: ActiveCompaction) -> Int {
	messages.firstIndex { $0.id == compaction.firstKeptMessageId } ?? -1
}

// MARK: - The summarizer input

/// Serialize a message span as labeled text for the summarizer. Tool
/// results truncate at ~2k chars (UTF-16); thinking and plan blocks skip.
public func serializeForSummary(_ messages: [Message]) -> String {
	var lines: [String] = []
	for m in messages {
		switch m.body {
		case .user(let u):
			lines.append("[LEARNER] \(u.content.compactMap(\.text).joined(separator: "\n"))")
		case .assistant(let a):
			var blocks: [String] = []
			for b in a.content {
				if b.type == "text" {
					blocks.append(b.raw["text"]?.stringValue ?? "")
				} else if b.type == "tool_use" {
					let name = b.raw["name"]?.stringValue ?? ""
					blocks.append("(tool call \(name): \((b.raw["input"] ?? .null).serialized()))")
				}
				// thinking: the model's private scratch — skip the noise
			}
			if !blocks.isEmpty { lines.append("[TUTOR] \(blocks.joined(separator: "\n"))") }
		case .toolResult(let r):
			let text = r.content.map { $0.type == "text" ? ($0.raw["text"]?.stringValue ?? "") : $0.raw.serialized() }.joined(separator: "\n")
			let body = text.jsLength > SUMMARY_TOOL_RESULT_TRUNCATE ? "\(text.jsSlice(0, SUMMARY_TOOL_RESULT_TRUNCATE))…[truncated]" : text
			lines.append("[RESULT for \(r.toolName)\(r.isError ? " (error)" : "")] \(body)")
		case .marker(let marker):
			if marker.kind == .planBlock { continue } // UI-only
			lines.append("[SYSTEM NOTE] \(marker.content)")
		}
	}
	return lines.joined(separator: "\n\n")
}

/// Render the plan dependency tree verbatim (structure from the tree,
/// statuses derived from the transcript). Empty tree → nil.
public func planTreeToText(_ tree: PlanTree?, _ messages: [Message]) -> String? {
	guard let tree, !tree.nodes.isEmpty else { return nil }
	let statuses = derivePlanStatuses(tree, messages)
	var byId: [String: PlanNode] = [:]
	for n in tree.nodes { byId[n.id] = n } // Map semantics: the last duplicate wins
	var lines: [String] = []
	for node in tree.nodes {
		let status = derivedNodeStatus(statuses, node.id)
		let summary = (node.summary?.isEmpty == false) ? " — \(node.summary!)" : ""
		lines.append("- [\(status.rawValue)] \(node.title) (\(node.id))\(summary)")
	}
	for edge in tree.edges {
		if let from = byId[edge.from], let to = byId[edge.to] {
			lines.append("- \(from.title) → \(to.title) (\(from.id) → \(to.id))")
		}
	}
	return lines.joined(separator: "\n")
}

/// The session kind, for the summarizer prompt's wording.
public enum CompactionPromptKind: String, Sendable, Hashable {
	case teach, practice, probe
}

/// The summarizer prompt: the learner's understanding AND its evolution,
/// the teaching arc, the plan tree verbatim, and the current moment.
public func buildCompactionPrompt(spanText: String, planTreeText: String?, kind: CompactionPromptKind) -> String {
	let planSection = planTreeText ?? "No plan tree exists in this session (nothing was persisted)."
	return """
You are compacting the earlier part of a tutoring session — writing the summary your future self will read INSTEAD of that transcript. Everything before the cut is replaced by what you write; everything after stays verbatim. The learner's transcript below labels the learner as [LEARNER], the tutoring agent as [TUTOR], tool traffic as [RESULT …]/[SYSTEM NOTE].

Write the summary with EXACTLY these sections, in this order:

## The learner's understanding
The most detailed picture you can give of what this learner knows and how that EVOLVED across the session: what they answered and how well (quiz outcomes, correct reasoning, mistakes), their stated or displayed confidence, misconceptions that surfaced, which were corrected and which still stand. This section carries the most weight — future teaching decisions hang on it.

## The teaching arc
How the session progressed: what was covered and in what order, which explanations landed and which didn't, how the learner responded, where the momentum went. Include probe-phase findings if present.

## The plan dependency tree
Reproduce the session's current plan tree verbatim from the structure below — do not drop nodes, edges, or statuses.

\(planSection)

## The current moment
What is happening RIGHT NOW at the cut: any question or problem awaiting the learner's answer, any commitment the agent has made that a later turn must honor, and the immediate next step.

Rules: no praise, no filler, no speculation beyond the transcript. Every claim about the learner must be traceable to what they actually said or answered. Keep every identifier (proposition ids, node ids, file paths) exact.

TRANSCRIPT TO SUMMARIZE:

\(spanText)
"""
}
