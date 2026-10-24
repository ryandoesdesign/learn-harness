import Foundation
import GRDB
import LHCore

/// Port of src/store/settings.ts: the delta record in kv_settings, always
/// passed through the LHCore sanitizer on read and write.
public struct SettingsRepository: Sendable {
	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	static let userKey = "user_settings"
	static let renderKey = "render_settings"

	/// The stored record, or nil on first boot.
	public func read() throws -> UserSettings? {
		try database.writer.read { db in try Self.read(db) }
	}

	/// Absent or unreadable → nil (first-boot semantics, as in TS).
	static func read(_ db: Database) throws -> UserSettings? {
		guard let text = try String.fetchOne(db, sql: "SELECT value_json FROM kv_settings WHERE key = ?", arguments: [userKey]),
			let raw = try? JSONValue.parse(text) else { return nil }
		return sanitizeUserSettings(raw)
	}

	public func write(_ settings: UserSettings) throws {
		try database.writer.write { db in
			let clean = sanitizeUserSettings(settings.json) ?? settings
			try KV.set(Self.userKey, clean.json, db: db)
		}
	}

	/// Read-modify-write under one transaction.
	public func update(_ change: (inout UserSettings) -> Void) throws {
		try database.writer.write { db in
			var s = try Self.read(db) ?? UserSettings()
			change(&s)
			try KV.set(Self.userKey, (sanitizeUserSettings(s.json) ?? s).json, db: db)
		}
	}

	/// The resolved view (factory defaults applied).
	public func effective(catalog: ModelCatalog) throws -> EffectiveSettings {
		resolveSettings(try read(), catalog: catalog)
	}

	public func observe() -> AsyncValueObservation<UserSettings?> {
		ValueObservation.tracking { db in try Self.read(db) }.values(in: database.writer)
	}

	/// Graph render settings, raw (its sanitizer ports with the graph view, M7).
	public func readRenderSettings() throws -> JSONValue? {
		try database.writer.read { db in try KV.get(Self.renderKey, db: db) }
	}

	public func writeRenderSettings(_ value: JSONValue) throws {
		try database.writer.write { db in try KV.set(Self.renderKey, value, db: db) }
	}
}

/// Port of src/store/prompt-overrides.ts: per-segment system-prompt override
/// bodies keyed by segment path ("system-prompt.md", "teacher/10-planning.md").
/// The on/off switch lives in settings (agent.prompts); composition is M5.
public struct PromptOverrideRepository: Sendable {
	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	/// Port of core/prompt-segments.ts isValidSegmentPath: "system-prompt.md",
	/// or `<prober|teacher|practice|shared>/<NN-name>.md` (FRAGMENT_RE
	/// `^\d+-[\w.-]+\.md$`; JS `\w` without the u flag is ASCII).
	public static func isValidSegmentPath(_ path: String) -> Bool {
		if path == "system-prompt.md" { return true }
		let parts = path.split(separator: "/", omittingEmptySubsequences: false)
		guard parts.count == 2, ["prober", "teacher", "practice", "shared"].contains(parts[0]) else { return false }
		return isFragmentName(Array(parts[1].utf8))
	}

	static func isFragmentName(_ u: [UInt8]) -> Bool {
		func isWordish(_ c: UInt8) -> Bool {
			(0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x5F || c == 0x2E || c == 0x2D
		}
		var i = 0
		while i < u.count, (0x30...0x39).contains(u[i]) { i += 1 }
		guard i > 0, i < u.count, u[i] == 0x2D else { return false }
		let rest = u[(i + 1)...]
		// [\w.-]+ then ".md": the greedy class also eats '.', so require ≥1 char before the suffix.
		guard rest.count >= 4, rest.suffix(3) == Array(".md".utf8)[...], rest.allSatisfy(isWordish) else { return false }
		return true
	}

	public func list() throws -> [String] {
		try database.writer.read { db in try String.fetchAll(db, sql: "SELECT segment_path FROM prompt_override ORDER BY segment_path") }
	}

	public func read(_ segmentPath: String) throws -> String? {
		guard Self.isValidSegmentPath(segmentPath) else { return nil }
		return try database.writer.read { db in try String.fetchOne(db, sql: "SELECT body FROM prompt_override WHERE segment_path = ?", arguments: [segmentPath]) }
	}

	public func write(_ segmentPath: String, body: String, now: Date = Date()) throws {
		guard Self.isValidSegmentPath(segmentPath) else { return }
		try database.writer.write { db in
			try db.execute(sql: """
				INSERT INTO prompt_override (segment_path, body, updated_at) VALUES (?, ?, ?)
				ON CONFLICT (segment_path) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
				""", arguments: [segmentPath, body, ISOClock.string(now)])
		}
	}

	public func delete(_ segmentPath: String) throws {
		try database.writer.write { db in try db.execute(sql: "DELETE FROM prompt_override WHERE segment_path = ?", arguments: [segmentPath]) }
	}

	/// Insert only when absent (the importer's skip-existing rule). True when inserted.
	@discardableResult
	public func insertIfAbsent(_ segmentPath: String, body: String, now: Date = Date()) throws -> Bool {
		guard Self.isValidSegmentPath(segmentPath) else { return false }
		return try database.writer.write { db in
			try db.execute(sql: "INSERT OR IGNORE INTO prompt_override (segment_path, body, updated_at) VALUES (?, ?, ?)", arguments: [segmentPath, body, ISOClock.string(now)])
			return db.changesCount > 0
		}
	}
}
