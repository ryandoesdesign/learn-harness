import Foundation

// Port of native-messages.ts `newAnswerResult`: the learner's answer IS the
// question call's toolResult.

/// The answer's toolResult (tool-result diet, 2026-10-02): the model reads
/// `JSON.stringify(compactAnswerForModel(answer))`; `details` keeps the FULL
/// graded answer for the record and the UI.
public func newAnswerResult(toolCallId: String, toolName: String, answer: JSONValue, id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	Message(id: id, timestamp: now, body: .toolResult(ToolResultBody(
		toolUseId: toolCallId, toolName: toolName,
		content: [.text(JSONValue.object(compactAnswerForModel(answer)).serialized())],
		isError: false, details: answer)))
}

public func newAnswerResult(toolCallId: String, toolName: String, answer: QuestionAnswerData, id: String = MessageID.mint(), now: Int = MessageID.nowMillis()) -> Message {
	newAnswerResult(toolCallId: toolCallId, toolName: toolName, answer: answer.json, id: id, now: now)
}
