import Foundation

// Port of src/core/graph.ts — the knowledge graph's merger (the deterministic
// final stage of the extraction pipeline) + derivation (reads).
//
// The extractor (LLM) supplies the propositions + chains, the auditor (LLM)
// the identity links; the merger HERE is pure code and the ONLY stage that
// touches the ledgers — timestamps and provenance are rebuilt
// deterministically. Derivation (getGraph / graphSnapshot) is reads only:
// everything is recomputed from the ledgers. Every function takes the
// storage ports explicitly.

/// "n_" + 12 hex chars.
private func newGraphNodeId(_ random: GraphRandom) -> String {
	"n_" + GraphJS.hex(random.bytes(6))
}

/// "arg_" + 12 hex chars — the implication-node namespace (a chain's id IS
/// its derived node's id).
private func newGraphChainId(_ random: GraphRandom) -> String {
	"arg_" + GraphJS.hex(random.bytes(6))
}

/// A chain's merge key: sorted premises + conclusion.
func graphChainKey(_ premises: [String], _ conclusion: String) -> String {
	GraphJS.sorted(premises).joined(separator: "+") + ">" + conclusion
}

/// What one merge run merges FROM: the chat path passes the extracted
/// batch's coverage entries (appended on success); the notes path passes
/// none and gets the whole-file checkpoint instead.
public struct MergeSource: Sendable, Hashable {
	public var foldedAt: String
	/// One entry per message in the extracted batch; nil → checkpoint.
	public var coverage: [CoverageEntry]?
	public init(foldedAt: String, coverage: [CoverageEntry]? = nil) {
		self.foldedAt = foldedAt
		self.coverage = coverage
	}
}

/// The run's provenance point: chat-level ("") unless a session birth carries
/// its passage's message id.
private func pointOf(_ chatId: String, _ messageId: String? = nil) -> [ProvenancePoint] {
	[ProvenancePoint(chatId: chatId, messageId: messageId ?? "")]
}

// MARK: - The merger

/// Merge one job's audited findings into the graph ledgers. Each job merges
/// INDEPENDENTLY: resolution is a job-local map from this submit's
/// proposition ids to graph node ids. A `linkTo` verdict naming an existing
/// node appends a LINK line (phrasings join aliases, provenance unions at
/// read time); anything else creates a node. Chains resolve through the
/// local map or pass through verbatim when they name an existing node, and
/// dedupe by (premises, conclusion) already asserted by THIS chat. Then the
/// simplification pass, then the checkpoint (coverage or whole-file).
///
/// `now` / `random` are injectable (TS: `new Date()` / `randomBytes`).
@discardableResult
public func mergeFindings(
	chatId: String,
	findings: SessionFindings,
	verdicts: AuditVerdicts,
	deps: GraphDeps,
	source: MergeSource,
	now: Date = Date(),
	random: GraphRandom = .system
) throws -> EmissionStats {
	let ledgers = deps.graphStore
	var stats = EmissionStats(nodes: 0, chains: 0)

	// 1. Resolution: this job's propositions → graph node ids.
	var existingIds = Set(ledgers.readNodes().map(\.id))
	var mapping: [String: String] = [:]
	let nowISO = GraphJS.isoString(now)
	var linkOf: [String: IdentityLink] = [:]
	for link in verdicts.links { linkOf[link.id] = link }

	for p in findings.propositions {
		if mapping[p.id] != nil { continue } // duplicate id within this submit — first resolution stands
		let points = pointOf(chatId, p.messageId)
		let graphNodeId: String
		if let link = linkOf[p.id], existingIds.contains(link.linkTo) {
			// Identity verdict: append a link line (the node's name/statement stand at read time unless it revises).
			graphNodeId = link.linkTo
			try ledgers.appendNode(GraphNode(id: graphNodeId, name: p.name, statement: p.statement, aliases: p.aliases, createdAt: nowISO, provenance: points,
				revises: link.rewrite ? true : nil))
		} else {
			let node = GraphNode(id: newGraphNodeId(random), name: p.name, statement: p.statement, aliases: p.aliases, createdAt: nowISO, provenance: points)
			try ledgers.appendNode(node)
			stats.nodes += 1
			graphNodeId = node.id
			existingIds.insert(graphNodeId)
		}
		mapping[p.id] = graphNodeId
	}

	// 2. Chains — the extractor's alone.
	var assertedByChat = Set<String>()
	var idOfKey: [String: String] = [:]
	for line in ledgers.readChains() {
		let key = graphChainKey(line.premises, line.conclusion)
		if idOfKey[key] == nil { idOfKey[key] = line.id }
		if line.provenance.contains(where: { $0.chatId == chatId }) { assertedByChat.insert(key) }
	}
	func resolve(_ endpoint: String) -> String? {
		mapping[endpoint] ?? (existingIds.contains(endpoint) ? endpoint : nil)
	}
	for chain in findings.chains {
		guard let conclusion = resolve(chain.conclusion) else { continue } // unresolvable endpoint
		// `[...new Set(premises.map(resolve))]`: first-occurrence dedupe, then
		// drop the unresolved and any premise equal to the conclusion.
		var seen = Set<String?>()
		var premises: [String] = []
		for resolved in chain.premises.map(resolve) where seen.insert(resolved).inserted {
			if let resolved, resolved != conclusion { premises.append(resolved) }
		}
		if premises.isEmpty { continue } // a chain IS an argument
		let key = graphChainKey(premises, conclusion)
		if assertedByChat.contains(key) { continue } // this chat already asserted it
		let id = idOfKey[key] ?? newGraphChainId(random)
		try ledgers.appendChain(GraphChain(id: id, premises: premises, conclusion: conclusion, provenance: pointOf(chatId), createdAt: nowISO))
		idOfKey[key] = id
		assertedByChat.insert(key)
		stats.chains! += 1
	}

	// 2b. Simplification over the WHOLE chain ledger (stats count appends only).
	let allChains = ledgers.readChains()
	let keptChains = simplifyChains(allChains)
	if keptChains.count != allChains.count {
		try ledgers.rewriteLedgers(GraphLedgerRewrite(chains: keptChains))
		stats.droppedChains = allChains.count - keptChains.count
	}

	// 3. Checkpoint — only after every append succeeded is the batch covered.
	if let coverage = source.coverage {
		for entry in coverage { try ledgers.appendCoverage(entry) }
	} else {
		try ledgers.appendCheckpoint(SessionCheckpoint(chatId: chatId, foldedAt: source.foldedAt))
	}
	return stats
}

/// The deterministic chain-simplification pass: per conclusion, greedy in
/// (premiseCount, createdAt, key) order, a chain is redundant when
/// • prefer-fewest-premises: its premise set contains a kept chain's, or
/// • ancestry-cover: every premise is a kept premise or derivable behind one
///   (transitively, through the FULL pre-simplification chain set).
/// Same-key lines are one logical chain — kept or dropped whole.
public func simplifyChains(_ lines: [GraphChain]) -> [GraphChain] {
	if lines.count < 2 { return lines }

	// Group lines by chain key (insertion-ordered).
	var groupOrder: [String] = []
	var groups: [String: [GraphChain]] = [:]
	for line in lines {
		let key = graphChainKey(line.premises, line.conclusion)
		if groups[key] == nil { groupOrder.append(key) }
		groups[key, default: []].append(line)
	}

	// Ancestry over the full chain set — memoized, cycle-guarded.
	var premisesOf: [String: [[String]]] = [:]
	for line in lines { premisesOf[line.conclusion, default: []].append(line.premises) }
	var ancestryMemo: [String: Set<String>] = [:]
	func ancestry(_ id: String, _ visiting: inout Set<String>) -> Set<String> {
		if let memo = ancestryMemo[id] { return memo }
		var out = Set<String>()
		if visiting.contains(id) { return out }
		visiting.insert(id)
		for premises in premisesOf[id] ?? [] {
			for premise in premises {
				out.insert(premise)
				out.formUnion(ancestry(premise, &visiting))
			}
		}
		visiting.remove(id)
		ancestryMemo[id] = out
		return out
	}

	struct Candidate {
		var key: String
		var premises: [String]
		var createdAt: String
	}
	var conclusionOrder: [String] = []
	var byConclusion: [String: [Candidate]] = [:]
	for key in groupOrder {
		let head = groups[key]![0] // the representative — its premises stand
		if byConclusion[head.conclusion] == nil { conclusionOrder.append(head.conclusion) }
		byConclusion[head.conclusion, default: []].append(Candidate(key: key, premises: head.premises, createdAt: head.createdAt))
	}
	var droppedKeys = Set<String>()
	for conclusion in conclusionOrder {
		let candidates = GraphJS.stableSorted(byConclusion[conclusion]!) { a, b in
			let d = a.premises.count - b.premises.count
			if d != 0 { return d }
			let c = GraphJS.localeCompare(a.createdAt, b.createdAt)
			if c != 0 { return c }
			return GraphJS.localeCompare(a.key, b.key)
		}
		var kept: [Candidate] = []
		for candidate in candidates {
			let candidateSet = Set(candidate.premises)
			let redundant = kept.contains { k in
				// Rule 1 — prefer-fewest-premises.
				if k.premises.allSatisfy(candidateSet.contains) { return true }
				// Rule 2 — ancestry-cover.
				var covered = Set(k.premises)
				for p in k.premises {
					var visiting = Set<String>()
					covered.formUnion(ancestry(p, &visiting))
				}
				return candidate.premises.allSatisfy(covered.contains)
			}
			if redundant { droppedKeys.insert(candidate.key) } else { kept.append(candidate) }
		}
	}
	if droppedKeys.isEmpty { return lines }
	return lines.filter { !droppedKeys.contains(graphChainKey($0.premises, $0.conclusion)) }
}

// MARK: - Derivation

/// The merged STORED truth: propositions + chains (no derived imp nodes).
public struct DerivedGraph: Sendable, Hashable {
	public var nodes: [GraphNode]
	public var chains: [GraphChain]
	public init(nodes: [GraphNode], chains: [GraphChain]) {
		self.nodes = nodes
		self.chains = chains
	}
}

/// The whole graph from the ledgers. Node lines merge by id: the FIRST line
/// defines name/statement/createdAt; later lines' statements and aliases join
/// `aliases`, provenance unions. A revising line instead replaces the name and
/// statement, the previous statement joining `aliases`; the last revision wins. Chain lines merge by (premises, conclusion):
/// the first line's id/premises/createdAt stand, provenance unions.
public func getGraph(_ graphStore: any GraphStore) -> DerivedGraph {
	var nodes: [GraphNode] = []
	var indexById: [String: Int] = [:]
	for line in graphStore.readNodes() {
		guard let i = indexById[line.id] else {
			indexById[line.id] = nodes.count
			nodes.append(line)
			continue
		}
		// A later line's statement is a phrasing, not a replacement — unless it revises.
		var phrasings = [line.statement] + line.aliases
		if line.revises == true {
			phrasings = [nodes[i].statement] + line.aliases.filter { $0 != line.statement }
			nodes[i].name = line.name
			nodes[i].statement = line.statement
			nodes[i].aliases.removeAll { $0 == line.statement }
		}
		for phrasing in phrasings where !phrasing.isEmpty && !nodes[i].aliases.contains(phrasing) {
			nodes[i].aliases.append(phrasing)
		}
		for pt in line.provenance where !nodes[i].provenance.contains(pt) {
			nodes[i].provenance.append(pt)
		}
	}

	var chains: [GraphChain] = []
	var indexByKey: [String: Int] = [:]
	for line in graphStore.readChains() {
		let key = graphChainKey(line.premises, line.conclusion)
		if let i = indexByKey[key] {
			for pt in line.provenance where !chains[i].provenance.contains(pt) {
				chains[i].provenance.append(pt)
			}
		} else {
			indexByKey[key] = chains.count
			chains.append(line)
		}
	}
	return DerivedGraph(nodes: nodes, chains: chains)
}

/// The canvas-facing derived view.
public struct DerivedView: Sendable, Hashable {
	/// Propositions + derived implication nodes.
	public var nodes: [GraphNode]
	public var edges: [GraphEdge]
	/// Every live chain contracted to premise → conclusion (deduped).
	public var logicalEdges: [GraphEdge]
	public var impLinks: [ImpLink]
}

/// The DERIVED view — what the canvas renders. A single-premise chain
/// collapses to ONE direct arrow; a multi-premise chain mints an implication
/// NODE (id = the chain's arg_ id, name "⟹", statement = the chain line)
/// plus arrows premise → imp → conclusion. Dangling chains drop.
public func deriveView(_ graph: DerivedGraph) -> DerivedView {
	var names: [String: String] = [:]
	for node in graph.nodes { names[node.id] = node.name }
	let live = Set(graph.nodes.map(\.id))
	var impNodes: [GraphNode] = []
	var edges: [GraphEdge] = []
	var impLinks: [ImpLink] = []
	var logicalEdges: [GraphEdge] = []
	var logicalSeen = Set<GraphEdge>()
	for chain in graph.chains {
		if !live.contains(chain.conclusion) || !chain.premises.allSatisfy(live.contains) { continue }
		for premise in chain.premises {
			let edge = GraphEdge(from: premise, to: chain.conclusion)
			if logicalSeen.insert(edge).inserted { logicalEdges.append(edge) }
		}
		if chain.premises.count == 1 {
			edges.append(GraphEdge(from: chain.premises[0], to: chain.conclusion))
			continue
		}
		impNodes.append(GraphNode(
			id: chain.id,
			name: "⟹",
			statement: formatChainLine(premises: chain.premises, conclusion: chain.conclusion, names: names),
			aliases: [],
			createdAt: chain.createdAt,
			provenance: chain.provenance))
		impLinks.append(ImpLink(id: chain.id, premises: chain.premises, conclusion: chain.conclusion))
		for premise in chain.premises { edges.append(GraphEdge(from: premise, to: chain.id)) }
		edges.append(GraphEdge(from: chain.id, to: chain.conclusion))
	}
	return DerivedView(nodes: graph.nodes + impNodes, edges: edges, logicalEdges: logicalEdges, impLinks: impLinks)
}

// MARK: - The snapshot

/// Everything the home graph view needs, in one read. Clusters are BIRTH
/// SESSIONS labeled with the session's name (chat title / file path), kept
/// at ≥ MIN_CLUSTER_SIZE propositions; imp nodes attach after the hull
/// filter. A birth session whose record is gone renders unlabeled.
public func graphSnapshot(_ deps: GraphDeps) -> GraphSnapshot {
	let graph = getGraph(deps.graphStore)
	let view = deriveView(graph)
	let nodes = view.nodes

	// nodeId → touching source ids, both levels insertion-ordered.
	var nodeOrder: [String] = []
	var nodeChats: [String: [String]] = [:]
	for node in nodes {
		for pt in node.provenance {
			if nodeChats[node.id] == nil {
				nodeOrder.append(node.id)
				nodeChats[node.id] = []
			}
			if !nodeChats[node.id]!.contains(pt.chatId) { nodeChats[node.id]!.append(pt.chatId) }
		}
	}
	var sourceIds: [String] = []
	var seenSources = Set<String>()
	for id in nodeOrder {
		for chatId in nodeChats[id]! where seenSources.insert(chatId).inserted { sourceIds.append(chatId) }
	}
	var sessions: [String: String] = [:]
	var fileSources: [String: String] = [:]
	for id in sourceIds {
		if let chat = deps.chatStore.getChat(id) {
			sessions[id] = chat.title
			continue
		}
		if let source = deps.graphStore.readSources().first(where: { $0.id == id }) {
			fileSources[id] = source.filePath
		}
	}

	var nodeSessions: [String: [String]] = [:]
	for nodeId in nodeOrder {
		let ids = nodeChats[nodeId]!.filter { sessions[$0] != nil || fileSources[$0] != nil }
		if !ids.isEmpty { nodeSessions[nodeId] = ids }
	}

	// Birth-session clusters over PROPOSITIONS only.
	var clusters = birthSessionPartition(graph.nodes)
		.filter { $0.members.count >= MIN_CLUSTER_SIZE }
		.map { Cluster(id: $0.id, label: sessions[$0.id] ?? fileSources[$0.id], members: $0.members) }
	attachImpToCommunities(&clusters, propositions: graph.nodes, chains: graph.chains)

	let positions = deps.graphStore.readPositions()
	return GraphSnapshot(
		nodes: nodes,
		propositions: graph.nodes,
		edges: view.edges,
		logicalEdges: view.logicalEdges,
		impLinks: view.impLinks,
		chains: graph.chains,
		sessions: sessions,
		fileSources: fileSources,
		nodeSessions: nodeSessions,
		clusters: clusters,
		positions: positions.isEmpty ? nil : positions)
}

// MARK: - Prober graph tools — the data seam

/// One session in the prober's graph view: a real chat or an imported file.
public struct GraphSessionEntry: Sendable, Hashable {
	public enum Kind: String, Sendable, Hashable, Codable { case chat, file }
	/// chatId or notes source id ("src_…") — the birth-session key.
	public var id: String
	/// The chat's title, or the file's path (the id when no record exists).
	public var name: String
	public var kind: Kind
	/// The chat's createdAt, or the file's importedAt; nil when undatable.
	public var createdAt: String?
	/// The chat's updatedAt, or the file's importedAt; nil when undatable.
	public var updatedAt: String?
	/// How many propositions were BORN in this session.
	public var propositions: Int
	public init(id: String, name: String, kind: Kind, createdAt: String?, updatedAt: String?, propositions: Int) {
		self.id = id
		self.name = name
		self.kind = kind
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.propositions = propositions
	}
}

/// The prober's session list: every birth session, most-recently-active
/// first (undatable records sink, in stable id order).
public func graphSessionIndex(_ deps: GraphDeps) -> [GraphSessionEntry] {
	let born = getGraph(deps.graphStore)
	var chats: [String: ChatSummary] = [:]
	for chat in deps.chatStore.listChats() { chats[chat.id] = chat }
	var sources: [String: NotesSource] = [:]
	for source in deps.graphStore.readSources() { sources[source.id] = source }
	var entries: [GraphSessionEntry] = []
	for cluster in birthSessionPartition(born.nodes) {
		let id = cluster.id, propositions = cluster.members.count
		if let chat = chats[id] {
			entries.append(GraphSessionEntry(id: id, name: chat.title, kind: .chat, createdAt: chat.createdAt, updatedAt: chat.updatedAt, propositions: propositions))
			continue
		}
		let source = sources[id]
		entries.append(GraphSessionEntry(id: id, name: source?.filePath ?? id, kind: .file, createdAt: source?.importedAt, updatedAt: source?.importedAt, propositions: propositions))
	}
	return GraphJS.stableSorted(entries) { a, b in
		let u = GraphJS.localeCompare(b.updatedAt ?? "", a.updatedAt ?? "")
		if u != 0 { return u }
		let c = GraphJS.localeCompare(b.createdAt ?? "", a.createdAt ?? "")
		if c != 0 { return c }
		return GraphJS.less(a.id, b.id) ? -1 : 1
	}
}

/// One birth proposition of one session.
public struct GraphSessionProposition: Sendable, Hashable, Codable {
	public var nodeId: String
	/// The compact handle — the same name the canvas shows.
	public var name: String
	public init(nodeId: String, name: String) {
		self.nodeId = nodeId
		self.name = name
	}
}

/// The propositions BORN in one session, sorted by node id.
public func graphSessionPropositions(_ deps: GraphDeps, sessionId: String) -> [GraphSessionProposition] {
	let born = getGraph(deps.graphStore).nodes.filter { birthSessionOf($0) == sessionId }
	return GraphJS.stableSorted(born.map { GraphSessionProposition(nodeId: $0.id, name: $0.name) }) { a, b in
		GraphJS.less(a.nodeId, b.nodeId) ? -1 : 1
	}
}
