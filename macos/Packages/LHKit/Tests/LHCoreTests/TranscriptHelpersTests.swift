import Foundation
import Testing
@testable import LHCore

// M4's view-side helpers: the view-dialect phase fold, latestTree, session
// navigation anchors and the usage formatters (usage-format.ts, timeAgo).

private func tool(_ name: String, _ state: ViewPartState, input: JSONValue? = nil, output: JSONValue? = nil) -> ViewPart {
	ViewPart(kind: .tool(name), state: state, toolCallId: "c_\(name)", input: input, output: output)
}

private let step = ViewPart(kind: .stepStart)
private let text = ViewPart(kind: .text, id: "a1-t0", text: "hi", state: .done)

@Suite struct ViewPhaseTests {
	@Test func probeToPlanToTeach() {
		let msgs = [
			ViewMessage(id: "1", role: .assistant, parts: [tool("probe_done", .inputAvailable)]),
			ViewMessage(id: "2", role: .assistant, parts: [tool("probe_done", .outputAvailable)]),
			ViewMessage(id: "3", role: .assistant, parts: [tool("quiz", .outputAvailable, input: [:])]),
			ViewMessage(id: "4", role: .assistant, parts: [tool("quiz", .inputAvailable, input: ["nodeId": "n1"])]),
		]
		#expect(viewPhaseTimeline(msgs) == [.probe, .plan, .plan, .teach])
	}
	@Test func teachCannotSkipThePlan() {
		let msgs = [ViewMessage(id: "1", role: .assistant, parts: [tool("explain", .outputAvailable, input: ["nodeId": "n1"])])]
		#expect(viewPhaseTimeline(msgs) == [.probe])
	}
	@Test func teachStepIndexFirstStepIsMinusOne() {
		#expect(viewTeachStepIndex([step, tool("quiz", .inputAvailable, input: ["nodeId": "n"])]) == -1)
		#expect(viewTeachStepIndex([text]) == -1)
	}
	@Test func teachStepIndexLaterStepIsItsBoundary() {
		let parts = [step, text, step, tool("quiz", .inputAvailable, input: ["nodeId": "n"])]
		#expect(viewTeachStepIndex(parts) == 2)
	}
}

@Suite struct LatestTreeTests {
	@Test func latestSuccessfulPlanOutputWins() {
		let t1: JSONValue = ["nodes": [["id": "a", "title": "A"]], "edges": [], "version": 1]
		let t2: JSONValue = ["nodes": [["id": "b", "title": "B"]], "edges": [], "version": 2]
		let msgs = [
			ViewMessage(id: "1", role: .assistant, parts: [tool("plan_init", .outputAvailable, output: ["ok": true, "tree": t1])]),
			ViewMessage(id: "2", role: .assistant, parts: [
				tool("plan_add", .outputAvailable, output: ["ok": true, "tree": t2]),
				tool("plan_add", .outputError, output: ["ok": false]),
			]),
		]
		#expect(latestTree(msgs)?.nodes.map(\.id) == ["b"])
	}
	@Test func noPlanIsNil() {
		#expect(latestTree([ViewMessage(id: "1", role: .assistant, parts: [text])]) == nil)
	}
}

@Suite struct SessionNavigationTests {
	@Test func anchorsRoundTrip() {
		#expect(messageAnchorId("abc") == "message-abc")
		#expect(messageIdFromAnchor("#message-abc") == "abc")
		#expect(messageIdFromAnchor("message-") == nil)
		#expect(messageIdFromAnchor("other") == nil)
	}
	@Test func textPartIdentity() {
		#expect(textPartMessageId("m1-t0") == "m1")
		#expect(textPartMessageId("a-b-t12") == "a-b")
		#expect(textPartMessageId("m1") == nil)
		#expect(textPartMessageId(nil) == nil)
	}
	@Test func firstNonEmptyProseAnchorsEachMessage() {
		let msgs = [ViewMessage(id: "g", role: .assistant, parts: [
			ViewPart(kind: .text, id: "m1-t0", text: "  ", state: .done),
			ViewPart(kind: .reasoning, text: "hmm"),
			ViewPart(kind: .text, id: "m1-t1", text: "first", state: .done),
			ViewPart(kind: .text, id: "m1-t2", text: "second", state: .done),
			ViewPart(kind: .text, id: "m2-t0", text: "other", state: .done),
		])]
		#expect(firstSourceTextParts(msgs) == ["m1": "m1-t1", "m2": "m2-t0"])
	}
}

@Suite struct UsageFormatTests {
	@Test func usd() {
		#expect(formatUsd(1.234) == "$1.23")
		#expect(formatUsd(0.01234) == "$0.0123")
		#expect(formatUsd(0) == "$0.0000")
	}
	@Test func tokens() {
		#expect(formatTokens(38000) == "38k")
		#expect(formatTokens(1_234_567) == "1.2M")
		#expect(formatTokens(1250) == "1.3k") // JS toFixed: an exact tie rounds up
		#expect(formatTokens(999) == "999")
	}
	@Test func jsToFixedMatchesJS() {
		#expect(jsToFixed(1.005, 2) == "1.00") // 1.005 is 1.00499999… in binary
		#expect(jsToFixed(0.25, 1) == "0.3")
		#expect(jsToFixed(9.96, 1) == "10.0")
		#expect(jsToFixed(-0.04, 1) == "0.0")
	}
	@Test func models() {
		#expect(prettyModel("z-ai/glm-5.3-flash") == "glm-5.3-flash")
		#expect(prettyModel("qwen3.8-max-0902") == "qwen3.8-max")
		#expect(prettyModel("openrouter:z-ai/glm-5.3-flash", qualified: true) == "glm-5.3-flash · openrouter")
		#expect(prettyModel("claude-sonnet-5") == "claude-sonnet")
	}
	@Test func ago() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		func iso(_ secondsAgo: Double) -> String {
			let f = ISO8601DateFormatter()
			f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			return f.string(from: now.addingTimeInterval(-secondsAgo))
		}
		#expect(timeAgo(iso(30), now: now) == "just now")
		#expect(timeAgo(iso(5 * 60), now: now) == "5m ago")
		#expect(timeAgo(iso(3 * 3600), now: now) == "3h ago")
		#expect(timeAgo(iso(2 * 86400), now: now) == "2d ago")
		#expect(timeAgo(iso(30 * 86400), now: now).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
	}
}

@Suite struct PlanLayoutTests {
	let nodes = ["a", "b", "c", "d", "e"].map { PlanLayoutNode(id: $0, title: "Node \($0.uppercased()) with a title long enough to wrap twice") }
	let edges = [PlanEdge(from: "a", to: "b"), PlanEdge(from: "a", to: "c"), PlanEdge(from: "b", to: "d"), PlanEdge(from: "c", to: "d"), PlanEdge(from: "a", to: "e"), PlanEdge(from: "d", to: "e")]

	@Test func wrapsAndSizesLikeTheTSBlock() {
		#expect(wrapTitle("  ") == [""])
		#expect(wrapTitle("one two three four five six seven") == ["one two three four five six", "seven"])
		#expect(wrapTitle(String(repeating: "x", count: 30)) == [String(repeating: "x", count: 28), "xx"])
		#expect(planNodeWidth(["hi"]) == PLAN_NODE_W_MIN)
	}
	@Test func everyEdgePointsDownARank() {
		let r = planLayout(nodes, edges)
		for e in r.edges {
			#expect(r.node(e.from)!.rank < r.node(e.to)!.rank)
			#expect(e.points.first!.y < e.points.last!.y)
		}
		#expect(r.edges.count == edges.count)
	}
	@Test func noNodesOverlap() {
		let r = planLayout(nodes, edges)
		for (i, a) in r.nodes.enumerated() {
			for b in r.nodes.dropFirst(i + 1) {
				let apart = a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y
				#expect(apart, "\(a.id) overlaps \(b.id)")
			}
		}
		#expect(r.nodes.allSatisfy { $0.x >= 0 && $0.x + $0.w <= r.width + 0.0001 })
	}
	@Test func longEdgesRouteThroughWaypoints() {
		let r = planLayout(nodes, edges)
		let ae = r.edges.first { $0.from == "a" && $0.to == "e" }!
		#expect(ae.points.count == 2 + (r.node("e")!.rank - r.node("a")!.rank - 1))
	}
	@Test func deterministicAndDefensive() {
		#expect(planLayout(nodes, edges) == planLayout(nodes, edges))
		let cyclic = planLayout(nodes.prefix(2).map { $0 }, [PlanEdge(from: "a", to: "b"), PlanEdge(from: "b", to: "a"), PlanEdge(from: "a", to: "ghost")])
		#expect(cyclic.nodes.count == 2)
		#expect(planLayout([], []).nodes.isEmpty)
	}
}

@Suite struct AnswerRecordReadTests {
	@Test func roundTripsTheStoredRecord() {
		var a = QuestionAnswerData(kind: .quiz, questionText: "Q?", dontKnow: false, answers: [OptionAnswer(label: "A", value: "a", index: 1)], answeredAt: "2026-10-24T00:00:00.000Z")
		a.tool = "quiz"
		a.questionType = .predict
		a.options = [.init(index: 1, label: "A"), .init(index: 2, label: "B")]
		a.correct = true
		a.correctIndices = [1]
		a.confidence = 70
		a.explanation = "because"
		a.thinking = "hm"
		#expect(QuestionAnswerData(json: a.json) == a)
	}
	@Test func notAnAnswerIsNil() {
		#expect(QuestionAnswerData(json: ["ok": true]) == nil)
	}
}
