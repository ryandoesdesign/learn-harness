import Foundation
import LHCore

/// Builds Messages API SSE bodies for `ScriptedTransport` — the shapes the
/// API streams (message_start → content blocks with deltas → message_delta
/// → message_stop), so agent tests run with no network and no key.
public enum ScriptedSSE {
	public enum Piece: Sendable {
		case text(String)
		/// Thinking text (optionally split into deltas) plus its signature.
		case thinking(String, signature: String)
		case redactedThinking(String)
		/// A client tool call; `json` is the raw streamed input text.
		case toolUse(id: String, name: String, json: String)
		case serverToolUse(id: String, name: String, json: String)
		/// Any block delivered whole at content_block_start (server results, fallback markers).
		case raw(JSONValue)
	}

	public static func frame(_ event: String, _ data: JSONValue) -> String {
		"event: \(event)\ndata: \(data.serialized())\n\n"
	}

	/// A whole message stream. `chunk` splits text/thinking/json into deltas of that size.
	public static func message(id: String = "msg_test", model: String = "claude-opus-5-5", _ pieces: [Piece],
		stopReason: String = "end_turn", stopDetails: JSONValue? = nil,
		usage: JSONValue = ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
		finalUsage: JSONValue? = nil, chunk: Int = 8, inputTransformations: [JSONValue]? = nil) -> String
	{
		var startMessage = JSONObject([
			"id": .string(id), "type": "message", "role": "assistant", "model": .string(model), "content": [],
			"stop_reason": nil, "usage": usage,
		])
		if let t = inputTransformations { startMessage["input_transformations"] = .array(t) }
		var out = frame("message_start", ["type": "message_start", "message": .object(startMessage)])
		out += frame("ping", ["type": "ping"])
		for (i, piece) in pieces.enumerated() {
			let idx = JSONValue.number(i)
			switch piece {
			case .text(let t):
				out += frame("content_block_start", ["type": "content_block_start", "index": idx, "content_block": ["type": "text", "text": ""]])
				for part in split(t, chunk) {
					out += frame("content_block_delta", ["type": "content_block_delta", "index": idx, "delta": ["type": "text_delta", "text": .string(part)]])
				}
			case .thinking(let t, let sig):
				out += frame("content_block_start", ["type": "content_block_start", "index": idx, "content_block": ["type": "thinking", "thinking": "", "signature": ""]])
				for part in split(t, chunk) {
					out += frame("content_block_delta", ["type": "content_block_delta", "index": idx, "delta": ["type": "thinking_delta", "thinking": .string(part)]])
				}
				out += frame("content_block_delta", ["type": "content_block_delta", "index": idx, "delta": ["type": "signature_delta", "signature": .string(sig)]])
			case .redactedThinking(let data):
				out += frame("content_block_start", ["type": "content_block_start", "index": idx, "content_block": ["type": "redacted_thinking", "data": .string(data)]])
			case .toolUse(let id, let name, let json), .serverToolUse(let id, let name, let json):
				let type = { if case .toolUse = piece { return "tool_use" }; return "server_tool_use" }()
				out += frame("content_block_start", ["type": "content_block_start", "index": idx, "content_block": ["type": .string(type), "id": .string(id), "name": .string(name), "input": [:]]])
				for part in split(json, chunk) {
					out += frame("content_block_delta", ["type": "content_block_delta", "index": idx, "delta": ["type": "input_json_delta", "partial_json": .string(part)]])
				}
			case .raw(let block):
				out += frame("content_block_start", ["type": "content_block_start", "index": idx, "content_block": block])
			}
			out += frame("content_block_stop", ["type": "content_block_stop", "index": idx])
		}
		var delta = JSONObject(["stop_reason": .string(stopReason), "stop_sequence": nil])
		if let stopDetails { delta["stop_details"] = stopDetails }
		out += frame("message_delta", ["type": "message_delta", "delta": .object(delta), "usage": finalUsage ?? ["output_tokens": usage["output_tokens"] ?? 5]])
		out += frame("message_stop", ["type": "message_stop"])
		return out
	}

	/// An `error` event (overloaded, api_error) as the API streams it.
	public static func errorEvent(type: String = "overloaded_error", message: String = "Overloaded") -> String {
		frame("error", ["type": "error", "error": ["type": .string(type), "message": .string(message)]])
	}

	static func split(_ s: String, _ n: Int) -> [String] {
		guard n > 0, !s.isEmpty else { return [s] }
		var out: [String] = []
		var current = ""
		for ch in s {
			current.append(ch)
			if current.count >= n {
				out.append(current)
				current = ""
			}
		}
		if !current.isEmpty { out.append(current) }
		return out
	}
}
