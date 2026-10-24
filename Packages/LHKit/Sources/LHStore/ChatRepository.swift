import Foundation
import GRDB
import LHCore

/// Port of src/store/chats.ts over SQLite. Messages are append-only rows;
/// the steer cards' invert toggle lives in `message_ui`, layered over
/// `details.ui` at read time.
public struct ChatRepository: Sendable {
	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	public enum Origin: String, Sendable { case native, `import` }

	// MARK: Writes

	/// A fresh chat (id `chat_<ms36>_<8hex>`, blank title → "Untitled session").
	@discardableResult
	public func createChat(title: String, kind: ChatKind? = nil, now: Date = Date()) throws -> ChatRecord {
		let stamp = ISOClock.string(now)
		let ms = Int(now.timeIntervalSince1970 * 1000)
		let record = ChatRecord(
			id: "chat_\(String(ms, radix: 36))_\(UUID().uuidString.lowercased().prefix(8))",
			title: Self.cleanTitle(title), createdAt: stamp, updatedAt: stamp, messages: [],
			kind: kind == .practice ? .practice : nil, version: CURRENT_CHAT_VERSION)
		try insert(record, origin: .native)
		return record
	}

	/// Insert a whole record (the importer's path; also createChat's).
	public func insert(_ record: ChatRecord, origin: Origin) throws {
		guard validId(record.id) else { throw StoreError.invalidId(record.id) }
		try database.writer.write { db in
			try db.execute(sql: """
				INSERT INTO chat (id, title, kind, created_at, updated_at, settings_json, tree_json, origin, version)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
				""", arguments: [record.id, record.title, record.kind?.rawValue, record.createdAt, record.updatedAt,
					try record.settings.map { try JSONCodec.encode($0).serialized() },
					try record.tree.map { try JSONCodec.encode($0).serialized() },
					origin.rawValue, CURRENT_CHAT_VERSION])
			for (seq, m) in record.messages.enumerated() {
				try MessageRow.insert(m, chatId: record.id, seq: seq, db: db)
			}
			for turn in record.turns ?? [] { try Self.insertTurn(turn, chatId: record.id, db: db) }
			for run in record.extractions ?? [] { try UsageRows.insertRun(run, ownerKind: "chat", ownerId: record.id, db: db) }
		}
	}

	/// Append messages to the record (the only message write there is).
	/// Ids already present are skipped — appends are idempotent.
	public func append(_ messages: [Message], to chatId: String, now: Date = Date()) throws {
		try database.writer.write { db in
			guard try Self.exists(chatId, db) else { throw StoreError.notFound(chatId) }
			var seq = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq) + 1, 0) FROM message WHERE chat_id = ?", arguments: [chatId]) ?? 0
			for m in messages {
				if try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE chat_id = ? AND id = ?", arguments: [chatId, m.id]) == true { continue }
				try MessageRow.insert(m, chatId: chatId, seq: seq, db: db)
				seq += 1
			}
			try db.execute(sql: "UPDATE chat SET updated_at = ?, version = ? WHERE id = ?", arguments: [ISOClock.string(now), CURRENT_CHAT_VERSION, chatId])
		}
	}

	public func saveTree(_ tree: PlanTree, chatId: String) throws {
		try update(chatId, sql: "UPDATE chat SET tree_json = ? WHERE id = ?", [try JSONCodec.encode(tree).serialized(), chatId])
	}

	public func saveSettings(_ settings: ChatSettings, chatId: String) throws {
		try update(chatId, sql: "UPDATE chat SET settings_json = ? WHERE id = ?", [try JSONCodec.encode(settings).serialized(), chatId])
	}

	public func rename(_ chatId: String, title: String) throws {
		try update(chatId, sql: "UPDATE chat SET title = ? WHERE id = ?", [Self.cleanTitle(title), chatId])
	}

	/// Delete a chat and everything it owns. False when it never existed.
	/// M7: its coverage and checkpoint rows go too (TS drops them in both
	/// delete modes); a traces delete runs deleteChatTraces first, in the
	/// same transaction (GraphTransaction.deleteChat).
	@discardableResult
	public func delete(_ chatId: String) throws -> Bool {
		try database.writer.write { db in try Self.deleteRows(chatId, db) }
	}

	static func deleteRows(_ chatId: String, _ db: Database) throws -> Bool {
		try db.execute(sql: "DELETE FROM usage_step WHERE owner_kind = 'turn' AND owner_id IN (SELECT id FROM turn WHERE chat_id = ?)", arguments: [chatId])
		try UsageRows.deleteRuns(ownerKind: "chat", ownerId: chatId, db: db)
		try db.execute(sql: "DELETE FROM coverage WHERE chat_id = ?", arguments: [chatId])
		try db.execute(sql: "DELETE FROM graph_session WHERE chat_id = ?", arguments: [chatId])
		try db.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [chatId])
		return db.changesCount > 0
	}

	/// Idempotent per turn id.
	public func appendTurnUsage(_ turn: TurnUsage, chatId: String) throws {
		try database.writer.write { db in
			guard try Self.exists(chatId, db) else { throw StoreError.notFound(chatId) }
			if try Bool.fetchOne(db, sql: "SELECT 1 FROM turn WHERE id = ?", arguments: [turn.id]) == true { return }
			try Self.insertTurn(turn, chatId: chatId, db: db)
		}
	}

	/// Idempotent per startedAt.
	public func appendExtractionUsage(_ run: ExtractionRunUsage, chatId: String) throws {
		try database.writer.write { db in
			guard try Self.exists(chatId, db) else { throw StoreError.notFound(chatId) }
			try UsageRows.insertRun(run, ownerKind: "chat", ownerId: chatId, db: db)
		}
	}

	/// The demo/visual steer card's invert toggle (only those kinds carry it).
	public func setArtifactInverted(_ inverted: Bool, messageId: String, chatId: String, now: Date = Date()) throws {
		try database.writer.write { db in
			guard let row = try Row.fetchOne(db, sql: "SELECT custom_type, details_json FROM message WHERE chat_id = ? AND id = ?", arguments: [chatId, messageId]) else {
				throw StoreError.notFound(messageId)
			}
			let details = try (row["details_json"] as String?).map(JSONValue.parse)
			let kind = details?["kind"]?.stringValue
			guard row["custom_type"] as String? == MarkerKind.subagentSteer.rawValue || row["custom_type"] as String? == MarkerKind.subagentAbort.rawValue,
				kind == "demo" || kind == "visual" else { return }
			try db.execute(sql: """
				INSERT INTO message_ui (chat_id, message_id, inverted, updated_at) VALUES (?, ?, ?, ?)
				ON CONFLICT (chat_id, message_id) DO UPDATE SET inverted = excluded.inverted, updated_at = excluded.updated_at
				""", arguments: [chatId, messageId, inverted, ISOClock.string(now)])
		}
	}

	// MARK: Reads

	public func get(_ chatId: String) throws -> ChatRecord? {
		try database.writer.read { db in try Self.fetchRecord(chatId, db) }
	}

	public func contains(_ chatId: String) throws -> Bool {
		try database.writer.read { db in try Self.exists(chatId, db) }
	}

	/// The sidebar summaries, most recently updated first.
	public func summaries() throws -> [ChatSummary] {
		try database.writer.read { db in try Self.fetchSummaries(db) }
	}

	/// Full-text search over message text → matching chat ids (best first).
	public func search(_ query: String) throws -> [String] {
		let terms = query.split(whereSeparator: \.isWhitespace).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
		guard !terms.isEmpty else { return [] }
		return try database.writer.read { db in
			try String.fetchAll(db, sql: "SELECT chat_id FROM message_fts WHERE message_fts MATCH ? GROUP BY chat_id ORDER BY MIN(rank)", arguments: [terms.joined(separator: " ")])
		}
	}

	// MARK: Observation

	/// The summaries, re-emitted on every committed change.
	public func observeSummaries() -> AsyncValueObservation<[ChatSummary]> {
		ValueObservation.tracking { db in try Self.fetchSummaries(db) }.values(in: database.writer)
	}

	public func observe(_ chatId: String) -> AsyncValueObservation<ChatRecord?> {
		ValueObservation.tracking { db in try Self.fetchRecord(chatId, db) }.values(in: database.writer)
	}

	// MARK: Internals

	static func cleanTitle(_ title: String) -> String {
		let t = title.jsTrimmed
		return t.isEmpty ? "Untitled session" : t
	}

	static func exists(_ id: String, _ db: Database) throws -> Bool {
		try Bool.fetchOne(db, sql: "SELECT 1 FROM chat WHERE id = ?", arguments: [id]) == true
	}

	private func update(_ chatId: String, sql: String, _ args: StatementArguments) throws {
		try database.writer.write { db in
			try db.execute(sql: sql, arguments: args)
			if db.changesCount == 0 { throw StoreError.notFound(chatId) }
		}
	}

	static func insertTurn(_ turn: TurnUsage, chatId: String, db: Database) throws {
		let seq = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq) + 1, 0) FROM turn WHERE chat_id = ?", arguments: [chatId]) ?? 0
		try db.execute(sql: "INSERT INTO turn (id, chat_id, seq, message_id, at, model) VALUES (?, ?, ?, ?, ?, ?)",
			arguments: [turn.id, chatId, seq, turn.messageId, turn.at, turn.model])
		try UsageRows.insertSteps(turn.steps, ownerKind: "turn", ownerId: turn.id, model: turn.model, db: db)
	}

	static func fetchMessages(_ chatId: String, _ db: Database) throws -> [Message] {
		let ui = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT message_id, inverted FROM message_ui WHERE chat_id = ?", arguments: [chatId])
			.map { ($0["message_id"] as String, $0["inverted"] as Bool) })
		return try Row.fetchAll(db, sql: "SELECT * FROM message WHERE chat_id = ? ORDER BY seq", arguments: [chatId]).map { row in
			var m = try MessageRow.decode(row)
			if let inverted = ui[m.id], var marker = m.marker {
				var uiObj = marker.details["ui"]?.objectValue ?? JSONObject()
				uiObj["inverted"] = .bool(inverted)
				marker.details["ui"] = .object(uiObj)
				m.body = .marker(marker)
			}
			return m
		}
	}

	static func fetchRecord(_ chatId: String, _ db: Database) throws -> ChatRecord? {
		guard let row = try Row.fetchOne(db, sql: "SELECT * FROM chat WHERE id = ?", arguments: [chatId]) else { return nil }
		let turns = try Row.fetchAll(db, sql: "SELECT * FROM turn WHERE chat_id = ? ORDER BY seq", arguments: [chatId]).map { t in
			let id: String = t["id"]
			return TurnUsage(id: id, messageId: t["message_id"], at: t["at"], model: t["model"], steps: try UsageRows.steps(ownerKind: "turn", ownerId: id, db: db))
		}
		let runs = try UsageRows.runs(ownerKind: "chat", ownerId: chatId, db: db)
		return ChatRecord(
			id: row["id"], title: row["title"], createdAt: row["created_at"], updatedAt: row["updated_at"],
			messages: try fetchMessages(chatId, db),
			kind: (row["kind"] as String?).flatMap(ChatKind.init(rawValue:)),
			tree: try (row["tree_json"] as String?).map { try JSONCodec.decode(PlanTree.self, from: JSONValue.parse($0)) },
			turns: turns.isEmpty ? nil : turns,
			extractions: runs.isEmpty ? nil : runs,
			settings: try (row["settings_json"] as String?).map { try JSONCodec.decode(ChatSettings.self, from: JSONValue.parse($0)) },
			version: row["version"])
	}

	static func fetchSummaries(_ db: Database) throws -> [ChatSummary] {
		let rows = try Row.fetchAll(db, sql: "SELECT * FROM chat")
		var out: [ChatSummary] = []
		for row in rows {
			let id: String = row["id"]
			let messages = try fetchMessages(id, db)
			let kind = (row["kind"] as String?).flatMap(ChatKind.init(rawValue:)) ?? .teach
			out.append(ChatSummary(
				id: id, title: row["title"], createdAt: row["created_at"], updatedAt: row["updated_at"], kind: kind,
				messageCount: messages.count, phase: phaseAt3Lh(messages),
				pendingQuestion: danglingQuestionOf(messages) != nil,
				pendingProblem: kind == .practice && activeProblemOf(messages) != nil,
				settings: try (row["settings_json"] as String?).map { try JSONCodec.decode(ChatSettings.self, from: JSONValue.parse($0)) }))
		}
		// updatedAt are ISO strings: code-unit order == chronological (localeCompare in TS agrees on these).
		return out.sorted { $1.updatedAt.utf16.lexicographicallyPrecedes($0.updatedAt.utf16) }
	}
}
