import Foundation

// Asking about an open question instead of answering it: every open
// question call is set aside (a `discussed` result, never graded), the
// learner's message follows, and once the teacher has replied the same
// calls are re-posed under new ids — the question stays open throughout.

/// What the teacher reads in place of an answer.
public let DISCUSSED_NOTE =
	"Not an answer: the learner set this question aside to ask about it (their message follows). " +
	"Reply to that; don't give the answer away and don't pose a new question. " +
	"The question is re-posed for them when you finish."

/// The re-posed calls' assistant message (system-written, like the practice dismissal's conclude).
public let REPOSE_MODEL = "synthetic:repose"

/// The call a re-posed id came from ("rp2_c1" → "c1"); any other id is its own origin.
public func reposeOrigin(_ id: String) -> String {
	guard let m = id.wholeMatch(of: /rp\d+_(.+)/) else { return id }
	return String(m.1)
}

/// Every unanswered question call of the latest assistant message (siblings included).
public func danglingQuestionsOf(_ messages: [Message]) -> [(toolCallId: String, tool: String, input: JSONValue)] {
	guard let mi = messages.lastIndex(where: { $0.assistant != nil }), let a = messages[mi].assistant else { return [] }
	let answered = Set(messages[(mi + 1)...].compactMap { $0.toolResult?.toolUseId })
	return a.toolUses.filter { QUESTION_TOOLS.contains($0.name) && !answered.contains($0.id) }.map { ($0.id, $0.name, $0.input) }
}

/// The discuss input's appends: a `discussed` result per open question call, then the message.
func discussAppends(_ messages: [Message], toolCallId: String, text: String, now: Int) throws(ChatInputError) -> [Message] {
	let open = danglingQuestionsOf(messages)
	guard open.contains(where: { $0.toolCallId == toolCallId }) else { throw ChatInputError("discuss input targets no pending question call") }
	guard !text.jsTrimmed.isEmpty else { throw ChatInputError("discuss input requires non-empty text") }
	let results = open.map { call in
		newAnswerResult(toolCallId: call.toolCallId, toolName: call.tool,
			answer: discussedAnswer(toolQuestionKind(call.tool), questionText: call.input["question"]?.stringValue ?? "", now: now), now: now)
	}
	return results + [newUserMessage(text, now: now)]
}

private func isDiscussedResult(_ m: Message) -> Bool {
	m.toolResult?.details?["discussed"]?.boolValue == true
}

/// After the teacher's reply: the set-aside calls, re-posed — unless a
/// question has been asked since (it replaces them) or they already were.
public func reposeAppends(_ messages: [Message], now: Int = MessageID.nowMillis()) -> [Message] {
	guard let last = messages.lastIndex(where: isDiscussedResult) else { return [] }
	let failed = Set(messages.compactMap { m in m.toolResult.flatMap { $0.isError ? $0.toolUseId : nil } })
	for m in messages[(last + 1)...] {
		guard let a = m.assistant, !["aborted", "error"].contains(a.stopReason) else { continue }
		if a.toolUses.contains(where: { QUESTION_TOOLS.contains($0.name) && !failed.contains($0.id) }) { return [] }
	}
	var first = last
	while first > 0, isDiscussedResult(messages[first - 1]) { first -= 1 }
	var calls: [Block] = []
	for result in messages[first...last] {
		guard let id = result.toolResult?.toolUseId,
		      let call = messages[..<first].reversed().lazy.compactMap({ $0.assistant?.toolUses.first { $0.id == id } }).first
		else { continue }
		let origin = reposeOrigin(id)
		let n = (id.wholeMatch(of: /rp(\d+)_.+/).flatMap { Int($0.1) } ?? 0) + 1
		calls.append(.toolUse(id: "rp\(n)_\(origin)", name: call.name, input: call.input))
	}
	guard !calls.isEmpty else { return [] }
	return [Message(id: MessageID.mint(), timestamp: now, body: .assistant(AssistantBody(
		content: calls, model: REPOSE_MODEL, stopReason: "tool_use",
		usage: MessageUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))))]
}
