import Foundation
import GRDB
import LHCore

/// Message ⇄ `message` row. payload_json holds the content blocks verbatim
/// (a marker's model-facing text as a JSON string); details_json the UI
/// payload; the remaining columns are queryable projections.
enum MessageRow {
	static func insert(_ m: Message, chatId: String, seq: Int, db: Database) throws {
		var customType: String?, toolCallId: String?, toolName: String?, model: String?, stopReason: String?
		var details: String?, usage: String?, errorMessage: String?, isError: Bool?, display: Bool?
		let payload: JSONValue
		switch m.body {
		case .user(let u):
			payload = .array(u.content.map(\.raw))
		case .assistant(let a):
			payload = .array(a.content.map(\.raw))
			model = a.model
			stopReason = a.stopReason
			errorMessage = a.errorMessage
			usage = a.usage.map { u -> String in
				JSONValue.object(JSONObject(["input": .number(u.input), "output": .number(u.output), "cacheRead": .number(u.cacheRead), "cacheWrite": .number(u.cacheWrite)])).serialized()
			}
		case .toolResult(let t):
			payload = .array(t.content.map(\.raw))
			toolCallId = t.toolUseId
			toolName = t.toolName
			isError = t.isError
			details = t.details?.serialized()
		case .marker(let k):
			payload = .string(k.content)
			customType = k.kind.rawValue
			display = k.display
			details = k.details.serialized()
		}
		try db.execute(sql: """
			INSERT INTO message (chat_id, seq, id, role, custom_type, tool_call_id, tool_name, model, stop_reason,
				timestamp, payload_json, details_json, usage_json, error_message, is_error, display)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			""", arguments: [chatId, seq, m.id, m.role.rawValue, customType, toolCallId, toolName, model, stopReason,
				m.timestamp, payload.serialized(), details, usage, errorMessage, isError, display])
		let body = searchText(m)
		if !body.isEmpty {
			try db.execute(sql: "INSERT INTO message_fts (chat_id, message_id, body) VALUES (?, ?, ?)", arguments: [chatId, m.id, body])
		}
	}

	static func decode(_ row: Row) throws -> Message {
		let id: String = row["id"]
		let ts: Int = row["timestamp"]
		let payload = try JSONValue.parse(row["payload_json"] as String)
		let details: JSONValue? = try (row["details_json"] as String?).map(JSONValue.parse)
		let blocks = (payload.arrayValue ?? []).map(Block.init(raw:))
		switch Message.Role(rawValue: row["role"]) {
		case .user?:
			return Message(id: id, timestamp: ts, body: .user(UserBody(content: blocks)))
		case .assistant?:
			let usage = try (row["usage_json"] as String?).map(JSONValue.parse).map {
				MessageUsage(input: $0["input"]?.intValue ?? 0, output: $0["output"]?.intValue ?? 0, cacheRead: $0["cacheRead"]?.intValue ?? 0, cacheWrite: $0["cacheWrite"]?.intValue ?? 0)
			}
			return Message(id: id, timestamp: ts, body: .assistant(AssistantBody(
				content: blocks, model: row["model"] ?? "", stopReason: row["stop_reason"] ?? "end_turn", usage: usage, errorMessage: row["error_message"])))
		case .toolResult?:
			return Message(id: id, timestamp: ts, body: .toolResult(ToolResultBody(
				toolUseId: row["tool_call_id"] ?? "", toolName: row["tool_name"] ?? "", content: blocks,
				isError: row["is_error"] ?? false, details: details)))
		case .marker?:
			guard let kind = MarkerKind(rawValue: row["custom_type"] ?? "") else { throw StoreError.corrupt("message \(id): unknown marker kind") }
			return Message(id: id, timestamp: ts, body: .marker(MarkerBody(
				kind: kind, content: payload.stringValue ?? "", display: row["display"] ?? true, details: details ?? .null)))
		case nil:
			throw StoreError.corrupt("message \(id): unknown role")
		}
	}

	/// The searchable text: text blocks, marker content, tool-result text.
	static func searchText(_ m: Message) -> String {
		switch m.body {
		case .user(let u): u.content.compactMap(\.text).joined(separator: "\n")
		case .assistant(let a): a.content.compactMap(\.text).joined(separator: "\n")
		case .toolResult(let t): t.content.compactMap(\.text).joined(separator: "\n")
		case .marker(let k): k.content
		}
	}
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
	case notFound(String)
	case corrupt(String)
	case invalidId(String)
	case newerVersion(String)

	public var description: String {
		switch self {
		case .notFound(let s): "Not found: \(s)"
		case .corrupt(let s): "Corrupt record: \(s)"
		case .invalidId(let s): "Invalid id: \(s)"
		case .newerVersion(let s): s
		}
	}
}

/// The TS id law: `[A-Za-z0-9_-]+`.
func validId(_ id: String) -> Bool {
	!id.isEmpty && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
}
