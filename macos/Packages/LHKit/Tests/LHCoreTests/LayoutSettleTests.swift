import Foundation
import Testing
@testable import LHCore

private final class SettleStore: PositionsLedgerStore {
	let inner: MemoryGraphStore
	var written: [[String: Position]] = []
	init(_ inner: MemoryGraphStore) { self.inner = inner }
	func appendNode(_ node: GraphNode) throws { try inner.appendNode(node) }
	func readNodes() -> [GraphNode] { inner.readNodes() }
	func appendChain(_ assertion: GraphChain) throws { try inner.appendChain(assertion) }
	func readChains() -> [GraphChain] { inner.readChains() }
	func appendCheckpoint(_ checkpoint: SessionCheckpoint) throws { try inner.appendCheckpoint(checkpoint) }
	func appendCoverage(_ entry: CoverageEntry) throws { try inner.appendCoverage(entry) }
	func readSources() -> [NotesSource] { inner.readSources() }
	func readPositions() -> [String: Position] { inner.readPositions() }
	func rewriteLedgers(_ next: GraphLedgerRewrite) throws { try inner.rewriteLedgers(next) }
	func writePositions(_ positions: [String: Position]) throws { written.append(positions) }
}

private func node(_ id: String) -> GraphNode {
	GraphNode(id: id, name: id, statement: id, aliases: [], createdAt: "2026-09-13T00:00:00.000Z", provenance: [])
}

private func chain(_ id: String, _ premises: [String], _ conclusion: String) -> GraphChain {
	GraphChain(id: id, premises: premises, conclusion: conclusion, provenance: [], createdAt: "2026-09-13T00:00:00.000Z")
}

@Suite struct LayoutSettleTests {
	@Test func dedupesRepeatedNodeLinesRunsAndWritesTheWholeLedger() throws {
		let store = SettleStore(MemoryGraphStore(
			nodes: ["a", "b", "c", "d", "a"].map(node),
			chains: [chain("arg_ab", ["a"], "b"), chain("arg_bcd", ["b", "c"], "d")]))
		try settleGraphLayout(store)
		#expect(store.written.count == 1)
		// Single-premise arg_ab collapses to a direct arrow; multi-premise arg_bcd's imp node joins.
		#expect(store.written[0].keys.sorted() == ["a", "arg_bcd", "b", "c", "d"])
	}

	@Test func doesNothingOnAnEmptyGraph() throws {
		let store = SettleStore(MemoryGraphStore())
		try settleGraphLayout(store)
		#expect(store.written.isEmpty)
	}

	@Test func goldenSettleMatchesTS() throws {
		let golden = try Golden.load("layout.settle")
		let store = SettleStore(try GoldenGraph.deps().1)
		try settleGraphLayout(store)
		let actual = JSONValue.object(JSONObject(pairs: store.written[0].map { ($0.key, ["x": .number($0.value.x), "y": .number($0.value.y)]) }))
		expectJSONEqual(actual, golden, tolerance: 1e-9)
	}
}
