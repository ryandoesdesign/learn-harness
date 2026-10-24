import Foundation

// Port of question-dock.tsx's QuestionData construction: the pending call's
// input → the canonical question the dock renders and buildAnswer grades.
// probe/recall canonicalize onto quiz/explain. Quiz options are shuffled
// deterministically (seeded by the call id) so position never leaks
// correctness and the order is stable across relaunches.

/// The dock's question for a pending call, or nil when the input is
/// malformed ("This question arrived malformed — the transcript keeps the retry.").
public func dockQuestion(tool: String, toolCallId: String, input: JSONValue, now: Int = MessageID.nowMillis()) -> QuestionData? {
	let kind = toolQuestionKind(tool)
	let createdAt = ISO8601DateFormatter.lhString(now)
	switch kind {
	case .quiz:
		guard let quiz = parseQuizInput(input), let options = try? normalizeOptions(quiz.options) else { return nil }
		let ordered = options.isEmpty ? options : shuffleOptions(options, rand: seededRandom(toolCallId))
		var q = QuestionData(id: toolCallId, kind: .quiz, questionType: normalizeQuizType(input["type"]), question: quiz.question,
			context: quiz.details, mode: quiz.multiSelect == true ? .multiSelect : .singleSelect, options: ordered, createdAt: createdAt)
		q.correctIndices = resolveCorrect(quiz.correctAnswer, options: ordered).indices
		q.explanation = quiz.explanation
		return q
	case .ask:
		guard let ask = parseAskInput(input), let options = try? normalizeOptions(ask.options ?? []) else { return nil }
		let mode: QuestionMode = options.isEmpty ? .text : ask.multiSelect == true ? .multiSelect : .singleSelect
		return QuestionData(id: toolCallId, kind: .ask, question: ask.question, context: ask.details, mode: mode, options: options, createdAt: createdAt)
	case .explain:
		guard let explain = parseExplainInput(input) else { return nil }
		var q = QuestionData(id: toolCallId, kind: .explain, question: explain.question, context: explain.details, mode: .text, options: [], createdAt: createdAt)
		q.committedAnswer = explain.correctAnswer
		return q
	}
}

/// The dock's header label (question-dock.tsx): the tool's own name for the
/// probe phase, the role for teach quizzes.
public func dockLabel(tool: String, question: QuestionData) -> String {
	if tool == "probe" { return "Probe" }
	if tool == "recall" { return "Recall" }
	switch question.kind {
	case .quiz: return question.questionType == .predict ? "Prediction" : "Check"
	case .explain: return "Explain"
	case .ask: return "Question"
	}
}

extension ISO8601DateFormatter {
	/// JS `new Date(ms).toISOString()`.
	static func lhString(_ ms: Int) -> String {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
	}
}
