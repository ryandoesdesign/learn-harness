import Foundation
import Testing
@testable import LHCore

// Port of tests/question-core.test.ts.

/// quizInputProblems over a raw (structurally valid) input object.
func questionsQuizProblems(_ v: JSONValue) -> [String] {
	let options = (v["options"]?.arrayValue ?? []).map { QuizOptionInput(label: $0["label"]?.stringValue ?? "", value: $0["value"]?.stringValue) }
	guard let answer = v["correctAnswer"].flatMap(CorrectAnswer.init(json:)) else { return ["(test) correctAnswer has no string shape"] }
	return quizInputProblems(options: options, correctAnswer: answer, multiSelect: v["multiSelect"]?.boolValue)
}

func questionsAskProblems(_ v: JSONValue) -> [String] {
	askOptionProblems((v["options"]?.arrayValue ?? []).map { QuizOptionInput(label: $0["label"]?.stringValue ?? "", value: $0["value"]?.stringValue) })
}

/// The boundary predicate: structural check AND zero authoring problems.
func questionsBoundaryOk(_ schema: JSONSchema, _ input: JSONValue, _ problems: [String]) -> Bool {
	schema.check(input) && problems.isEmpty
}

func questionsWith(_ v: JSONValue, _ changes: KeyValuePairs<String, JSONValue?>) -> JSONValue {
	var o = v.objectValue ?? JSONObject()
	for (k, x) in changes { o[k] = x }
	return .object(o)
}

private let planetQuiz: JSONValue = [
	"question": "Which planet is closest to the Sun?",
	"options": [["label": "Venus"], ["label": "Mercury"], ["label": "Mars"]],
	"correctAnswer": "Mercury",
	"explanation": "Mercury is the innermost planet.",
	"type": "check",
	"nodeId": "planet-order",
]

private func quizData(kind: QuestionKind = .quiz, mode: QuestionMode = .singleSelect, options: [QuizOptionInput]? = nil,
	correctIndices: [Int]? = [1], explanation: String? = "Mercury orbits closest.") throws -> QuestionData
{
	let opts = try normalizeOptions(options ?? [QuizOptionInput(label: "Mercury", value: "mercury"), QuizOptionInput(label: "Venus", value: "venus")])
	return QuestionData(id: "q_test", kind: kind, question: "Which planet is closest to the Sun?", mode: mode, options: opts,
		correctIndices: correctIndices, explanation: explanation, createdAt: "2026-01-01T00:00:00Z")
}

@Suite struct QuestionsSchemaOrderTests {
	@Test func emitsExplanationImmediatelyBeforeCorrectAnswer() {
		for schema in [quizInputSchema, probeQuizInputSchema] {
			let keys = schema.properties.map(\.name)
			#expect(keys.firstIndex(of: "explanation")! < keys.firstIndex(of: "correctAnswer")!)
			#expect(keys == (schema == quizInputSchema
				? ["type", "nodeId", "question", "options", "multiSelect", "explanation", "correctAnswer", "details"]
				: ["question", "options", "multiSelect", "explanation", "correctAnswer", "details"]))
		}
	}
}

@Suite struct QuestionsQuizContractTests {
	@Test func acceptsAValidSingleSelectQuiz() {
		#expect(questionsBoundaryOk(quizInputSchema, planetQuiz, questionsQuizProblems(planetQuiz)))
		#expect(questionsQuizProblems(planetQuiz) == [])
	}

	@Test func acceptsExplicitValuesAndMultiSelectArrays() {
		let multi = questionsWith(planetQuiz, [
			"options": [["label": "A", "value": "a"], ["label": "B", "value": "b"], ["label": "C", "value": "c"]],
			"correctAnswer": ["a", "b"], "multiSelect": true,
		])
		#expect(questionsBoundaryOk(quizInputSchema, multi, questionsQuizProblems(multi)))
		let stringified = questionsWith(multi, ["correctAnswer": .string(multi["correctAnswer"]!.serialized())])
		#expect(questionsBoundaryOk(quizInputSchema, stringified, questionsQuizProblems(stringified)))
		#expect(questionsQuizProblems(stringified) == [])
	}

	@Test func rejectsASlugMatchingNoOptionListingTheValidValues() {
		let bad: JSONValue = [
			"question": "What is Nietzsche's genealogical claim about religion?",
			"options": [["label": "A cultural diagnosis"], ["label": "Atheism as a conclusion"], ["label": "A call to convert people"]],
			"correctAnswer": "cultural-diagnosis",
			"explanation": "...",
		]
		#expect(!questionsBoundaryOk(quizInputSchema, bad, questionsQuizProblems(bad)))
		let problems = questionsQuizProblems(bad)
		#expect(problems.count == 1)
		#expect(problems[0].contains("does not match any option value"))
		#expect(problems[0].contains("\"A cultural diagnosis\""))
	}

	@Test func rejectsMultipleCorrectAnswersWithoutMultiSelect() {
		let bad = questionsWith(planetQuiz, ["correctAnswer": ["Venus", "Mercury"]])
		#expect(!questionsBoundaryOk(quizInputSchema, bad, questionsQuizProblems(bad)))
		#expect(questionsQuizProblems(bad).joined(separator: " ").contains("multiSelect"))
	}

	@Test func rejectsDuplicateOptionValues() {
		let bad = questionsWith(planetQuiz, ["options": [["label": "Mercury", "value": "same"], ["label": "Venus", "value": "same"]]])
		#expect(!questionsBoundaryOk(quizInputSchema, bad, questionsQuizProblems(bad)))
		#expect(questionsQuizProblems(bad).joined(separator: " ").contains("same value"))
	}

	@Test func rejectsAnEmptyOptionLabel() {
		let bad = questionsWith(planetQuiz, ["options": [["label": "  "], ["label": "Mercury"], ["label": "Mars"]]])
		#expect(!questionsBoundaryOk(quizInputSchema, bad, questionsQuizProblems(bad)))
		#expect(questionsQuizProblems(bad).joined(separator: " ").contains("label is empty"))
	}

	@Test func requiresAResolvableCorrectAnswer() {
		let empty = questionsWith(planetQuiz, ["correctAnswer": ""])
		let brackets = questionsWith(planetQuiz, ["correctAnswer": "[]"])
		#expect(!questionsBoundaryOk(quizInputSchema, empty, questionsQuizProblems(empty)))
		#expect(!questionsBoundaryOk(quizInputSchema, brackets, questionsQuizProblems(brackets)))
		#expect(questionsQuizProblems(empty).joined(separator: " ").contains("required"))
	}
}

@Suite struct QuestionsAskContractTests {
	@Test func acceptsAValidAsk() {
		let ask: JSONValue = ["question": "Which topic first?", "options": [["label": "Limits"], ["label": "Chain rule"]]]
		#expect(questionsBoundaryOk(askInputSchema, ask, questionsAskProblems(ask)))
	}

	@Test func rejectsDuplicateValuesAndEmptyLabels() {
		let bad: JSONValue = ["question": "?", "options": [["label": "A", "value": "x"], ["label": "B", "value": "x"]]]
		#expect(!questionsBoundaryOk(askInputSchema, bad, questionsAskProblems(bad)))
		#expect(questionsAskProblems(bad).joined(separator: " ").contains("same value"))
		let emptyLabel: JSONValue = ["question": "?", "options": [["label": ""], ["label": "B"]]]
		#expect(!questionsBoundaryOk(askInputSchema, emptyLabel, questionsAskProblems(emptyLabel)))
		#expect(questionsAskProblems(emptyLabel).joined(separator: " ").contains("label is empty"))
	}
}

@Suite struct QuestionsNormalizeOptionsTests {
	@Test func trimsLabelsAndDefaultsValueToLabel() throws {
		let opts = try normalizeOptions([QuizOptionInput(label: "  Mercury  "), QuizOptionInput(label: "Venus", value: " v ")])
		#expect(opts == [QuizOption(label: "Mercury", value: "Mercury"), QuizOption(label: "Venus", value: "v")])
	}

	@Test func dropsEmptyLabels() throws {
		#expect(try normalizeOptions([QuizOptionInput(label: ""), QuizOptionInput(label: "ok")]).count == 1)
	}

	@Test func throwsOnDuplicateValuesAndCoercesStringEncodedOptions() throws {
		#expect(throws: QuestionCoreError.duplicateOptionValue("x")) {
			try normalizeOptions([QuizOptionInput(label: "a", value: "x"), QuizOptionInput(label: "b", value: "x")])
		}
		let encoded: JSONValue = [["label": "Slope", "value": "slope"], ["label": "Value", "value": "value"]]
		let asString = JSONValue.string(encoded.serialized())
		#expect(try normalizeOptions(asString) == [QuizOption(label: "Slope", value: "slope"), QuizOption(label: "Value", value: "value")])
		#expect(try normalizeOptions(JSONValue.string("not json")) == [])
	}

	@Test func quizOptionsCarryNoDescriptionAskKeepsIt() throws {
		guard case .array(let quizItem, _)? = quizInputBase.property("options")?.kind,
			case .array(let askItem, _)? = askInputSchema.property("options")?.kind
		else { Issue.record("options are arrays"); return }
		#expect(quizItem.property("description") == nil, "quiz option schema has no description")
		#expect(askItem.property("description") != nil, "ask option schema keeps description")
	}

	@Test func handlesUndefinedInput() throws {
		#expect(try normalizeOptions(nil as JSONValue?) == [])
	}
}

@Suite struct QuestionsShuffleTests {
	@Test func permutesWithoutAddingRemovingOrMutating() {
		let input = (0..<20).map { QuizOption(label: "o\($0)", value: "o\($0)") }
		let shuffled = shuffleOptions(input)
		#expect(shuffled.count == input.count)
		#expect(shuffled.sorted { Int($0.label.dropFirst())! < Int($1.label.dropFirst())! } == input)
	}

	@Test func isStableForSingleAndEmptyInputs() {
		#expect(shuffleOptions([]) == [])
		#expect(shuffleOptions([QuizOption(label: "only", value: "only")]) == [QuizOption(label: "only", value: "only")])
	}
}

@Suite struct QuestionsCoerceCorrectAnswerTests {
	let values = ["mercury", "a", "b"]

	@Test func wrapsASingleString() { #expect(coerceCorrectAnswer(.single("mercury"), optionValues: values) == ["mercury"]) }
	@Test func passesArraysThrough() { #expect(coerceCorrectAnswer(.multiple(["a", "b"]), optionValues: values) == ["a", "b"]) }
	@Test func parsesAJSONStringifiedMultiSelectArray() { #expect(coerceCorrectAnswer(.single(#"["a", "b"]"#), optionValues: values) == ["a", "b"]) }
	@Test func leavesANonJSONBracketedStringAlone() { #expect(coerceCorrectAnswer(.single("[not json"), optionValues: values) == ["[not json"]) }

	@Test func preservesAnExactKeyThatLooksLikeAJSONArray() {
		let key = #"["a", "b"]"#
		#expect(coerceCorrectAnswer(.single(key), optionValues: values + [key]) == [key])
		#expect(coerceCorrectAnswer(.single("[]"), optionValues: ["[]"]) == ["[]"])
	}
}

@Suite struct QuestionsResolveCorrectTests {
	let options = try! normalizeOptions([
		QuizOptionInput(label: "Mercury", value: "mercury"), QuizOptionInput(label: "Venus", value: "venus"), QuizOptionInput(label: "Earth", value: "earth"),
	])

	@Test func resolvesASingleValueToItsDisplayIndex() {
		let r = resolveCorrect(.single("venus"), options: options)
		#expect(r.indices == [2] && r.error == nil)
	}

	@Test func resolvesMultiSelectValuesDedupedAndSorted() {
		let r = resolveCorrect(.multiple(["earth", "mercury", "mercury"]), options: options)
		#expect(r.indices == [1, 3] && r.error == nil)
	}

	@Test func errorsWhenTheValueMatchesNoOption() {
		let r = resolveCorrect(.single("mars"), options: options)
		#expect(r.error?.contains("does not match any option value") == true)
	}

	@Test func errorsOnMissingCorrectAnswer() { #expect(resolveCorrect(nil, options: options).error != nil) }

	@Test func resolvesAgainstPostShuffleOrder() {
		let shuffled = shuffleOptions(options)
		let r = resolveCorrect(.single("earth"), options: shuffled)
		#expect(r.indices == [shuffled.firstIndex { $0.value == "earth" }! + 1])
	}
}

@Suite struct QuestionsExactMembershipTests {
	@Test func theCalculusLabelsFinalPeriodSurvivesEverySeam() throws {
		let correct = "$f$ need not be differentiable at $a$."
		let input: JSONValue = [
			"question": "All partial derivatives of $f$ exist at $a$. Must $f$ be differentiable there?",
			"options": [["label": "$f$ is differentiable at $a$."], ["label": .string(correct)]],
			"explanation": "Existing partial derivatives need not give a linear approximation.",
			"correctAnswer": .string(correct),
		]
		let before = input.serialized()
		#expect(questionsBoundaryOk(probeQuizInputSchema, input, questionsQuizProblems(input)))
		let parsed = try #require(parseQuizInput(input), "the accepted raw call must also render")
		#expect(parsed.correctAnswer == .single(correct))
		let options = Array(try normalizeOptions(parsed.options).reversed())
		let resolved = resolveCorrect(parsed.correctAnswer, options: options)
		#expect(resolved.indices == [1] && resolved.error == nil)
		let qd = QuestionData(id: "calculus-period", kind: .quiz, question: parsed.question, mode: .singleSelect, options: options,
			correctIndices: resolved.indices, explanation: parsed.explanation, createdAt: "2026-10-12T00:00:00Z")
		#expect(buildAnswer(qd, AnswerRequest(values: [correct])).correct == true)
		#expect(buildAnswer(qd, AnswerRequest(values: ["$f$ is differentiable at $a$."])).correct == false)
		#expect(input.serialized() == before, "raw arguments are never rewritten")
	}

	@Test func retainsPunctuationQuotesColonsAndBackticksInExactKeys() throws {
		for key in ["value.", "value:", "\"value\"", "'value'", "`value`", ":value"] {
			for option: JSONValue in [["label": .string(key)], ["label": "A claim", "value": .string(key)]] {
				let input: JSONValue = [
					"question": "Which claim?", "options": [option, ["label": "Other", "value": "other"]],
					"explanation": "The first claim follows.", "correctAnswer": .string(key),
				]
				#expect(questionsQuizProblems(input) == [], "\(key)")
				#expect(parseQuizInput(input) != nil, "\(key)")
				#expect(resolveCorrect(.single(key), options: try normalizeOptions(input["options"])).indices == [1], "\(key)")
			}
		}
	}

	@Test func neverRedirectsAnExactPunctuatedKey() throws {
		let keys = ["value", "value.", "\"value\"", "`value`", ":value"]
		let options = try normalizeOptions(keys.enumerated().map { QuizOptionInput(label: "Claim \($0.offset)", value: $0.element) })
		for (i, key) in keys.enumerated() {
			let r = resolveCorrect(.single(key), options: options)
			#expect(r.indices == [i + 1] && r.error == nil, "\(key)")
		}
		#expect(options.map(\.value) == keys, "canonical keys stay distinct and untouched")
	}

	@Test func preservesExactMultiSelectEntriesWhileHealingDebris() throws {
		let input: JSONValue = [
			"question": "Which claims?", "options": [["label": "First."], ["label": "Second", "value": "second"]],
			"explanation": "Both claims follow.", "multiSelect": true,
		]
		let array: JSONValue = ["First.", ": \"second\""]
		for correctAnswer in [array, .string(array.serialized())] {
			let full = questionsWith(input, ["correctAnswer": correctAnswer])
			#expect(questionsQuizProblems(full) == [])
			#expect(parseQuizInput(full) != nil)
			let r = resolveCorrect(CorrectAnswer(json: correctAnswer), options: try normalizeOptions(input["options"]))
			#expect(r.indices == [1, 2] && r.error == nil)
		}
	}

	@Test func retainsAnExactJSONLookingOptionKey() throws {
		let key = #"["a", "b"]"#
		let input: JSONValue = [
			"question": "Which literal?", "options": [["label": .string(key)], ["label": "Other"]],
			"explanation": "The first literal is intended.", "correctAnswer": .string(key),
		]
		#expect(questionsQuizProblems(input) == [])
		#expect(parseQuizInput(input) != nil)
		#expect(resolveCorrect(.single(key), options: try normalizeOptions(input["options"])).indices == [1])
	}
}

@Suite struct QuestionsIsCorrectTests {
	@Test func matchesIdenticalSetsRegardlessOfOrder() { #expect(isCorrect([3, 1], [1, 3])) }
	@Test func rejectsPartialMatches() {
		#expect(!isCorrect([1], [1, 3]))
		#expect(!isCorrect([1, 2, 3], [1, 3]))
	}
	@Test func rejectsWrongSelectionsOfTheSameSize() { #expect(!isCorrect([1, 2], [1, 3])) }
	@Test func rejectsEmptySelectionAgainstANonEmptyAnswer() { #expect(!isCorrect([], [1])) }
}

@Suite struct QuestionsConfidenceStopsTests {
	@Test func theOwnerDecidedGrid() {
		#expect(CONFIDENCE_STOPS == [0, 30, 50, 70, 90, 100])
		#expect(CONFIDENCE_STOPS[DEFAULT_CONFIDENCE_INDEX] == 50, "rests at a real coin flip")
	}
}

@Suite struct QuestionsBuildAnswerTests {
	@Test func gradesACorrectSelection() throws {
		let ad = buildAnswer(try quizData(), AnswerRequest(values: ["mercury"]))
		#expect(ad.correct == true)
		#expect(ad.answers.first?.label == "Mercury")
		#expect(ad.answers.first?.index == 1)
		#expect(ad.dontKnow == false)
	}

	@Test func gradesAWrongSelection() throws {
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["venus"])).correct == false)
	}

	@Test func dontKnowIsNeverCorrectAndRecordsNoAnswers() throws {
		let ad = buildAnswer(try quizData(), AnswerRequest(dontKnow: true))
		#expect(ad.correct == false)
		#expect(ad.dontKnow == true)
		#expect(ad.answers == [])
	}

	@Test func keepsTheNoteOnlyWhenNonEmpty() throws {
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], thinking: "  ")).thinking == nil)
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], thinking: " x ")).thinking == "x")
	}

	@Test func ignoresUnknownOptionValues() throws {
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mars", "mercury"])).answers.map(\.value) == ["mercury"])
	}

	@Test func carriesConfidenceOnQuizAnswersAndClamps() throws {
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], confidence: 90)).confidence == 90)
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], confidence: 150)).confidence == 100)
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], confidence: -5)).confidence == 0)
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"])).confidence == nil)
		// JS Math.round: ties toward +∞.
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], confidence: 70.5)).confidence == 71)
		#expect(buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], confidence: -0.5)).confidence == 0)
	}

	@Test func dropsConfidenceOnDontKnowAndNonQuizKinds() throws {
		#expect(buildAnswer(try quizData(), AnswerRequest(dontKnow: true, confidence: 70)).confidence == nil)
		let ask = try quizData(kind: .ask, correctIndices: nil, explanation: nil)
		#expect(buildAnswer(ask, AnswerRequest(other: "x", confidence: 70)).confidence == nil)
	}

	@Test func multiSelectGradesAsExactSet() throws {
		let multi = try quizData(mode: .multiSelect, options: [
			QuizOptionInput(label: "A", value: "a"), QuizOptionInput(label: "B", value: "b"), QuizOptionInput(label: "C", value: "c"),
		], correctIndices: [1, 2])
		#expect(buildAnswer(multi, AnswerRequest(values: ["a", "b"])).correct == true)
		#expect(buildAnswer(multi, AnswerRequest(values: ["a"])).correct == false)
		#expect(buildAnswer(multi, AnswerRequest(values: ["a", "b", "c"])).correct == false)
	}

	@Test func askQuestionsAreNotGraded() throws {
		let ask = try quizData(kind: .ask, correctIndices: nil, explanation: nil)
		#expect(buildAnswer(ask, AnswerRequest(values: ["mercury"])).correct == nil)
	}

	@Test func answeredAtIsTheJSISOStringOfNow() throws {
		#expect(buildAnswer(try quizData(), AnswerRequest(), now: 1791626469187).answeredAt == "2026-10-10T10:01:09.187Z")
		#expect(buildAnswer(try quizData(), AnswerRequest(), now: 0).answeredAt == "1970-01-01T00:00:00.000Z")
	}
}

@Suite struct QuestionsCompactAnswerTests {
	@Test func quizCarriesOnlyWhatTheLearnerAdded() throws {
		let ad = buildAnswer(try quizData(), AnswerRequest(values: ["mercury"], thinking: "guessed", confidence: 70))
		let compact = compactAnswerForModel(ad)
		expectJSONEqual(.object(compact), [
			"kind": "quiz", "answers": [["index": 1, "label": "Mercury"]], "correct": true, "confidence": 70, "thinking": "guessed",
		])
		let raw = JSONValue.object(compact).serialized()
		#expect(!raw.contains("Which planet"), "no questionText")
		#expect(!raw.contains("Venus"), "no option-list restatement")
		#expect(!raw.contains("Mercury orbits closest"), "no explanation")
		#expect(compact["correctIndices"] == nil)
		#expect(compact["questionId"] == nil)
	}

	@Test func dontKnowStandsAlone() throws {
		expectJSONEqual(.object(compactAnswerForModel(buildAnswer(try quizData(), AnswerRequest(dontKnow: true)))), ["kind": "quiz", "dontKnow": true])
	}

	@Test func askSelectionOrTextNeverGraded() throws {
		let ask = try quizData(kind: .ask, mode: .text, correctIndices: nil, explanation: nil)
		expectJSONEqual(.object(compactAnswerForModel(buildAnswer(ask, AnswerRequest(text: "lateral thinking")))), ["kind": "ask", "text": "lateral thinking"])
	}

	@Test func dismissedIsAOneFieldRecord() throws {
		var ad = buildAnswer(try quizData(), AnswerRequest(dontKnow: true))
		ad.dismissed = true
		expectJSONEqual(.object(compactAnswerForModel(ad)), ["kind": "quiz", "dismissed": true])
	}
}

@Suite struct QuestionsDismissedAnswerTests {
	@Test func theMinimumHonestAnswer() {
		let ad = dismissedAnswer(.ask, questionText: "What drives you?")
		#expect(ad.kind == .ask)
		#expect(ad.questionText == "What drives you?")
		#expect(ad.dismissed == true)
		#expect(ad.dontKnow == false)
		#expect(ad.answers == [])
		#expect(!ad.answeredAt.isEmpty)
	}

	@Test func compactsToTheOneFieldDiet() {
		expectJSONEqual(.object(compactAnswerForModel(dismissedAnswer(.quiz, questionText: "Pick one"))), ["kind": "quiz", "dismissed": true])
	}
}

@Suite struct QuestionsClientQuestionTests {
	@Test func neverExposesCorrectIndicesOrExplanation() throws {
		let cq = toClientQuestion(try quizData())
		let raw = cq.json.serialized()
		#expect(!raw.contains("correctIndices"))
		#expect(!raw.contains("Mercury orbits closest"))
		#expect(cq.id == "q_test")
		#expect(cq.kind == .quiz)
		#expect(cq.options.count == 2)
	}
}

@Suite struct QuestionsDockSelectionTests {
	@Test func multiSelectOptionsAndOtherCoexist() {
		var sel = emptyDockSelection()
		sel = toggleOption(.multiSelect, sel, 0)
		sel = toggleOption(.multiSelect, sel, 1)
		#expect(sel.selected == [0, 1])
		sel = toggleOther(.multiSelect, sel)
		#expect(sel.selected == [0, 1], "Other never clears picked options")
		#expect(sel.otherSelected)
		sel = toggleOption(.multiSelect, sel, 2)
		#expect(sel.otherSelected, "options never clear a typed custom answer")
		#expect(sel.selected == [0, 1, 2])
		sel = toggleOption(.multiSelect, sel, 0)
		#expect(sel.selected == [1, 2])
		sel = toggleOther(.multiSelect, sel)
		#expect(!sel.otherSelected)
		#expect(sel.selected == [1, 2])
	}

	@Test func multiSelectAnySelectionClearsDontKnow() {
		var sel = DockSelection(dontKnow: true)
		sel = toggleOption(.multiSelect, sel, 0)
		#expect(!sel.dontKnow)
		sel = toggleOther(.multiSelect, sel)
		#expect(!sel.dontKnow)
	}

	@Test func singleSelectDisplacementSemantics() {
		var sel = emptyDockSelection()
		sel = toggleOption(.singleSelect, sel, 0)
		sel = toggleOther(.singleSelect, sel)
		#expect(sel.selected.isEmpty, "Other displaces the picked option")
		#expect(sel.otherSelected)
		sel = toggleOption(.singleSelect, sel, 1)
		#expect(!sel.otherSelected, "an option displaces Other")
		#expect(sel.selected == [1])
	}
}

@Suite struct QuestionsExplainContractTests {
	@Test func hasOneAuthoringField() {
		#expect(explainInputBase.properties.map(\.name) == ["question", "correctAnswer", "details"])
	}

	@Test func theTeachObjectLeadsWithTheRequiredPair() {
		#expect(explainInputObject.properties.map(\.name) == ["type", "nodeId"] + explainInputBase.properties.map(\.name))
	}

	@Test func anEmptyCommitmentIsTheOneAuthoringProblem() {
		#expect(explainInputProblems(correctAnswer: "Full speed is c.") == [])
		#expect(explainInputProblems(correctAnswer: "   ") == ["correctAnswer is required — commit to the full correct answer BEFORE posing the question."])
	}
}

@Suite struct QuestionsExplainAnswerTests {
	let commitment = "It ruled out the luminiferous aether — a stationary aether would produce a fringe shift, none was observed — and set up special relativity."

	func explainQD() -> QuestionData {
		QuestionData(id: "e1", kind: .explain, question: "Why does the Michelson-Morley null result matter?", mode: .text, options: [],
			committedAnswer: commitment, createdAt: "2026-01-01T00:00:00.000Z")
	}

	@Test func snapshotsTheCommitmentAndNeverGradesFreeText() {
		let ad = buildAnswer(explainQD(), AnswerRequest(text: "Something about light speed being constant?"))
		#expect(ad.correct == nil, "no client verdict — the model grades in its reply")
		#expect(ad.correctIndices == nil)
		#expect(ad.committed == commitment)
		#expect(ad.text == "Something about light speed being constant?")
	}

	@Test func dontKnowRecordsTheGapWithNoText() {
		let ad = buildAnswer(explainQD(), AnswerRequest(dontKnow: true))
		#expect(ad.dontKnow)
		#expect(ad.text == nil)
	}

	@Test func compactIsHisWordsOnly() {
		let compact = compactAnswerForModel(buildAnswer(explainQD(), AnswerRequest(text: "No idea about aether.")))
		let raw = JSONValue.object(compact).serialized()
		#expect(compact["text"] == "No idea about aether.")
		#expect(compact["kind"] == "explain")
		#expect(!raw.contains("luminiferous"), "the commitment must not ride the result")
		#expect(compact["committed"] == nil)
		#expect(compact["questionText"] == nil)
	}
}

@Suite struct QuestionsRoleFieldTests {
	@Test func theTeachSchemaRequiresTypeTheProbeSchemaHasNone() {
		#expect(quizInputSchema.check(planetQuiz), "fixture (type: check) is boundary-valid")
		#expect(!quizInputSchema.check(questionsWith(planetQuiz, ["type": .none])), "a teach quiz without a role is rejected")
		#expect(probeQuizInputSchema.property("nodeId") == nil)
		#expect(probeQuizInputSchema.property("type") == nil, "the probe quiz stays role-less")
	}

	@Test func normalizeQuizTypeExactLiteralsOnly() {
		#expect(normalizeQuizType("predict") == .predict)
		#expect(normalizeQuizType("check") == .check)
		#expect(normalizeQuizType(nil) == nil)
		#expect(normalizeQuizType("prediction") == nil)
		#expect(normalizeQuizType(42) == nil)
	}

	@Test func questionNeedsRevealChecksCollapsePredictionsNever() {
		#expect(questionNeedsReveal(tool: "quiz", rawInput: ["type": "check"], phase: "teach"))
		#expect(!questionNeedsReveal(tool: "quiz", rawInput: ["type": "predict"], phase: "teach"), "predictions arrive OPEN")
		#expect(questionNeedsReveal(tool: "quiz", rawInput: nil, phase: "teach"), "old records render check-style")
		#expect(!questionNeedsReveal(tool: "quiz", rawInput: ["type": "predict"], phase: "probe"))
		#expect(!questionNeedsReveal(tool: "quiz", rawInput: ["type": "check"], phase: "probe"))
		#expect(!questionNeedsReveal(tool: "ask_user_question", rawInput: [:], phase: "teach"))
		#expect(questionNeedsReveal(tool: "explain", rawInput: ["type": "check"], phase: "teach"))
		#expect(!questionNeedsReveal(tool: "explain", rawInput: ["type": "predict"], phase: "teach"))
		#expect(questionNeedsReveal(tool: "explain", rawInput: nil, phase: "teach"), "pre-type explain records render check-style")
		#expect(!questionNeedsReveal(tool: "explain", rawInput: ["type": "check"], phase: "probe"))
	}

	func quizQd() throws -> QuestionData {
		let options = try normalizeOptions(planetQuiz["options"])
		return QuestionData(id: "q1", kind: .quiz, question: "Which planet is closest to the Sun?", mode: .singleSelect, options: options,
			correctIndices: resolveCorrect(.single("Mercury"), options: options).indices, explanation: "Mercury is the innermost planet.",
			createdAt: "2026-01-01T00:00:00.000Z")
	}

	@Test func buildAnswerSnapshotsTheRoleAndBothThinkingChannels() throws {
		var predictQd = try quizQd()
		predictQd.questionType = .predict
		let a = buildAnswer(predictQd, AnswerRequest(values: ["Mercury"], thinking: "  guessed  ", readingThinking: "  reading note  "))
		#expect(a.questionType == .predict)
		#expect(a.thinking == "guessed", "thinking is trimmed")
		#expect(a.readingThinking == "reading note")
		let b = buildAnswer(try quizQd(), AnswerRequest(values: ["Mercury"]))
		#expect(b.thinking == nil, "empty channels stay absent")
		#expect(b.readingThinking == nil)
		#expect(b.questionType == nil, "a role-less QuestionData answers role-less")
	}

	@Test func compactUsesDistinctKeysAndFoldsLegacyNote() throws {
		var a = buildAnswer(try quizQd(), AnswerRequest(values: ["Mercury"], thinking: "h", readingThinking: "r"))
		let compact = compactAnswerForModel(a)
		#expect(compact["thinking"] == "h")
		#expect(compact["thinkingWhileReading"] == "r")
		a.thinking = nil
		a.note = "old note"
		let legacy = compactAnswerForModel(a)
		#expect(legacy["thinking"] == "old note", "records written before the rename still reach the model")
		#expect(legacy["note"] == nil, "the legacy key never re-crosses the wire")
	}

	@Test func theDisplayParseKeepsTheRole() {
		let cleaned = quizDisplayInputSchema.clean(planetQuiz)
		#expect(cleaned["type"] == "check", "role survives the display parse")
	}
}
