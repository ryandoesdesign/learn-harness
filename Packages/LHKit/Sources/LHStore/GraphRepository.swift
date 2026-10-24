import Foundation
import GRDB
import LHCore

/// Port of src/store/graph.ts: the append-only ledgers as rows holding each
/// JSONL line verbatim (line_json), read back in append order and merged by
/// the LHCore folds. Corrupt lines are skipped on read, as the TS reader does.
public final class GraphRepository: GraphTraceStore, Sendable {
	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	/// Run `body` against the graph inside one write transaction (M7: a
	/// merge, a session's trace delete with its chat, a batch of node
	/// deletes — all or nothing).
	public func transaction<T>(_ body: (GraphTransaction) throws -> T) throws -> T {
		try database.writer.write { db in try body(GraphTransaction(db)) }
	}

	// MARK: Ledger appends

	public func appendNode(_ node: GraphNode) throws { try write { try GraphSQL.appendNode(node, $0) } }
	public func appendChain(_ assertion: GraphChain) throws { try write { try GraphSQL.appendChain(assertion, $0) } }
	public func appendCheckpoint(_ checkpoint: SessionCheckpoint) throws { try write { try GraphSQL.appendCheckpoint(checkpoint, $0) } }
	public func appendCoverage(_ entry: CoverageEntry) throws { try write { try GraphSQL.appendCoverage(entry, $0) } }

	/// Raw-line appends (the importer keeps the source bytes).
	public func appendNodeLine(_ line: String, nodeId: String) throws {
		try write { try $0.execute(sql: "INSERT INTO graph_node_line (node_id, line_json) VALUES (?, ?)", arguments: [nodeId, line]) }
	}

	public func appendChainLine(_ line: String, chainId: String) throws {
		try write { try $0.execute(sql: "INSERT INTO graph_chain_line (chain_id, line_json) VALUES (?, ?)", arguments: [chainId, line]) }
	}

	public func appendSessionLine(_ line: String, chatId: String) throws {
		try write { try $0.execute(sql: "INSERT INTO graph_session (chat_id, line_json) VALUES (?, ?)", arguments: [chatId, line]) }
	}

	public func appendCoverageLine(_ line: String, chatId: String, fp: String) throws {
		try write { try $0.execute(sql: "INSERT INTO coverage (chat_id, fp, line_json) VALUES (?, ?, ?)", arguments: [chatId, fp, line]) }
	}

	// MARK: Ledger reads

	public func readNodes() -> [GraphNode] { read(GraphSQL.readNodes) ?? [] }
	public func readChains() -> [GraphChain] { read(GraphSQL.readChains) ?? [] }
	public func readCheckpoints() -> [SessionCheckpoint] { read(GraphSQL.readCheckpoints) ?? [] }
	public func readCoverage() -> [CoverageEntry] { read(GraphSQL.readCoverage) ?? [] }

	/// The verbatim lines of one ledger, in append order.
	public func rawLines(_ ledger: Ledger) throws -> [String] {
		try database.writer.read { db in try String.fetchAll(db, sql: "SELECT line_json FROM \(ledger.rawValue) ORDER BY seq") }
	}

	public enum Ledger: String, Sendable {
		case nodes = "graph_node_line", chains = "graph_chain_line", sessions = "graph_session", coverage
	}

	public func rewriteLedgers(_ next: GraphLedgerRewrite) throws { try write { try GraphSQL.rewriteLedgers(next, $0) } }

	/// The graph revision (M7): a counter that ticks after every commit
	/// touching the ledgers, positions or sources — what the graph window
	/// observes to re-read the snapshot.
	public func observeRevision() -> AsyncValueObservation<Int> {
		let tick = RevisionTick()
		return ValueObservation.tracking(regions: [Table("graph_node_line"), Table("graph_chain_line"), Table("node_position"), Table("source"), Table("coverage"), Table("extraction_run")]) { _ in
			tick.next()
		}.values(in: database.writer)
	}

	/// The one-time extraction backfill (docs/native-macos-m7.md): set once
	/// every eligible session has been attempted.
	public var backfillDone: Bool {
		(try? database.writer.read { db in try KV.get("extraction_backfill_done", db: db)?.boolValue }) ?? nil ?? false
	}

	public func markBackfillDone() throws {
		try write { try KV.set("extraction_backfill_done", .bool(true), db: $0) }
	}

	private func write(_ body: (Database) throws -> Void) throws { try database.writer.write(body) }
	private func read<T>(_ body: (Database) throws -> T) -> T? { try? database.writer.read(body) }

	// MARK: Sources

	public func readSources() -> [NotesSource] { read(GraphSQL.readSources) ?? [] }

	/// Upsert the source record; its usage log is preserved (TS upsertSource).
	public func upsertSource(_ source: NotesSource) throws {
		try database.writer.write { db in
			let seq = try Int.fetchOne(db, sql: "SELECT seq FROM source WHERE id = ?", arguments: [source.id])
			if seq != nil {
				try db.execute(sql: "UPDATE source SET file_path = ?, imported_at = ?, content_fp = ? WHERE id = ?", arguments: [source.filePath, source.importedAt, source.contentFp, source.id])
				return
			}
			let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq) + 1, 0) FROM source") ?? 0
			try db.execute(sql: "INSERT INTO source (id, seq, file_path, imported_at, content_fp) VALUES (?, ?, ?, ?, ?)", arguments: [source.id, next, source.filePath, source.importedAt, source.contentFp])
			for run in source.extractions ?? [] { try UsageRows.insertRun(run, ownerKind: "source", ownerId: source.id, db: db) }
		}
	}

	/// Idempotent per startedAt; unknown source = nothing to bill against.
	public func appendSourceUsage(_ run: ExtractionRunUsage, sourceId: String) throws {
		try database.writer.write { db in
			guard try Bool.fetchOne(db, sql: "SELECT 1 FROM source WHERE id = ?", arguments: [sourceId]) == true else { return }
			try UsageRows.insertRun(run, ownerKind: "source", ownerId: sourceId, db: db)
		}
	}

	// MARK: Positions

	public func readPositions() -> [String: Position] { read(GraphSQL.readPositions) ?? [:] }

	/// Replace the whole ledger (the settle's write), stamping updatedAt.
	public func writePositions(_ positions: [String: Position]) throws {
		try writePositions(positions.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }, updatedAt: ISOClock.string())
	}

	public func writePositions(_ ordered: [(key: String, value: Position)], updatedAt: String) throws {
		try write { try GraphSQL.writePositions(ordered, updatedAt: updatedAt, $0) }
	}
}

final class RevisionTick: @unchecked Sendable {
	private let lock = NSLock()
	private var n = 0
	func next() -> Int { lock.withLock { n += 1; return n } }
}

/// The graph store bound to one open write transaction (GraphRepository.transaction).
public final class GraphTransaction: GraphTraceStore {
	let db: Database
	init(_ db: Database) { self.db = db }

	public func appendNode(_ node: GraphNode) throws { try GraphSQL.appendNode(node, db) }
	public func appendChain(_ assertion: GraphChain) throws { try GraphSQL.appendChain(assertion, db) }
	public func appendCheckpoint(_ checkpoint: SessionCheckpoint) throws { try GraphSQL.appendCheckpoint(checkpoint, db) }
	public func appendCoverage(_ entry: CoverageEntry) throws { try GraphSQL.appendCoverage(entry, db) }
	public func readNodes() -> [GraphNode] { (try? GraphSQL.readNodes(db)) ?? [] }
	public func readChains() -> [GraphChain] { (try? GraphSQL.readChains(db)) ?? [] }
	public func readCheckpoints() -> [SessionCheckpoint] { (try? GraphSQL.readCheckpoints(db)) ?? [] }
	public func readCoverage() -> [CoverageEntry] { (try? GraphSQL.readCoverage(db)) ?? [] }
	public func readSources() -> [NotesSource] { (try? GraphSQL.readSources(db)) ?? [] }
	public func readPositions() -> [String: Position] { (try? GraphSQL.readPositions(db)) ?? [:] }
	public func rewriteLedgers(_ next: GraphLedgerRewrite) throws { try GraphSQL.rewriteLedgers(next, db) }
	public func writePositions(_ positions: [String: Position]) throws {
		try GraphSQL.writePositions(positions.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }, updatedAt: ISOClock.string(), db)
	}
	/// The session still exists (a merge for a deleted chat is dropped).
	public func chatExists(_ chatId: String) -> Bool {
		(try? Bool.fetchOne(db, sql: "SELECT 1 FROM chat WHERE id = ?", arguments: [chatId])) ?? nil ?? false
	}

	/// The chat delete, in this transaction (the traces go first).
	public func deleteChat(_ chatId: String) throws -> Bool { try ChatRepository.deleteRows(chatId, db) }
}

/// The ledger SQL, shared by GraphRepository and GraphTransaction.
enum GraphSQL {
	static func appendNode(_ n: GraphNode, _ db: Database) throws {
		try db.execute(sql: "INSERT INTO graph_node_line (node_id, line_json) VALUES (?, ?)", arguments: [n.id, try JSONCodec.encode(n).serialized()])
	}
	static func appendChain(_ c: GraphChain, _ db: Database) throws {
		try db.execute(sql: "INSERT INTO graph_chain_line (chain_id, line_json) VALUES (?, ?)", arguments: [c.id, try JSONCodec.encode(c).serialized()])
	}
	static func appendCheckpoint(_ c: SessionCheckpoint, _ db: Database) throws {
		try db.execute(sql: "INSERT INTO graph_session (chat_id, line_json) VALUES (?, ?)", arguments: [c.chatId, try JSONCodec.encode(c).serialized()])
	}
	static func appendCoverage(_ e: CoverageEntry, _ db: Database) throws {
		try db.execute(sql: "INSERT INTO coverage (chat_id, fp, line_json) VALUES (?, ?, ?)", arguments: [e.chatId, e.fp, try JSONCodec.encode(e).serialized()])
	}

	static func readNodes(_ db: Database) throws -> [GraphNode] { try lines("graph_node_line", db) }
	static func readChains(_ db: Database) throws -> [GraphChain] { try lines("graph_chain_line", db).filter { (c: GraphChain) in !c.premises.isEmpty } }
	static func readCheckpoints(_ db: Database) throws -> [SessionCheckpoint] { try lines("graph_session", db) }
	static func readCoverage(_ db: Database) throws -> [CoverageEntry] { try lines("coverage", db) }

	/// Corrupt lines are skipped, as the TS reader does.
	static func lines<T: Decodable>(_ table: String, _ db: Database) throws -> [T] {
		try String.fetchAll(db, sql: "SELECT line_json FROM \(table) ORDER BY seq")
			.compactMap { line in (try? JSONValue.parse(line)).flatMap { try? JSONCodec.decode(T.self, from: $0) } }
	}

	static func rewriteLedgers(_ next: GraphLedgerRewrite, _ db: Database) throws {
		if let nodes = next.nodes {
			try db.execute(sql: "DELETE FROM graph_node_line")
			for n in nodes { try appendNode(n, db) }
		}
		if let chains = next.chains {
			try db.execute(sql: "DELETE FROM graph_chain_line")
			for c in chains { try appendChain(c, db) }
		}
		if let coverage = next.coverage {
			try db.execute(sql: "DELETE FROM coverage")
			for e in coverage { try appendCoverage(e, db) }
		}
		if let checkpoints = next.checkpoints {
			try db.execute(sql: "DELETE FROM graph_session")
			for c in checkpoints { try appendCheckpoint(c, db) }
		}
	}

	static func readSources(_ db: Database) throws -> [NotesSource] {
		try Row.fetchAll(db, sql: "SELECT * FROM source ORDER BY seq").map { r in
			let id: String = r["id"]
			let runs = try UsageRows.runs(ownerKind: "source", ownerId: id, db: db)
			return NotesSource(id: id, filePath: r["file_path"], importedAt: r["imported_at"], contentFp: r["content_fp"], extractions: runs.isEmpty ? nil : runs)
		}
	}

	static func readPositions(_ db: Database) throws -> [String: Position] {
		try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT node_id, x, y FROM node_position ORDER BY seq").map {
			($0["node_id"] as String, Position(x: $0["x"], y: $0["y"]))
		})
	}

	static func writePositions(_ ordered: [(key: String, value: Position)], updatedAt: String, _ db: Database) throws {
		try db.execute(sql: "DELETE FROM node_position")
		for (seq, (id, p)) in ordered.enumerated() {
			try db.execute(sql: "INSERT INTO node_position (node_id, seq, x, y) VALUES (?, ?, ?, ?)", arguments: [id, seq, p.x, p.y])
		}
		try KV.set("positions_updated_at", .string(updatedAt), db: db)
	}
}

/// kv_settings access.
enum KV {
	static func get(_ key: String, db: Database) throws -> JSONValue? {
		try (String.fetchOne(db, sql: "SELECT value_json FROM kv_settings WHERE key = ?", arguments: [key])).map(JSONValue.parse)
	}

	static func set(_ key: String, _ value: JSONValue, db: Database) throws {
		try db.execute(sql: """
			INSERT INTO kv_settings (key, value_json) VALUES (?, ?)
			ON CONFLICT (key) DO UPDATE SET value_json = excluded.value_json
			""", arguments: [key, value.serialized()])
	}
}
