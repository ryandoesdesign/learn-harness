import Foundation

// The model half of components/chain-table.tsx (docs/native-macos-m7.md):
// chains grouped by their conclusion's birth session, searched (fuzzy over
// name, statement and aliases), and sorted by Name, Props or Created.

public enum ChainSortColumn: String, Sendable, Hashable { case name, props, created }

public struct ChainSort: Sendable, Hashable {
	public var column: ChainSortColumn
	/// 1 ascending, -1 descending.
	public var direction: Int
	public init(column: ChainSortColumn, direction: Int) {
		self.column = column
		self.direction = direction
	}
	public static let initial = ChainSort(column: .name, direction: 1)

	/// Clicking a header: the active one flips; a new one starts name ↑, props/created ↓.
	public func clicked(_ col: ChainSortColumn) -> ChainSort {
		col == column ? ChainSort(column: col, direction: -direction) : ChainSort(column: col, direction: col == .name ? 1 : -1)
	}
}

public struct ChainGroup: Sendable, Hashable, Identifiable {
	public enum Kind: Sendable, Hashable { case chat, notes }
	/// The birth session id, or "\0unlabeled".
	public var id: String
	public var birth: String?
	public var label: String?
	public var kind: Kind?
	public var chains: [ReasoningChain]
	/// Distinct member ids, in first-seen order.
	public var nodeIds: [String]
	public var newestCreatedAt: String
}

/// Every chain (stored ones plus chain-less propositions as singletons).
public func allChains(_ nodes: [GraphNode], _ chains: [GraphChain]) -> [ReasoningChain] {
	chainsForSelection(nodes.map(\.id), chains)
}

public func chainTableGroups(nodes: [GraphNode], chains stored: [GraphChain], sessions: [String: String], fileSources: [String: String],
	query: String, sort: ChainSort) -> [ChainGroup]
{
	let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
	let chains = allChains(nodes, stored)
	var visible = chains
	if !query.jsTrimmed.isEmpty {
		let scored: [(ReasoningChain, Int)] = chains.compactMap { chain in
			var best: Int?
			for id in chain.premises + [chain.conclusion] {
				guard let n = byId[id], let s = fuzzyScore(query, fields: [n.name, n.statement] + n.aliases) else { continue }
				if best == nil || s > best! { best = s }
			}
			return best.map { (chain, $0) }
		}
		visible = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : GraphJS.less($0.0.id, $1.0.id) }.map(\.0)
	}

	var groups: [String: ChainGroup] = [:]
	var order: [String] = []
	for chain in visible {
		let birth = byId[chain.conclusion]?.provenance.first?.chatId
		let key = birth ?? "\u{0}unlabeled"
		if groups[key] == nil {
			let label = birth.flatMap { sessions[$0] ?? fileSources[$0] }
			let kind: ChainGroup.Kind? = birth.flatMap { sessions[$0] != nil ? .chat : fileSources[$0] != nil ? .notes : nil }
			groups[key] = ChainGroup(id: key, birth: birth, label: label, kind: kind, chains: [], nodeIds: [], newestCreatedAt: "")
			order.append(key)
		}
		groups[key]!.chains.append(chain)
		for id in chain.premises + [chain.conclusion] {
			if !groups[key]!.nodeIds.contains(id) { groups[key]!.nodeIds.append(id) }
			let created = byId[id]?.createdAt ?? ""
			if GraphJS.less(groups[key]!.newestCreatedAt, created) { groups[key]!.newestCreatedAt = created }
		}
	}

	// Intl.Collator(sensitivity: base, numeric) ≈ localizedStandardCompare.
	func collate(_ a: String, _ b: String) -> Int {
		switch a.localizedStandardCompare(b) { case .orderedAscending: -1; case .orderedDescending: 1; case .orderedSame: 0 }
	}
	let dir = sort.direction
	func groupCmp(_ a: ChainGroup, _ b: ChainGroup) -> Int {
		let name = collate(a.label ?? "\u{FFFF}", b.label ?? "\u{FFFF}") * (sort.column == .name ? dir : 1)
		switch sort.column {
		case .name: return name
		case .props:
			let p = dir == -1 ? b.nodeIds.count - a.nodeIds.count : a.nodeIds.count - b.nodeIds.count
			return p != 0 ? p : name
		case .created:
			let c = dir == -1 ? GraphJS.localeCompare(b.newestCreatedAt, a.newestCreatedAt) : GraphJS.localeCompare(a.newestCreatedAt, b.newestCreatedAt)
			return c != 0 ? c : name
		}
	}
	func chainCmp(_ a: ReasoningChain, _ b: ReasoningChain) -> Int {
		let an = byId[a.conclusion]?.name ?? a.conclusion, bn = byId[b.conclusion]?.name ?? b.conclusion
		let name = collate(an, bn) * (sort.column == .name ? dir : 1)
		switch sort.column {
		case .name: return name
		case .props:
			let p = dir == -1 ? (b.premises.count + 1) - (a.premises.count + 1) : (a.premises.count + 1) - (b.premises.count + 1)
			return p != 0 ? p : name
		case .created:
			let ad = byId[a.conclusion]?.createdAt ?? "", bd = byId[b.conclusion]?.createdAt ?? ""
			let c = dir == -1 ? GraphJS.localeCompare(bd, ad) : GraphJS.localeCompare(ad, bd)
			return c != 0 ? c : name
		}
	}
	var list = GraphJS.stableSorted(order.compactMap { groups[$0] }, by: groupCmp)
	for i in list.indices { list[i].chains = GraphJS.stableSorted(list[i].chains, by: chainCmp) }
	return list
}
