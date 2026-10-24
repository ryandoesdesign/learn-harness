import Foundation
import Testing
@testable import LHCore

// The pure parts of tests/graph-context.test.ts that fall in chains.ts (the
// route's chainsForSelection → formatChainLine derivation), the
// resolveTargetId pin from tests/tool-heal.test.ts, and chainsForSelection's
// documented inclusion law.

private func node(_ id: String, _ name: String, _ statement: String) -> GraphNode {
	GraphNode(id: id, name: name, statement: statement, aliases: [], createdAt: "2026-10-01T00:00:00.000Z", provenance: [])
}

private func chain(_ id: String, _ premises: [String], _ conclusion: String) -> GraphChain {
	GraphChain(id: id, premises: premises, conclusion: conclusion, provenance: [], createdAt: "2026-10-01T00:00:00.000Z")
}

@Suite("chains — selection views")
struct GraphChainsTests {
	/// graph-context route: the chain AMONG the picks rides the marker as a
	/// formatChainLine (names, not ids).
	@Test func graphContextChainLinesDeriveFromTheLiveGraph() {
		let nodes = [node("n_a", "Modus ponens", "If P implies Q and P holds, Q holds."), node("n_b", "Soundness", "A valid argument from true premises has a true conclusion.")]
		let names = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.name) })
		let lines = chainsForSelection(nodes.map(\.id), [chain("arg_1", ["n_a"], "n_b")]).map { formatChainLine($0, names: names) }
		#expect(lines == ["Modus ponens → Soundness"])
		let marker = newGraphContextMessage(picks: nodes.map { GraphContextPick(id: $0.id, name: $0.name, statement: $0.statement) }, chains: lines, id: "m", now: 0)
		#expect(marker.marker?.content.contains("- Modus ponens → Soundness") == true)
	}

	@Test func aChainRidesOnlyWhenEveryMemberIsSelectedOthersAreSingletons() {
		let chains = [chain("arg_2", ["b", "a"], "c"), chain("arg_1", ["a"], "d"), chain("arg_3", ["a", "z"], "c")]
		let out = chainsForSelection(["c", "a", "b", "e"], chains)
		#expect(out == [
			ReasoningChain(id: "arg_2", premises: ["a", "b"], conclusion: "c"),
			ReasoningChain(id: "e", premises: [], conclusion: "e"),
		])
	}

	@Test func formatChainLineSingletonsAndUnknownIds() {
		#expect(formatChainLine(premises: [], conclusion: "x", names: ["x": "X"]) == "X (no premises)")
		#expect(formatChainLine(premises: ["q", "p"], conclusion: "ghost", names: ["p": "P"]) == "P, q → ghost")
	}

	@Test func resolveTargetIdHealsCopySyntaxOnTargets() {
		let nodes = [(id: "experience-first", name: "Experience first")]
		#expect(resolveTargetId(":experience-first", nodes) == "experience-first")
		#expect(resolveTargetId("\"Experience first\"", nodes) == "experience-first")
		#expect(resolveTargetId("nope", nodes) == nil)
		#expect(resolveTargetId(" `:. ", nodes) == nil, "all-debris is empty → nil")
	}
}
