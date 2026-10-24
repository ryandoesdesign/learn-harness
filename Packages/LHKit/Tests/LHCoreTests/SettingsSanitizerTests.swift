import Foundation
import Testing
@testable import LHCore

// Port of tests/settings.test.ts (the delta record's sanitizer and factory
// layer), adapted to docs/native-macos-m1.md "Settings". Skipped and
// rewritten cases are named in each test's comment.

private func sanitize(_ text: String) throws -> UserSettings? {
	sanitizeUserSettings(try JSONValue.parse(text))
}

@Suite struct FactorySettingsTests {
	// REWRITTEN: general/appearance pins dropped (sections died); slot models,
	// effort and compaction pins added.
	@Test func pinsTheOwnerDecidedDefaults() {
		#expect(CURRENT_SETTINGS_VERSION == 1)
		#expect(FACTORY_SETTINGS.graph == EffectiveGraph(enabled: true, rendering: true, extractionChunkTokens: 4096))
		#expect(FACTORY_SETTINGS.compaction == EffectiveCompaction(thresholdTokens: 150_000))
		#expect(FACTORY_SETTINGS.slotModels == [.strong: "claude-opus-5-5", .cheap: "claude-sonnet-5-5", .vision: "claude-sonnet-5-5"])
		#expect(FACTORY_SETTINGS.effort == .high)
		#expect(EXTRACTION_CHUNK_TOKENS_FLOOR == 500)
		#expect(COMPACTION_THRESHOLD_FLOOR == 32_000)
	}

	// REWRITTEN ("has NO factory model pin"): the native app HAS factory slot
	// models; every factory slot model is a catalog model.
	@Test func factorySlotModelsAreCatalogModels() {
		for slot in MODEL_SLOTS {
			let id = FACTORY_SETTINGS.slotModels[slot]!
			#expect(TestCatalog.shared.model(id) != nil, "\(slot) → \(id)")
		}
	}
}

@Suite struct SanitizeUserSettingsTests {
	// REWRITTEN: the adapted shape (model strings + effort; no general,
	// appearance, agent.search).
	@Test func roundTripsAFullyValidRecordFieldForField() throws {
		let text = #"""
		{"version":1,
		 "agent":{"models":{"researcher":{"model":"claude-haiku-5-5","effort":"high"},"visualMaker":{"effort":"max"}},
		          "tools":{"research":false,"quiz":true},
		          "prompts":{"system-prompt.md":true,"teacher/20-teaching.md":false},
		          "graphTools":{"enabled":false}},
		 "models":{"strong":{"model":"claude-fable-5","effort":"low"},"cheap":{"effort":"medium"}},
		 "graph":{"enabled":false,"rendering":true,"extractionChunkTokens":2048},
		 "compaction":{"thresholdTokens":64000}}
		"""#
		let raw = try JSONValue.parse(text)
		let out = try #require(sanitizeUserSettings(raw))
		expectJSONEqual(out.json, raw)
		#expect(sanitizeUserSettings(out.json) == out)
	}

	@Test func nullAndNonObjectsAreNil() throws {
		#expect(sanitizeUserSettings(nil) == nil)
		#expect(sanitizeUserSettings(.null) == nil)
		#expect(sanitizeUserSettings("junk") == nil)
		#expect(sanitizeUserSettings([1, 2]) == nil)
	}

	// PORTED (the `general` section in the original swapped for `agent`).
	@Test func absentVersionDefaultsAndUnknownKeysRideAlongVerbatim() throws {
		let out = try #require(try sanitize(#"{"futureSection":{"knob":3,"b":[1,"x"]},"agent":{"tools":{"demo":true}}}"#))
		#expect(out.version == CURRENT_SETTINGS_VERSION)
		expectJSONEqual(out.unknown["futureSection"]!, ["knob": 3, "b": [1, "x"]])
		#expect(out.agent?.tools == ["demo": true])
		// Unknown keys keep their order and re-serialize verbatim.
		let two = try #require(try sanitize(#"{"z":1,"a":{"q":null},"version":1}"#))
		#expect(two.unknown.keys == ["z", "a"])
		#expect(two.json.serialized() == #"{"version":1,"z":1,"a":{"q":null}}"#)
	}

	@Test func invalidVersionsFallBackToCurrent() throws {
		for bad in ["0", "-1", "1.5", "\"2\"", "null"] {
			#expect(try sanitize(#"{"version":\#(bad)}"#)?.version == CURRENT_SETTINGS_VERSION, "\(bad)")
		}
		#expect(try sanitize(#"{"version":3}"#)?.version == 3)
	}

	// The dead keys strip instead of riding (TS: `chat`; native: also the
	// dropped `general` and `appearance` sections — see the report).
	@Test func deadKeysAreStripped() throws {
		let out = try #require(try sanitize(#"{"chat":{"model":{"provider":"x","id":"y"}},"general":{"autoUpdate":false},"appearance":{"mode":"light"},"keep":true}"#))
		#expect(out.unknown.keys == ["keep"])
		#expect(out.json["chat"] == nil && out.json["general"] == nil && out.json["appearance"] == nil)
	}

	// PORTED minus the general/appearance assertions (sections died). The
	// NaN/Infinity junk values are not representable in JSON and are skipped.
	@Test func wrongTypedFieldsDropNeverCrash() throws {
		let out = try #require(try sanitize(#"""
		{"agent":{"tools":{"research":"no"},"prompts":{"system-prompt.md":1},"models":{"researcher":"fast"}},
		 "graph":{"enabled":0}}
		"""#))
		#expect(out.agent == AgentSettings())
		#expect(out.graph == GraphSettings())

		#expect(try sanitize(#"{"version":1,"graph":{"enabled":true,"extractionChunkTokens":2048}}"#)?.graph == GraphSettings(enabled: true, extractionChunkTokens: 2048))
		#expect(try sanitize(#"{"version":1,"graph":{"extractionChunkTokens":1024.9}}"#)?.graph?.extractionChunkTokens == 1024, "fractions floor to whole tokens")
		#expect(try sanitize(#"{"version":1,"graph":{"extractionChunkTokens":10}}"#)?.graph?.extractionChunkTokens == 500, "below the floor clamps UP")
		for junk in ["0", "-1000", "\"4096\"", "null", "true"] {
			let dropped = try sanitize(#"{"version":1,"graph":{"extractionChunkTokens":\#(junk)}}"#)
			#expect(dropped?.graph != nil)
			#expect(dropped?.graph?.extractionChunkTokens == nil, "junk \(junk) drops")
		}
	}

	// NEW (the M1 bug fix): compaction is sanitized without a graph section.
	@Test func compactionIsSanitizedIndependentlyOfGraph() throws {
		#expect(try sanitize(#"{"compaction":{"thresholdTokens":1000}}"#)?.compaction == CompactionSettings(thresholdTokens: 32_000))
		#expect(try sanitize(#"{"compaction":{"thresholdTokens":50000.7}}"#)?.compaction == CompactionSettings(thresholdTokens: 50_000))
		let junk = try #require(try sanitize(#"{"compaction":{"thresholdTokens":"big","x":1}}"#))
		#expect(junk.compaction == CompactionSettings())
		#expect(junk.unknown["compaction"] == nil, "a known section never rides along raw")
		#expect(try sanitize(#"{"compaction":5}"#)?.compaction == nil)
	}

	// REWRITTEN: model strings + effort instead of {provider,id} + thinkingLevel.
	@Test func agentRolesUnknownRolesDropKnownRolesKeepWellFormedOverrides() throws {
		let out = try #require(try sanitize(#"""
		{"agent":{"models":{
			"teacher":{"effort":"low"},
			"pdfReader":{"effort":"low"},
			"researcher":{"model":"claude-haiku-5-5"},
			"extractor":{"model":3,"effort":"high"},
			"auditor":{"effort":"banana"},
			"demoBuilder":{"model":{"provider":"anthropic","id":"claude-opus-5-5"}}
		}}}
		"""#))
		let models = out.agent?.models ?? [:]
		#expect(models[.teacher] == nil, "not a background role")
		#expect(models[.pdfReader] == nil, "not a background role")
		#expect(models[.researcher] == ModelSlot(model: "claude-haiku-5-5"))
		#expect(models[.extractor] == ModelSlot(effort: .high), "bad model drops, effort kept")
		#expect(models[.auditor] == nil, "invalid level → empty override drops")
		#expect(models[.demoBuilder] == nil, "the legacy object shape is not a native model")
	}

	@Test func slotsKeepOnlyWellFormedParts() throws {
		let out = try #require(try sanitize(#"{"models":{"strong":{"model":"claude-fable-5","effort":"off"},"cheap":{"effort":"xhigh"},"vision":"x","bogus":{"model":"m"}}}"#))
		#expect(out.models == ModelsSettings(strong: ModelSlot(model: "claude-fable-5"), cheap: ModelSlot(effort: .xhigh)))
		#expect(try sanitize(#"{"models":{"strong":{}}}"#)?.models == nil, "an all-empty section drops")
	}

	// REWRITTEN (search engine pin): agent.search died; it drops.
	@Test func agentSearchDrops() throws {
		let out = try #require(try sanitize(#"{"version":1,"agent":{"search":{"engine":"tavily"},"tools":{"research":true}}}"#))
		#expect(out.agent == AgentSettings(tools: ["research": true]))
		#expect(out.json["agent"]?["search"] == nil)
	}

	@Test func graphToolsBooleanSurvivesBadShapesDrop() throws {
		#expect(try sanitize(#"{"version":1,"agent":{"graphTools":{"enabled":true}}}"#)?.agent?.graphTools == GraphToolsSettings(enabled: true))
		#expect(try sanitize(#"{"version":1,"agent":{"graphTools":{"enabled":false}}}"#)?.agent?.graphTools == GraphToolsSettings(enabled: false))
		#expect(try sanitize(#"{"version":1,"agent":{"graphTools":{}}}"#)?.agent?.graphTools == GraphToolsSettings())
		#expect(try sanitize(#"{"version":1,"agent":{"graphTools":"on"}}"#)?.agent?.graphTools == nil)
		#expect(try sanitize(#"{"version":1,"agent":{"graphTools":{"enabled":"yes"}}}"#)?.agent?.graphTools == nil)
	}

	@Test func partialMapsBooleansSurviveNonBooleansDropIndividually() throws {
		let out = try sanitize(#"{"agent":{"tools":{"quiz":false,"demo":true,"visual":"x"}}}"#)
		#expect(out?.agent?.tools == ["quiz": false, "demo": true])
	}

	@Test func backgroundModelRolesMatchTheFiveBackgroundRoles() {
		#expect(BACKGROUND_MODEL_ROLES == [.researcher, .demoBuilder, .visualMaker, .extractor, .auditor])
		#expect(ModelRole.allCases.map(\.rawValue) == ["prober", "teacher", "researcher", "demoBuilder", "visualMaker", "pdfReader", "extractor", "auditor"])
	}
}

@Suite struct LegacySettingsDecodingTests {
	@Test func decodesTheGoldenSettingsFile() throws {
		let s = try #require(UserSettings(legacyJSON: try Fixtures.json("settings.json")))
		#expect(s.version == 1)
		#expect(s.agent == AgentSettings(tools: ["explain": false]))
		#expect(s.models == ModelsSettings(
			strong: ModelSlot(model: "openrouter:deepseek/deepseek-v4.1-flash", effort: .low),
			cheap: ModelSlot(model: "openrouter:deepseek/deepseek-v4.1-flash", effort: .low),
			vision: ModelSlot(model: "openrouter:qwen/qwen3.8-max-0902", effort: .low)))
		// compaction without a graph section — the bug-fix path.
		#expect(s.compaction == CompactionSettings(thresholdTokens: 50_000))
		#expect(s.graph == nil)
		#expect(s.unknown.isEmpty)
	}

	@Test func mapsAnthropicIdsBareAndThinkingLevelsToEffort() throws {
		let raw = try JSONValue.parse(#"""
		{"version":1,
		 "general":{"autoUpdate":false},
		 "appearance":{"mode":"light"},
		 "chat":{"model":{"provider":"anthropic","id":"claude-opus-5-5"}},
		 "agent":{"search":{"engine":"brave"},
		          "models":{"researcher":{"model":{"provider":"anthropic","id":"claude-haiku-5-5"},"thinkingLevel":"minimal"},
		                    "auditor":{"thinkingLevel":"xhigh"},
		                    "teacher":{"thinkingLevel":"high"}}},
		 "models":{"strong":{"model":{"provider":"anthropic","id":"claude-fable-5"},"thinkingLevel":"off"},
		           "cheap":{"model":{"provider":"openai","id":"gpt-5.2"}},
		           "vision":{"thinkingLevel":"bogus"}},
		 "graph":{"enabled":true,"embedding":true},
		 "futureKey":[1]}
		"""#)
		let s = try #require(UserSettings(legacyJSON: raw))
		#expect(s.agent?.models == [.researcher: ModelSlot(model: "claude-haiku-5-5", effort: .low), .auditor: ModelSlot(effort: .xhigh)])
		#expect(s.agent?.tools == nil)
		#expect(s.models == ModelsSettings(strong: ModelSlot(model: "claude-fable-5", effort: .low), cheap: ModelSlot(model: "openai:gpt-5.2")))
		#expect(s.graph == GraphSettings(enabled: true))
		#expect(s.unknown.keys == ["futureKey"], "general/appearance/chat are dead; unknown keys ride")
		#expect(UserSettings(legacyJSON: "x") == nil)
	}
}
