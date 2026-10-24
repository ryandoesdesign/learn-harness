import Foundation

// Port of src/core/settings-resolution.ts, adapted per
// docs/native-macos-m1.md: the delta record (UserSettings) projected into
// EffectiveSettings, every field concrete. Explicit values win; absent keys
// resolve to FACTORY_SETTINGS — models included (factory slot defaults
// exist, so a model chain never comes up empty). Every resolved effort is
// clamped to what the resolved model supports (catalog `efforts`).
//
// Deliberately NOT resolved here: per-chat overrides (the conversation
// chain below is the caller's one call), tool toggles and prompt switches
// (passed through as the delta maps).

/// Which slot a role draws from.
public let ROLE_SLOT: [ModelRole: ModelSlotName] = [
	.prober: .strong,
	.teacher: .strong,
	.researcher: .cheap,
	.demoBuilder: .cheap,
	.extractor: .cheap,
	.auditor: .cheap,
	.visualMaker: .vision,
	.pdfReader: .vision,
]

extension ModelRole {
	/// ROLE_SLOT[self].
	public var slot: ModelSlotName { ROLE_SLOT[self]! }
}

/// A fully-resolved model pin: a concrete model id and its clamped effort.
public struct EffectiveModelSpec: Sendable, Hashable {
	public var model: String
	public var effort: Effort
	public init(model: String, effort: Effort) {
		self.model = model
		self.effort = effort
	}
}

/// A resolved slot — the same shape as a role's spec.
public typealias EffectiveSlot = EffectiveModelSpec

/// The resolved strong/cheap/vision slots.
public struct EffectiveSlots: Sendable, Hashable {
	public var strong: EffectiveSlot
	public var cheap: EffectiveSlot
	public var vision: EffectiveSlot
	public init(strong: EffectiveSlot, cheap: EffectiveSlot, vision: EffectiveSlot) {
		self.strong = strong
		self.cheap = cheap
		self.vision = vision
	}

	public subscript(slot: ModelSlotName) -> EffectiveSlot {
		switch slot {
		case .strong: strong
		case .cheap: cheap
		case .vision: vision
		}
	}
}

public struct EffectiveGraph: Sendable, Hashable {
	public var enabled: Bool
	public var rendering: Bool
	public var extractionChunkTokens: Int
	public init(enabled: Bool, rendering: Bool, extractionChunkTokens: Int) {
		self.enabled = enabled
		self.rendering = rendering
		self.extractionChunkTokens = extractionChunkTokens
	}
}

public struct EffectiveCompaction: Sendable, Hashable {
	public var thresholdTokens: Int
	public init(thresholdTokens: Int) { self.thresholdTokens = thresholdTokens }
}

public struct EffectiveAgent: Sendable, Hashable {
	/// One entry per BACKGROUND_MODEL_ROLES role.
	public var models: [ModelRole: EffectiveModelSpec]
	/// Delta map as stored — consumers resolve absent key → enabled.
	public var tools: [String: Bool]
	/// Delta map as stored — absent key → override off.
	public var prompts: [String: Bool]
	/// Delta as stored — absent `enabled` = on; consumers use graphToolsEnabled.
	public var graphTools: GraphToolsSettings
	public init(models: [ModelRole: EffectiveModelSpec], tools: [String: Bool], prompts: [String: Bool], graphTools: GraphToolsSettings) {
		self.models = models
		self.tools = tools
		self.prompts = prompts
		self.graphTools = graphTools
	}
}

/// The concrete view: every knob resolved.
public struct EffectiveSettings: Sendable, Hashable {
	public var agent: EffectiveAgent
	public var models: EffectiveSlots
	public var graph: EffectiveGraph
	public var compaction: EffectiveCompaction
	public init(agent: EffectiveAgent, models: EffectiveSlots, graph: EffectiveGraph, compaction: EffectiveCompaction) {
		self.agent = agent
		self.models = models
		self.graph = graph
		self.compaction = compaction
	}
}

// MARK: - Effort clamp

/// Clamp `effort` to the nearest level in `supported`, rounding upward on a
/// tie (Fable supports only xhigh/max, so anything lower clamps to xhigh).
/// An empty `supported` list leaves the level untouched.
public func clampEffort(_ effort: Effort, supported: [Effort]) -> Effort {
	guard !supported.isEmpty, !supported.contains(effort) else { return effort }
	return supported.min { a, b in
		let da = abs(a.rank - effort.rank), db = abs(b.rank - effort.rank)
		return da != db ? da < db : a > b
	}!
}

extension ModelCatalog {
	/// Clamp `effort` to `model`'s supported levels. Unknown models leave it
	/// untouched (nothing to clamp against).
	public func clampEffort(_ effort: Effort, model: String) -> Effort {
		guard let supported = self.model(model)?.efforts else { return effort }
		return LHCore.clampEffort(effort, supported: supported)
	}
}

// MARK: - Resolution

private func spec(model: String, effort: Effort?, catalog: ModelCatalog) -> EffectiveModelSpec {
	EffectiveModelSpec(model: model, effort: catalog.clampEffort(effort ?? FACTORY_SETTINGS.effort, model: model))
}

/// Resolve one slot: the stored fields over the slot's factory model and
/// the factory effort.
public func resolveSlot(_ slot: ModelSlot?, _ name: ModelSlotName, catalog: ModelCatalog) -> EffectiveSlot {
	spec(model: slot?.model ?? FACTORY_SETTINGS.slotModels[name]!, effort: slot?.effort, catalog: catalog)
}

/// Resolve one role's spec: role override → slot → factory, each field
/// independent (an override may borrow only the slot's model, or only its
/// effort).
public func resolveModelSpec(_ role: ModelRole, override: RoleModelOverride?, slots: ModelsSettings?, catalog: ModelCatalog) -> EffectiveModelSpec {
	let slot = slots?[role.slot]
	return spec(
		model: override?.model ?? slot?.model ?? FACTORY_SETTINGS.slotModels[role.slot]!,
		effort: override?.effort ?? slot?.effort,
		catalog: catalog)
}

/// Full-chain resolution for ANY role: per-role override (background roles
/// only) → slot → factory. The conversation pair resolves the same chain
/// minus the override (their override is the chat's own settings; see
/// resolveConversationSpec).
public func resolveRoleSpec(_ role: ModelRole, record: UserSettings?, catalog: ModelCatalog) -> EffectiveModelSpec {
	let override = BACKGROUND_MODEL_ROLES.contains(role) ? record?.agent?.models?[role] : nil
	return resolveModelSpec(role, override: override, slots: record?.models, catalog: catalog)
}

/// The conversation pair's chain: the chat's own model/effort over the
/// STORED strong slot, then the factory, each field independent (a bare
/// chat effort rides the strong slot's model). `strong` is the record's
/// raw slot (`record?.models?.strong`), not its resolved view, so an
/// unclamped stored effort rides a chat model swap intact.
public func resolveConversationSpec(_ chat: ChatSettings?, strong: ModelSlot?, catalog: ModelCatalog) -> EffectiveModelSpec {
	spec(
		model: chat?.model ?? strong?.model ?? FACTORY_SETTINGS.slotModels[.strong]!,
		effort: chat?.effort ?? strong?.effort,
		catalog: catalog)
}

/// Resolve the whole record. `record` may be nil (first boot).
public func resolveSettings(_ record: UserSettings?, catalog: ModelCatalog) -> EffectiveSettings {
	let agent = record?.agent
	let slots = record?.models
	var models: [ModelRole: EffectiveModelSpec] = [:]
	for role in BACKGROUND_MODEL_ROLES {
		models[role] = resolveModelSpec(role, override: agent?.models?[role], slots: slots, catalog: catalog)
	}
	let graph = record?.graph
	let factory = FACTORY_SETTINGS
	return EffectiveSettings(
		agent: EffectiveAgent(
			models: models,
			tools: agent?.tools ?? [:],
			prompts: agent?.prompts ?? [:],
			graphTools: agent?.graphTools ?? GraphToolsSettings()),
		models: EffectiveSlots(
			strong: resolveSlot(slots?.strong, .strong, catalog: catalog),
			cheap: resolveSlot(slots?.cheap, .cheap, catalog: catalog),
			vision: resolveSlot(slots?.vision, .vision, catalog: catalog)),
		graph: EffectiveGraph(
			enabled: graph?.enabled ?? factory.graph.enabled,
			rendering: graph?.rendering ?? factory.graph.rendering,
			extractionChunkTokens: graph?.extractionChunkTokens ?? factory.graph.extractionChunkTokens),
		compaction: EffectiveCompaction(
			thresholdTokens: record?.compaction?.thresholdTokens ?? factory.compaction.thresholdTokens))
}

// MARK: - Graph channel gates

/// The WRITE channel gate (extraction + its auditor): dies with the master switch.
public func extractionEnabled(_ graph: EffectiveGraph) -> Bool {
	graph.enabled
}

/// The RENDERING gate: display-only (canvas vs chains view); no data path
/// consults it.
public func renderingEnabled(_ graph: EffectiveGraph) -> Bool {
	graph.rendering
}

/// The PROBER GRAPH TOOLS gate: the agent toggle AND the graph master switch.
public func graphToolsEnabled(graphEnabled: Bool, graphTools: GraphToolsSettings) -> Bool {
	graphEnabled && (graphTools.enabled ?? true)
}

/// graphToolsEnabled over a resolved view.
public func graphToolsEnabled(_ effective: EffectiveSettings) -> Bool {
	graphToolsEnabled(graphEnabled: effective.graph.enabled, graphTools: effective.agent.graphTools)
}
