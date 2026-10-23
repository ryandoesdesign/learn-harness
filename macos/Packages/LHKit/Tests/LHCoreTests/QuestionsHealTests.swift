import Foundation
import Testing
@testable import LHCore

// Port of tests/tool-heal.test.ts (the whitehead incident pins). pi-ai's
// validateToolArguments is Convert + Check (see ToolParts.boundaryParse);
// the JSONSchema validator stands in for it here.

private func quoted(_ v: String) -> String { "\"\(v)\"" }

private func whiteheadQuiz(type: JSONValue, correctAnswer: JSONValue) -> JSONValue {
	[
		"question": "What was Parmenides' claim?",
		"options": [
			["label": "Being is changeless and complete", "value": "parmenides"],
			["label": "Becoming is fundamental", "value": "heraclitus"],
			["label": "Split world", "value": "split"],
			["label": "Both unreal", "value": "both-illusion"],
		],
		"explanation": "What truly *is* cannot come to be or pass away — the flux is appearance.",
		"correctAnswer": correctAnswer,
		"type": type,
		"nodeId": "experience-first",
	]
}

/// pi-ai's validateToolArguments: Convert, then Check (nil = it throws).
private func piValidate(_ schema: JSONSchema, _ args: JSONValue) -> JSONValue? {
	let converted = schema.convert(args)
	return schema.check(converted) ? converted : .none
}

@Suite struct QuestionsHealDeathLoopTests {
	@Test func healsTheQuoteEncodedLiteral() {
		let healed = healEncodedArguments(["type": .string(quoted("predict"))], schema: quizInputObject)
		#expect(healed["type"] == "predict")
	}

	@Test func endToEndTheHealedArgsPassValidationWhereTheRawFailed() {
		let raw = whiteheadQuiz(type: .string(quoted("predict")), correctAnswer: ["parmenides"])
		let rawResult = piValidate(quizInputObject, raw)
		#expect(rawResult == nil, "\(rawResult?.serialized() ?? "none")")
		let validated = piValidate(quizInputObject, healEncodedArguments(raw, schema: quizInputObject))
		#expect(validated?["type"] == "predict")
	}

	@Test func theStringOptionsShapeHeals() {
		// The core of the bare-quiz wiring pin: the registry's prepareArguments
		// IS healEncodedArguments against the declared schema.
		let input = whiteheadQuiz(type: "predict", correctAnswer: ["parmenides"])
		let stringified = questionsWith(input, ["options": .string(input["options"]!.serialized())])
		let healed = healEncodedArguments(stringified, schema: quizInputObject)
		#expect(healed["options"]?.arrayValue != nil, "the JSON string heals to the array")
		#expect(healed["options"]?[0]?["value"] == "parmenides")
	}

	@Test func wellFormedArgsPassThroughUnchanged() {
		let input = whiteheadQuiz(type: "predict", correctAnswer: ["parmenides"])
		#expect(healEncodedArguments(input, schema: quizInputObject) == input)
	}
}

@Suite struct QuestionsHealColonShapeTests {
	@Test func stripModelValueDebrisHealsTheObservedShapes() {
		#expect(stripModelValueDebris(":parmenides") == "parmenides")
		#expect(stripModelValueDebris(quoted("predict")) == "predict")
		#expect(stripModelValueDebris(": \"primary-external\" ") == "primary-external")
		#expect(stripModelValueDebris("`value`") == "value")
		#expect(stripModelValueDebris("a:b") == "a:b", "interior colon is content")
		#expect(stripModelValueDebris(#"["x"]"#) == #"["x"]"#, "interior quotes are content")
	}

	@Test func coerceCorrectAnswerCleansNonMatchingEntries() {
		#expect(coerceCorrectAnswer(.multiple([":parmenides"]), optionValues: ["parmenides"]) == ["parmenides"])
		#expect(coerceCorrectAnswer(.single(quoted("primary-external")), optionValues: ["primary-external"]) == ["primary-external"])
	}

	@Test func theIncidentsExactCallPassesTheSemanticBoundary() {
		#expect(questionsQuizProblems(whiteheadQuiz(type: "predict", correctAnswer: [":parmenides"])) == [])
	}

	@Test func normalizeQuizTypeHealsAPersistedWobbledRecord() {
		#expect(normalizeQuizType(.string(quoted("predict"))) == .predict)
		#expect(normalizeQuizType("\"check\"") == .check)
		#expect(normalizeQuizType(nil) == nil)
		#expect(normalizeQuizType("bogus") == nil)
	}
}

@Suite struct QuestionsHealCalculusTests {
	@Test func anExactLabelWithItsSentenceFinalPeriodValidates() {
		// The boundary half of the probe-tool pin (prepareArguments → validate →
		// the execute refinement); posing is the agent's (M3).
		let input: JSONValue = [
			"question": "Which claim?",
			"options": [["label": "The claim holds."], ["label": "The claim need not hold."]],
			"explanation": "The premise does not imply the claim.",
			"correctAnswer": "The claim need not hold.",
		]
		let validated = piValidate(probeQuizInputSchema, healEncodedArguments(input, schema: probeQuizInputSchema))
		#expect(validated?["correctAnswer"] == input["correctAnswer"])
		#expect(questionsQuizProblems(validated ?? .null) == [], "an already-exact answer must not trigger a retry")
	}
}

@Suite struct QuestionsHealDisplayMirrorTests {
	@Test func parseQuizInputRendersTheIncidentsPersistedRawRecord() throws {
		let raw = whiteheadQuiz(type: .string(quoted("predict")), correctAnswer: [":parmenides"])
		let parsed = try #require(parseQuizInput(raw), "the wobbled record must parse — else the quiz is invisible")
		#expect(normalizeQuizType(parsed.type.map(JSONValue.string)) == .predict)
		#expect(coerceCorrectAnswer(parsed.correctAnswer, optionValues: parsed.options.map { $0.value ?? $0.label }) == ["parmenides"])
	}
}
