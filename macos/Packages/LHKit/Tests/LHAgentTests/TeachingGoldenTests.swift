import Foundation
import Testing
@testable import LHAgent
@testable import LHCore

// The teaching agents against the TS golden dumps (scripts/dump-agent-golden.ts):
// tool definitions byte-identical in name and description, schema-equal;
// the source prompt composition byte-identical; then the native gates.

private func golden(_ name: String) throws -> JSONValue {
	let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden"))
	return try JSONValue.parse(Data(contentsOf: url))
}

/// Key-order-insensitive form (typebox and the DSL may order keys differently).
private func canonical(_ v: JSONValue) -> JSONValue {
	switch v {
	case .object(let o): .object(JSONObject(pairs: o.map { ($0.key, canonical($0.value)) }.sorted { $0.0 < $1.0 }))
	case .array(let a): .array(a.map(canonical))
	default: v
	}
}

private let ctx = TeachingContext(chatId: "chat_golden", record: { nil }, saveTree: { _ in }, queueHandoff: {})
private let wiring = BackgroundWiring(files: FileAccess(folders: { [] })) { _, _, _, _ in "stub" }

@Suite struct TeachingToolGoldenTests {
	@Test(arguments: [
		("tools-prober", proberTools(ctx, enabled: nil, background: wiring)),
		("tools-prober-free", proberTools(ctx, enabled: ["explain": true], background: wiring)),
		("tools-teacher", teacherTools(ctx, enabled: nil, background: wiring)),
		("tools-teacher-free", teacherTools(ctx, enabled: ["explain": true], background: wiring)),
	] as [(String, [any AgentTool])])
	func definitionsMatchTheTS(_ name: String, _ tools: [any AgentTool]) throws {
		let expected = try #require(try golden(name).arrayValue)
		#expect(tools.map(\.name) == expected.compactMap { $0["name"]?.stringValue })
		for (tool, want) in zip(tools, expected) {
			#expect(tool.description == want["description"]?.stringValue, "\(tool.name) description")
			#expect(canonical(tool.schema.json) == canonical(want["input_schema"]!), "\(tool.name) schema")
		}
	}
}

@Suite struct PromptComposerGoldenTests {
	@Test func segmentOrderMatchesTheTS() throws {
		let g = try golden("prompt-segments")
		for agent in PromptAgent.allCases {
			#expect(PromptComposer.segmentPaths(agent) == g[agent.rawValue]?.arrayValue?.compactMap(\.stringValue), "\(agent)")
		}
	}

	@Test func sourceCompositionMatchesTheTS() throws {
		#expect(PromptComposer().compose(.prober, tools: nil) == (try golden("prompt-prober").stringValue))
		#expect(PromptComposer().compose(.teacher, tools: nil) == (try golden("prompt-teacher").stringValue))
	}

	@Test func anOverrideComposesOnlyWhenSwitchedOn() {
		let off = PromptComposer(overrides: ["teacher/10-planning.md": "OVERRIDE BODY"], switches: [:]).compose(.teacher, tools: nil)
		#expect(!off.contains("OVERRIDE BODY"))
		let on = PromptComposer(overrides: ["teacher/10-planning.md": "OVERRIDE BODY"], switches: ["teacher/10-planning.md": true]).compose(.teacher, tools: nil)
		#expect(on.contains("OVERRIDE BODY"))
		let noBody = PromptComposer(overrides: [:], switches: ["teacher/10-planning.md": true]).compose(.teacher, tools: nil)
		#expect(noBody == PromptComposer().compose(.teacher, tools: nil), "a switch without an override composes the source")
	}

	@Test func gatesDropMissingToolSegmentsAndLines() {
		// M6: the teacher's tools are all registered — its source composes whole.
		let teacherSet = Set(teacherTools(ctx, enabled: nil, background: wiring).map(\.name))
		#expect(PromptComposer().compose(.teacher, tools: teacherSet) == PromptComposer().compose(.teacher, tools: nil))
		let prober = PromptComposer().compose(.prober, tools: Set(proberTools(ctx, enabled: nil, background: wiring).map(\.name)))
		#expect(!prober.contains("`list_sessions`"))
		#expect(!prober.contains("Read his persistent map"))
		#expect(prober.contains("the `read` tool"))
		#expect(prober.contains("## Grounding"))
		#expect(prober.contains("## 2. Make the goal concrete"))
		#expect(!prober.contains("\n\n\n"), "removal leaves no blank-line runs")
		// A learner who switches research off loses its prompt text too.
		let noResearch = PromptComposer().compose(.teacher, tools: teacherSet.subtracting(["research"]))
		#expect(noResearch == PromptComposer().compose(.teacher, tools: nil), "no research gate remains (TS parity: the prompt stays)")
	}

	@Test func registeredToolsKeepTheirText() {
		let all: Set = ["read", "research", "demo", "list_sessions", "quiz", "probe"]
		#expect(PromptComposer().compose(.teacher, tools: all) == PromptComposer().compose(.teacher, tools: nil))
		#expect(PromptComposer().compose(.prober, tools: all) == PromptComposer().compose(.prober, tools: nil))
	}
}
