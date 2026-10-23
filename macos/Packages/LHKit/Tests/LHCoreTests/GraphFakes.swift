import Foundation
@testable import LHCore

/// In-memory GraphStore — the ledgers as arrays (append order kept).
final class MemoryGraphStore: GraphStore {
	var nodes: [GraphNode]
	var chains: [GraphChain]
	var checkpoints: [SessionCheckpoint] = []
	var coverage: [CoverageEntry] = []
	var sources: [NotesSource]
	var positions: [String: Position]

	init(nodes: [GraphNode] = [], chains: [GraphChain] = [], sources: [NotesSource] = [], positions: [String: Position] = [:]) {
		self.nodes = nodes
		self.chains = chains
		self.sources = sources
		self.positions = positions
	}

	func appendNode(_ node: GraphNode) { nodes.append(node) }
	func readNodes() -> [GraphNode] { nodes }
	func appendChain(_ assertion: GraphChain) { chains.append(assertion) }
	func readChains() -> [GraphChain] { chains }
	func appendCheckpoint(_ checkpoint: SessionCheckpoint) { checkpoints.append(checkpoint) }
	func appendCoverage(_ entry: CoverageEntry) { coverage.append(entry) }
	func readSources() -> [NotesSource] { sources }
	func readPositions() -> [String: Position] { positions }
	func rewriteLedgers(_ next: GraphLedgerRewrite) {
		if let n = next.nodes { nodes = n }
		if let c = next.chains { chains = c }
		if let c = next.coverage { coverage = c }
		if let c = next.checkpoints { checkpoints = c }
	}

	/// The notes-source upsert (TS GraphStore.upsertSource), test-side only.
	func upsertSource(_ source: NotesSource) {
		if let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i] = source } else { sources.append(source) }
	}
}

/// In-memory ChatStore over full records.
final class MemoryChatStore: ChatStore {
	var chats: [ChatRecord]
	init(_ chats: [ChatRecord] = []) { self.chats = chats }

	func getChat(_ id: String) -> ChatRecord? { chats.first { $0.id == id } }
	func listChats() -> [ChatSummary] {
		chats.map {
			ChatSummary(id: $0.id, title: $0.title, createdAt: $0.createdAt, updatedAt: $0.updatedAt, kind: $0.resolvedKind,
				messageCount: $0.messages.count, phase: .teach, pendingQuestion: false, pendingProblem: false)
		}
	}

	@discardableResult
	func create(_ id: String, title: String, createdAt: String = "", updatedAt: String = "", messages: [Message] = []) -> ChatRecord {
		let record = ChatRecord(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, messages: messages)
		chats.append(record)
		return record
	}
}

/// Deterministic id minting: a counter spread over the requested bytes.
final class CountingRandom: @unchecked Sendable {
	private var n: UInt64 = 0
	private let lock = NSLock()
	var random: GraphRandom {
		GraphRandom { [self] count in
			lock.lock()
			defer { lock.unlock() }
			n += 1
			var v = n
			var out = [UInt8](repeating: 0, count: count)
			for i in stride(from: count - 1, through: 0, by: -1) {
				out[i] = UInt8(v & 0xFF)
				v >>= 8
			}
			return out
		}
	}
}

/// The golden data dir behind the two ports (read-only).
enum GoldenGraph {
	static func deps() throws -> (GraphDeps, MemoryGraphStore) {
		let nodes = try Fixtures.jsonl("graph/nodes.jsonl").map { try JSONCodec.decode(GraphNode.self, from: $0) }
		let chains = try Fixtures.jsonl("graph/chains.jsonl").map { try JSONCodec.decode(GraphChain.self, from: $0) }
		guard case .object(let srcObj) = try Fixtures.json("graph/sources.json") else { throw CocoaError(.fileReadCorruptFile) }
		let sources = try srcObj.map { try JSONCodec.decode(NotesSource.self, from: $0.value) }
		// positions.json is { positions, updatedAt } — readPositions returns the map.
		let positions = try JSONCodec.decode([String: Position].self, from: try Fixtures.json("graph/positions.json")["positions"] ?? [:])
		let store = MemoryGraphStore(nodes: nodes, chains: chains, sources: sources, positions: positions)
		let chats = MemoryChatStore([try Fixtures.teachChat, try Fixtures.practiceChat])
		return (GraphDeps(chatStore: chats, graphStore: store), store)
	}
}
