import Foundation

// Port of src/core/graph-deletion.ts (docs/native-macos-m7.md): a session's
// graph traces, and one node (or one argument). Fix (your answer): a session
// delete only kills nodes that session contributed to — a line with no
// provenance counts as an unknown other source, so legacy nodes survive.

/// A graph store whose coverage, checkpoints and positions can be read and replaced.
public protocol GraphTraceStore: PositionsLedgerStore {
	func readCoverage() -> [CoverageEntry]
	func readCheckpoints() -> [SessionCheckpoint]
}

public enum ChatDeleteMode: String, Sendable, Hashable {
	/// Drop only the chat's coverage and checkpoint rows; the graph keeps everything.
	case preserveGraph = "preserve-graph"
	/// Also strip the chat's provenance; nodes and chains only it held die.
	case deleteNodes = "delete-nodes"
}

public struct ChatDeletionStats: Sendable, Hashable {
	public var nodesRemoved = 0
	public var chainsRemoved = 0
	public var coverageRemoved = 0
	public var checkpointsRemoved = 0
}

/// graph-deletion.ts deleteChatTraces.
@discardableResult
public func deleteChatTraces(_ store: any GraphTraceStore, chatId: String, mode: ChatDeleteMode) throws -> ChatDeletionStats {
	let allCoverage = store.readCoverage(), allCheckpoints = store.readCheckpoints()
	let coverage = allCoverage.filter { $0.chatId != chatId }
	let checkpoints = allCheckpoints.filter { $0.chatId != chatId }
	var stats = ChatDeletionStats(coverageRemoved: allCoverage.count - coverage.count, checkpointsRemoved: allCheckpoints.count - checkpoints.count)
	let bookkeepingOnly = stats.coverageRemoved > 0 || stats.checkpointsRemoved > 0

	let nodeLines = store.readNodes(), chainLines = store.readChains()
	let touched = nodeLines.contains { $0.provenance.contains { $0.chatId == chatId } }
		|| chainLines.contains { $0.provenance.contains { $0.chatId == chatId } }
	guard mode == .deleteNodes, touched else {
		if bookkeepingOnly { try store.rewriteLedgers(GraphLedgerRewrite(coverage: coverage, checkpoints: checkpoints)) }
		return stats
	}

	// A node dies only if this chat touched it and nothing else holds it: no
	// point from another source, and no provenance-less (legacy) line.
	var touchedIds = Set<String>(), heldElsewhere = Set<String>()
	for line in nodeLines {
		if line.provenance.contains(where: { $0.chatId == chatId }) { touchedIds.insert(line.id) }
		if line.provenance.isEmpty || line.provenance.contains(where: { $0.chatId != chatId }) { heldElsewhere.insert(line.id) }
	}
	let dead = touchedIds.subtracting(heldElsewhere)

	var outNodes: [GraphNode] = []
	var seen = Set<String>()
	for line in nodeLines where !dead.contains(line.id) {
		let first = seen.insert(line.id).inserted
		let points = line.provenance.filter { $0.chatId != chatId }
		if points.count == line.provenance.count {
			outNodes.append(line)
		} else if !points.isEmpty {
			var l = line
			l.provenance = points
			outNodes.append(l)
		} else if first {
			// The chat's create line of a surviving node keeps its identity.
			var l = line
			l.provenance = []
			l.aliases = []
			outNodes.append(l)
		}
	}

	var outChains: [GraphChain] = []
	var deadChainIds = Set<String>()
	for line in chainLines {
		if dead.contains(line.conclusion) || line.premises.contains(where: dead.contains) { deadChainIds.insert(line.id); continue }
		let points = line.provenance.filter { $0.chatId != chatId }
		if !line.provenance.isEmpty, points.isEmpty { deadChainIds.insert(line.id); continue }
		var l = line
		l.provenance = points
		outChains.append(l)
	}
	// A chain id whose every line died is gone; one with a surviving line stays.
	deadChainIds.subtract(outChains.map(\.id))

	stats.nodesRemoved = dead.count
	stats.chainsRemoved = chainLines.count - outChains.count
	try store.rewriteLedgers(GraphLedgerRewrite(nodes: outNodes, chains: outChains, coverage: coverage, checkpoints: checkpoints))
	try prunePositions(store) { dead.contains($0) || deadChainIds.contains($0) }
	return stats
}

/// graph-deletion.ts deleteNodeTraces: a proposition dies with every chain
/// through it; an `arg_` id deletes only that argument. nil = unknown id.
@discardableResult
public func deleteNodeTraces(_ store: any GraphTraceStore, nodeId: String) throws -> Int? {
	let chainLines = store.readChains()
	if nodeId.hasPrefix("arg_") {
		let outChains = chainLines.filter { $0.id != nodeId }
		if outChains.count == chainLines.count { return nil }
		try store.rewriteLedgers(GraphLedgerRewrite(chains: outChains))
		try prunePositions(store) { $0 == nodeId }
		return chainLines.count - outChains.count
	}
	let nodeLines = store.readNodes()
	guard nodeLines.contains(where: { $0.id == nodeId }) else { return nil }
	let outChains = chainLines.filter { $0.conclusion != nodeId && !$0.premises.contains(nodeId) }
	let deadChains = Set(chainLines.map(\.id)).subtracting(outChains.map(\.id))
	try store.rewriteLedgers(GraphLedgerRewrite(nodes: nodeLines.filter { $0.id != nodeId }, chains: outChains.count == chainLines.count ? nil : outChains))
	try prunePositions(store) { $0 == nodeId || deadChains.contains($0) }
	return chainLines.count - outChains.count
}

private func prunePositions(_ store: any GraphTraceStore, dead: (String) -> Bool) throws {
	let positions = store.readPositions()
	let kept = positions.filter { !dead($0.key) }
	if kept.count != positions.count { try store.writePositions(kept) }
}
