import Foundation

// Port of src/core/contracts/chat.ts — session records, usage accounting,
// plan blocks, summaries.

/// Anthropic `output_config.effort` (docs/native-macos-m1.md: replaces pi's
/// thinkingLevel; thinking is never disabled).
public enum Effort: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
	case low, medium, high, xhigh, max

	public var rank: Int { Effort.allCases.firstIndex(of: self)! }
	public static func < (a: Effort, b: Effort) -> Bool { a.rank < b.rank }
}

/// "teach" is the default and absent on pre-practice records.
public enum ChatKind: String, Sendable, Hashable, Codable {
	case teach, practice
}

/// The chat record format this build writes and understands.
public let CURRENT_CHAT_VERSION = 1

/// Per-chat model/effort overrides for the conversation agents.
public struct ChatSettings: Sendable, Hashable, Codable {
	/// A model id ("claude-opus-5-5").
	public var model: String?
	public var effort: Effort?
	public init(model: String? = nil, effort: Effort? = nil) {
		self.model = model
		self.effort = effort
	}
}

/// One model call's token accounting, Anthropic-native (docs/native-macos-m3.md):
/// `inputTokens` is the UNCACHED input only; cache reads and writes are
/// separate classes. nil = not reported (render absent, never zero).
public struct CallUsage: Sendable, Hashable, Codable {
	/// Uncached input tokens (API `input_tokens`).
	public var inputTokens: Int?
	public var outputTokens: Int?
	/// Cache-hit input tokens (`cache_read_input_tokens`).
	public var cacheReadTokens: Int?
	/// All cache-write tokens (`cache_creation_input_tokens`), both TTLs.
	public var cacheWriteTokens: Int?
	/// The 1-hour-TTL subset of `cacheWriteTokens`.
	public var cacheWrite1hTokens: Int?
	public var reasoningTokens: Int?
	/// Server tool requests (`usage.server_tool_use`).
	public var webSearchRequests: Int?
	public var webFetchRequests: Int?
	public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, cacheWrite1hTokens: Int? = nil, reasoningTokens: Int? = nil, webSearchRequests: Int? = nil, webFetchRequests: Int? = nil) {
		self.inputTokens = inputTokens
		self.outputTokens = outputTokens
		self.cacheReadTokens = cacheReadTokens
		self.cacheWriteTokens = cacheWriteTokens
		self.cacheWrite1hTokens = cacheWrite1hTokens
		self.reasoningTokens = reasoningTokens
		self.webSearchRequests = webSearchRequests
		self.webFetchRequests = webFetchRequests
	}

	/// The whole prompt: uncached input + cache reads + cache writes.
	public var promptTokens: Int { (inputTokens ?? 0) + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0) }
}

/// One billing turn: one full invocation of the conversation agent.
public struct TurnUsage: Sendable, Hashable, Codable {
	/// Unique per request — the append-only log's idempotency key.
	public var id: String
	/// The assistant message the turn produced.
	public var messageId: String
	public var at: String
	/// The model that ran the turn (bare id, or "provider:id" for imports).
	public var model: String
	/// One entry per model call in the turn.
	public var steps: [CallUsage]
	public init(id: String, messageId: String, at: String, model: String, steps: [CallUsage]) {
		self.id = id
		self.messageId = messageId
		self.at = at
		self.model = model
		self.steps = steps
	}
}

public struct ExtractionStageUsage: Sendable, Hashable, Codable {
	public var model: String
	public var steps: [CallUsage]
	public init(model: String, steps: [CallUsage]) {
		self.model = model
		self.steps = steps
	}
}

public struct ExtractionRunUsage: Sendable, Hashable, Codable {
	public struct Stages: Sendable, Hashable, Codable {
		public var extractor: ExtractionStageUsage
		public var auditor: ExtractionStageUsage
		public init(extractor: ExtractionStageUsage, auditor: ExtractionStageUsage) {
			self.extractor = extractor
			self.auditor = auditor
		}
	}

	/// Registry startedAt (ms) — the idempotency key.
	public var startedAt: Int
	public var at: String
	public var durationMs: Int
	public var stats: EmissionStats?
	public var stages: Stages
	public init(startedAt: Int, at: String, durationMs: Int, stats: EmissionStats? = nil, stages: Stages) {
		self.startedAt = startedAt
		self.at = at
		self.durationMs = durationMs
		self.stats = stats
		self.stages = stages
	}
}

/// One persisted session.
public struct ChatRecord: Sendable, Hashable {
	public var id: String
	public var title: String
	public var createdAt: String
	public var updatedAt: String
	public var messages: [Message]
	public var kind: ChatKind?
	public var tree: PlanTree?
	public var turns: [TurnUsage]?
	public var extractions: [ExtractionRunUsage]?
	public var settings: ChatSettings?
	public var version: Int?

	public init(id: String, title: String, createdAt: String, updatedAt: String, messages: [Message], kind: ChatKind? = nil, tree: PlanTree? = nil, turns: [TurnUsage]? = nil, extractions: [ExtractionRunUsage]? = nil, settings: ChatSettings? = nil, version: Int? = nil) {
		self.id = id
		self.title = title
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.messages = messages
		self.kind = kind
		self.tree = tree
		self.turns = turns
		self.extractions = extractions
		self.settings = settings
		self.version = version
	}

	/// The normalized kind (absent reads as teach).
	public var resolvedKind: ChatKind { kind ?? .teach }
}

/// The plan presentation snapshot (data of a plan-block marker).
public struct PlanBlockData: Sendable, Hashable, Codable {
	public struct Node: Sendable, Hashable, Codable {
		public var id: String
		public var title: String
		public var status: PlanNodeStatus
		public init(id: String, title: String, status: PlanNodeStatus) {
			self.id = id
			self.title = title
			self.status = status
		}
	}

	/// Always "full".
	public var kind: String
	public var at: String
	public var current: String?
	public var nodes: [Node]
	public var edges: [PlanEdge]
	public init(kind: String = "full", at: String, current: String?, nodes: [Node], edges: [PlanEdge]) {
		self.kind = kind
		self.at = at
		self.current = current
		self.nodes = nodes
		self.edges = edges
	}
}

/// The sidebar row's record-derived part.
public struct ChatSummary: Sendable, Hashable {
	public var id: String
	public var title: String
	public var createdAt: String
	public var updatedAt: String
	public var kind: ChatKind
	public var messageCount: Int
	public var phase: Phase3
	public var pendingQuestion: Bool
	public var pendingProblem: Bool
	public var settings: ChatSettings?
	public init(id: String, title: String, createdAt: String, updatedAt: String, kind: ChatKind, messageCount: Int, phase: Phase3, pendingQuestion: Bool, pendingProblem: Bool, settings: ChatSettings? = nil) {
		self.id = id
		self.title = title
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.kind = kind
		self.messageCount = messageCount
		self.phase = phase
		self.pendingQuestion = pendingQuestion
		self.pendingProblem = pendingProblem
		self.settings = settings
	}
}

/// The three teaching phases (core/phases.ts Phase3).
public enum Phase3: String, Sendable, Hashable, Codable {
	case probe, plan, teach
}

// MARK: - Legacy (TS data dir) decoding

extension ChatRecord {
	/// Decode a TS chat file (pi-native messages, provider-qualified models,
	/// thinkingLevel) into the native record. Pure; LHImport builds on it.
	public init?(legacyJSON json: JSONValue) {
		guard let id = json["id"]?.stringValue else { return nil }
		self.init(
			id: id,
			title: json["title"]?.stringValue ?? "",
			createdAt: json["createdAt"]?.stringValue ?? "",
			updatedAt: json["updatedAt"]?.stringValue ?? "",
			messages: LegacyRecordConversion.messages(fromPi: json["messages"]?.arrayValue ?? []),
			kind: json["kind"]?.stringValue.flatMap(ChatKind.init(rawValue:)),
			tree: json["tree"].flatMap { try? JSONCodec.decode(PlanTree.self, from: $0) },
			turns: json["turns"].flatMap { try? JSONCodec.decode([TurnUsage].self, from: $0) }?.map(Self.legacyTurn),
			extractions: json["extractions"].flatMap { try? JSONCodec.decode([ExtractionRunUsage].self, from: $0) }?.map(Self.legacyExtraction),
			settings: json["settings"].map(Self.legacySettings),
			version: json["version"]?.intValue)
	}

	/// "anthropic:claude-opus-5-5" → "claude-opus-5-5"; other providers keep the qualified key.
	public static func legacyModelKey(_ key: String) -> String {
		key.hasPrefix("anthropic:") ? String(key.dropFirst("anthropic:".count)) : key
	}

	/// pi thinkingLevel → effort. off/minimal have no Anthropic equivalent
	/// (thinking is never disabled) and read as low.
	public static func legacyEffort(_ thinkingLevel: String?) -> Effort? {
		switch thinkingLevel {
		case "off", "minimal", "low": .low
		case "medium": .medium
		case "high": .high
		case "xhigh": .xhigh
		case "max": .max
		default: nil
		}
	}

	static func legacySettings(_ s: JSONValue) -> ChatSettings {
		let model: String? = {
			guard let provider = s["model"]?["provider"]?.stringValue, let id = s["model"]?["id"]?.stringValue else { return nil }
			return LegacyRecordConversion.modelRef(provider: provider, id: id)
		}()
		return ChatSettings(model: model, effort: legacyEffort(s["thinkingLevel"]?.stringValue))
	}

	static func legacyTurn(_ t: TurnUsage) -> TurnUsage {
		var t = t
		t.model = legacyModelKey(t.model)
		return t
	}

	static func legacyExtraction(_ e: ExtractionRunUsage) -> ExtractionRunUsage {
		var e = e
		e.stages.extractor.model = legacyModelKey(e.stages.extractor.model)
		e.stages.auditor.model = legacyModelKey(e.stages.auditor.model)
		return e
	}
}

/// JSONValue ⇄ Codable bridge.
public enum JSONCodec {
	public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
		try JSONDecoder().decode(T.self, from: value.serializedData)
	}

	public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
		let enc = JSONEncoder()
		enc.outputFormatting = [.sortedKeys]
		return try JSONValue.parse(enc.encode(value))
	}
}
