import Foundation

// Port of core/input-events.ts — the learner's input events and the native
// appends each makes to the record (pure; the caller persists them
// write-ahead). The orphan discipline: an answer or dismissal must target
// the DANGLING question call, or it is refused honestly.

/// A learner input that may start a turn.
public enum ChatInput: Sendable, Hashable {
	case text(String)
	case answer(toolCallId: String, answer: QuestionAnswerData)
	/// A message about the open question instead of an answer (Discuss.swift).
	case discuss(toolCallId: String, text: String)
	case `continue`
	/// Practice (M8): the learner's thinking on the active problem.
	case thinking(problemCallId: String, text: String)
	/// Practice (M8): the move-on signal.
	case next
}

/// A dismissal: appended without a turn.
public enum DismissInput: Sendable, Hashable {
	case dismiss(toolCallId: String, answer: QuestionAnswerData)
	/// Practice (M8): the problem discard.
	case dismissProblem(problemCallId: String)
}

public struct ChatInputError: Error, Sendable, Hashable, CustomStringConvertible {
	public var message: String
	public init(_ message: String) { self.message = message }
	public var description: String { message }
}

/// The appends an input makes (throws the 400-class refusals).
public func inputAppends(_ messages: [Message], kind: ChatKind?, _ input: ChatInput, now: Int = MessageID.nowMillis()) throws(ChatInputError) -> [Message] {
	switch input {
	case .text(let text):
		guard !text.jsTrimmed.isEmpty else { throw ChatInputError("text input requires non-empty text") }
		return dismissalConclusion(messages, now: now) + [newUserMessage(text, now: now)]
	case .answer(let toolCallId, let answer):
		guard let pending = danglingQuestionOf(messages), pending.toolCallId == toolCallId else {
			throw ChatInputError("answer input targets no pending question call")
		}
		return [newAnswerResult(toolCallId: toolCallId, toolName: pending.tool, answer: answer, now: now)]
	case .discuss(let toolCallId, let text):
		return try discussAppends(messages, toolCallId: toolCallId, text: text, now: now)
	case .continue:
		return dismissalConclusion(messages, now: now)
	case .thinking(let problemCallId, let text):
		guard let active = activeProblemOf(messages), active.toolCallId == problemCallId else {
			throw ChatInputError("thinking input targets no active problem")
		}
		guard !text.jsTrimmed.isEmpty else { throw ChatInputError("thinking input requires non-empty text") }
		return dismissalConclusion(messages, now: now) + [newThinkingMessage(problemCallId: problemCallId, text: text, now: now)]
	case .next:
		guard kind == .practice else { throw ChatInputError("next input is a practice-session affordance") }
		guard activeProblemOf(messages) == nil else { throw ChatInputError("next input requires no active problem") }
		return dismissalConclusion(messages, now: now) + [newNextMessage(now: now)]
	}
}

/// The appends a dismissal makes.
public func dismissAppends(_ messages: [Message], _ input: DismissInput, now: Int = MessageID.nowMillis()) throws(ChatInputError) -> [Message] {
	switch input {
	case .dismissProblem(let problemCallId):
		guard let active = activeProblemOf(messages), active.toolCallId == problemCallId else {
			throw ChatInputError("dismiss-problem input targets no active problem")
		}
		return [newProblemDismissedMarker(problemCallId: problemCallId, now: now)]
	case .dismiss(let toolCallId, let answer):
		guard answer.dismissed == true else { throw ChatInputError("dismiss input's answer must be a dismissal (dismissed: true)") }
		guard let pending = danglingQuestionOf(messages), pending.toolCallId == toolCallId else {
			throw ChatInputError("dismiss input targets no pending question call")
		}
		guard answer.kind == toolQuestionKind(pending.tool) else {
			throw ChatInputError("dismiss input's answer kind does not match the question")
		}
		return [newAnswerResult(toolCallId: toolCallId, toolName: pending.tool, answer: answer, now: now)]
	}
}

/// A practice dismissal still owed its conclude pair rides the next input.
func dismissalConclusion(_ messages: [Message], now: Int) -> [Message] {
	guard let problemCallId = pendingProblemDismissalOf(messages) else { return [] }
	let (call, result) = concludedByDismissalPair(problemCallId: problemCallId, now: now)
	return [call, result]
}
