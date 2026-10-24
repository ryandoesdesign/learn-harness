import Foundation
import Testing
@testable import LHCore

// Port of tests/settings-resolution.test.ts, adapted to the factory slot
// defaults (no BYOK empty chains: every chain ends at the factory model)
// and the effort clamp. Rewritten cases are marked.

private let catalog = TestCatalog.shared
private let OPUS = "claude-opus-5-5"
private let SONNET = "claude-sonnet-5-5"
private let HAIKU = "claude-haiku-5-5"
private let FABLE = "claude-fable-5"

private func spec(_ model: String, _ effort: Effort) -> EffectiveModelSpec {
	EffectiveModelSpec(model: model, effort: effort)
}

@Suite struct ResolveSettingsTests {
	// REWRITTEN: no general/appearance/search; every model view resolves to
	// the factory slot model at the factory effort.
	@Test func nilRecordLandsOnFactoryDefaults() {
		let eff = resolveSettings(nil, catalog: catalog)
		#expect(eff.agent.tools == [:])
		#expect(eff.agent.prompts == [:])
		#expect(eff.agent.graphTools == GraphToolsSettings())
		for role in BACKGROUND_MODEL_ROLES {
			let expected = role.slot == .strong ? OPUS : SONNET
			#expect(eff.agent.models[role] == spec(expected, .high), "\(role)")
		}
		#expect(eff.agent.models.count == BACKGROUND_MODEL_ROLES.count)
		#expect(eff.models.strong == spec(OPUS, .high))
		#expect(eff.models.cheap == spec(SONNET, .high))
		#expect(eff.models.vision == spec(SONNET, .high))
		#expect(eff.graph == EffectiveGraph(enabled: true, rendering: true, extractionChunkTokens: 4096))
		#expect(eff.compaction == EffectiveCompaction(thresholdTokens: 150_000))
	}

	// REWRITTEN: general/appearance/search assertions dropped; compaction added.
	@Test func explicitRecordValuesWinOverEveryFactoryDefault() {
		let record = UserSettings(
			agent: AgentSettings(
				models: [.researcher: ModelSlot(model: HAIKU)],
				tools: ["research": false],
				prompts: ["system-prompt.md": true]),
			graph: GraphSettings(enabled: false),
			compaction: CompactionSettings(thresholdTokens: 64_000))
		let eff = resolveSettings(record, catalog: catalog)
		// effort not overridden and no cheap slot → the factory effort.
		#expect(eff.agent.models[.researcher] == spec(HAIKU, .high))
		#expect(eff.agent.tools == ["research": false])
		#expect(eff.agent.prompts == ["system-prompt.md": true])
		#expect(eff.graph == EffectiveGraph(enabled: false, rendering: true, extractionChunkTokens: 4096))
		#expect(renderingEnabled(eff.graph), "extraction off leaves rendering on")
		#expect(eff.compaction.thresholdTokens == 64_000)
		let budgeted = resolveSettings(UserSettings(graph: GraphSettings(extractionChunkTokens: 2000)), catalog: catalog)
		#expect(budgeted.graph == EffectiveGraph(enabled: true, rendering: true, extractionChunkTokens: 2000))
	}

	@Test func graphRenderingIsDisplayOnly() {
		let eff = resolveSettings(UserSettings(graph: GraphSettings(rendering: false)), catalog: catalog)
		#expect(eff.graph.rendering == false)
		#expect(eff.graph.enabled == true)
		#expect(renderingEnabled(eff.graph) == false)
		#expect(extractionEnabled(eff.graph) == true)
		#expect(resolveSettings(UserSettings(graph: GraphSettings()), catalog: catalog).graph.rendering == true)
	}

	// REWRITTEN: without a slot, an effort-only override rides the FACTORY model.
	@Test func partialRoleOverrideEffortAloneBorrowsTheSlotModel() {
		let eff = resolveSettings(UserSettings(
			agent: AgentSettings(models: [.extractor: ModelSlot(effort: .medium)]),
			models: ModelsSettings(cheap: ModelSlot(model: HAIKU))), catalog: catalog)
		#expect(eff.agent.models[.extractor] == spec(HAIKU, .medium))
		let bare = resolveSettings(UserSettings(agent: AgentSettings(models: [.extractor: ModelSlot(effort: .medium)])), catalog: catalog)
		#expect(bare.agent.models[.extractor] == spec(SONNET, .medium))
	}

	// REWRITTEN: the empty-chain case resolves the factory instead of undefined.
	@Test func resolveModelSpecIsFieldIndependent() {
		let slots = ModelsSettings(cheap: ModelSlot(model: HAIKU, effort: .low))
		#expect(resolveModelSpec(.auditor, override: ModelSlot(model: OPUS), slots: slots, catalog: catalog) == spec(OPUS, .low))
		#expect(resolveModelSpec(.auditor, override: ModelSlot(effort: .max), slots: slots, catalog: catalog) == spec(HAIKU, .max))
		#expect(resolveModelSpec(.auditor, override: nil, slots: ModelsSettings(), catalog: catalog) == spec(SONNET, .high))
	}
}

@Suite struct SlotTierTests {
	// REWRITTEN: "other tiers untouched" now means "other tiers on the factory".
	@Test func slotAloneReTiersEveryRoleOfItsTier() {
		let eff = resolveSettings(UserSettings(models: ModelsSettings(cheap: ModelSlot(model: HAIKU))), catalog: catalog)
		for role in [ModelRole.researcher, .demoBuilder, .extractor, .auditor] {
			#expect(eff.agent.models[role] == spec(HAIKU, .high), "\(role)")
		}
		#expect(eff.agent.models[.visualMaker] == spec(SONNET, .high))
	}

	@Test func roleOverrideStillBeatsTheSlotEachFieldIndependent() {
		let eff = resolveSettings(UserSettings(
			agent: AgentSettings(models: [.researcher: ModelSlot(model: OPUS)]),
			models: ModelsSettings(cheap: ModelSlot(model: HAIKU, effort: .medium))), catalog: catalog)
		#expect(eff.agent.models[.researcher] == spec(OPUS, .medium), "slot effort rides the override's model")
		#expect(eff.agent.models[.auditor] == spec(HAIKU, .medium))
	}

	// REWRITTEN: an effort-only slot is no longer inert — it rides the factory model.
	@Test func visionSlotCoversVisualMakerAndPdfReader() {
		let record = UserSettings(models: ModelsSettings(vision: ModelSlot(model: HAIKU, effort: .max)))
		let eff = resolveSettings(record, catalog: catalog)
		#expect(eff.agent.models[.visualMaker] == spec(HAIKU, .max))
		#expect(eff.models.vision == spec(HAIKU, .max))
		#expect(resolveRoleSpec(.pdfReader, record: record, catalog: catalog) == spec(HAIKU, .max))
		let levelOnly = resolveSettings(UserSettings(models: ModelsSettings(strong: ModelSlot(effort: .medium))), catalog: catalog)
		#expect(levelOnly.models.strong == spec(OPUS, .medium))
		#expect(levelOnly.agent.models[.researcher] == spec(SONNET, .high), "strong's level must not leak into other tiers")
	}

	// REWRITTEN: resolveSlot always yields a model.
	@Test func resolveSlotFallsBackFieldByField() {
		#expect(resolveSlot(ModelSlot(model: HAIKU, effort: .medium), .cheap, catalog: catalog) == spec(HAIKU, .medium))
		#expect(resolveSlot(ModelSlot(model: HAIKU), .cheap, catalog: catalog) == spec(HAIKU, .high))
		#expect(resolveSlot(ModelSlot(effort: .medium), .strong, catalog: catalog) == spec(OPUS, .medium))
		#expect(resolveSlot(nil, .vision, catalog: catalog) == spec(SONNET, .high))
	}

	@Test func resolveRoleSpecSharesTheChain() {
		let record = UserSettings(models: ModelsSettings(strong: ModelSlot(model: HAIKU)))
		#expect(resolveRoleSpec(.prober, record: record, catalog: catalog) == spec(HAIKU, .high))
		var withOverride = record
		withOverride.agent = AgentSettings(models: [.researcher: ModelSlot(model: OPUS)])
		#expect(resolveRoleSpec(.researcher, record: withOverride, catalog: catalog) == spec(OPUS, .high))
		// The conversation pair never reads a background override, even a stale one.
		var stale = record
		stale.agent = AgentSettings(models: [.teacher: ModelSlot(model: OPUS)])
		#expect(resolveRoleSpec(.teacher, record: stale, catalog: catalog) == spec(HAIKU, .high))
		let vision = UserSettings(models: ModelsSettings(vision: ModelSlot(model: HAIKU, effort: .low)))
		#expect(resolveRoleSpec(.pdfReader, record: vision, catalog: catalog) == spec(HAIKU, .low))
		#expect(resolveRoleSpec(.teacher, record: nil, catalog: catalog) == spec(OPUS, .high))
	}

	@Test func roleSlotMapsEveryRole() {
		#expect(ROLE_SLOT.count == ModelRole.allCases.count)
		#expect(ModelRole.allCases.filter { $0.slot == .strong } == [.prober, .teacher])
		#expect(ModelRole.allCases.filter { $0.slot == .vision } == [.visualMaker, .pdfReader])
	}
}

@Suite struct ResolveConversationSpecTests {
	// REWRITTEN: never nil — the factory strong model ends the chain.
	@Test func chatModelOverTheStrongSlot() {
		#expect(resolveConversationSpec(nil, strong: nil, catalog: catalog) == spec(OPUS, .high))
		#expect(resolveConversationSpec(nil, strong: ModelSlot(model: SONNET), catalog: catalog) == spec(SONNET, .high))
		#expect(resolveConversationSpec(ChatSettings(model: HAIKU), strong: nil, catalog: catalog) == spec(HAIKU, .high))
	}

	@Test func bareChatEffortRidesTheStrongSlotModel() {
		#expect(resolveConversationSpec(ChatSettings(effort: .high), strong: ModelSlot(model: SONNET, effort: .low), catalog: catalog) == spec(SONNET, .high))
		#expect(resolveConversationSpec(ChatSettings(model: HAIKU, effort: .max), strong: nil, catalog: catalog) == spec(HAIKU, .max))
		#expect(resolveConversationSpec(ChatSettings(model: HAIKU), strong: ModelSlot(effort: .low), catalog: catalog) == spec(HAIKU, .low))
	}

	// NEW: the stored (unclamped) strong effort rides a chat model swap.
	@Test func storedStrongEffortRidesUnclampedOntoTheChatModel() {
		let strong = ModelSlot(model: FABLE, effort: .low)
		#expect(resolveSlot(strong, .strong, catalog: catalog) == spec(FABLE, .xhigh))
		#expect(resolveConversationSpec(ChatSettings(model: OPUS), strong: strong, catalog: catalog) == spec(OPUS, .low))
	}
}

@Suite struct EffortClampTests {
	@Test func fableClampsUpToXhigh() {
		for e in [Effort.low, .medium, .high] {
			#expect(resolveSlot(ModelSlot(model: FABLE, effort: e), .strong, catalog: catalog).effort == .xhigh, "\(e)")
		}
		#expect(resolveSlot(ModelSlot(model: FABLE, effort: .max), .strong, catalog: catalog).effort == .max)
		#expect(resolveSlot(ModelSlot(model: "claude-fable-5-1"), .strong, catalog: catalog).effort == .xhigh, "the default high clamps too")
	}

	@Test func nearestSupportedLevelRoundingUpward() {
		#expect(clampEffort(.high, supported: [.low, .max]) == .max, "tie (distance 2 each way) rounds up")
		#expect(clampEffort(.medium, supported: [.low, .max]) == .low, "nearest wins")
		#expect(clampEffort(.medium, supported: [.low, .high]) == .high, "tie rounds up")
		#expect(clampEffort(.max, supported: [.low, .medium]) == .medium, "nothing above → the highest supported")
		#expect(clampEffort(.low, supported: []) == .low)
		#expect(clampEffort(.xhigh, supported: Effort.allCases) == .xhigh)
	}

	@Test func unknownModelsResolveUnclamped() {
		let eff = resolveSettings(UserSettings(models: ModelsSettings(cheap: ModelSlot(model: "openrouter:x/y", effort: .low))), catalog: catalog)
		#expect(eff.models.cheap == spec("openrouter:x/y", .low))
		#expect(catalog.model("openrouter:x/y") == nil)
	}
}

@Suite struct GraphGateTests {
	private func graph(enabled: Bool) -> EffectiveGraph {
		EffectiveGraph(enabled: enabled, rendering: true, extractionChunkTokens: 4096)
	}

	@Test func writeChannelDiesWithTheMasterSwitch() {
		#expect(extractionEnabled(graph(enabled: true)))
		#expect(!extractionEnabled(graph(enabled: false)))
	}

	@Test func writeGateRidesFactoryDefaults() {
		#expect(extractionEnabled(resolveSettings(nil, catalog: catalog).graph))
		#expect(!extractionEnabled(resolveSettings(UserSettings(graph: GraphSettings(enabled: false)), catalog: catalog).graph))
	}

	@Test func proberGraphToolsComposeToggleAndMasterSwitch() {
		#expect(graphToolsEnabled(graphEnabled: true, graphTools: GraphToolsSettings()), "absent = ON")
		#expect(graphToolsEnabled(graphEnabled: true, graphTools: GraphToolsSettings(enabled: true)))
		#expect(!graphToolsEnabled(graphEnabled: true, graphTools: GraphToolsSettings(enabled: false)))
		#expect(!graphToolsEnabled(graphEnabled: false, graphTools: GraphToolsSettings(enabled: true)), "graph off kills the tools")
	}

	@Test func graphToolsRidesResolveSettings() {
		#expect(resolveSettings(nil, catalog: catalog).agent.graphTools == GraphToolsSettings())
		let off = resolveSettings(UserSettings(agent: AgentSettings(graphTools: GraphToolsSettings(enabled: false))), catalog: catalog)
		#expect(off.agent.graphTools == GraphToolsSettings(enabled: false))
		#expect(!graphToolsEnabled(off))
		#expect(graphToolsEnabled(resolveSettings(nil, catalog: catalog)))
	}
}
