import Foundation
import GRDB
import LHCore

/// The steer delivery state (docs/native-macos-m5.md): a message sent while
/// a turn runs is written here PENDING, marked HANDED when the agent loop
/// takes it, and DELIVERED when its message lands in the record. Pending
/// rows survive a relaunch and become the next turn's input; a handed row
/// whose message never landed (a quit mid-turn) goes back to pending.
public struct SteerOutboxRepository: Sendable {
	public enum State: String, Sendable { case pending, handed, delivered }

	public let database: AppDatabase
	public init(_ database: AppDatabase) { self.database = database }

	/// Queue a steer (idempotent per message id).
	public func enqueue(_ message: Message, chatId: String, now: Date = Date()) throws {
		try database.writer.write { db in
			try db.execute(sql: """
				INSERT INTO steer_outbox (id, chat_id, message_json, state, created_at, updated_at) VALUES (?, ?, ?, 'pending', ?, ?)
				ON CONFLICT (id) DO NOTHING
				""", arguments: [message.id, chatId, message.json.serialized(), ISOClock.string(now), ISOClock.string(now)])
		}
	}

	/// The chat's steers in a state, oldest first.
	public func steers(chatId: String, state: State) throws -> [Message] {
		try database.writer.read { db in
			try String.fetchAll(db, sql: "SELECT message_json FROM steer_outbox WHERE chat_id = ? AND state = ? ORDER BY created_at, rowid",
				arguments: [chatId, state.rawValue])
				.compactMap { try? JSONValue.parse($0) }.compactMap(Message.init(json:))
		}
	}

	public func mark(_ ids: [String], _ state: State, now: Date = Date()) throws {
		guard !ids.isEmpty else { return }
		try database.writer.write { db in
			for id in ids {
				try db.execute(sql: "UPDATE steer_outbox SET state = ?, updated_at = ? WHERE id = ?", arguments: [state.rawValue, ISOClock.string(now), id])
			}
		}
	}

	/// Launch recovery: handed steers whose message never reached the
	/// record go back to pending; those that did are delivered.
	public func recover() throws {
		try database.writer.write { db in
			let handed = try Row.fetchAll(db, sql: "SELECT id, chat_id FROM steer_outbox WHERE state = 'handed'")
			for row in handed {
				let id: String = row["id"], chatId: String = row["chat_id"]
				let landed = try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE chat_id = ? AND id = ?", arguments: [chatId, id]) == true
				try db.execute(sql: "UPDATE steer_outbox SET state = ? WHERE id = ?", arguments: [landed ? "delivered" : "pending", id])
			}
		}
	}

	/// Remove a steer that is still pending (a job abort drops its result).
	/// Returns whether one was removed; a handed steer stays and may land.
	@discardableResult
	public func removePending(_ id: String) throws -> Bool {
		try database.writer.write { db in
			try db.execute(sql: "DELETE FROM steer_outbox WHERE id = ? AND state = 'pending'", arguments: [id])
			return db.changesCount > 0
		}
	}

	/// Chats with pending steers.
	public func chatsWithPending() throws -> [String] {
		try database.writer.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT chat_id FROM steer_outbox WHERE state = 'pending'") }
	}
}

extension SteerOutboxRepository {
	/// A deleted chat's steers go with it.
	public func deleteAll(chatId: String) throws {
		try database.writer.write { db in try db.execute(sql: "DELETE FROM steer_outbox WHERE chat_id = ?", arguments: [chatId]) }
	}
}
