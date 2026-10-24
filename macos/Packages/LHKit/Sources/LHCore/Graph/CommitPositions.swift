import Foundation

// Port of src/server/commit-positions.ts: the graph window's settled drag.

let MAX_COORD = 1e6

/// Keep known ids with finite coordinates (clamped to ±1e6), write them,
/// and re-settle when the view has ids the client didn't send. Returns
/// what was written (empty = nothing).
@discardableResult
public func commitPositions(_ input: [String: Position], store: any PositionsLedgerStore) throws -> [String: Position] {
	let known = Set(deriveView(getGraph(store)).nodes.map(\.id))
	var positions: [String: Position] = [:]
	for (id, p) in input where known.contains(id) && p.x.isFinite && p.y.isFinite {
		positions[id] = Position(x: min(max(p.x, -MAX_COORD), MAX_COORD), y: min(max(p.y, -MAX_COORD), MAX_COORD))
	}
	if positions.isEmpty { return [:] }
	try store.writePositions(positions)
	if !known.isSubset(of: positions.keys) { try settleGraphLayout(store) }
	return positions
}
