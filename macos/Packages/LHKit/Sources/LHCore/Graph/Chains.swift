import Foundation

// Port of src/core/chains.ts — the selection-facing chain views (the chain
// table, the graph-context marker) and practice-target resolution.

/// One reasoning chain — a selection-facing VIEW of stored chains: premises →
/// one conclusion. Singleton chains (`premises: []`) carry chain-less nodes.
public struct ReasoningChain: Sendable, Hashable, Codable {
	/// The stored chain's own id (arg_…), or the node id for a singleton.
	public var id: String
	/// Premise node ids, sorted. Empty = a singleton chain.
	public var premises: [String]
	public var conclusion: String
	public init(id: String, premises: [String], conclusion: String) {
		self.id = id
		self.premises = premises
		self.conclusion = conclusion
	}
}

/// The stored chains filtered to a selection: a chain rides along iff its
/// conclusion AND every premise are selected; a node in no surviving chain is
/// a singleton. Every stored chain keeps its own id. Deterministic: sorted by
/// id, premises sorted.
public func chainsForSelection(_ nodeIds: [String], _ chains: [GraphChain]) -> [ReasoningChain] {
	let selected = Set(nodeIds)
	var chained = Set<String>()
	var included: [ReasoningChain] = []
	for chain in chains {
		if !selected.contains(chain.conclusion) { continue }
		if !chain.premises.allSatisfy(selected.contains) { continue }
		included.append(ReasoningChain(id: chain.id, premises: GraphJS.sorted(chain.premises), conclusion: chain.conclusion))
		chained.insert(chain.conclusion)
		for premise in chain.premises { chained.insert(premise) }
	}
	for id in nodeIds where !chained.contains(id) {
		included.append(ReasoningChain(id: id, premises: [], conclusion: id))
	}
	return GraphJS.stableSorted(included) { a, b in
		GraphJS.less(a.id, b.id) ? -1 : GraphJS.less(b.id, a.id) ? 1 : 0
	}
}

/// Resolve ONE target string to a proposition id: exact id first, then name
/// (case-insensitive, debris-stripped; an ambiguous name resolves to the
/// FIRST node in store order). nil when nothing matches. The copy-syntax
/// debris strip (`:id`, quoted ids) runs before matching.
public func resolveTargetId(_ target: String, _ nodes: [(id: String, name: String)]) -> String? {
	let t = stripTargetDebris(target)
	if t.isEmpty { return nil }
	if nodes.contains(where: { $0.id == t }) { return t }
	let lower = t.lowercased()
	for n in nodes where stripTargetDebris(n.name).lowercased() == lower { return n.id }
	return nil
}

public func resolveTargetId(_ target: String, _ nodes: [GraphNode]) -> String? {
	resolveTargetId(target, nodes.map { (id: $0.id, name: $0.name) })
}

/// value-debris.ts `stripModelValueDebris`: surrounding runs of JS
/// whitespace, colons, periods, quotes and backticks. Private copy so this
/// module does not depend on the value-debris port's file.
private func stripTargetDebris(_ value: String) -> String {
	value.trimmingCharacters(in: targetDebris)
}

private let targetDebris: CharacterSet = CharacterSet.jsWhitespace.union(CharacterSet(charactersIn: ":.\"'`"))

/// A chain as one world-facing line — the propositions' NAMES joined by the
/// derivation arrow ("P1, P2 → C"); a singleton reads "C (no premises)".
/// Unknown ids fall back to the raw id. Premises sort by id.
public func formatChainLine(premises: [String], conclusion: String, names: [String: String]) -> String {
	func nameOf(_ id: String) -> String { names[id] ?? id }
	let premiseText = GraphJS.sorted(premises).map(nameOf).joined(separator: ", ")
	return premiseText != ""
		? "\(premiseText) → \(nameOf(conclusion))"
		: "\(nameOf(conclusion)) (no premises)"
}

public func formatChainLine(_ chain: ReasoningChain, names: [String: String]) -> String {
	formatChainLine(premises: chain.premises, conclusion: chain.conclusion, names: names)
}
