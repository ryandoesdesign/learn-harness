import Foundation

// Port of the src/core/ports.ts storage seams the graph modules use — one
// port per entity, domain operations only. Only the members graph.ts reads or
// writes are declared here; the adapters (LHStore, M2) add the rest.
// Reads never throw (the TS adapters skip corrupt lines / return null);
// writes may.

/// The session record's home — the graph derivations only label sources.
public protocol ChatStore {
	/// The full record, or nil if unknown id / corrupt.
	func getChat(_ id: String) -> ChatRecord?
	/// All sessions, newest activity first.
	func listChats() -> [ChatSummary]
}

/// The append-only evidence ledgers. Chains are the stored truth; edges are a
/// derived view and never touch this seam. Reads return raw append-order
/// lines — merging is derived in Graph.swift, never decided by the store.
public protocol GraphStore {
	/// Append one GraphNode line (a repeated id is a link-append).
	func appendNode(_ node: GraphNode) throws
	/// Raw node lines in append order.
	func readNodes() -> [GraphNode]
	/// Append one chain ASSERTION (readers merge by (premises, conclusion)).
	func appendChain(_ assertion: GraphChain) throws
	func readChains() -> [GraphChain]
	/// Append one emission checkpoint (the notes path's whole-file stamp).
	func appendCheckpoint(_ checkpoint: SessionCheckpoint) throws
	/// Append one message-granular coverage line.
	func appendCoverage(_ entry: CoverageEntry) throws
	/// Every notes source record, order-insensitive.
	func readSources() -> [NotesSource]
	/// The layout ledger: nodeId → resting position.
	func readPositions() -> [String: Position]
	/// Atomically replace any subset of the rewritable ledgers (nil = untouched).
	func rewriteLedgers(_ next: GraphLedgerRewrite) throws
}

/// The `rewriteLedgers` argument: each non-nil array replaces its ledger.
public struct GraphLedgerRewrite: Sendable, Hashable {
	public var nodes: [GraphNode]?
	public var chains: [GraphChain]?
	public var coverage: [CoverageEntry]?
	public var checkpoints: [SessionCheckpoint]?
	public init(nodes: [GraphNode]? = nil, chains: [GraphChain]? = nil, coverage: [CoverageEntry]? = nil, checkpoints: [SessionCheckpoint]? = nil) {
		self.nodes = nodes
		self.chains = chains
		self.coverage = coverage
		self.checkpoints = checkpoints
	}
}

/// The storage ports every graph operation needs, passed explicitly.
public struct GraphDeps {
	public var chatStore: any ChatStore
	public var graphStore: any GraphStore
	public init(chatStore: any ChatStore, graphStore: any GraphStore) {
		self.chatStore = chatStore
		self.graphStore = graphStore
	}
}
