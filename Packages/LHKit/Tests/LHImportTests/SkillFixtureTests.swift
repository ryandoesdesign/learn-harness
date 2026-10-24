import Foundation
import GRDB
import Testing
import LHCore
@testable import LHImport
@testable import LHStore

/// The Agent Skill's test data (docs/native-macos-m8.md, "Agent Skill"):
/// `tests/fixtures/golden-data.sqlite` is the golden JSON data folder run
/// through the importer, and `tests/fixtures/schema.sql` is the migrator's
/// schema, which the Python tests use to build small synthetic databases.
/// Both are drift-tested here; `LH_WRITE_FIXTURE=1` rewrites them instead.
@Suite(.serialized) struct SkillFixtureTests {
	static let root: URL = {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<5 { url.deleteLastPathComponent() }
		return url
	}()
	static let goldenData = root.appending(path: "tests/fixtures/golden-data")
	static let fixtureDB = root.appending(path: "tests/fixtures/golden-data.sqlite")
	static let schemaSQL = root.appending(path: "tests/fixtures/schema.sql")
	static var writing: Bool { ProcessInfo.processInfo.environment["LH_WRITE_FIXTURE"] == "1" }

	@Test func goldenDatabaseMatchesWhatTheImporterProduces() throws {
		let scratch = FileManager.default.temporaryDirectory.appending(path: "lhfixture-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? FileManager.default.removeItem(at: scratch) }
		let built = try Self.buildGoldenDatabase(in: scratch)
		if Self.writing {
			try? FileManager.default.removeItem(at: Self.fixtureDB)
			try FileManager.default.copyItem(at: built, to: Self.fixtureDB)
			return
		}
		#expect(FileManager.default.fileExists(atPath: Self.fixtureDB.path), "missing \(Self.fixtureDB.path); run with LH_WRITE_FIXTURE=1")
		let expected = try Self.logicalContent(of: Self.fixtureDB)
		let actual = try Self.logicalContent(of: built)
		#expect(Array(actual.keys).sorted() == Array(expected.keys).sorted())
		for (table, rows) in actual {
			#expect(rows == expected[table], "table \(table) drifted; rerun with LH_WRITE_FIXTURE=1 and commit")
		}
	}

	@Test func schemaSQLMatchesTheMigrator() throws {
		let dumped = try Self.schemaDump()
		if Self.writing {
			try Data(dumped.utf8).write(to: Self.schemaSQL)
			return
		}
		let committed = try String(contentsOf: Self.schemaSQL, encoding: .utf8)
		#expect(committed == dumped, "schema.sql drifted from the migrator; rerun with LH_WRITE_FIXTURE=1 and commit")
	}

	// MARK: Builders

	/// Import the golden data folder into an on-disk database, then make the
	/// file self-contained and deterministic: no import-log row (its stamps and
	/// temporary paths vary), WAL checkpointed, journal_mode=DELETE, VACUUM.
	static func buildGoldenDatabase(in scratch: URL) throws -> URL {
		let dbDir = scratch.appending(path: "db", directoryHint: .isDirectory)
		let artifacts = scratch.appending(path: "artifacts", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
		do {
			let db = try AppDatabase.open(directory: dbDir)
			_ = try LegacyImporter(database: db, dataDirectory: artifacts, keychain: InMemoryKeychain()).run(root: goldenData)
			try db.writer.write { try $0.execute(sql: "DELETE FROM import_log") }
			try db.writer.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) }
			try (db.writer as? DatabasePool)?.close()
		}
		let path = dbDir.appending(path: "aster.sqlite")
		let queue = try DatabaseQueue(path: path.path)
		try queue.writeWithoutTransaction { db in
			try db.execute(sql: "PRAGMA journal_mode=DELETE")
			try db.execute(sql: "VACUUM")
		}
		try queue.close()
		return path
	}

	/// Every table's rows in rowid order, plus the schema itself. FTS5's
	/// shadow tables (some WITHOUT ROWID) are covered by the virtual table.
	static func logicalContent(of file: URL) throws -> [String: [[DatabaseValue]]] {
		var config = Configuration()
		config.readonly = true
		let queue = try DatabaseQueue(path: file.path, configuration: config)
		defer { try? queue.close() }
		return try queue.read { db in
			var out: [String: [[DatabaseValue]]] = [:]
			out["sqlite_master"] = try Row.fetchAll(db, sql: "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").map { Array($0.databaseValues) }
			let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'message_fts_%' ORDER BY name")
			for table in tables {
				out[table] = try Row.fetchAll(db, sql: "SELECT rowid, * FROM \"\(table)\" ORDER BY rowid").map { Array($0.databaseValues) }
			}
			return out
		}
	}

	/// The migrated schema as a script: tables, indexes, triggers and the
	/// virtual table, without SQLite's own and FTS5's shadow tables, then the
	/// migration identifiers GRDB records.
	static func schemaDump() throws -> String {
		let db = try AppDatabase.inMemory()
		return try db.writer.read { db in
			let rows = try Row.fetchAll(db, sql: """
				SELECT name, sql FROM sqlite_master
				WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'message_fts_%'
				ORDER BY rowid
				""")
			var out = "-- Generated from the LHStore migrator by SkillFixtureTests (LH_WRITE_FIXTURE=1). Do not edit.\n"
			for row in rows {
				out += (row["sql"] as String) + ";\n"
			}
			for id in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") {
				out += "INSERT INTO grdb_migrations (identifier) VALUES ('\(id)');\n"
			}
			return out
		}
	}
}
