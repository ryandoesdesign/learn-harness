import Foundation
import Testing
@testable import LHCore

/// The synthetic heal/convert schema of scripts/core-golden/questions.ts.
let questionsHealSchema = JSONSchema.object([
	"mode": .union([.literal("recall"), .literal("apply")]),
	"maybe": .union([.literal("a"), .null()]),
	"flag": .boolean(),
	"n": .number(),
	"i": .integer(),
	"list": .array(.string()),
	"bare": .literal(3),
	"nothing": .null(),
], additionalProperties: false)

let questionsGoldenSchemas: [String: JSONSchema] = [
	"quizInputBase": quizInputBase,
	"quizInputObject": quizInputObject,
	"probeQuizInputSchema": probeQuizInputSchema,
	"quizDisplayInputSchema": quizDisplayInputSchema,
	"explainInputBase": explainInputBase,
	"explainInputObject": explainInputObject,
	"explainDisplayInputSchema": explainDisplayInputSchema,
	"askInputSchema": askInputSchema,
	"probeDoneInputSchema": probeDoneInputSchema,
	"healSchema": questionsHealSchema,
]

/// The tool → display parse dispatch, as JSON (null = no parse).
func questionsParsedJSON(tool: String, _ input: JSONValue) throws -> JSONValue {
	switch tool {
	case "quiz", "probe": return parseQuizInput(input)?.json ?? .null
	case "ask_user_question": return parseAskInput(input)?.json ?? .null
	case "explain", "recall": return parseExplainInput(input)?.json ?? .null
	case "probe_done": return try parseProbeDoneInput(input).map(JSONCodec.encode) ?? .null
	default: Issue.record("unknown tool \(tool)"); return .null
	}
}

/// The dock's QuestionData construction (components/question-dock.tsx) over
/// a PARSED input — mirrors questionDataFor in the golden script.
func questionsDockData(tool: String, toolCallId: String, parsed: JSONValue) throws -> QuestionData {
	let kind = toolQuestionKind(tool)
	let multi = parsed["multiSelect"]?.boolValue == true
	let rawOptions = parsed["options"]?.arrayValue ?? []
	let mode: QuestionMode = kind == .quiz ? (multi ? .multiSelect : .singleSelect)
		: kind == .ask && !rawOptions.isEmpty ? (multi ? .multiSelect : .singleSelect) : .text
	let options = try normalizeOptions(kind == .explain ? .array([]) : .array(rawOptions))
	let ordered = kind == .quiz && !options.isEmpty ? shuffleOptions(options, rand: seededRandom(toolCallId)) : options
	var qd = QuestionData(id: toolCallId, kind: kind, questionType: kind == .quiz ? normalizeQuizType(parsed["type"]) : nil,
		question: parsed["question"]?.stringValue ?? "", context: parsed["details"]?.stringValue, mode: mode, options: ordered,
		createdAt: "2026-01-01T00:00:00.000Z")
	if kind == .quiz {
		qd.correctIndices = resolveCorrect(parsed["correctAnswer"].flatMap(CorrectAnswer.init(json:)), options: ordered).indices
		qd.explanation = parsed["explanation"]?.stringValue
	}
	if kind == .explain { qd.committedAnswer = parsed["correctAnswer"]?.stringValue }
	return qd
}

/// The AnswerRequest a recorded answer implies (requestFrom in the script).
func questionsAnswerRequest(from d: JSONValue) -> AnswerRequest {
	AnswerRequest(
		dontKnow: d["dontKnow"]?.boolValue,
		values: (d["answers"]?.arrayValue ?? []).compactMap { $0["value"]?.stringValue },
		other: d["other"]?.stringValue,
		text: d["text"]?.stringValue,
		thinking: d["thinking"]?.stringValue ?? d["note"]?.stringValue,
		readingThinking: d["readingThinking"]?.stringValue,
		confidence: d["confidence"]?.doubleValue)
}

@Suite struct QuestionsGoldenTests {
	@Test func schemasEmitTypeboxJSON() throws {
		let golden = try Golden.load("questions.schemas")
		for (name, schema) in questionsGoldenSchemas {
			let expected = try #require(golden[name], "\(name)")
			expectJSONEqual(schema.json, expected)
			// Property ORDER is authoring guidance — compare it exactly too.
			#expect(schema.json.serialized() == expected.serialized(), "\(name) key order")
		}
	}

	@Test func goldenChatCallsParseLikeTS() throws {
		let golden = try Golden.load("questions.parse")
		var inputs: [String: JSONValue] = [:]
		for id in [Fixtures.teachChatId, Fixtures.practiceChatId] {
			for m in try Fixtures.chat(id).messages {
				for u in m.assistant?.toolUses ?? [] { inputs[u.id] = u.input }
			}
		}
		let rows = golden["chat"]?.arrayValue ?? []
		#expect(rows.count == 12)
		for row in rows {
			let id = try #require(row["toolCallId"]?.stringValue)
			let tool = try #require(row["tool"]?.stringValue)
			let input = try #require(inputs[id], "\(id)")
			expectJSONEqual(try questionsParsedJSON(tool: tool, input), row["parsed"]!)
		}
	}

	@Test func syntheticInputsParseLikeTS() throws {
		let golden = try Golden.load("questions.parse")
		let rows = golden["synthetic"]?.arrayValue ?? []
		#expect(rows.count == 36)
		for row in rows {
			let tool = try #require(row["tool"]?.stringValue)
			let input = row["input"] ?? .null
			let actual = try questionsParsedJSON(tool: tool, input)
			let d = jsonDiff(actual, row["parsed"]!)
			#expect(d == nil, "\(tool) \(input.serialized().prefix(160)): \(d ?? "")")
		}
	}

	@Test func answersRebuildLikeTS() throws {
		let golden = try Golden.load("questions.answers")
		let now = try #require(golden["answeredAtMs"]?.intValue)
		var calls: [String: JSONValue] = [:]
		var results: [String: ToolResultBody] = [:]
		for id in [Fixtures.teachChatId, Fixtures.practiceChatId] {
			for m in try Fixtures.chat(id).messages {
				for u in m.assistant?.toolUses ?? [] { calls[u.id] = u.input }
				if let r = m.toolResult { results[r.toolUseId] = r }
			}
		}
		let rows = golden["rows"]?.arrayValue ?? []
		#expect(rows.count == 10)
		for row in rows {
			let id = try #require(row["toolCallId"]?.stringValue)
			let tool = try #require(row["tool"]?.stringValue)
			let parsed = try questionsParsedJSON(tool: tool, try #require(calls[id]))
			let details = try #require(results[id]?.details)
			let qd = try questionsDockData(tool: tool, toolCallId: id, parsed: parsed)
			let answer = buildAnswer(qd, questionsAnswerRequest(from: details), tool: tool, now: now)
			expectJSONEqual(toClientQuestion(qd).json, row["client"]!)
			expectJSONEqual(answer.json, row["answer"]!)
			expectJSONEqual(.object(compactAnswerForModel(answer)), row["compact"]!)
			expectJSONEqual(.object(compactAnswerForModel(details)), row["compactRecorded"]!)
			// The model-visible bytes are exact.
			let result = newAnswerResult(toolCallId: id, toolName: tool, answer: details, id: "m", now: 0)
			#expect(result.toolResult?.firstText == row["resultText"]?.stringValue)
			#expect(result.toolResult?.details == details)
		}
		expectJSONEqual(dismissedAnswer(.ask, questionText: "Skip me?", now: now).json, golden["dismissed"]!)
	}

	@Test func healMatchesTS() throws {
		let golden = try Golden.load("questions.heal")
		for row in golden["rows"]?.arrayValue ?? [] {
			let schema = try #require(questionsGoldenSchemas[row["schema"]?.stringValue ?? ""])
			expectJSONEqual(healEncodedArguments(row["args"]!, schema: schema), row["healed"]!)
		}
	}

	@Test func checkConvertCleanMatchTypebox() throws {
		let golden = try Golden.load("questions.values")
		let rows = golden["rows"]?.arrayValue ?? []
		#expect(rows.count == 260)
		for row in rows {
			let name = row["schema"]?.stringValue ?? ""
			let schema = try #require(questionsGoldenSchemas[name])
			let value = row["value"]!
			let label = "\(name) ← \(value.serialized().prefix(100))"
			#expect(schema.check(value) == row["check"]?.boolValue, "check \(label)")
			let converted = schema.convert(value)
			let dc = jsonDiff(converted, row["converted"]!)
			#expect(dc == nil, "convert \(label): \(dc ?? "")")
			let dk = jsonDiff(schema.clean(converted), row["clean"]!)
			#expect(dk == nil, "clean \(label): \(dk ?? "")")
		}
	}

	@Test func gradingMatchesTS() throws {
		let g = try Golden.load("questions.grading")
		func answer(_ v: JSONValue?) throws -> CorrectAnswer { try #require(v.flatMap(CorrectAnswer.init(json:))) }
		func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
		func optionInputs(_ v: JSONValue?) -> [QuizOptionInput] {
			(v?.arrayValue ?? []).map { QuizOptionInput(label: $0["label"]?.stringValue ?? "", value: $0["value"]?.stringValue) }
		}
		for row in g["debris"]?.arrayValue ?? [] {
			#expect(stripModelValueDebris(row["value"]?.stringValue ?? "") == row["stripped"]?.stringValue)
		}
		for row in g["coerce"]?.arrayValue ?? [] {
			#expect(coerceCorrectAnswer(try answer(row["answer"]), optionValues: strings(row["values"])) == strings(row["coerced"]), "\(row["answer"]!.serialized())")
		}
		for row in g["problems"]?.arrayValue ?? [] {
			let options = optionInputs(row["options"])
			let problems = quizInputProblems(options: options, correctAnswer: try answer(row["correctAnswer"]), multiSelect: row["multiSelect"]?.boolValue)
			#expect(problems == strings(row["problems"]))
			#expect(askOptionProblems(options) == strings(row["askProblems"]))
		}
		for row in g["explainProblems"]?.arrayValue ?? [] {
			#expect(explainInputProblems(correctAnswer: row["correctAnswer"]?.stringValue ?? "") == strings(row["problems"]))
		}
		let resolveOptions = try normalizeOptions(["a", "b", "x", "parmenides", "value."].map { QuizOptionInput(label: $0) })
		for row in g["resolve"]?.arrayValue ?? [] {
			let r = resolveCorrect(try answer(row["answer"]), options: resolveOptions)
			#expect(r.indices == (row["indices"]?.arrayValue ?? []).compactMap(\.intValue))
			#expect(r.error == row["error"]?.stringValue)
		}
		for row in g["quizType"]?.arrayValue ?? [] {
			#expect(normalizeQuizType(row["raw"])?.rawValue == row["type"]?.stringValue)
		}
		for row in g["reveal"]?.arrayValue ?? [] {
			let input = row["input"].flatMap { $0.isNull ? nil : $0 }
			#expect(questionNeedsReveal(tool: row["tool"]?.stringValue ?? "", rawInput: input, phase: row["phase"]?.stringValue ?? "") == row["reveal"]?.boolValue)
		}
		for row in g["normalize"]?.arrayValue ?? [] {
			let options = row["options"].flatMap { $0.isNull ? nil : $0 }
			do {
				let normalized = try normalizeOptions(options)
				expectJSONEqual(.array(normalized.map(\.json)), row["normalized"] ?? .null)
			} catch {
				#expect("\(error)" == row["error"]?.stringValue)
			}
		}
	}

	@Test func seededShuffleMatchesTS() throws {
		let golden = try Golden.load("questions.random")
		let six = ["a", "b", "c", "d", "e", "f"].map { QuizOption(label: $0.uppercased(), value: $0) }
		for row in golden["rows"]?.arrayValue ?? [] {
			let seed = row["seed"]?.stringValue ?? ""
			let r = seededRandom(seed)
			let sequence = (0..<12).map { _ in r() }
			#expect(sequence == (row["sequence"]?.arrayValue ?? []).compactMap(\.doubleValue), "\(seed)")
			#expect(shuffleOptions(six, rand: seededRandom(seed)).map(\.value) == (row["shuffled"]?.arrayValue ?? []).compactMap(\.stringValue))
		}
	}
}
