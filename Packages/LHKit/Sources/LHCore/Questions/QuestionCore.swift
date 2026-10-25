import Foundation

// Port of src/core/question-core.ts — the question contract + pure grading.
// The dock validates, shuffles, and grades with these functions; the verdict
// returns to the model as the tool result (newAnswerResult). The schemas
// live in QuestionSchemas.swift.

// MARK: - Shared types

/// A normalized answer option (display order).
public struct QuizOption: Sendable, Hashable {
	public var label: String
	public var value: String
	public var description: String?
	public init(label: String, value: String, description: String? = nil) {
		self.label = label
		self.value = value
		self.description = description
	}

	public var json: JSONValue {
		var o = JSONObject(["label": .string(label), "value": .string(value)])
		if let description { o["description"] = .string(description) }
		return .object(o)
	}
}

/// A model-authored option as the schemas type it (`value` optional;
/// `description` on ask options only).
public struct QuizOptionInput: Sendable, Hashable {
	public var label: String
	public var value: String?
	public var description: String?
	public init(label: String, value: String? = nil, description: String? = nil) {
		self.label = label
		self.value = value
		self.description = description
	}
}

/// quiz `correctAnswer`: `string | string[]`.
public enum CorrectAnswer: Sendable, Hashable {
	case single(String)
	case multiple([String])

	public init?(json: JSONValue) {
		switch json {
		case .string(let s): self = .single(s)
		case .array(let a):
			let strings = a.compactMap(\.stringValue)
			guard strings.count == a.count else { return nil }
			self = .multiple(strings)
		default: return nil
		}
	}

	public var json: JSONValue {
		switch self {
		case .single(let s): .string(s)
		case .multiple(let a): .array(a.map(JSONValue.string))
		}
	}
}

/// The teaching-cycle role of a teach question.
public enum QuizQuestionType: String, Sendable, Hashable, Codable, CaseIterable {
	case predict, check
}

public let QUIZ_QUESTION_TYPES: [String] = QuizQuestionType.allCases.map(\.rawValue)

/// The tool names that carry the quizzing mechanic (teach seam, plan-position
/// fold, pending gate).
public let QUIZ_TOOL_NAMES: [String] = ["quiz", "explain"]

public enum SelectMode: String, Sendable, Hashable, Codable {
	case singleSelect = "single-select"
	case multiSelect = "multi-select"
}

public enum QuestionMode: String, Sendable, Hashable, Codable {
	case singleSelect = "single-select"
	case multiSelect = "multi-select"
	case text
}

public enum QuestionCoreError: Error, Sendable, Hashable, CustomStringConvertible {
	/// normalizeOptions: two options resolve to one value.
	case duplicateOptionValue(String)
	/// normalizeOptions: an option without a string label (TS throws a TypeError).
	case malformedOption

	public var description: String {
		switch self {
		case .duplicateOptionValue(let v): "duplicate option value \"\(v)\""
		case .malformedOption: "malformed option"
		}
	}
}

// MARK: - The GLM wobble guard

/// Models sometimes emit `options` as a JSON-ENCODED STRING. Parse it when it
/// is a parseable array; anything else returns untouched for validation to
/// report honestly.
public func parseOptionsIfString(_ options: JSONValue?) -> JSONValue? {
	guard case .string(let s)? = options else { return options }
	if let parsed = JSONValue.tryParse(s), parsed.arrayValue != nil { return parsed }
	return options
}

// MARK: - Cross-field authoring validation (schema-valid ⇔ gradeable)

/// Option sanity shared by quiz + ask: labels non-empty, resolved values
/// (trimmed `value`, else the trimmed label) distinct.
private func optionProblems(_ options: [QuizOptionInput]) -> (problems: [String], keys: [String]) {
	var problems: [String] = []
	var keys: [String] = []
	for (i, option) in options.enumerated() {
		let label = option.label.jsTrimmed
		if label.isEmpty {
			problems.append("options[\(i)].label is empty — every option needs a label.")
			continue
		}
		let trimmedValue = option.value?.jsTrimmed ?? ""
		let key = trimmedValue.isEmpty ? label : trimmedValue
		if keys.contains(key) {
			problems.append("Two options resolve to the same value \"\(key)\" — options must be distinct.")
		}
		keys.append(key)
	}
	return (problems, keys)
}

/// ask options: the shared sanity, nothing more (ask is not graded).
public func askOptionProblems(_ options: [QuizOptionInput]) -> [String] {
	optionProblems(options).problems
}

/// The full quiz authoring contract: option sanity + a gradeable correctAnswer.
public func quizInputProblems(options: [QuizOptionInput], correctAnswer: CorrectAnswer, multiSelect: Bool?) -> [String] {
	var (problems, keys) = optionProblems(options)
	let entries = coerceCorrectAnswer(correctAnswer, optionValues: keys)
	var unique: [String] = []
	for e in entries where !unique.contains(e) { unique.append(e) }
	if unique.isEmpty || unique.contains(where: \.isEmpty) {
		problems.append("correctAnswer is required — provide the value (or label) of the correct option(s).")
		return problems
	}
	for v in unique where !keys.contains(v) {
		problems.append(
			"correctAnswer \"\(v)\" does not match any option value. Valid values: \(keys.map { "\"\($0)\"" }.joined(separator: ", ")). " +
				"Copy the exact value (or label) of the intended option — never a paraphrase or slug.")
	}
	if unique.count > 1 && multiSelect != true {
		problems.append(
			"correctAnswer lists \(unique.count) values but multiSelect is not true — a single-select question with several " +
				"correct answers can never be answered correctly. Set multiSelect: true, or make exactly one option correct.")
	}
	return problems
}

/// The explain authoring contract: the commitment must exist.
public func explainInputProblems(correctAnswer: String) -> [String] {
	if correctAnswer.jsTrimmed.isEmpty {
		return ["correctAnswer is required — commit to the full correct answer BEFORE posing the question."]
	}
	return []
}

// MARK: - The question's role

/// Normalize a persisted quiz `type` (display seam): old records carry none,
/// unhealable wobble degrades to nil; the debris strip heals `"\"predict\""`.
public func normalizeQuizType(_ raw: JSONValue?) -> QuizQuestionType? {
	guard case .string(let s)? = raw else { return nil }
	return QuizQuestionType(rawValue: stripModelValueDebris(s))
}

/// The reveal law: a teach-phase CHECK (quiz or explain) collapses behind the
/// "Check your understanding" reveal; a prediction never does, nor do probe
/// / plan questions or ask. Records without `type` render as checks.
public func questionNeedsReveal(tool: String, rawInput: JSONValue?, phase: String) -> Bool {
	if (tool != "quiz" && tool != "explain") || phase != "teach" { return false }
	return normalizeQuizType(rawInput?["type"]) != .predict
}

// MARK: - Question / answer records

/// A real selected answer, in display order.
public struct OptionAnswer: Sendable, Hashable {
	public var label: String
	public var value: String
	/// 1-based display index.
	public var index: Int
	public init(label: String, value: String, index: Int) {
		self.label = label
		self.value = value
		self.index = index
	}
}

/// Full question data. `correctIndices` / `committedAnswer` / `explanation`
/// NEVER reach the client before answering.
public struct QuestionData: Sendable, Hashable {
	public var id: String
	public var kind: QuestionKind
	/// quiz only (teach): predict | check. Absent on probe quizzes and old records.
	public var questionType: QuizQuestionType?
	public var question: String
	public var context: String?
	public var mode: QuestionMode
	/// Display order (post-shuffle).
	public var options: [QuizOption]
	public var correctIndices: [Int]?
	public var committedAnswer: String?
	public var explanation: String?
	public var createdAt: String

	public init(id: String, kind: QuestionKind, questionType: QuizQuestionType? = nil, question: String, context: String? = nil,
		mode: QuestionMode, options: [QuizOption], correctIndices: [Int]? = nil, committedAnswer: String? = nil,
		explanation: String? = nil, createdAt: String)
	{
		self.id = id
		self.kind = kind
		self.questionType = questionType
		self.question = question
		self.context = context
		self.mode = mode
		self.options = options
		self.correctIndices = correctIndices
		self.committedAnswer = committedAnswer
		self.explanation = explanation
		self.createdAt = createdAt
	}
}

/// The learner's answer — the full structured record (`details` of the
/// answer's toolResult). No questionId: the toolResult carries it.
public struct QuestionAnswerData: Sendable, Hashable {
	public struct OptionSnapshot: Sendable, Hashable {
		public var index: Int
		public var label: String
		public init(index: Int, label: String) {
			self.index = index
			self.label = label
		}
	}

	public var kind: QuestionKind
	/// The persisted call's tool NAME (probe/recall vs quiz/explain).
	public var tool: String?
	public var questionType: QuizQuestionType?
	public var questionText: String
	public var options: [OptionSnapshot]?
	public var dontKnow: Bool
	public var answers: [OptionAnswer]
	/// ask: "Other" free text.
	public var other: String?
	/// ask/explain: text-mode answer.
	public var text: String?
	/// The learner's reasoning on the QUESTION (renamed from `note`).
	public var thinking: String?
	/// Deprecated pre-rename key — read via `thinking ?? note`.
	public var note: String?
	/// The thinking WHILE READING the teaching prose (rides check answers).
	public var readingThinking: String?
	/// quiz only: stated probability (0-100) the selection is correct.
	public var confidence: Double?
	public var correct: Bool?
	public var correctIndices: [Int]?
	/// explain only: the model's committed answer (rendering).
	public var committed: String?
	public var explanation: String?
	public var dismissed: Bool?
	/// Set aside to ask about it (Discuss.swift): not an answer, never graded.
	public var discussed: Bool?
	public var answeredAt: String

	public init(kind: QuestionKind, questionText: String, dontKnow: Bool, answers: [OptionAnswer], answeredAt: String) {
		self.kind = kind
		self.questionText = questionText
		self.dontKnow = dontKnow
		self.answers = answers
		self.answeredAt = answeredAt
	}

	/// Read a stored record (an answer toolResult's `details`); nil when
	/// the shape isn't an answer.
	public init?(json: JSONValue) {
		guard let kind = json["kind"]?.stringValue.flatMap(QuestionKind.init(rawValue:)),
		      let questionText = json["questionText"]?.stringValue
		else { return nil }
		self.kind = kind
		self.questionText = questionText
		dontKnow = json["dontKnow"]?.boolValue ?? false
		answers = (json["answers"]?.arrayValue ?? []).compactMap { a in
			guard let index = a["index"]?.intValue else { return nil }
			return OptionAnswer(label: a["label"]?.stringValue ?? "", value: a["value"]?.stringValue ?? "", index: index)
		}
		answeredAt = json["answeredAt"]?.stringValue ?? ""
		tool = json["tool"]?.stringValue
		questionType = json["questionType"]?.stringValue.flatMap(QuizQuestionType.init(rawValue:))
		options = json["options"]?.arrayValue?.compactMap { o in
			guard let index = o["index"]?.intValue else { return nil }
			return OptionSnapshot(index: index, label: o["label"]?.stringValue ?? "")
		}
		other = json["other"]?.stringValue
		text = json["text"]?.stringValue
		thinking = json["thinking"]?.stringValue
		note = json["note"]?.stringValue
		readingThinking = json["readingThinking"]?.stringValue
		confidence = json["confidence"]?.doubleValue
		correct = json["correct"]?.boolValue
		correctIndices = json["correctIndices"]?.arrayValue?.compactMap(\.intValue)
		committed = json["committed"]?.stringValue
		explanation = json["explanation"]?.stringValue
		dismissed = json["dismissed"]?.boolValue
		discussed = json["discussed"]?.boolValue
	}

	/// The record JSON, keyed in the TS construction order.
	public var json: JSONValue {
		var o = JSONObject(["kind": .string(kind.rawValue)])
		if let tool { o["tool"] = .string(tool) }
		if let questionType { o["questionType"] = .string(questionType.rawValue) }
		o["questionText"] = .string(questionText)
		if let options { o["options"] = .array(options.map { ["index": .number($0.index), "label": .string($0.label)] }) }
		o["dontKnow"] = .bool(dontKnow)
		o["answers"] = .array(answers.map { ["label": .string($0.label), "value": .string($0.value), "index": .number($0.index)] })
		if let thinking { o["thinking"] = .string(thinking) }
		if let note { o["note"] = .string(note) }
		if let readingThinking { o["readingThinking"] = .string(readingThinking) }
		if let dismissed { o["dismissed"] = .bool(dismissed) }
		if let discussed { o["discussed"] = .bool(discussed) }
		o["answeredAt"] = .string(answeredAt)
		if let other { o["other"] = .string(other) }
		if let text { o["text"] = .string(text) }
		if let correctIndices { o["correctIndices"] = .array(correctIndices.map(JSONValue.number)) }
		if let explanation { o["explanation"] = .string(explanation) }
		if let correct { o["correct"] = .bool(correct) }
		if let confidence { o["confidence"] = .number(JSONNumber(confidence)) }
		if let committed { o["committed"] = .string(committed) }
		return .object(o)
	}
}

/// Client-facing question payload — deliberately omits the answer.
public struct ClientQuestion: Sendable, Hashable {
	public var id: String
	public var kind: QuestionKind
	public var question: String
	public var context: String?
	public var mode: QuestionMode
	public var options: [QuizOption]

	public var json: JSONValue {
		var o = JSONObject(["id": .string(id), "kind": .string(kind.rawValue), "question": .string(question)])
		if let context { o["context"] = .string(context) }
		o["mode"] = .string(mode.rawValue)
		o["options"] = .array(options.map(\.json))
		return .object(o)
	}
}

/// What the dock passes when the learner answers.
public struct AnswerRequest: Sendable, Hashable {
	public var dontKnow: Bool?
	/// Option values.
	public var values: [String]?
	public var other: String?
	public var text: String?
	/// The reasoning-on-the-question channel (was `note`).
	public var thinking: String?
	/// The thinking-while-reading channel (check answers).
	public var readingThinking: String?
	/// quiz only: 0-100 raw probability — always sent on quiz answers.
	public var confidence: Double?

	public init(dontKnow: Bool? = nil, values: [String]? = nil, other: String? = nil, text: String? = nil,
		thinking: String? = nil, readingThinking: String? = nil, confidence: Double? = nil)
	{
		self.dontKnow = dontKnow
		self.values = values
		self.other = other
		self.text = text
		self.thinking = thinking
		self.readingThinking = readingThinking
		self.confidence = confidence
	}
}

/// The confidence slider's snap stops (owner, 2026-10-01): resolution
/// concentrates at the top; 50 is a genuine coin flip and the resting default.
public let CONFIDENCE_STOPS: [Double] = [0, 30, 50, 70, 90, 100]
public let DEFAULT_CONFIDENCE_INDEX = 2

// MARK: - Dock selection (the client state machine)

/// 0-based indices in display order.
public struct DockSelection: Sendable, Hashable {
	public var selected: Set<Int>
	public var otherSelected: Bool
	public var dontKnow: Bool
	public init(selected: Set<Int> = [], otherSelected: Bool = false, dontKnow: Bool = false) {
		self.selected = selected
		self.otherSelected = otherSelected
		self.dontKnow = dontKnow
	}
}

public func emptyDockSelection() -> DockSelection { DockSelection() }

/// Single-select: the option becomes THE answer and displaces "Other".
/// Multi-select: it toggles alongside its siblings AND "Other".
public func toggleOption(_ mode: SelectMode, _ sel: DockSelection, _ idx: Int) -> DockSelection {
	if mode == .multiSelect {
		var selected = sel.selected
		if selected.contains(idx) { selected.remove(idx) } else { selected.insert(idx) }
		return DockSelection(selected: selected, otherSelected: sel.otherSelected, dontKnow: false)
	}
	return DockSelection(selected: [idx], otherSelected: false, dontKnow: false)
}

/// Single-select: "Other…" displaces the listed options. Multi-select: it
/// toggles alone and clears nothing.
public func toggleOther(_ mode: SelectMode, _ sel: DockSelection) -> DockSelection {
	if mode == .multiSelect {
		return DockSelection(selected: sel.selected, otherSelected: !sel.otherSelected, dontKnow: false)
	}
	return DockSelection(selected: [], otherSelected: true, dontKnow: false)
}

// MARK: - Options

/// Trim labels, default value to the label, drop empty labels, throw on a
/// duplicate value.
public func normalizeOptions(_ options: [QuizOptionInput]) throws -> [QuizOption] {
	var seen = Set<String>()
	var out: [QuizOption] = []
	for option in options {
		let label = option.label.jsTrimmed
		let value = option.value?.jsTrimmed ?? ""
		let description = option.description?.jsTrimmed ?? ""
		let normalized = QuizOption(label: label, value: value.isEmpty ? label : value, description: description.isEmpty ? nil : description)
		if normalized.label.isEmpty { continue }
		if seen.contains(normalized.value) { throw QuestionCoreError.duplicateOptionValue(normalized.value) }
		seen.insert(normalized.value)
		out.append(normalized)
	}
	return out
}

/// The persisted-call form: coerces GLM's string-encoded options first
/// (parseOptionsIfString); a non-array yields no options.
public func normalizeOptions(_ options: JSONValue?) throws -> [QuizOption] {
	guard let list = parseOptionsIfString(options)?.arrayValue else { return [] }
	let inputs = try list.map { item -> QuizOptionInput in
		func optionalString(_ key: String) throws -> String? {
			switch item[key] {
			case nil, .null?: return nil
			case .string(let s)?: return s
			default: throw QuestionCoreError.malformedOption
			}
		}
		guard let label = item["label"]?.stringValue else { throw QuestionCoreError.malformedOption }
		return QuizOptionInput(label: label, value: try optionalString("value"), description: try optionalString("description"))
	}
	return try normalizeOptions(inputs)
}

/// mulberry32 seeded by a string (FNV-1a over UTF-16 units) — the
/// deterministic, per-toolCallId shuffle.
public func seededRandom(_ seed: String) -> () -> Double {
	var h: UInt32 = 2166136261
	for unit in seed.utf16 {
		h ^= UInt32(unit)
		h = h &* 16777619
	}
	var a = h
	return {
		a = a &+ 0x6d2b79f5
		var t = (a ^ (a >> 15)) &* (1 | a)
		t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
		return Double(t ^ (t >> 14)) / 4294967296
	}
}

/// Fisher–Yates over a copy with an injectable RNG (pass
/// `seededRandom(toolCallId)` for a stable per-question order).
public func shuffleOptions(_ options: [QuizOption], rand: () -> Double = { Double.random(in: 0..<1) }) -> [QuizOption] {
	var out = options
	var i = out.count - 1
	while i > 0 {
		let j = Int((rand() * Double(i + 1)).rounded(.down))
		out.swapAt(i, j)
		i -= 1
	}
	return out
}

// MARK: - Quiz grading

/// Preserve an exact option key before trying copy-syntax cleanup (a final
/// period or quotes can be CONTENT — calculus incident, 2026-10-12);
/// non-matches get the debris strip and JSON-stringified multi-select
/// coercion. Canonical option keys are never rewritten.
public func coerceCorrectAnswer(_ correctAnswer: CorrectAnswer, optionValues: [String]) -> [String] {
	func clean(_ value: String) -> String {
		let trimmed = value.jsTrimmed
		return optionValues.contains(trimmed) ? trimmed : stripModelValueDebris(value)
	}
	switch correctAnswer {
	case .multiple(let a):
		return a.map(clean)
	case .single(let s):
		let trimmed = s.jsTrimmed
		// An exact string key can itself look like a JSON array.
		if optionValues.contains(trimmed) { return [trimmed] }
		if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let parsed = JSONValue.tryParse(trimmed)?.arrayValue {
			return parsed.map { clean(TypeboxTry.jsString($0)) }
		}
		return [clean(s)]
	}
}

/// Resolve author-supplied value(s) to sorted, deduped 1-based display
/// indices. Must run AFTER shuffling; a typo is a hard error.
public func resolveCorrect(_ correctAnswer: CorrectAnswer?, options: [QuizOption]) -> (indices: [Int], error: String?) {
	guard let correctAnswer else { return ([], "correctAnswer is required") }
	let arr = coerceCorrectAnswer(correctAnswer, optionValues: options.map(\.value))
	if arr.isEmpty { return ([], "correctAnswer is required") }
	var byValue: [String: Int] = [:]
	for (i, o) in options.enumerated() { byValue[o.value] = i + 1 }
	var indices: [Int] = []
	for raw in arr {
		let v = raw.jsTrimmed
		guard let idx = byValue[v] else {
			let known = options.map { "\"\($0.value)\"" }.joined(separator: ", ")
			return ([], "correctAnswer \"\(v)\" does not match any option value (\(known))")
		}
		indices.append(idx)
	}
	return (Array(Set(indices)).sorted(), nil)
}

/// Exact-set match: same number of selections, same indices.
public func isCorrect(_ selectedIndices: [Int], _ correctIndices: [Int]) -> Bool {
	selectedIndices.count == correctIndices.count && selectedIndices.sorted() == correctIndices.sorted()
}

// MARK: - Arming + answering

public func toClientQuestion(_ qd: QuestionData) -> ClientQuestion {
	ClientQuestion(id: qd.id, kind: qd.kind, question: qd.question, context: qd.context, mode: qd.mode, options: qd.options)
}

/// JS `Math.round` (ties toward +∞).
private func jsRound(_ x: Double) -> Double {
	guard x.isFinite else { return x }
	let f = x.rounded(.down)
	return x - f >= 0.5 ? f + 1 : f
}

/// JS `new Date(ms).toISOString()`.
private func isoTimestamp(_ ms: Int) -> String {
	var secs = ms / 1000, frac = ms % 1000
	if frac < 0 { secs -= 1; frac += 1000 }
	var cal = Calendar(identifier: .gregorian)
	cal.timeZone = TimeZone(identifier: "UTC")!
	let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(secs)))
	return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, frac)
}

/// Turn an AnswerRequest into the full answer record. Quiz answers are
/// graded here; ask and explain are not (the model grades explain against
/// its commitment).
public func buildAnswer(_ qd: QuestionData, _ req: AnswerRequest, tool: String? = nil, now: Int = MessageID.nowMillis()) -> QuestionAnswerData {
	func trimmedOrNil(_ s: String?) -> String? {
		guard let t = s?.jsTrimmed, !t.isEmpty else { return nil }
		return t
	}
	var base = QuestionAnswerData(kind: qd.kind, questionText: qd.question, dontKnow: req.dontKnow == true, answers: [], answeredAt: isoTimestamp(now))
	if let tool, !tool.isEmpty { base.tool = tool }
	base.questionType = qd.questionType
	base.options = qd.options.enumerated().map { .init(index: $0.offset + 1, label: $0.element.label) }
	base.thinking = trimmedOrNil(req.thinking)
	base.readingThinking = trimmedOrNil(req.readingThinking)
	// Resolve selected values → OptionAnswer, in display order.
	if let values = req.values, !values.isEmpty {
		var byValue: [String: OptionAnswer] = [:]
		for (i, o) in qd.options.enumerated() { byValue[o.value] = OptionAnswer(label: o.label, value: o.value, index: i + 1) }
		let picked = values.compactMap { byValue[$0] } // unknown values are ignored
		base.answers = picked.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element)
	}
	base.other = trimmedOrNil(req.other)
	base.text = trimmedOrNil(req.text)

	if qd.kind == .quiz {
		base.correctIndices = qd.correctIndices ?? []
		base.explanation = qd.explanation
		base.correct = base.dontKnow ? false : isCorrect(base.answers.map(\.index), qd.correctIndices ?? [])
		// Confidence rides real quiz answers only — never "I don't know".
		if !base.dontKnow, let c = req.confidence {
			let r = jsRound(c)
			base.confidence = r.isNaN ? r : Swift.max(0, Swift.min(100, r))
		}
	}
	if qd.kind == .explain {
		base.committed = qd.committedAnswer
	}
	return base
}

/// The dismissal record (ESC-abort from a pending question): the minimum
/// honest answer — the model sees `{kind, dismissed: true}`.
public func dismissedAnswer(_ kind: QuestionKind, questionText: String, now: Int = MessageID.nowMillis()) -> QuestionAnswerData {
	var ad = QuestionAnswerData(kind: kind, questionText: questionText, dontKnow: false, answers: [], answeredAt: isoTimestamp(now))
	ad.dismissed = true
	return ad
}

/// The set-aside record (Discuss.swift): the model sees `{kind, discussed: true, note}`.
public func discussedAnswer(_ kind: QuestionKind, questionText: String, now: Int = MessageID.nowMillis()) -> QuestionAnswerData {
	var ad = QuestionAnswerData(kind: kind, questionText: questionText, dontKnow: false, answers: [], answeredAt: isoTimestamp(now))
	ad.discussed = true
	return ad
}

/// The MODEL-VISIBLE answer (tool-result diet, 2026-10-02): only what the
/// learner added — selection or words, verdict, confidence, the two thinking
/// channels. Everything the model authored already rides the call. Reads any
/// JSON (foreign / legacy records degrade to omission, never crash).
public func compactAnswerForModel(_ ad: JSONValue) -> JSONObject {
	var out = JSONObject()
	out["kind"] = ad["kind"]
	if ad["dismissed"]?.isTruthy == true {
		out["dismissed"] = true
		return out
	}
	if ad["discussed"]?.isTruthy == true {
		out["discussed"] = true
		out["note"] = .string(DISCUSSED_NOTE)
		return out
	}
	let dontKnow = ad["dontKnow"]?.isTruthy == true
	if dontKnow { out["dontKnow"] = true }
	if let answers = ad["answers"]?.arrayValue, !answers.isEmpty {
		out["answers"] = .array(answers.map { a in
			var o = JSONObject()
			o["index"] = a["index"]
			o["label"] = a["label"]
			return .object(o)
		})
	}
	if let text = ad["text"], text.isTruthy { out["text"] = text }
	if let other = ad["other"], other.isTruthy { out["other"] = other }
	// dontKnow implies incorrect and carries no confidence.
	if let correct = ad["correct"], !dontKnow { out["correct"] = correct }
	if let confidence = ad["confidence"] { out["confidence"] = confidence }
	// `note` is the pre-rename key — old records feed `thinking` too.
	let thinkingKey = ad["thinking"].flatMap { $0.isNull ? nil : $0 }
	if let thinking = thinkingKey ?? ad["note"], thinking.isTruthy { out["thinking"] = thinking }
	if let reading = ad["readingThinking"], reading.isTruthy { out["thinkingWhileReading"] = reading }
	return out
}

public func compactAnswerForModel(_ ad: QuestionAnswerData) -> JSONObject {
	compactAnswerForModel(ad.json)
}
