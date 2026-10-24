import Foundation
import LHCore

/// One Messages API stream event (the `data:` payload of an SSE frame).
public enum StreamEvent: Sendable, Hashable {
	case messageStart(message: JSONValue)
	case contentBlockStart(index: Int, block: JSONValue)
	case contentBlockDelta(index: Int, delta: JSONValue)
	case contentBlockStop(index: Int)
	case messageDelta(delta: JSONValue, usage: JSONValue?)
	case messageStop
	case ping
	/// A mid-stream API error (`{"type":"error","error":{…}}`).
	case error(type: String, message: String)
	/// Unknown event types pass through (forward-compat).
	case other(JSONValue)

	public init(json v: JSONValue) {
		switch v["type"]?.stringValue {
		case "message_start": self = .messageStart(message: v["message"] ?? .null)
		case "content_block_start": self = .contentBlockStart(index: v["index"]?.intValue ?? 0, block: v["content_block"] ?? .null)
		case "content_block_delta": self = .contentBlockDelta(index: v["index"]?.intValue ?? 0, delta: v["delta"] ?? .null)
		case "content_block_stop": self = .contentBlockStop(index: v["index"]?.intValue ?? 0)
		case "message_delta": self = .messageDelta(delta: v["delta"] ?? .null, usage: v["usage"])
		case "message_stop": self = .messageStop
		case "ping": self = .ping
		case "error": self = .error(type: v["error"]?["type"]?.stringValue ?? "error", message: v["error"]?["message"]?.stringValue ?? "Stream error")
		default: self = .other(v)
		}
	}
}

/// Incremental SSE framing: feed raw lines, get each complete frame's data.
/// Anthropic frames carry one `data:` line, but multi-line data is joined
/// per the SSE spec; a blank line dispatches.
public struct SSEParser: Sendable {
	private var data: [String] = []
	public init() {}

	/// Returns the frame's data when `line` completes one.
	public mutating func feed(_ line: String) -> String? {
		if line.isEmpty {
			guard !data.isEmpty else { return nil }
			defer { data.removeAll() }
			return data.joined(separator: "\n")
		}
		if line.hasPrefix(":") { return nil }
		if line.hasPrefix("data:") {
			var value = line.dropFirst(5)
			if value.hasPrefix(" ") { value = value.dropFirst() }
			data.append(String(value))
		}
		return nil
	}

	/// Flush a frame left open at end of stream.
	public mutating func finish() -> String? {
		guard !data.isEmpty else { return nil }
		defer { data.removeAll() }
		return data.joined(separator: "\n")
	}
}

/// The assembled assistant response: content blocks exactly as they will
/// be stored (bytes untouched) and re-sent, plus the stop/usage metadata.
public struct AssistantResponse: Sendable, Hashable {
	public var id: String?
	/// The model that produced the message (a fallback model after a switch).
	public var model: String
	public var content: [JSONValue]
	public var stopReason: String?
	public var stopDetails: JSONValue?
	public var usage: JSONValue
	/// `input_transformations` (dropped/mismatched thinking blocks).
	public var inputTransformations: [JSONValue]
	/// Tool-use blocks whose streamed input was not valid JSON (index → raw text).
	public var invalidToolInput: [Int: String]

	public init(id: String? = nil, model: String, content: [JSONValue] = [], stopReason: String? = nil, stopDetails: JSONValue? = nil, usage: JSONValue = [:], inputTransformations: [JSONValue] = [], invalidToolInput: [Int: String] = [:]) {
		self.id = id
		self.model = model
		self.content = content
		self.stopReason = stopReason
		self.stopDetails = stopDetails
		self.usage = usage
		self.inputTransformations = inputTransformations
		self.invalidToolInput = invalidToolInput
	}

	/// Per-attempt usage: `usage.iterations` when present (fallbacks), else the top-level usage.
	public var callUsages: [(model: String?, usage: CallUsage, fallbackFrom: String?)] {
		if let iterations = usage["iterations"]?.arrayValue, !iterations.isEmpty {
			var previous: String?
			return iterations.map { it in
				let model = it["model"]?.stringValue
				let fromModel = it["type"]?.stringValue == "fallback_message" ? previous : nil
				previous = model ?? previous
				return (model, Self.callUsage(it), fromModel)
			}
		}
		return [(model, Self.callUsage(usage), nil)]
	}

	/// Anthropic usage → the native CallUsage (input is the uncached part).
	public static func callUsage(_ u: JSONValue) -> CallUsage {
		let write1h = u["cache_creation"]?["ephemeral_1h_input_tokens"]?.intValue
		return CallUsage(
			inputTokens: u["input_tokens"]?.intValue,
			outputTokens: u["output_tokens"]?.intValue,
			cacheReadTokens: u["cache_read_input_tokens"]?.intValue,
			cacheWriteTokens: u["cache_creation_input_tokens"]?.intValue,
			cacheWrite1hTokens: write1h,
			reasoningTokens: nil,
			webSearchRequests: u["server_tool_use"]?["web_search_requests"]?.intValue,
			webFetchRequests: u["server_tool_use"]?["web_fetch_requests"]?.intValue)
	}

	public var messageUsage: MessageUsage {
		let u = Self.callUsage(usage)
		return MessageUsage(input: u.inputTokens ?? 0, output: u.outputTokens ?? 0, cacheRead: u.cacheReadTokens ?? 0, cacheWrite: u.cacheWriteTokens ?? 0)
	}
}

/// Folds stream events into an `AssistantResponse`. Text, thinking,
/// signature and citation deltas append onto the block that
/// `content_block_start` opened; tool inputs accumulate as raw JSON text and
/// are parsed strictly at `content_block_stop`.
public struct MessageAccumulator: Sendable {
	public private(set) var response: AssistantResponse
	private var partialJSON: [Int: String] = [:]
	public private(set) var sawStart = false

	public init(model: String) { response = AssistantResponse(model: model) }

	public mutating func apply(_ event: StreamEvent) {
		switch event {
		case .messageStart(let m):
			sawStart = true
			response.id = m["id"]?.stringValue
			if let model = m["model"]?.stringValue { response.model = model }
			response.usage = m["usage"] ?? [:]
			response.inputTransformations = m["input_transformations"]?.arrayValue ?? []
			if let content = m["content"]?.arrayValue, !content.isEmpty { response.content = content }
		case .contentBlockStart(let index, let block):
			while response.content.count <= index { response.content.append(.null) }
			var b = block
			// tool_use starts with `input: {}`; the deltas carry the real input.
			if ["tool_use", "server_tool_use"].contains(block["type"]?.stringValue ?? "") { partialJSON[index] = "" }
			if block["type"]?.stringValue == "tool_use" || block["type"]?.stringValue == "server_tool_use" { b["input"] = .object(JSONObject()) }
			response.content[index] = b
		case .contentBlockDelta(let index, let delta):
			guard response.content.indices.contains(index) else { return }
			var b = response.content[index]
			switch delta["type"]?.stringValue {
			case "text_delta": b["text"] = .string((b["text"]?.stringValue ?? "") + (delta["text"]?.stringValue ?? ""))
			case "thinking_delta": b["thinking"] = .string((b["thinking"]?.stringValue ?? "") + (delta["thinking"]?.stringValue ?? ""))
			case "signature_delta": b["signature"] = .string((b["signature"]?.stringValue ?? "") + (delta["signature"]?.stringValue ?? ""))
			case "input_json_delta": partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
			case "citations_delta":
				if let c = delta["citation"] { b["citations"] = .array((b["citations"]?.arrayValue ?? []) + [c]) }
			default: break
			}
			response.content[index] = b
		case .contentBlockStop(let index):
			guard let raw = partialJSON.removeValue(forKey: index), response.content.indices.contains(index) else { return }
			if raw.isEmpty { return }
			if let parsed = try? JSONValue.parse(raw), parsed.objectValue != nil {
				response.content[index]["input"] = parsed
			} else {
				response.invalidToolInput[index] = raw
			}
		case .messageDelta(let delta, let usage):
			if let reason = delta["stop_reason"]?.stringValue { response.stopReason = reason }
			if let details = delta["stop_details"], !details.isNull { response.stopDetails = details }
			if case .object(let u)? = usage {
				var merged = response.usage.objectValue ?? JSONObject()
				for (k, v) in u { merged[k] = v }
				response.usage = .object(merged)
			}
			if let transforms = delta["input_transformations"]?.arrayValue { response.inputTransformations = transforms }
		case .messageStop, .ping, .error, .other:
			break
		}
	}

	/// The live tool-input text of an open tool block (for streaming cards).
	public func partialInput(at index: Int) -> String? { partialJSON[index] }
}
