import Foundation
import Testing
@testable import LHCore

// The projectView assertions of tests/chat-flow.test.ts,
// practice-record.test.ts, jobs.test.ts, graph-context.test.ts and
// session-core.test.ts. Route/agent-driven cases are ported as the record
// those routes persist (built here by hand); only the view assertions are kept.

private func user(_ id: String, _ text: String) -> Message { newUserMessage(text, id: id, now: 1) }

private func assistant(_ id: String, _ content: [Block], stop: String = "end_turn") -> Message {
	Message(id: id, timestamp: 1, body: .assistant(AssistantBody(content: content, model: "openrouter:test", stopReason: stop)))
}

private func result(_ callId: String, _ tool: String, details: JSONValue?, text: String = "ok", isError: Bool = false) -> Message {
	Message(id: "r_\(callId)", timestamp: 2, body: .toolResult(ToolResultBody(
		toolUseId: callId, toolName: tool, content: [.text(text)], isError: isError, details: details)))
}

private func parts(_ view: [ViewMessage]) -> [ViewPart] { view.flatMap(\.parts) }

private let QUIZ_INPUT: JSONValue = [
	"question": "Which planet is closest to the sun?",
	"options": [["label": "Venus"], ["label": "Mercury"], ["label": "Mars"]],
	"correctAnswer": "Mercury",
	"explanation": "Mercury is the innermost planet.",
	"type": "check",
	"nodeId": "planet-order",
]

/// The graded quiz answer record (QuestionAnswerData) as the answer route persists it.
private let QUIZ_ANSWER: JSONValue = [
	"kind": "quiz", "questionText": "Which planet is closest to the sun?",
	"answers": [["index": 1, "label": "Mercury"]], "correct": true, "answeredAt": "2026-10-01T00:00:00.000Z",
]

// MARK: - chat-flow.test.ts

@Suite struct ChatFlowViewTests {
	/// "quiz tool call persists as a pending part; the answer continues the lesson"
	@Test func quizPendingThenAnsweredInOneGroup() throws {
		let turn1 = [
			user("u1", "teach me the solar system"),
			assistant("a1", [.thinking("Probe the basics first.", signature: nil), .toolUse(id: "call-1", name: "quiz", input: QUIZ_INPUT)], stop: "tool_use"),
		]
		let view1 = projectView(turn1)
		#expect(view1[1].parts.contains { $0.kind == .reasoning }, "reasoning part projected")
		let quiz = try #require(view1[1].parts.first { $0.type == "tool-quiz" }, "quiz tool part projected")
		#expect(quiz.state == .inputAvailable, "unanswered quiz = pending state (resume record)")
		#expect(quiz.input == QUIZ_INPUT)

		let turn2 = turn1 + [result("call-1", "quiz", details: QUIZ_ANSWER), assistant("a2", [.text("Right — Mercury it is.")])]
		let view2 = projectView(turn2)
		#expect(view2.count == 2, "the reaction continues the same assistant message (one group)")
		let text = try #require(view2[1].parts.first { $0.kind == .text })
		#expect(text.text?.contains("Mercury it is") == true)
		let answered = try #require(view2[1].parts.first { $0.type == "tool-quiz" })
		#expect(answered.state == .outputAvailable)
		#expect(answered.output?["kind"]?.stringValue == "quiz")
		#expect(answered.output?["correct"]?.boolValue == true)
	}

	/// "the view canon HOISTS reasoning above the message text"
	@Test func reasoningIsHoistedAboveTheMessageText() {
		let quizInput: JSONValue = ["question": "q", "options": [["label": "a"]], "correctAnswer": "a", "explanation": ""]
		let trailing = assistant("a_trail", [
			.text("The answer text."), .thinking("Checked the map afterwards.", signature: nil), .toolUse(id: "call-tr", name: "quiz", input: quizInput),
		], stop: "tool_use")
		let view = projectView([user("u0", "hi"), trailing])
		#expect(view.count == 2)
		let order = view[1].parts.filter { $0.kind != .stepStart }.map(\.type)
		#expect(order.first == "reasoning", "reasoning renders FIRST regardless of content order")
		#expect(order.firstIndex(of: "text")! > order.firstIndex(of: "reasoning")!, "text follows the reasoning")
		#expect(order.last == "tool-quiz", "the tool call stays last")

		let leading = assistant("a_lead", [.thinking("First.", signature: nil), .text("The answer text.")])
		let view2 = projectView([user("u1", "hi"), leading])
		#expect(view2[1].parts.filter { $0.kind != .stepStart }.map(\.type) == ["reasoning", "text"], "think-first messages project identically")
	}

	/// "an arrived-but-empty STREAMING message projects the thinking row; a settled empty one stays hidden"
	@Test func emptyStreamingMessageProjectsTheThinkingRow() {
		let empty = assistant("a_empty", [])
		let live = LiveTurnState(inFlight: true, streamingIds: ["a_empty"])
		let view = projectView([user("u0", "hi"), empty], live: live)
		let ps = view[1].parts.filter { $0.kind != .stepStart }
		#expect(ps.map(\.type) == ["reasoning"], "empty streaming message = the thinking row")
		#expect(ps.first?.text == "", "empty until the first token lands")
		#expect(projectView([user("u0", "hi"), empty]).count == 1, "a settled empty message renders nothing")
	}

	/// "an invalid quiz call is surfaced as a tool error and the model retries in the same turn"
	@Test func invalidQuizPersistsAsAnErrorPart() throws {
		let bad: JSONValue = [
			"question": "What is Nietzsche's genealogical claim about religion?", "type": "check", "nodeId": "genealogy",
			"options": [["label": "A cultural diagnosis"], ["label": "Atheism as a conclusion"]],
			"correctAnswer": "cultural-diagnosis", "explanation": "Genealogy diagnoses, it does not convert.",
		]
		let record = [
			user("u1", "quiz me"),
			assistant("a1", [.toolUse(id: "call-bad", name: "quiz", input: bad)], stop: "tool_use"),
			result("call-bad", "quiz", details: nil, text: "correctAnswer \"cultural-diagnosis\" does not match any option value", isError: true),
			assistant("a2", [.toolUse(id: "call-good", name: "quiz", input: QUIZ_INPUT)], stop: "tool_use"),
		]
		let view = projectView(record)
		let failed = try #require(view[1].parts.first { $0.type == "tool-quiz" && $0.state == .outputError }, "the invalid call persisted as an error-state part")
		#expect(failed.errorText?.contains("does not match any option value") == true)
		#expect(failed.rawInput == bad)
	}

	/// "structurally invalid quiz input (unhealable garbage) never reaches the dock and retries clean"
	@Test func structurallyInvalidQuizIsAnErrorPart() throws {
		let stringy: JSONValue = [
			"question": "Lewis's indexical analysis of 'actual' — which is it?", "type": "check", "nodeId": "indexicals",
			"options": "definitely not a JSON array — denim all the way down", "correctAnswer": "indexical",
			"explanation": "Indexical: every world is actual to its own inhabitants.",
		]
		let record = [
			user("u1", "quiz me"),
			assistant("a1", [.toolUse(id: "call-stringy", name: "quiz", input: stringy)], stop: "tool_use"),
			result("call-stringy", "quiz", details: nil, text: "Validation failed for tool \"quiz\": options: must be array", isError: true),
			assistant("a2", [.toolUse(id: "call-clean", name: "quiz", input: QUIZ_INPUT)], stop: "tool_use"),
		]
		let failed = try #require(projectView(record)[1].parts.first { $0.toolCallId == "call-stringy" })
		#expect(failed.state == .outputError, "persisted as an error part")
		#expect(failed.errorText?.contains("options") == true)
	}

	/// "parallel quiz calls are asked, saved, and answered in the model's call order"
	@Test func parallelQuizPartsKeepCallOrder() {
		let record = [
			user("u1", "quiz me twice"),
			assistant("a1", [
				.toolUse(id: "call-a", name: "quiz", input: QUIZ_INPUT), .toolUse(id: "call-b", name: "quiz", input: QUIZ_INPUT),
			], stop: "tool_use"),
		]
		let ids = projectView(record)[1].parts.filter { $0.type == "tool-quiz" }.compactMap(\.toolCallId)
		#expect(ids == ["call-a", "call-b"], "parts persisted in call order")
	}

	/// "write-ahead: the learner's answer is durable BEFORE the turn finishes"
	@Test func writeAheadAnswerRendersAnsweredMidTurn() throws {
		let midTurn = [
			user("u1", "teach me the solar system"),
			assistant("a1", [.thinking("Probe the basics first.", signature: nil), .toolUse(id: "call-1", name: "quiz", input: QUIZ_INPUT)], stop: "tool_use"),
			result("call-1", "quiz", details: QUIZ_ANSWER),
		]
		let midQuiz = try #require(projectView(midTurn)[1].parts.first { $0.type == "tool-quiz" })
		#expect(midQuiz.state == .outputAvailable, "write-ahead persisted the answer before finish")
		let saved = midTurn + [assistant("a2", [.text("Right — Mercury it is.")])]
		#expect(projectView(saved).count == 2, "the projection groups the answered quiz + reaction")
	}

	/// "explain tool call persists as a pending part; the free-text answer reveals the commitment"
	@Test func explainPendingThenAnswered() throws {
		let input: JSONValue = [
			"question": "Explain why Mercury is hard to observe.",
			"correctAnswer": "Its small angular separation from the Sun — it never strays far from the Sun in our sky.",
			"nodeId": "planet-order", "type": "check",
		]
		let turn1 = [
			user("u1", "teach me the solar system"),
			assistant("a1", [.thinking("Free recall this time.", signature: nil), .toolUse(id: "call-1", name: "explain", input: input)], stop: "tool_use"),
		]
		#expect(projectView(turn1)[1].parts.contains { $0.type == "tool-explain" }, "tool-explain part projected — the dock arms")
		let answer: JSONValue = [
			"kind": "explain", "questionText": input["question"]!, "text": "It stays near the Sun.",
			"committed": input["correctAnswer"]!, "answeredAt": "2026-10-01T00:00:00.000Z",
		]
		let turn2 = turn1 + [result("call-1", "explain", details: answer), assistant("a2", [.text("Right — it hugs the Sun.")])]
		let part = try #require(projectView(turn2)[1].parts.first { $0.type == "tool-explain" })
		#expect(part.state == .outputAvailable)
		#expect(part.output?["committed"] == input["correctAnswer"], "the commitment snapshots into the answer record")
		#expect(part.output?["explanation"] == nil, "no explanation remnant")
	}

	/// "every `call_0` turn keeps its identity: ask answered as ask, quiz as quiz" (the Lacan fix)
	@Test func uniquifiedCallIdsKeepTheirOwnAnswers() throws {
		let ask: JSONValue = ["question": "What do you want from Lacan?"]
		let record = [
			user("u1", "teach me Lacan"),
			assistant("a1", [.text("First — a question about your goal."), .toolUse(id: "call_0", name: "ask_user_question", input: ask)], stop: "tool_use"),
			result("call_0", "ask_user_question", details: ["kind": "ask", "questionText": "What do you want from Lacan?", "dontKnow": false, "answers": [], "text": "The theory core"]),
			assistant("a2", [.text("The unconscious, then."), .toolUse(id: "call_0~2", name: "quiz", input: QUIZ_INPUT)], stop: "tool_use"),
			result("call_0~2", "quiz", details: QUIZ_ANSWER),
			assistant("a3", [.text("Right — and that is where Lacan begins.")]),
		]
		let tools = parts(projectView(record)).filter { $0.toolName != nil }
		let askPart = try #require(tools.first { $0.toolCallId == "call_0" })
		let quizPart = try #require(tools.first { $0.toolCallId == "call_0~2" })
		#expect(askPart.state == .outputAvailable)
		#expect(askPart.output?["kind"]?.stringValue == "ask", "the ask card keeps its own answer")
		#expect(quizPart.state == .outputAvailable)
		#expect(quizPart.output?["kind"]?.stringValue == "quiz", "the quiz card got ITS answer")
	}
}

// MARK: - practice-record.test.ts

@Suite struct PracticeRecordViewTests {
	private func problemPose(_ callId: String = "call_p1", _ statement: String = "Show that…") -> [Message] {
		[
			Message(id: "msg_a_\(callId)", timestamp: 1, body: .assistant(AssistantBody(
				content: [.toolUse(id: callId, name: PRACTICE_PROBLEM_TOOL, input: ["statement": .string(statement), "mode": "recall", "modelSolution": .string(statement)])],
				model: "test:test-model", stopReason: "tool_use", usage: MessageUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)))),
			Message(id: "msg_r_\(callId)", timestamp: 2, body: .toolResult(ToolResultBody(
				toolUseId: callId, toolName: PRACTICE_PROBLEM_TOOL, content: [.text("Problem posed — the turn ends here.")], isError: false))),
		]
	}

	private func concludeCall(_ outcome: String) -> [Message] {
		[
			Message(id: "msg_c_\(outcome)", timestamp: 3, body: .assistant(AssistantBody(
				content: [.toolUse(id: "call_conclude_\(outcome)", name: PRACTICE_CONCLUDE_TOOL, input: ["outcome": .string(outcome)])],
				model: "test:test-model", stopReason: "tool_use"))),
			Message(id: "msg_cr_\(outcome)", timestamp: 4, body: .toolResult(ToolResultBody(
				toolUseId: "call_conclude_\(outcome)", toolName: PRACTICE_CONCLUDE_TOOL,
				content: [.text("Problem concluded — the composer is free; pose the next problem or wrap up.")], isError: false))),
		]
	}

	/// "projectView enriches the conclude part with the reveal"
	@Test func concludePartCarriesTheRevealAndProblemInput() throws {
		let view = projectView(problemPose() + concludeCall("solved"))
		let conclude = try #require(parts(view).first { $0.type == "tool-conclude" }, "the conclude part projects")
		#expect(conclude.reveal == "Show that…", "the view-seam join carries the committed solution")
		#expect(conclude.problemInput == ["statement": "Show that…", "mode": "recall", "modelSolution": "Show that…"])
	}

	/// "the practice-next marker projects the compact part"
	@Test func practiceNextProjectsTheCompactPart() {
		let view = projectView([newNextMessage()])
		#expect((view.first?.parts ?? []).contains { $0.type == "data-practice-next" })
	}
}

// MARK: - jobs.test.ts

@Suite struct JobsViewTests {
	/// "the research call resolves immediately with an ack; the turn continues and the runner steers"
	@Test func researchPartResolvesAtDispatch() throws {
		let ack = "Dispatched (job job_1). This call is fire-and-forget: continue your turn and keep teaching — do not wait, poll, or mention waiting. The researched brief arrives as a new message when ready and the lesson resumes from it; cite its sources when you use them."
		let input: JSONValue = ["question": "What is the latest stable sigma.js version?", "context": "Choosing a graph rendering library for the lesson."]
		let record = [
			user("u1", "teach me graph rendering"),
			assistant("a1", [.text("Let me check the current state of the library."), .toolUse(id: "call-r1", name: "research", input: input)], stop: "tool_use"),
			result("call-r1", "research", details: .string(ack), text: ack),
			assistant("a2", [.text("Back with the brief.")]),
		]
		let part = try #require(projectView(record)[1].parts.first { $0.type == "tool-research" }, "research tool part persisted")
		#expect(part.state == .outputAvailable, "the part resolved at dispatch time (not held pending)")
		let output = try #require(part.output?.stringValue, "the output is the ack, not the result")
		#expect(output.contains("fire-and-forget"))
	}
}

// MARK: - graph-context.test.ts

@Suite struct GraphContextViewTests {
	/// "projectView: a user-side data part — never a text bubble"
	@Test func graphContextIsAUserSideDataPart() throws {
		let picks = [
			GraphContextPick(id: "n_a", name: "Modus ponens", statement: "If P implies Q and P holds, Q holds."),
			GraphContextPick(id: "n_b", name: "Soundness", statement: "A valid argument from true premises has a true conclusion."),
		]
		let m = newGraphContextMessage(picks: picks, chains: [])
		let view = projectView([m])
		#expect(view.count == 1)
		#expect(view[0].role == .user)
		let part = try #require(view[0].parts.first)
		#expect(part.type == "data-graph-context")
		#expect(part.data == m.marker?.details)
	}
}

// MARK: - session-core.test.ts

@Suite struct SessionCoreViewTests {
	/// The post-settle pose-turn record of a practice session.
	private func poseRecord() -> [Message] {
		[
			user("m1", "db practice"),
			assistant("m3", [.toolUse(id: "call-p1", name: "problem", input: ["statement": "Q?"])]),
			result("call-p1", "problem", details: nil, text: "Problem posed — the turn ends here."),
		]
	}

	/// "a settled problem call NEVER renders live during another turn (the two-spinner bug)"
	@Test func aSettledProblemCallNeverRendersLive() throws {
		let view = projectView(poseRecord(), live: LiveTurnState(inFlight: true))
		let problem = try #require(parts(view).first { $0.type == "tool-problem" }, "the problem part projects")
		#expect(problem.state == .inputAvailable, "settled = the ProblemCard, never a shimmer")
	}

	/// "a call in THIS turn's streaming message stays input-streaming"
	@Test func aCallInTheStreamingMessageIsInputStreaming() throws {
		let messages = poseRecord() + [assistant("c_as1", [.toolUse(id: "call-c1", name: "conclude", input: ["outcome": "solved"])])]
		let view = projectView(messages, live: LiveTurnState(inFlight: true, streamingIds: ["c_as1"]))
		let conclude = try #require(parts(view).first { $0.type == "tool-conclude" }, "the conclude part projects")
		#expect(conclude.state == .inputStreaming, "the live card renders at the bottom, by construction")
	}

	/// "a DANGLING call in a settled message is the dock's pending — not a mid-turn shimmer"
	@Test func aDanglingSettledCallIsPending() throws {
		let messages = [user("m1", "go"), assistant("m2", [.toolUse(id: "call-p9", name: "problem", input: ["statement": "Q?"])])]
		let part = try #require(parts(projectView(messages, live: LiveTurnState(inFlight: true))).first { $0.type == "tool-problem" })
		#expect(part.state == .inputAvailable, "no evidence, no shimmer — even mid-turn")
	}

	// The model-level cases below drive the session model (applyWireEvent);
	// their view assertions are ported over the record + live layer that
	// model holds at the asserted moment.

	/// "ignores the question placeholder's clean execution end (fork 2) and keeps errors"
	@Test func cleanQuestionExecutionIsIgnoredErrorsKept() throws {
		let streaming = assistant("c_1", [.toolUse(id: "q1", name: "quiz", input: [:]), .toolUse(id: "bad1", name: "quiz", input: [:])])
		let live = LiveTurnState(executions: [
			"q1": LiveExecution(isError: false, output: ["placeholder": true]),
			"bad1": LiveExecution(isError: true, errorText: "correctAnswer does not match any option value"),
		], inFlight: true, streamingIds: ["c_1"])
		let quizParts = parts(projectView([user("u1", "q"), streaming], live: live)).filter { $0.type == "tool-quiz" }
		#expect(quizParts.count == 2)
		#expect(quizParts[0].state == .inputAvailable, "the clean placeholder is IGNORED — the dock mounts on it")
		#expect(quizParts[1].state == .outputError)
		#expect(quizParts[1].errorText == "correctAnswer does not match any option value")

		// turn_end carries the placeholder as a toolResult MESSAGE (details null).
		let placeholder = result("q1", "quiz", details: nil, text: "Question posed — the turn ends here; the learner's graded answer arrives as this call's result.")
		let after = parts(projectView([user("u1", "q"), streaming, placeholder], live: live)).filter { $0.type == "tool-quiz" }
		#expect(after[0].state == .inputAvailable, "the placeholder toolResult keeps the dock's mount state")
		#expect(after[0].output == nil, "no null output ever reaches the AnsweredCard")
	}

	/// "the optimistic answer result attaches to the pending quiz part at once"
	@Test func optimisticAnswerAttachesToThePendingQuiz() throws {
		let quizCall = assistant("call-1", [
			.text("Q?"), .toolUse(id: "call-1", name: "quiz", input: ["question": "Q?", "choices": ["a", "b"]]),
		], stop: "tool_use")
		let view = projectView([user("u1", "hi"), quizCall, result("call-1", "quiz", details: ["correct": true])])
		let quiz = try #require(parts(view).first { $0.type == "tool-quiz" })
		#expect(quiz.state == .outputAvailable)
		#expect(quiz.output == ["correct": true])
	}

	/// "Wave C: markers injected mid-run … append to the tail by id"
	@Test func aSteerMarkerProjectsItsArtifactPart() throws {
		let steer = Message(id: "steer_job_x_1", timestamp: 2, body: .marker(MarkerBody(
			kind: .subagentSteer, content: "The research result arrived.", details: ["jobId": "job_x", "kind": "research"])))
		let view = projectView([user("u1", "hello"), steer])
		#expect(view.count >= 2, "the marker produced a view message")
		let tail = try #require(view.last)
		#expect(tail.role == .user, "a steer marker projects as a user-role view message")
		#expect(tail.parts.contains { $0.type == "data-subagent-artifact" }, "the marker renders its artifact part")
		#expect(tail.metadata?["subagentResult"]?["jobId"]?.stringValue == "job_x")
	}

	/// "a replayed CONTINUATION mounts BESIDE the seeded message"
	@Test func aContinuationGroupsWithAStepSeparator() {
		let view = projectView([assistant("seed", [.text("the question")]), assistant("c_2", [.text("the reaction")])])
		#expect(view.count == 1, "one continuous assistant document")
		#expect(view[0].parts.map(\.type) == ["step-start", "text", "step-start", "text"])
	}
}

// MARK: - The typed part surface

@Suite struct ViewPartSurfaceTests {
	@Test func partKindsRoundTripTheTSTypeStrings() {
		for type in ["text", "reasoning", "step-start", "tool-quiz", "tool-plan_init", "data-compaction-cut", "data-plan-block"] {
			#expect(ViewPartKind(type: type)?.type == type)
		}
		#expect(ViewPartKind(type: "bogus") == nil)
	}

	@Test func planBlockSplicesAfterTheLastSuccessfulPlanInit() {
		let record = [
			user("u1", "plan it"),
			assistant("a1", [.toolUse(id: "p1", name: "plan_init", input: [:]), .text("Here is the plan.")], stop: "tool_use"),
			result("p1", "plan_init", details: ["ok": true]),
			Message(id: "pb_1", timestamp: 3, body: .marker(MarkerBody(kind: .planBlock, content: "", details: ["planCallId": "p1", "block": ["kind": "full"]]))),
		]
		let types = projectView(record)[1].parts.map(\.type)
		#expect(types == ["step-start", "tool-plan_init", "data-plan-block", "text"])
	}
}
