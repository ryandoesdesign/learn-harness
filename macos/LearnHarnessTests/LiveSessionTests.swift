import Foundation
import LHCore
import Testing
@testable import LearnHarness

// The live-session UI rules, ported from their TS specs: render-composer
// (enterAction), esc-layering (escAbortTarget), reveal-arrival,
// render-abort-turn-dialog (copy), render-sidebar (live meta), the dock
// teaser, and the dock's question construction.

@Suite struct LiveSessionRuleTests {
	@Test func enterActionPrecedence() {
		#expect(enterAction(busy: true, canSend: true) == .send, "typed text while busy is a steer")
		#expect(enterAction(busy: true, canSend: false) == .stop)
		#expect(enterAction(busy: false, canSend: true) == .send)
		#expect(enterAction(busy: false, canSend: false, nextProblem: true) == .next)
		#expect(enterAction(busy: false, canSend: false) == .none)
	}

	@Test func escLayering() {
		#expect(escAbortTarget(abortAsk: true, diagram: true, plan: true, setup: true, pending: true, problem: true, busy: true) == nil)
		#expect(escAbortTarget(abortAsk: false, diagram: true, plan: true, setup: false, pending: true, problem: false, busy: true) == .diagram)
		#expect(escAbortTarget(abortAsk: false, diagram: false, plan: true, setup: false, pending: true, problem: false, busy: true) == .plan)
		#expect(escAbortTarget(abortAsk: false, diagram: false, plan: false, setup: false, pending: true, problem: false, busy: true) == .question)
		#expect(escAbortTarget(abortAsk: false, diagram: false, plan: false, setup: false, pending: false, problem: false, busy: true) == .turn)
		#expect(escAbortTarget(abortAsk: false, diagram: false, plan: false, setup: false, pending: false, problem: false, busy: false) == nil)
	}

	@Test func revealArrivalRules() {
		#expect(revealArrival(wasQuestion: true) == (true, true))
		#expect(revealArrival(wasQuestion: false) == (false, false))
	}

	@Test func abortDialogCopy() {
		#expect(AbortMode.turn.title == "Abort this turn?")
		#expect(AbortMode.turn.line(busy: true) == "The partial answer stays in the transcript.")
		#expect(AbortMode.question.title == "Dismiss this question?")
		#expect(AbortMode.question.line(busy: false) == "Skipped — the teacher moves on without it.")
		#expect(AbortMode.question.line(busy: true) == "Skipped — the teacher moves on without it. The working turn stops too.")
		#expect(AbortMode.question.action == "Dismiss")
	}

	@Test func sidebarLiveMeta() {
		let s = ChatSummary(id: "1", title: "t", createdAt: "", updatedAt: "2026-10-24T00:00:00.000Z", kind: .teach, messageCount: 0, phase: .probe, pendingQuestion: false, pendingProblem: false)
		let now = ISO8601DateFormatter().date(from: "2026-10-24T00:05:00Z")!
		#expect(sessionMeta(s, busy: true, now: now) == "Working…")
		#expect(sessionMeta(s, busy: true, compacting: true, now: now) == "Compacting context · 5m ago")
	}

	@Test func teaserFlattensMath() {
		#expect(teaserText(#"What is $\frac{a}{b}$ when \(x\) is   large?"#) == "What is a/b when x is large?")
	}

	@Test func dockQuestionShufflesDeterministicallyAndLabels() throws {
		let input: JSONValue = ["type": "predict", "nodeId": "n", "question": "Q?", "options": [["label": "A", "value": "a"], ["label": "B", "value": "b"], ["label": "C", "value": "c"]], "explanation": "e", "correctAnswer": "b"]
		let q1 = try #require(dockQuestion(tool: "quiz", toolCallId: "call_1", input: input, now: 0))
		let q2 = try #require(dockQuestion(tool: "quiz", toolCallId: "call_1", input: input, now: 0))
		#expect(q1.options == q2.options, "seeded by the call id")
		#expect(q1.correctIndices.map { $0.map { q1.options[$0 - 1].value } } == ["b"], "1-based indices")
		#expect(dockLabel(tool: "quiz", question: q1) == "Prediction")
		#expect(dockLabel(tool: "probe", question: q1) == "Probe")
		let explain = try #require(dockQuestion(tool: "recall", toolCallId: "c2", input: ["question": "Why?", "correctAnswer": "Because."]))
		#expect(explain.mode == .text && explain.committedAnswer == "Because.")
		#expect(dockLabel(tool: "recall", question: explain) == "Recall")
		#expect(dockQuestion(tool: "quiz", toolCallId: "c3", input: ["question": "Q?"]) == nil, "malformed")
	}
}
