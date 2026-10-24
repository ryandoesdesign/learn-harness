import Foundation
import Testing
@testable import LHAgent
@testable import LHCore

// Port of tests/question-tools.test.ts (descriptions and registries are
// pinned by TeachingToolGoldenTests; these are the behaviours).

private func ctx(tree: PlanTree?) -> TeachingContext {
	TeachingContext(chatId: "c", record: { ChatRecord(id: "c", title: "t", createdAt: "", updatedAt: "", messages: [], tree: tree) }, saveTree: { _ in }, queueHandoff: {})
}

private let tree = PlanTree(nodes: (1...7).map { PlanNode(id: "n\($0)", title: "N\($0)") }, edges: [], version: 1)

private func quizArgs(_ nodeId: String?) -> JSONValue {
	var o = JSONObject(pairs: [("type", "check")])
	if let nodeId { o["nodeId"] = .string(nodeId) }
	o["question"] = "Q?"
	o["options"] = [["label": "A", "value": "a"], ["label": "B", "value": "b"]]
	o["explanation"] = "Because."
	o["correctAnswer"] = "a"
	return .object(o)
}

private func run(_ tool: any AgentTool, _ args: JSONValue) async throws -> ToolOutput {
	let converted = tool.schema.convert(tool.prepare(args))
	guard tool.schema.check(converted) else { return .error("schema") }
	return try await tool.execute(converted, context: ToolContext(toolCallId: "t"))
}

@Suite struct QuestionToolsTests {
	@Test func aMatchingNodeIdIsPosed() async throws {
		let out = try await run(QuestionTool.quiz(ctx(tree: tree)), quizArgs("n2"))
		#expect(out.terminate && out.ephemeral && !out.isError)
	}
	@Test func anOffMapNodeIdListsTheSlugs() async throws {
		let out = try await run(QuestionTool.quiz(ctx(tree: tree)), quizArgs("nope"))
		#expect(out.isError)
		let text = out.content.first?.raw["text"]?.stringValue ?? ""
		#expect(text.contains("nodeId \"nope\" matches no node in this session's plan map. Copy one of your plan_init slugs exactly (n1, n2, n3, n4, n5, …)."))
	}
	@Test func noTreeYetRejectsAnyNodeId() async throws {
		let out = try await run(QuestionTool.quiz(ctx(tree: nil)), quizArgs("n1"))
		#expect(out.content.first?.raw["text"]?.stringValue?.contains("No plan map exists yet — call plan_init before posing quizzes.") == true)
	}
	@Test func aMissingNodeIdFailsTheBoundary() async throws {
		let tool = QuestionTool.quiz(ctx(tree: tree))
		#expect(!tool.schema.check(tool.schema.convert(quizArgs(nil))))
	}
	@Test func theLiveRecordIsReadAtCallTime() async throws {
		let current = Box<PlanTree?>(nil)
		let live = TeachingContext(chatId: "c", record: { ChatRecord(id: "c", title: "t", createdAt: "", updatedAt: "", messages: [], tree: current.value) }, saveTree: { _ in }, queueHandoff: {})
		#expect(try await run(QuestionTool.quiz(live), quizArgs("n1")).isError)
		current.mutate { $0 = tree }
		#expect(try await !run(QuestionTool.quiz(live), quizArgs("n1")).isError)
	}
	@Test func gradingRulesChainFirst() async throws {
		var args = quizArgs("nope")
		args["correctAnswer"] = "zzz"
		let text = try await run(QuestionTool.quiz(ctx(tree: tree)), args).content.first?.raw["text"]?.stringValue ?? ""
		let lines = text.components(separatedBy: "\n").dropFirst()
		#expect(lines.first?.contains("nodeId") == false, "the grading problem is listed before the nodeId one")
		#expect(lines.last?.contains("nodeId") == true)
	}
	@Test func theProbeSchemaHasNoNodeId() {
		#expect(QuestionTool.probe.schema.json["properties"]?["nodeId"] == nil)
		#expect(QuestionTool.recall.schema.json["properties"]?["nodeId"] == nil)
	}
	@Test func stringEncodedOptionsAreCoercedOnEveryQuestionTool() async throws {
		var args = quizArgs("n1")
		args["options"] = .string(#"[{"label":"A","value":"a"},{"label":"B","value":"b"}]"#)
		#expect(try await !run(QuestionTool.quiz(ctx(tree: tree)), args).isError)
		var probe = quizArgs(nil)
		probe = .object(JSONObject(pairs: (probe.objectValue ?? JSONObject()).filter { $0.key != "type" }.map { ($0.key, $0.value) }))
		probe["options"] = .string(#"[{"label":"A","value":"a"},{"label":"B","value":"b"}]"#)
		#expect(try await !run(QuestionTool.probe, probe).isError)
		let ask: JSONValue = ["question": "Which?", "options": .string(#"[{"label":"X"},{"label":"Y"}]"#)]
		#expect(try await !run(QuestionTool.ask, ask).isError)
	}
	@Test func explainValidatesNodeIdAndTheCommitment() async throws {
		let ok: JSONValue = ["type": "check", "nodeId": "n1", "question": "Why?", "correctAnswer": "Because of X, which implies Y."]
		#expect(try await !run(QuestionTool.explain(ctx(tree: tree)), ok).isError)
		var off = ok
		off["nodeId"] = "zz"
		#expect(try await run(QuestionTool.explain(ctx(tree: tree)), off).isError)
		var empty = ok
		empty["correctAnswer"] = "  "
		#expect(try await run(QuestionTool.explain(ctx(tree: tree)), empty).isError)
	}
	@Test func freeRecallMechanicsSwapTheQuizzingTool() {
		#expect(proberTools(ctx(tree: nil), enabled: ["explain": true]).map(\.name) == ["recall", "ask_user_question", "probe_done"])
		#expect(teacherTools(ctx(tree: nil), enabled: ["explain": true, "quiz": false]).map(\.name) == ["explain", "ask_user_question", "plan_init"])
		#expect(proberTools(ctx(tree: nil), enabled: ["probe_done": false]).map(\.name).contains("probe_done"), "probe_done is always on")
	}
	@Test func planInitRefusesABadMapWithTheParserProblems() async throws {
		let out = try await run(PlanInitTool(ctx: ctx(tree: nil)), ["mermaid": "graph TD\n  Bad Id[x]"])
		#expect(!out.isError, "a refusal is a normal result")
		#expect(out.details?["ok"]?.boolValue == false)
		#expect(out.details?["error"]?.stringValue?.contains(/line 2.*slug/) == true)
	}
	@Test func planInitReturnsTheSlimContentAndTheTree() async throws {
		let saved = Box<PlanTree?>(nil)
		let c = TeachingContext(chatId: "c", record: { ChatRecord(id: "c", title: "t", createdAt: "", updatedAt: "", messages: []) }, saveTree: { t in saved.mutate { $0 = t } }, queueHandoff: {})
		let out = try await run(PlanInitTool(ctx: c), ["mermaid": "graph TD\n  a[A] --> b[B]"])
		let text = try JSONValue.parse(out.content.first?.raw["text"]?.stringValue ?? "")
		#expect(text["nodeIds"] == ["a", "b"])
		#expect(text["reminder"]?.stringValue == PLAN_NODE_IDS_REMINDER)
		#expect(out.details?["tree"]?["nodes"]?.arrayValue?.count == 2)
		#expect(saved.value?.edges == [PlanEdge(from: "a", to: "b")])
	}
}
