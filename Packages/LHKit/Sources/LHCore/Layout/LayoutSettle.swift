import Foundation

// Port of src/core/layout-settle.ts — the merge-time settle.

/// A graph store that can also replace the positions ledger.
public protocol PositionsLedgerStore: GraphStore {
	func writePositions(_ positions: [String: Position]) throws
}

/// Recompute the resting layout from the current graph + positions ledger
/// and replace the ledger. Lays out the DERIVED view (propositions + the
/// implication nodes of multi-premise chains), with the birth-session
/// partition (imp nodes attached) as the cluster pull — the same partition
/// the snapshot renders, so the ledger and the live sim agree.
public func settleGraphLayout(_ store: any PositionsLedgerStore) throws {
	let graph = getGraph(store)
	if graph.nodes.isEmpty { return }
	let view = deriveView(graph)
	var communities = birthSessionPartition(graph.nodes)
	attachImpToCommunities(&communities, propositions: graph.nodes, chains: graph.chains)
	let next = try incrementalLayout(view.nodes, edges: view.edges, previous: store.readPositions(), options: IncrementalLayoutOptions(
		clusters: communities.map(\.members),
		logicalEdges: view.logicalEdges,
		impLinks: view.impLinks))
	try store.writePositions(next)
}
