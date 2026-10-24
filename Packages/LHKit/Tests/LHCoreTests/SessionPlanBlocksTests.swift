import Foundation
import Testing
@testable import LHCore

// Port of tests/plan-blocks.test.ts. The TS cases run emission THROUGH the
// view projection (projectView); here they assert on the emitted markers'
// snapshot directly. The in-flow POSITION cases are the view's (M4).

// 5-node fixture: a → b → c, b → d, d → e.
private let TREE = PlanTree(
	nodes: ["a", "b", "c", "d", "e"].map { PlanNode(id: $0, title: $0.uppercased()) },
	edges: [PlanEdge(from: "a", to: "b"), PlanEdge(from: "b", to: "c"), PlanEdge(from: "b", to: "d"), PlanEdge(from: "d", to: "e")],
	version: 1)

/// A rewrite fixture: 3 fresh nodes.
private let TREE2 = PlanTree(
	nodes: ["x", "y", "z"].map { PlanNode(id: $0, title: $0.uppercased()) },
	edges: [PlanEdge(from: "x", to: "y"), PlanEdge(from: "y", to: "z")],
	version: 2)

private func treeJSON(_ t: PlanTree) -> JSONValue { (try? JSONCodec.encode(t)) ?? .null }

private func assistantWithCall(_ id: String, _ name: String, _ args: JSONValue, _ text: String...) -> Message {
	Message(id: id, timestamp: 0, body: .assistant(AssistantBody(
		content: text.map(Block.text) + [.toolUse(id: "call_\(id)", name: name, input: args)], model: "openrouter:test", stopReason: "end_turn")))
}

private func resultOf(_ callId: String, _ toolName: String, _ details: JSONValue, isError: Bool = false) -> Message {
	Message(id: "r_\(callId)\(isError ? "_e" : "")", timestamp: 0, body: .toolResult(ToolResultBody(
		toolUseId: "call_\(callId)", toolName: toolName, content: [.text(isError ? "failed" : "ok")], isError: isError, details: details)))
}

private func initTurn(_ id: String, _ tree: PlanTree) -> [Message] {
	[assistantWithCall(id, "plan_init", ["tree": treeJSON(tree)]), resultOf(id, "plan_init", ["ok": true, "tree": treeJSON(tree)])]
}

/// The emitted snapshots for a turn over a record (the persistTurn slice).
private func emitted(_ record: [Message], _ turn: [Message], _ tree: PlanTree?) -> [Message] {
	planBlocksFor(record: record, newMessages: turn, tree: tree, transcript: record + turn)
}

/// Every plan-block snapshot in a record.
private func blocksOf(_ messages: [Message]) -> [JSONValue] {
	messages.compactMap { m in m.marker?.kind == .planBlock ? m.marker?.details["block"] : nil }
}

@Suite struct SessionPlanBlocksTests {
	@Test func aSuccessfulPlanInitTurnGainsOneFullBlock() throws {
		let turn = [assistantWithCall("m1", "plan_init", ["tree": treeJSON(TREE)], "Here is the plan."), resultOf("m1", "plan_init", ["ok": true, "tree": treeJSON(TREE)])]
		let blocks = blocksOf(emitted([], turn, TREE))
		#expect(blocks.count == 1)
		let data = try #require(blocks.first)
		#expect(data["kind"] == "full")
		#expect(data["current"] == .null, "at authoring nothing is current")
		#expect(data["nodes"]?.arrayValue?.count == 5)
		#expect(data["nodes"]?.arrayValue?.allSatisfy { $0["status"] == "upcoming" } == true)
		#expect(data["edges"]?.arrayValue?.count == 4)
	}

	@Test func aFailedPlanInitGainsNothing() {
		let turn = [assistantWithCall("m1", "plan_init", ["tree": treeJSON(TREE)], "oops"), resultOf("m1", "plan_init", ["ok": false, "error": "bad"], isError: true)]
		#expect(emitted([], turn, TREE).isEmpty)
	}

	@Test func idempotentOnPersistReplay() {
		let turn = initTurn("m1", TREE)
		#expect(emitted([], turn, TREE).count == 1)
		let record = turn + planBlocksFor(record: [], newMessages: turn, tree: TREE, transcript: turn)
		#expect(planBlocksFor(record: record, newMessages: turn, tree: TREE, transcript: record).isEmpty, "no duplicate block on persist replay")
	}

	@Test func aLaterTurnRewriteGetsItsOwnBlock() {
		let first = initTurn("m1", TREE)
		let record = first + planBlocksFor(record: [], newMessages: first, tree: TREE, transcript: first)
		let second = initTurn("m2", TREE2)
		let blocks = blocksOf(record + second + emitted(record, second, TREE2))
		#expect(blocks.count == 2, "one full block per authoring turn")
		#expect(blocks[1]["nodes"]?.arrayValue?.count == 3)
	}

	@Test func aSameTurnRewriteEmitsOneBlockForTheLastCall() {
		let turn = [
			assistantWithCall("m1", "plan_init", ["tree": treeJSON(TREE)], "v1"),
			resultOf("m1", "plan_init", ["ok": true, "tree": treeJSON(TREE)]),
			assistantWithCall("m2", "plan_init", ["tree": treeJSON(TREE2)], "v2"),
			resultOf("m2", "plan_init", ["ok": true, "tree": treeJSON(TREE2)]),
		]
		let out = emitted([], turn, TREE2)
		#expect(out.count == 1, "one block per turn even on a same-turn rewrite")
		#expect(out.first?.marker?.details["planCallId"] == "call_m2", "the block presents the last successful init")
	}

	@Test func quizzesAloneEmitNothing() {
		let turn = [assistantWithCall("m1", "quiz", ["nodeId": "b", "question": "q?"]), resultOf("m1", "quiz", ["correct": true])]
		#expect(emitted([], turn, TREE).isEmpty)
	}

	@Test func noTreeEmptyTreeNoMessagesAreNoOps() {
		let turn = initTurn("m1", TREE)
		#expect(planBlocksFor(record: [], newMessages: turn, tree: nil, transcript: []).isEmpty, "no tree → nothing")
		#expect(planBlocksFor(record: [], newMessages: turn, tree: emptyTree(), transcript: []).isEmpty, "empty tree → nothing")
		#expect(planBlocksFor(record: [], newMessages: [], tree: TREE, transcript: []).isEmpty, "no messages → nothing")
	}

	@Test func midLessonRewriteDerivesStatusesFromTheWholeTranscript() throws {
		let before = [assistantWithCall("m0", "quiz", ["nodeId": "b", "question": "q?"]), resultOf("m0", "quiz", ["correct": true])]
		let data = try #require(blocksOf(emitted(before, initTurn("m1", TREE), TREE)).first)
		#expect(data["current"] == "b")
		#expect(data["nodes"]?.arrayValue?.first { $0["id"] == "b" }?["status"] == "current")
	}

	// ─── Swift-side: the injected clock and the marker envelope ─────────

	@Test func theInjectedClockStampsAtAndTheMarker() throws {
		let at = Date(timeIntervalSince1970: 1_700_000_000.5)
		let m = try #require(planBlocksFor(record: [], newMessages: initTurn("m1", TREE), tree: TREE, transcript: [], now: at).first)
		#expect(m.timestamp == 1_700_000_000_500)
		#expect(m.id.hasPrefix("pb_\(String(1_700_000_000_500, radix: 36))_"))
		let marker = try #require(m.marker)
		#expect(marker.kind == .planBlock)
		#expect(marker.content == "")
		#expect(marker.details["planCallId"] == "call_m1")
		#expect(marker.details["block"]?["at"] == "2023-11-14T22:13:20.500Z")
		// TS key order: kind, at, current, nodes, edges.
		#expect(marker.details["block"]?.objectValue?.keys == ["kind", "at", "current", "nodes", "edges"])

		let early = try #require(planBlocksFor(record: [], newMessages: initTurn("m1", TREE), tree: TREE, transcript: [], now: Date(timeIntervalSince1970: -1)).first)
		#expect(early.marker?.details["block"]?["at"] == "1969-12-31T23:59:59.000Z")
		let leap = try #require(planBlocksFor(record: [], newMessages: initTurn("m1", TREE), tree: TREE, transcript: [], now: Date(timeIntervalSince1970: 951_782_400)).first)
		#expect(leap.marker?.details["block"]?["at"] == "2000-02-29T00:00:00.000Z")
	}

	@Test func emittedPlanBlockCallsReadsMarkers() {
		let a = newPlanBlockMessage(planCallId: "call_1", block: [:], now: 0)
		let b = newPlanBlockMessage(planCallId: "call_2", block: [:], now: 0)
		let other = newNextMessage(now: 0)
		#expect(emittedPlanBlockCalls([a, other, b, a]) == ["call_1", "call_2"])
	}
}
