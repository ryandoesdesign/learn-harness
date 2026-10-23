import Foundation

// Port of src/core/tool-parts.ts — the UI parse seam: parse, don't cast.
// Model-authored INPUT (live partials, the raw args of rejected calls) is
// consumed only through these parsers, each running the SAME schema the
// model faced — boundary-valid ⇔ consumer-parseable. A failure is nil (the
// quiet fallback), never a crash.

// MARK: - Parsed inputs (the cleaned objects, typed)

/// A parsed quiz call: the display schema (base + optional lenient `type`);
/// the teacher-only `nodeId` is cleaned away.
public struct QuizToolInput: Sendable, Hashable {
	/// The cleaned object, exactly as the TS parse returns it.
	public var json: JSONValue
	public var question: String
	public var options: [QuizOptionInput]
	public var multiSelect: Bool?
	public var explanation: String
	public var correctAnswer: CorrectAnswer
	public var details: String?
	/// Raw role string — read through normalizeQuizType.
	public var type: String?

	init?(cleaned v: JSONValue) {
		guard let question = v["question"]?.stringValue, let explanation = v["explanation"]?.stringValue,
			let options = optionInputs(v["options"]), let correct = v["correctAnswer"].flatMap(CorrectAnswer.init(json:))
		else { return nil }
		json = v
		self.question = question
		self.options = options
		multiSelect = v["multiSelect"]?.boolValue
		self.explanation = explanation
		correctAnswer = correct
		details = v["details"]?.stringValue
		type = v["type"]?.stringValue
	}
}

/// A parsed ask_user_question call (no options = free-text mode).
public struct AskToolInput: Sendable, Hashable {
	public var json: JSONValue
	public var question: String
	public var details: String?
	public var options: [QuizOptionInput]?
	public var multiSelect: Bool?

	init?(cleaned v: JSONValue) {
		guard let question = v["question"]?.stringValue else { return nil }
		json = v
		self.question = question
		details = v["details"]?.stringValue
		if let raw = v["options"] {
			guard let options = optionInputs(raw) else { return nil }
			self.options = options
		}
		multiSelect = v["multiSelect"]?.boolValue
	}
}

/// A parsed explain / recall call (display schema; nodeId cleaned away).
public struct ExplainToolInput: Sendable, Hashable {
	public var json: JSONValue
	public var question: String
	public var correctAnswer: String
	public var details: String?
	public var type: String?

	init?(cleaned v: JSONValue) {
		guard let question = v["question"]?.stringValue, let correct = v["correctAnswer"]?.stringValue else { return nil }
		json = v
		self.question = question
		correctAnswer = correct
		details = v["details"]?.stringValue
		type = v["type"]?.stringValue
	}
}

private func optionInputs(_ v: JSONValue?) -> [QuizOptionInput]? {
	guard let items = v?.arrayValue else { return nil }
	var out: [QuizOptionInput] = []
	for item in items {
		guard let label = item["label"]?.stringValue else { return nil }
		out.append(QuizOptionInput(label: label, value: item["value"]?.stringValue, description: item["description"]?.stringValue))
	}
	return out
}

// MARK: - The seam

/// LaTeX-escape restoration, deep over every string value: records persist
/// RAW call args, so JSON-escape debris (FF ate the 'f' of \forall) and
/// doubled command backslashes heal here, at the one display seam.
private func restoreMathEscapesDeep(_ value: JSONValue) -> JSONValue {
	switch value {
	case .string(let s): .string(repairMathForDisplay(s))
	case .array(let a): .array(a.map(restoreMathEscapesDeep))
	case .object(let o): .object(JSONObject(pairs: o.map { ($0.key, restoreMathEscapesDeep($0.value)) }))
	default: value
	}
}

/// The pi-boundary parse mirrored: Convert before Check (a `correctAnswer`
/// sent as the NUMBER 17 converts to "17" at the boundary, so the display
/// must too, or the posed quiz renders nowhere), then Clean.
private func boundaryParse(_ schema: JSONSchema, _ input: JSONValue) -> JSONValue? {
	switch input {
	case .object, .array: break // JS `typeof input === "object"`
	default: return nil
	}
	let converted = schema.convert(input)
	guard schema.check(converted) else { return nil }
	return schema.clean(converted)
}

/// Quiz parse for DISPLAY: the lenient common core of both boundaries, plus
/// the shared grading refinement (quizInputProblems) — an input that could
/// never have been posed renders as the quiet fallback. The argument heal
/// runs first: the record keeps the RAW wobbled arguments.
public func parseQuizInput(_ input: JSONValue) -> QuizToolInput? {
	let healed = healEncodedArguments(restoreMathEscapesDeep(input), schema: quizDisplayInputSchema)
	guard let cleaned = boundaryParse(quizDisplayInputSchema, healed).flatMap(QuizToolInput.init(cleaned:)) else { return nil }
	if !quizInputProblems(options: cleaned.options, correctAnswer: cleaned.correctAnswer, multiSelect: cleaned.multiSelect).isEmpty { return nil }
	return cleaned
}

/// Ask parse for DISPLAY: the full ask schema plus the option sanity the
/// boundary enforced (duplicate values break the dock's keying).
public func parseAskInput(_ input: JSONValue) -> AskToolInput? {
	guard let cleaned = boundaryParse(askInputSchema, restoreMathEscapesDeep(input)).flatMap(AskToolInput.init(cleaned:)) else { return nil }
	if !askOptionProblems(cleaned.options ?? []).isEmpty { return nil }
	return cleaned
}

/// Explain parse for DISPLAY: the display schema plus the commitment
/// refinement.
public func parseExplainInput(_ input: JSONValue) -> ExplainToolInput? {
	guard let cleaned = boundaryParse(explainDisplayInputSchema, restoreMathEscapesDeep(input)).flatMap(ExplainToolInput.init(cleaned:)) else { return nil }
	if !explainInputProblems(correctAnswer: cleaned.correctAnswer).isEmpty { return nil }
	return cleaned
}

/// probe_done parse — the core-owned schema the tool itself declares.
public func parseProbeDoneInput(_ input: JSONValue) -> ProbeDoneInput? {
	guard let cleaned = boundaryParse(probeDoneInputSchema, input) else { return nil }
	return try? JSONCodec.decode(ProbeDoneInput.self, from: cleaned)
}
