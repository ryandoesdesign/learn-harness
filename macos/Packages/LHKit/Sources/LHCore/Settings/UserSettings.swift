import Foundation

// Port of src/core/settings.ts, adapted per docs/native-macos-m1.md
// ("Settings"): one versioned, DELTA-shaped record holding every non-secret
// product preference. Absent keys resolve to the factory defaults compiled
// in below — models included (the native app has factory slot defaults, so
// there is no first-run "models not configured" gate).
//
// Sanitizer contract: whatever arrives from disk passes through
// `sanitizeUserSettings` before use. Strict on known fields, PRESERVES
// unknown top-level keys verbatim (a newer record must survive an older
// app). Invalid known values degrade gracefully: out-of-range numbers
// clamp, wrong-typed fields drop, never throw.

/// The schema version this code understands. Bump ONLY for breaking shape
/// changes; pure additions never bump.
public let CURRENT_SETTINGS_VERSION = 1

/// The capability tiers a user pins models into: strong = prober + teacher;
/// cheap = researcher, demo builder, extractor, auditor; vision = visual
/// maker + PDF reader.
public enum ModelSlotName: String, Sendable, Hashable, Codable, CaseIterable {
	case strong, cheap, vision
}

public let MODEL_SLOTS: [ModelSlotName] = ModelSlotName.allCases

/// Every agent role in the app (config.ts ModelRole).
public enum ModelRole: String, Sendable, Hashable, Codable, CaseIterable {
	case prober, teacher, researcher, demoBuilder, visualMaker, pdfReader, extractor, auditor
}

/// The background-agent roles whose models the Agent settings expose. The
/// conversation pair stays out (chat-controlled via the strong slot), and
/// so does pdfReader (it only ever rides the vision slot).
public let BACKGROUND_MODEL_ROLES: [ModelRole] = [.researcher, .demoBuilder, .visualMaker, .extractor, .auditor]

/// One slot's (or one role override's) stored state. Every field is
/// independent: an absent field falls through to the next tier of the chain.
public struct ModelSlot: Sendable, Hashable {
	/// A model id ("claude-opus-5-5"; imports may carry "provider:id").
	public var model: String?
	public var effort: Effort?
	public init(model: String? = nil, effort: Effort? = nil) {
		self.model = model
		self.effort = effort
	}

	var isEmpty: Bool { model == nil && effort == nil }
}

/// A per-role model/effort override — the same shape as a slot.
public typealias RoleModelOverride = ModelSlot

/// The `models` section: the strong/cheap/vision slots.
public struct ModelsSettings: Sendable, Hashable {
	public var strong: ModelSlot?
	public var cheap: ModelSlot?
	public var vision: ModelSlot?
	public init(strong: ModelSlot? = nil, cheap: ModelSlot? = nil, vision: ModelSlot? = nil) {
		self.strong = strong
		self.cheap = cheap
		self.vision = vision
	}

	public subscript(slot: ModelSlotName) -> ModelSlot? {
		get {
			switch slot {
			case .strong: strong
			case .cheap: cheap
			case .vision: vision
			}
		}
		set {
			switch slot {
			case .strong: strong = newValue
			case .cheap: cheap = newValue
			case .vision: vision = newValue
			}
		}
	}

	var isEmpty: Bool { strong == nil && cheap == nil && vision == nil }
}

/// The prober graph tools switch (absent `enabled` = on).
public struct GraphToolsSettings: Sendable, Hashable {
	public var enabled: Bool?
	public init(enabled: Bool? = nil) { self.enabled = enabled }
}

/// Agent settings — everything about the non-conversation machinery.
public struct AgentSettings: Sendable, Hashable {
	/// Background-role overrides (only BACKGROUND_MODEL_ROLES keys survive).
	public var models: [ModelRole: RoleModelOverride]?
	/// Tool toggles keyed by tool id (absent key = enabled).
	public var tools: [String: Bool]?
	/// System-prompt override switches keyed by segment path (absent = off).
	public var prompts: [String: Bool]?
	public var graphTools: GraphToolsSettings?
	public init(models: [ModelRole: RoleModelOverride]? = nil, tools: [String: Bool]? = nil, prompts: [String: Bool]? = nil, graphTools: GraphToolsSettings? = nil) {
		self.models = models
		self.tools = tools
		self.prompts = prompts
		self.graphTools = graphTools
	}
}

/// Knowledge-graph settings.
public struct GraphSettings: Sendable, Hashable {
	/// The data switch: off = no extraction, no auditor.
	public var enabled: Bool?
	/// The display switch: off = the home shows the chains view.
	public var rendering: Bool?
	/// The extractor's transcript-token chunk budget (floored at
	/// EXTRACTION_CHUNK_TOKENS_FLOOR, no ceiling).
	public var extractionChunkTokens: Int?
	public init(enabled: Bool? = nil, rendering: Bool? = nil, extractionChunkTokens: Int? = nil) {
		self.enabled = enabled
		self.rendering = rendering
		self.extractionChunkTokens = extractionChunkTokens
	}
}

/// Compaction: the trigger threshold in context tokens (floored at
/// COMPACTION_THRESHOLD_FLOOR, no ceiling).
public struct CompactionSettings: Sendable, Hashable {
	public var thresholdTokens: Int?
	public init(thresholdTokens: Int? = nil) { self.thresholdTokens = thresholdTokens }
}

/// THE record. Every section optional (delta); unknown top-level keys ride
/// in `unknown`, verbatim and in their original order.
public struct UserSettings: Sendable, Hashable {
	public var version: Int
	public var agent: AgentSettings?
	public var models: ModelsSettings?
	public var graph: GraphSettings?
	public var compaction: CompactionSettings?
	/// Unknown top-level keys, preserved verbatim (forward-compat).
	public var unknown: JSONObject

	public init(version: Int = CURRENT_SETTINGS_VERSION, agent: AgentSettings? = nil, models: ModelsSettings? = nil, graph: GraphSettings? = nil, compaction: CompactionSettings? = nil, unknown: JSONObject = JSONObject()) {
		self.version = version
		self.agent = agent
		self.models = models
		self.graph = graph
		self.compaction = compaction
		self.unknown = unknown
	}
}

// MARK: - Factory defaults

/// The compiled factory layer.
public struct FactorySettings: Sendable, Hashable {
	public var version: Int
	/// Each slot's factory model.
	public var slotModels: [ModelSlotName: String]
	/// The effort any unset level resolves to (then clamped per model).
	public var effort: Effort
	public var graph: EffectiveGraph
	public var compaction: EffectiveCompaction
}

public let FACTORY_SETTINGS = FactorySettings(
	version: CURRENT_SETTINGS_VERSION,
	slotModels: [.strong: "claude-opus-5-5", .cheap: "claude-sonnet-5-5", .vision: "claude-sonnet-5-5"],
	effort: .high,
	graph: EffectiveGraph(enabled: true, rendering: true, extractionChunkTokens: 4096),
	compaction: EffectiveCompaction(thresholdTokens: 150_000))

/// The chunk budget's validated floor (penny-batch cost protection).
public let EXTRACTION_CHUNK_TOKENS_FLOOR = 500

/// The compaction threshold's floor (below the kept tail plus a summary
/// the chat would re-compact every turn).
public let COMPACTION_THRESHOLD_FLOOR = 32_000

// MARK: - Sanitizer

/// Top-level keys that are known-DEAD: stripped instead of riding along as
/// unknown keys, so a fossil copy on disk never resurrects. `chat` died with
/// per-session models (TS); `general` and `appearance` died with the native
/// app (docs/native-macos-m1.md: no updater, pure system look).
let DEAD_SETTINGS_KEYS: Set<String> = ["chat", "general", "appearance"]

/// The section keys this build owns.
let KNOWN_SETTINGS_KEYS: Set<String> = ["version", "agent", "models", "graph", "compaction"]

private extension JSONValue {
	/// A non-null, non-array object (the TS `typeof === "object"` guard).
	var plainObject: JSONObject? { objectValue }
}

/// clamp-never-reject for token budgets: a finite positive number floors to
/// an integer and clamps up to `floor`; anything else drops.
private func flooredTokens(_ raw: JSONValue?, floor: Int) -> Int? {
	guard let d = raw?.doubleValue, d.isFinite, d > 0 else { return nil }
	let whole = d.rounded(.down)
	let int = whole >= Double(Int.max) ? Int.max : Int(whole)
	return Swift.max(floor, int)
}

private func sanitizeSlot(_ raw: JSONValue?) -> ModelSlot? {
	guard let r = raw?.plainObject else { return nil }
	var out = ModelSlot()
	if let model = r["model"]?.stringValue { out.model = model }
	if let effort = r["effort"]?.stringValue.flatMap(Effort.init(rawValue:)) { out.effort = effort }
	return out.isEmpty ? nil : out
}

private func sanitizeModels(_ raw: JSONObject) -> ModelsSettings {
	var out = ModelsSettings()
	for slot in MODEL_SLOTS {
		out[slot] = sanitizeSlot(raw[slot.rawValue])
	}
	return out
}

private func sanitizeBooleanMap(_ raw: JSONValue?) -> [String: Bool]? {
	guard let r = raw?.plainObject else { return nil }
	var out: [String: Bool] = [:]
	for (key, value) in r {
		if let b = value.boolValue { out[key] = b }
	}
	return out.isEmpty ? nil : out
}

private func sanitizeAgent(_ raw: JSONObject) -> AgentSettings {
	var out = AgentSettings()
	if let models = raw["models"]?.plainObject {
		var cleaned: [ModelRole: RoleModelOverride] = [:]
		for (key, value) in models {
			guard let role = ModelRole(rawValue: key), BACKGROUND_MODEL_ROLES.contains(role) else { continue }
			if let o = sanitizeSlot(value) { cleaned[role] = o }
		}
		if !cleaned.isEmpty { out.models = cleaned }
	}
	out.tools = sanitizeBooleanMap(raw["tools"])
	out.prompts = sanitizeBooleanMap(raw["prompts"])
	// agent.search is not read: the server tools replace Tavily/Brave.
	if let graphTools = raw["graphTools"]?.plainObject {
		switch graphTools["enabled"] {
		case nil: out.graphTools = GraphToolsSettings()
		case .bool(let b)?: out.graphTools = GraphToolsSettings(enabled: b)
		default: break
		}
	}
	return out
}

private func sanitizeGraph(_ raw: JSONObject) -> GraphSettings {
	var out = GraphSettings()
	out.enabled = raw["enabled"]?.boolValue
	out.rendering = raw["rendering"]?.boolValue
	out.extractionChunkTokens = flooredTokens(raw["extractionChunkTokens"], floor: EXTRACTION_CHUNK_TOKENS_FLOOR)
	return out
}

private func sanitizeCompaction(_ raw: JSONObject) -> CompactionSettings {
	CompactionSettings(thresholdTokens: flooredTokens(raw["thresholdTokens"], floor: COMPACTION_THRESHOLD_FLOOR))
}

/// Coerce arbitrary JSON into a valid delta record. Never throws;
/// non-objects → nil.
///
/// Bug fix over the TS (settings.ts:630): `compaction` is sanitized on its
/// own, not only when a `graph` section is present.
public func sanitizeUserSettings(_ raw: JSONValue?) -> UserSettings? {
	guard let r = raw?.plainObject else { return nil }
	var out = UserSettings()
	if let v = r["version"]?.intValue, v >= 1 { out.version = v }
	if let agent = r["agent"]?.plainObject { out.agent = sanitizeAgent(agent) }
	if let models = r["models"]?.plainObject {
		let cleaned = sanitizeModels(models)
		if !cleaned.isEmpty { out.models = cleaned }
	}
	if let graph = r["graph"]?.plainObject { out.graph = sanitizeGraph(graph) }
	if let compaction = r["compaction"]?.plainObject { out.compaction = sanitizeCompaction(compaction) }
	for (key, value) in r where !KNOWN_SETTINGS_KEYS.contains(key) && !DEAD_SETTINGS_KEYS.contains(key) {
		out.unknown[key] = value
	}
	return out
}

extension UserSettings {
	/// `sanitizeUserSettings(raw)`.
	public init?(sanitizing raw: JSONValue?) {
		guard let s = sanitizeUserSettings(raw) else { return nil }
		self = s
	}
}

// MARK: - Serialization

extension ModelSlot {
	public var json: JSONValue {
		var o = JSONObject()
		if let model { o["model"] = .string(model) }
		if let effort { o["effort"] = .string(effort.rawValue) }
		return .object(o)
	}
}

private func boolMapJSON(_ map: [String: Bool]) -> JSONValue {
	var o = JSONObject()
	for key in map.keys.sorted() { o[key] = .bool(map[key]!) }
	return .object(o)
}

extension UserSettings {
	/// The record as JSON: the known sections in a fixed order, then the
	/// unknown keys in their original order. Sanitizing this value
	/// reproduces `self`.
	public var json: JSONValue {
		var o = JSONObject()
		o["version"] = .number(version)
		if let agent {
			var a = JSONObject()
			if let models = agent.models {
				var m = JSONObject()
				for role in BACKGROUND_MODEL_ROLES {
					if let override = models[role] { m[role.rawValue] = override.json }
				}
				a["models"] = .object(m)
			}
			if let tools = agent.tools { a["tools"] = boolMapJSON(tools) }
			if let prompts = agent.prompts { a["prompts"] = boolMapJSON(prompts) }
			if let graphTools = agent.graphTools {
				a["graphTools"] = graphTools.enabled.map { ["enabled": .bool($0)] } ?? .object(JSONObject())
			}
			o["agent"] = .object(a)
		}
		if let models {
			var m = JSONObject()
			for slot in MODEL_SLOTS {
				if let s = models[slot] { m[slot.rawValue] = s.json }
			}
			o["models"] = .object(m)
		}
		if let graph {
			var g = JSONObject()
			if let enabled = graph.enabled { g["enabled"] = .bool(enabled) }
			if let rendering = graph.rendering { g["rendering"] = .bool(rendering) }
			if let tokens = graph.extractionChunkTokens { g["extractionChunkTokens"] = .number(tokens) }
			o["graph"] = .object(g)
		}
		if let compaction {
			var c = JSONObject()
			if let t = compaction.thresholdTokens { c["thresholdTokens"] = .number(t) }
			o["compaction"] = .object(c)
		}
		for (key, value) in unknown where o[key] == nil { o[key] = value }
		return .object(o)
	}
}

// MARK: - Legacy (TS data dir) decoding

extension UserSettings {
	/// Decode a TS `settings.json` into the native record: every
	/// `{model: {provider, id}, thinkingLevel}` slot/override becomes
	/// `{model: "<id>" | "<provider>:<id>", effort}` (anthropic ids go bare),
	/// then the result runs through the sanitizer, which drops the dead
	/// sections (general, appearance, agent.search, chat). Pure; LHImport
	/// builds on it. Non-objects → nil.
	public init?(legacyJSON json: JSONValue) {
		guard case .object(var root) = json else { return nil }
		if case .object(var models)? = root["models"] {
			for slot in MODEL_SLOTS {
				if let s = models[slot.rawValue] { models[slot.rawValue] = Self.legacySlot(s) }
			}
			root["models"] = .object(models)
		}
		if case .object(var agent)? = root["agent"], case .object(var roles)? = agent["models"] {
			for key in roles.keys {
				roles[key] = Self.legacySlot(roles[key]!)
			}
			agent["models"] = .object(roles)
			root["agent"] = .object(agent)
		}
		guard let s = sanitizeUserSettings(.object(root)) else { return nil }
		self = s
	}

	static func legacySlot(_ value: JSONValue) -> JSONValue {
		guard let o = value.objectValue else { return value }
		var out = JSONObject()
		if let provider = o["model"]?["provider"]?.stringValue, let id = o["model"]?["id"]?.stringValue {
			out["model"] = .string(LegacyRecordConversion.modelRef(provider: provider, id: id))
		}
		if let effort = ChatRecord.legacyEffort(o["thinkingLevel"]?.stringValue) {
			out["effort"] = .string(effort.rawValue)
		}
		return .object(out)
	}
}
