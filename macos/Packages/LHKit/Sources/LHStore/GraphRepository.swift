import Foundation
import GRDB
import LHCore

/// Port of src/store/graph.ts: the append-only ledgers as rows holding each
/// JSONL line verbatim (line_json), read back in append order and merged by
/// the LHCore folds. Corrupt lines are skipped on read, as the TS reader does.
public final class GraphRepository: PositionsLedgerStore, Sendable {
	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	// MARK: Ledger appends

	public func appendNode(_ node: GraphNode) throws {
		try appendNodeLine(try JSONCodec.encode(node).serialized(), nodeId: node.id)
	}

	public func appendChain(_ assertion: GraphChain) throws {
		try appendChainLine(try JSONCodec.encode(assertion).serialized(), chainId: assertion.id)
	}

	public func appendCheckpoint(_ checkpoint: SessionCheckpoint) throws {
		try appendSessionLine(try JSONCodec.encode(checkpoint).serialized(), chatId: checkpoint.chatId)
	}

	public func appendCoverage(_ entry: CoverageEntry) throws {
		try appendCoverageLine(try JSONCodec.encode(entry).serialized(), chatId: entry.chatId, fp: entry.fp)
	}

	/// Raw-line appends (the importer keeps the source bytes).
	public func appendNodeLine(_ line: String, nodeId: String) throws {
		try database.writer.write { db in
			try db.execute(sql: "INSERT INTO graph_node_line (node_id, line_json) VALUES (?, ?)", arguments: [nodeId, line])
		}
	}

	public func appendChainLine(_ line: String, chainId: String) throws {
		try database.writer.write { db in
			try db.execute(sql: "INSERT INTO graph_chain_line (chain_id, line_json) VALUES (?, ?)", arguments: [chainId, line])
		}
	}

	public func appendSessionLine(_ line: String, chatId: String) throws {
		try database.writer.write { db in
			try db.execute(sql: "INSERT INTO graph_session (chat_id, line_json) VALUES (?, ?)", arguments: [chatId, line])
		}
	}

	public func appendCoverageLine(_ line: String, chatId: String, fp: String) throws {
		try database.writer.write { db in
			try db.execute(sql: "INSERT INTO coverage (chat_id, fp, line_json) VALUES (?, ?, ?)", arguments: [chatId, fp, line])
		}
	}

	// MARK: Ledger reads

	public func readNodes() -> [GraphNode] { readLines("graph_node_line", as: GraphNode.self) }
	public func readChains() -> [GraphChain] { readLines("graph_chain_line", as: GraphChain.self).filter { !$0.premises.isEmpty } }
	public func readCheckpoints() -> [SessionCheckpoint] { readLines("graph_session", as: SessionCheckpoint.self) }
	public func readCoverage() -> [CoverageEntry] { readLines("coverage", as: CoverageEntry.self) }

	/// The verbatim lines of one ledger, in append order.
	public func rawLines(_ ledger: Ledger) throws -> [String] {
		try database.writer.read { db in try String.fetchAll(db, sql: "SELECT line_json FROM \(ledger.rawValue) ORDER BY seq") }
	}

	public enum Ledger: String, Sendable {
		case nodes = "graph_node_line", chains = "graph_chain_line", sessions = "graph_session", coverage
	}

	private func readLines<T: Decodable>(_ table: String, as type: T.Type) -> [T] {
		let lines = (try? database.writer.read { db in try String.fetchAll(db, sql: "SELECT line_json FROM \(table) ORDER BY seq") }) ?? []
		return lines.compactMap { line in (try? JSONValue.parse(line)).flatMap { try? JSONCodec.decode(T.self, from: $0) } }
	}

	public func rewriteLedgers(_ next: GraphLedgerRewrite) throws {
		try database.writer.write { db in
			if let nodes = next.nodes {
				try db.execute(sql: "DELETE FROM graph_node_line")
				for n in nodes { try db.execute(sql: "INSERT INTO graph_node_line (node_id, line_json) VALUES (?, ?)", arguments: [n.id, try JSONCodec.encode(n).serialized()]) }
			}
			if let chains = next.chains {
				try db.execute(sql: "DELETE FROM graph_chain_line")
				for c in chains { try db.execute(sql: "INSERT INTO graph_chain_line (chain_id, line_json) VALUES (?, ?)", arguments: [c.id, try JSONCodec.encode(c).serialized()]) }
			}
			if let coverage = next.coverage {
				try db.execute(sql: "DELETE FROM coverage")
				for e in coverage { try db.execute(sql: "INSERT INTO coverage (chat_id, fp, line_json) VALUES (?, ?, ?)", arguments: [e.chatId, e.fp, try JSONCodec.encode(e).serialized()]) }
			}
			if let checkpoints = next.checkpoints {
				try db.execute(sql: "DELETE FROM graph_session")
				for c in checkpoints { try db.execute(sql: "INSERT INTO graph_session (chat_id, line_json) VALUES (?, ?)", arguments: [c.chatId, try JSONCodec.encode(c).serialized()]) }
			}
		}
	}

	// MARK: Sources

	public func readSources() -> [NotesSource] {
		(try? database.writer.read { db in
			try Row.fetchAll(db, sql: "SELECT * FROM source ORDER BY seq").map { r in
				let id: String = r["id"]
				let runs = try UsageRows.runs(ownerKind: "source", ownerId: id, db: db)
				return NotesSource(id: id, filePath: r["file_path"], importedAt: r["imported_at"], contentFp: r["content_fp"], extractions: runs.isEmpty ? nil : runs)
			}
		}) ?? []
	}

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

	public func readPositions() -> [String: Position] {
		(try? database.writer.read { db in
			try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT node_id, x, y FROM node_position ORDER BY seq").map {
				($0["node_id"] as String, Position(x: $0["x"], y: $0["y"]))
			})
		}) ?? [:]
	}

	/// Replace the whole ledger (the settle's write), stamping updatedAt.
	public func writePositions(_ positions: [String: Position]) throws {
		try writePositions(positions.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }, updatedAt: ISOClock.string())
	}

	public func writePositions(_ ordered: [(key: String, value: Position)], updatedAt: String) throws {
		try database.writer.write { db in
			try db.execute(sql: "DELETE FROM node_position")
			for (seq, (id, p)) in ordered.enumerated() {
				try db.execute(sql: "INSERT INTO node_position (node_id, seq, x, y) VALUES (?, ?, ?, ?)", arguments: [id, seq, p.x, p.y])
			}
			try KV.set("positions_updated_at", .string(updatedAt), db: db)
		}
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
