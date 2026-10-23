import Foundation

/// pi-native record message (the TS app's `LhMessage` JSON) → the native
/// record (docs/native-macos-m1.md). Pure; LHImport runs it over every chat,
/// and the LHCore golden tests run it before the ported folds.
///
/// - `toolCall{id,name,arguments}` → `tool_use{id,name,input}`
/// - Anthropic-signed thinking → `thinking{thinking,signature}`; redacted →
///   `redacted_thinking{data}`; any other provider's thinking → unsigned
///   `thinking{thinking}` (shown in the UI, dropped on the wire)
/// - `image{data,mimeType}` → `image{source:{type:"base64",…}}`
/// - string content → one text block
/// - model stamps: bare ids for provider "anthropic", "provider:id" otherwise
public enum LegacyRecordConversion {
	public static func message(fromPi json: JSONValue) -> Message? {
		guard let role = json["role"]?.stringValue else { return nil }
		let id = json["id"]?.stringValue ?? ""
		let ts = json["timestamp"]?.intValue ?? 0
		switch role {
		case "user":
			return Message(id: id, timestamp: ts, body: .user(UserBody(content: blocks(json["content"], anthropicSigned: false))))
		case "assistant":
			let provider = json["provider"]?.stringValue ?? ""
			let model = json["model"]?.stringValue ?? ""
			let usage = json["usage"].map {
				MessageUsage(input: $0["input"]?.intValue ?? 0, output: $0["output"]?.intValue ?? 0, cacheRead: $0["cacheRead"]?.intValue ?? 0, cacheWrite: $0["cacheWrite"]?.intValue ?? 0)
			}
			return Message(id: id, timestamp: ts, body: .assistant(AssistantBody(
				content: blocks(json["content"], anthropicSigned: provider == "anthropic"),
				model: modelRef(provider: provider, id: model),
				stopReason: stopReason(json["stopReason"]?.stringValue),
				usage: usage,
				errorMessage: json["errorMessage"]?.stringValue)))
		case "toolResult":
			return Message(id: id, timestamp: ts, body: .toolResult(ToolResultBody(
				toolUseId: json["toolCallId"]?.stringValue ?? "",
				toolName: json["toolName"]?.stringValue ?? "",
				content: blocks(json["content"], anthropicSigned: false),
				isError: json["isError"]?.boolValue ?? false,
				details: json["details"]?.nonNull)))
		case "custom":
			guard let kind = json["customType"]?.stringValue.flatMap(MarkerKind.init(rawValue:)) else { return nil }
			let content: String
			switch json["content"] {
			case .string(let s)?: content = s
			case .array(let a)?: content = a.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
			default: content = ""
			}
			return Message(id: id, timestamp: ts, body: .marker(MarkerBody(
				kind: kind, content: content, display: json["display"]?.boolValue ?? true, details: json["details"] ?? .null)))
		default:
			return nil
		}
	}

	public static func messages(fromPi array: [JSONValue]) -> [Message] {
		array.compactMap(message(fromPi:))
	}

	/// "anthropic" + "claude-opus-5-5" → "claude-opus-5-5"; others keep "provider:id".
	public static func modelRef(provider: String, id: String) -> String {
		if provider == "anthropic" || provider.isEmpty { return id }
		return "\(provider):\(id)"
	}

	/// pi StopReason → Anthropic stop_reason (the app's own aborted/error kept).
	public static func stopReason(_ pi: String?) -> String {
		switch pi {
		case "stop": "end_turn"
		case "length": "max_tokens"
		case "toolUse": "tool_use"
		case "error": "error"
		case "aborted": "aborted"
		case let other?: other
		case nil: "end_turn"
		}
	}

	static func blocks(_ content: JSONValue?, anthropicSigned: Bool) -> [Block] {
		switch content {
		case .string(let s)?:
			return [.text(s)]
		case .array(let items)?:
			return items.compactMap { block($0, anthropicSigned: anthropicSigned) }
		default:
			return []
		}
	}

	static func block(_ b: JSONValue, anthropicSigned: Bool) -> Block? {
		switch b["type"]?.stringValue {
		case "text":
			return .text(b["text"]?.stringValue ?? "")
		case "thinking":
			let text = b["thinking"]?.stringValue ?? ""
			let sig = b["thinkingSignature"]?.stringValue
			if anthropicSigned, b["redacted"]?.boolValue == true, let sig {
				return Block(raw: ["type": "redacted_thinking", "data": .string(sig)])
			}
			return .thinking(text, signature: anthropicSigned ? sig : nil)
		case "toolCall":
			return .toolUse(id: b["id"]?.stringValue ?? "", name: b["name"]?.stringValue ?? "", input: b["arguments"] ?? .object(JSONObject()))
		case "image":
			return .image(mediaType: b["mimeType"]?.stringValue ?? "", base64: b["data"]?.stringValue ?? "")
		default:
			return Block(raw: b)
		}
	}
}
