import Foundation

// Port of src/core/session-markdown.ts — session → markdown, the ONE
// formatting engine (owner ruling 2026-09-27) shared by the extractor's
// view and the user-facing export: speaker headers, quiz/check-in blocks,
// tool notes, optional message-id anchors. Native messages in, string out.
// A failed tool call renders nothing (retry context, not learning
// evidence); markers are invisible. Output is byte-identical to the TS.

/// The practice join context: practice tool RESULTS are acks — statement,
/// outcome and verdict live in the assistant's call input, and the model
/// solution commits at POSE time. The markdown blocks join them.
public struct MarkdownContext: Sendable {
	public var messages: [Message]
	/// tool_use id → the call's name + input (last call with an id wins).
	public var calls: [String: (name: String, args: JSONValue?)]

	public init(messages: [Message], calls: [String: (name: String, args: JSONValue?)]) {
		self.messages = messages
		self.calls = calls
	}

	/// The context `sessionMarkdown` builds over its messages.
	init(messages: [Message]) {
		var calls: [String: (name: String, args: JSONValue?)] = [:]
		for m in messages {
			guard let a = m.assistant else { continue }
			for block in a.content where block.type == "tool_use" {
				guard let id = block.raw["id"]?.stringValue else { continue }
				let input = block.raw["input"]
				calls[id] = (block.raw["name"]?.stringValue ?? "", input?.nonNull)
			}
		}
		self.init(messages: messages, calls: calls)
	}
}

/// The user-facing text blocks of a message (non-blank text blocks only).
private func textOf(_ content: [Block]) -> [String] {
	content.compactMap(\.text).filter { !$0.jsTrimmed.isEmpty }
}

/// solvedWithHints → "Solved with hints" — the outcome enum reads as prose
/// (JS `/([a-z])([A-Z])/g` → "lo hi.lower", then capitalize the first unit).
private func outcomeLabel(_ outcome: String) -> String {
	let u = Array(outcome.utf16)
	var out: [UInt16] = []
	var i = 0
	func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
	func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
	while i < u.count {
		if i + 1 < u.count, isLower(u[i]), isUpper(u[i + 1]) {
			out += [u[i], 0x20, u[i + 1] + 0x20]
			i += 2
		} else {
			out.append(u[i])
			i += 1
		}
	}
	guard let first = out.first else { return "" }
	let rest = String(decoding: out.dropFirst(), as: UTF16.self)
	if UTF16.isLeadSurrogate(first) || UTF16.isTrailSurrogate(first) {
		return String(decoding: out, as: UTF16.self)
	}
	return String(decoding: [first], as: UTF16.self).uppercased() + rest
}

/// JS `String(value)` for an array element inside `Array.prototype.join`
/// (null → "", nested arrays join with ",").
private func jsJoinElement(_ v: JSONValue) -> String {
	switch v {
	case .null: ""
	case .bool(let b): b ? "true" : "false"
	case .number(let n): JSONNumber(n.double).lexeme
	case .string(let s): s
	case .array(let a): a.map(jsJoinElement).joined(separator: ",")
	case .object: "[object Object]"
	}
}

/// `s.replace(/\n/g, "\n> ")` on UTF-16 units (Swift treats "\r\n" as one Character).
private func quoteNewlines(_ s: String) -> String {
	var out: [UInt16] = []
	for c in s.utf16 {
		out.append(c)
		if c == 0x0A { out += [0x3E, 0x20] }
	}
	return String(decoding: out, as: UTF16.self)
}

/// A non-empty string field (`typeof v === "string" && v`).
private func nonEmptyString(_ v: JSONValue?) -> String? {
	guard let s = v?.stringValue, !s.isEmpty else { return nil }
	return s
}

/// A non-blank string field, trimmed (`typeof v === "string" && v.trim()`).
private func trimmedString(_ v: JSONValue?) -> String? {
	guard let s = v?.stringValue else { return nil }
	let t = s.jsTrimmed
	return t.isEmpty ? nil : t
}

/// One tool result's learner-visible outcome, rendered as body lines.
private func toolResultBody(_ result: ToolResultBody, _ ctx: MarkdownContext?) -> (heading: String, body: [String]) {
	let out = result.details
	let name = result.toolName

	if name == "quiz" || name == "probe" || name == "explain" || name == "recall" {
		let heading = switch name {
		case "quiz": "Quiz"
		case "probe": "Probe"
		case "recall": "Recall"
		default: "Recall check" // explain — the teach free-recall name
		}
		let question = nonEmptyString(out?["questionText"]) ?? "(no question text)"
		var body = ["**Q:** \(question)"]
		if out?["dismissed"]?.boolValue == true {
			body.append("The learner skipped this check.")
		} else if out?["dontKnow"]?.boolValue == true {
			body.append("The learner did not know.")
		} else if out?["correct"]?.boolValue == true {
			body.append("The learner answered correctly.")
		} else if out?["correct"]?.boolValue == false {
			body.append("The learner answered incorrectly.")
		} else if let text = trimmedString(out?["text"]) {
			body.append("The learner answered in his own words: \(text)")
		}
		if let note = nonEmptyString(out?["note"]) { body.append("*(his thinking: \(note))*") }
		return (heading, body)
	}

	if let ctx, name == PRACTICE_PROBLEM_TOOL {
		let statement = trimmedString(ctx.calls[result.toolUseId]?.args?["statement"])
		return ("Problem", [statement ?? "(no statement)"])
	}

	if let ctx, name == PRACTICE_CONCLUDE_TOOL {
		let args = ctx.calls[result.toolUseId]?.args
		let outcome = trimmedString(args?["outcome"]) ?? ""
		let verdict = trimmedString(args?["verdict"])
		if outcome == "dismissed" { return ("Concluded", ["The learner skipped this problem."]) }
		let label = outcome != "" ? "**\(outcomeLabel(outcome)).**" : "**Concluded.**"
		var body = [verdict.map { "\(label) \($0)" } ?? label]
		// The reveal: the solution committed at pose time — the newest
		// cleanly-posed problem before this conclude.
		let input = problemInputForConclude(ctx.messages, concludeCallId: result.toolUseId)
		if let solution = trimmedString(input?["modelSolution"]) {
			body.append("> **Model solution**\n>\n> \(quoteNewlines(solution))")
		}
		return ("Concluded", body)
	}

	if name == "ask_user_question" {
		let question = nonEmptyString(out?["questionText"]) ?? "(no question text)"
		var body = ["**Q:** \(question)"]
		var chosen = (out?["answers"]?.arrayValue ?? []).map(jsJoinElement)
		if let other = trimmedString(out?["other"]) { chosen.append(other) }
		if let text = trimmedString(out?["text"]) {
			body.append("The learner answered: \(text)")
		} else if !chosen.isEmpty {
			body.append("The learner chose: \(chosen.joined(separator: ", "))")
		} else if out?["dismissed"]?.boolValue == true {
			body.append("The learner skipped this question.")
		}
		if let note = nonEmptyString(out?["note"]) { body.append("*(his thinking: \(note))*") }
		return ("Question", body)
	}

	// Parity with the line builder: other clean tool results are one line.
	return ("Tool", ["*\(name) result delivered*"])
}

/// ONE message as a markdown block — nil when the message renders nothing
/// (a failed tool call, a marker, an empty text block set). `mid` is the
/// provenance anchor shown when `anchors` is on.
public func messageMarkdown(_ message: Message, _ mid: String, anchors: Bool = true, ctx: MarkdownContext? = nil) -> String? {
	let anchor = anchors ? " · \(mid)" : ""
	var parts: [String] = []
	switch message.body {
	case .user(let u):
		for text in textOf(u.content) { parts.append("### Learner\(anchor)\n\n\(text.jsTrimmed)") }
	case .assistant(let a):
		for text in textOf(a.content) { parts.append("### Teacher\(anchor)\n\n\(text.jsTrimmed)") }
	case .toolResult(let r):
		if r.isError { return nil } // retry context, not learning evidence
		let (heading, body) = toolResultBody(r, ctx)
		parts.append("### \(heading)\(anchor)\n\n\(body.joined(separator: "\n\n"))")
	case .marker:
		break // markers are invisible, same as the extraction view
	}
	return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
}

/// A whole session (or one extraction BATCH — same engine, a subset of
/// messages) as one markdown document. Blocks render in message order;
/// messages that render nothing are skipped. A non-empty `title` mints the
/// `# <title>` header.
public func sessionMarkdown(_ messages: [Message], title: String? = nil, anchors: Bool = true) -> String {
	var blocks: [String] = []
	if let title, !title.isEmpty { blocks.append("# \(title)") }
	let ctx = MarkdownContext(messages: messages)
	for m in messages {
		if let block = messageMarkdown(m, m.id, anchors: anchors, ctx: ctx) { blocks.append(block) }
	}
	return blocks.joined(separator: "\n\n")
}
