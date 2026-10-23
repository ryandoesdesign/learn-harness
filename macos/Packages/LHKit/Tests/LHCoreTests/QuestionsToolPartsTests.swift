import Foundation
import Testing
@testable import LHCore

// Port of tests/tool-parts.test.ts. The cases calling restoreMathEscapes
// directly live in MathDelimitersTests.swift.

private let teacherQuiz: JSONValue = [
	"question": "What does Tarski's convention-T define?",
	"options": [["label": "Truth for a language", "value": "truth"], ["label": "Provability", "value": "provability"]],
	"correctAnswer": "truth",
	"explanation": "Convention-T schematizes truth for the object language.",
	"type": "check",
	"nodeId": "convention-t",
]

private let proberQuiz: JSONValue = [
	"question": "Which planet is closest to the sun?",
	"options": [["label": "Venus"], ["label": "Mercury"]],
	"correctAnswer": "Mercury",
	"explanation": "Mercury is the innermost planet.",
]

private let validAssessment: JSONValue = [
	"assessment": [
		"strands": [
			["strand": "modal logic basics", "assessment": "Floor: solid intuition; ceiling: notation."],
			["strand": "indexical 'actual'", "assessment": "Genuine floor — prior exposure likely."],
		],
		"summary": "Bracketed: teach the symbols on the intuition he has.",
	],
]

/// A two-option quiz around one field under test.
private func quiz(question: String, options: JSONValue = [["label": "x"], ["label": "y"]], correctAnswer: String = "x", explanation: String = "") -> JSONValue {
	["question": .string(question), "options": options, "correctAnswer": .string(correctAnswer), "explanation": .string(explanation)]
}

@Suite struct QuestionsParseQuizTests {
	@Test func parsesATeacherQuizAndStripsNodeId() throws {
		let parsed = try #require(parseQuizInput(teacherQuiz))
		#expect(parsed.question == teacherQuiz["question"]?.stringValue)
		#expect(parsed.json["nodeId"] == nil, "unknown keys are stripped, not trusted")
		#expect(parsed.type == "check", "the role field survives the display parse")
	}

	@Test func parsesAProberQuiz() { #expect(parseQuizInput(proberQuiz) != nil) }

	@Test func boundaryParityTeach() {
		#expect(quizInputSchema.check(teacherQuiz), "fixture must be boundary-valid")
		#expect(parseQuizInput(teacherQuiz) != nil)
	}

	@Test func boundaryParityProbe() {
		#expect(probeQuizInputSchema.check(proberQuiz))
		#expect(parseQuizInput(proberQuiz) != nil)
	}

	@Test func theStringOptionsShapeHealsOnRead() throws {
		let stringified = questionsWith(proberQuiz, ["options": .string(proberQuiz["options"]!.serialized())])
		let parsed = try #require(parseQuizInput(stringified), "the healed-at-boundary record must parse on read")
		#expect(parsed.options == [QuizOptionInput(label: "Venus"), QuizOptionInput(label: "Mercury")])
	}

	@Test func aNumericCorrectAnswerParsesUnderConvert() throws {
		let numeric: JSONValue = [
			"question": "What is 5 + 3 × 4?",
			"options": [["label": "17", "value": "17"], ["label": "27", "value": "27"], ["label": "9", "value": "9"]],
			"explanation": "Multiplication first.",
			"correctAnswer": 17,
		]
		let parsed = try #require(parseQuizInput(numeric))
		#expect(parsed.correctAnswer == .single("17"), "converted to the string the boundary saw")
		let parsedArray = try #require(parseQuizInput(questionsWith(numeric, ["multiSelect": true, "correctAnswer": [17, "27"]])))
		#expect(parsedArray.correctAnswer == .multiple(["17", "27"]))
		#expect(parseQuizInput(questionsWith(proberQuiz, ["correctAnswer": ["bad": true]])) == nil)
		// TS: Convert widens `undefined` to "" and the refinement rejects; JSON
		// has no undefined — the absent key fails Check. Same verdict.
		#expect(parseQuizInput(questionsWith(proberQuiz, ["correctAnswer": .none])) == nil, "the refinement owns the reject")
	}

	@Test func garbageNeverParses() {
		#expect(parseQuizInput("a string") == nil)
		#expect(parseQuizInput(["options": []]) == nil)
		#expect(parseQuizInput(questionsWith(proberQuiz, ["correctAnswer": .none])) == nil)
	}
}

@Suite struct QuestionsParseAskTests {
	@Test func parsesFreeTextAndOptionModes() {
		#expect(parseAskInput(["question": "What do you want to learn?"]) != nil)
		#expect(parseAskInput(["question": "Which topics?", "options": [["label": "Physics"], ["label": "Logic"]], "multiSelect": true]) != nil)
	}

	@Test func stringifiedOptionsDoNotParse() {
		#expect(parseAskInput(["question": "q", "options": "[]"]) == nil)
	}
}

@Suite struct QuestionsParseProbeDoneTests {
	@Test func parsesTheValidAssessment() throws {
		let parsed = try #require(parseProbeDoneInput(validAssessment))
		#expect(parsed.assessment.strands.count == 2)
		#expect(parsed.assessment.summary == "Bracketed: teach the symbols on the intuition he has.")
	}

	@Test func boundaryParity() {
		#expect(probeDoneInputSchema.check(validAssessment))
		#expect(parseProbeDoneInput(validAssessment) != nil)
	}

	@Test func aStringifiedAssessmentDoesNotParse() {
		let text = validAssessment["assessment"]!.serialized()
		#expect(parseProbeDoneInput(["assessment": .string(text)]) == nil)
		#expect(parseProbeDoneInput(.string(text.jsSlice(0, 30))) == nil)
	}

	@Test func aMidStreamPartialDoesNotParse() {
		#expect(parseProbeDoneInput(["assessment": ["summary": "…"]]) == nil)
	}
}

@Suite struct QuestionsLatexRestorationTests {
	@Test func parseQuizInputRestoresEscapeDebrisInsideMathSpans() throws {
		let parsed = try #require(parseQuizInput([
			"question": #"What does \(\forall x\, \varphi(x)\) mean?"#,
			"options": [
				["label": "\\(\u{0B}arphi\\) is true when every element satisfies it", "value": "tarski"],
				["label": "\\(\u{0C}orall\\) and \\(\\exists\\) are just shorthand", "value": "shorthand"],
			],
			"correctAnswer": "tarski",
			"explanation": "\\(\u{0C}orall\\) quantifies over the domain.",
		]))
		#expect(parsed.question == #"What does \(\forall x\, \varphi(x)\) mean?"#)
		#expect(parsed.options[0].label == #"\(\varphi\) is true when every element satisfies it"#)
		#expect(parsed.options[1].label == #"\(\forall\) and \(\exists\) are just shorthand"#)
		#expect(parsed.explanation == #"\(\forall\) quantifies over the domain."#)
	}

	@Test func parseAskInputRestoresDebrisInOptionLabels() throws {
		let parsed = try #require(parseAskInput(["question": "Goal?", "options": [["label": "\\(\u{0C}orall\\) rigor"], ["label": "Intuition first"]]]))
		#expect(parsed.options?[0].label == #"\(\forall\) rigor"#)
	}

	@Test func restoresTabDebrisInsideSpansOnly() throws {
		let parsed = try #require(parseQuizInput(quiz(question: "Is \\(p\to q\\) valid?", options: [["label": "yes"], ["label": "no"]], correctAnswer: "no")))
		#expect(parsed.question == #"Is \(p\to q\) valid?"#)
	}

	@Test func controlCharsOutsideMathSpansAreLeftAlone() throws {
		let parsed = try #require(parseQuizInput(quiz(question: "Pick:\ta\u{0B}b")))
		#expect(parsed.question == "Pick:\ta\u{0B}b")
	}

	@Test func unbalancedDelimitersPassThroughUntouched() throws {
		let parsed = try #require(parseQuizInput(quiz(question: #"\(\x0corall"#)))
		#expect(parsed.question == #"\(\x0corall"#)
	}
}

@Suite struct QuestionsDisplayMathNewlineTests {
	let multiline = "Compare:\n\\[\n\\forall x, & f(x) = x^2 \\\\\n& g(x) = x^3\n\\]"

	@Test func realNewlinesInsideDisplayMathAreKept() throws {
		let parsed = try #require(parseQuizInput(quiz(question: multiline, options: [["label": "f grows slower"], ["label": "g grows slower"]], correctAnswer: "f grows slower")))
		#expect(parsed.question == multiline)
	}

	@Test func nonNewlineDebrisInsideDisplayMathStillRestores() throws {
		let parsed = try #require(parseQuizInput(quiz(question: "Evaluate \\[\\left( a \right)\\] carefully.", options: [["label": "a"], ["label": "not a"]], correctAnswer: "a")))
		#expect(parsed.question == #"Evaluate \[\left( a \right)\] carefully."#)
	}

	@Test func sloppyNeqInDisplayMathStaysBroken() throws {
		let debris = "Is \\[p \neq q\\] valid?"
		let parsed = try #require(parseQuizInput(quiz(question: debris, options: [["label": "yes"], ["label": "no"]], correctAnswer: "no")))
		#expect(parsed.question == debris)
	}

	@Test func inlineSpansStillRestoreNewlineDebris() throws {
		let parsed = try #require(parseQuizInput(quiz(question: "Is \\(p \neq q\\) valid?", options: [["label": "yes"], ["label": "no"]], correctAnswer: "no")))
		#expect(parsed.question == #"Is \(p \neq q\) valid?"#)
	}
}

@Suite struct QuestionsDollarDelimiterTests {
	@Test func restoresQuestionOptionAndExplanationDebrisInDollarMath() throws {
		let parsed = try #require(parseQuizInput([
			"question": "What does $\u{0C}orall x$ mean?",
			"options": [["label": "$\u{0B}arphi$ holds", "value": "yes"], ["label": "No", "value": "no"]],
			"correctAnswer": "yes",
			"explanation": "Here $p\to q$ is an implication.",
		]))
		#expect(parsed.question == #"What does $\forall x$ mean?"#)
		#expect(parsed.options[0].label == #"$\varphi$ holds"#)
		#expect(parsed.explanation == #"Here $p\to q$ is an implication."#)
	}

	@Test func sharesDollarRecoveryWithAskAndFreeRecall() throws {
		let ask = try #require(parseAskInput(["question": "Goal?", "options": [["label": "$\u{0C}orall$ rigor"], ["label": "Intuition"]]]))
		#expect(ask.options?[0].label == #"$\forall$ rigor"#)
		let explain = try #require(parseExplainInput(["question": "Explain $p\to q$", "correctAnswer": "$p\neq q$ is different."]))
		#expect(explain.question == #"Explain $p\to q$"#)
		#expect(explain.correctAnswer == #"$p\neq q$ is different."#)
	}
}

@Suite struct QuestionsParseExplainTests {
	let good: JSONValue = [
		"question": "Explain why Mercury is hard to observe.",
		"correctAnswer": "Its small angular separation from the Sun — it never strays far from the Sun in our sky.",
		"nodeId": "planet-order",
		"details": "Think about where it appears at dusk.",
	]

	@Test func parsesAValidCallAndStripsNodeId() throws {
		let parsed = try #require(parseExplainInput(good))
		#expect(parsed.question == "Explain why Mercury is hard to observe.")
		#expect(parsed.correctAnswer == "Its small angular separation from the Sun — it never strays far from the Sun in our sky.")
		#expect(parsed.details == "Think about where it appears at dusk.")
		#expect(parsed.json["nodeId"] == nil, "the teacher-only key is cleaned away")
	}

	@Test func anEmptyCommitmentNeverArmsTheDock() {
		#expect(parseExplainInput(questionsWith(good, ["correctAnswer": "  "])) == nil)
	}

	@Test func restoresLatexEscapeDebrisInsideMathSpans() throws {
		// The TS literal "Because \(orall x\) holds." — `\(` is "(" and `\f`
		// a form feed — and its expected value are the same string.
		let dirty = "Because (\u{0C}orall x) holds."
		let parsed = try #require(parseExplainInput(questionsWith(good, ["correctAnswer": .string(dirty)])))
		#expect(parsed.correctAnswer == "Because (\u{0C}orall x) holds.")
	}

	@Test func wrongShapeInputNeverArmsTheDock() {
		#expect(parseExplainInput("just a string") == nil)
		#expect(parseExplainInput(["explanation": "e", "correctAnswer": "a"]) == nil, "missing question")
		#expect(parseExplainInput(["question": "q", "explanation": "e", "correctAnswer": ["nested": true]]) == nil)
		#expect(parseExplainInput(["question": "q", "explanation": "e", "correctAnswer": 42])?.correctAnswer == "42")
	}
}

@Suite struct QuestionsOverescapedHealTests {
	let clean = #"Let $f : \mathbb{R}^n \to \mathbb{R}$ be differentiable at $x$, with $\nabla f(x) \neq 0$. Among all unit directions $\|u\|_2 = 1$, which makes $D_u f(x)$ most negative?"#
	func double(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\") }
	let base: JSONValue = [
		"options": [["label": #"$u^\star = -\nabla f(x)$"#, "value": "neg"], ["label": #"$u^\star = \nabla f(x)$"#, "value": "pos"]],
		"correctAnswer": "neg",
		"explanation": "By Cauchy\u{2013}Schwarz: $$u^\\star = -\\frac{\\nabla f(x)}{\\|\\nabla f(x)\\|_2}$$",
	]

	@Test func healsADoubledQuestionField() throws {
		let parsed = try #require(parseQuizInput(questionsWith(base, ["question": .string(double(clean))])))
		#expect(parsed.question == clean)
		#expect(parsed.options[0].label == base["options"]?[0]?["label"]?.stringValue)
		#expect(parsed.explanation == base["explanation"]?.stringValue)
	}

	@Test func healsAQuadrupledField() throws {
		let parsed = try #require(parseQuizInput(questionsWith(base, ["question": .string(double(double(clean)))])))
		#expect(parsed.question == clean)
	}

	@Test func doubledOptionLabelsAndExplanationsHeal() throws {
		let parsed = try #require(parseQuizInput([
			"question": #"Let $A \in \mathbb{R}^{m \times k}$ and $C = AB$."#,
			"options": [["label": .string(double("$mkn$")), "value": "mkn"], ["label": .string(double("$2mkn$")), "value": "2"]],
			"correctAnswer": "mkn",
			"explanation": .string(double(#"$$c_{ij} = \sum_{\ell=1}^{k} a_{i\ell}\, b_{\ell j}$$"#)),
		]))
		#expect(parsed.options[0].label == "$mkn$")
		#expect(parsed.options[1].label == "$2mkn$")
		#expect(parsed.explanation == #"$$c_{ij} = \sum_{\ell=1}^{k} a_{i\ell}\, b_{\ell j}$$"#)
	}

	@Test func parseAskInputHealsDoubledDescriptions() throws {
		let parsed = try #require(parseAskInput([
			"question": "Depth?",
			"options": [["label": "Rigorous", "description": .string(double(#"why $-\nabla f$ is steepest descent"#))], ["label": "Intuition"]],
		]))
		#expect(parsed.options?[0].description == #"why $-\nabla f$ is steepest descent"#)
	}

	@Test func cleanRecordsPassThroughByteIdentical() throws {
		let parsed = try #require(parseQuizInput(questionsWith(base, ["question": .string(clean)])))
		#expect(parsed.question == clean)
		#expect(parsed.explanation == base["explanation"]?.stringValue)
	}

	@Test func legitimateRowBreaksInsideMatricesSurvive() throws {
		let matrix = #"Which matrix matches? $$\begin{pmatrix} 1 \ 2 \\ 3 \ 4\end{pmatrix}$$"#
		let parsed = try #require(parseQuizInput(questionsWith(base, ["question": .string(matrix)])))
		#expect(parsed.question == matrix)
	}
}
