import Foundation
import Testing
@testable import LHCore

// Port of tests/plan-tree.test.ts — the pure ops and the derived statuses.
// (The plan_init tool-execute and parseMermaidPlan suites belong to the
// agent layer, not LHCore — see the port report.)

private func N(_ id: String, _ title: String? = nil, _ summary: String? = nil) -> PlanNode {
	PlanNode(id: id, title: title ?? id, summary: summary)
}

private func E(_ from: String, _ to: String) -> PlanEdge { PlanEdge(from: from, to: to) }

/// The op throws a PlanTreeError whose message contains `needle`.
private func expectReject(_ needle: String, sourceLocation: SourceLocation = #_sourceLocation, _ fn: () throws(PlanTreeError) -> PlanTree) {
	do {
		_ = try fn()
		Issue.record("expected a PlanTreeError containing \(needle), but the op succeeded", sourceLocation: sourceLocation)
	} catch {
		#expect(error.message.contains(needle), "\(error.message)", sourceLocation: sourceLocation)
	}
}

/// The op throws exactly `message`.
private func expectMessage(_ message: String, sourceLocation: SourceLocation = #_sourceLocation, _ fn: () throws(PlanTreeError) -> PlanTree) {
	do {
		_ = try fn()
		Issue.record("expected a PlanTreeError, but the op succeeded", sourceLocation: sourceLocation)
	} catch {
		#expect(error.message == message, sourceLocation: sourceLocation)
	}
}

@Suite struct SessionPlanTreePureOpsTests {
	@Test func createTreeBuildsVersionOne() throws {
		let nodes = [N("a", "A"), N("b", "B")]
		let edges = [E("a", "b")]
		let t = try createTree(nodes, edges)
		#expect(t.version == 1)
		#expect(t.nodes.map(\.id) == ["a", "b"])
		#expect(t.edges == [E("a", "b")])
		#expect(nodes == [N("a", "A"), N("b", "B")])
		#expect(edges == [E("a", "b")])
	}

	@Test func emptyTreeIsVersionZero() {
		#expect(emptyTree() == PlanTree(nodes: [], edges: [], version: 0))
	}

	@Test func rejectsDuplicateNodeIds() {
		expectReject("Duplicate node id \"a\"") { () throws(PlanTreeError) in try createTree([N("a"), N("a")], []) }
	}

	@Test func rejectsEdgesWithMissingEndpoints() {
		expectReject("unknown node id \"ghost\"") { () throws(PlanTreeError) in try createTree([N("a")], [E("a", "ghost")]) }
		expectReject("unknown node id \"ghost\"") { () throws(PlanTreeError) in try createTree([N("a")], [E("ghost", "a")]) }
	}

	@Test func rejectsSelfLoopsDuplicatesAndCycles() {
		expectReject("self-loop") { () throws(PlanTreeError) in try createTree([N("a")], [E("a", "a")]) }
		expectReject("already exists") { () throws(PlanTreeError) in try createTree([N("a"), N("b")], [E("a", "b"), E("a", "b")]) }
		expectReject("cycle") { () throws(PlanTreeError) in try createTree([N("a"), N("b"), N("c")], [E("a", "b"), E("b", "c"), E("c", "a")]) }
	}

	@Test func rejectsInvalidNodeShapes() {
		expectReject("non-empty `id`") { () throws(PlanTreeError) in try createTree([N("")], []) }
		expectReject("non-empty `title`") { () throws(PlanTreeError) in try createTree([PlanNode(id: "a", title: "")], []) }
	}

	/// The agent-readable wording, byte for byte (it flows back as a tool error).
	@Test func exactAgentReadableMessages() {
		expectMessage("Every node needs a non-empty `id` (a stable slug like 'chain-rule-intuition').") { () throws(PlanTreeError) in try createTree([N("  ")], []) }
		expectMessage("Node \"a\" needs a non-empty `title`.") { () throws(PlanTreeError) in try createTree([PlanNode(id: "a", title: " \n")], []) }
		expectMessage("Duplicate node id \"a\" — node ids must be unique.") { () throws(PlanTreeError) in try createTree([N("a"), N("a")], []) }
		expectMessage("Edge `from` references unknown node id \"ghost\" — it is not in the tree.") { () throws(PlanTreeError) in try createTree([N("a")], [E("ghost", "a")]) }
		expectMessage("Edge `to` references unknown node id \"ghost\" — it is not in the tree.") { () throws(PlanTreeError) in try createTree([N("a")], [E("a", "ghost")]) }
		expectMessage("Edge \"a\" → \"a\" is a self-loop — a node can't require itself.") { () throws(PlanTreeError) in try createTree([N("a")], [E("a", "a")]) }
		expectMessage("Edge \"a\" → \"b\" already exists — duplicate edges are not allowed.") { () throws(PlanTreeError) in try createTree([N("a"), N("b")], [E("a", "b"), E("a", "b")]) }
		expectMessage("Edge \"c\" → \"a\" would create a cycle: \"a\" already leads (directly or transitively) back to \"c\". \"from\" must be understood before \"to\" — the tree is a DAG.") { () throws(PlanTreeError) in
			try createTree([N("a"), N("b"), N("c")], [E("a", "b"), E("b", "c"), E("c", "a")])
		}
		// Missing endpoints are reported before any per-edge check.
		expectMessage("Edge `to` references unknown node id \"ghost\" — it is not in the tree.") { () throws(PlanTreeError) in
			try createTree([N("a")], [E("a", "a"), E("a", "ghost")])
		}
	}
}

// ─── derived statuses: position from CALLS, never results ────────────────

private func quizCall(_ nodeId: String?, answered correct: Bool? = nil, tool name: String = "quiz") -> [Message] {
	let id = "call_\(UUID().uuidString.prefix(8))"
	let input: JSONValue = nodeId.map { ["nodeId": .string($0)] } ?? [:]
	let call = Message(id: "a_\(id)", timestamp: 0, body: .assistant(AssistantBody(content: [.toolUse(id: id, name: name, input: input)], model: "test", stopReason: "tool_use")))
	guard let correct else { return [call] }
	return [call, Message(id: "r_\(id)", timestamp: 0, body: .toolResult(ToolResultBody(toolUseId: id, toolName: name, content: [.text("ok")], isError: false, details: ["correct": .bool(correct)])))]
}

@Suite struct SessionDerivePlanStatusesTests {
	let tree = PlanTree(nodes: [N("a", "A"), N("b", "B"), N("c", "C")], edges: [E("a", "b"), E("b", "c")], version: 1)

	@Test func emptyTranscript() {
		let st = derivePlanStatuses(tree, [])
		#expect(st.current == nil)
		#expect(st.visited.isEmpty)
	}

	@Test func currentIsTheMostRecentTaggedCallRegardlessOfOutcome() {
		let st = derivePlanStatuses(tree, quizCall("b", answered: false))
		#expect(st.current == "b", "even a FAILED check positions the map")
		#expect(st.visited.isEmpty)
		#expect(derivePlanStatuses(tree, quizCall("c")).current == "c", "a merely ASKED question is already the position")
	}

	@Test func visitedIsEarlierTaggedNodesResultsFeedNothing() {
		let st = derivePlanStatuses(tree, quizCall("a", answered: true) + quizCall("b", answered: true))
		#expect(st.current == "b")
		#expect(st.visited == ["a"])
		let again = derivePlanStatuses(tree, quizCall("a", answered: true))
		#expect(again.current == "a")
		#expect(again.visited.isEmpty, "one correct answer on a does not finish it")
	}

	@Test func aTaggedAskMovesTheMapAnUntaggedOneDoesNot() {
		let st = derivePlanStatuses(tree, quizCall("a", answered: true) + quizCall("b", tool: "ask_user_question"))
		#expect(st.current == "b", "an exercise on b is the position")
		#expect(st.visited == ["a"])
		#expect(derivePlanStatuses(tree, quizCall("a") + quizCall(nil, tool: "ask_user_question")).current == "a")
		#expect(derivePlanStatuses(tree, quizCall("c", tool: "probe")).current == nil, "only quiz, explain and ask carry a tag")
	}

	@Test func revisitsKeepBoth() {
		let st = derivePlanStatuses(tree, quizCall("a", answered: true) + quizCall("b", answered: true) + quizCall("a"))
		#expect(st.current == "a")
		#expect(st.visited == ["a", "b"])
	}

	@Test func severalChecksOnOneNodeHoldTheMapStill() {
		let st = derivePlanStatuses(tree, quizCall("a", answered: true) + quizCall("a", answered: false) + quizCall("a"))
		#expect(st.current == "a")
		#expect(st.visited.isEmpty)
	}

	@Test func untaggedAndUnknownNodeIdsMoveNothing() {
		let st = derivePlanStatuses(tree, quizCall(nil, answered: true) + quizCall("ghost", answered: true))
		#expect(st.current == nil)
		#expect(st.visited.isEmpty)
	}

	@Test func aRewrittenMapDerivesAgainstTheCurrentTree() {
		var rewritten = tree
		rewritten.nodes = [tree.nodes[0], tree.nodes[1]]
		let st = derivePlanStatuses(rewritten, quizCall("a", answered: true) + quizCall("c", answered: true))
		#expect(st.current == "a", "the orphaned tag is ignored")
		#expect(st.visited.isEmpty)
	}

	@Test func derivedNodeStatusCurrentWinsOverVisited() {
		let st = derivePlanStatuses(tree, quizCall("a", answered: true))
		#expect(derivedNodeStatus(st, "a") == .current)
		#expect(derivedNodeStatus(st, "b") == .upcoming)
		let later = derivePlanStatuses(tree, quizCall("a", answered: true) + quizCall("b", answered: true))
		#expect(derivedNodeStatus(later, "a") == .visited)
		#expect(derivedNodeStatus(later, "b") == .current)
		#expect(derivedNodeStatus(later, "c") == .upcoming)
	}
}

@Suite struct SessionDerivePlanStatusesExplainTests {
	let tree = PlanTree(nodes: [N("a", "A"), N("b", "B")], edges: [E("a", "b")], version: 1)

	@Test func taggedExplainIsThePosition() {
		let st = derivePlanStatuses(tree, quizCall("a", answered: true, tool: "explain") + quizCall("b", answered: true, tool: "explain"))
		#expect(st.current == "b")
		#expect(st.visited == ["a"])
	}

	@Test func untaggedExplainMovesNothing() {
		let st = derivePlanStatuses(tree, quizCall(nil, answered: true, tool: "explain"))
		#expect(st.current == nil)
		#expect(st.visited.isEmpty)
	}

	@Test func mixedMechanicsDeriveOneRun() {
		let st = derivePlanStatuses(tree, quizCall("a", answered: true) + quizCall("b", answered: true, tool: "explain"))
		#expect(st.current == "b")
		#expect(st.visited == ["a"])
	}
}
