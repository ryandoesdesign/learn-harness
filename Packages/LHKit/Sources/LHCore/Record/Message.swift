import Foundation

/// The session record's message (docs/native-macos-m1.md, "The message
/// record"): one row per message, Anthropic-native content blocks stored
/// verbatim. Mirrors the TS record's four roles (pi user / assistant /
/// toolResult + the app's custom markers) so every fold ports one-to-one.
public struct Message: Sendable, Hashable, Identifiable {
	public var id: String
	/// Epoch milliseconds (JS `Date.now()`).
	public var timestamp: Int
	public var body: Body

	public enum Body: Sendable, Hashable {
		case user(UserBody)
		case assistant(AssistantBody)
		case toolResult(ToolResultBody)
		case marker(MarkerBody)
	}

	public init(id: String, timestamp: Int, body: Body) {
		self.id = id
		self.timestamp = timestamp
		self.body = body
	}

	public var role: Role {
		switch body {
		case .user: .user
		case .assistant: .assistant
		case .toolResult: .toolResult
		case .marker: .marker
		}
	}

	public enum Role: String, Sendable, Hashable, Codable {
		case user, assistant, toolResult, marker
	}

	public var user: UserBody? { if case .user(let b) = body { return b }; return nil }
	public var assistant: AssistantBody? { if case .assistant(let b) = body { return b }; return nil }
	public var toolResult: ToolResultBody? { if case .toolResult(let b) = body { return b }; return nil }
	public var marker: MarkerBody? { if case .marker(let b) = body { return b }; return nil }
}

public struct UserBody: Sendable, Hashable {
	public var content: [Block]
	public init(content: [Block]) { self.content = content }
}

public struct AssistantBody: Sendable, Hashable {
	public var content: [Block]
	/// Bare Anthropic id ("claude-opus-5-5"); foreign imports keep "provider:id".
	public var model: String
	/// Anthropic `stop_reason` ("end_turn", "tool_use", "max_tokens",
	/// "pause_turn", "refusal", "stop_sequence") or the app's own
	/// "aborted" / "error".
	public var stopReason: String
	public var usage: MessageUsage?
	public var errorMessage: String?
	/// The API's `stop_details` (refusals: category + explanation).
	public var stopDetails: JSONValue?

	public init(content: [Block], model: String, stopReason: String, usage: MessageUsage? = nil, errorMessage: String? = nil, stopDetails: JSONValue? = nil) {
		self.content = content
		self.model = model
		self.stopReason = stopReason
		self.usage = usage
		self.errorMessage = errorMessage
		self.stopDetails = stopDetails
	}

	/// The `tool_use` blocks, in order.
	public var toolUses: [ToolUse] { content.compactMap(\.toolUse) }
}

/// The token stamp a model call leaves on its assistant message (pi's
/// `usage`; Anthropic's `usage` with input EXCLUDING the cached portion).
public struct MessageUsage: Sendable, Hashable {
	public var input: Int
	public var output: Int
	public var cacheRead: Int
	public var cacheWrite: Int
	public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
		self.input = input
		self.output = output
		self.cacheRead = cacheRead
		self.cacheWrite = cacheWrite
	}
}

public struct ToolResultBody: Sendable, Hashable {
	public var toolUseId: String
	public var toolName: String
	/// Model-facing content (text / image blocks).
	public var content: [Block]
	public var isError: Bool
	/// The UI payload — never model-visible.
	public var details: JSONValue?

	public init(toolUseId: String, toolName: String, content: [Block], isError: Bool, details: JSONValue? = nil) {
		self.toolUseId = toolUseId
		self.toolName = toolName
		self.content = content
		self.isError = isError
		self.details = details
	}

	/// The first text block's text.
	public var firstText: String? { content.lazy.compactMap(\.text).first }
}

public enum MarkerKind: String, Sendable, Hashable, Codable, CaseIterable {
	case graphContext = "graph-context"
	case probeHandoff = "probe-handoff"
	case subagentSteer = "subagent-steer"
	case subagentAbort = "subagent-abort"
	case planBlock = "plan-block"
	case practiceThinking = "practice-thinking"
	case practiceNext = "practice-next"
	case problemDismissed = "problem-dismissed"
	case compaction
}

public struct MarkerBody: Sendable, Hashable {
	public var kind: MarkerKind
	/// The model-facing text ("" for UI-only markers).
	public var content: String
	public var display: Bool
	/// The UI payload — per kind, never model-visible.
	public var details: JSONValue

	public init(kind: MarkerKind, content: String, display: Bool = true, details: JSONValue) {
		self.kind = kind
		self.content = content
		self.display = display
		self.details = details
	}
}

// MARK: - Blocks

/// One Anthropic content block, kept as its raw JSON (bytes untouched) with
/// typed views over the shapes the app reads.
public struct Block: Sendable, Hashable {
	public var raw: JSONValue

	public init(raw: JSONValue) { self.raw = raw }

	public var type: String { raw["type"]?.stringValue ?? "" }

	public static func text(_ text: String) -> Block { Block(raw: ["type": "text", "text": .string(text)]) }

	public static func thinking(_ thinking: String, signature: String?) -> Block {
		var o = JSONObject(["type": "thinking", "thinking": .string(thinking)])
		if let signature { o["signature"] = .string(signature) }
		return Block(raw: .object(o))
	}

	public static func toolUse(id: String, name: String, input: JSONValue) -> Block {
		Block(raw: ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
	}

	public static func image(mediaType: String, base64: String) -> Block {
		Block(raw: ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)]])
	}

	/// `text` blocks' text.
	public var text: String? { type == "text" ? raw["text"]?.stringValue : nil }

	/// `thinking` blocks (signature absent for foreign-provider imports).
	public var thinking: (text: String, signature: String?)? {
		guard type == "thinking" else { return nil }
		return (raw["thinking"]?.stringValue ?? "", raw["signature"]?.stringValue)
	}

	public var isRedactedThinking: Bool { type == "redacted_thinking" }

	/// Client `tool_use` blocks.
	public var toolUse: ToolUse? {
		guard type == "tool_use", let id = raw["id"]?.stringValue, let name = raw["name"]?.stringValue else { return nil }
		return ToolUse(id: id, name: name, input: raw["input"] ?? .object(JSONObject()))
	}

	/// Server `server_tool_use` blocks (web_search / web_fetch).
	public var serverToolUse: ToolUse? {
		guard type == "server_tool_use", let id = raw["id"]?.stringValue, let name = raw["name"]?.stringValue else { return nil }
		return ToolUse(id: id, name: name, input: raw["input"] ?? .object(JSONObject()))
	}

	public var image: (mediaType: String, base64: String)? {
		guard type == "image", let src = raw["source"], src["type"]?.stringValue == "base64" else { return nil }
		return (src["media_type"]?.stringValue ?? "", src["data"]?.stringValue ?? "")
	}
}

public struct ToolUse: Sendable, Hashable {
	public var id: String
	public var name: String
	public var input: JSONValue
	public init(id: String, name: String, input: JSONValue) {
		self.id = id
		self.name = name
		self.input = input
	}
}

// MARK: - Record JSON envelope

extension Message {
	/// The flat JSON envelope (fixtures, debug dumps; LHStore splits it into
	/// columns). Keys: id, role, timestamp + the body's fields.
	public var json: JSONValue {
		var o = JSONObject(["id": .string(id), "role": .string(role.rawValue), "timestamp": .number(timestamp)])
		switch body {
		case .user(let u):
			o["content"] = .array(u.content.map(\.raw))
		case .assistant(let a):
			o["content"] = .array(a.content.map(\.raw))
			o["model"] = .string(a.model)
			o["stopReason"] = .string(a.stopReason)
			if let u = a.usage {
				o["usage"] = ["input": .number(u.input), "output": .number(u.output), "cacheRead": .number(u.cacheRead), "cacheWrite": .number(u.cacheWrite)]
			}
			if let e = a.errorMessage { o["errorMessage"] = .string(e) }
			if let d = a.stopDetails { o["stopDetails"] = d }
		case .toolResult(let t):
			o["toolUseId"] = .string(t.toolUseId)
			o["toolName"] = .string(t.toolName)
			o["content"] = .array(t.content.map(\.raw))
			o["isError"] = .bool(t.isError)
			if let d = t.details { o["details"] = d }
		case .marker(let m):
			o["customType"] = .string(m.kind.rawValue)
			o["content"] = .string(m.content)
			o["display"] = .bool(m.display)
			o["details"] = m.details
		}
		return .object(o)
	}

	public init?(json: JSONValue) {
		guard let id = json["id"]?.stringValue, let role = json["role"]?.stringValue.flatMap(Role.init(rawValue:)) else { return nil }
		let ts = json["timestamp"]?.intValue ?? 0
		let blocks = (json["content"]?.arrayValue ?? []).map(Block.init(raw:))
		switch role {
		case .user:
			self.init(id: id, timestamp: ts, body: .user(UserBody(content: blocks)))
		case .assistant:
			let usage = json["usage"].map {
				MessageUsage(input: $0["input"]?.intValue ?? 0, output: $0["output"]?.intValue ?? 0, cacheRead: $0["cacheRead"]?.intValue ?? 0, cacheWrite: $0["cacheWrite"]?.intValue ?? 0)
			}
			self.init(id: id, timestamp: ts, body: .assistant(AssistantBody(
				content: blocks, model: json["model"]?.stringValue ?? "", stopReason: json["stopReason"]?.stringValue ?? "end_turn",
				usage: usage, errorMessage: json["errorMessage"]?.stringValue, stopDetails: json["stopDetails"]?.nonNull)))
		case .toolResult:
			self.init(id: id, timestamp: ts, body: .toolResult(ToolResultBody(
				toolUseId: json["toolUseId"]?.stringValue ?? "", toolName: json["toolName"]?.stringValue ?? "",
				content: blocks, isError: json["isError"]?.boolValue ?? false, details: json["details"])))
		case .marker:
			guard let kind = json["customType"]?.stringValue.flatMap(MarkerKind.init(rawValue:)) else { return nil }
			self.init(id: id, timestamp: ts, body: .marker(MarkerBody(
				kind: kind, content: json["content"]?.stringValue ?? "", display: json["display"]?.boolValue ?? true,
				details: json["details"] ?? .null)))
		}
	}
}

// MARK: - id minting

public enum MessageID {
	/// The app-wide message id shape: `msg_<ms base36>_<8 hex>`.
	public static func mint(now: Date = Date()) -> String {
		let ms = Int(now.timeIntervalSince1970 * 1000)
		return "msg_\(String(ms, radix: 36))_\(UUID().uuidString.lowercased().prefix(8))"
	}

	public static func nowMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}
