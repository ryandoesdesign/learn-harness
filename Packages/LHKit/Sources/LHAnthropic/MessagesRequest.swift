import Foundation
import LHCore

/// One `POST /v1/messages` request (docs/native-macos-m3.md, "Requests").
/// Content blocks are raw JSON: the wire projection hands over the record's
/// bytes and this type never rewrites them.
public struct MessagesRequest: Sendable, Hashable {
	public var model: String
	public var maxTokens: Int
	/// The system prompt (one text block, cached with `cacheTTL`).
	public var system: String?
	public var messages: [WireMessage]
	/// In declaration order (fixed order keeps the cache prefix stable).
	public var tools: [ToolDefinition]
	public var effort: Effort
	public var thinkingDisplay: ThinkingDisplay
	public var cacheTTL: CacheTTL
	/// `fallbacks: "default"` (never sent for models without server-side fallback).
	public var fallbacks: Bool
	/// `thinking.block_binding.prefix_mismatch_behavior: "drop_block"`.
	public var dropMismatchedThinking: Bool
	public var stream: Bool

	public init(model: String, maxTokens: Int, system: String? = nil, messages: [WireMessage], tools: [ToolDefinition] = [],
		effort: Effort, thinkingDisplay: ThinkingDisplay = .summarized, cacheTTL: CacheTTL = .fiveMinutes,
		fallbacks: Bool = true, dropMismatchedThinking: Bool = true, stream: Bool = true)
	{
		self.model = model
		self.maxTokens = maxTokens
		self.system = system
		self.messages = messages
		self.tools = tools
		self.effort = effort
		self.thinkingDisplay = thinkingDisplay
		self.cacheTTL = cacheTTL
		self.fallbacks = fallbacks
		self.dropMismatchedThinking = dropMismatchedThinking
		self.stream = stream
	}

	public enum ThinkingDisplay: String, Sendable, Hashable { case summarized, omitted }

	public enum CacheTTL: Sendable, Hashable {
		case fiveMinutes, oneHour
		var json: JSONValue { self == .oneHour ? ["type": "ephemeral", "ttl": "1h"] : ["type": "ephemeral"] }
	}

	/// Models with no server-side fallback (a `fallbacks` value is ignored or 400s).
	public static func supportsFallbacks(_ model: String) -> Bool { !model.hasPrefix("claude-haiku") }

	public static let apiVersion = "2026-10-21"
	static let fallbackBeta = "server-side-fallback-2026-07-01"
	static let bindingBeta = "thinking-binding-controls-2026-08-01"

	public var useFallbacks: Bool { fallbacks && Self.supportsFallbacks(model) }

	/// The `anthropic-beta` header value (nil when none apply).
	public var betaHeader: String? {
		var betas: [String] = []
		if useFallbacks { betas.append(Self.fallbackBeta) }
		if dropMismatchedThinking { betas.append(Self.bindingBeta) }
		return betas.isEmpty ? nil : betas.joined(separator: ",")
	}

	/// The JSON body. Key order is fixed, so the same request always
	/// serializes to the same bytes.
	public var body: JSONValue {
		var o = JSONObject()
		o["model"] = .string(model)
		o["max_tokens"] = .number(maxTokens)
		if let system {
			o["system"] = [["type": "text", "text": .string(system), "cache_control": cacheTTL.json]]
		}
		o["messages"] = .array(messages.map(\.json))
		if !tools.isEmpty { o["tools"] = .array(tools.map(\.json)) }
		var thinking = JSONObject(["type": "adaptive", "display": .string(thinkingDisplay.rawValue)])
		if dropMismatchedThinking { thinking["block_binding"] = ["prefix_mismatch_behavior": "drop_block"] }
		o["thinking"] = .object(thinking)
		o["output_config"] = ["effort": .string(effort.rawValue)]
		o["cache_control"] = cacheTTL.json
		if useFallbacks { o["fallbacks"] = "default" }
		if stream { o["stream"] = true }
		return .object(o)
	}
}

public struct WireMessage: Sendable, Hashable {
	public enum Role: String, Sendable, Hashable { case user, assistant }
	public var role: Role
	/// Raw content blocks.
	public var content: [JSONValue]
	public init(role: Role, content: [JSONValue]) {
		self.role = role
		self.content = content
	}

	public var json: JSONValue { ["role": .string(role.rawValue), "content": .array(content)] }
}

public enum ToolDefinition: Sendable, Hashable {
	/// A client tool: the TS schema as-is (non-strict — strict mode rejects
	/// it; see docs/native-macos-m5.md), eager input streaming, validated
	/// client-side with the TS problem list on failure.
	case client(name: String, description: String, inputSchema: JSONValue)
	/// A server tool (`web_search_20260209`, `web_fetch_20260209`, …) with its options.
	case server(type: String, name: String, options: JSONObject = JSONObject())

	public var name: String {
		switch self {
		case .client(let name, _, _), .server(_, let name, _): name
		}
	}

	public var json: JSONValue {
		switch self {
		case .client(let name, let description, let schema):
			return ["name": .string(name), "description": .string(description), "input_schema": schema, "eager_input_streaming": true]
		case .server(let type, let name, let options):
			var o = JSONObject(["type": .string(type), "name": .string(name)])
			for (k, v) in options { o[k] = v }
			return .object(o)
		}
	}

	public static func webSearch(maxUses: Int? = nil) -> ToolDefinition {
		.server(type: "web_search_20260209", name: "web_search", options: maxUses.map { JSONObject(["max_uses": .number($0)]) } ?? JSONObject())
	}

	public static func webFetch(maxUses: Int? = nil) -> ToolDefinition {
		.server(type: "web_fetch_20260209", name: "web_fetch", options: maxUses.map { JSONObject(["max_uses": .number($0)]) } ?? JSONObject())
	}
}
