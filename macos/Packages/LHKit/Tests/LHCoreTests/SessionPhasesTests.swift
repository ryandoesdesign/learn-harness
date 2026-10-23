import Foundation
import Testing
@testable import LHCore

// Port of tests/phases.test.ts. The TS view-part cases (phaseAt3 /
// phaseTimeline over UI parts) run here over the equivalent NATIVE record:
// a part "output-available" is a call + its clean result, "output-error" a
// call + an errored result, "input-available" the call alone.

private func user(_ text: String) -> Message {
	newUserMessage(text, id: "u_\(text)", now: 0)
}

private func nextId() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

private func call(_ name: String, _ input: JSONValue = [:], callId: String? = nil) -> Message {
	let id = nextId()
	return Message(id: "a_\(id)", timestamp: 0, body: .assistant(AssistantBody(
		content: [.toolUse(id: callId ?? "call_\(id)", name: name, input: input)], model: "test", stopReason: "tool_use")))
}

private func toolResult(_ name: String, callId: String? = nil, isError: Bool = false, details: JSONValue? = nil) -> Message {
	Message(id: "tr_\(name)_\(nextId())", timestamp: 0, body: .toolResult(ToolResultBody(
		toolUseId: callId ?? "call_\(name)", toolName: name, content: [.text("ok")], isError: isError, details: details)))
}

/// An assistant tool part in the given state, as native messages.
private func assistantTool(_ name: String, _ state: String, _ output: JSONValue? = nil) -> [Message] {
	let c = call(name)
	let callId = c.assistant!.toolUses[0].id
	switch state {
	case "output-available": return [c, toolResult(name, callId: callId, details: output)]
	case "output-error": return [c, toolResult(name, callId: callId, isError: true, details: output)]
	default: return [c]
	}
}

/// A quiz call — `nodeId` present iff tagged.
private func assistantQuiz(_ input: JSONValue) -> Message { call("quiz", input) }

private let DONE_ASSESSMENT: JSONValue = ["assessment": ["strands": [["strand": "s", "assessment": "a"]]]]
private let PLAN_OK: JSONValue = ["ok": true, "tree": ["nodes": [["id": "n1", "title": "N"]], "edges": []]]

@Suite struct SessionPhasesTests {
	@Test func probeUntilConcludedProbeDoneThenPlanUntilFirstTaggedQuizThenTeach() {
		let probe = phaseAt3Lh([user("teach me calculus"), assistantQuiz(["question": "q", "correctAnswer": "a"])])
		#expect(probe == .probe, "an UNTAGGED quiz alone never ends the probe")

		let concluded = phaseAt3Lh([user("teach me")] + assistantTool("probe_done", "output-available", DONE_ASSESSMENT))
		#expect(concluded == .plan, "a concluded probe_done ends the probe")

		let presented = [user("teach me")]
			+ assistantTool("probe_done", "output-available", DONE_ASSESSMENT)
			+ assistantTool("plan_init", "output-available", PLAN_OK)
			+ [user("looks good, go")]
		#expect(phaseAt3Lh(presented) == .plan, "plan_init + the go-ahead TEXT sanction nothing")

		let teaching = presented + [assistantQuiz(["question": "q", "nodeId": "gravity-basics", "correctAnswer": "a"])]
		#expect(phaseAt3Lh(teaching) == .teach, "the first nodeId-tagged quiz CALL is where teaching begins")

		let failedPlan = [user("teach me")]
			+ assistantTool("probe_done", "output-available", DONE_ASSESSMENT)
			+ assistantTool("plan_init", "output-error", ["ok": false, "error": "bad mermaid"])
			+ [assistantQuiz(["question": "q", "nodeId": "n1", "correctAnswer": "a"])]
		#expect(phaseAt3Lh(failedPlan) == .teach, "a tagged quiz begins teaching even after a failed init")
	}

	@Test func theTagIsTheSeam() {
		let plainText = [user("teach me")]
			+ assistantTool("probe_done", "output-available", DONE_ASSESSMENT)
			+ assistantTool("plan_init", "output-available", PLAN_OK)
			+ [user("The plan is accepted — begin teaching."), assistantQuiz(["question": "ad-hoc check", "correctAnswer": "a"])]
		#expect(phaseAt3Lh(plainText) == .plan, "only a nodeId-tagged quiz flips the seam")

		let taggedOutOfOrder = [user("teach me"), assistantQuiz(["question": "q", "nodeId": "n1", "correctAnswer": "a"])]
		#expect(phaseAt3Lh(taggedOutOfOrder) == .probe, "the chain never skips")
	}

	@Test func aMereProbeDoneCallKeepsTheProbeOpen() {
		#expect(phaseAt3Lh([user("teach me")] + assistantTool("probe_done", "input-available")) == .probe)
	}

	@Test func legacyTranscriptsWithoutProbeDoneReadAsProbe() {
		let legacy = [user("teach me lacan")] + assistantTool("plan_init", "output-available", PLAN_OK)
		#expect(phaseAt3Lh(legacy) == .probe, "plan_init alone never flips a phase")
	}

	@Test func phaseTimelineFoldsMessagesIntoSpans() {
		let messages = [user("teach me")]
			+ assistantTool("quiz", "output-available")
			+ assistantTool("probe_done", "output-available", DONE_ASSESSMENT)
			+ assistantTool("plan_init", "output-available", PLAN_OK)
			+ [user("what does node 1 mean?"), user("go on")]
			+ [assistantQuiz(["question": "q", "nodeId": "n1", "correctAnswer": "a"])]
			+ [assistantQuiz(["question": "q2", "nodeId": "n2", "correctAnswer": "a"])]
		let timeline = phaseTimeline(messages)
		// user · quiz call+result · probe_done call+RESULT · plan_init call+result · 2 users · 2 tagged quizzes
		#expect(timeline == [.probe, .probe, .probe, .probe, .plan, .plan, .plan, .plan, .plan, .teach, .teach])
		#expect(timeline.count == 11)
		for i in messages.indices { #expect(timeline[i] == phaseAt3Lh(messages, upToIndex: i)) }
	}

	@Test func emptyTranscriptIsProbe() {
		#expect(phaseAt3Lh([]) == .probe)
		#expect(phaseTimeline([]).isEmpty)
	}

	// ─── the native fold ───────────────────────────────────────────────

	@Test func nativeFoldProbeToPlanAtCleanResultPlanToTeachAtTaggedCall() {
		let done = toolResult("probe_done")
		let tagged = assistantQuiz(["question": "q", "nodeId": "gravity-basics", "correctAnswer": "a"])
		let untagged = assistantQuiz(["question": "q", "correctAnswer": "a"])
		#expect(phaseAt3Lh([done, untagged]) == .plan, "an untagged quiz call never starts teaching")
		#expect(phaseAt3Lh([done, tagged]) == .teach, "the tagged quiz CALL is the seam")
		#expect(phaseAt3Lh([tagged]) == .probe, "the chain never skips")
		#expect(phaseAt3Lh([toolResult("probe_done", isError: true), tagged]) == .probe, "an ERRORED probe_done concludes nothing")
	}

	@Test func aTaggedExplainCallIsTheSeamToo() {
		let done = toolResult("probe_done")
		let tagged = call("explain", ["question": "q", "correctAnswer": "a", "explanation": "e", "nodeId": "gravity-basics"])
		let untagged = call("explain", ["question": "q", "correctAnswer": "a", "explanation": "e"])
		#expect(phaseAt3Lh([done, untagged]) == .plan, "an untagged explain never starts teaching")
		#expect(phaseAt3Lh([done, tagged]) == .teach, "the tagged explain CALL is the seam")
	}

	@Test func anEmptyNodeIdIsUntagged() {
		#expect(phaseAt3Lh([toolResult("probe_done"), assistantQuiz(["nodeId": ""])]) == .plan)
		#expect(phaseAt3Lh([toolResult("probe_done"), assistantQuiz(["nodeId": 3])]) == .plan)
	}

	@Test func upToIndexIsInclusiveAndClamped() {
		let messages = [toolResult("probe_done"), assistantQuiz(["nodeId": "n1"])]
		#expect(phaseAt3Lh(messages, upToIndex: -1) == .probe)
		#expect(phaseAt3Lh(messages, upToIndex: 0) == .plan)
		#expect(phaseAt3Lh(messages, upToIndex: 1) == .teach)
		#expect(phaseAt3Lh(messages, upToIndex: 99) == .teach)
	}

	// ─── teachStepIndex (native adaptation; no TS spec — pins the doc) ──

	@Test func teachStepIndexFirstStepIsMinusOneLaterStepIsItsIndex() {
		let tagged = assistantQuiz(["nodeId": "n1"])
		let presentation = Message(id: "a_plan", timestamp: 0, body: .assistant(AssistantBody(content: [.text("Here is the plan.")], model: "test", stopReason: "end_turn")))
		#expect(teachStepIndex([tagged]) == -1, "first step → the divider goes before the whole group")
		#expect(teachStepIndex([presentation, toolResult("plan_init"), tagged]) == 2, "a later step → that step's index")
		#expect(teachStepIndex([presentation, assistantQuiz(["question": "untagged"])]) == -1, "no tagged call → -1")
		let empty = Message(id: "a_empty", timestamp: 0, body: .assistant(AssistantBody(content: [], model: "test", stopReason: "end_turn")))
		#expect(teachStepIndex([empty, tagged]) == -1, "an empty assistant message projects no step")
	}
}
