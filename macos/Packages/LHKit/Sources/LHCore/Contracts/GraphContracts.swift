import Foundation

// Port of src/core/contracts/graph.ts — the knowledge graph's stored truth
// (propositions + reasoning chains) and its derived snapshot.

public struct GraphEdge: Sendable, Hashable, Codable {
	public var from: String
	public var to: String
	public init(from: String, to: String) {
		self.from = from
		self.to = to
	}
}

public struct ProvenancePoint: Sendable, Hashable, Codable {
	/// A chat id, or a notes source id ("src_…").
	public var chatId: String
	/// "" for chat-level / notes provenance.
	public var messageId: String
	public init(chatId: String, messageId: String) {
		self.chatId = chatId
		self.messageId = messageId
	}
}

/// One stored reasoning chain: premises that jointly entail the conclusion.
public struct GraphChain: Sendable, Hashable, Codable {
	/// "arg_" + nanoid-like.
	public var id: String
	public var premises: [String]
	public var conclusion: String
	public var provenance: [ProvenancePoint]
	public var createdAt: String
	public init(id: String, premises: [String], conclusion: String, provenance: [ProvenancePoint], createdAt: String) {
		self.id = id
		self.premises = premises
		self.conclusion = conclusion
		self.provenance = provenance
		self.createdAt = createdAt
	}
}

public struct EmissionStats: Sendable, Hashable, Codable {
	public var nodes: Int
	public var chains: Int?
	public var droppedChains: Int?
	public init(nodes: Int, chains: Int? = nil, droppedChains: Int? = nil) {
		self.nodes = nodes
		self.chains = chains
		self.droppedChains = droppedChains
	}
}

/// One imported notes file's bookkeeping.
public struct NotesSource: Sendable, Hashable, Codable {
	public var id: String
	public var filePath: String
	public var importedAt: String
	/// Legacy; read but ignored.
	public var contentFp: String?
	public var extractions: [ExtractionRunUsage]?
	public init(id: String, filePath: String, importedAt: String, contentFp: String? = nil, extractions: [ExtractionRunUsage]? = nil) {
		self.id = id
		self.filePath = filePath
		self.importedAt = importedAt
		self.contentFp = contentFp
		self.extractions = extractions
	}
}

public let CURRENT_GRAPH_FORMAT_VERSION = 1

public struct GraphNode: Sendable, Hashable, Codable {
	/// "n_" + nanoid-like (store-assigned); implication nodes reuse the chain's "arg_" id.
	public var id: String
	public var name: String
	public var statement: String
	public var aliases: [String]
	public var createdAt: String
	public var provenance: [ProvenancePoint]
	public init(id: String, name: String, statement: String, aliases: [String], createdAt: String, provenance: [ProvenancePoint]) {
		self.id = id
		self.name = name
		self.statement = statement
		self.aliases = aliases
		self.createdAt = createdAt
		self.provenance = provenance
	}
}

/// sessions.jsonl line — the notes-import fold checkpoint.
public struct SessionCheckpoint: Sendable, Hashable, Codable {
	public var chatId: String
	public var foldedAt: String
	public init(chatId: String, foldedAt: String) {
		self.chatId = chatId
		self.foldedAt = foldedAt
	}
}

/// coverage.jsonl line — one message of one chat has been extracted.
public struct CoverageEntry: Sendable, Hashable, Codable {
	public var chatId: String
	/// sha256 of the message's view lines.
	public var fp: String
	/// chars/4 estimate of the message's view.
	public var tokens: Int
	public var foldedAt: String
	public init(chatId: String, fp: String, tokens: Int, foldedAt: String) {
		self.chatId = chatId
		self.fp = fp
		self.tokens = tokens
		self.foldedAt = foldedAt
	}
}

// MARK: - Extraction findings

public struct ExtractedProposition: Sendable, Hashable, Codable {
	/// Extractor-local id ("p1", …).
	public var id: String
	public var name: String
	public var statement: String
	public var aliases: [String]
	/// Session path only: the teacher passage this came from.
	public var messageId: String?
	public init(id: String, name: String, statement: String, aliases: [String], messageId: String? = nil) {
		self.id = id
		self.name = name
		self.statement = statement
		self.aliases = aliases
		self.messageId = messageId
	}
}

public struct ExtractedChain: Sendable, Hashable, Codable {
	public var premises: [String]
	public var conclusion: String
	public init(premises: [String], conclusion: String) {
		self.premises = premises
		self.conclusion = conclusion
	}
}

public struct SessionFindings: Sendable, Hashable, Codable {
	public var propositions: [ExtractedProposition]
	public var chains: [ExtractedChain]
	public init(propositions: [ExtractedProposition], chains: [ExtractedChain]) {
		self.propositions = propositions
		self.chains = chains
	}
}

public struct IdentityLink: Sendable, Hashable, Codable {
	public var id: String
	public var linkTo: String
	public init(id: String, linkTo: String) {
		self.id = id
		self.linkTo = linkTo
	}
}

public struct AuditVerdicts: Sendable, Hashable, Codable {
	public var links: [IdentityLink]
	public init(links: [IdentityLink]) { self.links = links }
}

// MARK: - Snapshot

public struct Cluster: Sendable, Hashable, Codable {
	public var id: String
	public var label: String?
	/// Node ids, sorted.
	public var members: [String]
	public init(id: String, label: String?, members: [String]) {
		self.id = id
		self.label = label
		self.members = members
	}
}

public struct Position: Sendable, Hashable, Codable {
	public var x: Double
	public var y: Double
	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}
}

public struct ImpLink: Sendable, Hashable, Codable {
	public var id: String
	public var premises: [String]
	public var conclusion: String
	public init(id: String, premises: [String], conclusion: String) {
		self.id = id
		self.premises = premises
		self.conclusion = conclusion
	}
}

public struct GraphSnapshot: Sendable, Hashable, Codable {
	/// Propositions + derived implication nodes.
	public var nodes: [GraphNode]
	/// The stored propositions alone.
	public var propositions: [GraphNode]
	/// Derived arrows: premise → imp → conclusion.
	public var edges: [GraphEdge]
	/// Chains contracted to premise → conclusion over proposition ids.
	public var logicalEdges: [GraphEdge]
	/// One per multi-premise live chain.
	public var impLinks: [ImpLink]
	/// The stored chains, merged by (premises, conclusion).
	public var chains: [GraphChain]
	/// chatId → title.
	public var sessions: [String: String]
	/// srcId → file path.
	public var fileSources: [String: String]
	/// nodeId → chatIds that touched the node.
	public var nodeSessions: [String: [String]]
	public var clusters: [Cluster]
	public var positions: [String: Position]?

	public init(nodes: [GraphNode], propositions: [GraphNode], edges: [GraphEdge], logicalEdges: [GraphEdge], impLinks: [ImpLink], chains: [GraphChain], sessions: [String: String], fileSources: [String: String], nodeSessions: [String: [String]], clusters: [Cluster], positions: [String: Position]? = nil) {
		self.nodes = nodes
		self.propositions = propositions
		self.edges = edges
		self.logicalEdges = logicalEdges
		self.impLinks = impLinks
		self.chains = chains
		self.sessions = sessions
		self.fileSources = fileSources
		self.nodeSessions = nodeSessions
		self.clusters = clusters
		self.positions = positions
	}
}

// MARK: - Titles

/// The auto-title's character cap (UTF-16 units, as in TS).
public let TITLE_MAX_CHARS = 72

/// Derive a short chat title from the learner's first message: whitespace
/// collapses, the cut snaps to a word boundary at or under the cap, a single
/// over-long word cuts at the cap.
public func titleFromPrompt(_ prompt: String) -> String {
	let oneLine = prompt.replacing(/\s+/, with: " ").jsTrimmed
	if oneLine.jsLength <= TITLE_MAX_CHARS { return oneLine }
	let units = Array(oneLine.utf16)
	var cut = -1
	var i = TITLE_MAX_CHARS
	while i > 0 {
		if units[i - 1] == 0x20 { cut = i - 1; break }
		i -= 1
	}
	if cut < 0 { cut = TITLE_MAX_CHARS }
	return oneLine.jsSlice(0, cut) + "…"
}
