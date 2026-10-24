import Foundation

// Port of src/core/session-clusters.ts — BIRTH-SESSION CLUSTERING: a
// proposition's cluster is the session that created it, derived on every read
// from provenance (no persisted partition). A node's birth session is its
// FIRST surviving provenance point's chatId, so deletion re-attributes with
// zero special handling; a node with no provenance is unclustered. Notes
// imports are birth sessions too ("src_…" ids).

/// Anything with an id + a members list — the shape attachImpToCommunities
/// mutates (the snapshot's `Cluster`s and the raw partition alike).
public protocol ClusterMembership {
	var id: String { get }
	var members: [String] { get set }
}

extension Cluster: ClusterMembership {}

/// One birth-session cluster: the session id + the SORTED member node ids.
public struct BirthSessionCluster: Sendable, Hashable, Codable, ClusterMembership {
	/// A chatId or a notes source id ("src_…").
	public var id: String
	/// Node ids born in this session, sorted.
	public var members: [String]
	public init(id: String, members: [String]) {
		self.id = id
		self.members = members
	}
}

/// A node's birth session: its first provenance point's chatId (nil = none).
public func birthSessionOf(_ node: GraphNode) -> String? {
	node.provenance.first?.chatId
}

/// The birth-session partition over node LINES: dedupes by id (first line
/// defines), groups by birth session, size-desc with members sorted; ties
/// break by session id ascending. Provenance-less nodes are left out.
public func birthSessionPartition(_ nodes: [GraphNode]) -> [BirthSessionCluster] {
	var order: [String] = []
	var members: [String: [String]] = [:]
	var seen = Set<String>()
	for node in nodes {
		if seen.contains(node.id) { continue }
		seen.insert(node.id)
		guard let birth = birthSessionOf(node) else { continue }
		if members[birth] == nil { order.append(birth) }
		members[birth, default: []].append(node.id)
	}
	let clusters = order.map { BirthSessionCluster(id: $0, members: GraphJS.sorted(members[$0]!)) }
	return GraphJS.stableSorted(clusters) { a, b in
		let d = b.members.count - a.members.count
		return d != 0 ? d : (GraphJS.less(a.id, b.id) ? -1 : 1)
	}
}

/// The cluster key a derived implication node takes: MAJORITY among its
/// PREMISES' birth sessions; ties to the chain's own birth (its first
/// provenance point), last resort the alphabetically-first winner.
public func impClusterKey(_ chain: GraphChain, birthOf: (String) -> String?) -> String? {
	impClusterKey(premises: chain.premises, provenance: chain.provenance, birthOf: birthOf)
}

func impClusterKey(premises: [String], provenance: [ProvenancePoint], birthOf: (String) -> String?) -> String? {
	var order: [String] = []
	var counts: [String: Int] = [:]
	for premise in premises {
		guard let birth = birthOf(premise) else { continue }
		if counts[birth] == nil { order.append(birth) }
		counts[birth, default: 0] += 1
	}
	let own = provenance.first?.chatId
	if counts.isEmpty { return own }
	let max = counts.values.max() ?? 0
	let winners = order.filter { counts[$0] == max }
	if winners.count == 1 { return winners[0] }
	return own ?? GraphJS.sorted(winners)[0]
}

/// Attach derived imp nodes to communities IN PLACE: only MULTI-premise,
/// fully-live chains mint imp nodes; a chain whose home community is absent
/// from the list stays unclustered. Members re-sort afterwards.
public func attachImpToCommunities<C: ClusterMembership>(_ communities: inout [C], propositions: [GraphNode], chains: [GraphChain]) {
	var birthById: [String: String?] = [:]
	for node in propositions { birthById[node.id] = birthSessionOf(node) }
	let live = Set(propositions.map(\.id))
	for chain in chains {
		if chain.premises.count < 2 { continue }
		if !live.contains(chain.conclusion) || !chain.premises.allSatisfy(live.contains) { continue }
		let key = impClusterKey(chain) { id in birthById[id] ?? nil }
		guard let key, let index = communities.firstIndex(where: { $0.id == key }) else { continue }
		communities[index].members.append(chain.id)
	}
	for i in communities.indices { communities[i].members = GraphJS.sorted(communities[i].members) }
}
