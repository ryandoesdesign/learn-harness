import Foundation
import GRDB
import LHCore

/// The importer's audit trail (`import_log`): one row per run.
public struct ImportLog: Sendable {
	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	public struct Entry: Sendable, Hashable {
		public var startedAt: String
		public var finishedAt: String?
		public var sourcePath: String
		public var counts: JSONValue
		public var warnings: [String]
	}

	/// Anything with counts and warnings (LHImport's report).
	public func record(sourcePath: String, imported: [String: Int], skipped: [String: Int], warnings: [String], startedAt: String, now: Date = Date()) throws {
		func obj(_ d: [String: Int]) -> JSONValue { .object(JSONObject(pairs: d.sorted { $0.key < $1.key }.map { ($0.key, .number($0.value)) })) }
		let counts: JSONValue = ["imported": obj(imported), "skipped": obj(skipped)]
		try database.writer.write { db in
			try db.execute(sql: "INSERT INTO import_log (started_at, finished_at, source_path, counts_json, warnings_json) VALUES (?, ?, ?, ?, ?)",
				arguments: [startedAt, ISOClock.string(now), sourcePath, counts.serialized(), JSONValue.array(warnings.map(JSONValue.string)).serialized()])
		}
	}

	public func entries() throws -> [Entry] {
		try database.writer.read { db in
			try Row.fetchAll(db, sql: "SELECT * FROM import_log ORDER BY id").map {
				Entry(startedAt: $0["started_at"], finishedAt: $0["finished_at"], sourcePath: $0["source_path"],
					counts: try JSONValue.parse(($0["counts_json"] as String?) ?? "{}"),
					warnings: try JSONValue.parse(($0["warnings_json"] as String?) ?? "[]").arrayValue?.compactMap(\.stringValue) ?? [])
			}
		}
	}
}
